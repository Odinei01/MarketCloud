-- =====================================================================
-- Fix E005 — lado CONVERTED agregava em grão ultra-fino (7 dimensões:
-- +targeting +match_type +customer_search_term), o que fazia o AMC suprimir
-- ~100% das conversões (dimensões anuladas) e o ingest pular todas → bronze
-- com 0 CONVERTED_ASIN (só ADVERTISED). Validado: AMC tem 121 orders com
-- dimensão no grão (data,campanha,apt,asin).
--
-- Correção: o lado CONVERTED passa a agregar no grão correto de um extrato de
-- ASIN — (data, campanha, ad_product_type, tracked_asin) — com targeting/
-- match_type/customer_search_term como sentinela. Grupos maiores => menos
-- supressão => captura as conversões por ASIN comprado.
-- O lado ADVERTISED (tráfego) permanece igual.
--
-- Marker: E005_PRODUCT_ASIN_DAILY_V2_CONVERTED_COARSE
-- =====================================================================

UPDATE query_templates
SET version = 2,
    updated_at = NOW(),
    description = 'Product ASIN daily. CONVERTED agregado por (data,campanha,apt,tracked_asin) — grão que o AMC dimensiona, sem supressão total. Marker E005_PRODUCT_ASIN_DAILY_V2_CONVERTED_COARSE.',
    sql_template = $V2$
