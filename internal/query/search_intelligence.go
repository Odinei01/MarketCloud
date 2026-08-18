package query

import (
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
)

// GoldSearchIntelligence returns the MVP product ranking:
// total sales by product, Ads attribution, estimated organic sales, EBITDA and
// Brand Analytics coverage. It is read-only and intentionally does not invent
// BA funnel metrics when reports are not ingested yet.
func (h *Handler) GoldSearchIntelligence(w http.ResponseWriter, r *http.Request) {
	to := parseDateOr(r.URL.Query().Get("to"), time.Now().In(time.FixedZone("BRT", -3*60*60)))
	from := parseDateOr(r.URL.Query().Get("from"), to.AddDate(0, 0, -29))
	if from.After(to) {
		from, to = to, from
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}

	rows, err := h.db.Query(r.Context(), `
WITH period AS (
  SELECT *
  FROM marketcloud_gold.mv_gold_search_intelligence_product_daily_v1
  WHERE data_date BETWEEN $1::date AND $2::date
),
ba_period AS (
  SELECT asin,
         COUNT(*)::int AS ba_periods_covered,
         MAX(ba_coverage_status) AS ba_best_coverage_status,
         MAX(ba_impression_share)::float8 AS ba_impression_share,
         MAX(ba_click_share)::float8 AS ba_click_share,
         MAX(ba_cart_share)::float8 AS ba_cart_share,
         MAX(ba_purchase_share)::float8 AS ba_purchase_share,
         MAX(ba_purchase_share_lift)::float8 AS ba_purchase_share_lift,
         MAX(ba_search_conversion)::float8 AS ba_search_conversion,
         SUM(COALESCE(query_count,0))::int AS ba_query_count,
         jsonb_agg(top_queries ORDER BY period_end DESC) FILTER (WHERE top_queries IS NOT NULL AND top_queries <> '[]'::jsonb) AS ba_top_queries
  FROM marketcloud_gold.gold_brand_analytics_product_period_v1
  WHERE period_start <= $2::date AND period_end >= $1::date
  GROUP BY asin
),
product_base AS (
  SELECT asin,
         MAX(seller_sku) AS seller_sku,
         MAX(product_name) AS product_name,
         MAX(brand) AS brand,
         MAX(current_price)::float8 AS current_price,
         MAX(unit_cost)::float8 AS unit_cost,
         MAX(unit_amazon_fee_estimated)::float8 AS unit_amazon_fee_estimated,
         MAX(currency_code) AS currency_code,
         MIN(data_date) AS first_date,
         MAX(data_date) AS last_date,
         SUM(total_orders)::float8 AS total_orders,
         SUM(total_units)::float8 AS total_units,
         SUM(gross_sales)::float8 AS gross_sales,
         CASE WHEN SUM(total_units) > 0 THEN (SUM(gross_sales) / NULLIF(SUM(total_units),0))::float8 ELSE NULL END AS avg_realized_price,
         SUM(ads_spend)::float8 AS ads_spend,
         SUM(ads_sales)::float8 AS ads_sales,
         SUM(ads_orders)::float8 AS ads_orders,
         SUM(organic_sales_estimated)::float8 AS organic_sales_estimated,
         SUM(organic_orders_estimated)::float8 AS organic_orders_estimated,
         SUM(cmv_estimated)::float8 AS cmv_estimated,
         SUM(amazon_fee_estimated)::float8 AS amazon_fee_estimated,
         SUM(tax_estimated)::float8 AS tax_estimated,
         SUM(coper_estimated)::float8 AS coper_estimated,
         SUM(ebitda_estimated)::float8 AS ebitda_estimated,
         CASE WHEN SUM(gross_sales) > 0 THEN (SUM(ebitda_estimated) / NULLIF(SUM(gross_sales),0))::float8 ELSE NULL END AS ebitda_margin,
         CASE WHEN SUM(gross_sales) > 0 THEN (SUM(ads_sales) / NULLIF(SUM(gross_sales),0))::float8 ELSE NULL END AS ads_sales_share,
         CASE WHEN SUM(gross_sales) > 0 THEN (SUM(organic_sales_estimated) / NULLIF(SUM(gross_sales),0))::float8 ELSE NULL END AS organic_sales_share,
         CASE WHEN SUM(ads_spend) > 0 THEN (SUM(ads_sales) / NULLIF(SUM(ads_spend),0))::float8 ELSE NULL END AS ads_roas,
         CASE WHEN SUM(gross_sales) > 0 THEN (SUM(ads_spend) / NULLIF(SUM(gross_sales),0))::float8 ELSE NULL END AS tacos,
         MAX(stock_available)::float8 AS stock_available,
         COUNT(*) FILTER (WHERE ba_coverage_status <> 'NO_BRAND_ANALYTICS_DATA')::int AS ba_days_covered,
         COUNT(*)::int AS days_observed,
         CASE
           WHEN SUM(gross_sales) <= 0 AND SUM(ads_spend) > 0 THEN 'CORTAR_OU_REVISAR'
           WHEN SUM(ebitda_estimated) > 0 AND COALESCE(SUM(organic_sales_estimated) / NULLIF(SUM(gross_sales),0),0) >= 0.45 THEN 'ESCALAR_ORGANICO_FORTE'
           WHEN SUM(ebitda_estimated) > 0 AND COALESCE(SUM(ads_sales) / NULLIF(SUM(gross_sales),0),0) >= 0.60 THEN 'ESCALAR_COM_CUIDADO_DEPENDE_ADS'
           WHEN SUM(ebitda_estimated) < 0 THEN 'REVISAR_MARGEM'
           ELSE 'MANTER_OBSERVAR'
         END AS recommendation_status
  FROM period
  GROUP BY asin
)
SELECT p.*,
       COALESCE(ba.ba_periods_covered,0) AS ba_periods_covered,
       COALESCE(ba.ba_query_count,0) AS ba_query_count,
       ba.ba_impression_share,
       ba.ba_click_share,
       ba.ba_cart_share,
       ba.ba_purchase_share,
       ba.ba_purchase_share_lift,
       ba.ba_search_conversion,
       COALESCE(ba.ba_top_queries, '[]'::jsonb) AS ba_top_queries,
       CASE WHEN COALESCE(ba.ba_periods_covered,0) > 0 THEN COALESCE(ba.ba_best_coverage_status,'PARTIAL')
            WHEN p.days_observed > 0 AND p.ba_days_covered = p.days_observed THEN 'COMPLETE'
            WHEN p.ba_days_covered > 0 THEN 'PARTIAL'
            ELSE 'NOT_CONFIGURED' END AS brand_analytics_coverage,
       'SALES_API_DAILY_ALLOCATED_TO_ITEMS_MINUS_ADS_ATTRIBUTION' AS organic_estimation_basis,
       'MVP_V1_OBSERVE_EXPLAIN_RECOMMEND_ONLY' AS decision_scope
FROM product_base p
LEFT JOIN ba_period ba ON ba.asin = p.asin
ORDER BY gross_sales DESC, ebitda_estimated DESC
LIMIT `+strconv.Itoa(limit), from.Format("2006-01-02"), to.Format("2006-01-02"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_intelligence_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	baCoveredItems := 0
	baQueryCount := 0
	for _, item := range items {
		if n := numericAny(item["ba_periods_covered"]); n > 0 {
			baCoveredItems++
		}
		baQueryCount += int(numericAny(item["ba_query_count"]))
	}
	baCoverage := "NOT_CONFIGURED"
	if baCoveredItems > 0 && baCoveredItems == len(items) {
		baCoverage = "COMPLETE"
	} else if baCoveredItems > 0 {
		baCoverage = "PARTIAL"
	}

	var totals map[string]any
	err = h.db.QueryRow(r.Context(), `
SELECT jsonb_build_object(
  'gross_sales', COALESCE(SUM(gross_sales),0),
  'ads_spend', COALESCE(SUM(ads_spend),0),
  'ads_sales', COALESCE(SUM(ads_sales),0),
  'organic_sales_estimated', COALESCE(SUM(organic_sales_estimated),0),
  'ebitda_estimated', COALESCE(SUM(ebitda_estimated),0),
  'ebitda_margin', CASE WHEN COALESCE(SUM(gross_sales),0) > 0 THEN COALESCE(SUM(ebitda_estimated),0) / NULLIF(SUM(gross_sales),0) ELSE NULL END,
  'orders', COALESCE(SUM(total_orders),0),
  'units', COALESCE(SUM(total_units),0),
  'cmv_estimated', COALESCE(SUM(cmv_estimated),0),
  'amazon_fee_estimated', COALESCE(SUM(amazon_fee_estimated),0),
  'tax_estimated', COALESCE(SUM(tax_estimated),0),
  'coper_estimated', COALESCE(SUM(coper_estimated),0)
)::jsonb
FROM marketcloud_gold.mv_gold_search_intelligence_product_daily_v1
WHERE data_date BETWEEN $1::date AND $2::date`, from.Format("2006-01-02"), to.Format("2006-01-02")).Scan(&totals)
	if err != nil {
		totals = map[string]any{}
	}
	var baJobs map[string]any
	err = h.db.QueryRow(r.Context(), `
SELECT jsonb_build_object(
  'total', COUNT(*),
  'pending', COUNT(*) FILTER (WHERE status IN ('REQUESTED','IN_QUEUE','IN_PROGRESS','WAITING_AMAZON')),
  'processed', COUNT(*) FILTER (WHERE status='PROCESSED'),
  'failed', COUNT(*) FILTER (WHERE status='FAILED'),
  'last_requested_at', COALESCE(to_char(MAX(requested_at),'YYYY-MM-DD HH24:MI:SS'),''),
  'last_processed_at', COALESCE(to_char(MAX(processed_at) FILTER (WHERE status='PROCESSED'),'YYYY-MM-DD HH24:MI:SS'),'')
)::jsonb
FROM swarm_src.amazon_brand_analytics_report_jobs
WHERE date_from <= $2::date AND date_to >= $1::date`, from.Format("2006-01-02"), to.Format("2006-01-02")).Scan(&baJobs)
	if err != nil {
		baJobs = map[string]any{}
	}
	if baCoverage == "NOT_CONFIGURED" && numericAny(baJobs["pending"]) > 0 {
		baCoverage = "REQUESTED_WAITING_AMAZON"
	}
	minimumSources := []map[string]any{}
	sourceRows, err := h.db.Query(r.Context(), `
SELECT source_key, source_label, status, rows, entities, positive_signal, evidence
FROM marketcloud_gold.mv_search_intelligence_minimum_source_status_v1
ORDER BY CASE source_key
  WHEN 'FINANCEIRO_ASIN' THEN 1
  WHEN 'SEARCH_CATALOG_PERFORMANCE' THEN 2
  WHEN 'SEARCH_QUERY_PERFORMANCE' THEN 3
  WHEN 'ADS_SEARCH_TERMS' THEN 4
  ELSE 9
END`)
	if err == nil {
		minimumSources, _ = pgx.CollectRows(sourceRows, pgx.RowToMap)
	}
	var minimumMatrix map[string]any
	err = h.db.QueryRow(r.Context(), `
SELECT jsonb_build_object(
  'ready_for_decision', COUNT(*) FILTER (WHERE minimum_decision_status='READY_FOR_DECISION'),
  'observe_only', COUNT(*) FILTER (WHERE minimum_decision_status='OBSERVE_ONLY'),
  'insufficient_data', COUNT(*) FILTER (WHERE minimum_decision_status='INSUFFICIENT_DATA'),
  'total_asins', COUNT(*),
  'scp_missing', COUNT(*) FILTER (WHERE scp_status='MISSING'),
  'sqp_missing', COUNT(*) FILTER (WHERE sqp_status='MISSING'),
  'ads_search_terms_missing', COUNT(*) FILTER (WHERE ads_search_terms_status='MISSING'),
  'finance_partial_or_missing', COUNT(*) FILTER (WHERE finance_status <> 'READY')
)::jsonb
FROM marketcloud_gold.gold_search_intelligence_minimum_decision_matrix_v1`).Scan(&minimumMatrix)
	if err != nil {
		minimumMatrix = map[string]any{}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"from":   from.Format("2006-01-02"),
		"to":     to.Format("2006-01-02"),
		"count":  len(items),
		"items":  items,
		"totals": totals,
		"coverage": map[string]any{
			"brand_analytics":         baCoverage,
			"brand_analytics_items":   baCoveredItems,
			"brand_analytics_queries": baQueryCount,
			"brand_analytics_jobs":    baJobs,
			"sales_source":            "SALES_API_DAILY_ALLOCATED_TO_ITEMS",
			"ads_source":              "amazon_ads_product_daily",
			"minimum_sources":         minimumSources,
			"minimum_matrix":          minimumMatrix,
		},
	})
}

func (h *Handler) GoldSearchIntelligenceProduct(w http.ResponseWriter, r *http.Request) {
	asin := chi.URLParam(r, "asin")
	to := parseDateOr(r.URL.Query().Get("to"), time.Now().In(time.FixedZone("BRT", -3*60*60)))
	from := parseDateOr(r.URL.Query().Get("from"), to.AddDate(0, 0, -29))
	if from.After(to) {
		from, to = to, from
	}
	rows, err := h.db.Query(r.Context(), `
SELECT d.data_date, d.asin, d.seller_sku, d.product_name, d.current_price::float8, d.unit_cost::float8,
       d.unit_amazon_fee_estimated::float8,
       CASE WHEN d.total_units > 0 THEN (d.gross_sales / NULLIF(d.total_units,0))::float8 ELSE NULL END AS avg_realized_price,
       d.gross_sales::float8, d.total_orders::float8,
       d.total_units::float8, d.ads_spend::float8, d.ads_sales::float8, d.ads_orders::float8,
       d.organic_sales_estimated::float8, d.organic_orders_estimated::float8,
       d.cmv_estimated::float8, d.amazon_fee_estimated::float8, d.tax_estimated::float8,
       d.coper_estimated::float8, d.ebitda_estimated::float8,
       CASE WHEN d.gross_sales > 0 THEN (d.ebitda_estimated / NULLIF(d.gross_sales,0))::float8 ELSE NULL END AS ebitda_margin,
       d.ads_roas::float8, d.tacos::float8,
       COALESCE(ba.impressions,0)::float8 AS ba_impressions,
       COALESCE(ba.clicks,0)::float8 AS ba_clicks,
       COALESCE(ba.cart_adds,0)::float8 AS ba_cart_adds,
       COALESCE(ba.purchases,0)::float8 AS ba_purchases,
       COALESCE(scp.search_traffic_sales,0)::float8 AS ba_search_traffic_sales,
       scp.click_rate::float8 AS ba_click_rate,
       scp.conversion_rate::float8 AS ba_conversion_rate,
       scp.impression_median_price::float8 AS ba_impression_median_price,
       scp.clicked_median_price::float8 AS ba_clicked_median_price,
       scp.purchase_median_price::float8 AS ba_purchase_median_price,
       COALESCE(ba.ba_impression_share, d.ba_impression_share)::float8 AS ba_impression_share,
       COALESCE(ba.ba_click_share, d.ba_click_share)::float8 AS ba_click_share,
       COALESCE(ba.ba_cart_share, d.ba_cart_share)::float8 AS ba_cart_share,
       COALESCE(ba.ba_purchase_share, d.ba_purchase_share)::float8 AS ba_purchase_share,
       COALESCE(ba.ba_purchase_share_lift, d.ba_purchase_share_lift)::float8 AS ba_purchase_share_lift,
       COALESCE(ba.ba_search_conversion, d.ba_search_conversion)::float8 AS ba_search_conversion,
       COALESCE(ba.ba_coverage_status, d.ba_coverage_status) AS ba_coverage_status,
       COALESCE(ba.query_count,0)::int AS ba_query_count,
       COALESCE(ba.top_queries,'[]'::jsonb) AS ba_top_queries
FROM marketcloud_gold.mv_gold_search_intelligence_product_daily_v1 d
LEFT JOIN LATERAL (
  SELECT *
  FROM marketcloud_gold.gold_brand_analytics_product_period_v1 b
  WHERE b.asin = d.asin AND d.data_date BETWEEN b.period_start AND b.period_end
  ORDER BY b.period_end DESC
  LIMIT 1
) ba ON TRUE
LEFT JOIN LATERAL (
  SELECT *
  FROM marketcloud_gold.gold_brand_analytics_search_catalog_full_v1 s
  WHERE s.asin = d.asin AND d.data_date BETWEEN s.period_start AND s.period_end
  ORDER BY s.period_end DESC
  LIMIT 1
) scp ON TRUE
WHERE d.asin=$1 AND d.data_date BETWEEN $2::date AND $3::date
ORDER BY data_date`, asin, from.Format("2006-01-02"), to.Format("2006-01-02"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_intelligence_product_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"asin": asin, "from": from.Format("2006-01-02"), "to": to.Format("2006-01-02"), "items": items, "count": len(items)})
}

func (h *Handler) GoldSearchIntelligenceProductAdsTerms(w http.ResponseWriter, r *http.Request) {
	asin := chi.URLParam(r, "asin")
	to := parseDateOr(r.URL.Query().Get("to"), time.Now().In(time.FixedZone("BRT", -3*60*60)))
	from := parseDateOr(r.URL.Query().Get("from"), to.AddDate(0, 0, -29))
	if from.After(to) {
		from, to = to, from
	}
	limit := 80
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 300 {
			limit = n
		}
	}
	rows, err := h.db.Query(r.Context(), `
WITH term AS (
  SELECT customer_search_term,
         MAX(campaign_name) AS campaign_name,
         MAX(ad_group_name) AS ad_group_name,
         MAX(keyword_or_target) AS keyword_or_target,
         MAX(match_type) AS match_type,
         SUM(impressions)::float8 AS impressions,
         SUM(clicks)::float8 AS clicks,
         SUM(spend)::float8 AS spend,
         CASE WHEN SUM(clicks) > 0 THEN SUM(spend) / NULLIF(SUM(clicks),0) ELSE NULL END::float8 AS cpc,
         SUM(ads_orders)::float8 AS ads_orders,
         SUM(ads_sales)::float8 AS ads_sales,
         CASE WHEN SUM(spend) > 0 THEN SUM(ads_sales) / NULLIF(SUM(spend),0) ELSE NULL END::float8 AS roas,
         CASE WHEN SUM(impressions) > 0 THEN SUM(clicks) / NULLIF(SUM(impressions),0) ELSE NULL END::float8 AS ctr,
         CASE WHEN SUM(clicks) > 0 THEN SUM(ads_orders) / NULLIF(SUM(clicks),0) ELSE NULL END::float8 AS conversion_rate,
         MIN(data_date) AS first_date,
         MAX(data_date) AS last_date
  FROM marketcloud_gold.gold_ads_search_term_daily_v1
  WHERE asin=$1 AND data_date BETWEEN $2::date AND $3::date
    AND customer_search_term IS NOT NULL
    AND TRIM(customer_search_term) <> ''
  GROUP BY customer_search_term
)
SELECT *
FROM term
ORDER BY spend DESC NULLS LAST, clicks DESC NULLS LAST, impressions DESC NULLS LAST
LIMIT `+strconv.Itoa(limit), asin, from.Format("2006-01-02"), to.Format("2006-01-02"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_intelligence_product_ads_terms_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	var totals map[string]any
	err = h.db.QueryRow(r.Context(), `
SELECT jsonb_build_object(
  'terms', COUNT(DISTINCT customer_search_term),
  'rows', COUNT(*),
  'impressions', COALESCE(SUM(impressions),0),
  'clicks', COALESCE(SUM(clicks),0),
  'spend', COALESCE(SUM(spend),0),
  'orders', COALESCE(SUM(ads_orders),0),
  'sales', COALESCE(SUM(ads_sales),0),
  'roas', CASE WHEN COALESCE(SUM(spend),0) > 0 THEN COALESCE(SUM(ads_sales),0) / NULLIF(SUM(spend),0) ELSE NULL END
)::jsonb
FROM marketcloud_gold.gold_ads_search_term_daily_v1
WHERE asin=$1 AND data_date BETWEEN $2::date AND $3::date
  AND customer_search_term IS NOT NULL
  AND TRIM(customer_search_term) <> ''`, asin, from.Format("2006-01-02"), to.Format("2006-01-02")).Scan(&totals)
	if err != nil {
		totals = map[string]any{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"asin": asin, "from": from.Format("2006-01-02"), "to": to.Format("2006-01-02"), "items": items, "totals": totals, "count": len(items)})
}

func (h *Handler) GoldSearchIntelligenceMarketQueries(w http.ResponseWriter, r *http.Request) {
	to := parseDateOr(r.URL.Query().Get("to"), time.Now().In(time.FixedZone("BRT", -3*60*60)))
	from := parseDateOr(r.URL.Query().Get("from"), to.AddDate(0, 0, -29))
	if from.After(to) {
		from, to = to, from
	}
	limit := 40
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 200 {
			limit = n
		}
	}
	rows, err := h.db.Query(r.Context(), `
SELECT search_query,
       best_rank,
       asin_count,
       our_asin_count,
       avg_click_share::float8 AS avg_click_share,
       avg_purchase_share::float8 AS avg_purchase_share,
       period_start,
       period_end,
       top_asins
FROM marketcloud_gold.mv_brand_analytics_market_query_v1
WHERE period_start <= $2::date AND period_end >= $1::date
ORDER BY best_rank ASC NULLS LAST, avg_purchase_share DESC NULLS LAST, avg_click_share DESC NULLS LAST
LIMIT `+strconv.Itoa(limit), from.Format("2006-01-02"), to.Format("2006-01-02"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_intelligence_market_queries_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"from": from.Format("2006-01-02"), "to": to.Format("2006-01-02"), "items": items, "count": len(items)})
}

func (h *Handler) GoldSearchIntelligenceBrandQueries(w http.ResponseWriter, r *http.Request) {
	to := parseDateOr(r.URL.Query().Get("to"), time.Now().In(time.FixedZone("BRT", -3*60*60)))
	from := parseDateOr(r.URL.Query().Get("from"), to.AddDate(0, 0, -29))
	if from.After(to) {
		from, to = to, from
	}
	limit := 80
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 300 {
			limit = n
		}
	}
	rows, err := h.db.Query(r.Context(), `
SELECT search_query,
       query_score::float8 AS query_score,
       search_query_volume::float8 AS search_query_volume,
       impression_total_count::float8 AS impression_total_count,
       impression_brand_count::float8 AS impression_brand_count,
       impression_brand_share::float8 AS impression_brand_share,
       click_total_count::float8 AS click_total_count,
       click_rate::float8 AS click_rate,
       click_brand_count::float8 AS click_brand_count,
       click_brand_share::float8 AS click_brand_share,
       click_median_price::float8 AS click_median_price,
       click_brand_avg_price::float8 AS click_brand_avg_price,
       cart_add_total_count::float8 AS cart_add_total_count,
       cart_add_rate::float8 AS cart_add_rate,
       cart_add_brand_count::float8 AS cart_add_brand_count,
       cart_add_brand_share::float8 AS cart_add_brand_share,
       cart_add_median_price::float8 AS cart_add_median_price,
       cart_add_brand_median_price::float8 AS cart_add_brand_median_price,
       purchase_total_count::float8 AS purchase_total_count,
       purchase_rate::float8 AS purchase_rate,
       purchase_brand_count::float8 AS purchase_brand_count,
       purchase_brand_share::float8 AS purchase_brand_share,
       purchase_median_price::float8 AS purchase_median_price,
       purchase_brand_median_price::float8 AS purchase_brand_median_price,
       brand_purchase_share_lift::float8 AS brand_purchase_share_lift,
       brand_purchase_per_query::float8 AS brand_purchase_per_query,
       period_start,
       period_end,
       report_date
FROM marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1
WHERE period_start <= $2::date AND period_end >= $1::date
ORDER BY query_score ASC NULLS LAST, purchase_brand_count DESC NULLS LAST, search_query_volume DESC NULLS LAST
LIMIT `+strconv.Itoa(limit), from.Format("2006-01-02"), to.Format("2006-01-02"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_intelligence_brand_queries_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	var totals map[string]any
	err = h.db.QueryRow(r.Context(), `
SELECT jsonb_build_object(
  'queries', COUNT(*),
  'search_query_volume', COALESCE(SUM(search_query_volume),0),
  'impression_total_count', COALESCE(SUM(impression_total_count),0),
  'impression_brand_count', COALESCE(SUM(impression_brand_count),0),
  'click_total_count', COALESCE(SUM(click_total_count),0),
  'click_brand_count', COALESCE(SUM(click_brand_count),0),
  'cart_add_total_count', COALESCE(SUM(cart_add_total_count),0),
  'cart_add_brand_count', COALESCE(SUM(cart_add_brand_count),0),
  'purchase_total_count', COALESCE(SUM(purchase_total_count),0),
  'purchase_brand_count', COALESCE(SUM(purchase_brand_count),0),
  'impression_brand_share', CASE WHEN COALESCE(SUM(impression_total_count),0) > 0 THEN COALESCE(SUM(impression_brand_count),0) / NULLIF(SUM(impression_total_count),0) ELSE NULL END,
  'click_brand_share', CASE WHEN COALESCE(SUM(click_total_count),0) > 0 THEN COALESCE(SUM(click_brand_count),0) / NULLIF(SUM(click_total_count),0) ELSE NULL END,
  'purchase_brand_share', CASE WHEN COALESCE(SUM(purchase_total_count),0) > 0 THEN COALESCE(SUM(purchase_brand_count),0) / NULLIF(SUM(purchase_total_count),0) ELSE NULL END
)::jsonb
FROM marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1
WHERE period_start <= $2::date AND period_end >= $1::date`, from.Format("2006-01-02"), to.Format("2006-01-02")).Scan(&totals)
	if err != nil {
		totals = map[string]any{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"from": from.Format("2006-01-02"), "to": to.Format("2006-01-02"), "items": items, "totals": totals, "count": len(items)})
}

func (h *Handler) GoldSearchIntelligenceCompetitors(w http.ResponseWriter, r *http.Request) {
	limit := 80
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 300 {
			limit = n
		}
	}
	mode := r.URL.Query().Get("mode")
	where := "WHERE NOT is_our_asin AND COALESCE(ads_spend,0) > 0"
	if mode == "all" {
		where = "WHERE NOT is_our_asin"
	}
	rows, err := h.db.Query(r.Context(), `
SELECT search_query,
       competitor_asin,
       competitor_item_name,
       competitor_rank,
       competitor_click_share::float8 AS competitor_click_share,
       competitor_purchase_share::float8 AS competitor_purchase_share,
       search_query_volume::float8 AS search_query_volume,
       impression_brand_share::float8 AS impression_brand_share,
       click_brand_share::float8 AS click_brand_share,
       purchase_brand_share::float8 AS purchase_brand_share,
       purchase_median_price::float8 AS purchase_median_price,
       purchase_brand_median_price::float8 AS purchase_brand_median_price,
       our_advertised_asins,
       campaigns,
       ads_impressions::float8 AS ads_impressions,
       ads_clicks::float8 AS ads_clicks,
       ads_spend::float8 AS ads_spend,
       ads_orders::float8 AS ads_orders,
       ads_sales::float8 AS ads_sales,
       ads_roas::float8 AS ads_roas,
       ads_cpc::float8 AS ads_cpc
FROM marketcloud_gold.mv_gold_search_intelligence_competitor_radar_v1
`+where+`
ORDER BY
  ads_spend DESC NULLS LAST,
  competitor_purchase_share DESC NULLS LAST,
  competitor_click_share DESC NULLS LAST
LIMIT $1`, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_intelligence_competitors_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	var totals map[string]any
	err = h.db.QueryRow(r.Context(), `
SELECT jsonb_build_object(
  'competitors', COUNT(DISTINCT competitor_asin) FILTER (WHERE NOT is_our_asin),
  'queries', COUNT(DISTINCT search_query) FILTER (WHERE NOT is_our_asin),
  'rows', COUNT(*) FILTER (WHERE NOT is_our_asin),
  'with_our_ads', COUNT(*) FILTER (WHERE NOT is_our_asin AND COALESCE(ads_spend,0) > 0),
  'competitor_purchase_while_our_ads_no_sale', COUNT(*) FILTER (
      WHERE NOT is_our_asin
        AND COALESCE(ads_spend,0) > 0
        AND COALESCE(ads_sales,0) = 0
        AND COALESCE(competitor_purchase_share,0) > 0
  ),
  'competitor_with_purchase_share', COUNT(*) FILTER (
      WHERE NOT is_our_asin AND COALESCE(competitor_purchase_share,0) > 0
  ),
  'our_spend_on_competed_queries', COALESCE(SUM(ads_spend) FILTER (WHERE NOT is_our_asin AND COALESCE(ads_spend,0) > 0),0),
  'our_sales_on_competed_queries', COALESCE(SUM(ads_sales) FILTER (WHERE NOT is_our_asin AND COALESCE(ads_spend,0) > 0),0)
)::jsonb
FROM marketcloud_gold.mv_gold_search_intelligence_competitor_radar_v1`).Scan(&totals)
	if err != nil {
		totals = map[string]any{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "totals": totals, "count": len(items)})
}

func (h *Handler) GoldSearchIntelligenceQueryOpportunities(w http.ResponseWriter, r *http.Request) {
	limit := parseLimit(r.URL.Query().Get("limit"), 80, 300)
	asin := r.URL.Query().Get("asin")
	where := "WHERE true"
	args := []any{}
	if asin != "" {
		args = append(args, asin)
		where += " AND asin = $" + strconv.Itoa(len(args))
	}
	args = append(args, limit)
	rows, err := h.db.Query(r.Context(), `
SELECT asin,
       campaign_id,
       seller_sku,
       product_name,
       query_key,
       search_query,
       campaign_name,
       ad_group_name,
       keyword_or_target,
       match_type,
       ads_impressions::float8 AS ads_impressions,
       ads_clicks::float8 AS ads_clicks,
       ads_spend::float8 AS ads_spend,
       ads_orders::float8 AS ads_orders,
       ads_sales::float8 AS ads_sales,
       ads_cpc::float8 AS ads_cpc,
       ads_roas::float8 AS ads_roas,
       ads_ctr::float8 AS ads_ctr,
       ads_cvr::float8 AS ads_cvr,
       ebitda_margin::float8 AS ebitda_margin,
       current_price::float8 AS current_price,
       avg_realized_price::float8 AS avg_realized_price,
       search_query_volume::float8 AS search_query_volume,
       brand_impression_share::float8 AS brand_impression_share,
       brand_click_share::float8 AS brand_click_share,
       brand_cart_share::float8 AS brand_cart_share,
       brand_purchase_share::float8 AS brand_purchase_share,
       brand_purchase_share_lift::float8 AS brand_purchase_share_lift,
       competitor_count,
       top_competitor_click_share::float8 AS top_competitor_click_share,
       top_competitor_purchase_share::float8 AS top_competitor_purchase_share,
       competitors,
       ml_computed_at,
       ml_cells,
       ml_max_click_probability::float8 AS ml_max_click_probability,
       ml_max_conversion_probability::float8 AS ml_max_conversion_probability,
       ml_max_expected_roas::float8 AS ml_max_expected_roas,
       ml_best_hour,
       query_history_as_of_date,
       spend_7d_lag::float8 AS spend_7d_lag,
       orders_7d_lag::float8 AS orders_7d_lag,
       sales_7d_lag::float8 AS sales_7d_lag,
       roas_7d_lag::float8 AS roas_7d_lag,
       spend_28d_lag::float8 AS spend_28d_lag,
       orders_28d_lag::float8 AS orders_28d_lag,
       sales_28d_lag::float8 AS sales_28d_lag,
       roas_28d_lag::float8 AS roas_28d_lag,
       ml_explain_label,
       ml_explain_score::float8 AS ml_explain_score
FROM marketcloud_gold.gold_search_intelligence_asin_query_v1
`+where+`
ORDER BY ml_explain_score DESC NULLS LAST,
         ads_spend DESC NULLS LAST,
         search_query
LIMIT $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_intelligence_query_opportunities_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	var totals map[string]any
	totalsSQL := `
SELECT jsonb_build_object(
  'rows', COUNT(*),
  'asins', COUNT(DISTINCT asin),
  'with_ml', COUNT(*) FILTER (WHERE COALESCE(ml_cells,0) > 0),
  'with_competitor', COUNT(*) FILTER (WHERE COALESCE(competitor_count,0) > 0),
  'with_brand_query', COUNT(*) FILTER (WHERE search_query_volume IS NOT NULL),
  'ads_spend', COALESCE(SUM(ads_spend),0),
  'ads_sales', COALESCE(SUM(ads_sales),0),
  'labels', COALESCE(jsonb_object_agg(ml_explain_label, label_count), '{}'::jsonb)
)::jsonb
FROM (
  SELECT *, COUNT(*) OVER (PARTITION BY ml_explain_label) AS label_count
  FROM marketcloud_gold.gold_search_intelligence_asin_query_v1
  ` + where + `
) q`
	err = h.db.QueryRow(r.Context(), totalsSQL, args[:len(args)-1]...).Scan(&totals)
	if err != nil {
		totals = map[string]any{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "totals": totals, "count": len(items)})
}

func (h *Handler) GoldSearchIntelligenceProductQueryOpportunities(w http.ResponseWriter, r *http.Request) {
	asin := chi.URLParam(r, "asin")
	q := r.URL.Query()
	q.Set("asin", asin)
	r.URL.RawQuery = q.Encode()
	h.GoldSearchIntelligenceQueryOpportunities(w, r)
}

func (h *Handler) GoldSearchIntelligenceCoverage(w http.ResponseWriter, r *http.Request) {
	limit := parseLimit(r.URL.Query().Get("limit"), 80, 300)
	status := r.URL.Query().Get("status")
	where := "WHERE true"
	args := []any{}
	if status != "" {
		args = append(args, status)
		where += " AND coverage_label = $" + strconv.Itoa(len(args))
	}
	args = append(args, limit)
	rows, err := h.db.Query(r.Context(), `
SELECT asin,
       product_name,
       seller_sku,
       gross_sales::float8 AS gross_sales,
       total_units::float8 AS total_units,
       total_orders::float8 AS total_orders,
       ebitda_estimated::float8 AS ebitda_estimated,
       ebitda_margin::float8 AS ebitda_margin,
       finance_status,
       scp_status,
       sqp_status,
       ads_search_terms_status,
       minimum_decision_status,
       scp_impressions::float8 AS scp_impressions,
       scp_clicks::float8 AS scp_clicks,
       scp_purchases::float8 AS scp_purchases,
       scp_ctr::float8 AS scp_ctr,
       scp_click_to_purchase_cvr::float8 AS scp_click_to_purchase_cvr,
       sqp_query_rows,
       sqp_impressions::float8 AS sqp_impressions,
       sqp_clicks::float8 AS sqp_clicks,
       sqp_purchases::float8 AS sqp_purchases,
       ads_search_terms,
       ads_search_term_spend::float8 AS ads_search_term_spend,
       ads_search_term_orders::float8 AS ads_search_term_orders,
       ads_search_term_sales::float8 AS ads_search_term_sales,
       ads_search_term_roas::float8 AS ads_search_term_roas,
       ready_source_count,
       missing_sources_json,
       coverage_label
FROM marketcloud_gold.mv_gold_search_intelligence_asin_source_coverage_v1
`+where+`
ORDER BY ready_source_count DESC,
         gross_sales DESC NULLS LAST,
         ads_search_term_spend DESC NULLS LAST,
         asin
LIMIT $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_intelligence_coverage_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	summaryRows, err := h.db.Query(r.Context(), `
SELECT source_key,
       source_label,
       total_asins,
       ready_asins,
       missing_asins,
       gross_sales::float8 AS gross_sales,
       total_units::float8 AS total_units,
       total_orders::float8 AS total_orders,
       impressions::float8 AS impressions,
       clicks::float8 AS clicks,
       purchases::float8 AS purchases,
       explanation
FROM marketcloud_gold.gold_search_intelligence_ba_coverage_summary_v1
ORDER BY source_key`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_intelligence_coverage_summary_failed: "+err.Error())
		return
	}
	summary, err := pgx.CollectRows(summaryRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "summary": summary, "count": len(items)})
}

func (h *Handler) GoldSearchIntelligenceQueryDoctor(w http.ResponseWriter, r *http.Request) {
	limit := parseLimit(r.URL.Query().Get("limit"), 80, 300)
	asin := r.URL.Query().Get("asin")
	evidenceClass := r.URL.Query().Get("class")
	where := "WHERE true"
	args := []any{}
	if asin != "" {
		args = append(args, asin)
		where += " AND asin = $" + strconv.Itoa(len(args))
	}
	if evidenceClass != "" {
		args = append(args, evidenceClass)
		where += " AND doctor_evidence_class = $" + strconv.Itoa(len(args))
	}
	args = append(args, limit)
	rows, err := h.db.Query(r.Context(), `
SELECT asin,
       campaign_id,
       seller_sku,
       product_name,
       query_key,
       search_query,
       campaign_name,
       ad_group_name,
       keyword_or_target,
       match_type,
       ads_impressions::float8 AS ads_impressions,
       ads_clicks::float8 AS ads_clicks,
       ads_spend::float8 AS ads_spend,
       ads_orders::float8 AS ads_orders,
       ads_sales::float8 AS ads_sales,
       ads_cpc::float8 AS ads_cpc,
       ads_roas::float8 AS ads_roas,
       search_query_volume::float8 AS search_query_volume,
       brand_impression_share::float8 AS brand_impression_share,
       brand_click_share::float8 AS brand_click_share,
       brand_cart_share::float8 AS brand_cart_share,
       brand_purchase_share::float8 AS brand_purchase_share,
       query_purchase_median_price::float8 AS query_purchase_median_price,
       competitor_count,
       top_competitor_click_share::float8 AS top_competitor_click_share,
       top_competitor_purchase_share::float8 AS top_competitor_purchase_share,
       competitors,
       ml_cells,
       ml_max_click_probability::float8 AS ml_max_click_probability,
       ml_max_conversion_probability::float8 AS ml_max_conversion_probability,
       ml_max_expected_roas::float8 AS ml_max_expected_roas,
       ml_best_hour,
       spend_7d_lag::float8 AS spend_7d_lag,
       orders_7d_lag::float8 AS orders_7d_lag,
       sales_7d_lag::float8 AS sales_7d_lag,
       roas_7d_lag::float8 AS roas_7d_lag,
       ml_explain_label,
       ml_explain_score::float8 AS ml_explain_score,
       coverage_label,
       finance_status,
       scp_status,
       sqp_status,
       ads_search_terms_status,
       missing_sources_json,
       doctor_evidence_class,
       doctor_json
FROM marketcloud_gold.mv_gold_search_intelligence_query_doctor_v1
`+where+`
ORDER BY
  CASE doctor_evidence_class
    WHEN 'ML_COMPETITION_AND_MARKET' THEN 1
    WHEN 'ML_ONLY' THEN 2
    WHEN 'MARKET_COMPETITION_ONLY' THEN 3
    WHEN 'ADS_FACT_ONLY' THEN 4
    ELSE 5
  END,
  ml_explain_score DESC NULLS LAST,
  ads_spend DESC NULLS LAST,
  search_query
LIMIT $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "search_intelligence_query_doctor_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	var totals map[string]any
	totalsSQL := `
SELECT jsonb_build_object(
  'rows', COUNT(*),
  'asins', COUNT(DISTINCT asin),
  'with_ml', COUNT(*) FILTER (WHERE COALESCE(ml_cells,0) > 0),
  'with_competitor', COUNT(*) FILTER (WHERE COALESCE(competitor_count,0) > 0),
  'with_brand_query', COUNT(*) FILTER (WHERE search_query_volume IS NOT NULL),
  'classes', COALESCE(jsonb_object_agg(doctor_evidence_class, class_count), '{}'::jsonb)
)::jsonb
FROM (
  SELECT *, COUNT(*) OVER (PARTITION BY doctor_evidence_class) AS class_count
  FROM marketcloud_gold.mv_gold_search_intelligence_query_doctor_v1
  ` + where + `
) q`
	err = h.db.QueryRow(r.Context(), totalsSQL, args[:len(args)-1]...).Scan(&totals)
	if err != nil {
		totals = map[string]any{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "totals": totals, "count": len(items)})
}

func (h *Handler) GoldSearchIntelligenceProductQueryDoctor(w http.ResponseWriter, r *http.Request) {
	asin := chi.URLParam(r, "asin")
	q := r.URL.Query()
	q.Set("asin", asin)
	r.URL.RawQuery = q.Encode()
	h.GoldSearchIntelligenceQueryDoctor(w, r)
}

func parseDateOr(raw string, fallback time.Time) time.Time {
	if raw == "" {
		return fallback
	}
	if t, err := time.Parse("2006-01-02", raw); err == nil {
		return t
	}
	return fallback
}

func parseLimit(raw string, fallback int, max int) int {
	if raw == "" {
		return fallback
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 {
		return fallback
	}
	if n > max {
		return max
	}
	return n
}

func numericAny(v any) float64 {
	switch t := v.(type) {
	case int:
		return float64(t)
	case int64:
		return float64(t)
	case int32:
		return float64(t)
	case float64:
		return t
	case float32:
		return float64(t)
	case string:
		if n, err := strconv.ParseFloat(t, 64); err == nil {
			return n
		}
	}
	return 0
}
