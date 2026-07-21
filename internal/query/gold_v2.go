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

// GET /api/v1/gold/review-queue?bucket=&status=&decision=&limit=
// Fila priorizada (G015) do tenant autenticado.
func (h *Handler) GoldReviewQueue(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()

	limit := 200
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 1000 {
			limit = n
		}
	}
	where := []string{"tenant_id = $1"}
	args := []any{tenantID}
	add := func(cond string, val string) {
		if val != "" {
			args = append(args, val)
			where = append(where, cond+"$"+strconv.Itoa(len(args)))
		}
	}
	add("priority_bucket = ", r.URL.Query().Get("bucket"))
	add("recommendation_status = ", r.URL.Query().Get("status"))
	add("human_decision_status = ", r.URL.Query().Get("decision"))
	add("final_action_type = ", r.URL.Query().Get("action"))
	add("swarm_state = ", r.URL.Query().Get("swarm_state"))
	// only_new=true: esconde o que o RobÃ´ ZANOM jÃ¡ fez (negativa/hora jÃ¡ reduzida)
	if r.URL.Query().Get("only_new") == "true" {
		where = append(where, "swarm_state = 'NEW'")
	}

	sql := `
		SELECT
			recommendation_id, priority_rank, priority_bucket, priority_score::float8 AS priority_score,
			entity_type, campaign_id, campaign_name, ad_product_type, ad_group_name, event_hour, customer_search_term,
			final_action_type, final_bid_multiplier::float8 AS final_bid_multiplier,
			final_confidence_score::float8 AS final_confidence_score, final_risk_level,
			agreement, action_conflict, recommendation_status,
			spend::float8 AS spend, clicks::float8 AS clicks, orders::float8 AS orders,
			sales::float8 AS sales, roas::float8 AS roas,
			campaign_status, ad_group_status, swarm_entity_status,
			swarm_state, already_negative,
			current_hour_multiplier::float8 AS current_hour_multiplier,
			campaign_avg_bid::float8 AS campaign_avg_bid,
			target_bid::float8 AS target_bid,
			swarm_roas_35d::float8 AS swarm_roas_35d,
			human_decision_status, execution_status, decided_by, decided_at
		FROM marketcloud_gold.gold_review_queue_actionable_v2
		WHERE ` + strings.Join(where, " AND ") + `
		ORDER BY priority_rank
		LIMIT ` + strconv.Itoa(limit)

	rows, err := h.db.Query(r.Context(), sql, args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "review_queue_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

// GET /api/v1/gold/action-summary â€” resumo por aÃ§Ã£o (G012) para cards.
func (h *Handler) GoldActionSummary(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	rows, err := h.db.Query(r.Context(), `
		SELECT final_action_type, final_risk_level, priority_bucket,
			recommendations_count, entities_count,
			total_spend::float8 AS total_spend, total_orders::float8 AS total_orders,
			total_sales::float8 AS total_sales, avg_roas::float8 AS avg_roas,
			avg_confidence::float8 AS avg_confidence, avg_priority_score::float8 AS avg_priority_score,
			p0_count, p1_count, p2_count, p3_count, conflict_count
		FROM marketcloud_gold.gold_action_impact_summary_v2
		WHERE tenant_id = $1
		ORDER BY recommendations_count DESC`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "action_summary_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

// GET /api/v1/gold/campaign-plans â€” plano por campanha (G013).
func (h *Handler) GoldCampaignPlans(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	rows, err := h.db.Query(r.Context(), `
		SELECT campaign_id, campaign_name, ad_product_type, campaign_plan_bucket, dominant_action,
			total_recommendations, p0_count, p1_count, high_risk_count, conflict_count,
			total_spend_at_risk::float8 AS total_spend_at_risk, total_sales::float8 AS total_sales,
			avg_roas::float8 AS avg_roas, max_priority_score::float8 AS max_priority_score
		FROM marketcloud_gold.gold_campaign_action_plan_v2
		WHERE tenant_id = $1
		ORDER BY max_priority_score DESC`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "campaign_plans_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

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
		SELECT recommendation_id, campaign_name, event_hour,
			-- ACAO e SUGERIDO vem do ALVO DO ML quando ele existe pra essa
			-- campanha x hora (mesmo cerebro do cockpit e da tela de keyword).
			-- Sem alvo do ML, cai no que a v1 calculava. Unifica as 3 telas.
			CASE WHEN t.ml_multiplier IS NULL THEN gr.action_type
			     WHEN t.ml_multiplier > gr.current_multiplier + 0.001 THEN 'BID_UP'
			     WHEN t.ml_multiplier < gr.current_multiplier - 0.001 THEN 'BID_DOWN'
			     ELSE 'KEEP_STRONG' END AS action_type,
			confidence,
			spend::float8 AS spend, orders::int AS orders, sales::float8 AS sales,
			roas::float8 AS roas, cvr::float8 AS cvr, clicks::int AS clicks,
			impressions::int AS impressions, days_observed::int AS days_observed,
			current_multiplier::float8 AS current_multiplier,
			mult_max::float8 AS mult_max, has_schedule,
			COALESCE(t.ml_multiplier, gr.suggested_multiplier)::float8 AS suggested_multiplier,
			(t.ml_multiplier IS NOT NULL) AS suggestion_from_ml,
			overlap_rule_count,
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
			overlap_mult_min::float8 AS overlap_mult_min,
			overlap_mult_max::float8 AS overlap_mult_max,
			overlap_labels, overlap_rule_details,
			priority_score::float8 AS priority_score, label_caveat,
			window_from, window_to,
			ml_conversion_probability::float8 AS ml_conversion_probability,
			ml_expected_roas::float8 AS ml_expected_roas,
			ml_good_hour, ml_agrees,
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
	) q
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

func (h *Handler) GoldDecide(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	userID := middleware.UserIDFromCtx(r.Context()).String()
	recID := chi.URLParam(r, "id")

	var body struct {
		Decision        string `json:"decision"`
		DecidedAction   string `json:"decided_action"`
		DecisionNotes   string `json:"decision_notes"`
		ExecutionStatus string `json:"execution_status"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	allowed := map[string]bool{"APPROVED": true, "REJECTED": true, "SNOOZED": true, "MODIFIED": true, "NOT_DECIDED": true}
	if !allowed[body.Decision] {
		writeError(w, http.StatusBadRequest, "invalid_decision")
		return
	}
	execStatus := body.ExecutionStatus
	if execStatus == "" {
		execStatus = "NOT_EXECUTED"
	}
	if !map[string]bool{"NOT_EXECUTED": true, "EXECUTED": true, "SKIPPED": true, "ROLLED_BACK": true}[execStatus] {
		writeError(w, http.StatusBadRequest, "invalid_execution_status")
		return
	}

	// Snapshot da recomendaÃ§Ã£o vem da prÃ³pria view (garante consistÃªncia) e
	// confina ao tenant autenticado.
	tag, err := h.db.Exec(r.Context(), `
		INSERT INTO marketcloud_recommendations.recommendation_decisions (
			recommendation_id, tenant_id, amc_instance_id, ads_profile_id,
			entity_type, entity_key, campaign_id, campaign_name, ad_product_type,
			ad_group_name, event_hour, customer_search_term,
			recommended_action, recommended_bid_multiplier, priority_score, priority_bucket,
			final_risk_level, final_confidence_score, gold_evidence_json, prediction_evidence_json, features_snapshot,
			decision, decided_action, decided_by, decision_notes, decided_at, execution_status, executed_at, updated_at)
		SELECT
			p.recommendation_id, p.tenant_id, p.amc_instance_id, p.ads_profile_id,
			p.entity_type, p.entity_key, p.campaign_id, p.campaign_name, p.ad_product_type,
			p.ad_group_name, p.event_hour, p.customer_search_term,
			p.final_action_type, p.final_bid_multiplier, p.priority_score, p.priority_bucket,
			p.final_risk_level, p.final_confidence_score, p.gold_evidence_json, p.prediction_evidence_json, p.features_snapshot,
			$3, COALESCE(NULLIF($4,''), p.final_action_type), $5, NULLIF($6,''), NOW(), $7,
			CASE WHEN $7='EXECUTED' THEN NOW() ELSE NULL END, NOW()
		FROM marketcloud_gold.gold_recommendation_priority_v2 p
		WHERE p.recommendation_id = $1 AND p.tenant_id = $2
		ON CONFLICT (recommendation_id) DO UPDATE SET
			decision = EXCLUDED.decision,
			decided_action = EXCLUDED.decided_action,
			decided_by = EXCLUDED.decided_by,
			decision_notes = EXCLUDED.decision_notes,
			decided_at = EXCLUDED.decided_at,
			execution_status = EXCLUDED.execution_status,
			executed_at = EXCLUDED.executed_at,
			updated_at = NOW()
	`, recID, tenantID, body.Decision, body.DecidedAction, userID, body.DecisionNotes, execStatus)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "decision_failed: "+err.Error())
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, http.StatusNotFound, "recommendation_not_found")
		return
	}
	if h.audit != nil {
		h.audit.LogRequest(r.Context(), r, "GOLD_DECISION_"+body.Decision, "gold_recommendation", recID, nil,
			map[string]string{"decision": body.Decision, "execution_status": execStatus})
	}
	writeJSON(w, http.StatusOK, map[string]any{"recommendation_id": recID, "decision": body.Decision, "execution_status": execStatus, "status": "ok"})
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
			c.clicks::float8 AS clicks, c.reason
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

	writeJSON(w, http.StatusOK, map[string]any{
		"recommendations": recs, "heatmap": hm, "candidates": cands,
		"keywords": kws, "kw_com_rec": recCount,
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
// Dry-run retorna o plano (atual->sugerido) sem escrever. Audit ANTES de escrever.
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
	var auditID int64
	_ = h.db.QueryRow(ctx, `
		INSERT INTO marketcloud_gold.dayparting_apply_audit
			(keyword_id, keyword_text, profile_id, dry_run, hours_changed, plan_json, actor)
		VALUES ($1,$2,$3,$4,$5,$6::jsonb,$7) RETURNING id`,
		body.KeywordID, kwText, profileID, !realWrite, hoursChanged, string(planJSON),
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
				_, e2 := tx.Exec(ctx, `
					INSERT INTO swarm_src.zanom_ads_bid_schedule_rules
						(id, profile_id_ref, hour_start, hour_end, multiplier, created_at)
					SELECT gen_random_uuid()::text, $1, event_hour, event_hour+1, recommended_multiplier, now()
					FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1 WHERE keyword_id=$2`,
					profileID, body.KeywordID)
				if e1 != nil || e2 != nil {
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
