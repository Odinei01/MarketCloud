package query

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/zanom/marketcloud/internal/middleware"
)

// gold_v2.go â€” endpoints da Gold Layer V2 (cockpit operacional) + loop de
// feedback. Somente LEITURA das views Gold e ESCRITA de decisÃ£o humana.
// Nenhum endpoint executa aÃ§Ã£o na Amazon.

// GET /api/v1/gold/hourly-real?action=&confidence=&limit=
// RecomendaÃ§Ãµes horÃ¡rias sobre o DADO REAL (relatÃ³rio da conta, sem supressÃ£o),
// cruzadas com a agenda de multiplicadores do RobÃ´. Somente leitura.
// Fonte: gold_hourly_recommendations_v1 (single-tenant ZANOM).
func (h *Handler) GoldHourlyReal(w http.ResponseWriter, r *http.Request) {
	limit := 200
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 1000 {
			limit = n
		}
	}
	where := []string{"1=1"}
	args := []any{}
	add := func(cond, val string) {
		if val != "" {
			args = append(args, val)
			where = append(where, cond+"$"+strconv.Itoa(len(args)))
		}
	}
	add("action_type = ", r.URL.Query().Get("action"))
	add("confidence = ", r.URL.Query().Get("confidence"))
	// sÃ³ o acionÃ¡vel (esconde KEEP_STRONG) por padrÃ£o
	if r.URL.Query().Get("include_keep") != "true" {
		where = append(where, "action_type <> 'KEEP_STRONG'")
	}

	sql := `
	  SELECT *,
	    -- status derivado dos numeros JA recontados contra o alvo do ML,
	    -- nao o schedule_overlap_status cru da v1 (que comparava com a sugestao antiga).
	    CASE WHEN rules_still_need_change > 0 AND rules_already_aligned > 0 THEN 'PARTIALLY_CORRECTED'
	         WHEN rules_still_need_change > 0 THEN 'NEEDS_CHANGE'
	         ELSE 'ALIGNED' END AS schedule_overlap_status
	  FROM (
		SELECT gr.recommendation_id, gr.campaign_name, gr.event_hour,
			-- ACAO e SUGERIDO vem do ALVO DO ML quando ele existe pra essa
			-- campanha x hora (mesmo cerebro do cockpit e da tela de keyword).
			-- Sem alvo do ML, cai no que a v1 calculava. Unifica as 3 telas.
			CASE WHEN t.ml_multiplier IS NULL THEN gr.action_type
			     WHEN t.ml_multiplier > gr.current_multiplier + 0.001 THEN 'BID_UP'
			     WHEN t.ml_multiplier < gr.current_multiplier - 0.001 THEN 'BID_DOWN'
			     ELSE 'KEEP_STRONG' END AS action_type,
			gr.confidence,
			gr.spend::float8 AS spend, gr.orders::int AS orders, gr.sales::float8 AS sales,
			gr.roas::float8 AS roas, gr.cvr::float8 AS cvr, gr.clicks::int AS clicks,
			gr.impressions::int AS impressions, gr.days_observed::int AS days_observed,
			gr.current_multiplier::float8 AS current_multiplier,
			gr.mult_max::float8 AS mult_max, gr.has_schedule,
			COALESCE(t.ml_multiplier, gr.suggested_multiplier)::float8 AS suggested_multiplier,
			(t.ml_multiplier IS NOT NULL) AS suggestion_from_ml,
			gr.overlap_rule_count,
			-- "X de Y abaixo" recontado contra o ALVO DO ML, nao contra a
			-- suggested_multiplier da v1. Se sobe (alvo > atual): regra abaixo do
			-- alvo ainda precisa mudar. Se desce: regra acima do alvo. Sem alvo do
			-- ML, mantem o que a v1 contou.
			CASE WHEN t.ml_multiplier IS NULL THEN gr.rules_still_need_change
			     ELSE (SELECT count(*) FROM jsonb_array_elements(gr.overlap_rule_details) e
			           WHERE CASE WHEN t.ml_multiplier > gr.current_multiplier
			                      THEN (e->>'multiplier')::float8 < t.ml_multiplier - 0.001
			                      ELSE (e->>'multiplier')::float8 > t.ml_multiplier + 0.001 END)
			END AS rules_still_need_change,
			CASE WHEN t.ml_multiplier IS NULL THEN gr.rules_already_aligned
			     ELSE (SELECT count(*) FROM jsonb_array_elements(gr.overlap_rule_details) e
			           WHERE CASE WHEN t.ml_multiplier > gr.current_multiplier
			                      THEN (e->>'multiplier')::float8 >= t.ml_multiplier - 0.001
			                      ELSE (e->>'multiplier')::float8 <= t.ml_multiplier + 0.001 END)
			END AS rules_already_aligned,
			gr.overlap_mult_min::float8 AS overlap_mult_min,
			gr.overlap_mult_max::float8 AS overlap_mult_max,
			gr.overlap_labels, gr.overlap_rule_details,
			gr.priority_score::float8 AS priority_score, gr.label_caveat,
			gr.window_from, gr.window_to,
			gr.ml_conversion_probability::float8 AS ml_conversion_probability,
			gr.ml_expected_roas::float8 AS ml_expected_roas,
			gr.ml_good_hour, gr.ml_agrees,
			(SELECT CASE WHEN bool_and(u.conversion_trustworthy) THEN 'MATURE'
			             WHEN bool_or(u.conversion_trustworthy)  THEN 'MIXED'
			             ELSE 'IMMATURE' END
			 FROM marketcloud_gold.gold_hourly_signal_unified u
			 WHERE LOWER(TRIM(u.campaign_name)) = LOWER(TRIM(gr.campaign_name))
			   AND u.event_hour = gr.event_hour) AS conversion_maturity,
			(SELECT CASE WHEN bool_or(u.traffic_source = 'AMS_STREAM') THEN 'AMS_STREAM' ELSE 'REPORTING' END
			 FROM marketcloud_gold.gold_hourly_signal_unified u
			 WHERE LOWER(TRIM(u.campaign_name)) = LOWER(TRIM(gr.campaign_name))
			   AND u.event_hour = gr.event_hour) AS traffic_source
		FROM marketcloud_gold.gold_hourly_recommendations_v1 gr
		LEFT JOIN marketcloud_gold.gold_hourly_ml_target_mv t
		  ON t.campaign_name = gr.campaign_name AND t.event_hour = gr.event_hour
	) q0
	WHERE ` + strings.Join(where, " AND ") + `
	ORDER BY priority_score DESC
	LIMIT ` + strconv.Itoa(limit)

	rows, err := h.db.Query(r.Context(), sql, args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "hourly_real_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

// POST /api/v1/gold/refresh-swarm-state
// Recarrega o snapshot SWARM -> bronze na hora.
//
// Por que existe: o loop de sync roda de hora em hora, entao um pin aplicado
// pela tela ficava invisivel pra ela por ate 60min — a recomendacao "voltava"
// e o dono clicava de novo no que ja tinha feito. A tela chama isto depois de
// aplicar, pra ver o efeito do proprio clique.
func (h *Handler) RefreshSwarmState(w http.ResponseWriter, r *http.Request) {
	// refresh_swarm_state_and_target: sync do SWARM + refresh do alvo do ML
	// materializado. Os dois juntos, senao a tela mostra agenda nova com alvo velho.
	rows, err := h.db.Query(r.Context(), `SELECT source_table, rows_inserted FROM marketcloud_bronze.refresh_swarm_state_and_target()`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "refresh_failed: "+err.Error())
		return
	}
	defer rows.Close()
	refreshed := map[string]any{}
	for rows.Next() {
		var table string
		var n int64
		if err := rows.Scan(&table, &n); err == nil {
			refreshed[table] = n
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"refreshed": refreshed})
}

