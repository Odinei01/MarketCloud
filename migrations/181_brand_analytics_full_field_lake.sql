-- 181: Brand Analytics 100% field lake.
-- Campos canônicos do Search Catalog Performance (SCP) + views field-level
-- para nenhum campo bruto do report ficar fora do Lake.

ALTER FOREIGN TABLE swarm_src.amazon_brand_analytics_search_catalog_performance
  ADD COLUMN IF NOT EXISTS impression_median_price numeric,
  ADD COLUMN IF NOT EXISTS same_day_shipping_impression_count numeric,
  ADD COLUMN IF NOT EXISTS one_day_shipping_impression_count numeric,
  ADD COLUMN IF NOT EXISTS two_day_shipping_impression_count numeric,
  ADD COLUMN IF NOT EXISTS click_rate numeric,
  ADD COLUMN IF NOT EXISTS clicked_median_price numeric,
  ADD COLUMN IF NOT EXISTS same_day_shipping_click_count numeric,
  ADD COLUMN IF NOT EXISTS one_day_shipping_click_count numeric,
  ADD COLUMN IF NOT EXISTS two_day_shipping_click_count numeric,
  ADD COLUMN IF NOT EXISTS cart_added_median_price numeric,
  ADD COLUMN IF NOT EXISTS same_day_shipping_cart_add_count numeric,
  ADD COLUMN IF NOT EXISTS one_day_shipping_cart_add_count numeric,
  ADD COLUMN IF NOT EXISTS two_day_shipping_cart_add_count numeric,
  ADD COLUMN IF NOT EXISTS search_traffic_sales numeric,
  ADD COLUMN IF NOT EXISTS conversion_rate numeric,
  ADD COLUMN IF NOT EXISTS purchase_median_price numeric,
  ADD COLUMN IF NOT EXISTS same_day_shipping_purchase_count numeric,
  ADD COLUMN IF NOT EXISTS one_day_shipping_purchase_count numeric,
  ADD COLUMN IF NOT EXISTS two_day_shipping_purchase_count numeric;

CREATE OR REPLACE VIEW marketcloud_bronze.bronze_brand_analytics_search_catalog_field_v1 AS
WITH RECURSIVE fields AS (
  SELECT report_id,
         source_report_type,
         data_domain,
         period,
         period_start,
         period_end,
         marketplace_id,
         asin,
         ARRAY[]::text[] AS field_path_parts,
         raw_json_sanitized AS field_json
  FROM swarm_src.amazon_brand_analytics_search_catalog_performance

  UNION ALL

  SELECT f.report_id,
         f.source_report_type,
         f.data_domain,
         f.period,
         f.period_start,
         f.period_end,
         f.marketplace_id,
         f.asin,
         f.field_path_parts || e.key,
         e.value
  FROM fields f
  CROSS JOIN LATERAL jsonb_each(f.field_json) e
  WHERE jsonb_typeof(f.field_json) = 'object'
)
SELECT report_id,
       source_report_type,
       data_domain,
       period,
       period_start,
       period_end,
       marketplace_id,
       asin,
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

CREATE OR REPLACE VIEW marketcloud_bronze.bronze_brand_analytics_search_query_field_v1 AS
WITH RECURSIVE fields AS (
  SELECT report_id,
         source_report_type,
         data_domain,
         period,
         period_start,
         period_end,
         marketplace_id,
         asin,
         search_query,
         ARRAY[]::text[] AS field_path_parts,
         raw_json_sanitized AS field_json
  FROM swarm_src.amazon_brand_analytics_search_query_performance

  UNION ALL

  SELECT f.report_id,
         f.source_report_type,
         f.data_domain,
         f.period,
         f.period_start,
         f.period_end,
         f.marketplace_id,
         f.asin,
         f.search_query,
         f.field_path_parts || e.key,
         e.value
  FROM fields f
  CROSS JOIN LATERAL jsonb_each(f.field_json) e
  WHERE jsonb_typeof(f.field_json) = 'object'
)
SELECT report_id,
       source_report_type,
       data_domain,
       period,
       period_start,
       period_end,
       marketplace_id,
       asin,
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

CREATE OR REPLACE VIEW marketcloud_gold.gold_brand_analytics_search_catalog_full_v1 AS
SELECT *
FROM swarm_src.amazon_brand_analytics_search_catalog_performance;

COMMENT ON VIEW marketcloud_bronze.bronze_brand_analytics_search_catalog_field_v1 IS
'Explode 100% dos campos raw_json_sanitized do Brand Analytics SCP em field_path/value.';

COMMENT ON VIEW marketcloud_bronze.bronze_brand_analytics_search_query_field_v1 IS
'Explode 100% dos campos raw_json_sanitized dos reports BA de query/Search Terms em field_path/value.';

COMMENT ON VIEW marketcloud_gold.gold_brand_analytics_search_catalog_full_v1 IS
'SCP por ASIN com todas as colunas canônicas atuais e raw_json_sanitized completo.';