WITH advertised_raw AS (
    SELECT
        event_date AS data_date,
        campaign_id, campaign, ad_product_type, ad_group,
        targeting, match_type, customer_search_term,
        creative_asin, currency_iso_code, portfolio_id, portfolio_name,
        COUNT(1) AS activity_rows,
        SUM(impressions) AS impressions, SUM(clicks) AS clicks,
        SUM(spend / 100000000.0) AS spend,
        SUM(viewable_impressions) AS viewable_impressions, SUM(five_sec_views) AS five_sec_views
    FROM sponsored_ads_traffic
    WHERE event_date IS NOT NULL AND campaign_id IS NOT NULL
      AND campaign IS NOT NULL AND ad_product_type IS NOT NULL
      AND creative_asin IS NOT NULL
    GROUP BY event_date, campaign_id, campaign, ad_product_type, ad_group,
        targeting, match_type, customer_search_term, creative_asin,
        currency_iso_code, portfolio_id, portfolio_name
),
advertised AS (
    SELECT
        data_date,
        'ADVERTISED_ASIN' AS product_role,
        NULLIF(TRIM(CAST(campaign_id AS VARCHAR)), '') AS campaign_id,
        NULLIF(TRIM(REPLACE(REPLACE(CAST(campaign AS VARCHAR), '"', ' '), ',', ' ')), '') AS campaign_name,
        NULLIF(TRIM(CAST(ad_product_type AS VARCHAR)), '') AS ad_product_type,
        NULLIF(TRIM(REPLACE(REPLACE(CAST(ad_group AS VARCHAR), '"', ' '), ',', ' ')), '') AS ad_group_name,
        COALESCE(NULLIF(TRIM(REPLACE(REPLACE(CAST(targeting AS VARCHAR), '"', ' '), ',', ' ')), ''), 'NO_TARGETING') AS targeting,
        COALESCE(NULLIF(TRIM(CAST(match_type AS VARCHAR)), ''), 'NO_MATCH_TYPE') AS match_type,
        COALESCE(NULLIF(TRIM(REPLACE(REPLACE(CAST(customer_search_term AS VARCHAR), '"', ' '), ',', ' ')), ''), 'NO_SEARCH_TERM') AS customer_search_term,
        NULLIF(TRIM(CAST(creative_asin AS VARCHAR)), '') AS product_asin,
        NULLIF(TRIM(CAST(currency_iso_code AS VARCHAR)), '') AS currency_iso_code,
        NULLIF(TRIM(CAST(currency_iso_code AS VARCHAR)), '') AS purchase_currency,
        NULLIF(TRIM(CAST(portfolio_id AS VARCHAR)), '') AS portfolio_id,
        NULLIF(TRIM(CAST(portfolio_name AS VARCHAR)), '') AS portfolio_name,
        activity_rows, impressions, clicks, spend, viewable_impressions, five_sec_views,
        0 AS orders, 0 AS sales, 0 AS units_sold, 0 AS add_to_cart, 0 AS detail_page_views,
        0 AS brand_halo_orders, 0 AS brand_halo_sales,
        0 AS new_to_brand_orders, 0 AS new_to_brand_sales,
        0 AS purchases_clicks, 0 AS purchases_views,
        0 AS product_sales_clicks, 0 AS product_sales_views,
        0 AS off_amazon_sales, 0 AS combined_sales
    FROM advertised_raw
    WHERE NULLIF(TRIM(CAST(campaign_id AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(campaign AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(ad_product_type AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(creative_asin AS VARCHAR)), '') IS NOT NULL
),
converted_raw AS (
    SELECT
        conversion_event_date AS data_date,
        campaign_id, campaign, ad_product_type,
        tracked_asin, purchase_currency,
        SUM(total_purchases) AS orders, SUM(total_product_sales) AS sales,
        SUM(total_units_sold) AS units_sold, SUM(total_add_to_cart) AS add_to_cart,
        SUM(total_detail_page_view) AS detail_page_views,
        SUM(brand_halo_purchases) AS brand_halo_orders, SUM(brand_halo_product_sales) AS brand_halo_sales,
        SUM(new_to_brand_purchases) AS new_to_brand_orders, SUM(new_to_brand_product_sales) AS new_to_brand_sales,
        SUM(purchases_clicks) AS purchases_clicks, SUM(purchases_views) AS purchases_views,
        SUM(product_sales_clicks) AS product_sales_clicks, SUM(product_sales_views) AS product_sales_views,
        SUM(off_amazon_product_sales) AS off_amazon_sales, SUM(combined_sales) AS combined_sales
    FROM amazon_attributed_events_by_conversion_time
    WHERE conversion_event_date IS NOT NULL AND campaign_id IS NOT NULL
      AND ad_product_type IS NOT NULL AND tracked_asin IS NOT NULL
    GROUP BY conversion_event_date, campaign_id, campaign, ad_product_type,
        tracked_asin, purchase_currency
),
converted AS (
    SELECT
        data_date,
        'CONVERTED_ASIN' AS product_role,
        NULLIF(TRIM(CAST(campaign_id AS VARCHAR)), '') AS campaign_id,
        NULLIF(TRIM(CAST(campaign AS VARCHAR)), '') AS campaign_name,
        NULLIF(TRIM(CAST(ad_product_type AS VARCHAR)), '') AS ad_product_type,
        'NO_AD_GROUP' AS ad_group_name,
        'NO_TARGETING' AS targeting,
        'NO_MATCH_TYPE' AS match_type,
        'NO_SEARCH_TERM' AS customer_search_term,
        NULLIF(TRIM(CAST(tracked_asin AS VARCHAR)), '') AS product_asin,
        NULLIF(TRIM(CAST(purchase_currency AS VARCHAR)), '') AS currency_iso_code,
        NULLIF(TRIM(CAST(purchase_currency AS VARCHAR)), '') AS purchase_currency,
        CAST(NULL AS VARCHAR) AS portfolio_id,
        CAST(NULL AS VARCHAR) AS portfolio_name,
        0 AS activity_rows,
        0 AS impressions, 0 AS clicks, CAST(0 AS DOUBLE) AS spend,
        0 AS viewable_impressions, 0 AS five_sec_views,
        orders, sales, units_sold, add_to_cart, detail_page_views,
        brand_halo_orders, brand_halo_sales, new_to_brand_orders, new_to_brand_sales,
        purchases_clicks, purchases_views, product_sales_clicks, product_sales_views,
        off_amazon_sales, combined_sales
    FROM converted_raw
    WHERE NULLIF(TRIM(CAST(campaign_id AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(ad_product_type AS VARCHAR)), '') IS NOT NULL
      AND NULLIF(TRIM(CAST(tracked_asin AS VARCHAR)), '') IS NOT NULL
)
SELECT data_date, product_role, campaign_id, campaign_name, ad_product_type, ad_group_name,
    targeting, match_type, customer_search_term, product_asin,
    currency_iso_code, purchase_currency, portfolio_id, portfolio_name,
    activity_rows, impressions, clicks, spend, viewable_impressions, five_sec_views,
    orders, sales, units_sold, add_to_cart, detail_page_views,
    brand_halo_orders, brand_halo_sales, new_to_brand_orders, new_to_brand_sales,
    purchases_clicks, purchases_views, product_sales_clicks, product_sales_views,
    off_amazon_sales, combined_sales
FROM advertised
UNION ALL
SELECT data_date, product_role, campaign_id, campaign_name, ad_product_type, ad_group_name,
    targeting, match_type, customer_search_term, product_asin,
    currency_iso_code, purchase_currency, portfolio_id, portfolio_name,
    activity_rows, impressions, clicks, spend, viewable_impressions, five_sec_views,
    orders, sales, units_sold, add_to_cart, detail_page_views,
    brand_halo_orders, brand_halo_sales, new_to_brand_orders, new_to_brand_sales,
    purchases_clicks, purchases_views, product_sales_clicks, product_sales_views,
    off_amazon_sales, combined_sales
FROM converted
$V2$
WHERE code = 'MC_ZANOM_E005' AND status = 'ACTIVE';
