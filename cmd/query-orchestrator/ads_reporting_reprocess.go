package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// runAdsReportingReprocessLoop registra e executa as janelas oficiais que
// precisam ser reprocessadas pelo Amazon Ads Reporting API v3.
func (o *orchestrator) runAdsReportingReprocessLoop(ctx context.Context) {
	lastEnqueue := time.Now()
	o.enqueueAdsReportingReprocess(ctx)
	o.processAdsReportingReprocess(ctx)

	t := time.NewTicker(5 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if time.Since(lastEnqueue) >= 6*time.Hour {
				o.enqueueAdsReportingReprocess(ctx)
				lastEnqueue = time.Now()
			}
			o.processAdsReportingReprocess(ctx)
		}
	}
}

func (o *orchestrator) enqueueAdsReportingReprocess(ctx context.Context) {
	var affected int
	if err := o.db.QueryRow(ctx, `SELECT marketcloud_ops.enqueue_ads_reporting_reprocess_windows()`).Scan(&affected); err != nil {
		log.Printf("[ads-reporting-reprocess] enqueue failed: %v", err)
		return
	}
	log.Printf("[ads-reporting-reprocess] windows queued/updated=%d", affected)
}

func (o *orchestrator) processAdsReportingReprocess(ctx context.Context) {
	rows, err := o.db.Query(ctx, `
		SELECT id::text, status
		FROM marketcloud_ops.ads_reporting_reprocess_requests
		WHERE status IN ('WAITING_REAL_ADS_REPORT_EXECUTOR','SUBMITTED','RUNNING')
		ORDER BY
			CASE status
				WHEN 'WAITING_REAL_ADS_REPORT_EXECUTOR' THEN 0
				WHEN 'SUBMITTED' THEN 1
				ELSE 2
			END,
			data_date DESC,
			id
		LIMIT 4
	`)
	if err != nil {
		log.Printf("[ads-reporting-reprocess] load pending failed: %v", err)
		return
	}
	defer rows.Close()

	type pending struct {
		id     string
		status string
	}
	var requests []pending
	for rows.Next() {
		var p pending
		if err := rows.Scan(&p.id, &p.status); err != nil {
			log.Printf("[ads-reporting-reprocess] scan failed: %v", err)
			return
		}
		requests = append(requests, p)
	}
	for _, p := range requests {
		action := "poll"
		if p.status == "WAITING_REAL_ADS_REPORT_EXECUTOR" {
			action = "submit"
		}
		if err := o.callAdsReprocessConnector(ctx, p.id, action); err != nil {
			log.Printf("[ads-reporting-reprocess] %s request=%s failed: %v", action, p.id, err)
			continue
		}
		log.Printf("[ads-reporting-reprocess] %s request=%s ok", action, p.id)
	}
}

func (o *orchestrator) callAdsReprocessConnector(ctx context.Context, requestID, action string) error {
	url := fmt.Sprintf("%s/internal/ads/reprocess/%s/%s", strings.TrimRight(o.cfg.ConnectorURL, "/"), requestID, action)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader([]byte(`{}`)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := o.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusTooManyRequests {
		return fmt.Errorf("rate limited: %s", strings.TrimSpace(string(raw)))
	}
	if resp.StatusCode >= 400 {
		return fmt.Errorf("connector http %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err == nil {
		if st, _ := out["status"].(string); st != "" {
			log.Printf("[ads-reporting-reprocess] connector request=%s action=%s status=%s", requestID, action, st)
		}
	}
	return nil
}
