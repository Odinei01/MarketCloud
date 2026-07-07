-- Fix E008 — sanitiza texto livre (remove aspas/virgulas que quebram CSV do AMC).
-- Mesmo bug do LazyProof aplicado a E005/E002/E003. Marker E008_SANITIZE_FREETEXT_CSV
UPDATE query_templates
SET updated_at = NOW(),
    description = COALESCE(description,'') || ' [sanitize E008_SANITIZE_FREETEXT_CSV]',
    sql_template = $SAN$WITH conversions_raw AS (
    SELECT
        conversion_event_date AS conversion_date,

        campaign_id,
        campaign,
        ad_product_type,

        targeting,
        match_type,
        customer_search_term,

        tracked_asin,

        purchase_currency,

        COUNT(1) AS conversion_rows,

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
      AND campaign IS NOT NULL
      AND ad_product_type IS NOT NULL
      AND tracked_asin IS NOT NULL

    GROUP BY
        conversion_event_date,
        campaign_id,
        campaign,
        ad_product_type,
        targeting,
        match_type,
        customer_search_term,
        tracked_asin,
        purchase_currency
),

conversions AS (
    SELECT
        conversion_date,

        NULLIF(TRIM(CAST(campaign_id AS VARCHAR)), '') AS campaign_id,
        NULLIF(TRIM(REPLACE(REPLACE(CAST(campaign AS VARCHAR), '"', ' '), ',', ' ')), '') AS campaign_name,
        NULLIF(TRIM(CAST(ad_product_type AS VARCHAR)), '') AS ad_product_type,

        COALESCE(
            NULLIF(TRIM(REPLACE(REPLACE(CAST(targeting AS VARCHAR), '"', ' '), ',', ' ')), ''),
            'NO_TARGETING'
        ) AS targeting,

        COALESCE(
            NULLIF(TRIM(CAST(match_type AS VARCHAR)), ''),
            'NO_MATCH_TYPE'
        ) AS match_type,

        COALESCE(
            NULLIF(TRIM(REPLACE(REPLACE(CAST(customer_search_term AS VARCHAR), '"', ' '), ',', ' ')), ''),
            'NO_SEARCH_TERM'
        ) AS customer_search_term,

        NULLIF(TRIM(CAST(tracked_asin AS VARCHAR)), '') AS tracked_asin,

        NULLIF(TRIM(CAST(purchase_currency AS VARCHAR)), '') AS purchase_currency,

        conversion_rows,

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

conversions_clean AS (
    SELECT
        conversion_date,

        campaign_id,
        campaign_name,
        ad_product_type,

        targeting,
        match_type,
        customer_search_term,

        tracked_asin,

        purchase_currency,

        conversion_rows,

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

        CASE
            WHEN orders > 0
            THEN brand_halo_orders / orders
            ELSE 0
        END AS brand_halo_order_share,

        CASE
            WHEN sales > 0
            THEN brand_halo_sales / sales
            ELSE 0
        END AS brand_halo_sales_share,

        CASE
            WHEN orders > 0
            THEN new_to_brand_orders / orders
            ELSE 0
        END AS new_to_brand_order_share,

        CASE
            WHEN sales > 0
            THEN new_to_brand_sales / sales
            ELSE 0
        END AS new_to_brand_sales_share,

        CASE
            WHEN orders > 0
            THEN sales / orders
            ELSE 0
        END AS average_order_value,

        CASE
            WHEN (purchases_clicks + purchases_views) > 0
            THEN CAST(purchases_clicks AS DOUBLE) / (purchases_clicks + purchases_views)
            ELSE 0
        END AS click_purchase_share,

        CASE
            WHEN (product_sales_clicks + product_sales_views) > 0
            THEN CAST(product_sales_clicks AS DOUBLE) / (product_sales_clicks + product_sales_views)
            ELSE 0
        END AS click_sales_share

    FROM conversions

    WHERE campaign_id IS NOT NULL
      AND campaign_name IS NOT NULL
      AND ad_product_type IS NOT NULL
      AND tracked_asin IS NOT NULL
)

SELECT
    conversion_date,

    campaign_id,
    campaign_name,
    ad_product_type,

    targeting,
    match_type,
    customer_search_term,

    tracked_asin,

    purchase_currency,

    conversion_rows,

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

    brand_halo_order_share,
    brand_halo_sales_share,

    new_to_brand_order_share,
    new_to_brand_sales_share,

    average_order_value,

    click_purchase_share,
    click_sales_share

FROM conversions_clean
$SAN$
WHERE code = 'MC_ZANOM_E008' AND status = 'ACTIVE';
