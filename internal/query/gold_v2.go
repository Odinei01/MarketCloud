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

// gold_v2.go — endpoints da Gold Layer V2 (cockpit operacional) + loop de
// feedback. Somente LEITURA das views Gold e ESCRITA de decisão humana.
// Nenhum endpoint executa ação na Amazon.

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
	// only_new=true: esconde o que o Robô ZANOM já fez (negativa/hora já reduzida)
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

// GET /api/v1/gold/action-summary — resumo por ação (G012) para cards.
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

// GET /api/v1/gold/campaign-plans — plano por campanha (G013).
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

// POST /api/v1/gold/review-queue/{id}/decision
// Registra a decisão humana. NÃO executa nada na Amazon.
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

	// Snapshot da recomendação vem da própria view (garante consistência) e
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
