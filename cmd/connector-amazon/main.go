package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"sort"
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
	r.Get("/internal/amc/result/{execution_id}", s.fetchResultCSV)
	r.Post("/internal/amc/ingest/e001/{execution_id}", s.ingestE001)
	r.Post("/internal/amc/ingest/e002/{execution_id}", s.ingestE002)
	r.Post("/internal/amc/ingest/e003/{execution_id}", s.ingestE003)
	r.Post("/internal/amc/ingest/e004/{execution_id}", s.ingestE004)
	r.Post("/internal/amc/ingest/e005/{execution_id}", s.ingestE005)
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

	// Compute time window: explicit period_start/period_end override lookback_days.
	// AMC requires LocalDateTime format (YYYY-MM-DDTHH:mm:ss), so date-only strings get T00:00:00 appended.
	ensureDateTime := func(s string) string {
		if len(s) == 10 { // "2026-05-31" → "2026-05-31T00:00:00"
			return s + "T00:00:00"
		}
		return s
	}
	var periodStart, periodEnd string
	if ps, ok := req.Parameters["period_start"].(string); ok && ps != "" {
		periodStart = ensureDateTime(ps)
		if pe, ok2 := req.Parameters["period_end"].(string); ok2 && pe != "" {
			periodEnd = ensureDateTime(pe)
		} else {
			periodEnd = time.Now().UTC().Format("2006-01-02T15:04:05")
		}
	} else {
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
		periodEnd = now.Format("2006-01-02T15:04:05")
		periodStart = now.AddDate(0, 0, -lookback).Format("2006-01-02T15:04:05")
	}

	// ── Step 1: Create workflow (register the SQL query) ──────────────────────
	// WorkflowId includes a run-UUID prefix + date-window suffix to guarantee a
	// brand-new AMC workflow on every run. AMC silently reuses existing workflows
	// on POST and does not update their timeWindowType; using a unique ID ensures
	// the EXPLICIT type is respected on first creation.
	baseID := strings.ToLower(strings.ReplaceAll(req.TemplateCode, "_", "-"))
	if baseID == "" {
		baseID = "mc-run"
	}
	dateSuffix := strings.ReplaceAll(periodStart[:10], "-", "") + "-" + strings.ReplaceAll(periodEnd[:10], "-", "")
	runPrefix := req.QueryRunID
	if len(runPrefix) > 8 {
		runPrefix = runPrefix[:8]
	}
	workflowID := baseID + "-" + runPrefix + "-" + dateSuffix

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

	// Diagnostic GET: log the timeWindowType AMC actually stored for this workflow.
	getWfReq, _ := amcHeaders("GET", base+"/workflows/"+workflowID, nil)
	getWfResp, getWfErr := httpClient.Do(getWfReq)
	if getWfErr == nil {
		getWfBody, _ := io.ReadAll(getWfResp.Body)
		getWfResp.Body.Close()
		log.Printf("amc GET workflow %s status=%d body=%s", workflowID, getWfResp.StatusCode, string(getWfBody))
	}

	// AMC returns 200 {} on success — workflowId is the one we provided
	s.db.Exec(r.Context(), `UPDATE query_runs SET amc_workflow_id=$1, updated_at=NOW() WHERE id=$2`,
		workflowID, req.QueryRunID)

	// ── Step 2: Execute workflow for the requested time window ────────────────

	execWorkflow := func(wfID string) (resp *http.Response, body []byte, err error) {
		ep := map[string]any{
			"workflowId":      wfID,
			"timeWindowType":  "EXPLICIT",
			"timeWindowStart": periodStart,
			"timeWindowEnd":   periodEnd,
		}
		pl, _ := json.Marshal(ep)
		req, _ := amcHeaders("POST", base+"/workflowExecutions", bytes.NewReader(pl))
		resp, err = httpClient.Do(req)
		if err != nil {
			return
		}
		body, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		log.Printf("amc execute workflow wfID=%s status=%d body=%s", wfID, resp.StatusCode, string(body))
		return
	}

	execResp, execBody, err := execWorkflow(workflowID)
	if err != nil {
		writeError(w, http.StatusBadGateway, "AMC_EXECUTE_WORKFLOW_FAILED: "+err.Error())
		return
	}

	// Fallback: workflowId was previously created as MOST_RECENT_DAY — cannot use explicit dates.
	// Create a fresh EXPLICIT workflow with "-ex" suffix and execute that instead.
	if execResp.StatusCode >= 400 && strings.Contains(string(execBody), "MOST_RECENT_DAY") {
		explicitID := workflowID + "-ex"
		log.Printf("amc: workflow %s is MOST_RECENT_DAY, creating new explicit workflow %s", workflowID, explicitID)
		exPayload, _ := json.Marshal(map[string]any{
			"workflowId":     explicitID,
			"sqlQuery":       resolvedSQL,
			"timeWindowType": "EXPLICIT",
		})
		exReq, _ := amcHeaders("POST", base+"/workflows", bytes.NewReader(exPayload))
		exWfResp, exWfErr := httpClient.Do(exReq)
		if exWfErr == nil {
			exWfBody, _ := io.ReadAll(exWfResp.Body)
			exWfResp.Body.Close()
			log.Printf("amc create explicit fallback workflow status=%d body=%s", exWfResp.StatusCode, string(exWfBody))
		}
		s.db.Exec(r.Context(), `UPDATE query_runs SET amc_workflow_id=$1, updated_at=NOW() WHERE id=$2`,
			explicitID, req.QueryRunID)
		execResp, execBody, err = execWorkflow(explicitID)
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

// GET /internal/amc/result/{execution_id}
// Downloads the CSV result from S3 using SigV4 signing (stdlib only, no AWS SDK).
// The execution_id is the AMC workflowExecutionId stored in external_query_execution_id.
func (s *connectorServer) fetchResultCSV(w http.ResponseWriter, r *http.Request) {
	executionID := chi.URLParam(r, "execution_id")

	var s3Path string
	err := s.db.QueryRow(r.Context(), `
		SELECT COALESCE(result_object_path, '')
		FROM query_runs
		WHERE external_query_execution_id = $1
	`, executionID).Scan(&s3Path)
	if err != nil || s3Path == "" {
		writeError(w, http.StatusNotFound, "RESULT_NOT_FOUND")
		return
	}

	// Parse s3://bucket/key
	path := strings.TrimPrefix(s3Path, "s3://")
	idx := strings.IndexByte(path, '/')
	if idx < 0 {
		writeError(w, http.StatusInternalServerError, "INVALID_S3_PATH")
		return
	}
	bucket := path[:idx]
	key := path[idx+1:]

	region := s.cfg.AWSRegion
	if region == "" {
		region = "us-east-1"
	}
	s3URL := fmt.Sprintf("https://%s.s3.%s.amazonaws.com/%s", bucket, region, key)

	now := time.Now().UTC()
	dateTime := now.Format("20060102T150405Z")
	date := now.Format("20060102")

	req, _ := http.NewRequestWithContext(r.Context(), "GET", s3URL, nil)

	// SigV4 signing — canonical URI must use the percent-encoded path that
	// Go's HTTP client will actually transmit (req.URL.EscapedPath()).
	payloadHash := sha256Hex("") // empty body for GET
	req.Header.Set("x-amz-date", dateTime)
	req.Header.Set("x-amz-content-sha256", payloadHash)
	req.Header.Set("host", fmt.Sprintf("%s.s3.%s.amazonaws.com", bucket, region))

	canonicalHeaders := fmt.Sprintf("host:%s.s3.%s.amazonaws.com\nx-amz-content-sha256:%s\nx-amz-date:%s\n",
		bucket, region, payloadHash, dateTime)
	signedHeaders := "host;x-amz-content-sha256;x-amz-date"

	// SigV4 canonical URI: encode everything except unreserved chars (A-Z a-z 0-9 - _ . ~)
	// and path separator /. Go's url.EscapedPath() leaves = and : unencoded (RFC 3986
	// allows them in paths), but SigV4 requires them encoded.
	canonicalRequest := strings.Join([]string{
		"GET",
		sigv4URIPath(key),
		"", // no query string
		canonicalHeaders,
		signedHeaders,
		payloadHash,
	}, "\n")

	scope := strings.Join([]string{date, region, "s3", "aws4_request"}, "/")
	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		dateTime,
		scope,
		sha256Hex(canonicalRequest),
	}, "\n")

	signingKey := hmacSHA256(
		hmacSHA256(
			hmacSHA256(
				hmacSHA256([]byte("AWS4"+s.cfg.AWSSecretAccessKey), date),
				region,
			),
			"s3",
		),
		"aws4_request",
	)
	signature := hex.EncodeToString(hmacSHA256(signingKey, stringToSign))

	req.Header.Set("Authorization", fmt.Sprintf(
		"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=%s",
		s.cfg.AWSAccessKeyID, scope, signature,
	))

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		writeError(w, http.StatusBadGateway, "S3_FETCH_FAILED: "+err.Error())
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		log.Printf("s3 fetch status=%d body=%s", resp.StatusCode, string(body))
		writeError(w, resp.StatusCode, fmt.Sprintf("S3_FETCH_FAILED: http %d", resp.StatusCode))
		return
	}

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.csv"`, executionID))
	w.WriteHeader(http.StatusOK)
	io.Copy(w, resp.Body)
}

