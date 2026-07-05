package query

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zanom/marketcloud/internal/audit"
	"github.com/zanom/marketcloud/internal/middleware"
)

type Handler struct {
	db    *pgxpool.Pool
	audit *audit.Logger
}

func NewHandler(db *pgxpool.Pool, auditLogger *audit.Logger) *Handler {
	return &Handler{db: db, audit: auditLogger}
}

// GET /api/v1/query-templates
func (h *Handler) ListTemplates(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())

	rows, err := h.db.Query(r.Context(), `
		SELECT id, name, code, description, query_family, query_goal,
		       parameters_schema, min_lookback_days, max_lookback_days,
		       supported_campaign_types, supported_marketplaces, version, status
		FROM query_templates
		WHERE (tenant_id IS NULL OR tenant_id = $1)
		  AND status = 'ACTIVE'
		ORDER BY query_family, name
	`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "list_failed")
		return
	}
	defer rows.Close()

	templates := []QueryTemplate{}
	for rows.Next() {
		var t QueryTemplate
		if err := rows.Scan(&t.ID, &t.Name, &t.Code, &t.Description, &t.QueryFamily, &t.QueryGoal,
			&t.ParametersSchema, &t.MinLookbackDays, &t.MaxLookbackDays,
			&t.SupportedCampaignTypes, &t.SupportedMarketplaces, &t.Version, &t.Status); err == nil {
			templates = append(templates, t)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": templates, "total": len(templates)})
}

// GET /api/v1/query-templates/{id}
func (h *Handler) GetTemplate(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	tenantID := middleware.TenantIDFromCtx(r.Context())

	var t QueryTemplate
	err := h.db.QueryRow(r.Context(), `
		SELECT id, name, code, description, query_family, query_goal, sql_template,
		       parameters_schema, min_lookback_days, max_lookback_days,
		       supported_campaign_types, supported_marketplaces, version, status
		FROM query_templates
		WHERE id = $1 AND (tenant_id IS NULL OR tenant_id = $2) AND status = 'ACTIVE'
	`, id, tenantID).Scan(
		&t.ID, &t.Name, &t.Code, &t.Description, &t.QueryFamily, &t.QueryGoal, &t.SQLTemplate,
		&t.ParametersSchema, &t.MinLookbackDays, &t.MaxLookbackDays,
		&t.SupportedCampaignTypes, &t.SupportedMarketplaces, &t.Version, &t.Status,
	)
	if err != nil {
		writeError(w, http.StatusNotFound, "QUERY_TEMPLATE_INVALID")
		return
	}
	writeJSON(w, http.StatusOK, t)
}

// POST /api/v1/query-runs
func (h *Handler) CreateRun(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	userID := middleware.UserIDFromCtx(r.Context())

	var req struct {
		StoreID             string         `json:"store_id"`
		AMCInstanceID       string         `json:"amc_instance_id"`
		AmazonProfileID     string         `json:"amazon_profile_id"`
		QueryTemplateCode   string         `json:"query_template_code"`
		RunType             string         `json:"run_type"`
		Parameters          map[string]any `json:"parameters"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if req.StoreID == "" || req.AMCInstanceID == "" || req.QueryTemplateCode == "" {
		writeError(w, http.StatusBadRequest, "store_id, amc_instance_id, query_template_code required")
		return
	}

	// Verify store belongs to tenant
	var exists bool
	h.db.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM stores WHERE id=$1 AND tenant_id=$2)`, req.StoreID, tenantID).Scan(&exists)
	if !exists {
		writeError(w, http.StatusForbidden, "STORE_ACCESS_DENIED")
		return
	}

	// Resolve template
	var tmplID uuid.UUID
	err := h.db.QueryRow(r.Context(), `
		SELECT id FROM query_templates
		WHERE code = $1 AND (tenant_id IS NULL OR tenant_id = $2) AND status = 'ACTIVE'
		ORDER BY version DESC LIMIT 1
	`, req.QueryTemplateCode, tenantID).Scan(&tmplID)
	if err != nil {
		writeError(w, http.StatusBadRequest, "QUERY_TEMPLATE_INVALID: code not found")
		return
	}

	runType := "MANUAL"
	if req.RunType != "" {
		runType = req.RunType
	}

	paramsJSON, _ := json.Marshal(req.Parameters)
	idempotencyKey := buildIdempotencyKey(tenantID.String(), req.StoreID, tmplID.String(), string(paramsJSON))

	// Check for duplicate
	var existingID uuid.UUID
	var existingStatus string
	checkErr := h.db.QueryRow(r.Context(), `
		SELECT id, status FROM query_runs WHERE idempotency_key = $1
	`, idempotencyKey).Scan(&existingID, &existingStatus)
	if checkErr == nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"query_run_id": existingID,
			"status":       existingStatus,
			"idempotent":   true,
		})
		return
	}

	var run QueryRun
	err = h.db.QueryRow(r.Context(), `
		INSERT INTO query_runs
			(tenant_id, store_id, amazon_profile_id, amc_instance_id, query_template_id,
			 run_type, parameters_json, idempotency_key, status, created_by)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'CREATED', $9)
		RETURNING id, tenant_id, store_id, amc_instance_id, query_template_id,
		          run_type, parameters_json, idempotency_key, status, created_at
	`, tenantID, req.StoreID, nullIfEmpty(req.AmazonProfileID), req.AMCInstanceID, tmplID,
		runType, paramsJSON, idempotencyKey, userID).Scan(
		&run.ID, &run.TenantID, &run.StoreID, &run.AMCInstanceID, &run.QueryTemplateID,
		&run.RunType, &run.ParametersJSON, &run.IdempotencyKey, &run.Status, &run.CreatedAt,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "create_run_failed: "+err.Error())
		return
	}

	// Insert initial status event
	h.db.Exec(r.Context(), `INSERT INTO query_run_events (query_run_id, status) VALUES ($1, 'CREATED')`, run.ID)

	h.audit.LogRequest(r.Context(), r, "QUERY_RUN_CREATED", "query_run", run.ID.String(), nil, run)
	writeJSON(w, http.StatusCreated, run)
}