// GET /api/v1/gold/keyword-hourly-real?action=&confidence=&source=&limit=
// Recomendacoes advisor no grao keyword x hora. A execucao continua fora daqui:
// o endpoint so mostra lance efetivo = base bid da keyword x multiplicador horario.
func (h *Handler) GoldKeywordHourlyReal(w http.ResponseWriter, r *http.Request) {
	limit := 200
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 1000 {
			limit = n
		}
	}
	where := []string{"1=1"}
	args := []any{}
	add := func(cond, val string) {
		if val != "" {
			args = append(args, val)
			where = append(where, cond+"$"+strconv.Itoa(len(args)))
		}
	}
	add("r.campaign_action_type = ", r.URL.Query().Get("action"))
	add("r.confidence = ", r.URL.Query().Get("confidence"))
	add("r.source_grain = ", r.URL.Query().Get("source"))

	sql := `
		SELECT r.keyword_hour_recommendation_id, r.campaign_id, r.campaign_name,
			r.ad_group_id, r.ad_group_name, r.keyword_text, r.match_type, r.event_hour,
			r.campaign_action_type, r.advisor_action, r.confidence, r.source_grain,
			r.sample_guard, r.execution_hint,
			r.base_bid::float8 AS base_bid,
			r.current_hour_multiplier::float8 AS current_hour_multiplier,
			r.suggested_hour_multiplier::float8 AS suggested_hour_multiplier,
			r.current_effective_bid::float8 AS current_effective_bid,
			r.suggested_effective_bid::float8 AS suggested_effective_bid,
			r.effective_bid_delta::float8 AS effective_bid_delta,
			r.effective_bid_delta_percent::float8 AS effective_bid_delta_percent,
			r.spend::float8 AS spend, r.orders::int AS orders, r.sales::float8 AS sales,
			r.roas::float8 AS roas, r.clicks::int AS clicks, r.impressions::int AS impressions,
			r.days_observed::int AS days_observed, r.window_from, r.window_to,
			r.ml_conversion_probability::float8 AS ml_conversion_probability,
			r.ml_expected_roas::float8 AS ml_expected_roas,
			r.ml_good_hour, r.ml_agrees,
			r.target_ml_click_probability::float8 AS target_ml_click_probability,
			r.target_ml_conversion_probability::float8 AS target_ml_conversion_probability,
			r.target_ml_expected_roas::float8 AS target_ml_expected_roas,
			r.target_ml_good_hour,
			r.target_ml_label_caveat,
			r.target_ml_computed_at,
			r.priority_score::float8 AS priority_score,
			r.target_hour_has_data,
			r.target_impressions::float8 AS target_impressions,
			r.target_clicks::float8 AS target_clicks,
			r.target_spend::float8 AS target_spend,
			r.target_orders::float8 AS target_orders,
			r.target_sales::float8 AS target_sales,
			r.current_multiplier_scope,
			r.ml_target_roas::float8 AS ml_target_roas,
			r.ml_roas_ancora::float8 AS ml_roas_ancora,
			r.ml_roas_observado::float8 AS ml_roas_observado,
			r.ml_gasto_observado::float8 AS ml_gasto_observado,
			r.vetoed, r.veto_reason
		FROM marketcloud_gold.gold_keyword_hourly_recommendations_v3 r
		WHERE ` + strings.Join(where, " AND ") + `
		ORDER BY r.priority_score DESC, ABS(r.effective_bid_delta) DESC
		LIMIT ` + strconv.Itoa(limit)

	rows, err := h.db.Query(r.Context(), sql, args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "keyword_hourly_real_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

// GET /api/v1/gold/keyword-hourly-real/{id}/explain
// JSON pesado do modal de detalhe. Fica separado da lista porque a view de
// explicacao recalcula contexto comercial/calendario e deixava a tela presa.
func (h *Handler) GoldKeywordHourlyExplain(w http.ResponseWriter, r *http.Request) {
	recID := strings.TrimSpace(chi.URLParam(r, "id"))
	if recID == "" {
		writeError(w, http.StatusBadRequest, "recommendation_id_required")
		return
	}
	// Le do matview (keyword_hourly_recommendation_explain_mv, migration 139):
	// a view crua custa ~15s/id (filtro nao empurrado), o matview e sub-ms.
	// Refresh periodico no runAmsHourlyRefreshLoop do query-orchestrator.
	rows, err := h.db.Query(r.Context(), `
		SELECT COALESCE(mv.explanation_json::text, '{}') AS explanation_json
		FROM marketcloud_gold.gold_keyword_hourly_recommendations_v3 r
		LEFT JOIN marketcloud_gold.keyword_hourly_recommendation_explain_mv mv
			USING (keyword_hour_recommendation_id)
		WHERE r.keyword_hour_recommendation_id = $1
		LIMIT 1
	`, recID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "keyword_hourly_explain_failed: "+err.Error())
		return
	}
	item, err := pgx.CollectOneRow(rows, pgx.RowToMap)
	if err != nil {
		if err == pgx.ErrNoRows {
			writeError(w, http.StatusNotFound, "keyword_hourly_explain_not_found")
			return
		}
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, item)
}

