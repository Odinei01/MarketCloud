package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zanom/marketcloud/internal/config"
	"github.com/zanom/marketcloud/internal/database"
)

// Connector service: handles raw Amazon Ads / AMC API communication.
// Called by the query-orchestrator when jobs need to be submitted or results fetched.

type connectorServer struct {
	db  *pgxpool.Pool
	cfg config.Config
}

func main() {
	cfg := config.Load()
	if cfg.Port == "8090" {
		cfg.Port = "8091" // Connector default port
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	db, err := database.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer db.Close()

	s := &connectorServer{db: db, cfg: cfg}

	r := chi.NewRouter()
	r.Use(chimw.Logger)
	r.Use(chimw.Recoverer)

	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"status":"ok","service":"marketcloud-connector-amazon"}`))
	})

	// Internal endpoints called by the orchestrator
	r.Post("/internal/amc/submit", s.submitAMCQuery)
	r.Get("/internal/amc/status/{execution_id}", s.getQueryStatus)
	r.Post("/internal/amc/download", s.downloadResult)
	r.Post("/internal/amazon/token/refresh", s.refreshTokenForStore)

	addr := ":" + cfg.Port
	log.Printf("marketcloud-connector-amazon listening on %s", addr)
	srv := &http.Server{
		Addr:         addr,
		Handler:      r,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 60 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

// POST /internal/amc/submit
// Body: {query_run_id, amc_instance_id, sql_template, parameters}
//
// AMC Reporting API is a 2-step flow:
//   Step 1 — POST /workflows          → creates/saves the SQL query, returns workflowId
//   Step 2 — POST /workflowExecutions → runs the workflow for a time window, returns workflowExecutionId
func (s *connectorServer) submitAMCQuery(w http.ResponseWriter, r *http.Request) {
	var req struct {
		QueryRunID    string         `json:"query_run_id"`
		AMCInstanceID string         `json:"amc_instance_id"`
		TenantID      string         `json:"tenant_id"`
		StoreID       string         `json:"store_id"`
		SQLTemplate   string         `json:"sql_template"`
		TemplateCode  string         `json:"template_code"`
		Parameters    map[string]any `json:"parameters"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}

	// Resolve AMC instance: external ID + entity/marketplace IDs for headers
	var amcExternalID, storeID, entityID, marketplaceID string
	s.db.QueryRow(r.Context(), `
		SELECT amc_instance_id, store_id::text,
		       COALESCE(entity_id,''), COALESCE(marketplace_id,'')
		FROM amc_instances WHERE id = $1 AND tenant_id = $2
	`, req.AMCInstanceID, req.TenantID).Scan(&amcExternalID, &storeID, &entityID, &marketplaceID)

	if amcExternalID == "" {
		writeError(w, http.StatusNotFound, "AMC_INSTANCE_NOT_FOUND")
		return
	}

	accessToken, err := s.getValidAccessToken(r.Context(), req.TenantID, storeID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "AMAZON_AUTH_EXPIRED")
		return
	}

	// Helper: build request with standard AMC auth headers
	amcHeaders := func(method, url string, body *bytes.Reader) (*http.Request, error) {
		var r *http.Request
		if body != nil {
			r, _ = http.NewRequest(method, url, body)
		} else {
			r, _ = http.NewRequest(method, url, nil)
		}
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Authorization", "Bearer "+accessToken)
		r.Header.Set("Amazon-Advertising-API-ClientId", s.cfg.AmazonLWAClientID)
		if entityID != "" {
			r.Header.Set("Amazon-Advertising-API-AdvertiserId", entityID)
		}
		if marketplaceID != "" {
			r.Header.Set("Amazon-Advertising-API-MarketplaceId", marketplaceID)
		}
		return r, nil
	}

	httpClient := &http.Client{Timeout: 45 * time.Second}
	base := fmt.Sprintf("%s/%s", s.cfg.AMCAPIURL, amcExternalID)

	// Compute time window from lookback_days parameter
	lookback := 14
	if v, ok := req.Parameters["lookback_days"]; ok {
		switch n := v.(type) {
		case float64:
			lookback = int(n)
		case int:
			lookback = n
		}
	}
	now := time.Now().UTC()
	periodEnd := now.Format("2006-01-02T15:04:05")
	periodStart := now.AddDate(0, 0, -lookback).Format("2006-01-02T15:04:05")

	// ── Step 1: Create workflow (register the SQL query) ──────────────────────
	// workflowId is customer-provided; derive a stable ID from the template code
	// so the same template reuses the same workflow definition across runs.
	workflowID := strings.ToLower(strings.ReplaceAll(req.TemplateCode, "_", "-"))
	if workflowID == "" {
		workflowID = "mc-run-" + req.QueryRunID[:8]
	}

	// Substitute {{param}} placeholders before sending to AMC.
	// AMC does not support template variables — the SQL must be valid SQL.
	resolvedSQL := substituteAMCParams(req.SQLTemplate, req.Parameters, periodStart, periodEnd)

	wfPayload, _ := json.Marshal(map[string]any{
		"workflowId":     workflowID,
		"sqlQuery":       resolvedSQL,
		"timeWindowType": "EXPLICIT",
	})
	wfReq, _ := amcHeaders("POST", base+"/workflows", bytes.NewReader(wfPayload))
	wfResp, err := httpClient.Do(wfReq)
	if err != nil {
		writeError(w, http.StatusBadGateway, "AMC_CREATE_WORKFLOW_FAILED: "+err.Error())
		return
	}
	defer wfResp.Body.Close()
	wfBody, _ := io.ReadAll(wfResp.Body)
	log.Printf("amc create workflow status=%d body=%s", wfResp.StatusCode, string(wfBody))

	if wfResp.StatusCode == 429 {
		writeError(w, http.StatusTooManyRequests, "AMC_RATE_LIMITED")
		return
	}
	if wfResp.StatusCode >= 400 {
		if !strings.Contains(string(wfBody), "already exists") {
			writeError(w, wfResp.StatusCode, fmt.Sprintf("AMC_CREATE_WORKFLOW_FAILED: %s", wfBody))
			return
		}
		// Workflow exists — update it via PUT to ensure correct timeWindowType
		log.Printf("amc workflow %s already exists, updating via PUT", workflowID)
		putReq, _ := amcHeaders("PUT",
			fmt.Sprintf("%s/workflows/%s", base, workflowID),
			bytes.NewReader(wfPayload))
		putResp, putErr := httpClient.Do(putReq)
		if putErr == nil {
			putBody, _ := io.ReadAll(putResp.Body)
			putResp.Body.Close()
			log.Printf("amc update workflow status=%d body=%s", putResp.StatusCode, string(putBody))
		}
	}

	// AMC returns 200 {} on success — workflowId is the one we provided
	s.db.Exec(r.Context(), `UPDATE query_runs SET amc_workflow_id=$1, updated_at=NOW() WHERE id=$2`,
		workflowID, req.QueryRunID)

	// ── Step 2: Execute workflow for the requested time window ────────────────

	// First try with explicit time window; if the workflow was created as MOST_RECENT_DAY,
	// AMC rejects explicit dates — in that case retry without dates.
	doExec := func(withDates bool) (resp *http.Response, body []byte, err error) {
		ep := map[string]any{"workflowId": workflowID}
		if withDates {
			ep["timeWindowStart"] = periodStart
			ep["timeWindowEnd"] = periodEnd
		}
		pl, _ := json.Marshal(ep)
		req, _ := amcHeaders("POST", base+"/workflowExecutions", bytes.NewReader(pl))
		resp, err = httpClient.Do(req)
		if err != nil {
			return
		}
		body, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		log.Printf("amc execute workflow withDates=%v status=%d body=%s", withDates, resp.StatusCode, string(body))
		return
	}

	execResp, execBody, err := doExec(true)
	if err != nil {
		writeError(w, http.StatusBadGateway, "AMC_EXECUTE_WORKFLOW_FAILED: "+err.Error())
		return
	}

	// Fallback: MOST_RECENT_DAY workflows cannot have explicit dates
	if execResp.StatusCode >= 400 && strings.Contains(string(execBody), "MOST_RECENT_DAY") {
		execResp, execBody, err = doExec(false)
		if err != nil {
			writeError(w, http.StatusBadGateway, "AMC_EXECUTE_WORKFLOW_FAILED: "+err.Error())
			return
		}
	}

	if execResp.StatusCode == 429 {
		writeError(w, http.StatusTooManyRequests, "AMC_RATE_LIMITED")
		return
	}
	if execResp.StatusCode >= 400 {
		writeError(w, execResp.StatusCode, fmt.Sprintf("AMC_EXECUTE_WORKFLOW_FAILED: %s", execBody))
		return
	}

	var execResult struct {
		WorkflowExecutionID string `json:"workflowExecutionId"`
	}
	json.Unmarshal(execBody, &execResult)

	s.db.Exec(r.Context(), `
		UPDATE query_runs SET
			status = 'SUBMITTED',
			external_query_execution_id = $1,
			submitted_at = NOW(),
			updated_at = NOW()
		WHERE id = $2
	`, execResult.WorkflowExecutionID, req.QueryRunID)
	s.db.Exec(r.Context(), `INSERT INTO query_run_events (query_run_id, status) VALUES ($1, 'SUBMITTED')`, req.QueryRunID)

	writeJSON(w, http.StatusOK, map[string]string{
		"workflow_id":           workflowID,
		"workflow_execution_id": execResult.WorkflowExecutionID,
		"status":                "SUBMITTED",
	})
}

