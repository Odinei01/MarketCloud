-- =====================================================================
-- Fix E004 — Hourly Performance Extract V2 (grão oficial de bid schedule)
--
-- Problema corrigido:
--   O template E004 ativo (76602dcd) ainda estava na versão antiga, com
--   targeting/match_type no grão e um `SELECT * FROM traffic` (proibido no
--   AMC). Como o grão da AMC ficava mais fino que o PK da bronze
--   (bronze_amc_hourly_performance, sem targeting/match_type) e o ingest usa
--   ON CONFLICT DO UPDATE SET x = EXCLUDED.x (substitui, não soma), as N
--   linhas por (campaign, ad_group, hora) — uma por targeting — colapsavam
--   em last-writer-wins → métricas horárias ERRADAS.
--
-- Correção:
--   A V2 aprovada agrega no próprio SQL até o grão oficial
--   (data_date / event_hour / campaign_id / campaign_name / ad_product_type /
--    ad_group_name), sem targeting/match_type e sem SELECT *. As colunas de
--   saída batem exatamente com o handler ingestE004 e com o PK da bronze.
--
--   Consolida em um único template ativo: atualiza 76602dcd para V2 e arquiva
--   o duplicado ec8362e8.
--
-- Marker: E004_HOURLY_PERFORMANCE_EXTRACT_V2_APPROVED
-- =====================================================================

-- 1) Arquiva o template E004 duplicado/órfão (remove do pool ACTIVE)
UPDATE query_templates
SET status = 'ARCHIVED', updated_at = NOW()
WHERE code = 'MC_ZANOM_E004'
  AND id::text LIKE 'ec8362e8%';

-- 2) Atualiza o template E004 canônico para a V2 aprovada
UPDATE query_templates
SET version = 3,
    updated_at = NOW(),
    description = 'Hourly performance por campanha/ad group (grão oficial de bid schedule). Fontes: sponsored_ads_traffic + amazon_attributed_events_by_traffic_time. Sem targeting/match_type, sem SELECT *. Marker E004_HOURLY_PERFORMANCE_EXTRACT_V2_APPROVED.',
    sql_template = $V2$
