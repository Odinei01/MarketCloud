-- 185: fecha a cobertura minima por ASIN para Search Intelligence.
-- Ajustes:
-- 1) Ads Search Terms resolve ASIN tambem pelo ad_group_name do proprio report.
-- 2) Campanhas legadas univocas ganham alias explicito e auditavel.
-- 3) A matriz minima passa a medir SQP proprietario por ASIN, nao apenas query de mercado/brand-level.

CREATE OR REPLACE VIEW marketcloud_gold.gold_ads_search_term_daily_v1 AS
WITH campaign_asin AS (
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
FROM marketcloud_silver.silver_search_term_daily s
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
'Ads Search Terms no grao correto para decisao. ASIN vem de advertised_asin, ASIN no ad_group, inventory/target expression ou alias legado auditavel; alias aparece como ASIN_INFERRED_BY_ALIAS.';

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
         COALESCE(SUM(search_query_volume),0)::numeric AS search_query_volume,
         COALESCE(SUM(impression_total_count),0)::numeric AS impressions,
         COALESCE(SUM(click_total_count),0)::numeric AS clicks,
         COALESCE(SUM(purchase_total_count),0)::numeric AS purchases,
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
       'Brand Query Comprehensive',
       rows,
       queries,
       purchases::int,
       CASE WHEN rows = 0 THEN 'MISSING' WHEN search_query_volume <= 0 THEN 'PARTIAL' ELSE 'READY' END,
       jsonb_build_object('queries', queries, 'search_query_volume', search_query_volume, 'impressions', impressions, 'clicks', clicks, 'purchases', purchases, 'min_date', min_date, 'max_date', max_date)
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
'Status das fontes minimas: Financeiro ASIN, SCP, SQP proprietario por ASIN e Ads Search Terms. Brand Query Comprehensive fica separado como dado de mercado/brand-level.';

DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_minimum_decision_matrix_v1 CASCADE;

CREATE VIEW marketcloud_gold.gold_search_intelligence_minimum_decision_matrix_v1 AS
WITH finance AS (
  SELECT asin,
         MAX(product_name) AS product_name,
         MAX(seller_sku) AS seller_sku,
         MIN(data_date) AS first_date,
         MAX(data_date) AS last_date,
         SUM(gross_sales)::numeric AS gross_sales,
         SUM(total_units)::numeric AS total_units,
         SUM(total_orders)::numeric AS total_orders,
         CASE WHEN SUM(total_units) > 0 THEN SUM(gross_sales) / NULLIF(SUM(total_units),0) ELSE NULL END AS avg_realized_price,
         MAX(unit_cost)::numeric AS unit_cost,
         SUM(cmv_estimated)::numeric AS cmv_estimated,
         SUM(amazon_fee_estimated)::numeric AS amazon_fee_estimated,
         SUM(tax_estimated)::numeric AS tax_estimated,
         SUM(coper_estimated)::numeric AS coper_estimated,
         SUM(ads_spend)::numeric AS product_ads_spend,
         SUM(ebitda_estimated)::numeric AS ebitda_estimated,
         CASE WHEN SUM(gross_sales) > 0 THEN SUM(ebitda_estimated) / NULLIF(SUM(gross_sales),0) ELSE NULL END AS ebitda_margin,
         CASE WHEN SUM(gross_sales) > 0 THEN (SUM(gross_sales) - SUM(cmv_estimated) - SUM(amazon_fee_estimated) - SUM(tax_estimated) - SUM(coper_estimated)) / NULLIF(SUM(gross_sales),0) ELSE NULL END AS margin_before_ads
  FROM marketcloud_gold.gold_search_intelligence_product_daily_v1
  GROUP BY asin
),
scp AS (
  SELECT asin,
         SUM(impressions)::numeric AS scp_impressions,
         SUM(clicks)::numeric AS scp_clicks,
         SUM(cart_adds)::numeric AS scp_cart_adds,
         SUM(purchases)::numeric AS scp_purchases,
         SUM(search_traffic_sales)::numeric AS scp_sales,
         CASE WHEN SUM(impressions) > 0 THEN SUM(clicks) / NULLIF(SUM(impressions),0) ELSE NULL END AS scp_ctr,
         CASE WHEN SUM(clicks) > 0 THEN SUM(purchases) / NULLIF(SUM(clicks),0) ELSE NULL END AS scp_click_to_purchase_cvr,
         CASE WHEN SUM(clicks) > 0 THEN SUM(cart_adds) / NULLIF(SUM(clicks),0) ELSE NULL END AS scp_add_to_cart_rate,
         CASE WHEN SUM(cart_adds) > 0 THEN SUM(purchases) / NULLIF(SUM(cart_adds),0) ELSE NULL END AS scp_cart_to_purchase_rate,
         MAX(purchase_median_price)::numeric AS scp_purchase_median_price,
         COUNT(*)::int AS scp_periods
  FROM marketcloud_gold.gold_brand_analytics_search_catalog_full_v1
  GROUP BY asin
),
sqp AS (
  SELECT asin,
         SUM(query_count)::int AS sqp_query_rows,
         SUM(query_impressions)::numeric AS sqp_impressions,
         SUM(query_clicks)::numeric AS sqp_clicks,
         SUM(query_cart_adds)::numeric AS sqp_cart_adds,
         SUM(query_purchases)::numeric AS sqp_purchases,
         CASE WHEN SUM(query_impressions) > 0 THEN SUM(query_clicks) / NULLIF(SUM(query_impressions),0) ELSE NULL END AS sqp_ctr,
         CASE WHEN SUM(query_clicks) > 0 THEN SUM(query_purchases) / NULLIF(SUM(query_clicks),0) ELSE NULL END AS sqp_click_to_purchase_cvr,
         AVG(avg_brand_impression_share)::numeric AS sqp_avg_impression_share,
         AVG(avg_brand_click_share)::numeric AS sqp_avg_click_share,
         AVG(avg_brand_cart_add_share)::numeric AS sqp_avg_cart_add_share,
         AVG(avg_brand_purchase_share)::numeric AS sqp_avg_purchase_share,
         jsonb_agg(top_queries) FILTER (WHERE top_queries IS NOT NULL) AS sqp_top_queries,
         COUNT(*)::int AS sqp_periods
  FROM marketcloud_silver.silver_brand_analytics_query_product_v1
  GROUP BY asin
),
ads AS (
  SELECT asin,
         COUNT(*)::int AS ads_search_term_rows,
         COUNT(DISTINCT customer_search_term) FILTER (WHERE customer_search_term IS NOT NULL AND TRIM(customer_search_term) <> '')::int AS ads_search_terms,
         SUM(impressions)::numeric AS ads_st_impressions,
         SUM(clicks)::numeric AS ads_st_clicks,
         SUM(spend)::numeric AS ads_st_spend,
         SUM(ads_orders)::numeric AS ads_st_orders,
         SUM(ads_sales)::numeric AS ads_st_sales,
         CASE WHEN SUM(spend) > 0 THEN SUM(ads_sales) / NULLIF(SUM(spend),0) ELSE NULL END AS ads_st_roas,
         CASE WHEN SUM(ads_sales) > 0 THEN SUM(spend) / NULLIF(SUM(ads_sales),0) ELSE NULL END AS ads_st_acos
  FROM marketcloud_gold.gold_ads_search_term_daily_v1
  WHERE asin IS NOT NULL
  GROUP BY asin
)
SELECT f.*,
       COALESCE(s.scp_periods,0) AS scp_periods,
       COALESCE(s.scp_impressions,0) AS scp_impressions,
       COALESCE(s.scp_clicks,0) AS scp_clicks,
       COALESCE(s.scp_cart_adds,0) AS scp_cart_adds,
       COALESCE(s.scp_purchases,0) AS scp_purchases,
       COALESCE(s.scp_sales,0) AS scp_sales,
       s.scp_ctr,
       s.scp_click_to_purchase_cvr,
       s.scp_add_to_cart_rate,
       s.scp_cart_to_purchase_rate,
       s.scp_purchase_median_price,
       COALESCE(q.sqp_periods,0) AS sqp_periods,
       COALESCE(q.sqp_query_rows,0) AS sqp_query_rows,
       COALESCE(q.sqp_impressions,0) AS sqp_impressions,
       COALESCE(q.sqp_clicks,0) AS sqp_clicks,
       COALESCE(q.sqp_cart_adds,0) AS sqp_cart_adds,
       COALESCE(q.sqp_purchases,0) AS sqp_purchases,
       q.sqp_ctr,
       q.sqp_click_to_purchase_cvr,
       q.sqp_avg_impression_share,
       q.sqp_avg_click_share,
       q.sqp_avg_cart_add_share,
       q.sqp_avg_purchase_share,
       q.sqp_top_queries,
       COALESCE(a.ads_search_term_rows,0) AS ads_search_term_rows,
       COALESCE(a.ads_search_terms,0) AS ads_search_terms,
       COALESCE(a.ads_st_impressions,0) AS ads_search_term_impressions,
       COALESCE(a.ads_st_clicks,0) AS ads_search_term_clicks,
       COALESCE(a.ads_st_spend,0) AS ads_search_term_spend,
       COALESCE(a.ads_st_orders,0) AS ads_search_term_orders,
       COALESCE(a.ads_st_sales,0) AS ads_search_term_sales,
       a.ads_st_roas AS ads_search_term_roas,
       a.ads_st_acos AS ads_search_term_acos,
       CASE WHEN f.gross_sales > 0 AND f.unit_cost > 0 THEN 'READY' WHEN f.gross_sales > 0 THEN 'PARTIAL' ELSE 'MISSING' END AS finance_status,
       CASE WHEN COALESCE(s.scp_impressions,0) > 0 THEN 'READY' ELSE 'MISSING' END AS scp_status,
       CASE WHEN COALESCE(q.sqp_query_rows,0) > 0 THEN 'READY' ELSE 'MISSING' END AS sqp_status,
       CASE WHEN COALESCE(a.ads_search_terms,0) > 0 THEN 'READY' ELSE 'MISSING' END AS ads_search_terms_status,
       CASE
         WHEN f.gross_sales > 0 AND f.unit_cost > 0 AND COALESCE(s.scp_impressions,0) > 0 AND COALESCE(q.sqp_query_rows,0) > 0 AND COALESCE(a.ads_search_terms,0) > 0 THEN 'READY_FOR_DECISION'
         WHEN f.gross_sales > 0 AND COALESCE(s.scp_impressions,0) > 0 AND COALESCE(a.ads_search_terms,0) > 0 THEN 'OBSERVE_ONLY'
         ELSE 'INSUFFICIENT_DATA'
       END AS minimum_decision_status
FROM finance f
LEFT JOIN scp s ON s.asin = f.asin
LEFT JOIN sqp q ON q.asin = f.asin
LEFT JOIN ads a ON a.asin = f.asin;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_minimum_decision_matrix_v1 IS
'Matriz por ASIN com financeiro, SCP, SQP proprietario e Ads Search Terms resolvidos. READY_FOR_DECISION exige as quatro fontes no ASIN.';
