-- 176: Search Intelligence MVP.
-- Produto vendavel inicial: ranking por ASIN com vendas totais, Ads, organico
-- estimado, margem operacional estimada e slots honestos para Brand Analytics.
-- Brand Analytics real entra depois nos campos ba_*; ate la, cobertura fica
-- NOT_CONFIGURED/NO_BRAND_ANALYTICS_DATA, sem mock.

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_orders (
    id bigint,
    amazon_order_id text,
    purchase_date timestamptz,
    last_update_date timestamptz,
    order_status text,
    fulfillment_channel text,
    sales_channel text,
    marketplace_id text,
    order_total_amount numeric,
    currency text,
    synced_at timestamptz,
    raw_snapshot_json_sanitized jsonb
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_orders');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_order_items (
    id bigint,
    amazon_order_id text,
    asin text,
    seller_sku text,
    title text,
    quantity_ordered integer,
    quantity_shipped integer,
    item_price_amount numeric,
    item_tax_amount numeric,
    promotion_discount_amount numeric,
    currency text,
    synced_at timestamptz,
    raw_snapshot_json_sanitized jsonb,
    order_item_id text,
    item_status text,
    stock_movement_status text
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_order_items');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_ads_product_daily (
    id bigint,
    date date,
    profile_id text,
    asin text,
    seller_sku text,
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
    synced_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_ads_product_daily');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_fee_estimates (
    id bigint,
    asin text,
    seller_sku text,
    price numeric,
    fulfillment_channel text,
    referral_fee numeric,
    fba_fee numeric,
    closing_fee numeric,
    total_fee numeric,
    currency text,
    raw_snapshot_json jsonb,
    estimated_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_fee_estimates');

CREATE SCHEMA IF NOT EXISTS marketcloud_gold;

DROP VIEW IF EXISTS marketcloud_gold.dim_ba_brand_asin_v1 CASCADE;
CREATE VIEW marketcloud_gold.dim_ba_brand_asin_v1 AS
WITH fba AS (
    SELECT asin,
           SUM(COALESCE(available_quantity,0))::numeric AS fba_available,
           MAX(last_synced_at) AS fba_synced_at
    FROM swarm_src.amazon_fba_inventory
    WHERE COALESCE(asin,'') <> ''
    GROUP BY asin
),
link_rows AS (
    SELECT DISTINCT ON (asin)
           asin, seller_sku, sku, product_name, listing_title, listing_status,
           current_price, currency_code, product_cost, extra_cost, unit_cost,
           link_status, updated_at, last_synced_at
    FROM (
        SELECT COALESCE(NULLIF(al.asin,''), NULLIF(l.asin,'')) AS asin,
               COALESCE(NULLIF(al.seller_sku,''), NULLIF(l.seller_sku,'')) AS seller_sku,
               COALESCE(NULLIF(l.zanom_sku,''), NULLIF(l.seller_sku,''), NULLIF(al.seller_sku,'')) AS sku,
               COALESCE(NULLIF(l.zanom_product_name,''), NULLIF(al.title,''), COALESCE(NULLIF(al.asin,''), NULLIF(l.asin,''))) AS product_name,
               COALESCE(NULLIF(al.title,''), NULLIF(l.zanom_product_name,'')) AS listing_title,
               COALESCE(al.status, l.link_status, 'UNKNOWN') AS listing_status,
               COALESCE(al.price, 0)::numeric AS current_price,
               COALESCE(al.currency, 'BRL') AS currency_code,
               COALESCE(l.product_cost,0)::numeric AS product_cost,
               COALESCE(l.extra_cost,0)::numeric AS extra_cost,
               COALESCE(l.product_cost,0)::numeric + COALESCE(l.extra_cost,0)::numeric AS unit_cost,
               l.link_status,
               l.updated_at,
               al.last_synced_at,
               0 AS source_rank
        FROM swarm_src.amazon_listings al
        LEFT JOIN swarm_src.amazon_listing_links l ON l.seller_sku = al.seller_sku
        WHERE COALESCE(NULLIF(al.asin,''), NULLIF(l.asin,'')) IS NOT NULL
        UNION ALL
        SELECT l.asin,
               l.seller_sku,
               COALESCE(NULLIF(l.zanom_sku,''), NULLIF(l.seller_sku,'')) AS sku,
               COALESCE(NULLIF(l.zanom_product_name,''), l.asin) AS product_name,
               NULL::text AS listing_title,
               COALESCE(l.link_status, 'UNKNOWN') AS listing_status,
               0::numeric AS current_price,
               'BRL'::text AS currency_code,
               COALESCE(l.product_cost,0)::numeric AS product_cost,
               COALESCE(l.extra_cost,0)::numeric AS extra_cost,
               COALESCE(l.product_cost,0)::numeric + COALESCE(l.extra_cost,0)::numeric AS unit_cost,
               l.link_status,
               l.updated_at,
               NULL::timestamptz AS last_synced_at,
               1 AS source_rank
        FROM swarm_src.amazon_listing_links l
        WHERE COALESCE(l.asin,'') <> ''
    ) u
    WHERE COALESCE(asin,'') <> ''
    ORDER BY asin,
             CASE WHEN link_status IN ('LINKED','ACTIVE','CONFIRMED') THEN 0 ELSE 1 END,
             source_rank,
             COALESCE(updated_at, last_synced_at) DESC NULLS LAST
)
SELECT l.*,
       COALESCE(f.fba_available, 0)::numeric AS stock_available,
       f.fba_synced_at,
       'ZANOM'::text AS brand,
       CASE WHEN COALESCE(l.link_status,'') IN ('LINKED','ACTIVE','CONFIRMED') OR COALESCE(l.seller_sku,'') <> ''
            THEN 'ELIGIBLE_CANDIDATE'
            ELSE 'UNKNOWN'
       END AS brand_analytics_eligibility_status,
       NULL::date AS brand_eligibility_start_date,
       now() AS refreshed_at
FROM link_rows l
LEFT JOIN fba f ON f.asin = l.asin;

COMMENT ON VIEW marketcloud_gold.dim_ba_brand_asin_v1 IS
'Dimensao MVP de ASIN da marca, derivada de listings/links/estoque reais do SWARM. Elegibilidade Brand Analytics ainda e candidata ate extractor BA validar.';

DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_product_daily_v1 CASCADE;
CREATE VIEW marketcloud_gold.gold_search_intelligence_product_daily_v1 AS
WITH order_items AS (
    SELECT (o.purchase_date AT TIME ZONE 'America/Sao_Paulo')::date AS data_date,
           oi.asin,
           COALESCE(NULLIF(oi.seller_sku,''), d.seller_sku) AS seller_sku,
           MAX(COALESCE(NULLIF(oi.title,''), d.product_name)) AS product_name,
           COUNT(DISTINCT o.amazon_order_id)::numeric AS total_orders,
           SUM(COALESCE(oi.quantity_ordered,0))::numeric AS total_units,
           SUM(COALESCE(oi.item_price_amount,0))::numeric AS gross_sales,
           MAX(COALESCE(oi.currency, d.currency_code, 'BRL')) AS currency_code
    FROM swarm_src.amazon_orders o
    JOIN swarm_src.amazon_order_items oi ON oi.amazon_order_id = o.amazon_order_id
    LEFT JOIN marketcloud_gold.dim_ba_brand_asin_v1 d ON d.asin = oi.asin
    WHERE COALESCE(oi.asin,'') <> ''
      AND COALESCE(o.order_status,'') NOT IN ('Canceled','Cancelled')
    GROUP BY 1,2,3
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
       d.currency_code,
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
       CASE WHEN COALESCE(oi.gross_sales,0) > 0 THEN COALESCE(a.ads_sales,0) / NULLIF(oi.gross_sales,0) ELSE NULL END::numeric AS ads_sales_share,
       CASE WHEN COALESCE(oi.gross_sales,0) > 0 THEN GREATEST(COALESCE(oi.gross_sales,0)-COALESCE(a.ads_sales,0),0) / NULLIF(oi.gross_sales,0) ELSE NULL END::numeric AS organic_sales_share,
       CASE WHEN COALESCE(a.ads_spend,0) > 0 THEN COALESCE(a.ads_sales,0) / NULLIF(a.ads_spend,0) ELSE NULL END::numeric AS ads_roas,
       CASE WHEN COALESCE(oi.gross_sales,0) > 0 THEN COALESCE(a.ads_spend,0) / NULLIF(oi.gross_sales,0) ELSE NULL END::numeric AS tacos,
       NULL::numeric AS ba_impression_share,
       NULL::numeric AS ba_click_share,
       NULL::numeric AS ba_cart_share,
       NULL::numeric AS ba_purchase_share,
       NULL::numeric AS ba_purchase_share_lift,
       NULL::numeric AS ba_search_conversion,
       'NO_BRAND_ANALYTICS_DATA'::text AS ba_coverage_status,
       'ORDERS_API_ITEMS_MINUS_ADS_ATTRIBUTION'::text AS organic_estimation_basis,
       now() AS refreshed_at
FROM keys k
LEFT JOIN marketcloud_gold.dim_ba_brand_asin_v1 d ON d.asin = k.asin
LEFT JOIN order_items oi ON oi.data_date = k.data_date AND oi.asin = k.asin
LEFT JOIN ads a ON a.data_date = k.data_date AND a.asin = k.asin
LEFT JOIN fee f ON f.asin = k.asin
WHERE d.asin IS NOT NULL;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_product_daily_v1 IS
'MVP Search Intelligence por produto/dia: vendas totais por Orders API item, Ads por amazon_ads_product_daily e organico estimado. Campos BA ficam NULL ate reports oficiais.';

DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_product_summary_v1 CASCADE;
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
       CASE WHEN SUM(gross_sales) > 0 THEN SUM(ads_sales) / NULLIF(SUM(gross_sales),0) ELSE NULL END::numeric AS ads_sales_share,
       CASE WHEN SUM(gross_sales) > 0 THEN SUM(organic_sales_estimated) / NULLIF(SUM(gross_sales),0) ELSE NULL END::numeric AS organic_sales_share,
       CASE WHEN SUM(ads_spend) > 0 THEN SUM(ads_sales) / NULLIF(SUM(ads_spend),0) ELSE NULL END::numeric AS ads_roas,
       CASE WHEN SUM(gross_sales) > 0 THEN SUM(ads_spend) / NULLIF(SUM(gross_sales),0) ELSE NULL END::numeric AS tacos,
       MAX(stock_available)::numeric AS stock_available,
       COUNT(*) FILTER (WHERE ba_coverage_status <> 'NO_BRAND_ANALYTICS_DATA') AS ba_days_covered,
       COUNT(*) AS days_observed,
       CASE
           WHEN SUM(gross_sales) <= 0 AND SUM(ads_spend) > 0 THEN 'CORTAR_OU_REVISAR'
           WHEN SUM(ebitda_estimated) > 0 AND COALESCE(SUM(organic_sales_estimated) / NULLIF(SUM(gross_sales),0),0) >= 0.45 THEN 'ESCALAR_ORGANICO_FORTE'
           WHEN SUM(ebitda_estimated) > 0 AND COALESCE(SUM(ads_sales) / NULLIF(SUM(gross_sales),0),0) >= 0.60 THEN 'ESCALAR_COM_CUIDADO_DEPENDE_ADS'
           WHEN SUM(ebitda_estimated) < 0 THEN 'REVISAR_MARGEM'
           ELSE 'MANTER_OBSERVAR'
       END AS recommendation_status,
       now() AS refreshed_at
FROM marketcloud_gold.gold_search_intelligence_product_daily_v1
GROUP BY asin;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_product_summary_v1 IS
'Resumo historico MVP por produto. Endpoint aplica filtro de periodo diretamente na daily view para nao misturar janelas.';