WITH traffic_raw AS (
    SELECT
        event_date AS data_date,
        event_hour,
        campaign_id,
        campaign,
        ad_product_type,
        ad_group,
        currency_iso_code,
        portfolio_id,
        portfolio_name,
        COUNT(1) AS activity_rows,
        SUM(impressions) AS impressions,
        SUM(clicks) AS clicks,
        SUM(spend / 100000000.0) AS spend,
        SUM(viewable_impressions) AS viewable_impressions,
        SUM(five_sec_views) AS five_sec_views
    FROM sponsored_ads_traffic
    WHERE event_date IS NOT NULL
      AND event_hour IS NOT NULL
      AND campaign_id IS NOT NULL
      AND campaign IS NOT NULL
      AND ad_product_type IS NOT NULL
    GROUP BY
        event_date,
        event_hour,
        campaign_id,
        campaign,
        ad_product_type,
        ad_group,
        currency_iso_code,
        portfolio_id,
        portfolio_name
),
traffic AS (
    SELECT
        data_date,
        event_hour,
        NULLIF(TRIM(CAST(campaign_id AS VARCHAR)), '') AS campaign_id,
        NULLIF(TRIM(CAST(campaign AS VARCHAR)), '') AS campaign_name,
        NULLIF(TRIM(CAST(ad_product_type AS VARCHAR)), '') AS ad_product_type,
        COALESCE(NULLIF(TRIM(CAST(ad_group AS VARCHAR)), ''), 'NO_AD_GROUP') AS ad_group_name,
        NULLIF(TRIM(CAST(currency_iso_code AS VARCHAR)), '') AS currency_iso_code,
        COALESCE(NULLIF(TRIM(CAST(portfolio_id AS VARCHAR)), ''), 'NO_PORTFOLIO') AS portfolio_id,
        COALESCE(NULLIF(TRIM(CAST(portfolio_name AS VARCHAR)), ''), 'NO_PORTFOLIO') AS portfolio_name,
        activity_rows,
        impressions,
        clicks,
        spend,
        viewable_impressions,
        five_sec_views
    FROM traffic_raw
),
traffic_clean AS (
    SELECT
        data_date,
        event_hour,
        campaign_id,
        campaign_name,
        ad_product_type,
        ad_group_name,
        currency_iso_code,
        portfolio_id,
        portfolio_name,
        activity_rows,
        impressions,
        clicks,
        spend,
        viewable_impressions,
        five_sec_views
    FROM traffic
    WHERE campaign_id IS NOT NULL
      AND campaign_name IS NOT NULL
      AND ad_product_type IS NOT NULL
),
conversions_raw AS (
    SELECT
        traffic_event_date AS data_date,
        traffic_event_hour AS event_hour,
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
    FROM amazon_attributed_events_by_traffic_time
    WHERE traffic_event_date IS NOT NULL
      AND traffic_event_hour IS NOT NULL
      AND campaign_id IS NOT NULL
      AND ad_product_type IS NOT NULL
    GROUP BY
        traffic_event_date,
        traffic_event_hour,
        campaign_id,
        campaign,
        ad_product_type,
        purchase_currency
),
conversions AS (
    SELECT
        data_date,
        event_hour,
        NULLIF(TRIM(CAST(campaign_id AS VARCHAR)), '') AS campaign_id,
        NULLIF(TRIM(CAST(ad_product_type AS VARCHAR)), '') AS ad_product_type,
        NULLIF(TRIM(CAST(purchase_currency AS VARCHAR)), '') AS purchase_currency,
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
        combined_sales
    FROM conversions_raw
),
joined AS (
    SELECT
        t.data_date,
        t.event_hour,
        t.campaign_id,
        t.campaign_name,
        t.ad_product_type,
        t.ad_group_name,
        t.currency_iso_code,
        COALESCE(c.purchase_currency, t.currency_iso_code) AS purchase_currency,
        t.portfolio_id,
        t.portfolio_name,
        t.activity_rows,
        t.impressions,
        t.clicks,
        t.spend,
        t.viewable_impressions,
        t.five_sec_views,
        COALESCE(c.orders, 0) AS orders,
        COALESCE(c.sales, 0) AS sales,
        COALESCE(c.units_sold, 0) AS units_sold,
        COALESCE(c.add_to_cart, 0) AS add_to_cart,
        COALESCE(c.detail_page_views, 0) AS detail_page_views,
        COALESCE(c.brand_halo_orders, 0) AS brand_halo_orders,
        COALESCE(c.brand_halo_sales, 0) AS brand_halo_sales,
        COALESCE(c.new_to_brand_orders, 0) AS new_to_brand_orders,
        COALESCE(c.new_to_brand_sales, 0) AS new_to_brand_sales,
        COALESCE(c.purchases_clicks, 0) AS purchases_clicks,
        COALESCE(c.purchases_views, 0) AS purchases_views,
        COALESCE(c.product_sales_clicks, 0) AS product_sales_clicks,
        COALESCE(c.product_sales_views, 0) AS product_sales_views,
        COALESCE(c.off_amazon_sales, 0) AS off_amazon_sales,
        COALESCE(c.combined_sales, 0) AS combined_sales,
        CASE
            WHEN t.impressions > 0
            THEN CAST(t.clicks AS DOUBLE) / t.impressions
            ELSE 0
        END AS ctr,
        CASE
            WHEN t.clicks > 0
            THEN t.spend / t.clicks
            ELSE 0
        END AS cpc,
        CASE
            WHEN t.spend > 0
            THEN COALESCE(c.sales, 0) / t.spend
            ELSE 0
        END AS roas,
        CASE
            WHEN t.spend > 0
            THEN COALESCE(c.combined_sales, 0) / t.spend
            ELSE 0
        END AS total_roas,
        CASE
            WHEN t.clicks > 0
            THEN CAST(COALESCE(c.orders, 0) AS DOUBLE) / t.clicks
            ELSE 0
        END AS conversion_rate
    FROM traffic_clean t
    LEFT JOIN conversions c
        ON  t.data_date = c.data_date
        AND t.event_hour = c.event_hour
        AND t.campaign_id = c.campaign_id
        AND t.ad_product_type = c.ad_product_type
)
SELECT
    data_date,
    event_hour,
    campaign_id,
    campaign_name,
    ad_product_type,
    ad_group_name,
    currency_iso_code,
    purchase_currency,
    portfolio_id,
    portfolio_name,
    activity_rows,
    impressions,
    clicks,
    spend,
    viewable_impressions,
    five_sec_views,
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
    ctr,
    cpc,
    roas,
    total_roas,
    conversion_rate
FROM joined
$V2$
WHERE code = 'MC_ZANOM_E004'
  AND id::text LIKE '76602dcd%';
