package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/zanom/marketcloud/internal/config"
	"github.com/zanom/marketcloud/internal/database"
)

// Query Orchestrator: polls for QUEUED runs, submits to connector, polls for RUNNING completion.
// In production, replace the polling loop with Redis Streams or RabbitMQ.

type orchestrator struct {
	db         *pgxpool.Pool
	cfg        config.Config
	httpClient *http.Client
}

func main() {
	cfg := config.Load()
	if cfg.Port == "8090" {
		cfg.Port = "8092"
	}

	ctx := context.Background()

	db, err := database.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer db.Close()

	o := &orchestrator{
		db:         db,
		cfg:        cfg,
		httpClient: &http.Client{Timeout: 30 * time.Second},
	}

	// Start background workers
	go o.runSubmitLoop(ctx)
	go o.runStatusLoop(ctx)
	go o.runDailyEnqueueLoop(ctx)     // enfileira E001..E009 1x/dia (janela deslizante)
	go o.runIngestLoop(ctx)           // auto-ingest de runs SUCCEEDED -> bronze
	go o.runSwarmSyncLoop(ctx)        // sync do estado SWARM/ZANOM -> bronze local
	go o.runAmsHourlyRefreshLoop(ctx) // reconcilia AMS -> hourly em janela movel D-14

	// HTTP for health + manual trigger
	r := chi.NewRouter()
	r.Use(chimw.Logger)
	r.Use(chimw.Recoverer)

	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"status":"ok","service":"marketcloud-query-orchestrator"}`))
	})

	// POST /internal/trigger - enqueue a specific run immediately
	r.Post("/internal/trigger/{run_id}", func(w http.ResponseWriter, r *http.Request) {
		runID := chi.URLParam(r, "run_id")
		db.Exec(r.Context(), `
			UPDATE query_runs SET status='QUEUED', updated_at=NOW() WHERE id=$1 AND status='CREATED'
		`, runID)
		w.Write([]byte(`{"queued":true}`))
	})

	addr := ":" + cfg.Port
	log.Printf("marketcloud-query-orchestrator listening on %s", addr)
	srv := &http.Server{
		Addr:         addr,
		Handler:      r,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

// runSubmitLoop: picks QUEUED runs and submits them to the connector.
func (o *orchestrator) runSubmitLoop(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			o.processQueued(ctx)
		}
	}
}

// runStatusLoop: polls SUBMITTED/RUNNING runs for completion.
func (o *orchestrator) runStatusLoop(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			o.checkRunningStatus(ctx)
		}
	}
}

func (o *orchestrator) processQueued(ctx context.Context) {
	rows, err := o.db.Query(ctx, `
		SELECT qr.id, qr.tenant_id, qr.store_id, qr.amc_instance_id,
		       qr.parameters_json, qt.sql_template, qt.code
		FROM query_runs qr
		JOIN query_templates qt ON qt.id = qr.query_template_id
		WHERE qr.status = 'QUEUED'
		ORDER BY qr.created_at ASC
		LIMIT 5
		FOR UPDATE SKIP LOCKED
	`)
	if err != nil {
		return
	}
	defer rows.Close()

	type run struct {
		ID            string
		TenantID      string
		StoreID       string
		AMCInstanceID string
		Params        json.RawMessage
		SQLTemplate   string
		TemplateCode  string
	}

	var queued []run
	for rows.Next() {
		var run run
		if err := rows.Scan(&run.ID, &run.TenantID, &run.StoreID, &run.AMCInstanceID, &run.Params, &run.SQLTemplate, &run.TemplateCode); err == nil {
			queued = append(queued, run)
		}
	}
	rows.Close()

	for _, run := range queued {
		var params map[string]any
		json.Unmarshal(run.Params, &params)

		payload, _ := json.Marshal(map[string]any{
			"query_run_id":    run.ID,
			"tenant_id":       run.TenantID,
			"store_id":        run.StoreID,
			"amc_instance_id": run.AMCInstanceID,
			"sql_template":    run.SQLTemplate,
			"template_code":   run.TemplateCode,
			"parameters":      params,
		})

		resp, err := o.httpClient.Post(
			o.cfg.ConnectorURL+"/internal/amc/submit",
			"application/json",
			bytes.NewReader(payload),
		)
		if err != nil {
			log.Printf("submit run %s failed: %v", run.ID, err)
			o.markFailed(ctx, run.ID, "CONNECTOR_UNREACHABLE", err.Error())
			continue
		}
		resp.Body.Close()

		if resp.StatusCode >= 400 {
			log.Printf("submit run %s: connector returned %d", run.ID, resp.StatusCode)
			o.markFailed(ctx, run.ID, "AMC_SUBMIT_FAILED", fmt.Sprintf("http %d", resp.StatusCode))
		}
	}
}

func (o *orchestrator) checkRunningStatus(ctx context.Context) {
	rows, err := o.db.Query(ctx, `
		SELECT id, tenant_id, amc_instance_id, external_query_execution_id
		FROM query_runs
		WHERE status IN ('SUBMITTED', 'RUNNING')
		  AND submitted_at < NOW() - INTERVAL '2 minutes'
		ORDER BY submitted_at ASC
		LIMIT 20
	`)
	if err != nil {
		return
	}
	defer rows.Close()

	type run struct {
		ID, TenantID, AMCInstanceID, ExecID string
	}
	var running []run
	for rows.Next() {
		var r run
		var execID *string
		if err := rows.Scan(&r.ID, &r.TenantID, &r.AMCInstanceID, &execID); err == nil {
			if execID != nil {
				r.ExecID = *execID
				running = append(running, r)
			}
		}
	}
	rows.Close()

	for _, run := range running {
		url := fmt.Sprintf("%s/internal/amc/status/%s?amc_instance_id=%s&tenant_id=%s",
			o.cfg.ConnectorURL, run.ExecID, run.AMCInstanceID, run.TenantID)
		resp, err := o.httpClient.Get(url)
		if err != nil {
			continue
		}
		defer resp.Body.Close()

		var statusResp struct {
			Status       string `json:"status"`
			OutputS3Path string `json:"outputS3Uri"`
			StatusReason string `json:"statusReason"`
		}
		json.NewDecoder(resp.Body).Decode(&statusResp)

		log.Printf("run %s AMC status=%s", run.ID, statusResp.Status)

		switch statusResp.Status {
		case "SUCCEEDED", "COMPLETED", "MODELING_COMPLETED":
			o.db.Exec(ctx, `
				UPDATE query_runs SET status='SUCCEEDED', finished_at=NOW(), result_object_path=$1, updated_at=NOW()
				WHERE id=$2
			`, statusResp.OutputS3Path, run.ID)
			o.db.Exec(ctx, `INSERT INTO query_run_events (query_run_id, status) VALUES ($1, 'SUCCEEDED')`, run.ID)
			log.Printf("run %s SUCCEEDED", run.ID)

		case "FAILED", "ERROR":
			reason := statusResp.StatusReason
			if reason == "" {
				reason = "AMC reported failure"
			}
			o.markFailed(ctx, run.ID, "AMC_QUERY_FAILED", reason)
			log.Printf("run %s FAILED: %s", run.ID, reason)

		case "REJECTED":
			reason := statusResp.StatusReason
			if reason == "" {
				reason = "AMC rejected query"
			}
			o.markFailed(ctx, run.ID, "AMC_QUERY_REJECTED", reason)
			log.Printf("run %s REJECTED: %s", run.ID, reason)

		case "RUNNING":
			o.db.Exec(ctx, `UPDATE query_runs SET status='RUNNING', started_at=COALESCE(started_at,NOW()), updated_at=NOW() WHERE id=$1`, run.ID)

		case "CANCELLED":
			o.db.Exec(ctx, `UPDATE query_runs SET status='CANCELLED', updated_at=NOW() WHERE id=$1`, run.ID)
		}
	}
}

func (o *orchestrator) markFailed(ctx context.Context, runID, code, msg string) {
	o.db.Exec(ctx, `
		UPDATE query_runs SET status='FAILED', error_code=$1, error_message=$2, updated_at=NOW()
		WHERE id=$3
	`, code, msg, runID)
	o.db.Exec(ctx, `INSERT INTO query_run_events (query_run_id, status, message) VALUES ($1, 'FAILED', $2)`, runID, msg)
}