// sigv4URIPath returns the SigV4 canonical URI for an S3 key.
// SigV4 encodes all characters except unreserved (A-Z a-z 0-9 - _ . ~) and /.
func sigv4URIPath(key string) string {
	var b strings.Builder
	b.WriteByte('/')
	for i := 0; i < len(key); i++ {
		c := key[i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
			c == '-' || c == '_' || c == '.' || c == '~' || c == '/' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func hmacSHA256(key []byte, data string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(data))
	return h.Sum(nil)
}

var _ = sort.Strings // ensure import used

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

// substituteAMCParams replaces {{param}} and ${param} placeholders in the SQL template.
//
// Two syntaxes are supported:
//   - {{param}} — value is auto-quoted for SQL (dates get 'YYYY-MM-DD', strings get 'val')
//   - ${param}  — raw substitution, no extra quoting; the template owns all SQL syntax
//
// The ${...} syntax is used for templates that embed values inside SQL literals themselves,
// e.g. TIMESTAMP '${period_start_ts}' or CAST(${min_spend} AS DOUBLE).
func substituteAMCParams(sqlTpl string, params map[string]any, periodStart, periodEnd string) string {
	// {{...}} defaults — auto-quoted where appropriate
	quoted := map[string]string{
		"period_start":          "'" + periodStart[:10] + "'",
		"period_end":            "'" + periodEnd[:10] + "'",
		"today":                 "'" + periodEnd[:10] + "'",
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

	// ${...} defaults — raw values, no quoting (template handles SQL syntax)
	// period_start_ts / period_end_ts: datetime string matching AMC TIMESTAMP literal format.
	pStartTS := strings.ReplaceAll(periodStart, "T", " ")
	if len(pStartTS) > 19 {
		pStartTS = pStartTS[:19]
	}
	pEndTS := strings.ReplaceAll(periodEnd, "T", " ")
	if len(pEndTS) > 19 {
		pEndTS = pEndTS[:19]
	}
	raw := map[string]string{
		"period_start_ts": pStartTS,
		"period_end_ts":   pEndTS,
		"min_spend":       "30.0",
		"min_spend_hour":  "5.0",
		"target_roas":     "5.0",
		"min_clicks":      "8",
		"min_impressions": "100",
		"min_orders_exact": "1",
	}

	// Override both maps with caller-supplied params
	for k, v := range params {
		if k == "lookback_days" {
			continue
		}
		switch val := v.(type) {
		case float64:
			s := fmt.Sprintf("%g", val)
			quoted[k] = s
			raw[k] = s
		case int:
			s := fmt.Sprintf("%d", val)
			quoted[k] = s
			raw[k] = s
		case string:
			if val != "" {
				quoted[k] = "'" + strings.ReplaceAll(val, "'", "''") + "'"
				raw[k] = val // raw: no extra quoting
			}
		}
	}

	result := sqlTpl
	// Apply ${...} substitutions first (raw)
	for k, v := range raw {
		result = strings.ReplaceAll(result, "${"+k+"}", v)
	}
	// Apply {{...}} substitutions (auto-quoted)
	for k, v := range quoted {
		result = strings.ReplaceAll(result, "{{"+k+"}}", v)
	}
	return result
}
