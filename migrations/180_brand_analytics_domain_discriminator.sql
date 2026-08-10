-- 180: separa semanticamente Search Terms de mercado e SQP proprietario.
-- A mesma tabela fisica no SWARM recebe ambos os relatorios, mas as gold views
-- nao podem misturar share de concorrentes com funil proprietario dos ASINs ZANOM.

ALTER FOREIGN TABLE swarm_src.amazon_brand_analytics_search_query_performance
  ADD COLUMN IF NOT EXISTS source_report_type text;

ALTER FOREIGN TABLE swarm_src.amazon_brand_analytics_search_query_performance
  ADD COLUMN IF NOT EXISTS data_domain text;

ALTER FOREIGN TABLE swarm_src.amazon_brand_analytics_search_catalog_performance
  ADD COLUMN IF NOT EXISTS source_report_type text;

ALTER FOREIGN TABLE swarm_src.amazon_brand_analytics_search_catalog_performance
  ADD COLUMN IF NOT EXISTS data_domain text;

CREATE OR REPLACE VIEW marketcloud_silver.silver_brand_analytics_query_product_v1 AS
SELECT asin,
       period,
       period_start,
       period_end,
       COUNT(*)::int AS query_count,
       SUM(COALESCE(impressions,0))::numeric AS query_impressions,
       SUM(COALESCE(clicks,0))::numeric AS query_clicks,
       SUM(COALESCE(cart_adds,0))::numeric AS query_cart_adds,
       SUM(COALESCE(purchases,0))::numeric AS query_purchases,
       AVG(NULLIF(brand_impression_share,0))::numeric AS avg_brand_impression_share,
       AVG(NULLIF(brand_click_share,0))::numeric AS avg_brand_click_share,
       AVG(NULLIF(brand_cart_add_share,0))::numeric AS avg_brand_cart_add_share,
       AVG(NULLIF(brand_purchase_share,0))::numeric AS avg_brand_purchase_share,
       jsonb_agg(
         jsonb_build_object(
           'search_query', search_query,
           'query_rank', query_rank,
           'impressions', impressions,
           'clicks', clicks,
           'cart_adds', cart_adds,
           'purchases', purchases,
           'brand_purchase_share', brand_purchase_share
         )
         ORDER BY COALESCE(query_rank, 999999), COALESCE(purchases,0) DESC, COALESCE(clicks,0) DESC
       ) FILTER (WHERE search_query IS NOT NULL) AS top_queries,
       MAX(synced_at) AS refreshed_at
FROM swarm_src.amazon_brand_analytics_search_query_performance
WHERE COALESCE(asin,'') <> ''
  AND COALESCE(data_domain, 'PROPRIETARY_SEARCH_QUERY') = 'PROPRIETARY_SEARCH_QUERY'
GROUP BY 1,2,3,4;

CREATE OR REPLACE VIEW marketcloud_gold.gold_brand_analytics_market_query_v1 AS
WITH ours AS (
  SELECT DISTINCT asin
  FROM marketcloud_gold.dim_ba_brand_asin_v1
  WHERE COALESCE(asin,'') ILIKE 'B0%'
),
ranked AS (
  SELECT search_query,
         asin,
         raw_json_sanitized->>'clickedItemName' AS item_name,
         query_rank,
         brand_click_share,
         brand_purchase_share,
         period_start,
         period_end,
         ROW_NUMBER() OVER (
           PARTITION BY search_query
           ORDER BY COALESCE(brand_purchase_share,0) DESC,
                    COALESCE(brand_click_share,0) DESC,
                    asin
         ) AS asin_rank
  FROM swarm_src.amazon_brand_analytics_search_query_performance
  WHERE COALESCE(search_query,'') <> ''
    AND COALESCE(data_domain, 'MARKET_SEARCH_TERMS') = 'MARKET_SEARCH_TERMS'
),
summary AS (
  SELECT search_query,
         MIN(query_rank)::int AS best_rank,
         COUNT(DISTINCT asin)::int AS asin_count,
         COUNT(DISTINCT asin) FILTER (WHERE asin IN (SELECT asin FROM ours))::int AS our_asin_count,
         AVG(NULLIF(brand_click_share,0))::numeric AS avg_click_share,
         AVG(NULLIF(brand_purchase_share,0))::numeric AS avg_purchase_share,
         MIN(period_start) AS period_start,
         MAX(period_end) AS period_end
  FROM ranked
  GROUP BY search_query
)
SELECT s.search_query,
       s.best_rank,
       s.asin_count,
       s.our_asin_count,
       s.avg_click_share,
       s.avg_purchase_share,
       s.period_start,
       s.period_end,
       COALESCE(
         jsonb_agg(
           jsonb_build_object(
             'asin', r.asin,
             'item_name', r.item_name,
             'click_share', r.brand_click_share,
             'purchase_share', r.brand_purchase_share,
             'rank', r.query_rank
           )
           ORDER BY r.asin_rank
         ) FILTER (WHERE r.asin_rank <= 5),
         '[]'::jsonb
       ) AS top_asins
FROM summary s
LEFT JOIN ranked r ON r.search_query = s.search_query AND r.asin_rank <= 5
GROUP BY s.search_query, s.best_rank, s.asin_count, s.our_asin_count,
         s.avg_click_share, s.avg_purchase_share, s.period_start, s.period_end;

COMMENT ON VIEW marketcloud_silver.silver_brand_analytics_query_product_v1 IS
'SQP proprietario por ASIN/query. Filtra data_domain=PROPRIETARY_SEARCH_QUERY para nao misturar Search Terms de mercado.';

COMMENT ON VIEW marketcloud_gold.gold_brand_analytics_market_query_v1 IS
'Brand Analytics Search Terms agregado por termo. Filtra data_domain=MARKET_SEARCH_TERMS; mostra demanda de mercado e concorrentes clicados, nao funil proprietario dos ASINs ZANOM.';
