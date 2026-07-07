-- =====================================================================
-- MarketCloud AMC Silver Layer V1
-- ZANOM / Amazon Marketing Cloud
--
-- Conteúdo:
--   S001 silver_campaign_daily          (fonte: E001)
--   S002 silver_target_daily            (fonte: E002)
--   S003 silver_search_term_daily       (fonte: E003)
--   S004 silver_hourly_campaign_adgroup (fonte: E004 V2)
--   S005 silver_product_asin_daily      (fonte: E005)
--   S006 silver_placement_creative_daily (fonte: E007)
--   S007 silver_new_to_brand_halo_daily (fonte: E008)
--   S008 silver_conversions_unified_daily (fonte: E009)
--
-- Regras:
--   - Views apenas (CREATE OR REPLACE VIEW)
--   - Sem alteração no Bronze
--   - Sem marketplace_id / marketplace_name
--   - Sem ação ou recomendação automática de campanha
--   - Divisão por zero: CASE WHEN denominador > 0 THEN ... ELSE 0 END
--   - E009: nunca somar sem filtrar attribution_mode
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS marketcloud_silver;

-- =====================================================================
-- S001 — silver_campaign_daily
-- Fonte: marketcloud_bronze.bronze_amc_campaign_daily
-- Grão: tenant_id / amc_instance_id / ads_profile_id / data_date
--       / campaign_id / ad_product_type
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_silver.silver_campaign_daily AS
SELECT
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    workflow_run_id,

    data_date,
    campaign_id,
    campaign_name,
    ad_product_type,

    currency_iso_code,
    purchase_currency,
    portfolio_id,
    portfolio_name,

    impressions,
    clicks,
    spend,

    orders,
    sales,
    units_sold,
    combined_sales,

    brand_halo_orders,
    brand_halo_sales,
    new_to_brand_orders,
    new_to_brand_sales,

    -- KPIs passados do Bronze
    ctr,
    cpc,
    roas,
    total_roas,
    conversion_rate,

    -- KPIs calculados na Silver
    CASE WHEN sales    > 0 THEN spend        / sales    ELSE 0 END AS acos,
    CASE WHEN orders   > 0 THEN spend        / orders   ELSE 0 END AS cpa,
    CASE WHEN orders   > 0 THEN sales        / orders   ELSE 0 END AS aov,
    CASE WHEN sales    > 0 THEN brand_halo_sales     / sales ELSE 0 END AS brand_halo_sales_share,
    CASE WHEN sales    > 0 THEN new_to_brand_sales   / sales ELSE 0 END AS new_to_brand_sales_share,

    loaded_at
FROM marketcloud_bronze.bronze_amc_campaign_daily;


-- =====================================================================
-- S002 — silver_target_daily
-- Fonte: marketcloud_bronze.bronze_amc_target_daily
-- Grão: tenant_id / amc_instance_id / ads_profile_id / data_date
--       / campaign_id / ad_product_type / ad_group_name / targeting / match_type
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_silver.silver_target_daily AS
SELECT
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    workflow_run_id,

    data_date,
    campaign_id,
    campaign_name,
    ad_product_type,
    ad_group_name,
    targeting,
    match_type,

    impressions,
    clicks,
    spend,

    orders,
    sales,
    combined_sales,

    -- KPIs passados do Bronze
    ctr,
    cpc,
    roas,
    total_roas,
    conversion_rate,

    -- KPIs calculados na Silver
    CASE WHEN sales  > 0 THEN spend / sales  ELSE 0 END AS acos,
    CASE WHEN orders > 0 THEN spend / orders ELSE 0 END AS cpa,
    CASE WHEN orders > 0 THEN sales / orders ELSE 0 END AS aov,

    -- Classificação de eficiência (sem recomendar ação)
    CASE
        WHEN spend = 0                                    THEN 'NO_SPEND'
        WHEN spend > 0 AND clicks = 0                     THEN 'NO_CLICK'
        WHEN spend > 0 AND sales  = 0                     THEN 'SPEND_NO_SALE'
        WHEN COALESCE(roas, 0) >= 5                       THEN 'PROFITABLE_TRAFFIC'
        ELSE                                                   'WATCH'
    END AS efficiency_bucket,

    loaded_at
