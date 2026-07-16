-- =====================================================================
-- Full Control: estoque unificado SWARM
--
-- O Full Control precisa olhar estoque atual, nao apenas o snapshot salvo
-- no piloto. O SWARM considera estoque local + fases fisicas FBA.
-- =====================================================================

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.inventory_phase_balances (
    id bigint,
    product_id text,
    swarm_sku text,
    seller_sku text,
    asin text,
    fnsku text,
    phase text,
    quantity integer,
    cost_unit_brl numeric(10,2),
    cost_unit_base_brl numeric(10,2),
    internal_handling_cost_brl numeric(10,2),
    labeling_cost_brl numeric(10,2),
    fba_shipment_allocated_cost_brl numeric(10,2),
    cost_unit_total_brl numeric(10,2),
    cost_source text,
    cost_value_brl numeric(12,2),
    source text,
    source_ref text,
    snapshot_id text,
    updated_at timestamptz,
    created_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'inventory_phase_balances');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_fba_inventory (
    seller_sku text,
    asin text,
    fnsku text,
    condition text,
    available_quantity integer,
    inbound_quantity integer,
    reserved_quantity integer,
    unfulfillable_quantity integer,
    last_synced_at timestamptz,
    raw_snapshot_json jsonb
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_fba_inventory');

DROP VIEW IF EXISTS marketcloud_gold.full_control_effective_governance_v1;
DROP VIEW IF EXISTS marketcloud_gold.full_control_product_candidates_v1;

CREATE OR REPLACE VIEW marketcloud_gold.full_control_product_candidates_v1 AS
WITH amc AS (
    SELECT
        COALESCE(t.id::text, a.tenant_id) AS tenant_id,
        a.product_asin,
        NULL::text AS seller_sku,
        NULL::text AS product_title,
        a.campaign_id,
        a.campaign_name,
        MAX(a.data_date) AS last_seen_date,
        SUM(a.impressions)::numeric AS impressions_30d,
        SUM(a.clicks)::numeric AS clicks_30d,
        SUM(a.spend)::numeric AS spend_30d,
        SUM(a.orders)::numeric AS orders_30d,
        SUM(a.sales)::numeric AS sales_30d,
        SUM(a.units_sold)::numeric AS units_30d
    FROM marketcloud_bronze.bronze_amc_product_asin_daily a
    LEFT JOIN tenants t ON t.slug = a.tenant_id
    WHERE a.product_role = 'ADVERTISED_ASIN'
      AND a.data_date >= CURRENT_DATE - INTERVAL '30 days'
      AND a.product_asin IS NOT NULL
      AND a.product_asin <> 'NO_ASIN'
    GROUP BY COALESCE(t.id::text, a.tenant_id), a.product_asin, a.campaign_id, a.campaign_name
), swarm AS (
    SELECT
        (SELECT id::text FROM tenants WHERE slug = 'zanom' LIMIT 1) AS tenant_id,
        NULLIF(advertised_asin, '') AS product_asin,
        NULLIF(advertised_sku, '') AS seller_sku,
        NULL::text AS product_title,
        campaign_id,
        campaign_name,
        MAX(date) AS last_seen_date,
        SUM(COALESCE(impressions,0))::numeric AS impressions_30d,
        SUM(COALESCE(clicks,0))::numeric AS clicks_30d,
        SUM(COALESCE(cost,0))::numeric AS spend_30d,
        SUM(COALESCE(purchases,0))::numeric AS orders_30d,
        SUM(COALESCE(attributed_sales,0))::numeric AS sales_30d,
        SUM(COALESCE(units_sold,0))::numeric AS units_30d
    FROM swarm_src.amazon_ads_campaigns_daily
    WHERE date >= CURRENT_DATE - INTERVAL '30 days'
      AND NULLIF(advertised_asin, '') IS NOT NULL
      AND campaign_id IS NOT NULL
    GROUP BY advertised_asin, advertised_sku, campaign_id, campaign_name
), unioned AS (
    SELECT * FROM amc
    UNION ALL
    SELECT * FROM swarm
), rollup AS (
    SELECT
        tenant_id,
        product_asin,
        MAX(seller_sku) FILTER (WHERE seller_sku IS NOT NULL) AS seller_sku,
        MAX(product_title) FILTER (WHERE product_title IS NOT NULL) AS product_title,
        campaign_id,
        campaign_name,
        MAX(last_seen_date) AS last_seen_date,
        SUM(impressions_30d) AS impressions_30d,
        SUM(clicks_30d) AS clicks_30d,
        SUM(spend_30d) AS spend_30d,
        SUM(orders_30d) AS orders_30d,
        SUM(sales_30d) AS sales_30d,
        SUM(units_30d) AS units_30d
    FROM unioned
    WHERE tenant_id IS NOT NULL
      AND product_asin IS NOT NULL
    GROUP BY tenant_id, product_asin, campaign_id, campaign_name
), product_level AS (
    SELECT
        tenant_id,
        product_asin,
        MAX(seller_sku) FILTER (WHERE seller_sku IS NOT NULL) AS seller_sku,
        COALESCE(MAX(product_title) FILTER (WHERE product_title IS NOT NULL), product_asin) AS product_title,
        MAX(last_seen_date) AS last_seen_date,
        SUM(impressions_30d) AS impressions_30d,
        SUM(clicks_30d) AS clicks_30d,
        SUM(spend_30d) AS spend_30d,
        SUM(orders_30d) AS orders_30d,
        SUM(sales_30d) AS sales_30d,
        SUM(units_30d) AS units_30d,
        COUNT(DISTINCT campaign_id) AS campaign_count
    FROM rollup
    GROUP BY tenant_id, product_asin
), campaign_json AS (
    SELECT
        r.tenant_id,
        r.product_asin,
        jsonb_agg(
            jsonb_build_object(
                'campaign_id', r.campaign_id,
                'campaign_name', r.campaign_name,
                'last_seen_date', r.last_seen_date,
                'spend_30d', r.spend_30d,
                'orders_30d', r.orders_30d,
                'sales_30d', r.sales_30d,
                'roas_30d', CASE WHEN r.spend_30d > 0 THEN r.sales_30d / r.spend_30d ELSE 0 END,
                'pilot_mode', COALESCE(p.mode, 'not_configured'),
                'pilot_status', COALESCE(p.status, 'not_configured'),
                'pilot_id', p.pilot_id
            )
            ORDER BY r.spend_30d DESC, r.campaign_name
        ) AS campaigns
    FROM rollup r
    LEFT JOIN marketcloud_control.full_control_pilots p
      ON p.tenant_id = r.tenant_id
     AND p.product_asin = r.product_asin
     AND p.campaign_id = r.campaign_id
    GROUP BY r.tenant_id, r.product_asin
), listing AS (
    SELECT DISTINCT ON (asin)
        asin,
        NULLIF(seller_sku,'') AS seller_sku,
        NULLIF(zanom_sku,'') AS zanom_sku,
        NULLIF(zanom_product_name,'') AS product_title,
        COALESCE(NULLIF(zanom_cost_base,0), NULLIF(product_cost,0), NULLIF(extra_cost,0)) AS unit_cost_brl,
        CASE
            WHEN NULLIF(zanom_cost_base,0) IS NOT NULL THEN 'amazon_listing_links.zanom_cost_base'
            WHEN NULLIF(product_cost,0) IS NOT NULL THEN 'amazon_listing_links.product_cost'
            WHEN NULLIF(extra_cost,0) IS NOT NULL THEN 'amazon_listing_links.extra_cost'
        END AS unit_cost_source,
        NULLIF(zanom_internal_quantity,0)::numeric AS internal_quantity,
        link_status,
        updated_at
    FROM swarm_src.amazon_listing_links
    WHERE asin IS NOT NULL
    ORDER BY asin,
             CASE WHEN link_status LIKE 'LINKED%' THEN 0 ELSE 1 END,
             updated_at DESC NULLS LAST
), listing_price AS (
    SELECT DISTINCT ON (asin)
        asin,
        NULLIF(seller_sku,'') AS seller_sku,
        NULLIF(title,'') AS title,
        NULLIF(price,0) AS sale_price_brl,
        last_synced_at
    FROM swarm_src.amazon_listings
    WHERE asin IS NOT NULL
    ORDER BY asin, last_synced_at DESC NULLS LAST
), local_stock AS (
    SELECT DISTINCT ON (sku)
        sku,
        qty_on_hand AS stock_local_on_hand,
        qty_available AS stock_local_available,
        COALESCE(NULLIF(replacement_cost,0), NULLIF(avg_cost,0), NULLIF(last_purchase_cost,0)) AS stock_unit_cost_brl,
        CASE
            WHEN NULLIF(replacement_cost,0) IS NOT NULL THEN 'stock_position.replacement_cost'
            WHEN NULLIF(avg_cost,0) IS NOT NULL THEN 'stock_position.avg_cost'
            WHEN NULLIF(last_purchase_cost,0) IS NOT NULL THEN 'stock_position.last_purchase_cost'
        END AS stock_unit_cost_source,
        updated_at AS stock_local_updated_at
    FROM swarm_src.stock_position
    ORDER BY sku, updated_at DESC NULLS LAST
), fba_phase AS (
    SELECT
        swarm_sku AS sku,
        SUM(quantity)::numeric AS stock_fba_physical,
        MAX(updated_at) AS stock_fba_updated_at
    FROM swarm_src.inventory_phase_balances
    WHERE phase IN ('FBA_SHIPMENT_CREATED','FBA_IN_TRANSIT','FBA_RECEIVING','FBA_AVAILABLE','FBA_RESERVED','FBA_UNFULFILLABLE')
    GROUP BY swarm_sku
), fba_api AS (
    SELECT DISTINCT ON (seller_sku)
        seller_sku AS sku,
        available_quantity::numeric AS stock_fba_api_available,
        last_synced_at AS stock_fba_api_updated_at
    FROM swarm_src.amazon_fba_inventory
    ORDER BY seller_sku, last_synced_at DESC NULLS LAST
), stock AS (
    SELECT
        COALESCE(ls.sku, fp.sku, fa.sku) AS sku,
        COALESCE(ls.stock_local_available, 0)::numeric AS stock_local_available,
        COALESCE(fp.stock_fba_physical, fa.stock_fba_api_available, 0)::numeric AS stock_fba_available,
        COALESCE(ls.stock_local_available, 0)::numeric + COALESCE(fp.stock_fba_physical, fa.stock_fba_api_available, 0)::numeric AS stock_available,
        ls.stock_unit_cost_brl,
        ls.stock_unit_cost_source,
        GREATEST(ls.stock_local_updated_at, fp.stock_fba_updated_at, fa.stock_fba_api_updated_at) AS stock_updated_at,
        CASE
            WHEN fp.stock_fba_physical IS NOT NULL THEN 'stock_position + inventory_phase_balances'
            WHEN fa.stock_fba_api_available IS NOT NULL THEN 'stock_position + amazon_fba_inventory'
            WHEN ls.sku IS NOT NULL THEN 'stock_position'
        END AS stock_source
    FROM local_stock ls
    FULL JOIN fba_phase fp ON fp.sku = ls.sku
    FULL JOIN fba_api fa ON fa.sku = COALESCE(ls.sku, fp.sku)
)
SELECT
    p.tenant_id,
    p.product_asin,
    COALESCE(p.seller_sku, l.seller_sku, lp.seller_sku) AS seller_sku,
    COALESCE(l.product_title, lp.title, p.product_title) AS product_title,
    p.last_seen_date,
    p.impressions_30d,
    p.clicks_30d,
    p.spend_30d,
    p.orders_30d,
    p.sales_30d,
    p.units_30d,
    CASE WHEN p.spend_30d > 0 THEN p.sales_30d / p.spend_30d ELSE 0 END AS roas_30d,
    COALESCE(lp.sale_price_brl, CASE WHEN p.orders_30d > 0 THEN p.sales_30d / p.orders_30d ELSE NULL END) AS sale_price_brl,
    COALESCE(l.unit_cost_brl, s.stock_unit_cost_brl) AS unit_cost_brl,
    COALESCE(l.unit_cost_source, s.stock_unit_cost_source) AS unit_cost_source,
    s.stock_local_available,
    s.stock_fba_available,
    COALESCE(s.stock_available, l.internal_quantity) AS stock_available,
    COALESCE(s.stock_source, CASE WHEN l.internal_quantity IS NOT NULL THEN 'amazon_listing_links.zanom_internal_quantity' END) AS stock_source,
    s.stock_updated_at,
    CASE
        WHEN COALESCE(lp.sale_price_brl, CASE WHEN p.orders_30d > 0 THEN p.sales_30d / p.orders_30d ELSE NULL END) IS NOT NULL
         AND COALESCE(l.unit_cost_brl, s.stock_unit_cost_brl) IS NOT NULL
        THEN COALESCE(lp.sale_price_brl, CASE WHEN p.orders_30d > 0 THEN p.sales_30d / p.orders_30d ELSE NULL END) - COALESCE(l.unit_cost_brl, s.stock_unit_cost_brl)
    END AS gross_margin_brl,
    CASE
        WHEN COALESCE(lp.sale_price_brl, CASE WHEN p.orders_30d > 0 THEN p.sales_30d / p.orders_30d ELSE NULL END) > 0
         AND COALESCE(l.unit_cost_brl, s.stock_unit_cost_brl) IS NOT NULL
        THEN (
            COALESCE(lp.sale_price_brl, CASE WHEN p.orders_30d > 0 THEN p.sales_30d / p.orders_30d ELSE NULL END) - COALESCE(l.unit_cost_brl, s.stock_unit_cost_brl)
        ) / COALESCE(lp.sale_price_brl, CASE WHEN p.orders_30d > 0 THEN p.sales_30d / p.orders_30d ELSE NULL END)
    END AS gross_margin_pct,
    p.campaign_count,
    c.campaigns,
    (COALESCE(l.unit_cost_brl, s.stock_unit_cost_brl) IS NOT NULL AND COALESCE(l.unit_cost_brl, s.stock_unit_cost_brl) > 0) AS has_unit_cost,
    (COALESCE(s.stock_available, l.internal_quantity) IS NOT NULL AND COALESCE(s.stock_available, l.internal_quantity) > 0) AS has_stock,
    (
        COALESCE(lp.sale_price_brl, CASE WHEN p.orders_30d > 0 THEN p.sales_30d / p.orders_30d ELSE NULL END) > 0
        AND COALESCE(l.unit_cost_brl, s.stock_unit_cost_brl) > 0
        AND COALESCE(s.stock_available, l.internal_quantity) > 0
    ) AS economics_ready
FROM product_level p
JOIN campaign_json c ON c.tenant_id = p.tenant_id AND c.product_asin = p.product_asin
LEFT JOIN listing l ON l.asin = p.product_asin
LEFT JOIN listing_price lp ON lp.asin = p.product_asin
LEFT JOIN stock s ON UPPER(s.sku) = UPPER(COALESCE(l.zanom_sku, l.seller_sku, lp.seller_sku, p.seller_sku));

COMMENT ON VIEW marketcloud_gold.full_control_product_candidates_v1 IS
    'Produtos candidatos a Full Control. Deriva campanhas por ASIN e usa estoque unificado SWARM: stock_position local + fases fisicas FBA.';

CREATE OR REPLACE VIEW marketcloud_gold.full_control_effective_governance_v1 AS
WITH today AS (
    SELECT
        campaign_id,
        COALESCE(SUM(spend),0)::numeric AS spend_today,
        COALESCE(SUM(orders_7d),0)::numeric AS orders_today,
        COALESCE(SUM(sales_7d),0)::numeric AS sales_today,
        MAX(updated_at) AS last_ams_update
    FROM marketcloud_bronze.bronze_ams_hourly
    WHERE data_date = CURRENT_DATE
    GROUP BY campaign_id
), latest_campaign AS (
    SELECT DISTINCT ON (campaign_id)
        campaign_id,
        campaign_name,
        budget_amount::numeric AS current_budget_brl,
        budget_type,
        campaign_status,
        date AS last_report_date,
        synced_at
    FROM swarm_src.amazon_ads_campaigns_daily
    WHERE campaign_id IS NOT NULL
    ORDER BY campaign_id, date DESC NULLS LAST, synced_at DESC NULLS LAST
), effective AS (
    SELECT
        p.*,
        COALESCE(c.sale_price_brl, p.sale_price_brl) AS effective_sale_price_brl,
        COALESCE(c.unit_cost_brl, p.unit_cost_brl) AS effective_unit_cost_brl,
        COALESCE(c.stock_available, p.stock_available) AS effective_stock_available,
        c.stock_local_available,
        c.stock_fba_available,
        c.stock_source,
        c.stock_updated_at,
        c.unit_cost_source
    FROM marketcloud_control.full_control_pilots p
    LEFT JOIN marketcloud_gold.full_control_product_candidates_v1 c
      ON c.tenant_id = p.tenant_id
     AND c.product_asin = p.product_asin
)
SELECT
    e.pilot_id,
    e.tenant_id,
    e.product_asin,
    e.seller_sku,
    e.product_title,
    e.campaign_id,
    e.campaign_name,
    e.mode,
    e.status,
    e.effective_sale_price_brl AS sale_price_brl,
    e.effective_unit_cost_brl AS unit_cost_brl,
    e.effective_stock_available AS stock_available,
    CASE WHEN e.effective_sale_price_brl IS NOT NULL AND e.effective_unit_cost_brl IS NOT NULL THEN e.effective_sale_price_brl - e.effective_unit_cost_brl END AS gross_margin_brl,
    CASE WHEN e.effective_sale_price_brl > 0 AND e.effective_unit_cost_brl IS NOT NULL THEN (e.effective_sale_price_brl - e.effective_unit_cost_brl) / e.effective_sale_price_brl END AS gross_margin_pct,
    e.stock_local_available,
    e.stock_fba_available,
    e.stock_source,
    e.stock_updated_at,
    e.unit_cost_source,
    e.max_daily_budget_brl,
    e.max_spend_without_order_brl,
    e.min_roas,
    e.max_acos,
    COALESCE(t.spend_today,0)::numeric AS spend_today,
    COALESCE(t.orders_today,0)::numeric AS orders_today,
    COALESCE(t.sales_today,0)::numeric AS sales_today,
    CASE WHEN COALESCE(t.spend_today,0) > 0 THEN COALESCE(t.sales_today,0) / NULLIF(t.spend_today,0) ELSE 0 END AS roas_today,
    lc.current_budget_brl,
    lc.budget_type,
    lc.campaign_status,
    lc.last_report_date,
    t.last_ams_update,
    (
        e.effective_sale_price_brl IS NOT NULL AND e.effective_sale_price_brl > 0
        AND e.effective_unit_cost_brl IS NOT NULL AND e.effective_unit_cost_brl > 0
        AND e.effective_stock_available IS NOT NULL AND e.effective_stock_available > 0
    ) AS economics_ready,
    (
        e.mode = 'full_control'
        AND e.status = 'active'
        AND e.effective_sale_price_brl IS NOT NULL AND e.effective_sale_price_brl > 0
        AND e.effective_unit_cost_brl IS NOT NULL AND e.effective_unit_cost_brl > 0
        AND e.effective_stock_available IS NOT NULL AND e.effective_stock_available > 0
        AND e.max_daily_budget_brl > 0
        AND e.max_spend_without_order_brl > 0
        AND COALESCE(t.spend_today,0) < e.max_daily_budget_brl
        AND NOT (COALESCE(t.orders_today,0) = 0 AND COALESCE(t.spend_today,0) >= e.max_spend_without_order_brl)
    ) AS can_control,
    CASE
        WHEN e.mode <> 'full_control' THEN 'NOT_FULL_CONTROL'
        WHEN e.status <> 'active' THEN 'PILOT_NOT_ACTIVE'
        WHEN e.effective_sale_price_brl IS NULL OR e.effective_sale_price_brl <= 0 THEN 'MISSING_PRICE'
        WHEN e.effective_unit_cost_brl IS NULL OR e.effective_unit_cost_brl <= 0 THEN 'MISSING_COST'
        WHEN e.effective_stock_available IS NULL OR e.effective_stock_available <= 0 THEN 'NO_STOCK'
        WHEN e.max_daily_budget_brl <= 0 THEN 'MISSING_DAILY_BUDGET'
        WHEN e.max_spend_without_order_brl <= 0 THEN 'MISSING_NO_ORDER_CAP'
        WHEN COALESCE(t.spend_today,0) >= e.max_daily_budget_brl THEN 'DAILY_BUDGET_CAP_REACHED'
        WHEN COALESCE(t.orders_today,0) = 0 AND COALESCE(t.spend_today,0) >= e.max_spend_without_order_brl THEN 'SPEND_WITHOUT_ORDER_CAP_REACHED'
        ELSE 'READY'
    END AS gate_reason,
    e.updated_at
FROM effective e
LEFT JOIN today t ON t.campaign_id = e.campaign_id
LEFT JOIN latest_campaign lc ON lc.campaign_id = e.campaign_id;

COMMENT ON VIEW marketcloud_gold.full_control_effective_governance_v1 IS
    'Governanca efetiva de Full Control usando economia atual do produto, estoque unificado SWARM e tetos do piloto.';
