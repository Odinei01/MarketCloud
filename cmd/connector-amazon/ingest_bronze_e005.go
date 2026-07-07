package main

import (
	"encoding/csv"
	"io"
	"log"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
)

// POST /internal/amc/ingest/e005/{execution_id}
// Downloads E005 CSV from S3 and upserts into marketcloud_bronze.bronze_amc_product_asin_daily.
// Body: { "tenant_id", "amc_instance_id", "ads_profile_id" }
//
// E005 uses UNION ALL of ADVERTISED_ASIN (traffic) and CONVERTED_ASIN (conversions).
// No ctr/cpc/roas columns — raw metrics only.
func (s *connectorServer) ingestE005(w http.ResponseWriter, r *http.Request) {
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
			log.Printf("ingest e005: csv read error: %v", err)
			continue
		}

		campaignID := col(row, "campaign_id")
		campaignName := col(row, "campaign_name")
		adProductType := col(row, "ad_product_type")
		productAsin := col(row, "product_asin")
		productRole := col(row, "product_role")

		if campaignID == "" || campaignName == "" || adProductType == "" || productAsin == "" || productRole == "" {
			skipped++
			continue
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

		adGroupName := col(row, "ad_group_name")
		adGroupKey := adGroupName
		if adGroupKey == "" {
			adGroupKey = "NO_AD_GROUP"
		}

		_, err = s.db.Exec(r.Context(), `
			INSERT INTO marketcloud_bronze.bronze_amc_product_asin_daily (
				tenant_id, amc_instance_id, ads_profile_id, workflow_run_id,
				data_date, product_role, campaign_id, campaign_name, ad_product_type,
				ad_group_name, ad_group_key, targeting, match_type, customer_search_term,
				product_asin,
				currency_iso_code, purchase_currency,
				portfolio_id, portfolio_name,
				activity_rows,
				impressions, clicks, spend, viewable_impressions, five_sec_views,
				orders, sales, units_sold, add_to_cart, detail_page_views,
				brand_halo_orders, brand_halo_sales,
				new_to_brand_orders, new_to_brand_sales,
				purchases_clicks, purchases_views,
				product_sales_clicks, product_sales_views,
				off_amazon_sales, combined_sales,
				loaded_at
			) VALUES (
				$1,$2,$3,$4,
				$5,$6,$7,$8,$9,
				$10,$11,$12,$13,$14,
				$15,
				$16,$17,
				$18,$19,
				$20,
				$21,$22,$23,$24,$25,
				$26,$27,$28,$29,$30,
				$31,$32,
				$33,$34,
				$35,$36,
				$37,$38,
				$39,$40,
				NOW()
			)
			ON CONFLICT (tenant_id, amc_instance_id, ads_profile_id, data_date, product_role, campaign_id, ad_product_type, ad_group_key, targeting, match_type, customer_search_term, product_asin)
			DO UPDATE SET
				campaign_name        = EXCLUDED.campaign_name,
				ad_group_name        = EXCLUDED.ad_group_name,
				currency_iso_code    = EXCLUDED.currency_iso_code,
				purchase_currency    = EXCLUDED.purchase_currency,
				portfolio_id         = EXCLUDED.portfolio_id,
				portfolio_name       = EXCLUDED.portfolio_name,
				activity_rows        = EXCLUDED.activity_rows,
				impressions          = EXCLUDED.impressions,
				clicks               = EXCLUDED.clicks,
				spend                = EXCLUDED.spend,
				viewable_impressions = EXCLUDED.viewable_impressions,
				five_sec_views       = EXCLUDED.five_sec_views,
				orders               = EXCLUDED.orders,
				sales                = EXCLUDED.sales,
				units_sold           = EXCLUDED.units_sold,
				add_to_cart          = EXCLUDED.add_to_cart,
				detail_page_views    = EXCLUDED.detail_page_views,
				brand_halo_orders    = EXCLUDED.brand_halo_orders,
				brand_halo_sales     = EXCLUDED.brand_halo_sales,
				new_to_brand_orders  = EXCLUDED.new_to_brand_orders,
				new_to_brand_sales   = EXCLUDED.new_to_brand_sales,
				purchases_clicks     = EXCLUDED.purchases_clicks,
				purchases_views      = EXCLUDED.purchases_views,
				product_sales_clicks = EXCLUDED.product_sales_clicks,
				product_sales_views  = EXCLUDED.product_sales_views,
				off_amazon_sales     = EXCLUDED.off_amazon_sales,
				combined_sales       = EXCLUDED.combined_sales,
				workflow_run_id      = EXCLUDED.workflow_run_id,
				loaded_at            = NOW()
		`,
			req.TenantID, req.AMCInstanceID, req.AdsProfileID, workflowRunID,
			dataDate, productRole, campaignID, campaignName, adProductType,
			adGroupName, adGroupKey, targeting, matchType, customerSearchTerm,
			productAsin,
			col(row, "currency_iso_code"), col(row, "purchase_currency"),
			col(row, "portfolio_id"), col(row, "portfolio_name"),
			toInt64(col(row, "activity_rows")),
			toInt64(col(row, "impressions")), toInt64(col(row, "clicks")),
			toFloat(col(row, "spend")),
			toInt64(col(row, "viewable_impressions")), toInt64(col(row, "five_sec_views")),
			toFloat(col(row, "orders")), toFloat(col(row, "sales")),
			toFloat(col(row, "units_sold")), toFloat(col(row, "add_to_cart")),
			toFloat(col(row, "detail_page_views")),
			toFloat(col(row, "brand_halo_orders")), toFloat(col(row, "brand_halo_sales")),
			toFloat(col(row, "new_to_brand_orders")), toFloat(col(row, "new_to_brand_sales")),
			toFloat(col(row, "purchases_clicks")), toFloat(col(row, "purchases_views")),
			toFloat(col(row, "product_sales_clicks")), toFloat(col(row, "product_sales_views")),
			toFloat(col(row, "off_amazon_sales")), toFloat(col(row, "combined_sales")),
		)
		if err != nil {
			log.Printf("ingest e005: upsert error asin=%s role=%s date=%s: %v", productAsin, productRole, dataDate, err)
			skipped++
			continue
		}
		inserted++
	}

	log.Printf("ingest e005: execution=%s inserted=%d skipped=%d", executionID, inserted, skipped)
	writeJSON(w, http.StatusOK, map[string]any{
		"execution_id": executionID,
		"inserted":     inserted,
		"skipped":      skipped,
		"status":       "OK",
	})
}