FROM marketcloud_bronze.bronze_amc_target_daily;


-- =====================================================================
-- S003 — silver_search_term_daily
-- Fonte: marketcloud_bronze.bronze_amc_search_term_daily
-- Grão: tenant_id / amc_instance_id / ads_profile_id / data_date
--       / campaign_id / ad_product_type / ad_group_name / targeting
--       / match_type / customer_search_term
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_silver.silver_search_term_daily AS
SELECT
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    workflow_run_id,

    data_date,
    campaign_id,
    campaign_name,
    ad_product_type,
    ad_group_name,
    targeting,
    match_type,
    customer_search_term,

    impressions,
    clicks,
    spend,

    orders,
    sales,
    combined_sales,

    -- KPIs passados do Bronze
    ctr,
    cpc,
    roas,
    total_roas,
    conversion_rate,

    -- KPIs calculados na Silver
    CASE WHEN sales  > 0 THEN spend / sales  ELSE 0 END AS acos,
    CASE WHEN orders > 0 THEN spend / orders ELSE 0 END AS cpa,
    CASE WHEN orders > 0 THEN sales / orders ELSE 0 END AS aov,

    -- Search term normalizado para harvest e negativos
    LOWER(TRIM(customer_search_term)) AS search_term_normalized,

    -- Bucket de intenção inicial (V1: BRANDED_ZANOM vs GENERIC)
    CASE
        WHEN LOWER(customer_search_term) LIKE '%zanom%' THEN 'BRANDED_ZANOM'
        ELSE 'GENERIC'
    END AS search_term_intent_bucket,

    loaded_at
FROM marketcloud_bronze.bronze_amc_search_term_daily;


-- =====================================================================
-- S004 — silver_hourly_campaign_adgroup
-- Fonte: marketcloud_bronze.bronze_amc_hourly_performance (E004 V2)
-- Grão: tenant_id / amc_instance_id / ads_profile_id / data_date
--       / event_hour / campaign_id / ad_product_type / ad_group_name
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_silver.silver_hourly_campaign_adgroup AS
SELECT
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    workflow_run_id,

    data_date,
    event_hour,
    campaign_id,
    campaign_name,
    ad_product_type,
    ad_group_name,

    impressions,
    clicks,
    spend,

    orders,
    sales,
    combined_sales,

    -- KPIs passados do Bronze
    ctr,
    cpc,
    roas,
    total_roas,
    conversion_rate,

    -- KPIs calculados na Silver
    CASE WHEN sales  > 0 THEN spend / sales  ELSE 0 END AS acos,
    CASE WHEN orders > 0 THEN spend / orders ELSE 0 END AS cpa,
    CASE WHEN orders > 0 THEN sales / orders ELSE 0 END AS aov,

    -- Período do dia
    CASE
        WHEN event_hour BETWEEN  0 AND  5 THEN 'MADRUGADA'
        WHEN event_hour BETWEEN  6 AND 11 THEN 'MANHA'
        WHEN event_hour BETWEEN 12 AND 17 THEN 'TARDE'
        ELSE                                   'NOITE'
    END AS day_part,

    -- Bucket de eficiência horária (sem recomendar ação)
    CASE
        WHEN spend = 0                                          THEN 'NO_SPEND'
        WHEN spend > 0 AND clicks = 0                           THEN 'SPEND_NO_CLICK'
        WHEN clicks > 0 AND sales = 0                           THEN 'CLICK_NO_SALE'
        WHEN sales > 0 AND COALESCE(roas, 0) < 3               THEN 'SALE_LOW_ROAS'
        WHEN COALESCE(roas, 0) >= 3 AND COALESCE(roas, 0) < 7  THEN 'SALE_GOOD_ROAS'
        ELSE                                                         'SALE_STRONG_ROAS'
    END AS hour_efficiency_bucket,

    loaded_at