// GET /internal/amc/status/{execution_id}
func (s *connectorServer) getQueryStatus(w http.ResponseWriter, r *http.Request) {
	executionID := chi.URLParam(r, "execution_id")
	amcInstanceID := r.URL.Query().Get("amc_instance_id")
	tenantID := r.URL.Query().Get("tenant_id")

	var amcExternalID, storeID, entityID, marketplaceID string
	s.db.QueryRow(r.Context(), `
		SELECT amc_instance_id, store_id::text,
		       COALESCE(entity_id,''), COALESCE(marketplace_id,'')
		FROM amc_instances WHERE id=$1 AND tenant_id=$2
	`, amcInstanceID, tenantID).Scan(&amcExternalID, &storeID, &entityID, &marketplaceID)

	accessToken, err := s.getValidAccessToken(r.Context(), tenantID, storeID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "AMAZON_AUTH_EXPIRED")
		return
	}

	amcURL := fmt.Sprintf("%s/%s/workflowExecutions/%s", s.cfg.AMCAPIURL, amcExternalID, executionID)
	statusReq, _ := http.NewRequestWithContext(r.Context(), "GET", amcURL, nil)
	statusReq.Header.Set("Authorization", "Bearer "+accessToken)
	statusReq.Header.Set("Amazon-Advertising-API-ClientId", s.cfg.AmazonLWAClientID)
	if entityID != "" {
		statusReq.Header.Set("Amazon-Advertising-API-AdvertiserId", entityID)
	}
	if marketplaceID != "" {
		statusReq.Header.Set("Amazon-Advertising-API-MarketplaceId", marketplaceID)
	}

	resp, err := http.DefaultClient.Do(statusReq)
	if err != nil || resp.StatusCode >= 400 {
		writeError(w, http.StatusBadGateway, "AMC_STATUS_FAILED")
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

// POST /internal/amc/download
func (s *connectorServer) downloadResult(w http.ResponseWriter, r *http.Request) {
	var req struct {
		QueryRunID       string `json:"query_run_id"`
		AMCInstanceID    string `json:"amc_instance_id"`
		TenantID         string `json:"tenant_id"`
		ExecutionID      string `json:"execution_id"`
		ResultS3Path     string `json:"result_s3_path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}

	// Mark run as result_downloaded
	s.db.Exec(r.Context(), `
		UPDATE query_runs SET status='RESULT_DOWNLOADED', result_object_path=$1, finished_at=NOW(), updated_at=NOW()
		WHERE id=$2
	`, req.ResultS3Path, req.QueryRunID)
	s.db.Exec(r.Context(), `INSERT INTO query_run_events (query_run_id, status) VALUES ($1, 'RESULT_DOWNLOADED')`, req.QueryRunID)

	writeJSON(w, http.StatusOK, map[string]string{"status": "RESULT_DOWNLOADED"})
}

// POST /internal/amazon/token/refresh
func (s *connectorServer) refreshTokenForStore(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TenantID string `json:"tenant_id"`
		StoreID  string `json:"store_id"`
	}
	json.NewDecoder(r.Body).Decode(&req)

	token, err := s.getValidAccessToken(r.Context(), req.TenantID, req.StoreID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "AMAZON_AUTH_EXPIRED")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"access_token": token})
}

func (s *connectorServer) getValidAccessToken(ctx context.Context, tenantID, storeID string) (string, error) {
	var accessToken, refreshToken string
	var expiresAt time.Time
	err := s.db.QueryRow(ctx, `
		SELECT access_token, refresh_token, token_expires_at
		FROM amazon_oauth_connections WHERE tenant_id=$1 AND store_id=$2 AND status='ACTIVE'
	`, tenantID, storeID).Scan(&accessToken, &refreshToken, &expiresAt)
	if err != nil {
		return "", fmt.Errorf("no active connection for tenant=%s store=%s", tenantID, storeID)
	}

	if time.Now().Before(expiresAt.Add(-5 * time.Minute)) {
		return accessToken, nil
	}

	// Token expired — refresh via LWA
	newToken, newExpiry, err := s.refreshLWAToken(ctx, refreshToken)
	if err != nil {
		return "", fmt.Errorf("lwa refresh failed: %w", err)
	}

	// Persist refreshed token
	s.db.Exec(ctx, `
		UPDATE amazon_oauth_connections
		SET access_token=$1, token_expires_at=$2, updated_at=NOW()
		WHERE tenant_id=$3 AND store_id=$4
	`, newToken, newExpiry, tenantID, storeID)

	return newToken, nil
}

func (s *connectorServer) refreshLWAToken(ctx context.Context, refreshToken string) (string, time.Time, error) {
	tokenURL := s.cfg.AmazonLWATokenURL
	if tokenURL == "" {
		tokenURL = "https://api.amazon.com/auth/o2/token"
	}

	form := url.Values{}
	form.Set("grant_type", "refresh_token")
	form.Set("refresh_token", refreshToken)
	form.Set("client_id", s.cfg.AmazonLWAClientID)
	form.Set("client_secret", s.cfg.AmazonLWAClientSecret)

	req, _ := http.NewRequestWithContext(ctx, "POST", tokenURL, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", time.Time{}, err
	}
	defer resp.Body.Close()

	var body struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Error       string `json:"error"`
	}
	json.NewDecoder(resp.Body).Decode(&body)

	if body.Error != "" || body.AccessToken == "" {
		return "", time.Time{}, fmt.Errorf("lwa error: %s (status %d)", body.Error, resp.StatusCode)
	}

	expiry := time.Now().Add(time.Duration(body.ExpiresIn) * time.Second)
	log.Printf("lwa token refreshed, expires in %ds", body.ExpiresIn)
	return body.AccessToken, expiry, nil
}

func jsonReader(b []byte) io.Reader {
	return jsonBody{data: b, pos: 0}
}

type jsonBody struct {
	data []byte
	pos  int
}

func (j jsonBody) Read(p []byte) (n int, err error) {
	if j.pos >= len(j.data) {
		return 0, io.EOF
	}
	n = copy(p, j.data[j.pos:])
	j.pos += n
	return n, nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

var _ = uuid.UUID{} // ensure import used

// substituteAMCParams replaces {{param}} placeholders in the SQL template
// with actual values. AMC does not support template variables — the SQL must
// be valid SQL before being submitted.
//
// Period dates use date-only format for SQL WHERE clauses (AMC accepts DATE literals).
// Scalar params (spend, roas, clicks) use their numeric representation.
// SQL-fragment params (campaign_filter, asin_filter) default to empty string.
func substituteAMCParams(sqlTpl string, params map[string]any, periodStart, periodEnd string) string {
	// Date in SQL-friendly format (strip the time component for WHERE clauses)
	pStart := "'" + periodStart[:10] + "'"
	pEnd := "'" + periodEnd[:10] + "'"

	defaults := map[string]string{
		"period_start":          pStart,
		"period_end":            pEnd,
		"today":                 pEnd,
		"min_spend":             "30.0",
		"min_spend_hour":        "5.0",
		"target_roas":           "5.0",
		"min_clicks":            "8",
		"min_orders_exact":      "1",
		"assist_rate_threshold": "0.30",
		"product_group_label":   "'TODOS'",
		"asin_filter_label":     "'TODOS'",
		"campaign_filter":       "",
		"asin_filter":           "",
		"product_filter":        "1=1",
		"zanom_asins":           "'B0H2NL3S6T'",
		"zanom_parent_asins":    "'B0H2NL3S6T'",
		"source_product_group":  "'LOCALIZADOR'",
		"target_product_group":  "'TODOS'",
		"store_id":              "'zanom-brasil'",
	}

	// Override defaults with caller-supplied params
	for k, v := range params {
		if k == "lookback_days" {
			continue // already consumed to compute period_start/end
		}
		switch val := v.(type) {
		case float64:
			defaults[k] = fmt.Sprintf("%g", val)
		case int:
			defaults[k] = fmt.Sprintf("%d", val)
		case string:
			if val != "" {
				defaults[k] = "'" + strings.ReplaceAll(val, "'", "''") + "'"
			}
		}
	}

	result := sqlTpl
	for k, v := range defaults {
		result = strings.ReplaceAll(result, "{{"+k+"}}", v)
	}

	// Best-effort AMC SQL dialect fixes:
	// SAFE_DIVIDE(a, b) → (CAST(a AS DOUBLE) / NULLIF(b, 0.0)) is not trivially
	// replaceable with regex due to nested parens, so we leave it as-is.
	// Queries using SAFE_DIVIDE will fail in AMC if AMC doesn't support it —
	// AMC errors will surface in query_runs.error_message after polling.

	return result
}
