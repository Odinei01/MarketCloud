package main

import (
	"encoding/csv"
	"io"
	"log"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
)

// POST /internal/amc/ingest/e013/{execution_id}
// Downloads E013 CSV from S3 and upserts into
// marketcloud_bronze.bronze_amc_conversions_daily_total.
// Body: { "tenant_id", "amc_instance_id", "ads_profile_id" }
//
// E013: total diário de conversões (grão só por dia + moeda). Fonte da
// verdade financeira — não sofre supressão do AMC. Skip apenas se a data
// vier vazia.
func (s *connectorServer) ingestE013(w http.ResponseWriter, r *http.Request) {
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

	inserted, skipped := 0, 0
	for {
		row, err := csvReader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			if _, ok := err.(*csv.ParseError); ok {
				log.Printf("ingest e013: csv parse error (linha ignorada): %v", err)
				continue
			}
			log.Printf("ingest e013: csv read abortado (I/O), parando: %v", err)
			break
		}

		rawDate := col(row, "data_date")
		if rawDate == "" {
			skipped++
			continue
		}
		dataDate := rawDate
		if len(dataDate) > 10 {
			dataDate = dataDate[:10]
		}
		purchaseCurrency := col(row, "purchase_currency")
		if purchaseCurrency == "" {
			purchaseCurrency = "UNKNOWN"
		}

		_, err = s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_conversions_daily_total (
				tenant_id, amc_instance_id, ads_profile_id, workflow_run_id,
				data_date, purchase_currency,
				conversion_rows, orders, sales, units_sold, add_to_cart, detail_page_views,
				brand_halo_orders, brand_halo_sales,
				new_to_brand_orders, new_to_brand_sales,
				off_amazon_sales, combined_sales,
				loaded_at
			) VALUES (
				$1,$2,$3,$4,
				$5,$6,
				$7,$8,$9,$10,$11,$12,
				$13,$14,
				$15,$16,
				$17,$18,
				NOW()
			)
			ON CONFLICT (tenant_id, amc_instance_id, ads_profile_id, data_date, purchase_currency)
			DO UPDATE SET
				conversion_rows     = EXCLUDED.conversion_rows,
				orders              = EXCLUDED.orders,
				sales               = EXCLUDED.sales,
				units_sold          = EXCLUDED.units_sold,
				add_to_cart         = EXCLUDED.add_to_cart,
				detail_page_views   = EXCLUDED.detail_page_views,
				brand_halo_orders   = EXCLUDED.brand_halo_orders,
				brand_halo_sales    = EXCLUDED.brand_halo_sales,
				new_to_brand_orders = EXCLUDED.new_to_brand_orders,
				new_to_brand_sales  = EXCLUDED.new_to_brand_sales,
				off_amazon_sales    = EXCLUDED.off_amazon_sales,
				combined_sales      = EXCLUDED.combined_sales,
				workflow_run_id     = EXCLUDED.workflow_run_id,
				loaded_at           = NOW()
		`,
			req.TenantID, req.AMCInstanceID, req.AdsProfileID, workflowRunID,
			dataDate, purchaseCurrency,
			toInt64(col(row, "conversion_rows")),
			toFloat(col(row, "orders")), toFloat(col(row, "sales")),
			toFloat(col(row, "units_sold")), toFloat(col(row, "add_to_cart")),
			toFloat(col(row, "detail_page_views")),
			toFloat(col(row, "brand_halo_orders")), toFloat(col(row, "brand_halo_sales")),
			toFloat(col(row, "new_to_brand_orders")), toFloat(col(row, "new_to_brand_sales")),
			toFloat(col(row, "off_amazon_sales")), toFloat(col(row, "combined_sales")),
		)
		if err != nil {
			log.Printf("ingest e013: upsert error date=%s: %v", dataDate, err)
			skipped++
			continue
		}
		inserted++
	}

	log.Printf("ingest e013: execution=%s inserted=%d skipped=%d", executionID, inserted, skipped)
	writeJSON(w, http.StatusOK, map[string]any{
		"execution_id": executionID,
		"inserted":     inserted,
		"skipped":      skipped,
		"status":       "OK",
	})
}
