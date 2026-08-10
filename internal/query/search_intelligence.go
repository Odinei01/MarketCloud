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
  FROM marketcloud_gold.gold_search_intelligence_product_daily_v1
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
         MAX(currency_code) AS currency_code,
         MIN(data_date) AS first_date,
         MAX(data_date) AS last_date,
         SUM(total_orders)::float8 AS total_orders,
         SUM(total_units)::float8 AS total_units,
         SUM(gross_sales)::float8 AS gross_sales,
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
FROM marketcloud_gold.gold_search_intelligence_product_daily_v1
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
SELECT d.data_date, d.asin, d.seller_sku, d.product_name, d.gross_sales::float8, d.total_orders::float8,
       d.total_units::float8, d.ads_spend::float8, d.ads_sales::float8, d.ads_orders::float8,
       d.organic_sales_estimated::float8, d.organic_orders_estimated::float8,
       d.cmv_estimated::float8, d.amazon_fee_estimated::float8, d.tax_estimated::float8,
       d.coper_estimated::float8, d.ebitda_estimated::float8,
       CASE WHEN d.gross_sales > 0 THEN (d.ebitda_estimated / NULLIF(d.gross_sales,0))::float8 ELSE NULL END AS ebitda_margin,
       d.ads_roas::float8, d.tacos::float8,
       COALESCE(ba.ba_impression_share, d.ba_impression_share)::float8 AS ba_impression_share,
       COALESCE(ba.ba_click_share, d.ba_click_share)::float8 AS ba_click_share,
       COALESCE(ba.ba_cart_share, d.ba_cart_share)::float8 AS ba_cart_share,
       COALESCE(ba.ba_purchase_share, d.ba_purchase_share)::float8 AS ba_purchase_share,
       COALESCE(ba.ba_purchase_share_lift, d.ba_purchase_share_lift)::float8 AS ba_purchase_share_lift,
       COALESCE(ba.ba_search_conversion, d.ba_search_conversion)::float8 AS ba_search_conversion,
       COALESCE(ba.ba_coverage_status, d.ba_coverage_status) AS ba_coverage_status,
       COALESCE(ba.query_count,0)::int AS ba_query_count,
       COALESCE(ba.top_queries,'[]'::jsonb) AS ba_top_queries
FROM marketcloud_gold.gold_search_intelligence_product_daily_v1 d
LEFT JOIN LATERAL (
  SELECT *
  FROM marketcloud_gold.gold_brand_analytics_product_period_v1 b
  WHERE b.asin = d.asin AND d.data_date BETWEEN b.period_start AND b.period_end
  ORDER BY b.period_end DESC
  LIMIT 1
) ba ON TRUE
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
FROM marketcloud_gold.gold_brand_analytics_market_query_v1
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

func parseDateOr(raw string, fallback time.Time) time.Time {
	if raw == "" {
		return fallback
	}
	if t, err := time.Parse("2006-01-02", raw); err == nil {
		return t
	}
	return fallback
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