FROM marketcloud_bronze.bronze_amc_hourly_performance;


-- =====================================================================
-- S005 — silver_product_asin_daily
-- Fonte: marketcloud_bronze.bronze_amc_product_asin_daily
-- Grão: tenant_id / amc_instance_id / ads_profile_id / data_date
--       / product_role / campaign_id / ad_product_type / product_asin
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_silver.silver_product_asin_daily AS
SELECT
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    workflow_run_id,

    data_date,
    product_role,
    campaign_id,
    campaign_name,
    ad_product_type,
    ad_group_name,
    targeting,
    match_type,
    customer_search_term,
    product_asin,

    impressions,
    clicks,
    spend,

    orders,
    sales,
    combined_sales,
    units_sold,

    -- Bucket do papel do ASIN (não somar ADVERTISED + CONVERTED como mesmo fato)
    CASE
        WHEN product_role ILIKE '%ADVERTISED%' THEN 'ADVERTISED_ASIN'
        WHEN product_role ILIKE '%PURCHASE%'
          OR product_role ILIKE '%CONVERT%'   THEN 'CONVERTED_ASIN'
        ELSE product_role
    END AS product_role_bucket,

    loaded_at
FROM marketcloud_bronze.bronze_amc_product_asin_daily;


-- =====================================================================
-- S006 — silver_placement_creative_daily
-- Fonte: marketcloud_bronze.bronze_amc_placement_creative_daily
-- Grão: tenant_id / amc_instance_id / ads_profile_id / data_date
--       / campaign_id / ad_product_type / placement_type
--       / creative / creative_type / creative_asin
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_silver.silver_placement_creative_daily AS
SELECT
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    workflow_run_id,

    data_date,
    campaign_id,
    campaign_name,
    ad_product_type,
    ad_group_name,
    targeting,
    match_type,
    placement_type,
    creative,
    creative_type,
    creative_asin,

    impressions,
    clicks,
    spend,
    viewable_impressions,
    five_sec_views,

    video_first_quartile_views,
    video_midpoint_views,
    video_third_quartile_views,
    video_complete_views,
    video_unmutes,

    -- KPIs passados do Bronze
    ctr,
    cpc,
    viewability_rate,
    video_completion_rate,

    -- Bucket de custo por placement (sem recomendar ação)
    CASE
        WHEN spend = 0                                          THEN 'NO_SPEND'
        WHEN COALESCE(cpc, 0) >= 2                             THEN 'HIGH_CPC'
        WHEN impressions >= 100 AND COALESCE(ctr, 0) < 0.005  THEN 'LOW_CTR'
        WHEN COALESCE(ctr, 0) >= 0.01                          THEN 'GOOD_TRAFFIC'
        ELSE                                                        'WATCH'
    END AS placement_cost_bucket,

    loaded_at
FROM marketcloud_bronze.bronze_amc_placement_creative_daily;


-- =====================================================================
-- S007 — silver_new_to_brand_halo_daily
-- Fonte: marketcloud_bronze.bronze_amc_new_to_brand_halo_daily
-- Grão: tenant_id / amc_instance_id / ads_profile_id / conversion_date
--       / campaign_id / ad_product_type / targeting / match_type
--       / customer_search_term / tracked_asin
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_silver.silver_new_to_brand_halo_daily AS
SELECT
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    workflow_run_id,

    conversion_date,
    campaign_id,
    campaign_name,
    ad_product_type,
    targeting,
    match_type,
    customer_search_term,
    tracked_asin,

    orders,
    sales,
    units_sold,

    brand_halo_orders,
    brand_halo_sales,
    new_to_brand_orders,
    new_to_brand_sales,

    purchases_clicks,
    purchases_views,
    product_sales_clicks,
    product_sales_views,
    combined_sales,

    -- KPIs passados do Bronze
    brand_halo_order_share,
    brand_halo_sales_share,
    new_to_brand_order_share,
    new_to_brand_sales_share,
    average_order_value,
    click_purchase_share,
    click_sales_share,

    -- Buckets de sinal (sem recomendar ação)
    CASE WHEN brand_halo_sales > 0 THEN 'HAS_HALO' ELSE 'NO_HALO' END AS halo_bucket,
    CASE WHEN new_to_brand_sales > 0 THEN 'HAS_NTB'  ELSE 'NO_NTB'  END AS ntb_bucket,

    loaded_at
