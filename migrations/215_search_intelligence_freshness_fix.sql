-- 215: Search Intelligence freshness fix.
--
-- 1) Ads Search Terms: use the fresher SWARM/pricing source when it has dates
--    newer than MarketCloud AMC/silver. This keeps the canonical Gold shape and
--    avoids duplicate days.
-- 2) Brand/market query: the old "brand query comprehensive" CSV/SP-API source
--    only exists up to 2026-08-08. Repoint the compatible Gold view to the E003
--    Search Terms market source, which is the fresh market/competitor source.
--    Fields not present in E003 stay NULL/0 instead of being invented.
-- 3) Refresh functions must refresh the cached MVs that the UI reads.

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_ads_search_terms_daily (
    id bigint,
    date date,
    profile_id text,
    campaign_id text,
    campaign_name text,
    ad_group_id text,
    ad_group_name text,
    keyword_id text,
    keyword_text text,
    match_type text,
    search_term text,
    targeting text,
    impressions integer,
    clicks integer,
    cost numeric,
    attributed_sales numeric,
    purchases integer,
    units_sold integer,
    cpc numeric,
    ctr numeric,
    acos numeric,
    roas numeric,
    suggested_action text,
    recommendation_reason text,
    currency text,
    report_id text,
    synced_at timestamptz,
    raw_snapshot_json_sanitized jsonb
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_ads_search_terms_daily');

CREATE OR REPLACE VIEW marketcloud_gold.gold_brand_analytics_brand_query_comprehensive_v1 AS
WITH ranked AS (
  SELECT
    report_id,
    period,
    period_start,
    period_end,
    search_term AS search_query,
    search_frequency_rank AS query_score,
    search_frequency_rank,
    clicked_asin,
    clicked_item_name,
    click_share_rank,
    click_share,
    conversion_share,
    raw_json_sanitized,
    synced_at,
    row_number() OVER (
      PARTITION BY period_start, period_end, search_term
      ORDER BY COALESCE(conversion_share,0) DESC,
               COALESCE(click_share,0) DESC,
               COALESCE(click_share_rank,999999),
               clicked_asin
    ) AS rn
  FROM swarm_src.amazon_brand_analytics_search_terms
  WHERE COALESCE(search_term,'') <> ''
),
agg AS (
  SELECT
    min(report_id) AS report_id,
    'SEARCH_TERMS_E003'::text AS source_file,
    'MARKET'::text AS brand,
    max(period) AS period,
    period_start,
    period_end,
    search_query,
    min(query_score)::numeric AS query_score,
    NULL::numeric AS search_query_volume,
    NULL::numeric AS impression_total_count,
    NULL::numeric AS impression_brand_count,
    NULL::numeric AS impression_brand_share,
    NULL::numeric AS click_total_count,
    NULL::numeric AS click_rate,
    COALESCE(sum(click_share) FILTER (WHERE rn <= 3), 0)::numeric AS click_brand_count,
    max(click_share) FILTER (WHERE rn = 1)::numeric AS click_brand_share,
    NULL::numeric AS click_median_price,
    NULL::numeric AS click_brand_avg_price,
    NULL::numeric AS cart_add_total_count,
    NULL::numeric AS cart_add_rate,
    NULL::numeric AS cart_add_brand_count,
    NULL::numeric AS cart_add_brand_share,
    NULL::numeric AS cart_add_median_price,
    NULL::numeric AS cart_add_brand_median_price,
    NULL::numeric AS purchase_total_count,
    NULL::numeric AS purchase_rate,
    COALESCE(sum(conversion_share) FILTER (WHERE rn <= 3), 0)::numeric AS purchase_brand_count,
    max(conversion_share) FILTER (WHERE rn = 1)::numeric AS purchase_brand_share,
    NULL::numeric AS purchase_median_price,
    NULL::numeric AS purchase_brand_median_price,
    max(period_end)::date AS report_date,
    jsonb_build_object(
      'source', 'amazon_brand_analytics_search_terms',
      'note', 'E003 market source. Volume and full funnel counts are not present in this report.',
      'top_asins',
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'asin', clicked_asin,
            'item_name', clicked_item_name,
            'rank', click_share_rank,
            'click_share', click_share,
            'conversion_share', conversion_share
          )
          ORDER BY rn
        ) FILTER (WHERE rn <= 5),
        '[]'::jsonb
      )
    ) AS raw_json_sanitized,
    max(synced_at) AS synced_at
  FROM ranked
  GROUP BY period_start, period_end, search_query
)
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
       NULL::numeric AS same_day_shipping_click_count,
       NULL::numeric AS one_day_shipping_click_count,
       NULL::numeric AS two_day_shipping_click_count,
       cart_add_total_count,
       cart_add_rate,
       cart_add_brand_count,
       cart_add_brand_share,
       cart_add_median_price,
       cart_add_brand_median_price,
       NULL::numeric AS same_day_shipping_cart_add_count,
       NULL::numeric AS one_day_shipping_cart_add_count,
       NULL::numeric AS two_day_shipping_cart_add_count,
       purchase_total_count,
       purchase_rate,
       purchase_brand_count,
       purchase_brand_share,
       purchase_median_price,
       purchase_brand_median_price,
       NULL::numeric AS same_day_shipping_purchase_count,
       NULL::numeric AS one_day_shipping_purchase_count,
       NULL::numeric AS two_day_shipping_purchase_count,
       CASE
         WHEN COALESCE(impression_brand_share,0) > 0
           THEN (COALESCE(purchase_brand_share,0) - COALESCE(impression_brand_share,0))::numeric
         ELSE NULL
       END AS brand_purchase_share_lift,
       NULL::numeric AS brand_purchase_per_query,
       report_date,
       raw_json_sanitized,
       synced_at
