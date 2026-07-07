-- =====================================================================
-- Fix E001 — conversões deixam de ser descartadas (traffic-anchored -> FULL OUTER)
--
-- Problema (validado contra o AMC em 07/07):
--   AMC conversion-time = 219 orders. Nossa E001 = 135 (-38%).
--   O template era ancorado em tráfego: sponsored_ads_traffic LEFT JOIN
--   conversions. Toda conversão sem linha de tráfego correspondente em
--   (data, campaign_id, ad_product_type) era silenciosamente descartada
--   (view-through, brand-halo, ad_product_type ausente). Dias já maduros
--   batiam exato com o AMC, mas o total ficava 34+ orders abaixo por descarte.
--
-- Correção:
--   traffic_clean FULL OUTER JOIN conversions -> nenhuma conversão é perdida.
--   Chaves de grão via COALESCE(t, c). Linhas conversão-sem-tráfego entram
--   com spend/clicks/impressions = 0 (correto: view-through/halo). campaign_name
--   (NOT NULL na bronze) passa a ser carregado também pelo lado das conversões.
--
-- Marker: E001_CAMPAIGN_DAILY_EXTRACT_V3_FULL_OUTER
-- =====================================================================

UPDATE query_templates
SET version = 3,
    updated_at = NOW(),
    description = 'Campaign daily. FULL OUTER JOIN traffic/conversions + remove filtro ad_product_type IS NOT NULL nas conversões (sentinela UNKNOWN_AD_PRODUCT) — casa com a Q4 do AMC (219). Marker E001_CAMPAIGN_DAILY_EXTRACT_V3_FULL_OUTER.',
    sql_template = $V3$
