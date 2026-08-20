-- 189: Search Intelligence Fase 2.
-- Camada ML-only para inteligencia competitiva:
-- 1) historico Ads por query em janela lagged (D-1) para futuro treino point-in-time;
-- 2) ASIN x Query com economia, funil BA, concorrentes e predicoes ML;
-- 3) explicacao por query sem recomendar acao por regra.

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;

CREATE SCHEMA IF NOT EXISTS marketcloud_features;

CREATE OR REPLACE VIEW marketcloud_features.feature_query_ads_history_lagged_v1 AS
WITH daily AS (
  SELECT
    data_date,
    lower(trim(public.unaccent(customer_search_term))) AS query_key,
    max(customer_search_term) AS search_query,
    sum(coalesce(impressions,0))::numeric AS impressions,
    sum(coalesce(clicks,0))::numeric AS clicks,
    sum(coalesce(spend,0))::numeric AS spend,
    sum(coalesce(ads_orders,0))::numeric AS orders,
    sum(coalesce(ads_sales,0))::numeric AS sales
  FROM marketcloud_gold.gold_ads_search_term_daily_v1
  WHERE trim(coalesce(customer_search_term,'')) <> ''
  GROUP BY data_date, lower(trim(public.unaccent(customer_search_term)))
),
calendar AS (
  SELECT
    query_key,
    max(search_query) AS search_query,
    generate_series(min(data_date) + interval '1 day', max(data_date) + interval '1 day', interval '1 day')::date AS as_of_date
  FROM daily
  GROUP BY query_key
)
SELECT
  c.query_key,
  c.search_query,
  c.as_of_date,
  coalesce(sum(d.impressions) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 7 AND c.as_of_date - 1),0)::numeric AS impressions_7d_lag,
  coalesce(sum(d.clicks) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 7 AND c.as_of_date - 1),0)::numeric AS clicks_7d_lag,
  coalesce(sum(d.spend) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 7 AND c.as_of_date - 1),0)::numeric AS spend_7d_lag,
  coalesce(sum(d.orders) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 7 AND c.as_of_date - 1),0)::numeric AS orders_7d_lag,
  coalesce(sum(d.sales) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 7 AND c.as_of_date - 1),0)::numeric AS sales_7d_lag,
  CASE WHEN coalesce(sum(d.spend) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 7 AND c.as_of_date - 1),0) > 0
       THEN coalesce(sum(d.sales) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 7 AND c.as_of_date - 1),0)
            / nullif(sum(d.spend) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 7 AND c.as_of_date - 1),0)
  END::numeric AS roas_7d_lag,
  coalesce(sum(d.impressions) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 14 AND c.as_of_date - 1),0)::numeric AS impressions_14d_lag,
  coalesce(sum(d.clicks) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 14 AND c.as_of_date - 1),0)::numeric AS clicks_14d_lag,
  coalesce(sum(d.spend) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 14 AND c.as_of_date - 1),0)::numeric AS spend_14d_lag,
  coalesce(sum(d.orders) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 14 AND c.as_of_date - 1),0)::numeric AS orders_14d_lag,
  coalesce(sum(d.sales) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 14 AND c.as_of_date - 1),0)::numeric AS sales_14d_lag,
  CASE WHEN coalesce(sum(d.spend) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 14 AND c.as_of_date - 1),0) > 0
       THEN coalesce(sum(d.sales) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 14 AND c.as_of_date - 1),0)
            / nullif(sum(d.spend) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 14 AND c.as_of_date - 1),0)
  END::numeric AS roas_14d_lag,
  coalesce(sum(d.impressions) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 28 AND c.as_of_date - 1),0)::numeric AS impressions_28d_lag,
  coalesce(sum(d.clicks) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 28 AND c.as_of_date - 1),0)::numeric AS clicks_28d_lag,
  coalesce(sum(d.spend) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 28 AND c.as_of_date - 1),0)::numeric AS spend_28d_lag,
  coalesce(sum(d.orders) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 28 AND c.as_of_date - 1),0)::numeric AS orders_28d_lag,
  coalesce(sum(d.sales) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 28 AND c.as_of_date - 1),0)::numeric AS sales_28d_lag,
  CASE WHEN coalesce(sum(d.spend) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 28 AND c.as_of_date - 1),0) > 0
       THEN coalesce(sum(d.sales) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 28 AND c.as_of_date - 1),0)
            / nullif(sum(d.spend) FILTER (WHERE d.data_date BETWEEN c.as_of_date - 28 AND c.as_of_date - 1),0)
  END::numeric AS roas_28d_lag
