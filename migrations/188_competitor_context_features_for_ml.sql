-- 188: concorrencia vira feature do ML, nao motor paralelo de decisao.
-- Remove a view de acao por regra e publica sinais numericos para treino.

DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_action_matrix_v1;
DROP VIEW IF EXISTS marketcloud_features.feature_target_competitor_context_v1;

CREATE SCHEMA IF NOT EXISTS marketcloud_features;

CREATE OR REPLACE VIEW marketcloud_features.feature_target_competitor_context_v1 AS
WITH base AS (
  SELECT
    query_key,
    max(search_query) AS search_query,
    count(DISTINCT competitor_asin) FILTER (WHERE NOT is_our_asin) AS ba_competitor_count,
    max(coalesce(competitor_click_share,0)) FILTER (WHERE NOT is_our_asin) AS ba_top_competitor_click_share,
    max(coalesce(competitor_purchase_share,0)) FILTER (WHERE NOT is_our_asin) AS ba_top_competitor_purchase_share,
    avg(coalesce(competitor_click_share,0)) FILTER (WHERE NOT is_our_asin) AS ba_avg_competitor_click_share,
    avg(coalesce(competitor_purchase_share,0)) FILTER (WHERE NOT is_our_asin) AS ba_avg_competitor_purchase_share,
    max(coalesce(search_query_volume,0)) AS ba_search_query_volume,
    max(coalesce(impression_brand_share,0)) AS ba_brand_impression_share,
    max(coalesce(click_brand_share,0)) AS ba_brand_click_share,
    max(coalesce(purchase_brand_share,0)) AS ba_brand_purchase_share,
    max(coalesce(purchase_median_price,0)) AS ba_purchase_median_price,
    max(coalesce(purchase_brand_median_price,0)) AS ba_brand_purchase_median_price,
    max(coalesce(ads_cpc,0)) AS ba_query_ads_cpc,
    max(CASE WHEN is_our_asin THEN 1 ELSE 0 END) AS ba_our_asin_in_top_results,
    max(CASE WHEN coalesce(ads_spend,0) > 0 THEN 1 ELSE 0 END) AS ba_has_our_ads_on_query
  FROM marketcloud_gold.gold_search_intelligence_competitor_radar_v1
  GROUP BY query_key
)
SELECT
  query_key,
  search_query,
  1::int AS has_ba_competitor_context,
  coalesce(ba_competitor_count,0)::numeric AS ba_competitor_count,
  coalesce(ba_top_competitor_click_share,0)::numeric AS ba_top_competitor_click_share,
  coalesce(ba_top_competitor_purchase_share,0)::numeric AS ba_top_competitor_purchase_share,
  coalesce(ba_avg_competitor_click_share,0)::numeric AS ba_avg_competitor_click_share,
  coalesce(ba_avg_competitor_purchase_share,0)::numeric AS ba_avg_competitor_purchase_share,
  coalesce(ba_search_query_volume,0)::numeric AS ba_search_query_volume,
  coalesce(ba_brand_impression_share,0)::numeric AS ba_brand_impression_share,
  coalesce(ba_brand_click_share,0)::numeric AS ba_brand_click_share,
  coalesce(ba_brand_purchase_share,0)::numeric AS ba_brand_purchase_share,
  coalesce(ba_purchase_median_price,0)::numeric AS ba_purchase_median_price,
  coalesce(ba_brand_purchase_median_price,0)::numeric AS ba_brand_purchase_median_price,
  coalesce(ba_query_ads_cpc,0)::numeric AS ba_query_ads_cpc,
  coalesce(ba_our_asin_in_top_results,0)::numeric AS ba_our_asin_in_top_results,
  coalesce(ba_has_our_ads_on_query,0)::numeric AS ba_has_our_ads_on_query
FROM base;

COMMENT ON VIEW marketcloud_features.feature_target_competitor_context_v1 IS
'Features de concorrencia por query/termo para o ML. Nao recomenda acao; apenas fornece sinais numericos do Brand Analytics e Ads.';