// POST /api/v1/gold/review-queue/{id}/decision
// Registra a decisÃ£o humana. NÃƒO executa nada na Amazon.
// Body: { decision, decided_action?, decision_notes?, execution_status? }
// POST /api/v1/gold/keyword-hourly/apply
// Aplica um pin de keyword-hora via Robo/SWARM E registra a decisao localmente
// em recommendation_decisions. Antes a tela chamava o Robo direto e o loop
// proposta->aplicada->medida->outcome so existia no SWARM; agora o MarketCloud
// tem o registro da decisao (achado P1 da auditoria 17/07).
func (h *Handler) GoldKeywordApply(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	userID := middleware.UserIDFromCtx(r.Context()).String()

	var body struct {
		RecommendationID      string  `json:"recommendation_id"`
		CampaignID            string  `json:"campaign_id"`
		CampaignName          string  `json:"campaign_name"`
		AdGroupID             string  `json:"ad_group_id"`
		KeywordText           string  `json:"keyword_text"`
		MatchType             string  `json:"match_type"`
		Hour                  int     `json:"hour"`
		ActionType            string  `json:"action_type"`
		SuggestedMultiplier   float64 `json:"suggested_multiplier"`
		BaseBid               float64 `json:"base_bid"`
		SuggestedEffectiveBid float64 `json:"suggested_effective_bid"`
		BaselineImpressions   float64 `json:"baseline_impressions"`
		BaselineClicks        float64 `json:"baseline_clicks"`
		BaselineSpend         float64 `json:"baseline_spend"`
		BaselineOrders        float64 `json:"baseline_orders"`
		BaselineSales         float64 `json:"baseline_sales"`
		BaselineRoas          float64 `json:"baseline_roas"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if body.RecommendationID == "" {
		writeError(w, http.StatusBadRequest, "recommendation_id_required")
		return
	}

	// 1) Chama o Robo (SWARM) com snapshot canonico do banco. O frontend manda
	// apenas o recommendation_id; campos criticos sao reconstruidos da v3.
	rows, err := h.db.Query(r.Context(), `
		SELECT keyword_hour_recommendation_id, campaign_id, campaign_name,
			ad_group_id, keyword_text, match_type, event_hour::int,
			campaign_action_type, confidence, source_grain,
			base_bid::float8 AS base_bid,
			current_hour_multiplier::float8 AS current_hour_multiplier,
			suggested_hour_multiplier::float8 AS suggested_hour_multiplier,
			current_effective_bid::float8 AS current_effective_bid,
			suggested_effective_bid::float8 AS suggested_effective_bid,
			impressions::float8 AS impressions, clicks::float8 AS clicks,
			spend::float8 AS spend, orders::float8 AS orders,
			sales::float8 AS sales, roas::float8 AS roas,
			audit_reason
		FROM marketcloud_gold.gold_keyword_hourly_recommendations_v3
		WHERE keyword_hour_recommendation_id = $1
		  AND audit_decision = 'APPROVED'
		  AND campaign_action_type IN ('BID_UP','BID_DOWN','CUT_HOUR')
		LIMIT 1
	`, body.RecommendationID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "keyword_recommendation_lookup_failed: "+err.Error())
		return
	}
	rec, err := pgx.CollectOneRow(rows, pgx.RowToMap)
	if err != nil {
		if err == pgx.ErrNoRows {
			writeError(w, http.StatusConflict, "keyword_recommendation_not_actionable")
			return
		}
		writeError(w, http.StatusInternalServerError, "keyword_recommendation_scan_failed: "+err.Error())
		return
	}
	asString := func(key string) string {
		if v, ok := rec[key]; ok && v != nil {
			if s, ok := v.(string); ok {
				return strings.TrimSpace(s)
			}
		}
		return ""
	}
	asFloat := func(key string) float64 {
		if v, ok := rec[key]; ok && v != nil {
			switch x := v.(type) {
			case float64:
				return x
			case int64:
				return float64(x)
			case int32:
				return float64(x)
			case int:
				return float64(x)
			}
		}
		return 0
	}
	asInt := func(key string) int {
		if v, ok := rec[key]; ok && v != nil {
			switch x := v.(type) {
			case int32:
				return int(x)
			case int64:
				return int(x)
			case int:
				return x
			case float64:
				return int(x)
			}
		}
		return 0
	}

	body.RecommendationID = asString("keyword_hour_recommendation_id")
	body.CampaignID = asString("campaign_id")
	body.CampaignName = asString("campaign_name")
	body.AdGroupID = asString("ad_group_id")
	body.KeywordText = asString("keyword_text")
	body.MatchType = asString("match_type")
	body.Hour = asInt("event_hour")
	body.ActionType = asString("campaign_action_type")
	body.SuggestedMultiplier = asFloat("suggested_hour_multiplier")
	body.BaseBid = asFloat("base_bid")
	body.SuggestedEffectiveBid = asFloat("suggested_effective_bid")
	body.BaselineImpressions = asFloat("impressions")
	body.BaselineClicks = asFloat("clicks")
	body.BaselineSpend = asFloat("spend")
	body.BaselineOrders = asFloat("orders")
	body.BaselineSales = asFloat("sales")
	body.BaselineRoas = asFloat("roas")
	if body.RecommendationID == "" || body.CampaignID == "" || body.KeywordText == "" {
		writeError(w, http.StatusConflict, "keyword_recommendation_missing_required_fields")
		return
	}

	roboBase := strings.TrimRight(os.Getenv("BID_ROBOT_API_BASE"), "/")
	if roboBase == "" {
		roboBase = "http://host.docker.internal:8080"
	}
	roboPayload, _ := json.Marshal(map[string]interface{}{
		"campaign_id": body.CampaignID, "ad_group_id": body.AdGroupID,
		"keyword_text": body.KeywordText, "match_type": body.MatchType,
		"campaign_name": body.CampaignName, "hour": body.Hour,
		"suggested_multiplier": body.SuggestedMultiplier, "recommendation_id": body.RecommendationID,
		"base_bid": body.BaseBid, "suggested_effective_bid": body.SuggestedEffectiveBid,
		"baseline_impressions": body.BaselineImpressions, "baseline_clicks": body.BaselineClicks,
		"baseline_spend": body.BaselineSpend, "baseline_orders": body.BaselineOrders,
		"baseline_sales": body.BaselineSales, "baseline_roas": body.BaselineRoas,
	})
	roboStatus := "ROBOT_UNREACHABLE"
	roboBody := map[string]interface{}{}
	applied := false
	client := &http.Client{Timeout: 60 * time.Second}
	req, _ := http.NewRequestWithContext(r.Context(), http.MethodPost, roboBase+"/api/amazon/ads/bid-robot/schedules/apply-suggestion-entity", bytes.NewReader(roboPayload))
	req.Header.Set("Content-Type", "application/json")
	if resp, err := client.Do(req); err == nil {
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		_ = json.Unmarshal(raw, &roboBody)
		if s, ok := roboBody["status"].(string); ok {
			roboStatus = strings.ToUpper(s)
		}
		applied = resp.StatusCode < 300 && (roboStatus == "APPLIED" || roboStatus == "ALREADY_ALIGNED" || roboStatus == "OK" || roboStatus == "PUBLISHED")
	}

	// 2) Registra a decisao no MarketCloud, independente do resultado do Robo.
	//    execution_status reflete se aplicou de fato.
	execStatus := "SKIPPED"
	if applied {
		execStatus = "EXECUTED"
	}
	action := body.ActionType
	if action == "" {
		action = "KEYWORD_HOUR_PIN"
	}
	entityKey := body.KeywordText + ":" + strconv.Itoa(body.Hour)
	evidence, _ := json.Marshal(map[string]interface{}{
		"source": "keyword_hourly_apply_screen", "snapshot_source": "marketcloud_gold.gold_keyword_hourly_recommendations_v3",
		"robot_status": roboStatus, "audit_reason": asString("audit_reason"),
		"confidence": asString("confidence"), "source_grain": asString("source_grain"),
		"base_bid": body.BaseBid, "current_hour_multiplier": asFloat("current_hour_multiplier"),
		"current_effective_bid": asFloat("current_effective_bid"), "suggested_effective_bid": body.SuggestedEffectiveBid,
		"baseline": map[string]float64{"impressions": body.BaselineImpressions, "clicks": body.BaselineClicks,
			"spend": body.BaselineSpend, "orders": body.BaselineOrders, "sales": body.BaselineSales, "roas": body.BaselineRoas},
	})
	_, err = h.db.Exec(r.Context(), `
		INSERT INTO marketcloud_recommendations.recommendation_decisions (
			recommendation_id, tenant_id, amc_instance_id, ads_profile_id,
			entity_type, entity_key, campaign_id, campaign_name, ad_product_type,
			event_hour, recommended_action, recommended_bid_multiplier,
			decision, decided_action, decided_bid_multiplier, decided_by,
			decision_notes, gold_evidence_json, decided_at, execution_status, executed_at, updated_at)
		SELECT
			$1, $2,
			COALESCE((SELECT amc_instance_id FROM marketcloud_control.amc_instances WHERE tenant_id=$2 LIMIT 1), 'amcoo5vzswt'),
			COALESCE((SELECT ads_profile_id FROM marketcloud_control.amc_instances WHERE tenant_id=$2 LIMIT 1), '3084626225435227'),
			'KEYWORD_HOUR', $3, NULLIF($4,''), $5, 'SPONSORED_PRODUCTS',
			$6, $7, $8,
			'APPROVED', $7, $8, $9,
			$10, $11::jsonb, NOW(), $12, CASE WHEN $12='EXECUTED' THEN NOW() ELSE NULL END, NOW()
		ON CONFLICT (recommendation_id) DO UPDATE SET
			decision='APPROVED', decided_action=EXCLUDED.decided_action,
			decided_bid_multiplier=EXCLUDED.decided_bid_multiplier, decided_by=EXCLUDED.decided_by,
			decision_notes=EXCLUDED.decision_notes, gold_evidence_json=EXCLUDED.gold_evidence_json,
			decided_at=NOW(), execution_status=EXCLUDED.execution_status, executed_at=EXCLUDED.executed_at, updated_at=NOW()
	`, body.RecommendationID, tenantID, entityKey, body.CampaignID, body.CampaignName,
		body.Hour, action, body.SuggestedMultiplier, userID, "Aplicado pela tela Keywords x hora.", string(evidence), execStatus)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "decision_record_failed: "+err.Error())
		return
	}
	if h.audit != nil {
		h.audit.LogRequest(r.Context(), r, "GOLD_KEYWORD_APPLY", "keyword_hour", body.RecommendationID, nil,
			map[string]string{"robot_status": roboStatus, "execution_status": execStatus})
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status": roboStatus, "applied": applied, "execution_status": execStatus,
		"recommendation_id": body.RecommendationID, "robot": roboBody,
	})
}

// GET /api/v1/gold/dayparting-calibration
// Calibracao de dayparting no grao KEYWORD (hierarquia keyword->campanha->global via
// shrinkage). Retorna: recomendacoes com prova (mudanca vs a curva publicada de cada
// keyword) + heatmap semana x hora (eficiencia) + resumo. Somente leitura (advisory).
func (h *Handler) GoldDaypartingCalibration(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	recRows, err := h.db.Query(ctx, `
		WITH kw_rec AS (
			SELECT DISTINCT keyword_id
			FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
			WHERE gate='OK' AND action <> 'HOLD'
		)
		SELECT c.keyword_id, COALESCE(NULLIF(c.keyword_text,''),'(sem texto)') AS keyword_text,
			c.event_hour,
			(c.published_multiplier*100)::int AS atual_pct,
			(c.recommended_multiplier*100)::int AS sugerido_pct,
			c.action, c.scope, c.baseline_scope, c.weeks_of_data,
			c.hour_roas::float8 AS roas, c.scope_avg_roas::float8 AS ref_roas,
			c.clicks::float8 AS clicks, c.reason,
			-- entranhas do blend ML x dayparting (migration 200): brain visivel
			c.kw_roas_raw::float8 AS kw_roas, c.prior_roas::float8 AS prior_roas,
			c.ml_factor::float8 AS ml_factor, c.blend_weight::float8 AS blend_weight
		FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1 c
		JOIN kw_rec USING (keyword_id)
		ORDER BY c.keyword_text, c.event_hour`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "calibration_recs_failed: "+err.Error())
		return
	}
	recs, err := pgx.CollectRows(recRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	hmRows, err := h.db.Query(ctx, `
		SELECT to_char(data_date,'IW') AS semana, event_hour AS hora,
			sum(spend)::float8 AS spend, sum(sales_7d)::float8 AS sales,
			CASE WHEN sum(spend)>0 THEN round((sum(sales_7d)/sum(spend))::numeric,2)::float8 ELSE 0 END AS roas
		FROM marketcloud_bronze.bronze_amazon_ads_hourly
		GROUP BY 1,2 HAVING sum(spend)>0 ORDER BY 1,2`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "calibration_heatmap_failed: "+err.Error())
		return
	}
	hm, err := pgx.CollectRows(hmRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	var kws, recCount int
	_ = h.db.QueryRow(ctx, `
		SELECT count(DISTINCT keyword_id),
			count(DISTINCT keyword_id) FILTER (WHERE gate='OK' AND action<>'HOLD')
		FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1`).Scan(&kws, &recCount)

	// candidatas a schedule proprio (sem ENTITY publicado, com dado suficiente)
	candRows, err := h.db.Query(ctx, `
		SELECT keyword_text, herda_de, clicks_total, horas_com_rec
		FROM marketcloud_gold.v_dayparting_schedule_candidates_v1 LIMIT 50`)
	var cands []map[string]any
	if err == nil {
		cands, _ = pgx.CollectRows(candRows, pgx.RowToMap)
	}

	// Outcome loop do blend ML (migration 202): placar de acerto da direcao do ML
	// contra o ROAS realizado, + status de maturacao do ledger (quando comeca a valer).
	var mlScore []map[string]any
	if scoreRows, e := h.db.Query(ctx, `
		SELECT ml_direction, celulas_maduras, julgaveis, acertos, pct_acerto, roas_forward_medio
		FROM marketcloud_gold.v_dayparting_ml_outcome_scoreboard`); e == nil {
		mlScore, _ = pgx.CollectRows(scoreRows, pgx.RowToMap)
	}
	var ledgerDays, ledgerRows, maduros int
	_ = h.db.QueryRow(ctx, `
		SELECT count(DISTINCT snapshot_date), count(*),
			count(*) FILTER (WHERE snapshot_date <= (SELECT max(data_date) FROM marketcloud_bronze.bronze_ams_hourly_target) - 14)
		FROM marketcloud_gold.dayparting_ml_outcome_ledger`).Scan(&ledgerDays, &ledgerRows, &maduros)

	writeJSON(w, http.StatusOK, map[string]any{
		"recommendations": recs, "heatmap": hm, "candidates": cands,
		"keywords": kws, "kw_com_rec": recCount,
		"ml_outcome": map[string]any{
			"scoreboard": mlScore, "ledger_days": ledgerDays,
			"ledger_rows": ledgerRows, "ledger_maduros": maduros,
		},
	})
}

// daypartingApplyAllowlist: os 3 pilotos de dayparting (por keyword_id). SO essas 3
// podem ter o schedule escrito pelo apply. Hardcoded de proposito (nao ampliavel por
// env sem querer).
var daypartingApplyAllowlist = map[string]string{
	"42786116647278":  "tag rastreador android",
	"63928923350381":  "abridor de vinho",
	"146896707092851": "seladora a vacuo para alimentos",
}

// POST /api/v1/gold/dayparting-calibration/apply  body {keyword_id, dry_run}
// Aplica a curva RECOMENDADA no schedule publicado da keyword piloto. Gated:
//   - allowlist: so os 3 pilotos.
//   - kill-switch DAYPARTING_APPLY_ENABLED (default OFF) — sem ele, sempre dry-run.
//
// Dry-run retorna o plano (atual->sugerido) sem escrever. Audit ANTES de escrever.
// GET /api/v1/gold/dayparting-pilot?scope=CAMPAIGN|ENTITY
// CAMPAIGN: TODAS as campanhas com dado (view) + flag (join profile por nome).
// ENTITY: keywords com profile (filtra "Sem Texto"). Ranqueado por cliques.
func (h *Handler) GoldDaypartingPilotProfiles(w http.ResponseWriter, r *http.Request) {
	scope := strings.ToUpper(strings.TrimSpace(r.URL.Query().Get("scope")))
	if scope != "ENTITY" {
		scope = "CAMPAIGN"
	}
	var q string
	if scope == "CAMPAIGN" {
		// Lista do seletor = campanhas ATIVAS (status atual ENABLED) com clique nos ultimos
		// 30 dias, fonte fresca do bronze. Nao a curva de calibracao (que exclui os ultimos
		// 7d p/ maturar atribuicao e vira historico infinito -> some campanha recente e
		// mostra pausada/arquivada). Nao toca na curva/ROAS da calibracao.
		q = `
			WITH latest_status AS (
				-- status vive no swarm_src.campaigns_daily (o campaign_status do bronze horario
				-- vem vazio). Pega o status mais recente por campanha.
				SELECT DISTINCT ON (campaign_name) campaign_name, UPPER(TRIM(campaign_status)) AS st
				FROM swarm_src.amazon_ads_campaigns_daily
				WHERE COALESCE(campaign_name,'') <> ''
				ORDER BY campaign_name, date DESC
			)
			SELECT ''::text AS id, 'CAMPAIGN'::text AS scope, h.campaign_name AS campaign_name,
				''::text AS entity_label, ''::text AS entity_id,
				COALESCE(bool_or(p.dayparting_synced), false) AS synced,
				sum(h.clicks)::int AS clicks
			FROM marketcloud_bronze.bronze_amazon_ads_hourly h
			JOIN latest_status ls ON ls.campaign_name = h.campaign_name AND ls.st = 'ENABLED'
			LEFT JOIN swarm_src.zanom_ads_bid_schedule_profiles p
				ON p.scope='CAMPAIGN' AND p.campaign_name=h.campaign_name AND p.status='PUBLISHED' AND p.is_active=true
			WHERE h.data_date >= CURRENT_DATE - 30 AND COALESCE(h.campaign_name,'') <> ''
			GROUP BY h.campaign_name
			HAVING sum(h.clicks) > 0
			ORDER BY clicks DESC NULLS LAST, h.campaign_name`
	} else {
		q = `
			SELECT p.id, 'ENTITY'::text AS scope, COALESCE(p.campaign_name,'') AS campaign_name,
				COALESCE(p.entity_label,'') AS entity_label, COALESCE(p.entity_id,'') AS entity_id,
				COALESCE(p.dayparting_synced,false) AS synced,
				COALESCE((SELECT sum(k.clicks) FROM marketcloud_gold.gold_keyword_hourly_calibration_v1 k
					WHERE k.keyword_id=p.entity_id
					  AND k.computed_at=(SELECT max(computed_at) FROM marketcloud_gold.gold_keyword_hourly_calibration_v1)),0)::int AS clicks
			FROM swarm_src.zanom_ads_bid_schedule_profiles p
			WHERE p.scope='ENTITY' AND p.status='PUBLISHED' AND p.is_active=true
			  AND COALESCE(NULLIF(p.entity_label,''),'')<>''
			ORDER BY clicks DESC NULLS LAST, p.entity_label`
	}
	rows, err := h.db.Query(r.Context(), q)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "pilot_profiles_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items), "scope": scope})
}

// POST /api/v1/gold/dayparting-pilot  {scope, profile_id, campaign_name, enabled}
// ENTITY: grava a flag por profile_id. CAMPAIGN: por campaign_name — CRIA o profile se
// nao existir (resolve campaign_id via FDW + clona o config do global). Via FDW -> pricing.
func (h *Handler) GoldDaypartingPilotToggle(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Scope        string `json:"scope"`
		ProfileID    string `json:"profile_id"`
		CampaignName string `json:"campaign_name"`
		Enabled      bool   `json:"enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	ctx := r.Context()
	scope := strings.ToUpper(strings.TrimSpace(body.Scope))
	created := false
	ref := strings.TrimSpace(body.ProfileID)
	if scope == "CAMPAIGN" {
		name := strings.TrimSpace(body.CampaignName)
		ref = name
		if name == "" {
			writeError(w, http.StatusBadRequest, "campaign_name_required")
			return
		}
		tag, err := h.db.Exec(ctx, `UPDATE swarm_src.zanom_ads_bid_schedule_profiles SET dayparting_synced=$2 WHERE scope='CAMPAIGN' AND campaign_name=$1 AND status='PUBLISHED' AND is_active=true`, name, body.Enabled)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "toggle_failed: "+err.Error())
			return
		}
		if tag.RowsAffected() == 0 && body.Enabled {
			var campaignID, adsProfileID, marketplaceID string
			_ = h.db.QueryRow(ctx, `SELECT campaign_id FROM swarm_src.amazon_ads_campaigns_daily WHERE campaign_name=$1 AND COALESCE(campaign_id,'')<>'' ORDER BY date DESC LIMIT 1`, name).Scan(&campaignID)
			_ = h.db.QueryRow(ctx, `SELECT profile_id, marketplace_id FROM swarm_src.zanom_ads_bid_schedule_profiles WHERE scope='GLOBAL' AND is_active=true LIMIT 1`).Scan(&adsProfileID, &marketplaceID)
			if campaignID == "" || adsProfileID == "" {
				writeError(w, http.StatusUnprocessableEntity, "campaign_id_or_global_profile_not_found")
				return
			}
			newID := "absp-dp-" + strconv.FormatInt(time.Now().UnixNano(), 36)
			// FDW manda NULL pras colunas nao-listadas; version/created_at/updated_at sao
			// NOT NULL (default so local) -> precisam de valor explicito.
			if _, err := h.db.Exec(ctx, `
				INSERT INTO swarm_src.zanom_ads_bid_schedule_profiles
					(id, name, scope, status, profile_id, marketplace_id, campaign_id, campaign_name, is_active, priority, version, created_at, updated_at, dayparting_synced)
				VALUES ($1, $2, 'CAMPAIGN', 'PUBLISHED', $3, $4, $5, $6, true, 40, 1, NOW(), NOW(), true)`,
				newID, "Dayparting "+name, adsProfileID, marketplaceID, campaignID, name); err != nil {
				writeError(w, http.StatusInternalServerError, "create_profile_failed: "+err.Error())
				return
			}
			created = true
		}
	} else {
		if ref == "" {
			writeError(w, http.StatusBadRequest, "profile_id_required")
			return
		}
		tag, err := h.db.Exec(ctx, `UPDATE swarm_src.zanom_ads_bid_schedule_profiles SET dayparting_synced=$2 WHERE id=$1`, ref, body.Enabled)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "toggle_failed: "+err.Error())
			return
		}
		if tag.RowsAffected() == 0 {
			writeError(w, http.StatusNotFound, "profile_not_found")
			return
		}
	}
	if h.audit != nil {
		h.audit.LogRequest(ctx, r, "DAYPARTING_PILOT", "bid_schedule_profile", ref, nil, map[string]string{"scope": scope, "enabled": strconv.FormatBool(body.Enabled), "created": strconv.FormatBool(created)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "scope": scope, "enabled": body.Enabled, "created_profile": created})
}

