-- 178: Brand Analytics oficial (SP-API Reports API) no lake do MarketCloud.
-- A origem real fica no SWARM/mercado-data-app; o MarketCloud consome por FDW
-- e publica silver/gold sem mockar share de busca.

CREATE SCHEMA IF NOT EXISTS swarm_src;
CREATE SCHEMA IF NOT EXISTS marketcloud_bronze;
CREATE SCHEMA IF NOT EXISTS marketcloud_silver;
CREATE SCHEMA IF NOT EXISTS marketcloud_gold;

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_brand_analytics_report_jobs (
    id text,
    report_id text,
    report_document_id text,
    report_type text,
    period text,
    date_from date,
    date_to date,
    marketplace_id text,
    status text,
    requested_at timestamptz,
    last_poll_at timestamptz,
    completed_at timestamptz,
    downloaded_at timestamptz,
    processed_at timestamptz,
    attempt_count integer,
    safe_error_detail text,
    raw_request_json_sanitized jsonb,
    raw_response_json_sanitized jsonb
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_brand_analytics_report_jobs');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_brand_analytics_search_query_performance (
    report_id text,
    source_report_type text,
    data_domain text,
    period text,
    period_start date,
    period_end date,
    marketplace_id text,
    asin text,
    search_query text,
    query_rank integer,
    impressions numeric,
    clicks numeric,
    cart_adds numeric,
    purchases numeric,
    brand_impression_share numeric,
    brand_click_share numeric,
    brand_cart_add_share numeric,
    brand_purchase_share numeric,
    raw_json_sanitized jsonb,
    synced_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_brand_analytics_search_query_performance');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_brand_analytics_search_catalog_performance (
    report_id text,
    source_report_type text,
    data_domain text,
    period text,
    period_start date,
    period_end date,
    marketplace_id text,
    asin text,
    impressions numeric,
    clicks numeric,
    cart_adds numeric,
    purchases numeric,
    brand_impression_share numeric,
    brand_click_share numeric,
    brand_cart_add_share numeric,
    brand_purchase_share numeric,
    raw_json_sanitized jsonb,
    synced_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_brand_analytics_search_catalog_performance');

DROP VIEW IF EXISTS marketcloud_gold.gold_brand_analytics_product_period_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_silver.silver_brand_analytics_catalog_product_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_silver.silver_brand_analytics_query_product_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_bronze.bronze_brand_analytics_search_catalog_performance_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_bronze.bronze_brand_analytics_search_query_performance_v1 CASCADE;

CREATE VIEW marketcloud_bronze.bronze_brand_analytics_search_query_performance_v1 AS
SELECT *
FROM swarm_src.amazon_brand_analytics_search_query_performance;

CREATE VIEW marketcloud_bronze.bronze_brand_analytics_search_catalog_performance_v1 AS
SELECT *
FROM swarm_src.amazon_brand_analytics_search_catalog_performance;

CREATE VIEW marketcloud_silver.silver_brand_analytics_query_product_v1 AS
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
FROM marketcloud_bronze.bronze_brand_analytics_search_query_performance_v1
WHERE COALESCE(asin,'') <> ''
  AND COALESCE(data_domain, 'PROPRIETARY_SEARCH_QUERY') = 'PROPRIETARY_SEARCH_QUERY'
GROUP BY 1,2,3,4;

CREATE VIEW marketcloud_silver.silver_brand_analytics_catalog_product_v1 AS
SELECT asin,
       period,
       period_start,
       period_end,
       SUM(COALESCE(impressions,0))::numeric AS catalog_impressions,
       SUM(COALESCE(clicks,0))::numeric AS catalog_clicks,
       SUM(COALESCE(cart_adds,0))::numeric AS catalog_cart_adds,
       SUM(COALESCE(purchases,0))::numeric AS catalog_purchases,
       AVG(NULLIF(brand_impression_share,0))::numeric AS brand_impression_share,
       AVG(NULLIF(brand_click_share,0))::numeric AS brand_click_share,
       AVG(NULLIF(brand_cart_add_share,0))::numeric AS brand_cart_add_share,
       AVG(NULLIF(brand_purchase_share,0))::numeric AS brand_purchase_share,
       MAX(synced_at) AS refreshed_at
FROM marketcloud_bronze.bronze_brand_analytics_search_catalog_performance_v1
WHERE COALESCE(asin,'') <> ''
GROUP BY 1,2,3,4;

CREATE VIEW marketcloud_gold.gold_brand_analytics_product_period_v1 AS
SELECT COALESCE(c.asin, q.asin) AS asin,
       COALESCE(c.period, q.period) AS period,
       COALESCE(c.period_start, q.period_start) AS period_start,
       COALESCE(c.period_end, q.period_end) AS period_end,
       COALESCE(q.query_count,0)::int AS query_count,
       COALESCE(q.query_impressions, c.catalog_impressions, 0)::numeric AS impressions,
       COALESCE(q.query_clicks, c.catalog_clicks, 0)::numeric AS clicks,
       COALESCE(q.query_cart_adds, c.catalog_cart_adds, 0)::numeric AS cart_adds,
       COALESCE(q.query_purchases, c.catalog_purchases, 0)::numeric AS purchases,
       COALESCE(c.brand_impression_share, q.avg_brand_impression_share)::numeric AS ba_impression_share,
       COALESCE(c.brand_click_share, q.avg_brand_click_share)::numeric AS ba_click_share,
       COALESCE(c.brand_cart_add_share, q.avg_brand_cart_add_share)::numeric AS ba_cart_share,
       COALESCE(c.brand_purchase_share, q.avg_brand_purchase_share)::numeric AS ba_purchase_share,
       CASE
         WHEN COALESCE(c.brand_purchase_share, q.avg_brand_purchase_share) IS NOT NULL
              AND COALESCE(c.brand_impression_share, q.avg_brand_impression_share) IS NOT NULL
           THEN (COALESCE(c.brand_purchase_share, q.avg_brand_purchase_share) - COALESCE(c.brand_impression_share, q.avg_brand_impression_share))::numeric
         ELSE NULL
       END AS ba_purchase_share_lift,
       CASE WHEN COALESCE(q.query_clicks, c.catalog_clicks, 0) > 0
         THEN (COALESCE(q.query_purchases, c.catalog_purchases, 0) / NULLIF(COALESCE(q.query_clicks, c.catalog_clicks, 0),0))::numeric
         ELSE NULL
       END AS ba_search_conversion,
       COALESCE(q.top_queries, '[]'::jsonb) AS top_queries,
       GREATEST(COALESCE(c.refreshed_at, 'epoch'::timestamptz), COALESCE(q.refreshed_at, 'epoch'::timestamptz)) AS refreshed_at,
       'BRAND_ANALYTICS_' || COALESCE(c.period, q.period) AS ba_coverage_status
FROM marketcloud_silver.silver_brand_analytics_catalog_product_v1 c
FULL JOIN marketcloud_silver.silver_brand_analytics_query_product_v1 q
  ON q.asin = c.asin
 AND q.period = c.period
 AND q.period_start = c.period_start
 AND q.period_end = c.period_end;

COMMENT ON VIEW marketcloud_gold.gold_brand_analytics_product_period_v1 IS
'Brand Analytics oficial por produto/periodo (WEEK/MONTH/QUARTER). E usado para enriquecer Search Intelligence; nao e dado diario nativo.';
