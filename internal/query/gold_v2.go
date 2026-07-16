package query

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

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
	add("campaign_action_type = ", r.URL.Query().Get("action"))
	add("confidence = ", r.URL.Query().Get("confidence"))
	add("source_grain = ", r.URL.Query().Get("source"))

	sql := `
		SELECT keyword_hour_recommendation_id, campaign_id, campaign_name,
			ad_group_id, ad_group_name, keyword_text, match_type, event_hour,
			campaign_action_type, advisor_action, confidence, source_grain,
			sample_guard, execution_hint,
			base_bid::float8 AS base_bid,
			current_hour_multiplier::float8 AS current_hour_multiplier,
			suggested_hour_multiplier::float8 AS suggested_hour_multiplier,
			current_effective_bid::float8 AS current_effective_bid,
			suggested_effective_bid::float8 AS suggested_effective_bid,
			effective_bid_delta::float8 AS effective_bid_delta,
			effective_bid_delta_percent::float8 AS effective_bid_delta_percent,
			spend::float8 AS spend, orders::int AS orders, sales::float8 AS sales,
			roas::float8 AS roas, clicks::int AS clicks, impressions::int AS impressions,
			days_observed::int AS days_observed, window_from, window_to,
			ml_conversion_probability::float8 AS ml_conversion_probability,
			ml_expected_roas::float8 AS ml_expected_roas,
			ml_good_hour, ml_agrees,
			target_ml_click_probability::float8 AS target_ml_click_probability,
			target_ml_conversion_probability::float8 AS target_ml_conversion_probability,
			target_ml_expected_roas::float8 AS target_ml_expected_roas,
			target_ml_good_hour,
			target_ml_label_caveat,
			target_ml_computed_at,
			priority_score::float8 AS priority_score,
			target_hour_has_data,
			target_impressions::float8 AS target_impressions,
			target_clicks::float8 AS target_clicks,
			target_spend::float8 AS target_spend,
			target_orders::float8 AS target_orders,
			target_sales::float8 AS target_sales
		FROM marketcloud_gold.gold_keyword_hourly_recommendations_v3
		WHERE ` + strings.Join(where, " AND ") + `
		ORDER BY priority_score DESC, ABS(effective_bid_delta) DESC
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

// POST /api/v1/gold/review-queue/{id}/decision
// Registra a decisÃ£o humana. NÃƒO executa nada na Amazon.
// Body: { decision, decided_action?, decision_notes?, execution_status? }
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