FROM calendar c
LEFT JOIN daily d ON d.query_key = c.query_key AND d.data_date < c.as_of_date
GROUP BY c.query_key, c.search_query, c.as_of_date;

COMMENT ON VIEW marketcloud_features.feature_query_ads_history_lagged_v1 IS
'Historico Ads por query com janelas trailing ate D-1. Fonte honesta para treino point-in-time futuro; nao usar cumulativo presente.';

DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_ml_query_explain_v1;
DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_asin_query_v1;

CREATE OR REPLACE VIEW marketcloud_gold.gold_search_intelligence_asin_query_v1 AS
WITH ads AS (
  SELECT
    asin,
    campaign_id,
    lower(trim(public.unaccent(customer_search_term))) AS query_key,
    max(customer_search_term) AS search_query,
    max(campaign_name) AS campaign_name,
    max(ad_group_name) AS ad_group_name,
    max(keyword_or_target) AS keyword_or_target,
    max(match_type) AS match_type,
    min(data_date) AS first_ads_date,
    max(data_date) AS last_ads_date,
    sum(coalesce(impressions,0))::numeric AS ads_impressions,
    sum(coalesce(clicks,0))::numeric AS ads_clicks,
    sum(coalesce(spend,0))::numeric AS ads_spend,
    sum(coalesce(ads_orders,0))::numeric AS ads_orders,
    sum(coalesce(ads_sales,0))::numeric AS ads_sales,
    CASE WHEN sum(coalesce(clicks,0)) > 0 THEN sum(coalesce(spend,0))/nullif(sum(coalesce(clicks,0)),0) END::numeric AS ads_cpc,
    CASE WHEN sum(coalesce(spend,0)) > 0 THEN sum(coalesce(ads_sales,0))/nullif(sum(coalesce(spend,0)),0) END::numeric AS ads_roas,
    CASE WHEN sum(coalesce(impressions,0)) > 0 THEN sum(coalesce(clicks,0))/nullif(sum(coalesce(impressions,0)),0) END::numeric AS ads_ctr,
    CASE WHEN sum(coalesce(clicks,0)) > 0 THEN sum(coalesce(ads_orders,0))/nullif(sum(coalesce(clicks,0)),0) END::numeric AS ads_cvr
  FROM marketcloud_gold.gold_ads_search_term_daily_v1
  WHERE coalesce(asin,'') <> ''
    AND trim(coalesce(customer_search_term,'')) <> ''
  GROUP BY asin, campaign_id, lower(trim(public.unaccent(customer_search_term)))
),
product AS (
  SELECT
    asin,
    max(seller_sku) AS seller_sku,
    max(product_name) AS product_name,
    max(brand) AS brand,
    sum(gross_sales)::numeric AS gross_sales,
    sum(total_units)::numeric AS total_units,
    sum(total_orders)::numeric AS total_orders,
    sum(ads_spend)::numeric AS product_ads_spend,
    sum(ads_sales)::numeric AS product_ads_sales,
    sum(ads_orders)::numeric AS product_ads_orders,
    sum(organic_sales_estimated)::numeric AS organic_sales_estimated,
    sum(cmv_estimated)::numeric AS cmv_estimated,
    sum(amazon_fee_estimated)::numeric AS amazon_fee_estimated,
    sum(tax_estimated)::numeric AS tax_estimated,
    sum(coper_estimated)::numeric AS coper_estimated,
    sum(ebitda_estimated)::numeric AS ebitda_estimated,
    CASE WHEN sum(gross_sales) > 0 THEN sum(ebitda_estimated)/nullif(sum(gross_sales),0) END::numeric AS ebitda_margin,
    max(stock_available)::numeric AS stock_available,
    max(current_price)::numeric AS current_price,
    CASE WHEN sum(total_units) > 0 THEN sum(gross_sales)/nullif(sum(total_units),0) END::numeric AS avg_realized_price
  FROM marketcloud_gold.gold_search_intelligence_product_daily_v1
  GROUP BY asin
),
catalog AS (
  SELECT DISTINCT ON (asin)
    asin,
    impressions AS scp_impressions,
    clicks AS scp_clicks,
    cart_adds AS scp_cart_adds,
    purchases AS scp_purchases,
    search_traffic_sales AS scp_search_traffic_sales,
    brand_impression_share AS scp_impression_share,
    brand_click_share AS scp_click_share,
    brand_cart_add_share AS scp_cart_share,
    brand_purchase_share AS scp_purchase_share,
    click_rate AS scp_ctr,
    conversion_rate AS scp_cvr,
    impression_median_price AS scp_impression_median_price,
    clicked_median_price AS scp_clicked_median_price,
    purchase_median_price AS scp_purchase_median_price,
    period_start AS scp_period_start,
    period_end AS scp_period_end
  FROM marketcloud_gold.gold_brand_analytics_search_catalog_full_v1
  ORDER BY asin, period_end DESC NULLS LAST, synced_at DESC NULLS LAST
),
brand_query AS (
  SELECT
    lower(trim(public.unaccent(search_query))) AS query_key,
    max(search_query) AS search_query,
    max(search_query_volume)::numeric AS search_query_volume,
    max(impression_brand_share)::numeric AS brand_impression_share,
    max(click_brand_share)::numeric AS brand_click_share,
    max(cart_add_brand_share)::numeric AS brand_cart_share,
    max(purchase_brand_share)::numeric AS brand_purchase_share,
    max(purchase_median_price)::numeric AS query_purchase_median_price,
    max(purchase_brand_median_price)::numeric AS brand_purchase_median_price,
    max(brand_purchase_share_lift)::numeric AS brand_purchase_share_lift,
    max(purchase_rate)::numeric AS query_purchase_rate,
    max(report_date)::date AS brand_query_report_date
  FROM marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1
  GROUP BY lower(trim(public.unaccent(search_query)))
),
competitor AS (
  SELECT
    query_key,
    count(DISTINCT competitor_asin) FILTER (WHERE NOT is_our_asin)::int AS competitor_count,
    max(coalesce(competitor_click_share,0)) FILTER (WHERE NOT is_our_asin)::numeric AS top_competitor_click_share,
    max(coalesce(competitor_purchase_share,0)) FILTER (WHERE NOT is_our_asin)::numeric AS top_competitor_purchase_share,
    jsonb_agg(
      jsonb_build_object(
        'asin', competitor_asin,
        'name', competitor_item_name,
        'rank', competitor_rank,
        'click_share', competitor_click_share,
        'purchase_share', competitor_purchase_share
      )
      ORDER BY competitor_purchase_share DESC NULLS LAST, competitor_click_share DESC NULLS LAST
    ) FILTER (WHERE NOT is_our_asin) AS competitors
  FROM marketcloud_gold.gold_search_intelligence_competitor_radar_v1
  GROUP BY query_key
),
ml AS (
  SELECT
    lower(trim(public.unaccent(coalesce(nullif(keyword_text,''), nullif(targeting,''), '')))) AS query_key,
    max(computed_at) AS ml_computed_at,
    campaign_id,
    count(*)::int AS ml_cells,
    max(click_probability)::numeric AS ml_max_click_probability,
    avg(click_probability)::numeric AS ml_avg_click_probability,
    max(conversion_probability)::numeric AS ml_max_conversion_probability,
    avg(conversion_probability)::numeric AS ml_avg_conversion_probability,
    max(expected_roas)::numeric AS ml_max_expected_roas,
    avg(expected_roas)::numeric AS ml_avg_expected_roas,
    max(event_hour) FILTER (WHERE predicted_good_target_hour) AS ml_best_hour
  FROM marketcloud_gold.hourly_target_ml_predictions_v3
  WHERE trim(coalesce(keyword_text, targeting, '')) <> ''
  GROUP BY campaign_id, lower(trim(public.unaccent(coalesce(nullif(keyword_text,''), nullif(targeting,''), ''))))
),
lag AS (
  SELECT DISTINCT ON (query_key)
    *
  FROM marketcloud_features.feature_query_ads_history_lagged_v1
  ORDER BY query_key, as_of_date DESC
)
SELECT
  a.asin,
  a.campaign_id,
  p.seller_sku,
  p.product_name,
  p.brand,
  a.query_key,
  a.search_query,
  a.campaign_name,
  a.ad_group_name,
  a.keyword_or_target,
  a.match_type,
  a.first_ads_date,
  a.last_ads_date,
  a.ads_impressions,
  a.ads_clicks,
  a.ads_spend,
  a.ads_orders,
  a.ads_sales,
  a.ads_cpc,
  a.ads_roas,
  a.ads_ctr,
  a.ads_cvr,
  p.gross_sales,
  p.total_units,
  p.total_orders,
  p.product_ads_spend,
  p.product_ads_sales,
  p.product_ads_orders,
  p.organic_sales_estimated,
  p.cmv_estimated,
  p.amazon_fee_estimated,
  p.tax_estimated,
  p.coper_estimated,
  p.ebitda_estimated,
  p.ebitda_margin,
  p.stock_available,
  p.current_price,
  p.avg_realized_price,
  c.scp_impressions,
  c.scp_clicks,
  c.scp_cart_adds,
  c.scp_purchases,
  c.scp_search_traffic_sales,
  c.scp_impression_share,
  c.scp_click_share,
  c.scp_cart_share,
  c.scp_purchase_share,
  c.scp_ctr,
  c.scp_cvr,
  c.scp_impression_median_price,
  c.scp_clicked_median_price,
  c.scp_purchase_median_price,
  b.search_query_volume,
  b.brand_impression_share,
  b.brand_click_share,
  b.brand_cart_share,
  b.brand_purchase_share,
  b.brand_purchase_share_lift,
  b.query_purchase_rate,
  b.query_purchase_median_price,
  b.brand_purchase_median_price,
  coalesce(k.competitor_count,0)::int AS competitor_count,
  coalesce(k.top_competitor_click_share,0)::numeric AS top_competitor_click_share,
  coalesce(k.top_competitor_purchase_share,0)::numeric AS top_competitor_purchase_share,
  coalesce(k.competitors,'[]'::jsonb) AS competitors,
  m.ml_computed_at,
  coalesce(m.ml_cells,0)::int AS ml_cells,
  m.ml_max_click_probability,
  m.ml_avg_click_probability,
  m.ml_max_conversion_probability,
  m.ml_avg_conversion_probability,
  m.ml_max_expected_roas,
  m.ml_avg_expected_roas,
  m.ml_best_hour,
  l.as_of_date AS query_history_as_of_date,
  l.spend_7d_lag,
  l.orders_7d_lag,
  l.sales_7d_lag,
  l.roas_7d_lag,
  l.spend_14d_lag,
  l.orders_14d_lag,
  l.sales_14d_lag,
  l.roas_14d_lag,
  l.spend_28d_lag,
  l.orders_28d_lag,
  l.sales_28d_lag,
  l.roas_28d_lag,
  CASE
    WHEN m.ml_cells > 0 AND m.ml_max_expected_roas >= 4 AND coalesce(p.ebitda_margin,0) > 0 THEN 'ML_SIGNAL_WITH_MARGIN'
    WHEN m.ml_cells > 0 AND coalesce(m.ml_max_expected_roas,0) < 2 AND coalesce(a.ads_spend,0) > 0 THEN 'ML_SIGNAL_WEAK_ON_PAID_QUERY'
    WHEN coalesce(k.competitor_count,0) > 0 AND coalesce(m.ml_cells,0) = 0 THEN 'COMPETITOR_CONTEXT_NO_ML_MATCH'
    WHEN coalesce(a.ads_spend,0) > 0 AND coalesce(a.ads_sales,0) = 0 THEN 'ADS_FACT_NO_SALE'
    ELSE 'CONTEXT_ONLY'
  END AS ml_explain_label,
  (
    coalesce(m.ml_max_expected_roas,0) * 20
    + coalesce(m.ml_max_conversion_probability,0) * 35
    + coalesce(m.ml_max_click_probability,0) * 10
    + least(coalesce(p.ebitda_margin,0),0.5) * 20
    + least(coalesce(b.search_query_volume,0) / 1000.0, 1) * 10
    + least(coalesce(k.top_competitor_purchase_share,0),0.5) * 10
  )::numeric AS ml_explain_score
