package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// daily_ingest.go — fecha o pipeline Bronze de ponta a ponta sem intervenção
// manual. Duas responsabilidades:
//
//  1. runDailyEnqueueLoop: 1x/dia enfileira as extrações E001..E009 com uma
//     janela deslizante de N dias (default 14) para capturar a maturação de
//     atribuição do AMC. Catch-up por relógio de parede (não timer monotônico):
//     se a máquina dormir na hora do disparo, roda ao acordar em vez de pular.
//
//  2. runIngestLoop: pega runs SUCCEEDED com resultado disponível e chama o
//     endpoint de ingest do connector (mapeando MC_ZANOM_E00X -> /ingest/e00x),
//     marcando RESULT_DOWNLOADED em seguida. Idempotente e com retry — se o
//     connector estiver fora, tenta de novo no próximo tick.
//
// Nada aqui muta campanha, bid ou budget. É só ETL Bronze.

const dailyIngestMarker = "marketcloud-daily-bronze-ingest-v1"

type dailyIngestConfig struct {
	Extracts      []string // codes MC_ZANOM_E001..E009
	LookbackDays  int      // tamanho da janela deslizante
	RunHourUTC    int      // hora (UTC) a partir da qual o lote do dia pode disparar
	TenantID      string
	StoreID       string
	AMCInstanceID string
	AdsProfileID  string
}

func loadDailyIngestConfig() dailyIngestConfig {
	cfg := dailyIngestConfig{
		Extracts: []string{
			"MC_ZANOM_E001", "MC_ZANOM_E002", "MC_ZANOM_E003",
			"MC_ZANOM_E004", "MC_ZANOM_E005", "MC_ZANOM_E006",
			"MC_ZANOM_E007", "MC_ZANOM_E008", "MC_ZANOM_E009",
			"MC_ZANOM_E013",
			// Features de contexto AMC (diarias) -> alimentam o ML horario via join.
			"MC_ZANOM_Q005", "MC_ZANOM_Q007", "MC_ZANOM_Q008",
			"MC_ZANOM_Q016", "MC_ZANOM_Q019", "MC_ZANOM_Q020",
			"MC_ZANOM_Q041", // mid-funnel (DPV/cart) -> feature ML
			"MC_ZANOM_Q042", // avaliacao retargeting SD -> alertas
		},
		LookbackDays:  14,
		RunHourUTC:    9, // 09:00 UTC = 06:00 BRT
		TenantID:      "d7ec8c23-3f86-4cd1-b4cb-2a753a74c5f9",
		StoreID:       "f1a59d8d-2966-45c1-83be-8e20c87ea1e0",
		AMCInstanceID: "77226b3f-8683-4887-9606-4afcc4113ed5",
		AdsProfileID:  "3084626225435227",
	}
	if v := strings.TrimSpace(os.Getenv("DAILY_INGEST_EXTRACTS")); v != "" {
		cfg.Extracts = splitCSV(v)
	}
	if v := envInt("DAILY_INGEST_LOOKBACK_DAYS", 0); v >= 1 && v <= 90 {
		cfg.LookbackDays = v
	}
	if v := envInt("DAILY_INGEST_RUN_HOUR_UTC", -1); v >= 0 && v <= 23 {
		cfg.RunHourUTC = v
	}
	if v := strings.TrimSpace(os.Getenv("DAILY_INGEST_TENANT_ID")); v != "" {
		cfg.TenantID = v
	}
	if v := strings.TrimSpace(os.Getenv("DAILY_INGEST_STORE_ID")); v != "" {
		cfg.StoreID = v
	}
	if v := strings.TrimSpace(os.Getenv("DAILY_INGEST_AMC_INSTANCE_ID")); v != "" {
		cfg.AMCInstanceID = v
	}
	if v := strings.TrimSpace(os.Getenv("DAILY_INGEST_ADS_PROFILE_ID")); v != "" {
		cfg.AdsProfileID = v
	}
	return cfg
}

func splitCSV(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	return out
}

