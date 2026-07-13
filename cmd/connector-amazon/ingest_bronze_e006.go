package main

import (
	"encoding/csv"
	"io"
	"log"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
)

// POST /internal/amc/ingest/e006/{execution_id}
// Downloads E006 CSV from S3 and upserts into marketcloud_bronze.bronze_amc_traffic_attribution_hourly.
// Body: { "tenant_id", "amc_instance_id", "ads_profile_id" }
//
// E006: conversions attributed at traffic time (no spend — cross with E004 in Silver for assisted ROAS).
func (s *connectorServer) ingestE006(w http.ResponseWriter, r *http.Request) {
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
				log.Printf("ingest e006: csv parse error (linha ignorada): %v", err)
				continue
			}
			log.Printf("ingest e006: csv read abortado (I/O), parando: %v", err)
			break
		}

		campaignID := col(row, "campaign_id")
		campaignName := col(row, "campaign_name")
		adProductType := col(row, "ad_product_type")

		if campaignID == "" || campaignName == "" || adProductType == "" {
			skipped++
			continue
		}

		rawDate := col(row, "traffic_date")
		if rawDate == "" {
			skipped++
			continue
		}
		trafficDate := rawDate
		if len(trafficDate) > 10 {
			trafficDate = trafficDate[:10]
		}

		targeting := col(row, "targeting")
		if targeting == "" {
			targeting = "NO_TARGETING"
		}
		matchType := col(row, "match_type")
		if matchType == "" {
			matchType = "NO_MATCH_TYPE"
		}
		customerSearchTerm := col(row, "customer_search_term")
		if customerSearchTerm == "" {
			customerSearchTerm = "NO_SEARCH_TERM"
		}

		_, err = s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_traffic_attribution_hourly (
				tenant_id, amc_instance_id, ads_profile_id, workflow_run_id,
				traffic_date, traffic_hour,
				campaign_id, campaign_name, ad_product_type,
				targeting, match_type, customer_search_term,
				purchase_currency,
				attribution_rows,
				attributed_impressions, attributed_clicks,
				attributed_orders, attributed_sales, attributed_units_sold,
				attributed_add_to_cart, attributed_detail_page_views,
				brand_halo_orders, brand_halo_sales,
				new_to_brand_orders, new_to_brand_sales,
				purchases_clicks, purchases_views,
				product_sales_clicks, product_sales_views,
				off_amazon_sales, combined_sales,
				click_conversion_rate, view_conversion_rate, click_attribution_share,
				loaded_at
			) VALUES (
				$1,$2,$3,$4,
				$5,$6,
				$7,$8,$9,
				$10,$11,$12,
				$13,
				$14,
				$15,$16,
				$17,$18,$19,
				$20,$21,
				$22,$23,
				$24,$25,
				$26,$27,
				$28,$29,
				$30,$31,
				$32,$33,$34,
				NOW()
			)
			ON CONFLICT (tenant_id, amc_instance_id, ads_profile_id, traffic_date, traffic_hour, campaign_id, ad_product_type, targeting, match_type, customer_search_term)
			DO UPDATE SET
				campaign_name              = EXCLUDED.campaign_name,
				purchase_currency          = EXCLUDED.purchase_currency,
				attribution_rows           = EXCLUDED.attribution_rows,
				attributed_impressions     = EXCLUDED.attributed_impressions,
				attributed_clicks          = EXCLUDED.attributed_clicks,
				attributed_orders          = EXCLUDED.attributed_orders,
				attributed_sales           = EXCLUDED.attributed_sales,
				attributed_units_sold      = EXCLUDED.attributed_units_sold,
				attributed_add_to_cart     = EXCLUDED.attributed_add_to_cart,
				attributed_detail_page_views = EXCLUDED.attributed_detail_page_views,
				brand_halo_orders          = EXCLUDED.brand_halo_orders,
				brand_halo_sales           = EXCLUDED.brand_halo_sales,
				new_to_brand_orders        = EXCLUDED.new_to_brand_orders,
				new_to_brand_sales         = EXCLUDED.new_to_brand_sales,
				purchases_clicks           = EXCLUDED.purchases_clicks,
				purchases_views            = EXCLUDED.purchases_views,
				product_sales_clicks       = EXCLUDED.product_sales_clicks,
				product_sales_views        = EXCLUDED.product_sales_views,
				off_amazon_sales           = EXCLUDED.off_amazon_sales,
				combined_sales             = EXCLUDED.combined_sales,
				click_conversion_rate      = EXCLUDED.click_conversion_rate,
				view_conversion_rate       = EXCLUDED.view_conversion_rate,
				click_attribution_share    = EXCLUDED.click_attribution_share,
				workflow_run_id            = EXCLUDED.workflow_run_id,
				loaded_at                  = NOW()
		`,
			req.TenantID, req.AMCInstanceID, req.AdsProfileID, workflowRunID,
			trafficDate, toInt64(col(row, "traffic_hour")),
			campaignID, campaignName, adProductType,
			targeting, matchType, customerSearchTerm,
			col(row, "purchase_currency"),
			toInt64(col(row, "attribution_rows")),
			toInt64(col(row, "attributed_impressions")), toInt64(col(row, "attributed_clicks")),
			toFloat(col(row, "attributed_orders")), toFloat(col(row, "attributed_sales")), toFloat(col(row, "attributed_units_sold")),
			toFloat(col(row, "attributed_add_to_cart")), toFloat(col(row, "attributed_detail_page_views")),
			toFloat(col(row, "brand_halo_orders")), toFloat(col(row, "brand_halo_sales")),
			toFloat(col(row, "new_to_brand_orders")), toFloat(col(row, "new_to_brand_sales")),
			toFloat(col(row, "purchases_clicks")), toFloat(col(row, "purchases_views")),
			toFloat(col(row, "product_sales_clicks")), toFloat(col(row, "product_sales_views")),
			toFloat(col(row, "off_amazon_sales")), toFloat(col(row, "combined_sales")),
			toFloat(col(row, "click_conversion_rate")), toFloat(col(row, "view_conversion_rate")), toFloat(col(row, "click_attribution_share")),
		)
		if err != nil {
			log.Printf("ingest e006: upsert error campaign=%s date=%s hour=%s: %v", campaignID, trafficDate, col(row, "traffic_hour"), err)
			skipped++
			continue
		}
		inserted++
	}

	log.Printf("ingest e006: execution=%s inserted=%d skipped=%d", executionID, inserted, skipped)
	writeJSON(w, http.StatusOK, map[string]any{
		"execution_id": executionID,
		"inserted":     inserted,
		"skipped":      skipped,
		"status":       "OK",
	})
}