WITH traffic_raw AS (
    SELECT
        event_date AS data_date,
        campaign_id,
        campaign,
        ad_product_type,
        marketplace_name,
        currency_iso_code,
        portfolio_id,
        portfolio_name,
        SUM(impressions) AS impressions,
        SUM(clicks) AS clicks,
        SUM(spend / 100000000.0) AS spend,
        SUM(viewable_impressions) AS viewable_impressions,
        SUM(five_sec_views) AS five_sec_views
    FROM sponsored_ads_traffic
    WHERE event_date IS NOT NULL
      AND campaign_id IS NOT NULL
      AND campaign IS NOT NULL
      AND ad_product_type IS NOT NULL
    GROUP BY
        event_date, campaign_id, campaign, ad_product_type,
        marketplace_name, currency_iso_code,
        portfolio_id, portfolio_name
),
traffic AS (
    SELECT
        data_date,
        NULLIF(TRIM(CAST(campaign_id AS VARCHAR)), '') AS campaign_id,
        NULLIF(TRIM(CAST(campaign AS VARCHAR)), '') AS campaign_name,
        NULLIF(TRIM(CAST(ad_product_type AS VARCHAR)), '') AS ad_product_type,
        NULLIF(TRIM(CAST(marketplace_name AS VARCHAR)), '') AS marketplace_name,
        NULLIF(TRIM(CAST(currency_iso_code AS VARCHAR)), '') AS currency_iso_code,
        NULLIF(TRIM(CAST(portfolio_id AS VARCHAR)), '') AS portfolio_id,
        NULLIF(TRIM(CAST(portfolio_name AS VARCHAR)), '') AS portfolio_name,
        impressions, clicks, spend, viewable_impressions, five_sec_views
    FROM traffic_raw
),
traffic_clean AS (
    SELECT * FROM traffic
    WHERE campaign_id IS NOT NULL
      AND campaign_name IS NOT NULL
      AND ad_product_type IS NOT NULL
),
conversions_raw AS (
    SELECT
        conversion_event_date AS data_date,
        campaign_id,
        campaign,
        ad_product_type,
        purchase_currency,
        SUM(total_purchases) AS orders,
        SUM(total_product_sales) AS sales,
        SUM(total_units_sold) AS units_sold,
        SUM(total_add_to_cart) AS add_to_cart,
        SUM(total_detail_page_view) AS detail_page_views,
        SUM(brand_halo_purchases) AS brand_halo_orders,
        SUM(brand_halo_product_sales) AS brand_halo_sales,
        SUM(new_to_brand_purchases) AS new_to_brand_orders,
        SUM(new_to_brand_product_sales) AS new_to_brand_sales,
        SUM(purchases_clicks) AS purchases_clicks,
        SUM(purchases_views) AS purchases_views,
        SUM(product_sales_clicks) AS product_sales_clicks,
        SUM(product_sales_views) AS product_sales_views,
        SUM(off_amazon_product_sales) AS off_amazon_sales,
        SUM(combined_sales) AS combined_sales
    FROM amazon_attributed_events_by_conversion_time
    WHERE conversion_event_date IS NOT NULL
      AND campaign_id IS NOT NULL
    GROUP BY
        conversion_event_date, campaign_id, campaign, ad_product_type, purchase_currency
),
conversions AS (
    SELECT
        data_date,
        NULLIF(TRIM(CAST(campaign_id AS VARCHAR)), '') AS campaign_id,
        NULLIF(TRIM(CAST(campaign AS VARCHAR)), '') AS campaign_name,
        COALESCE(NULLIF(TRIM(CAST(ad_product_type AS VARCHAR)), ''), 'UNKNOWN_AD_PRODUCT') AS ad_product_type,
        NULLIF(TRIM(CAST(purchase_currency AS VARCHAR)), '') AS purchase_currency,
        orders, sales, units_sold, add_to_cart, detail_page_views,
        brand_halo_orders, brand_halo_sales,
        new_to_brand_orders, new_to_brand_sales,
        purchases_clicks, purchases_views,
        product_sales_clicks, product_sales_views,
        off_amazon_sales, combined_sales
    FROM conversions_raw
),
joined AS (
    SELECT
        COALESCE(t.data_date, c.data_date)                              AS data_date,
        COALESCE(t.campaign_id, c.campaign_id)                          AS campaign_id,
        COALESCE(t.campaign_name, c.campaign_name, 'UNKNOWN_CAMPAIGN')  AS campaign_name,
        COALESCE(t.ad_product_type, c.ad_product_type)                  AS ad_product_type,
        t.marketplace_name,
        COALESCE(t.currency_iso_code, c.purchase_currency)              AS currency_iso_code,
        t.portfolio_id,
        t.portfolio_name,
        COALESCE(t.impressions, 0)          AS impressions,
        COALESCE(t.clicks, 0)               AS clicks,
        COALESCE(t.spend, 0)                AS spend,
        COALESCE(t.viewable_impressions, 0) AS viewable_impressions,
        COALESCE(t.five_sec_views, 0)       AS five_sec_views,
        COALESCE(c.purchase_currency, t.currency_iso_code) AS purchase_currency,
        COALESCE(c.orders, 0)               AS orders,
        COALESCE(c.sales, 0)                AS sales,
        COALESCE(c.units_sold, 0)           AS units_sold,
        COALESCE(c.add_to_cart, 0)          AS add_to_cart,
        COALESCE(c.detail_page_views, 0)    AS detail_page_views,
        COALESCE(c.brand_halo_orders, 0)    AS brand_halo_orders,
        COALESCE(c.brand_halo_sales, 0)     AS brand_halo_sales,
        COALESCE(c.new_to_brand_orders, 0)  AS new_to_brand_orders,
        COALESCE(c.new_to_brand_sales, 0)   AS new_to_brand_sales,
        COALESCE(c.purchases_clicks, 0)     AS purchases_clicks,
        COALESCE(c.purchases_views, 0)      AS purchases_views,
        COALESCE(c.product_sales_clicks, 0) AS product_sales_clicks,
        COALESCE(c.product_sales_views, 0)  AS product_sales_views,
        COALESCE(c.off_amazon_sales, 0)     AS off_amazon_sales,
        COALESCE(c.combined_sales, 0)       AS combined_sales,
        CASE WHEN COALESCE(t.impressions,0) > 0 THEN CAST(t.clicks AS DOUBLE) / t.impressions ELSE 0 END AS ctr,
        CASE WHEN COALESCE(t.clicks,0)      > 0 THEN t.spend / t.clicks ELSE 0 END AS cpc,
        CASE WHEN COALESCE(t.spend,0)       > 0 THEN COALESCE(c.sales, 0) / t.spend ELSE 0 END AS roas,
        CASE WHEN COALESCE(t.spend,0)       > 0 THEN COALESCE(c.combined_sales, 0) / t.spend ELSE 0 END AS total_roas,
        CASE WHEN COALESCE(t.clicks,0)      > 0 THEN CAST(COALESCE(c.orders, 0) AS DOUBLE) / t.clicks ELSE 0 END AS conversion_rate
    FROM traffic_clean t
    FULL OUTER JOIN conversions c
        ON  t.data_date       = c.data_date
        AND t.campaign_id     = c.campaign_id
        AND t.ad_product_type = c.ad_product_type
)
SELECT
    data_date, campaign_id, campaign_name, ad_product_type,
    marketplace_name, currency_iso_code, purchase_currency,
    portfolio_id, portfolio_name,
    impressions, clicks, spend, viewable_impressions, five_sec_views,
    orders, sales, units_sold, add_to_cart, detail_page_views,
    brand_halo_orders, brand_halo_sales,
    new_to_brand_orders, new_to_brand_sales,
    purchases_clicks, purchases_views,
    product_sales_clicks, product_sales_views,
    off_amazon_sales, combined_sales,
    ctr, cpc, roas, total_roas, conversion_rate
FROM joined
$V3$
WHERE code = 'MC_ZANOM_E001' AND status = 'ACTIVE';