FROM ads a
LEFT JOIN product p ON p.asin = a.asin
LEFT JOIN catalog c ON c.asin = a.asin
LEFT JOIN brand_query b ON b.query_key = a.query_key
LEFT JOIN competitor k ON k.query_key = a.query_key
LEFT JOIN ml m ON m.campaign_id = a.campaign_id AND m.query_key = a.query_key
LEFT JOIN lag l ON l.query_key = a.query_key;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_asin_query_v1 IS
'ASIN x query com economia, Ads Search Terms, BA/SCP/SQP, concorrentes e predicoes ML. Campo ml_explain_label e explicativo; nao executa acao.';

CREATE OR REPLACE VIEW marketcloud_gold.gold_search_intelligence_ml_query_explain_v1 AS
SELECT
  asin,
  seller_sku,
  product_name,
  query_key,
  search_query,
  ml_explain_label,
  ml_explain_score,
  jsonb_build_object(
    'ml', jsonb_build_object(
      'cells', ml_cells,
      'computed_at', ml_computed_at,
      'max_click_probability', ml_max_click_probability,
      'max_conversion_probability', ml_max_conversion_probability,
      'max_expected_roas', ml_max_expected_roas,
      'best_hour', ml_best_hour
    ),
    'economics', jsonb_build_object(
      'gross_sales', gross_sales,
      'ebitda_estimated', ebitda_estimated,
      'ebitda_margin', ebitda_margin,
      'stock_available', stock_available,
      'avg_realized_price', avg_realized_price
    ),
    'ads_search_term', jsonb_build_object(
      'spend', ads_spend,
      'orders', ads_orders,
      'sales', ads_sales,
      'roas', ads_roas,
      'cpc', ads_cpc,
      'ctr', ads_ctr,
      'cvr', ads_cvr
    ),
    'query_history_lagged', jsonb_build_object(
      'as_of_date', query_history_as_of_date,
      'spend_7d_lag', spend_7d_lag,
      'orders_7d_lag', orders_7d_lag,
      'sales_7d_lag', sales_7d_lag,
      'roas_7d_lag', roas_7d_lag,
      'spend_28d_lag', spend_28d_lag,
      'orders_28d_lag', orders_28d_lag,
      'sales_28d_lag', sales_28d_lag,
      'roas_28d_lag', roas_28d_lag
    ),
    'brand_analytics', jsonb_build_object(
      'search_query_volume', search_query_volume,
      'brand_impression_share', brand_impression_share,
      'brand_click_share', brand_click_share,
      'brand_cart_share', brand_cart_share,
      'brand_purchase_share', brand_purchase_share,
      'brand_purchase_share_lift', brand_purchase_share_lift,
      'query_purchase_median_price', query_purchase_median_price
    ),
    'competitors', competitors
  ) AS explanation_json
FROM marketcloud_gold.gold_search_intelligence_asin_query_v1;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_ml_query_explain_v1 IS
'Explicacao compacta por ASIN/query. Usa predicoes ML + fatos; nao contem matriz de acao automatica.';
