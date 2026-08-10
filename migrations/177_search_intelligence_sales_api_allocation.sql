-- 177: Search Intelligence must use total Amazon sales, not only item rows with
-- item_price_amount populated. The product split is allocated from Sales API
-- daily totals across the ASINs sold that day using order/item weights.

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_sales_daily (
    date date,
    marketplace_id text,
    ordered_product_sales_amount numeric,
    ordered_product_sales_currency text,
    units_ordered integer,
    total_order_items integer,
    synced_at timestamptz,
    raw_snapshot_json_sanitized jsonb
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_sales_daily');

DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_product_summary_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_product_daily_v1 CASCADE;

CREATE VIEW marketcloud_gold.gold_search_intelligence_product_daily_v1 AS
WITH order_item_base AS (
    SELECT (o.purchase_date AT TIME ZONE 'America/Sao_Paulo')::date AS data_date,
           o.amazon_order_id,
           oi.asin,
           COALESCE(NULLIF(oi.seller_sku,''), d.seller_sku) AS seller_sku,
           COALESCE(NULLIF(oi.title,''), d.product_name) AS product_name,
           COALESCE(oi.currency, d.currency_code, 'BRL') AS currency_code,
           GREATEST(COALESCE(oi.quantity_ordered,0), COALESCE(oi.quantity_shipped,0), 1)::numeric AS item_units,
           COALESCE(o.order_total_amount,0)::numeric AS order_total_amount,
           CASE
             WHEN COALESCE(oi.item_price_amount,0) > 0 THEN COALESCE(oi.item_price_amount,0)::numeric
             WHEN COALESCE(d.current_price,0) > 0 THEN GREATEST(COALESCE(oi.quantity_ordered,0), COALESCE(oi.quantity_shipped,0), 1)::numeric * COALESCE(d.current_price,0)::numeric
             WHEN COALESCE(d.unit_cost,0) > 0 THEN GREATEST(COALESCE(oi.quantity_ordered,0), COALESCE(oi.quantity_shipped,0), 1)::numeric * COALESCE(d.unit_cost,0)::numeric
             ELSE GREATEST(COALESCE(oi.quantity_ordered,0), COALESCE(oi.quantity_shipped,0), 1)::numeric
           END AS item_weight
    FROM swarm_src.amazon_orders o
    JOIN swarm_src.amazon_order_items oi ON oi.amazon_order_id = o.amazon_order_id
    LEFT JOIN marketcloud_gold.dim_ba_brand_asin_v1 d ON d.asin = oi.asin
    WHERE COALESCE(oi.asin,'') <> ''
      AND COALESCE(o.order_status,'') NOT IN ('Canceled','Cancelled')
),
order_weight AS (
    SELECT amazon_order_id,
           NULLIF(SUM(item_weight),0) AS order_weight_sum,
           MAX(order_total_amount) AS order_total_amount
    FROM order_item_base
    GROUP BY amazon_order_id
),
item_alloc AS (
    SELECT b.data_date,
           b.amazon_order_id,
           b.asin,
           b.seller_sku,
           b.product_name,
           b.currency_code,
           b.item_units,
           CASE
             WHEN COALESCE(w.order_total_amount,0) > 0 AND COALESCE(w.order_weight_sum,0) > 0
               THEN (b.item_weight / w.order_weight_sum) * w.order_total_amount
             ELSE b.item_weight
           END AS allocated_order_gross
    FROM order_item_base b
    LEFT JOIN order_weight w ON w.amazon_order_id = b.amazon_order_id
),
item_day_raw AS (
    SELECT data_date,
           asin,
           seller_sku,
           MAX(product_name) AS product_name,
           COUNT(DISTINCT amazon_order_id)::numeric AS total_orders,
           SUM(item_units)::numeric AS total_units,
           SUM(allocated_order_gross)::numeric AS allocated_order_gross,
           MAX(currency_code) AS currency_code
    FROM item_alloc
    GROUP BY 1,2,3
),
sales_day AS (
    SELECT date AS data_date,
           SUM(COALESCE(ordered_product_sales_amount,0))::numeric AS sales_api_gross,
           SUM(COALESCE(units_ordered,0))::numeric AS sales_api_units,
           SUM(COALESCE(total_order_items,0))::numeric AS sales_api_order_items,
           MAX(COALESCE(ordered_product_sales_currency,'BRL')) AS currency_code
    FROM swarm_src.amazon_sales_daily
    GROUP BY 1
),
day_scale AS (
    SELECT r.data_date,
           CASE
             WHEN COALESCE(SUM(r.allocated_order_gross),0) > 0 AND COALESCE(MAX(s.sales_api_gross),0) > 0
               THEN MAX(s.sales_api_gross) / NULLIF(SUM(r.allocated_order_gross),0)
             ELSE 1::numeric
           END AS sales_api_scale,
           MAX(s.sales_api_gross) AS sales_api_gross
    FROM item_day_raw r
    LEFT JOIN sales_day s ON s.data_date = r.data_date
    GROUP BY r.data_date
),
order_items AS (
    SELECT r.data_date,
           r.asin,
           r.seller_sku,
           r.product_name,
           r.total_orders,
           r.total_units,
           (r.allocated_order_gross * COALESCE(ds.sales_api_scale,1))::numeric AS gross_sales,
           r.currency_code,
           COALESCE(ds.sales_api_scale,1)::numeric AS sales_api_allocation_scale
    FROM item_day_raw r
    LEFT JOIN day_scale ds ON ds.data_date = r.data_date
),
ads AS (
    SELECT date AS data_date,
           asin,
           COALESCE(NULLIF(seller_sku,''), '') AS seller_sku,
           SUM(COALESCE(impressions,0))::numeric AS ads_impressions,
           SUM(COALESCE(clicks,0))::numeric AS ads_clicks,
           SUM(COALESCE(cost,0))::numeric AS ads_spend,
           SUM(COALESCE(attributed_sales,0))::numeric AS ads_sales,
           SUM(COALESCE(purchases,0))::numeric AS ads_orders
    FROM swarm_src.amazon_ads_product_daily
    WHERE COALESCE(asin,'') <> ''
    GROUP BY 1,2,3
),
fee AS (
    SELECT DISTINCT ON (asin)
           asin,
           COALESCE(total_fee,0)::numeric AS unit_amazon_fee,
           estimated_at
    FROM swarm_src.amazon_fee_estimates
    WHERE COALESCE(asin,'') <> ''
    ORDER BY asin, estimated_at DESC NULLS LAST
),
keys AS (
    SELECT data_date, asin FROM order_items
    UNION
    SELECT data_date, asin FROM ads
)
SELECT k.data_date,
       d.asin,
       COALESCE(NULLIF(oi.seller_sku,''), NULLIF(d.seller_sku,''), NULLIF(a.seller_sku,'')) AS seller_sku,
       COALESCE(NULLIF(oi.product_name,''), d.product_name, d.listing_title, d.asin) AS product_name,
       d.brand,
       d.current_price,
       COALESCE(NULLIF(oi.currency_code,''), d.currency_code, 'BRL') AS currency_code,
       d.unit_cost,
       COALESCE(f.unit_amazon_fee,0)::numeric AS unit_amazon_fee_estimated,
       d.stock_available,
       COALESCE(oi.total_orders,0)::numeric AS total_orders,
       COALESCE(oi.total_units,0)::numeric AS total_units,
       COALESCE(oi.gross_sales,0)::numeric AS gross_sales,
       COALESCE(a.ads_impressions,0)::numeric AS ads_impressions,
       COALESCE(a.ads_clicks,0)::numeric AS ads_clicks,
       COALESCE(a.ads_spend,0)::numeric AS ads_spend,
       COALESCE(a.ads_sales,0)::numeric AS ads_sales,
       COALESCE(a.ads_orders,0)::numeric AS ads_orders,
       GREATEST(COALESCE(oi.gross_sales,0) - COALESCE(a.ads_sales,0), 0)::numeric AS organic_sales_estimated,
       GREATEST(COALESCE(oi.total_orders,0) - COALESCE(a.ads_orders,0), 0)::numeric AS organic_orders_estimated,
       (COALESCE(oi.total_units,0) * COALESCE(d.unit_cost,0))::numeric AS cmv_estimated,
       (COALESCE(oi.total_units,0) * COALESCE(f.unit_amazon_fee,0))::numeric AS amazon_fee_estimated,
       (COALESCE(oi.gross_sales,0) * 0.04)::numeric AS tax_estimated,
       (COALESCE(oi.gross_sales,0) * 0.02)::numeric AS coper_estimated,
       (COALESCE(oi.gross_sales,0)
          - (COALESCE(oi.total_units,0) * COALESCE(d.unit_cost,0))
          - (COALESCE(oi.total_units,0) * COALESCE(f.unit_amazon_fee,0))
          - COALESCE(a.ads_spend,0)
          - (COALESCE(oi.gross_sales,0) * 0.04)
          - (COALESCE(oi.gross_sales,0) * 0.02))::numeric AS ebitda_estimated,
       CASE WHEN COALESCE(oi.gross_sales,0) > 0 THEN LEAST(COALESCE(a.ads_sales,0), COALESCE(oi.gross_sales,0)) / NULLIF(oi.gross_sales,0) ELSE NULL END::numeric AS ads_sales_share,
       CASE WHEN COALESCE(oi.gross_sales,0) > 0 THEN GREATEST(COALESCE(oi.gross_sales,0)-LEAST(COALESCE(a.ads_sales,0), COALESCE(oi.gross_sales,0)),0) / NULLIF(oi.gross_sales,0) ELSE NULL END::numeric AS organic_sales_share,
       CASE WHEN COALESCE(a.ads_spend,0) > 0 THEN COALESCE(a.ads_sales,0) / NULLIF(a.ads_spend,0) ELSE NULL END::numeric AS ads_roas,
       CASE WHEN COALESCE(oi.gross_sales,0) > 0 THEN COALESCE(a.ads_spend,0) / NULLIF(oi.gross_sales,0) ELSE NULL END::numeric AS tacos,
       NULL::numeric AS ba_impression_share,
       NULL::numeric AS ba_click_share,
       NULL::numeric AS ba_cart_share,
       NULL::numeric AS ba_purchase_share,
       NULL::numeric AS ba_purchase_share_lift,
       NULL::numeric AS ba_search_conversion,
       'NO_BRAND_ANALYTICS_DATA'::text AS ba_coverage_status,
       'SALES_API_DAILY_ALLOCATED_TO_ITEMS_MINUS_ADS_ATTRIBUTION'::text AS organic_estimation_basis,
       COALESCE(oi.sales_api_allocation_scale,1)::numeric AS sales_api_allocation_scale,
       now() AS refreshed_at
FROM keys k
LEFT JOIN marketcloud_gold.dim_ba_brand_asin_v1 d ON d.asin = k.asin
LEFT JOIN order_items oi ON oi.data_date = k.data_date AND oi.asin = k.asin
LEFT JOIN ads a ON a.data_date = k.data_date AND a.asin = k.asin
LEFT JOIN fee f ON f.asin = k.asin
WHERE d.asin IS NOT NULL;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_product_daily_v1 IS
'MVP Search Intelligence por produto/dia: vendas totais da Sales API diaria alocadas aos ASINs vendidos, Ads por amazon_ads_product_daily e organico estimado. Campos BA ficam NULL ate reports oficiais.';

CREATE VIEW marketcloud_gold.gold_search_intelligence_product_summary_v1 AS
SELECT asin,
       MAX(seller_sku) AS seller_sku,
       MAX(product_name) AS product_name,
       MAX(brand) AS brand,
       MAX(currency_code) AS currency_code,
       MIN(data_date) AS first_date,
       MAX(data_date) AS last_date,
       SUM(total_orders)::numeric AS total_orders,
       SUM(total_units)::numeric AS total_units,
       SUM(gross_sales)::numeric AS gross_sales,
       SUM(ads_spend)::numeric AS ads_spend,
       SUM(ads_sales)::numeric AS ads_sales,
       SUM(ads_orders)::numeric AS ads_orders,
       SUM(organic_sales_estimated)::numeric AS organic_sales_estimated,
       SUM(organic_orders_estimated)::numeric AS organic_orders_estimated,
       SUM(cmv_estimated)::numeric AS cmv_estimated,
       SUM(amazon_fee_estimated)::numeric AS amazon_fee_estimated,
       SUM(tax_estimated)::numeric AS tax_estimated,
       SUM(coper_estimated)::numeric AS coper_estimated,
       SUM(ebitda_estimated)::numeric AS ebitda_estimated,
       CASE WHEN SUM(gross_sales) > 0 THEN LEAST(SUM(ads_sales), SUM(gross_sales)) / NULLIF(SUM(gross_sales),0) ELSE NULL END::numeric AS ads_sales_share,
       CASE WHEN SUM(gross_sales) > 0 THEN GREATEST(SUM(gross_sales)-LEAST(SUM(ads_sales), SUM(gross_sales)),0) / NULLIF(SUM(gross_sales),0) ELSE NULL END::numeric AS organic_sales_share,
       CASE WHEN SUM(ads_spend) > 0 THEN SUM(ads_sales) / NULLIF(SUM(ads_spend),0) ELSE NULL END::numeric AS ads_roas,
       CASE WHEN SUM(gross_sales) > 0 THEN SUM(ads_spend) / NULLIF(SUM(gross_sales),0) ELSE NULL END::numeric AS tacos,
       MAX(stock_available)::numeric AS stock_available,
       COUNT(*) FILTER (WHERE ba_coverage_status <> 'NO_BRAND_ANALYTICS_DATA') AS ba_days_covered,
       COUNT(*) AS days_observed,
       CASE
           WHEN SUM(gross_sales) <= 0 AND SUM(ads_spend) > 0 THEN 'CORTAR_OU_REVISAR'
           WHEN SUM(ebitda_estimated) > 0 AND COALESCE(GREATEST(SUM(gross_sales)-LEAST(SUM(ads_sales), SUM(gross_sales)),0) / NULLIF(SUM(gross_sales),0),0) >= 0.45 THEN 'ESCALAR_ORGANICO_FORTE'
           WHEN SUM(ebitda_estimated) > 0 AND COALESCE(LEAST(SUM(ads_sales), SUM(gross_sales)) / NULLIF(SUM(gross_sales),0),0) >= 0.60 THEN 'ESCALAR_COM_CUIDADO_DEPENDE_ADS'
           WHEN SUM(ebitda_estimated) < 0 THEN 'REVISAR_MARGEM'
           ELSE 'MANTER_OBSERVAR'
       END AS recommendation_status,
       now() AS refreshed_at
FROM marketcloud_gold.gold_search_intelligence_product_daily_v1
GROUP BY asin;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_product_summary_v1 IS
'Resumo historico MVP por produto. Endpoint aplica filtro de periodo diretamente na daily view para nao misturar janelas.';
