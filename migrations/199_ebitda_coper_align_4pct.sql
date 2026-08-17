-- 199: Equalizar EBITDA ao conceito real — COPER passa de 2% para 4% do faturamento.
-- Formula oficial unica (dashboard + SI): Receita - CMV - AmazonFees - Ads - Impostos(4%) - COPER(4%).
-- Recria a view do Search Intelligence trocando coper 0.02 -> 0.04 (tax permanece 0.04).
CREATE OR REPLACE VIEW marketcloud_gold.gold_search_intelligence_product_daily_v1 AS
 WITH order_item_base AS (
         SELECT (o.purchase_date AT TIME ZONE 'America/Sao_Paulo'::text)::date AS data_date,
            o.amazon_order_id,
            oi_1.asin,
            COALESCE(NULLIF(oi_1.seller_sku, ''::text), d_1.seller_sku) AS seller_sku,
            COALESCE(NULLIF(oi_1.title, ''::text), d_1.product_name) AS product_name,
            COALESCE(oi_1.currency, d_1.currency_code, 'BRL'::text) AS currency_code,
            GREATEST(COALESCE(oi_1.quantity_ordered, 0), COALESCE(oi_1.quantity_shipped, 0), 1)::numeric AS item_units,
            COALESCE(o.order_total_amount, 0::numeric) AS order_total_amount,
                CASE
                    WHEN COALESCE(oi_1.item_price_amount, 0::numeric) > 0::numeric THEN COALESCE(oi_1.item_price_amount, 0::numeric)
                    WHEN COALESCE(d_1.current_price, 0::numeric) > 0::numeric THEN GREATEST(COALESCE(oi_1.quantity_ordered, 0), COALESCE(oi_1.quantity_shipped, 0), 1)::numeric * COALESCE(d_1.current_price, 0::numeric)
                    WHEN COALESCE(d_1.unit_cost, 0::numeric) > 0::numeric THEN GREATEST(COALESCE(oi_1.quantity_ordered, 0), COALESCE(oi_1.quantity_shipped, 0), 1)::numeric * COALESCE(d_1.unit_cost, 0::numeric)
                    ELSE GREATEST(COALESCE(oi_1.quantity_ordered, 0), COALESCE(oi_1.quantity_shipped, 0), 1)::numeric
                END AS item_weight
           FROM swarm_src.amazon_orders o
             JOIN swarm_src.amazon_order_items oi_1 ON oi_1.amazon_order_id = o.amazon_order_id
             LEFT JOIN marketcloud_gold.dim_ba_brand_asin_v1 d_1 ON d_1.asin = oi_1.asin
          WHERE COALESCE(oi_1.asin, ''::text) <> ''::text AND (COALESCE(o.order_status, ''::text) <> ALL (ARRAY['Canceled'::text, 'Cancelled'::text])) AND COALESCE(o.sales_channel, ''::text) <> 'Non-Amazon'::text
        ), order_weight AS (
         SELECT order_item_base.amazon_order_id,
            NULLIF(sum(order_item_base.item_weight), 0::numeric) AS order_weight_sum,
            max(order_item_base.order_total_amount) AS order_total_amount
           FROM order_item_base
          GROUP BY order_item_base.amazon_order_id
        ), item_alloc AS (
         SELECT b.data_date,
            b.amazon_order_id,
            b.asin,
            b.seller_sku,
            b.product_name,
            b.currency_code,
            b.item_units,
                CASE
                    WHEN COALESCE(w.order_total_amount, 0::numeric) > 0::numeric AND COALESCE(w.order_weight_sum, 0::numeric) > 0::numeric THEN b.item_weight / w.order_weight_sum * w.order_total_amount
                    ELSE b.item_weight
                END AS allocated_order_gross
           FROM order_item_base b
             LEFT JOIN order_weight w ON w.amazon_order_id = b.amazon_order_id
        ), item_day_raw AS (
         SELECT item_alloc.data_date,
            item_alloc.asin,
            item_alloc.seller_sku,
            max(item_alloc.product_name) AS product_name,
            count(DISTINCT item_alloc.amazon_order_id)::numeric AS total_orders,
            sum(item_alloc.item_units) AS total_units,
            sum(item_alloc.allocated_order_gross) AS allocated_order_gross,
            max(item_alloc.currency_code) AS currency_code
           FROM item_alloc
          GROUP BY item_alloc.data_date, item_alloc.asin, item_alloc.seller_sku
        ), sales_day AS (
         SELECT amazon_sales_daily.date AS data_date,
            sum(COALESCE(amazon_sales_daily.ordered_product_sales_amount, 0::numeric)) AS sales_api_gross,
            sum(COALESCE(amazon_sales_daily.units_ordered, 0))::numeric AS sales_api_units,
            sum(COALESCE(amazon_sales_daily.total_order_items, 0))::numeric AS sales_api_order_items,
            max(COALESCE(amazon_sales_daily.ordered_product_sales_currency, 'BRL'::text)) AS currency_code
           FROM swarm_src.amazon_sales_daily
          GROUP BY amazon_sales_daily.date
        ), day_scale AS (
         SELECT r.data_date,
                CASE
                    WHEN COALESCE(sum(r.allocated_order_gross), 0::numeric) > 0::numeric AND COALESCE(max(s.sales_api_gross), 0::numeric) > 0::numeric THEN max(s.sales_api_gross) / NULLIF(sum(r.allocated_order_gross), 0::numeric)
                    ELSE 1::numeric
                END AS sales_api_scale,
            max(s.sales_api_gross) AS sales_api_gross
           FROM item_day_raw r
             LEFT JOIN sales_day s ON s.data_date = r.data_date
          GROUP BY r.data_date
        ), order_items AS (
         SELECT r.data_date,
            r.asin,
            r.seller_sku,
            r.product_name,
            r.total_orders,
            r.total_units,
            r.allocated_order_gross * COALESCE(ds.sales_api_scale, 1::numeric) AS gross_sales,
            r.currency_code,
            COALESCE(ds.sales_api_scale, 1::numeric) AS sales_api_allocation_scale
           FROM item_day_raw r
             LEFT JOIN day_scale ds ON ds.data_date = r.data_date
        ), ads AS (
         SELECT amazon_ads_product_daily.date AS data_date,
            amazon_ads_product_daily.asin,
            COALESCE(NULLIF(amazon_ads_product_daily.seller_sku, ''::text), ''::text) AS seller_sku,
            sum(COALESCE(amazon_ads_product_daily.impressions, 0))::numeric AS ads_impressions,
            sum(COALESCE(amazon_ads_product_daily.clicks, 0))::numeric AS ads_clicks,
            sum(COALESCE(amazon_ads_product_daily.cost, 0::numeric)) AS ads_spend,
            sum(COALESCE(amazon_ads_product_daily.attributed_sales, 0::numeric)) AS ads_sales,
            sum(COALESCE(amazon_ads_product_daily.purchases, 0))::numeric AS ads_orders
           FROM swarm_src.amazon_ads_product_daily
          WHERE COALESCE(amazon_ads_product_daily.asin, ''::text) <> ''::text
          GROUP BY amazon_ads_product_daily.date, amazon_ads_product_daily.asin, (COALESCE(NULLIF(amazon_ads_product_daily.seller_sku, ''::text), ''::text))
        ), fee AS (
         SELECT DISTINCT ON (amazon_fee_estimates.asin) amazon_fee_estimates.asin,
            COALESCE(amazon_fee_estimates.total_fee, 0::numeric) AS unit_amazon_fee,
            amazon_fee_estimates.estimated_at
           FROM swarm_src.amazon_fee_estimates
          WHERE COALESCE(amazon_fee_estimates.asin, ''::text) <> ''::text
          ORDER BY amazon_fee_estimates.asin, amazon_fee_estimates.estimated_at DESC NULLS LAST
        ), keys AS (
         SELECT order_items.data_date,
            order_items.asin
           FROM order_items
        UNION
         SELECT ads.data_date,
            ads.asin
           FROM ads
        )
 SELECT k.data_date,
    d.asin,
    COALESCE(NULLIF(oi.seller_sku, ''::text), NULLIF(d.seller_sku, ''::text), NULLIF(a.seller_sku, ''::text)) AS seller_sku,
    COALESCE(NULLIF(oi.product_name, ''::text), d.product_name, d.listing_title, d.asin) AS product_name,
    d.brand,
    d.current_price,
    COALESCE(NULLIF(oi.currency_code, ''::text), d.currency_code, 'BRL'::text) AS currency_code,
    d.unit_cost,
    COALESCE(f.unit_amazon_fee, 0::numeric) AS unit_amazon_fee_estimated,
    d.stock_available,
    COALESCE(oi.total_orders, 0::numeric) AS total_orders,
    COALESCE(oi.total_units, 0::numeric) AS total_units,
    COALESCE(oi.gross_sales, 0::numeric) AS gross_sales,
    COALESCE(a.ads_impressions, 0::numeric) AS ads_impressions,
    COALESCE(a.ads_clicks, 0::numeric) AS ads_clicks,
    COALESCE(a.ads_spend, 0::numeric) AS ads_spend,
    COALESCE(a.ads_sales, 0::numeric) AS ads_sales,
    COALESCE(a.ads_orders, 0::numeric) AS ads_orders,
    GREATEST(COALESCE(oi.gross_sales, 0::numeric) - COALESCE(a.ads_sales, 0::numeric), 0::numeric) AS organic_sales_estimated,
    GREATEST(COALESCE(oi.total_orders, 0::numeric) - COALESCE(a.ads_orders, 0::numeric), 0::numeric) AS organic_orders_estimated,
    COALESCE(oi.total_units, 0::numeric) * COALESCE(d.unit_cost, 0::numeric) AS cmv_estimated,
    COALESCE(oi.total_units, 0::numeric) * COALESCE(f.unit_amazon_fee, 0::numeric) AS amazon_fee_estimated,
    COALESCE(oi.gross_sales, 0::numeric) * 0.04 AS tax_estimated,
    COALESCE(oi.gross_sales, 0::numeric) * 0.04 AS coper_estimated,
    COALESCE(oi.gross_sales, 0::numeric) - COALESCE(oi.total_units, 0::numeric) * COALESCE(d.unit_cost, 0::numeric) - COALESCE(oi.total_units, 0::numeric) * COALESCE(f.unit_amazon_fee, 0::numeric) - COALESCE(a.ads_spend, 0::numeric) - COALESCE(oi.gross_sales, 0::numeric) * 0.04 - COALESCE(oi.gross_sales, 0::numeric) * 0.04 AS ebitda_estimated,
        CASE
            WHEN COALESCE(oi.gross_sales, 0::numeric) > 0::numeric THEN LEAST(COALESCE(a.ads_sales, 0::numeric), COALESCE(oi.gross_sales, 0::numeric)) / NULLIF(oi.gross_sales, 0::numeric)
            ELSE NULL::numeric
        END AS ads_sales_share,
        CASE
            WHEN COALESCE(oi.gross_sales, 0::numeric) > 0::numeric THEN GREATEST(COALESCE(oi.gross_sales, 0::numeric) - LEAST(COALESCE(a.ads_sales, 0::numeric), COALESCE(oi.gross_sales, 0::numeric)), 0::numeric) / NULLIF(oi.gross_sales, 0::numeric)
            ELSE NULL::numeric
        END AS organic_sales_share,
        CASE
            WHEN COALESCE(a.ads_spend, 0::numeric) > 0::numeric THEN COALESCE(a.ads_sales, 0::numeric) / NULLIF(a.ads_spend, 0::numeric)
            ELSE NULL::numeric
        END AS ads_roas,
        CASE
            WHEN COALESCE(oi.gross_sales, 0::numeric) > 0::numeric THEN COALESCE(a.ads_spend, 0::numeric) / NULLIF(oi.gross_sales, 0::numeric)
            ELSE NULL::numeric
        END AS tacos,
    NULL::numeric AS ba_impression_share,
    NULL::numeric AS ba_click_share,
    NULL::numeric AS ba_cart_share,
    NULL::numeric AS ba_purchase_share,
    NULL::numeric AS ba_purchase_share_lift,
    NULL::numeric AS ba_search_conversion,
    'NO_BRAND_ANALYTICS_DATA'::text AS ba_coverage_status,
    'SALES_API_DAILY_ALLOCATED_TO_ITEMS_MINUS_ADS_ATTRIBUTION'::text AS organic_estimation_basis,
    COALESCE(oi.sales_api_allocation_scale, 1::numeric) AS sales_api_allocation_scale,
    now() AS refreshed_at
   FROM keys k
     LEFT JOIN marketcloud_gold.dim_ba_brand_asin_v1 d ON d.asin = k.asin
     LEFT JOIN order_items oi ON oi.data_date = k.data_date AND oi.asin = k.asin
     LEFT JOIN ads a ON a.data_date = k.data_date AND a.asin = k.asin
     LEFT JOIN fee f ON f.asin = k.asin
  WHERE d.asin IS NOT NULL;