func envInt(key string, def int) int {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

// runDailyEnqueueLoop: checa a cada 15 min se o lote do dia já foi enfileirado.
func (o *orchestrator) runDailyEnqueueLoop(ctx context.Context) {
	cfg := loadDailyIngestConfig()
	log.Printf("[daily-ingest] enqueue loop up: extracts=%d lookback=%dd run_hour_utc=%02d marker=%s",
		len(cfg.Extracts), cfg.LookbackDays, cfg.RunHourUTC, dailyIngestMarker)

	ticker := time.NewTicker(15 * time.Minute)
	defer ticker.Stop()
	// primeira avaliação imediata no boot (catch-up após restart/sleep)
	o.maybeEnqueueDailyBatch(ctx, cfg)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			o.maybeEnqueueDailyBatch(ctx, cfg)
		}
	}
}

func (o *orchestrator) maybeEnqueueDailyBatch(ctx context.Context, cfg dailyIngestConfig) {
	now := time.Now().UTC()
	if now.Hour() < cfg.RunHourUTC {
		return // ainda não deu a hora do lote de hoje
	}

	// Janela: [D-lookback, D-1]. period_end = ontem (dia mais recente que o AMC
	// costuma ter). A idempotency_key é ancorada em period_end (única por dia),
	// então o loop pode disparar N vezes no dia sem duplicar.
	periodEndDate := now.AddDate(0, 0, -1).Format("2006-01-02")
	periodStartDate := now.AddDate(0, 0, -cfg.LookbackDays).Format("2006-01-02")

	enqueued := 0
	for _, code := range cfg.Extracts {
		templateID, err := o.resolveActiveTemplateID(ctx, code)
		if err != nil || templateID == "" {
			log.Printf("[daily-ingest] skip %s: template não resolvido (%v)", code, err)
			continue
		}
		idempKey := fmt.Sprintf("daily-%s-%s", strings.ToLower(code), periodEndDate)
		params, _ := json.Marshal(map[string]any{
			"period_start": periodStartDate,
			"period_end":   periodEndDate,
			"source":       dailyIngestMarker,
		})

		tag, err := o.db.Exec(ctx, `
			INSERT INTO query_runs
				(tenant_id, store_id, amc_instance_id, query_template_id,
				 idempotency_key, status, parameters_json, created_at, updated_at)
			VALUES ($1,$2,$3,$4,$5,'QUEUED',$6,NOW(),NOW())
			ON CONFLICT (idempotency_key) DO NOTHING
		`, cfg.TenantID, cfg.StoreID, cfg.AMCInstanceID, templateID, idempKey, params)
		if err != nil {
			log.Printf("[daily-ingest] enqueue %s falhou: %v", code, err)
			continue
		}
		if tag.RowsAffected() > 0 {
			enqueued++
		}
	}
	if enqueued > 0 {
		log.Printf("[daily-ingest] lote enfileirado: %d novos runs janela=[%s..%s] marker=%s",
			enqueued, periodStartDate, periodEndDate, dailyIngestMarker)
	}
}

// resolveActiveTemplateID: resolve o code -> template_id ACTIVE. Quando há mais
// de um template ativo para o mesmo code (ex.: E004 duplicado), escolhe o que
// teve o run bem-sucedido mais recente.
func (o *orchestrator) resolveActiveTemplateID(ctx context.Context, code string) (string, error) {
	var id string
	err := o.db.QueryRow(ctx, `
		SELECT qt.id
		FROM query_templates qt
		LEFT JOIN LATERAL (
			SELECT MAX(finished_at) AS last_ok
			FROM query_runs qr
			WHERE qr.query_template_id = qt.id AND qr.finished_at IS NOT NULL
		) r ON TRUE
		WHERE qt.code = $1 AND qt.status = 'ACTIVE'
		ORDER BY r.last_ok DESC NULLS LAST, qt.created_at DESC
		LIMIT 1
	`, code).Scan(&id)
	return id, err
}

// ── Auto-ingest ─────────────────────────────────────────────────────────────

var ingestRouteRe = regexp.MustCompile(`^e0(0[1-9]|1[0-3])$`)

// ingestRouteForCode: MC_ZANOM_E001 -> "e001". "" se não for uma extração bronze.
func ingestRouteForCode(code string) string {
	route := strings.ToLower(strings.TrimPrefix(strings.ToUpper(code), "MC_ZANOM_"))
	switch route { // features AMC -> bronze (assist / new-to-brand / mid-funnel / alertas SD)
	case "q005", "q019", "q041", "q042":
		return route
	}
	if ingestRouteRe.MatchString(route) {
		return route
	}
	return ""
}

