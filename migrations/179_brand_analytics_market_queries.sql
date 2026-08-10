-- 179: leitura de demanda/concorrencia por query via Brand Analytics Search Terms.
-- Mantem payload pequeno para a UI: cada query traz no maximo 5 ASINs lideres.

CREATE SCHEMA IF NOT EXISTS marketcloud_gold;

DROP VIEW IF EXISTS marketcloud_gold.gold_brand_analytics_market_query_v1 CASCADE;

CREATE VIEW marketcloud_gold.gold_brand_analytics_market_query_v1 AS
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
  FROM marketcloud_bronze.bronze_brand_analytics_search_query_performance_v1
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

COMMENT ON VIEW marketcloud_gold.gold_brand_analytics_market_query_v1 IS
'Brand Analytics Search Terms agregado por termo. Mostra demanda de mercado e concorrentes clicados; nao e funil proprietario dos ASINs ZANOM.';