FROM marketcloud_bronze.bronze_amc_new_to_brand_halo_daily;


-- =====================================================================
-- S008 — silver_conversions_unified_daily
-- Fonte: marketcloud_bronze.bronze_amc_conversions_unified_daily
-- Grão: tenant_id / amc_instance_id / ads_profile_id / attribution_mode
--       / attribution_date / campaign_id / ad_product_type / targeting
--       / match_type / customer_search_term / tracked_asin
--
-- ATENÇÃO: NUNCA somar sem filtrar attribution_mode.
-- CONVERSION_TIME e TRAFFIC_TIME são duas leituras distintas de atribuição.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_silver.silver_conversions_unified_daily AS
SELECT
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    workflow_run_id,

    attribution_mode,
    attribution_date,
    campaign_id,
    campaign_name,
    ad_product_type,
    targeting,
    match_type,
    customer_search_term,
    tracked_asin,

    orders,
    sales,
    units_sold,
    add_to_cart,
    detail_page_views,

    brand_halo_orders,
    brand_halo_sales,
    new_to_brand_orders,
    new_to_brand_sales,

    purchases_clicks,
    purchases_views,
    product_sales_clicks,
    product_sales_views,
    off_amazon_sales,
    combined_sales,

    -- KPIs passados do Bronze
    brand_halo_order_share,
    new_to_brand_order_share,
    new_to_brand_sales_share,
    click_attribution_share,
    average_order_value,

    -- Flags de modo de atribuição
    (attribution_mode = 'CONVERSION_TIME') AS is_conversion_time,
    (attribution_mode = 'TRAFFIC_TIME')    AS is_traffic_time,
    (tracked_asin     = 'NO_ASIN')         AS is_no_asin,

    loaded_at
FROM marketcloud_bronze.bronze_amc_conversions_unified_daily;


-- =====================================================================
-- Validações (executar após criação das views)
-- =====================================================================

-- Contagens — devem bater com o Bronze:
-- SELECT 'S001' AS silver, COUNT(*) FROM marketcloud_silver.silver_campaign_daily
-- UNION ALL SELECT 'S002', COUNT(*) FROM marketcloud_silver.silver_target_daily
-- UNION ALL SELECT 'S003', COUNT(*) FROM marketcloud_silver.silver_search_term_daily
-- UNION ALL SELECT 'S004', COUNT(*) FROM marketcloud_silver.silver_hourly_campaign_adgroup
-- UNION ALL SELECT 'S005', COUNT(*) FROM marketcloud_silver.silver_product_asin_daily
-- UNION ALL SELECT 'S006', COUNT(*) FROM marketcloud_silver.silver_placement_creative_daily
-- UNION ALL SELECT 'S007', COUNT(*) FROM marketcloud_silver.silver_new_to_brand_halo_daily
-- UNION ALL SELECT 'S008', COUNT(*) FROM marketcloud_silver.silver_conversions_unified_daily;

-- Totais financeiros S001 — comparar com E001 Bronze:
-- SELECT SUM(spend), SUM(sales), SUM(combined_sales), SUM(orders)
-- FROM marketcloud_silver.silver_campaign_daily;

-- Validação S004 por data:
-- SELECT data_date, COUNT(*) AS rows_count, SUM(spend), SUM(clicks), SUM(sales)
-- FROM marketcloud_silver.silver_hourly_campaign_adgroup
-- GROUP BY data_date ORDER BY data_date;

-- =====================================================================
-- End of file
-- =====================================================================