// GET /api/v1/query-runs/{id}
func (h *Handler) GetRun(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var run QueryRun
	err := h.db.QueryRow(r.Context(), `
		SELECT id, tenant_id, store_id, amc_instance_id, query_template_id,
		       run_type, parameters_json, idempotency_key, status,
		       submitted_at, started_at, finished_at,
		       external_query_execution_id, result_object_path,
		       error_code, error_message, created_at, updated_at
		FROM query_runs WHERE id = $1 AND tenant_id = $2
	`, id, tenantID).Scan(
		&run.ID, &run.TenantID, &run.StoreID, &run.AMCInstanceID, &run.QueryTemplateID,
		&run.RunType, &run.ParametersJSON, &run.IdempotencyKey, &run.Status,
		&run.SubmittedAt, &run.StartedAt, &run.FinishedAt,
		&run.ExternalQueryExecutionID, &run.ResultObjectPath,
		&run.ErrorCode, &run.ErrorMessage, &run.CreatedAt, &run.UpdatedAt,
	)
	if err != nil {
		writeError(w, http.StatusNotFound, "query_run_not_found")
		return
	}
	writeJSON(w, http.StatusOK, run)
}

// GET /api/v1/query-runs  (list with filters)
func (h *Handler) ListRuns(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	q := r.URL.Query()

	storeFilter := ""
	args := []any{tenantID}
	if sid := q.Get("store_id"); sid != "" {
		args = append(args, sid)
		storeFilter = fmt.Sprintf("AND store_id = $%d", len(args))
	}
	statusFilter := ""
	if st := q.Get("status"); st != "" {
		args = append(args, st)
		statusFilter = fmt.Sprintf("AND status = $%d", len(args))
	}

	rows, err := h.db.Query(r.Context(), fmt.Sprintf(`
		SELECT id, tenant_id, store_id, amc_instance_id, query_template_id,
		       run_type, status, submitted_at, finished_at, error_code, created_at
		FROM query_runs WHERE tenant_id = $1 %s %s
		ORDER BY created_at DESC LIMIT 100
	`, storeFilter, statusFilter), args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "list_failed")
		return
	}
	defer rows.Close()

	runs := []map[string]any{}
	for rows.Next() {
		var (
			id, tenantID, storeID, amcInstanceID, templateID uuid.UUID
			runType, status                                   string
			submittedAt, finishedAt                          *time.Time
			errorCode                                        *string
			createdAt                                        time.Time
		)
		if err := rows.Scan(&id, &tenantID, &storeID, &amcInstanceID, &templateID,
			&runType, &status, &submittedAt, &finishedAt, &errorCode, &createdAt); err == nil {
			runs = append(runs, map[string]any{
				"id": id, "tenant_id": tenantID, "store_id": storeID,
				"amc_instance_id": amcInstanceID, "query_template_id": templateID,
				"run_type": runType, "status": status, "submitted_at": submittedAt,
				"finished_at": finishedAt, "error_code": errorCode, "created_at": createdAt,
			})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": runs, "total": len(runs)})
}

// GET /api/v1/insights
func (h *Handler) ListInsights(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	q := r.URL.Query()

	args := []any{tenantID}
	where := "WHERE i.tenant_id = $1"
	if sid := q.Get("store_id"); sid != "" {
		args = append(args, sid)
		where += fmt.Sprintf(" AND i.store_id = $%d", len(args))
	}
	if it := q.Get("insight_type"); it != "" {
		args = append(args, it)
		where += fmt.Sprintf(" AND i.insight_type = $%d", len(args))
	}
	if sev := q.Get("severity"); sev != "" {
		args = append(args, sev)
		where += fmt.Sprintf(" AND i.severity = $%d", len(args))
	}

	rows, err := h.db.Query(r.Context(), fmt.Sprintf(`
		SELECT id, store_id, insight_type, entity_type, entity_id, entity_name,
		       severity, confidence, score, title, summary, recommended_action,
		       period_start, period_end, created_at
		FROM insights i %s ORDER BY created_at DESC LIMIT 200
	`, where), args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "list_failed")
		return
	}
	defer rows.Close()

	insights := []map[string]any{}
	for rows.Next() {
		var (
			id, storeID                             uuid.UUID
			insightType, entityType, entityID       string
			entityName, recommendedAction           *string
			severity                                string
			confidence, score                       *float64
			title, summary                          string
			periodStart, periodEnd                  *time.Time
			createdAt                               time.Time
		)
		if err := rows.Scan(&id, &storeID, &insightType, &entityType, &entityID, &entityName,
			&severity, &confidence, &score, &title, &summary, &recommendedAction,
			&periodStart, &periodEnd, &createdAt); err == nil {
			insights = append(insights, map[string]any{
				"id": id, "store_id": storeID, "insight_type": insightType,
				"entity_type": entityType, "entity_id": entityID, "entity_name": entityName,
				"severity": severity, "confidence": confidence, "score": score,
				"title": title, "summary": summary, "recommended_action": recommendedAction,
				"period_start": periodStart, "period_end": periodEnd, "created_at": createdAt,
			})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": insights, "total": len(insights)})
}

// GET /api/v1/recommendations
func (h *Handler) ListRecommendations(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	q := r.URL.Query()

	args := []any{tenantID}
	where := "WHERE tenant_id = $1"
	if sid := q.Get("store_id"); sid != "" {
		args = append(args, sid)
		where += fmt.Sprintf(" AND store_id = $%d", len(args))
	}
	if st := q.Get("status"); st != "" {
		args = append(args, st)
		where += fmt.Sprintf(" AND status = $%d", len(args))
	}

	rows, err := h.db.Query(r.Context(), fmt.Sprintf(`
		SELECT id, store_id, target_type, target_id, target_name,
		       action_type, recommended_value, reason, confidence, status, created_at
		FROM recommendations %s ORDER BY created_at DESC LIMIT 200
	`, where), args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "list_failed")
		return
	}
	defer rows.Close()

	recs := []map[string]any{}
	for rows.Next() {
		var (
			id, storeID                               uuid.UUID
			targetType, targetID, actionType, reason  string
			targetName                                *string
			recommendedValue                          *json.RawMessage
			confidence                                float64
			status                                    string
			createdAt                                 time.Time
		)
		if err := rows.Scan(&id, &storeID, &targetType, &targetID, &targetName,
			&actionType, &recommendedValue, &reason, &confidence, &status, &createdAt); err == nil {
			recs = append(recs, map[string]any{
				"id": id, "store_id": storeID, "target_type": targetType,
				"target_id": targetID, "target_name": targetName,
				"action_type": actionType, "recommended_value": recommendedValue,
				"reason": reason, "confidence": confidence, "status": status, "created_at": createdAt,
			})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": recs, "total": len(recs)})
}

// POST /api/v1/recommendations/{id}/approve
func (h *Handler) ApproveRecommendation(w http.ResponseWriter, r *http.Request) {
	h.updateRecommendationStatus(w, r, "APPROVED")
}

// POST /api/v1/recommendations/{id}/reject
func (h *Handler) RejectRecommendation(w http.ResponseWriter, r *http.Request) {
	h.updateRecommendationStatus(w, r, "REJECTED")
}

func (h *Handler) updateRecommendationStatus(w http.ResponseWriter, r *http.Request, newStatus string) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	userID := middleware.UserIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var prev struct {
		Status string `json:"status"`
	}
	h.db.QueryRow(r.Context(), `SELECT status FROM recommendations WHERE id=$1 AND tenant_id=$2`, id, tenantID).Scan(&prev.Status)
	if prev.Status == "" {
		writeError(w, http.StatusNotFound, "recommendation_not_found")
		return
	}

	var rec map[string]any
	err := h.db.QueryRow(r.Context(), `
		UPDATE recommendations SET status=$1, reviewed_by=$2, reviewed_at=NOW(), updated_at=NOW()
		WHERE id=$3 AND tenant_id=$4
		RETURNING id, status, updated_at
	`, newStatus, userID, id, tenantID).Scan(
		func() *uuid.UUID { v := uuid.UUID{}; return &v }(),
		&newStatus, func() *time.Time { v := time.Now(); return &v }(),
	)
	_ = err

	// Use a simpler return
	h.db.QueryRow(r.Context(), `SELECT id, status, updated_at FROM recommendations WHERE id=$1`, id).Scan()
	h.audit.LogRequest(r.Context(), r, "RECOMMENDATION_"+newStatus, "recommendation", id, prev, map[string]string{"status": newStatus})
	writeJSON(w, http.StatusOK, map[string]string{"id": id, "status": newStatus})
	_ = rec
}

// GET /api/v1/external/recommendations/actions  (for SWARM/third-party)
func (h *Handler) ExternalActions(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context())
	q := r.URL.Query()

	storeID := q.Get("store_id")
	if storeID == "" {
		writeError(w, http.StatusBadRequest, "store_id required")
		return
	}

	rows, err := h.db.Query(r.Context(), `
		SELECT r.id, r.target_type, r.target_id, r.target_name,
		       r.action_type, r.recommended_value, r.reason, r.confidence, r.impact_estimate
		FROM recommendations r
		WHERE r.tenant_id = $1 AND r.store_id = $2 AND r.status = 'APPROVED'
		  AND (r.expires_at IS NULL OR r.expires_at > NOW())
		ORDER BY r.confidence DESC, r.created_at DESC
		LIMIT 100
	`, tenantID, storeID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "list_failed")
		return
	}
	defer rows.Close()

	items := []map[string]any{}
	for rows.Next() {
		var (
			id                               uuid.UUID
			targetType, targetID, actionType string
			targetName, reason               *string
			recommendedValue, impactEstimate  *json.RawMessage
			confidence                       float64
		)
		if err := rows.Scan(&id, &targetType, &targetID, &targetName,
			&actionType, &recommendedValue, &reason, &confidence, &impactEstimate); err == nil {
			items = append(items, map[string]any{
				"recommendation_id": id,
				"target_type":       targetType,
				"target_id":         targetID,
				"target_name":       targetName,
				"action_type":       actionType,
				"recommended_value": recommendedValue,
				"reason":            reason,
				"confidence":        confidence,
				"evidence":          impactEstimate,
			})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func buildIdempotencyKey(tenantID, storeID, templateID, paramsJSON string) string {
	h := sha256.New()
	h.Write([]byte(tenantID + "|" + storeID + "|" + templateID + "|" + paramsJSON))
	return fmt.Sprintf("%x", h.Sum(nil))
}

func nullIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}
