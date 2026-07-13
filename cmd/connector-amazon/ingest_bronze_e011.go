package main

import (
	"encoding/csv"
	"io"
	"log"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
)

// POST /internal/amc/ingest/e011/{execution_id}
// Downloads E011 CSV from S3 and upserts into marketcloud_bronze.bronze_amc_audience_segment_weekly.
// Body: { "tenant_id", "amc_instance_id", "ads_profile_id" }
//
// E011: DSP audience segment impressions, weekly grain.
// behavior_segment_matched is NUMERIC and part of the PK.
// spend and audience_fee arrive already converted (millicents/microcents done in SQL).
func (s *connectorServer) ingestE011(w http.ResponseWriter, r *http.Request) {
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
				log.Printf("ingest e011: csv parse error (linha ignorada): %v", err)
				continue
			}
			log.Printf("ingest e011: csv read abortado (I/O), parando: %v", err)
			break
		}

		campaignID := col(row, "campaign_id")
		campaignName := col(row, "campaign_name")
		behaviorSegmentID := col(row, "behavior_segment_id")

		if campaignID == "" || campaignName == "" || behaviorSegmentID == "" {
			skipped++
			continue
		}

		rawDate := col(row, "week_start_date")
		if rawDate == "" {
			skipped++
			continue
		}
		weekStartDate := rawDate
		if len(weekStartDate) > 10 {
			weekStartDate = weekStartDate[:10]
		}

		lineItemID := sentinel(col(row, "line_item_id"), "NO_LINE_ITEM")
		lineItemName := sentinel(col(row, "line_item_name"), "NO_LINE_ITEM")
		behaviorSegmentName := sentinel(col(row, "behavior_segment_name"), "NO_SEGMENT_NAME")
		currencyISOCode := sentinel(col(row, "currency_iso_code"), "UNKNOWN")

		segmentMatched := col(row, "behavior_segment_matched")
		if segmentMatched == "" {
			segmentMatched = "0"
		}

		_, err = s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_audience_segment_weekly (
				tenant_id, amc_instance_id, ads_profile_id, workflow_run_id,
				week_start_date,
				campaign_id, campaign_name,
				line_item_id, line_item_name,
				behavior_segment_id, behavior_segment_name, behavior_segment_matched,
				currency_iso_code,
				impression_rows, impressions,
				spend, audience_fee,
				cost_per_impression, audience_fee_per_impression,
				loaded_at
			) VALUES (
				$1,$2,$3,$4,
				$5,
				$6,$7,
				$8,$9,
				$10,$11,$12,
				$13,
				$14,$15,
				$16,$17,
				$18,$19,
				NOW()
			)
			ON CONFLICT (tenant_id, amc_instance_id, ads_profile_id, week_start_date, campaign_id, line_item_id, behavior_segment_id, behavior_segment_matched, currency_iso_code)
			DO UPDATE SET
				campaign_name               = EXCLUDED.campaign_name,
				line_item_name              = EXCLUDED.line_item_name,
				behavior_segment_name       = EXCLUDED.behavior_segment_name,
				impression_rows             = EXCLUDED.impression_rows,
				impressions                 = EXCLUDED.impressions,
				spend                       = EXCLUDED.spend,
				audience_fee                = EXCLUDED.audience_fee,
				cost_per_impression         = EXCLUDED.cost_per_impression,
				audience_fee_per_impression = EXCLUDED.audience_fee_per_impression,
				workflow_run_id             = EXCLUDED.workflow_run_id,
				loaded_at                   = NOW()
		`,
			req.TenantID, req.AMCInstanceID, req.AdsProfileID, workflowRunID,
			weekStartDate,
			campaignID, campaignName,
			lineItemID, lineItemName,
			behaviorSegmentID, behaviorSegmentName, segmentMatched,
			currencyISOCode,
			toInt64(col(row, "impression_rows")), toInt64(col(row, "impressions")),
			toFloat(col(row, "spend")), toFloat(col(row, "audience_fee")),
			toFloat(col(row, "cost_per_impression")), toFloat(col(row, "audience_fee_per_impression")),
		)
		if err != nil {
			log.Printf("ingest e011: upsert error campaign=%s segment=%s week=%s: %v",
				campaignID, behaviorSegmentID, weekStartDate, err)
			skipped++
			continue
		}
		inserted++
	}

	log.Printf("ingest e011: execution=%s inserted=%d skipped=%d", executionID, inserted, skipped)
	writeJSON(w, http.StatusOK, map[string]any{
		"execution_id": executionID,
		"inserted":     inserted,
		"skipped":      skipped,
		"status":       "OK",
	})
}
