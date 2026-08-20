-- 182: Brand Analytics - Search Query Brand Performance (Exibicao de marca Abrangente).
-- Fonte inicial: CSV oficial exportado do Seller Central enquanto a SP-API nao
-- entrega esse report no mesmo formato. Mantem raw_json_sanitized e field-level.

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_brand_analytics_search_query_brand_performance (
    report_id text,
    source_file text,
    brand text,
    period text,
    period_start date,
    period_end date,
    search_query text,
    query_score numeric,
    search_query_volume numeric,
    impression_total_count numeric,
    impression_brand_count numeric,
    impression_brand_share numeric,
    click_total_count numeric,
    click_rate numeric,
    click_brand_count numeric,
    click_brand_share numeric,
    click_median_price numeric,
    click_brand_avg_price numeric,
    same_day_shipping_click_count numeric,
    one_day_shipping_click_count numeric,
    two_day_shipping_click_count numeric,
    cart_add_total_count numeric,
    cart_add_rate numeric,
    cart_add_brand_count numeric,
    cart_add_brand_share numeric,
    cart_add_median_price numeric,
    cart_add_brand_median_price numeric,
    same_day_shipping_cart_add_count numeric,
    one_day_shipping_cart_add_count numeric,
    two_day_shipping_cart_add_count numeric,
    purchase_total_count numeric,
    purchase_rate numeric,
    purchase_brand_count numeric,
    purchase_brand_share numeric,
    purchase_median_price numeric,
    purchase_brand_median_price numeric,
    same_day_shipping_purchase_count numeric,
    one_day_shipping_purchase_count numeric,
    two_day_shipping_purchase_count numeric,
    report_date date,
    raw_json_sanitized jsonb,
    synced_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_brand_analytics_search_query_brand_performance');

CREATE OR REPLACE VIEW marketcloud_bronze.bronze_brand_analytics_search_query_brand_performance_v1 AS
SELECT *
FROM swarm_src.amazon_brand_analytics_search_query_brand_performance;

CREATE OR REPLACE VIEW marketcloud_gold.gold_brand_analytics_brand_query_comprehensive_v1 AS
SELECT report_id,
       source_file,
       brand,
       period,
       period_start,
       period_end,
       search_query,
       query_score,
       search_query_volume,
       impression_total_count,
       impression_brand_count,
       impression_brand_share,
       click_total_count,
       click_rate,
       click_brand_count,
       click_brand_share,
       click_median_price,
       click_brand_avg_price,
       same_day_shipping_click_count,
       one_day_shipping_click_count,
       two_day_shipping_click_count,
       cart_add_total_count,
       cart_add_rate,
       cart_add_brand_count,
       cart_add_brand_share,
       cart_add_median_price,
       cart_add_brand_median_price,
       same_day_shipping_cart_add_count,
       one_day_shipping_cart_add_count,
       two_day_shipping_cart_add_count,
       purchase_total_count,
       purchase_rate,
       purchase_brand_count,
       purchase_brand_share,
       purchase_median_price,
       purchase_brand_median_price,
       same_day_shipping_purchase_count,
       one_day_shipping_purchase_count,
       two_day_shipping_purchase_count,
       CASE
         WHEN COALESCE(impression_brand_share,0) > 0
           THEN (COALESCE(purchase_brand_share,0) - COALESCE(impression_brand_share,0))::numeric
         ELSE NULL
       END AS brand_purchase_share_lift,
       CASE
         WHEN COALESCE(search_query_volume,0) > 0
           THEN (COALESCE(purchase_brand_count,0) / NULLIF(search_query_volume,0))::numeric
         ELSE NULL
       END AS brand_purchase_per_query,
       report_date,
       raw_json_sanitized,
       synced_at
FROM marketcloud_bronze.bronze_brand_analytics_search_query_brand_performance_v1;

CREATE OR REPLACE VIEW marketcloud_bronze.bronze_brand_analytics_search_query_brand_field_v1 AS
WITH RECURSIVE fields AS (
  SELECT report_id,
         brand,
         period,
         period_start,
         period_end,
         search_query,
         ARRAY[]::text[] AS field_path_parts,
         raw_json_sanitized AS field_json
  FROM swarm_src.amazon_brand_analytics_search_query_brand_performance

  UNION ALL

  SELECT f.report_id,
         f.brand,
         f.period,
         f.period_start,
         f.period_end,
         f.search_query,
         f.field_path_parts || e.key,
         e.value
  FROM fields f
  CROSS JOIN LATERAL jsonb_each(f.field_json) e
  WHERE jsonb_typeof(f.field_json) = 'object'
)
SELECT report_id,
       brand,
       period,
       period_start,
       period_end,
       search_query,
       array_to_string(field_path_parts, '.') AS field_path,
       field_json,
       CASE
         WHEN jsonb_typeof(field_json) IN ('string','number','boolean') THEN field_json #>> '{}'
         ELSE field_json::text
       END AS field_value_text,
       CASE
         WHEN jsonb_typeof(field_json) = 'number' THEN (field_json #>> '{}')::numeric
         ELSE NULL
       END AS field_value_numeric
FROM fields
WHERE array_length(field_path_parts, 1) IS NOT NULL
  AND jsonb_typeof(field_json) <> 'object';

COMMENT ON VIEW marketcloud_gold.gold_brand_analytics_brand_query_comprehensive_v1 IS
'Relatorio Brand Analytics Exibicao de marca Abrangente por query/marca. Percentuais normalizados para decimal.';

COMMENT ON VIEW marketcloud_bronze.bronze_brand_analytics_search_query_brand_field_v1 IS
'Explode 100% dos campos raw_json_sanitized do relatorio Exibicao de marca Abrangente.';
