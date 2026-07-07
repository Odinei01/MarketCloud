package main

import (
	"encoding/csv"
	"io"
	"log"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
)

// POST /internal/amc/ingest/e012/{execution_id}
// Downloads E012 CSV from S3 and upserts into marketcloud_bronze.bronze_amc_retail_purchases_weekly.
// Body: { "tenant_id", "amc_instance_id", "ads_profile_id" }
//
// E012: Retail demand (non-ads-attributed) from amazon_retail_purchases.
// purchase_sales = unit_price * purchase_units_sold (computed in SQL, arrives pre-calculated).
// product_title and brand are non-key labels updated on conflict.
func (s *connectorServer) ingestE012(w http.ResponseWriter, r *http.Request) {
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
			log.Printf("ingest e012: csv read error: %v", err)
			continue
		}

		asin := col(row, "asin")
		if asin == "" {
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

		parentAsin := sentinel(col(row, "parent_asin"), "NO_PARENT_ASIN")
		purchaseCurrency := sentinel(col(row, "purchase_currency"), "UNKNOWN")
		productTitle := sentinel(col(row, "product_title"), "NO_PRODUCT_TITLE")
		brand := sentinel(col(row, "brand"), "NO_BRAND")

		_, err = s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_retail_purchases_weekly (
				tenant_id, amc_instance_id, ads_profile_id, workflow_run_id,
				week_start_date, asin, parent_asin, purchase_currency,
				product_title, brand,
				purchase_rows, units_purchased, purchase_sales,
				units_per_purchase, average_unit_price, average_purchase_value,
				loaded_at
			) VALUES (
				$1,$2,$3,$4,
				$5,$6,$7,$8,
				$9,$10,
				$11,$12,$13,
				$14,$15,$16,
				NOW()
			)
			ON CONFLICT (tenant_id, amc_instance_id, ads_profile_id, week_start_date, asin, parent_asin, purchase_currency)
			DO UPDATE SET
				product_title          = EXCLUDED.product_title,
				brand                  = EXCLUDED.brand,
				purchase_rows          = EXCLUDED.purchase_rows,
				units_purchased        = EXCLUDED.units_purchased,
				purchase_sales         = EXCLUDED.purchase_sales,
				units_per_purchase     = EXCLUDED.units_per_purchase,
				average_unit_price     = EXCLUDED.average_unit_price,
				average_purchase_value = EXCLUDED.average_purchase_value,
				workflow_run_id        = EXCLUDED.workflow_run_id,
				loaded_at              = NOW()
		`,
			req.TenantID, req.AMCInstanceID, req.AdsProfileID, workflowRunID,
			weekStartDate, asin, parentAsin, purchaseCurrency,
			productTitle, brand,
			toInt64(col(row, "purchase_rows")),
			toFloat(col(row, "units_purchased")),
			toFloat(col(row, "purchase_sales")),
			toFloat(col(row, "units_per_purchase")),
			toFloat(col(row, "average_unit_price")),
			toFloat(col(row, "average_purchase_value")),
		)
		if err != nil {
			log.Printf("ingest e012: upsert error asin=%s week=%s: %v", asin, weekStartDate, err)
			skipped++
			continue
		}
		inserted++
	}

	log.Printf("ingest e012: execution=%s inserted=%d skipped=%d", executionID, inserted, skipped)
	writeJSON(w, http.StatusOK, map[string]any{
		"execution_id": executionID,
		"inserted":     inserted,
		"skipped":      skipped,
		"status":       "OK",
	})
}
