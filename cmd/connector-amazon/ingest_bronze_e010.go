package main

import (
	"encoding/csv"
	"io"
	"log"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
)

// POST /internal/amc/ingest/e010/{execution_id}
// Downloads E010 CSV from S3 and upserts into marketcloud_bronze.bronze_amc_brand_store_daily.
// Body: { "tenant_id", "amc_instance_id", "ads_profile_id" }
//
// E010: Brand Store page views LEFT JOIN engagement events.
// page_views-driven — every page_view row enters even with no matching engagement.
// campaign_id comes from reference_id; page_title is a non-key dimension.
func (s *connectorServer) ingestE010(w http.ResponseWriter, r *http.Request) {
	executionID := chi.URLParam(r, "execution_id")

	var req struct {
		TenantID      string `json:"tenant_id"`
		AMCInstanceID string `json:"amc_instance_id"`
		AdsProfileID  string `json:"ads_profile_id"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}

	var s3Path string
	var workflowRunID *int64
	err := s.db.QueryRow(r.Context(), `
		SELECT COALESCE(result_object_path,''), NULL::BIGINT
		FROM query_runs
		WHERE external_query_execution_id = $1
	`, executionID).Scan(&s3Path, &workflowRunID)
	if err != nil || s3Path == "" {
		writeError(w, http.StatusNotFound, "RESULT_NOT_FOUND")
		return
	}

	resp, err := s.downloadS3CSV(r, s3Path)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	defer resp.Body.Close()

	csvReader := csv.NewReader(resp.Body)
	csvReader.LazyQuotes = true
	csvReader.TrimLeadingSpace = true

	headers, err := csvReader.Read()
	if err != nil {
		writeError(w, http.StatusBadGateway, "CSV_PARSE_ERROR: "+err.Error())
		return
	}
	colIdx := make(map[string]int, len(headers))
	for i, h := range headers {
		colIdx[strings.TrimSpace(h)] = i
	}

	col := func(row []string, name string) string {
		i, ok := colIdx[name]
		if !ok || i >= len(row) {
			return ""
		}
		return strings.TrimSpace(row[i])
	}

	sentinel := func(v, fallback string) string {
		if v == "" {
			return fallback
		}
		return v
	}

	inserted, skipped := 0, 0

	for {
		row, err := csvReader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			if _, ok := err.(*csv.ParseError); ok {
				log.Printf("ingest e010: csv parse error (linha ignorada): %v", err)
				continue
			}
			log.Printf("ingest e010: csv read abortado (I/O), parando: %v", err)
			break
		}

		rawDate := col(row, "store_event_date")
		if rawDate == "" {
			skipped++
			continue
		}
		storeEventDate := rawDate
		if len(storeEventDate) > 10 {
			storeEventDate = storeEventDate[:10]
		}

		storeID := sentinel(col(row, "store_id"), "NO_STORE")
		pageID := sentinel(col(row, "page_id"), "NO_PAGE")
		pageTitle := sentinel(col(row, "page_title"), "NO_PAGE_TITLE")
		ingressType := sentinel(col(row, "ingress_type"), "NO_INGRESS")
		referrerDomain := sentinel(col(row, "referrer_domain"), "NO_REFERRER")
		channel := sentinel(col(row, "channel"), "NO_CHANNEL")
		deviceType := sentinel(col(row, "device_type"), "NO_DEVICE")
		campaignID := sentinel(col(row, "campaign_id"), "NO_CAMPAIGN")
		eventSubType := sentinel(col(row, "event_sub_type"), "NO_EVENT_SUBTYPE")
		widgetType := sentinel(col(row, "widget_type"), "NO_WIDGET_TYPE")
		widgetSubType := sentinel(col(row, "widget_sub_type"), "NO_WIDGET_SUBTYPE")
		asin := sentinel(col(row, "asin"), "NO_ASIN")

		_, err = s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_brand_store_daily (
				tenant_id, amc_instance_id, ads_profile_id, workflow_run_id,
				store_event_date,
				store_id, page_id, page_title,
				ingress_type, referrer_domain, channel, device_type,
				campaign_id,
				event_sub_type, widget_type, widget_sub_type, asin,
				page_view_rows, total_dwell_time_seconds, avg_dwell_time_seconds,
				engagement_rows,
				loaded_at
			) VALUES (
				$1,$2,$3,$4,
				$5,
				$6,$7,$8,
				$9,$10,$11,$12,
				$13,
				$14,$15,$16,$17,
				$18,$19,$20,
				$21,
				NOW()
			)
			ON CONFLICT (tenant_id, amc_instance_id, ads_profile_id, store_event_date, store_id, page_id, ingress_type, referrer_domain, channel, device_type, campaign_id, event_sub_type, widget_type, widget_sub_type, asin)
			DO UPDATE SET
				page_title                 = EXCLUDED.page_title,
				page_view_rows             = EXCLUDED.page_view_rows,
				total_dwell_time_seconds   = EXCLUDED.total_dwell_time_seconds,
				avg_dwell_time_seconds     = EXCLUDED.avg_dwell_time_seconds,
				engagement_rows            = EXCLUDED.engagement_rows,
				workflow_run_id            = EXCLUDED.workflow_run_id,
				loaded_at                  = NOW()
		`,
			req.TenantID, req.AMCInstanceID, req.AdsProfileID, workflowRunID,
			storeEventDate,
			storeID, pageID, pageTitle,
			ingressType, referrerDomain, channel, deviceType,
			campaignID,
			eventSubType, widgetType, widgetSubType, asin,
			toInt64(col(row, "page_view_rows")),
			toFloat(col(row, "total_dwell_time_seconds")),
			toFloat(col(row, "avg_dwell_time_seconds")),
			toInt64(col(row, "engagement_rows")),
		)
		if err != nil {
			log.Printf("ingest e010: upsert error store=%s page=%s date=%s: %v",
				storeID, pageID, storeEventDate, err)
			skipped++
			continue
		}
		inserted++
	}

	log.Printf("ingest e010: execution=%s inserted=%d skipped=%d", executionID, inserted, skipped)
	writeJSON(w, http.StatusOK, map[string]any{
		"execution_id": executionID,
		"inserted":     inserted,
		"skipped":      skipped,
		"status":       "OK",
	})
}
