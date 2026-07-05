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
	"github.com/zanom/marketcloud/internal/awsv4"
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
func (s *connectorServer) submitAMCQuery(w http.ResponseWriter, r *http.Request) {
	var req struct {
		QueryRunID    string         `json:"query_run_id"`
		AMCInstanceID string         `json:"amc_instance_id"`
		TenantID      string         `json:"tenant_id"`
		StoreID       string         `json:"store_id"`
		SQLTemplate   string         `json:"sql_template"`
		Parameters    map[string]any `json:"parameters"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}

	// Resolve AMC instance external ID + access token
	var amcExternalID, storeID string
	s.db.QueryRow(r.Context(), `
		SELECT a.amc_instance_id, a.store_id::text FROM amc_instances a WHERE a.id = $1 AND a.tenant_id = $2
	`, req.AMCInstanceID, req.TenantID).Scan(&amcExternalID, &storeID)

	if amcExternalID == "" {
		writeError(w, http.StatusNotFound, "AMC_INSTANCE_NOT_FOUND")
		return
	}

	accessToken, err := s.getValidAccessToken(r.Context(), req.TenantID, storeID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "AMAZON_AUTH_EXPIRED")
		return
	}

	// Compute time window from lookback_days (fallback: 14 days)
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
	periodEnd := now.Format("2006-01-02")
	periodStart := now.AddDate(0, 0, -lookback).Format("2006-01-02")

	// Build AMC query execution payload
	// URL: {baseURL}/{instanceId}/queryExecutions  (not /instances/{id})
	amcPayload := map[string]any{
		"timeWindowStart": periodStart,
		"timeWindowEnd":   periodEnd,
		"queryText":       req.SQLTemplate,
	}

	payloadJSON, _ := json.Marshal(amcPayload)

	// Correct AMC endpoint: base already contains the instance path
	// cfg.AMCAPIURL = "https://advertising-api.amazon.com/amc/reporting"
	amcURL := fmt.Sprintf("%s/%s/queryExecutions", s.cfg.AMCAPIURL, amcExternalID)

	amcReq, _ := http.NewRequestWithContext(r.Context(), "POST", amcURL, bytes.NewReader(payloadJSON))
	amcReq.Header.Set("Content-Type", "application/json")
	amcReq.Header.Set("Amazon-Advertising-API-ClientId", s.cfg.AmazonLWAClientID)
	amcReq.Header.Set("Amazon-Advertising-API-Scope", "3084626225435227")

	// Use SigV4 if AWS credentials are configured; fall back to Bearer token
	awsCreds := awsv4.Credentials{
		AccessKeyID:     s.cfg.AWSAccessKeyID,
		SecretAccessKey: s.cfg.AWSSecretAccessKey,
		Region:          s.cfg.AWSRegion,
		Service:         "advertising",
	}
	if !awsCreds.IsEmpty() {
		if err := awsv4.SignRequest(amcReq, payloadJSON, awsCreds); err != nil {
			writeError(w, http.StatusInternalServerError, "SIGV4_SIGNING_FAILED: "+err.Error())
			return
		}
		log.Printf("amc submit using SigV4 (key=%s)", awsCreds.AccessKeyID[:8]+"***")
	} else {
		amcReq.Header.Set("Authorization", "Bearer "+accessToken)
		log.Printf("amc submit using Bearer token (no AWS creds configured)")
	}

	httpClient := &http.Client{Timeout: 45 * time.Second}
	resp, err := httpClient.Do(amcReq)
	if err != nil {
		writeError(w, http.StatusBadGateway, "AMC_QUERY_FAILED: "+err.Error())
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	log.Printf("amc submit status=%d body=%s", resp.StatusCode, string(body))

	if resp.StatusCode == 429 {
		writeError(w, http.StatusTooManyRequests, "AMC_RATE_LIMITED")
		return
	}
	if resp.StatusCode >= 400 {
		writeError(w, resp.StatusCode, fmt.Sprintf("AMC_QUERY_FAILED: %s", body))
		return
	}

	var amcResp struct {
		QueryExecutionID string `json:"queryExecutionId"`
	}
	json.Unmarshal(body, &amcResp)

	// Update query_run with external execution ID
	s.db.Exec(r.Context(), `
		UPDATE query_runs SET
			status = 'SUBMITTED',
			external_query_execution_id = $1,
			submitted_at = NOW(),
			updated_at = NOW()
		WHERE id = $2
	`, amcResp.QueryExecutionID, req.QueryRunID)

	s.db.Exec(r.Context(), `INSERT INTO query_run_events (query_run_id, status) VALUES ($1, 'SUBMITTED')`, req.QueryRunID)

	writeJSON(w, http.StatusOK, map[string]string{
		"query_execution_id": amcResp.QueryExecutionID,
		"status":             "SUBMITTED",
	})
}

// GET /internal/amc/status/{execution_id}
func (s *connectorServer) getQueryStatus(w http.ResponseWriter, r *http.Request) {
	executionID := chi.URLParam(r, "execution_id")
	amcInstanceID := r.URL.Query().Get("amc_instance_id")
	tenantID := r.URL.Query().Get("tenant_id")

	var amcExternalID, storeID string
	s.db.QueryRow(r.Context(), `
		SELECT amc_instance_id, store_id::text FROM amc_instances WHERE id=$1 AND tenant_id=$2
	`, amcInstanceID, tenantID).Scan(&amcExternalID, &storeID)

	accessToken, err := s.getValidAccessToken(r.Context(), tenantID, storeID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "AMAZON_AUTH_EXPIRED")
		return
	}

	amcURL := fmt.Sprintf("%s/instances/%s/queries/%s", s.cfg.AMCAPIURL, amcExternalID, executionID)
	req, _ := http.NewRequestWithContext(r.Context(), "GET", amcURL, nil)
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Amazon-Advertising-API-ClientId", s.cfg.AmazonLWAClientID)

	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode >= 400 {
		writeError(w, http.StatusBadGateway, "AMC_QUERY_FAILED")
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