// runIngestLoop: pega runs SUCCEEDED prontos e ingere no bronze.
func (o *orchestrator) runIngestLoop(ctx context.Context) {
	cfg := loadDailyIngestConfig()
	log.Printf("[daily-ingest] ingest loop up marker=%s", dailyIngestMarker)
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			o.ingestSucceededRuns(ctx, cfg)
		}
	}
}

func (o *orchestrator) ingestSucceededRuns(ctx context.Context, cfg dailyIngestConfig) {
	// Chave de coordenação: bronze_ingested_at IS NULL — NÃO o status. O
	// modeling-worker consome SUCCEEDED/RESULT_DOWNLOADED e move para
	// MODELING_COMPLETED; se dependêssemos de status, ele venceria a corrida e
	// o Bronze nunca seria ingerido. Rastrear por coluna dedicada torna a
	// ingestão independente do ciclo de vida do run. Recência de 3 dias evita
	// reprocessar runs antigos (S3 expirado) indefinidamente.
	rows, err := o.db.Query(ctx, `
		SELECT qr.id, qr.external_query_execution_id, qr.amc_instance_id, qt.code
		FROM query_runs qr
		JOIN query_templates qt ON qt.id = qr.query_template_id
		WHERE qr.bronze_ingested_at IS NULL
		  AND COALESCE(qr.result_object_path,'') <> ''
		  AND qr.external_query_execution_id IS NOT NULL
		  AND (qt.code LIKE 'MC_ZANOM_E0%' OR qt.code IN ('MC_ZANOM_Q005','MC_ZANOM_Q019','MC_ZANOM_Q041','MC_ZANOM_Q042'))
		  AND qr.created_at > NOW() - INTERVAL '3 days'
		ORDER BY qr.created_at ASC
		LIMIT 20
	`)
	if err != nil {
		return
	}
	type target struct{ id, execID, amcInstance, code string }
	var targets []target
	for rows.Next() {
		var t target
		var execID *string
		if err := rows.Scan(&t.id, &execID, &t.amcInstance, &t.code); err == nil && execID != nil {
			t.execID = *execID
			targets = append(targets, t)
		}
	}
	rows.Close()

	for _, t := range targets {
		route := ingestRouteForCode(t.code)
		if route == "" {
			// não é uma extração bronze com rota (ex.: código fora de e001..e012)
			// — marca como resolvido para não reprocessar em loop
			o.db.Exec(ctx, `UPDATE query_runs SET bronze_ingested_at=NOW() WHERE id=$1`, t.id)
			continue
		}
		inserted, err := o.callIngest(ctx, route, t.execID, t.amcInstance, cfg)
		if err != nil {
			log.Printf("[daily-ingest] ingest %s (%s) falhou, retry no próximo tick: %v", t.code, route, err)
			continue // deixa bronze_ingested_at NULL para retry
		}
		o.db.Exec(ctx, `UPDATE query_runs SET bronze_ingested_at=NOW(), updated_at=NOW() WHERE id=$1`, t.id)
		log.Printf("[daily-ingest] ingerido %s route=%s rows=%d run=%s", t.code, route, inserted, t.id)
	}
}

func (o *orchestrator) callIngest(ctx context.Context, route, execID, amcInstance string, cfg dailyIngestConfig) (int64, error) {
	body, _ := json.Marshal(map[string]string{
		"tenant_id":       cfg.TenantID,
		"amc_instance_id": amcInstance,
		"ads_profile_id":  cfg.AdsProfileID,
	})
	url := fmt.Sprintf("%s/internal/amc/ingest/%s/%s", o.cfg.ConnectorURL, route, execID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(string(body)))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := o.httpClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return 0, fmt.Errorf("connector http %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	// tenta extrair contagem de linhas do JSON de resposta (best-effort)
	var out struct {
		RowsAffected int64 `json:"rows_affected"`
		Inserted     int64 `json:"inserted"`
		Rows         int64 `json:"rows"`
	}
	_ = json.Unmarshal(raw, &out)
	n := out.RowsAffected
	if n == 0 {
		n = out.Inserted
	}
	if n == 0 {
		n = out.Rows
	}
	return n, nil
}
