package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
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

	// Build AMC query payload
	paramsJSON, _ := json.Marshal(req.Parameters)
	queryName := fmt.Sprintf("mc_%s_%d", req.QueryRunID[:8], time.Now().Unix())

	amcPayload := map[string]any{
		"queryId":   queryName,
		"queryText": req.SQLTemplate,
		"timeWindowStart": fmt.Sprintf("%v", req.Parameters["period_start"]),
		"timeWindowEnd":   fmt.Sprintf("%v", req.Parameters["period_end"]),
	}
	_ = paramsJSON

	payloadJSON, _ := json.Marshal(amcPayload)

	amcURL := fmt.Sprintf("%s/instances/%s/queries", s.cfg.AMCAPIURL, amcExternalID)
	amcReq, _ := http.NewRequestWithContext(r.Context(), "POST", amcURL, jsonReader(payloadJSON))
	amcReq.Header.Set("Authorization", "Bearer "+accessToken)
	amcReq.Header.Set("Amazon-Advertising-API-ClientId", s.cfg.AmazonLWAClientID)
	amcReq.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(amcReq)
	if err != nil {
		writeError(w, http.StatusBadGateway, "AMC_QUERY_FAILED: "+err.Error())
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
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
		return "", fmt.Errorf("no active connection")
	}

	if time.Now().Before(expiresAt.Add(-5 * time.Minute)) {
		return accessToken, nil
	}
	return "", fmt.Errorf("token expired — needs refresh via api service")
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
