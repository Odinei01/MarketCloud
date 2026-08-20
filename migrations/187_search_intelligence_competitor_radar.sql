-- 187: Radar de concorrentes por query.
-- Explode os top ASINs do Brand Analytics e cruza com nossos Search Terms Ads.
-- Objetivo: trazer informacao nova de mercado/concorrentes, nao repetir ML.

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;

DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_competitor_radar_v1 CASCADE;

CREATE OR REPLACE VIEW marketcloud_gold.gold_search_intelligence_competitor_radar_v1 AS
WITH our_asins AS (
  SELECT DISTINCT asin
  FROM marketcloud_gold.gold_search_intelligence_product_summary_v1
  WHERE asin IS NOT NULL
),
ads_query AS (
  SELECT
    lower(trim(public.unaccent(customer_search_term))) AS query_key,
    max(customer_search_term) AS ads_search_term,
    array_agg(DISTINCT asin) FILTER (WHERE asin IS NOT NULL) AS our_advertised_asins,
    array_agg(DISTINCT campaign_name) FILTER (WHERE campaign_name IS NOT NULL) AS campaigns,
    sum(coalesce(impressions,0)) AS ads_impressions,
    sum(coalesce(clicks,0)) AS ads_clicks,
    sum(coalesce(spend,0)) AS ads_spend,
    sum(coalesce(ads_orders,0)) AS ads_orders,
    sum(coalesce(ads_sales,0)) AS ads_sales,
    CASE WHEN sum(coalesce(spend,0)) > 0 THEN sum(coalesce(ads_sales,0)) / NULLIF(sum(coalesce(spend,0)),0) END AS ads_roas,
    CASE WHEN sum(coalesce(clicks,0)) > 0 THEN sum(coalesce(spend,0)) / NULLIF(sum(coalesce(clicks,0)),0) END AS ads_cpc
  FROM marketcloud_gold.gold_ads_search_term_daily_v1
  WHERE trim(coalesce(customer_search_term,'')) <> ''
  GROUP BY lower(trim(public.unaccent(customer_search_term)))
),
brand_query AS (
  SELECT
    lower(trim(public.unaccent(search_query))) AS query_key,
    max(search_query) AS search_query,
    max(query_score) AS query_score,
    max(search_query_volume) AS search_query_volume,
    max(impression_total_count) AS impression_total_count,
    max(impression_brand_count) AS impression_brand_count,
    max(impression_brand_share) AS impression_brand_share,
    max(click_total_count) AS click_total_count,
    max(click_brand_count) AS click_brand_count,
    max(click_brand_share) AS click_brand_share,
    max(click_median_price) AS click_median_price,
    max(click_brand_avg_price) AS click_brand_avg_price,
    max(cart_add_total_count) AS cart_add_total_count,
    max(cart_add_brand_count) AS cart_add_brand_count,
    max(cart_add_brand_share) AS cart_add_brand_share,
    max(purchase_total_count) AS purchase_total_count,
    max(purchase_brand_count) AS purchase_brand_count,
    max(purchase_brand_share) AS purchase_brand_share,
    max(purchase_median_price) AS purchase_median_price,
    max(purchase_brand_median_price) AS purchase_brand_median_price,
    min(period_start) AS period_start,
    max(period_end) AS period_end
  FROM marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1
  GROUP BY lower(trim(public.unaccent(search_query)))
),
market_query AS (
  SELECT
    lower(trim(public.unaccent(search_query))) AS query_key,
    max(search_query) AS search_query,
    max(best_rank) AS best_rank,
    max(asin_count) AS asin_count,
    max(our_asin_count) AS our_asin_count,
    (array_agg(top_asins ORDER BY period_end DESC NULLS LAST))[1] AS top_asins
  FROM marketcloud_gold.mv_brand_analytics_market_query_v1
  WHERE top_asins IS NOT NULL
  GROUP BY lower(trim(public.unaccent(search_query)))
),
exploded AS (
  SELECT
    m.query_key,
    coalesce(b.search_query, m.search_query) AS search_query,
    m.best_rank,
    m.asin_count,
    coalesce(m.our_asin_count,0) AS our_asin_count,
    (x.value->>'asin') AS competitor_asin,
    (x.value->>'item_name') AS competitor_item_name,
    nullif(x.value->>'rank','')::int AS competitor_rank,
    nullif(x.value->>'click_share','')::numeric AS competitor_click_share,
    nullif(x.value->>'purchase_share','')::numeric AS competitor_purchase_share,
    b.query_score,
    b.search_query_volume,
    b.impression_total_count,
    b.impression_brand_count,
    b.impression_brand_share,
    b.click_total_count,
    b.click_brand_count,
    b.click_brand_share,
    b.click_median_price,
    b.click_brand_avg_price,
    b.cart_add_total_count,
    b.cart_add_brand_count,
    b.cart_add_brand_share,
    b.purchase_total_count,
    b.purchase_brand_count,
    b.purchase_brand_share,
    b.purchase_median_price,
    b.purchase_brand_median_price,
    b.period_start,
    b.period_end,
    a.our_advertised_asins,
    a.campaigns,
    a.ads_impressions,
    a.ads_clicks,
    a.ads_spend,
    a.ads_orders,
    a.ads_sales,
    a.ads_roas,
    a.ads_cpc,
    CASE WHEN oa.asin IS NOT NULL THEN true ELSE false END AS is_our_asin
  FROM market_query m
  CROSS JOIN LATERAL jsonb_array_elements(m.top_asins) AS x(value)
  LEFT JOIN brand_query b ON b.query_key = m.query_key
  LEFT JOIN ads_query a ON a.query_key = m.query_key
  LEFT JOIN our_asins oa ON oa.asin = (x.value->>'asin')
)
SELECT *
FROM exploded;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_competitor_radar_v1 IS
'Radar de concorrentes do Brand Analytics: query, top ASINs concorrentes, shares e cruzamento com gasto/venda Ads da ZANOM.';