FROM agg;

COMMENT ON VIEW marketcloud_gold.gold_brand_analytics_brand_query_comprehensive_v1 IS
'Fresh market-query compatibility layer backed by BA Search Terms E003. Missing comprehensive-only volume/funnel fields remain NULL instead of being invented.';

CREATE OR REPLACE VIEW marketcloud_gold.gold_ads_search_term_daily_v1 AS
WITH silver_max AS (
  SELECT max(data_date) AS max_data_date
  FROM marketcloud_silver.silver_search_term_daily
),
source_rows AS (
  SELECT s.tenant_id,
         s.data_date,
         s.ads_profile_id,
         s.campaign_id,
         s.campaign_name,
         s.ad_product_type,
         s.ad_group_name,
         s.targeting,
         s.match_type,
         s.customer_search_term,
         s.search_term_normalized,
         s.impressions,
         s.clicks,
         s.spend,
         s.cpc,
         s.orders,
         s.sales,
         s.acos,
         s.roas,
         s.ctr,
         s.conversion_rate,
         s.loaded_at
  FROM marketcloud_silver.silver_search_term_daily s

  UNION ALL

  SELECT NULL::text AS tenant_id,
         p.date AS data_date,
         p.profile_id AS ads_profile_id,
         p.campaign_id,
         p.campaign_name,
         'SPONSORED_PRODUCTS'::text AS ad_product_type,
         p.ad_group_name,
         COALESCE(NULLIF(TRIM(p.targeting), ''), NULLIF(TRIM(p.keyword_text), '')) AS targeting,
         p.match_type,
         p.search_term AS customer_search_term,
         lower(btrim(unaccent(COALESCE(p.search_term,'')))) AS search_term_normalized,
         COALESCE(p.impressions,0)::numeric AS impressions,
         COALESCE(p.clicks,0)::numeric AS clicks,
         COALESCE(p.cost,0)::numeric AS spend,
         p.cpc::numeric AS cpc,
         COALESCE(p.purchases,0)::numeric AS orders,
         COALESCE(p.attributed_sales,0)::numeric AS sales,
         p.acos::numeric AS acos,
         p.roas::numeric AS roas,
         p.ctr::numeric AS ctr,
         CASE WHEN COALESCE(p.clicks,0) > 0 THEN COALESCE(p.purchases,0)::numeric / NULLIF(p.clicks,0) ELSE NULL END AS conversion_rate,
         p.synced_at::timestamp AS loaded_at
  FROM swarm_src.amazon_ads_search_terms_daily p
  CROSS JOIN silver_max sm
  WHERE sm.max_data_date IS NULL OR p.date > sm.max_data_date
),
campaign_asin AS (
  SELECT date,
         profile_id,
         campaign_id,
         NULLIF(TRIM(ad_group_name), '') AS ad_group_name,
         MAX(NULLIF(TRIM(advertised_asin), '')) AS advertised_asin,
         MAX(NULLIF(TRIM(advertised_sku), '')) AS advertised_sku,
         MAX(top_of_search_bid_adjustment)::numeric AS top_of_search_bid_adjustment
  FROM swarm_src.amazon_ads_campaigns_daily
  GROUP BY date, profile_id, campaign_id, NULLIF(TRIM(ad_group_name), '')
),
inventory_asin AS (
  SELECT profile_id,
         campaign_id,
         NULLIF(TRIM(ad_group_name), '') AS ad_group_name,
         MAX(
           CASE
             WHEN target_expression ~ 'B0[A-Z0-9]{8}' THEN substring(target_expression from '(B0[A-Z0-9]{8})')
             WHEN resolved_expression ~ 'B0[A-Z0-9]{8}' THEN substring(resolved_expression from '(B0[A-Z0-9]{8})')
             WHEN raw_payload::text ~ 'B0[A-Z0-9]{8}' THEN substring(raw_payload::text from '(B0[A-Z0-9]{8})')
             ELSE NULL
           END
         ) AS inferred_asin
  FROM swarm_src.amazon_ads_targeting_inventory
  GROUP BY profile_id, campaign_id, NULLIF(TRIM(ad_group_name), '')
),
adgroup_inventory_asin AS (
  SELECT profile_id,
         campaign_id,
         NULLIF(TRIM(ad_group_name), '') AS ad_group_name,
         MAX(CASE WHEN ad_group_name ~ 'B0[A-Z0-9]{8}' THEN substring(ad_group_name from '(B0[A-Z0-9]{8})') END) AS adgroup_asin
  FROM swarm_src.amazon_ads_targeting_inventory
  GROUP BY profile_id, campaign_id, NULLIF(TRIM(ad_group_name), '')
),
legacy_campaign_alias AS (
  SELECT *
  FROM (VALUES
    ('Abridor de Vinho'::text, 'B0H2TXK1YG'::text, 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'::text),
    ('Vinho automatica', 'B0H2TXK1YG', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Seladora', 'B0H2SRPWF9', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Forma Silicone', 'B0H2VVZ73C', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Forma Silicone_PAUSED', 'B0H2VVZ73C', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Hub USB', 'B0H2TBRYQR', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('PAUSED_Hub USB', 'B0H2TBRYQR', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Suporte de Celular', 'B0H2QWNRSB', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Suporte de Celular_PAUSED', 'B0H2QWNRSB', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Porta Capsula de Café', 'B0HBLS7BPG', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Cozedor de ovos', 'B0HBZJG89G', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Moedor de Cafe', 'B0H9BXSH35', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Parafusadeira Ampla', 'B0HB7671Z1', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Carregador 30W', 'B0H2SLZ9XC', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('PAUSED_Carregador 30W', 'B0H2SLZ9XC', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Carregadores 30W', 'B0H2SLZ9XC', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Carregadores 20W', 'B0H2XNTDVL', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Carregador 20W - Dual', 'B0H2XNTDVL', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Automatica -Carregador 20W', 'B0H2XNTDVL', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Carregadores Automatica 20W USB-C - USB', 'B0H2XNTDVL', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Fone', 'B0H2ZBJ727', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('KIt Perfume portátil', 'B0H4YK4S3H', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Esponja Gota', 'B0H4ZS8F5R', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('PAUSED_Esponja Gota', 'B0H4ZS8F5R', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Kit Kadukli Manga', 'B0H4ZY78D4', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Afiador de facas', 'B0H2NJSMNW', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Pau de Selfie', 'B0H2TV1X2G', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE'),
    ('Pau de Selfie_PAUSED', 'B0H2TV1X2G', 'LEGACY_CAMPAIGN_ALIAS_UNIQUE')
  ) AS v(campaign_name, asin, resolution_reason)
)
SELECT s.tenant_id,
       s.data_date,
       s.ads_profile_id AS profile_id,
       s.campaign_id,
       s.campaign_name,
       s.ad_product_type,
       s.ad_group_name,
       COALESCE(
         c.advertised_asin,
         CASE WHEN s.ad_group_name ~ 'B0[A-Z0-9]{8}' THEN substring(s.ad_group_name from '(B0[A-Z0-9]{8})') END,
         a.adgroup_asin,
         i.inferred_asin,
         l.asin
       ) AS asin,
       c.advertised_sku AS seller_sku,
       s.targeting AS keyword_or_target,
       s.match_type,
       s.customer_search_term,
       s.search_term_normalized,
       s.impressions::numeric AS impressions,
       s.clicks::numeric AS clicks,
       s.spend::numeric AS spend,
       s.cpc::numeric AS cpc,
       s.orders::numeric AS ads_orders,
       s.sales::numeric AS ads_sales,
       s.acos::numeric AS acos,
       s.roas::numeric AS roas,
       s.ctr::numeric AS ctr,
       s.conversion_rate::numeric AS conversion_rate,
       NULL::text AS placement,
       c.top_of_search_bid_adjustment,
       CASE
         WHEN c.advertised_asin IS NOT NULL THEN 'ASIN_RESOLVED_ADS_PRODUCT'
         WHEN s.ad_group_name ~ 'B0[A-Z0-9]{8}' THEN 'ASIN_RESOLVED_ADGROUP_NAME'
         WHEN a.adgroup_asin IS NOT NULL THEN 'ASIN_RESOLVED_INVENTORY_ADGROUP'
         WHEN i.inferred_asin IS NOT NULL THEN 'ASIN_RESOLVED_TARGET_EXPRESSION'
         WHEN l.asin IS NOT NULL THEN 'ASIN_INFERRED_BY_ALIAS'
         ELSE 'ASIN_MISSING'
       END AS asin_resolution_status,
       CASE
         WHEN s.customer_search_term IS NULL OR TRIM(s.customer_search_term) = '' THEN 'SEARCH_TERM_MISSING'
         ELSE 'OK'
       END AS search_term_status,
       s.loaded_at
FROM source_rows s
LEFT JOIN campaign_asin c
  ON c.date = s.data_date
 AND c.profile_id = s.ads_profile_id
 AND c.campaign_id = s.campaign_id
 AND COALESCE(c.ad_group_name, '') = COALESCE(NULLIF(TRIM(s.ad_group_name), ''), '')
LEFT JOIN adgroup_inventory_asin a
  ON a.profile_id = s.ads_profile_id
 AND a.campaign_id = s.campaign_id
 AND COALESCE(a.ad_group_name, '') = COALESCE(NULLIF(TRIM(s.ad_group_name), ''), '')
LEFT JOIN inventory_asin i
  ON i.profile_id = s.ads_profile_id
 AND i.campaign_id = s.campaign_id
 AND COALESCE(i.ad_group_name, '') = COALESCE(NULLIF(TRIM(s.ad_group_name), ''), '')
LEFT JOIN legacy_campaign_alias l
  ON l.campaign_name = s.campaign_name;

COMMENT ON VIEW marketcloud_gold.gold_ads_search_term_daily_v1 IS
'Ads Search Terms no grao correto para decisao. Base = MarketCloud silver + SWARM/pricing para datas mais frescas que ainda nao chegaram pelo AMC/silver.';

CREATE OR REPLACE VIEW marketcloud_gold.gold_search_intelligence_minimum_source_status_v1 AS
WITH finance AS (
  SELECT COUNT(*)::int AS rows,
         COUNT(DISTINCT asin)::int AS asins,
         COUNT(*) FILTER (WHERE gross_sales > 0)::int AS rows_with_sales,
         COUNT(*) FILTER (WHERE unit_cost IS NOT NULL AND unit_cost > 0)::int AS rows_with_cost,
         MIN(data_date) AS min_date,
         MAX(data_date) AS max_date
  FROM marketcloud_gold.gold_search_intelligence_product_daily_v1
),
scp AS (
  SELECT COUNT(*)::int AS rows,
         COUNT(DISTINCT asin)::int AS asins,
         COALESCE(SUM(impressions),0)::numeric AS impressions,
         COALESCE(SUM(clicks),0)::numeric AS clicks,
         COALESCE(SUM(purchases),0)::numeric AS purchases,
         MIN(period_start) AS min_date,
         MAX(period_end) AS max_date
  FROM marketcloud_gold.gold_brand_analytics_search_catalog_full_v1
),
sqp AS (
  SELECT COALESCE(SUM(query_count),0)::int AS rows,
         COUNT(DISTINCT asin)::int AS asins,
         COALESCE(SUM(query_impressions),0)::numeric AS impressions,
         COALESCE(SUM(query_clicks),0)::numeric AS clicks,
         COALESCE(SUM(query_purchases),0)::numeric AS purchases,
         MIN(period_start) AS min_date,
         MAX(period_end) AS max_date
  FROM marketcloud_silver.silver_brand_analytics_query_product_v1
),
brand_query AS (
  SELECT COUNT(*)::int AS rows,
         COUNT(DISTINCT search_query)::int AS queries,
         COUNT(*) FILTER (WHERE click_brand_share IS NOT NULL OR purchase_brand_share IS NOT NULL)::int AS share_rows,
         MIN(period_start) AS min_date,
         MAX(period_end) AS max_date
  FROM marketcloud_gold.gold_brand_analytics_brand_query_comprehensive_v1
),
ads_terms AS (
  SELECT COUNT(*)::int AS rows,
         COUNT(DISTINCT customer_search_term) FILTER (WHERE customer_search_term IS NOT NULL AND TRIM(customer_search_term) <> '')::int AS search_terms,
         COUNT(DISTINCT asin) FILTER (WHERE asin IS NOT NULL)::int AS resolved_asins,
         COALESCE(SUM(impressions),0)::numeric AS impressions,
         COALESCE(SUM(clicks),0)::numeric AS clicks,
         COALESCE(SUM(spend),0)::numeric AS spend,
         COALESCE(SUM(ads_orders),0)::numeric AS orders,
         COALESCE(SUM(ads_sales),0)::numeric AS sales,
         MIN(data_date) AS min_date,
         MAX(data_date) AS max_date
  FROM marketcloud_gold.gold_ads_search_term_daily_v1
)
SELECT 'FINANCEIRO_ASIN'::text AS source_key,
       'Financeiro do ASIN'::text AS source_label,
       rows,
       asins AS entities,
       rows_with_sales AS positive_signal,
       CASE WHEN rows = 0 THEN 'MISSING' WHEN rows_with_cost < rows_with_sales THEN 'PARTIAL' ELSE 'READY' END AS status,
       jsonb_build_object('asins', asins, 'rows_with_sales', rows_with_sales, 'rows_with_cost', rows_with_cost, 'min_date', min_date, 'max_date', max_date) AS evidence
FROM finance
UNION ALL
SELECT 'SEARCH_CATALOG_PERFORMANCE',
       'Search Catalog Performance',
       rows,
       asins,
       purchases::int,
       CASE WHEN rows = 0 THEN 'MISSING' WHEN impressions <= 0 THEN 'PARTIAL' ELSE 'READY' END,
       jsonb_build_object('asins', asins, 'impressions', impressions, 'clicks', clicks, 'purchases', purchases, 'min_date', min_date, 'max_date', max_date)
FROM scp
UNION ALL
SELECT 'SEARCH_QUERY_PERFORMANCE',
       'Search Query Performance por ASIN',
       rows,
       asins,
       purchases::int,
       CASE WHEN rows = 0 THEN 'MISSING' WHEN impressions <= 0 THEN 'PARTIAL' ELSE 'READY' END,
       jsonb_build_object('asins', asins, 'impressions', impressions, 'clicks', clicks, 'purchases', purchases, 'min_date', min_date, 'max_date', max_date)
FROM sqp
UNION ALL
SELECT 'BRAND_QUERY_COMPREHENSIVE',
       'Brand/Market Query Search Terms',
       rows,
       queries,
       share_rows,
       CASE WHEN rows = 0 THEN 'MISSING' WHEN share_rows <= 0 THEN 'PARTIAL' ELSE 'READY' END,
       jsonb_build_object(
         'queries', queries,
         'share_rows', share_rows,
         'min_date', min_date,
         'max_date', max_date,
         'source', 'BA_SEARCH_TERMS_E003',
         'note', 'Fresh market/competitor source. Full comprehensive volume/funnel fields are not present in E003.'
       )
FROM brand_query
UNION ALL
SELECT 'ADS_SEARCH_TERMS',
       'Ads Search Terms',
       rows,
       search_terms,
       orders::int,
       CASE WHEN rows = 0 THEN 'MISSING' WHEN search_terms = 0 OR impressions <= 0 THEN 'PARTIAL' ELSE 'READY' END,
       jsonb_build_object('search_terms', search_terms, 'resolved_asins', resolved_asins, 'impressions', impressions, 'clicks', clicks, 'spend', spend, 'orders', orders, 'sales', sales, 'min_date', min_date, 'max_date', max_date, 'placement_status', 'MISSING_IN_CURRENT_SOURCE')
FROM ads_terms;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_minimum_source_status_v1 IS
'Status das fontes minimas. Brand/Market Query usa BA Search Terms E003 fresco; campos comprehensive-only nao sao inventados.';

CREATE OR REPLACE FUNCTION marketcloud_gold.refresh_search_intelligence_cache_v1()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_market_query_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_search_intelligence_minimum_source_status_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_product_daily_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_query_doctor_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_competitor_radar_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_asin_source_coverage_v1;
END;
$$;

CREATE OR REPLACE FUNCTION marketcloud_gold.refresh_brand_analytics_gold()
RETURNS text LANGUAGE plpgsql AS $function$
BEGIN
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_market_search_weekly_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_brand_query_weekly_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_market_query_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_search_intelligence_minimum_source_status_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_product_daily_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_query_doctor_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_competitor_radar_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_asin_source_coverage_v1;
  RETURN 'brand_analytics_gold refreshed at '||now();
END;
$function$;