func (h *Handler) GoldDaypartingApply(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var body struct {
		KeywordID string `json:"keyword_id"`
		DryRun    *bool  `json:"dry_run"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "payload invalido")
		return
	}
	kwText, allowed := daypartingApplyAllowlist[body.KeywordID]
	if !allowed {
		writeError(w, http.StatusForbidden, "keyword fora da allowlist de pilotos de dayparting")
		return
	}
	killSwitch := strings.EqualFold(os.Getenv("DAYPARTING_APPLY_ENABLED"), "true")
	dryRun := true
	if body.DryRun != nil {
		dryRun = *body.DryRun
	}
	realWrite := killSwitch && !dryRun

	planRows, err := h.db.Query(ctx, `
		SELECT event_hour,
			(published_multiplier*100)::int AS atual_pct,
			(recommended_multiplier*100)::int AS sugerido_pct,
			action
		FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
		WHERE keyword_id=$1 ORDER BY event_hour`, body.KeywordID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "plan_failed: "+err.Error())
		return
	}
	plan, err := pgx.CollectRows(planRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	hoursChanged := 0
	for _, p := range plan {
		if a, _ := p["action"].(string); a == "UP" || a == "DOWN" {
			hoursChanged++
		}
	}

	var profileID string
	_ = h.db.QueryRow(ctx, `
		SELECT id FROM swarm_src.zanom_ads_bid_schedule_profiles
		WHERE status='PUBLISHED' AND scope='ENTITY' AND entity_id=$1 LIMIT 1`, body.KeywordID).Scan(&profileID)

	planJSON, _ := json.Marshal(plan)
	// BACKUP do estado atual (regras publicadas) ANTES de sobrescrever — reversivel.
	preRulesJSON := "[]"
	if profileID != "" {
		if pr, e := h.db.Query(ctx, `
			SELECT hour_start, hour_end, multiplier::float8 AS multiplier, day_of_week
			FROM swarm_src.zanom_ads_bid_schedule_rules WHERE profile_id_ref=$1 ORDER BY hour_start`, profileID); e == nil {
			if preRules, e2 := pgx.CollectRows(pr, pgx.RowToMap); e2 == nil {
				if b, e3 := json.Marshal(preRules); e3 == nil {
					preRulesJSON = string(b)
				}
			}
		}
	}
	var auditID int64
	_ = h.db.QueryRow(ctx, `
		INSERT INTO marketcloud_gold.dayparting_apply_audit
			(keyword_id, keyword_text, profile_id, dry_run, hours_changed, plan_json, pre_rules_json, actor)
		VALUES ($1,$2,$3,$4,$5,$6::jsonb,$7::jsonb,$8) RETURNING id`,
		body.KeywordID, kwText, profileID, !realWrite, hoursChanged, string(planJSON), preRulesJSON,
		middleware.TenantIDFromCtx(ctx).String()).Scan(&auditID)

	result := "DRY_RUN"
	applied := false
	if realWrite {
		if profileID == "" {
			result = "NO_PROFILE"
		} else {
			tx, txErr := h.db.Begin(ctx)
			if txErr != nil {
				result = "TX_FAILED"
			} else {
				_, e1 := tx.Exec(ctx, `DELETE FROM swarm_src.zanom_ads_bid_schedule_rules WHERE profile_id_ref=$1`, profileID)
				// agrupa horas consecutivas de mesmo multiplicador em JANELAS (preserva
				// a estrutura de programacao do dono, nao 24 regras soltas)
				_, e2 := tx.Exec(ctx, `
					INSERT INTO swarm_src.zanom_ads_bid_schedule_rules
						(id, profile_id_ref, hour_start, hour_end, multiplier, created_at, updated_at)
					SELECT gen_random_uuid()::text, $1, hs, he, mult, now(), now()
					FROM (
					  WITH c AS (SELECT event_hour hr, recommended_multiplier mult
					             FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1 WHERE keyword_id=$2),
					  isl AS (SELECT hr, mult, hr - row_number() OVER (PARTITION BY mult ORDER BY hr) AS g FROM c)
					  SELECT mult, min(hr) hs, max(hr)+1 he FROM isl GROUP BY mult, g
					) w`,
					profileID, body.KeywordID)
				// mantem PUBLISHED+is_active e bumpa version/published_at para o app
				// enxergar como recem-publicado (o automator horario aplica na Amazon).
				_, e3 := tx.Exec(ctx, `
					UPDATE swarm_src.zanom_ads_bid_schedule_profiles
					SET status='PUBLISHED', is_active=true, version=COALESCE(version,0)+1,
					    published_at=now(), updated_at=now()
					WHERE id=$1`, profileID)
				if e1 != nil || e2 != nil || e3 != nil {
					_ = tx.Rollback(ctx)
					result = "WRITE_FAILED"
				} else if cErr := tx.Commit(ctx); cErr != nil {
					result = "COMMIT_FAILED"
				} else {
					applied = true
					result = "APPLIED"
				}
			}
		}
	}
	_, _ = h.db.Exec(ctx, `UPDATE marketcloud_gold.dayparting_apply_audit SET applied=$2, result=$3 WHERE id=$1`, auditID, applied, result)

	writeJSON(w, http.StatusOK, map[string]any{
		"status": result, "applied": applied, "dry_run": !realWrite,
		"kill_switch": killSwitch, "keyword_text": kwText, "profile_id": profileID,
		"hours_changed": hoursChanged, "plan": plan,
	})
}

// GET /api/v1/gold/dayparting-metrics
// Serie diaria de metricas (ROAS/TACOS/CVR/CPC) + DoD/WoW/MoM do ultimo dia.
// Base do historico de aprendizado do dayparting. Somente leitura.
func (h *Handler) GoldDaypartingMetrics(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	campaign := r.URL.Query().Get("campaign")

	var sRows pgx.Rows
	var err error
	if campaign != "" {
		sRows, err = h.db.Query(ctx, `
			SELECT to_char(date,'YYYY-MM-DD') AS date,
				roas::float8, NULL::float8 AS tacos, cvr::float8, cpc::float8, acos::float8,
				spend::float8, NULL::float8 AS total_sales, ad_sales::float8 AS vendas
			FROM marketcloud_gold.v_dayparting_metrics_campaign_daily_v1
			WHERE campaign_name=$1 AND date > CURRENT_DATE - 60 ORDER BY date`, campaign)
	} else {
		sRows, err = h.db.Query(ctx, `
			SELECT to_char(date,'YYYY-MM-DD') AS date,
				roas::float8, tacos::float8, cvr::float8, cpc::float8, acos::float8,
				spend::float8, total_sales::float8, ad_sales::float8 AS vendas
			FROM marketcloud_gold.v_dayparting_metrics_daily_v1
			WHERE date > CURRENT_DATE - 60 ORDER BY date`)
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "metrics_failed: "+err.Error())
		return
	}
	series, err := pgx.CollectRows(sRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	// lista de campanhas (p/ o seletor), ordenada por gasto recente
	cRows, cErr := h.db.Query(ctx, `
		SELECT campaign_name, round(sum(spend))::float8 AS spend
		FROM marketcloud_gold.v_dayparting_metrics_campaign_daily_v1
		WHERE date > CURRENT_DATE - 14 GROUP BY 1 ORDER BY 2 DESC LIMIT 40`)
	var campaigns []map[string]any
	if cErr == nil {
		campaigns, _ = pgx.CollectRows(cRows, pgx.RowToMap)
	}

	writeJSON(w, http.StatusOK, map[string]any{"series": series, "campaigns": campaigns, "campaign": campaign})
}

// GET /api/v1/gold/dayparting-keyword-heatmap
// Heatmap geral: TODAS as keywords x hora, ROAS (eficiencia) + gasto (confianca),
// janela trailing 28d. Somente leitura.
func (h *Handler) GoldDaypartingKeywordHeatmap(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	// filtro por dia-da-semana. ISODOW: seg=1..dom=7.
	// dow: '' (tudo) | 'weekday' (1-5) | 'weekend' (6-7) | '1'..'7' (dia unico)
	dowFilter := ""
	switch dow := r.URL.Query().Get("dow"); dow {
	case "", "all":
		dowFilter = ""
	case "weekday":
		dowFilter = " AND EXTRACT(ISODOW FROM data_date) BETWEEN 1 AND 5"
	case "weekend":
		dowFilter = " AND EXTRACT(ISODOW FROM data_date) IN (6,7)"
	case "1", "2", "3", "4", "5", "6", "7":
		dowFilter = " AND EXTRACT(ISODOW FROM data_date) = " + dow
	default:
		dowFilter = "" // valor desconhecido = sem filtro (nunca interpola livre)
	}
	rows, err := h.db.Query(ctx, `
		WITH kw AS (
			SELECT COALESCE(NULLIF(keyword_text,''),'(sem texto)') AS keyword_text,
				event_hour,
				sum(spend)::float8 AS spend,
				COALESCE(sum(sales_7d) FILTER (WHERE clicks > 0),0)::float8 AS sales,   -- so venda-com-clique
				CASE WHEN sum(spend)>0 THEN round((COALESCE(sum(sales_7d) FILTER (WHERE clicks > 0),0)/sum(spend))::numeric,2)::float8 ELSE 0 END AS roas
			FROM marketcloud_bronze.bronze_ams_hourly_target
			WHERE data_date > CURRENT_DATE - 28`+dowFilter+`
			GROUP BY 1,2 HAVING sum(spend) > 0
		)
		SELECT keyword_text, event_hour, spend, sales, roas,
			sum(spend) OVER (PARTITION BY keyword_text) AS kw_total_spend
		FROM kw
		ORDER BY kw_total_spend DESC, keyword_text, event_hour`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "kw_heatmap_failed: "+err.Error())
		return
	}
	cells, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"cells": cells})
}

// GoldDaypartingGreening: motor DETERMINISTICO de "esverdear". Retorna o placar
// (% do gasto em celula verde, hoje vs potencial) + a lista de acoes acionaveis
// (CUT/FEED/KEEP e keywords VIGIAR/MATAR). Somente leitura: recomenda, nao gasta.
func (h *Handler) GoldDaypartingGreening(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	sbRows, err := h.db.Query(ctx, `SELECT * FROM marketcloud_gold.v_dayparting_greening_scoreboard`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "greening_scoreboard_failed: "+err.Error())
		return
	}
	scoreboard, err := pgx.CollectRows(sbRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	// acionaveis: tudo que nao e so "aguardar dado", ordenado por gasto.
	actRows, err := h.db.Query(ctx, `
		SELECT keyword_text, event_hour, spend, sales, clicks, raw_roas, shrunk_roas,
			kw_roas, kw_clicks, kw_flag, action, suggested_multiplier, reason
		FROM marketcloud_gold.v_dayparting_greening_cells
		WHERE action <> 'HOLD' OR kw_flag <> 'ok'
		ORDER BY (action='FEED') DESC, spend DESC`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "greening_cells_failed: "+err.Error())
		return
	}
	actions, err := pgx.CollectRows(actRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	var sb map[string]any
	if len(scoreboard) > 0 {
		sb = scoreboard[0]
	}
	writeJSON(w, http.StatusOK, map[string]any{"scoreboard": sb, "actions": actions})
}

// GoldDaypartingWindows: fundacao das 3 alavancas. Score DETERMINISTICO de
// estabilidade de janela (dia x daypart) + candidatas de placement (primeira
// pagina, grao campanha) + candidatas de pricing (feeder do robo de preco).
// Somente leitura.
func (h *Handler) GoldDaypartingWindows(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	sumRows, err := h.db.Query(ctx, `
		SELECT readiness, count(*)::int AS janelas, sum(clicks)::float8 AS cliques,
			round(sum(spend)::numeric,2)::float8 AS gasto
		FROM marketcloud_gold.v_dayparting_window_stability
		GROUP BY readiness ORDER BY readiness`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "window_stability_failed: "+err.Error())
		return
	}
	stability, err := pgx.CollectRows(sumRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	plcRows, err := h.db.Query(ctx, `
		SELECT campaign_name, daypart, day_bucket, clicks, spend, roas, weeks_green,
			readiness, suggested_tos_boost_pct, reason
		FROM marketcloud_gold.v_placement_window_candidates
		WHERE suggested_tos_boost_pct > 0
		ORDER BY suggested_tos_boost_pct DESC, roas DESC`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "placement_candidates_failed: "+err.Error())
		return
	}
	placement, err := pgx.CollectRows(plcRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	prcRows, err := h.db.Query(ctx, `
		SELECT keyword_text, campaign_name, daypart, day_bucket, weeks_green, clicks, roas, hypothesis
		FROM marketcloud_gold.v_pricing_window_candidates`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "pricing_candidates_failed: "+err.Error())
		return
	}
	pricing, err := pgx.CollectRows(prcRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"stability": stability, "placement": placement, "pricing": pricing,
	})
}

// GoldDaypartCurveRich: heatmap campanha x hora da FONTE RICA (bronze_amazon_ads_hourly,
// desde 31/05, ~3257 cliques). Substitui o heatmap de keyword do stream esparso como
// visual autoritativo do dayparting. Retorna tambem a curva global. Somente leitura.
func (h *Handler) GoldDaypartCurveRich(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	campRows, err := h.db.Query(ctx, `
		SELECT campaign_name, event_hour, clicks, spend::float8 AS spend,
			sales::float8 AS sales, orders::float8 AS orders, roas::float8 AS roas
		FROM marketcloud_gold.v_daypart_curve_campaign_rich
		ORDER BY campaign_name, event_hour`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "curve_campaign_failed: "+err.Error())
		return
	}
	campaign, err := pgx.CollectRows(campRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	glRows, err := h.db.Query(ctx, `
		SELECT event_hour, clicks, spend::float8 AS spend, sales::float8 AS sales,
			orders::float8 AS orders, roas::float8 AS roas, suggested_global_mult, reason
		FROM marketcloud_gold.v_daypart_curve_global_rich ORDER BY event_hour`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "curve_global_failed: "+err.Error())
		return
	}
	global, err := pgx.CollectRows(glRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"campaign": campaign, "global": global})
}
