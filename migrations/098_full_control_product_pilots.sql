-- =====================================================================
-- Full Control Pilot por produto
--
-- Produto e o ponto de partida. Do ASIN/SKU derivamos campanhas e so entao
-- liberamos autonomia total do robo dentro de tetos economicos.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_control.full_control_pilots (
    pilot_id BIGSERIAL PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    product_asin TEXT NOT NULL,
    seller_sku TEXT,
    product_title TEXT,
    campaign_id TEXT NOT NULL,
    campaign_name TEXT NOT NULL,

    mode TEXT NOT NULL DEFAULT 'monitor_only',
    status TEXT NOT NULL DEFAULT 'draft',

    sale_price_brl NUMERIC(18,4),
    unit_cost_brl NUMERIC(18,4),
    stock_available NUMERIC(18,4),
    gross_margin_brl NUMERIC(18,4),
    gross_margin_pct NUMERIC(10,4),

    max_daily_budget_brl NUMERIC(18,4) NOT NULL DEFAULT 0,
    max_spend_without_order_brl NUMERIC(18,4) NOT NULL DEFAULT 0,
    min_roas NUMERIC(10,4) NOT NULL DEFAULT 4,
    max_acos NUMERIC(10,4),

    start_at TIMESTAMPTZ,
    end_at TIMESTAMPTZ,
    notes TEXT,
    created_by TEXT,
    updated_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_full_control_mode CHECK (mode IN ('monitor_only','semi_auto','full_control')),
    CONSTRAINT chk_full_control_status CHECK (status IN ('draft','active','paused','completed','archived')),
    CONSTRAINT uq_full_control_pilot UNIQUE (tenant_id, product_asin, campaign_id)
);

CREATE INDEX IF NOT EXISTS idx_full_control_pilots_tenant
    ON marketcloud_control.full_control_pilots (tenant_id, status, mode);
CREATE INDEX IF NOT EXISTS idx_full_control_pilots_product
    ON marketcloud_control.full_control_pilots (tenant_id, product_asin);
CREATE INDEX IF NOT EXISTS idx_full_control_pilots_campaign
    ON marketcloud_control.full_control_pilots (tenant_id, campaign_id);

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_listing_links (
    id bigint,
    asin text,
    seller_sku text,
    seller_sku_normalized text,
    zanom_product_name text,
    zanom_sku text,
    product_cost numeric(14,2),
    extra_cost numeric(14,2),
    link_status text,
    zanom_internal_quantity integer,
    zanom_cost_base numeric(14,2),
    zanom_cost_source text,
    updated_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_listing_links');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_listings (
    id bigint,
    asin text,
    seller_sku text,
    title text,
    status text,
    price numeric(14,2),
    currency text,
    last_synced_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_listings');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.stock_position (
    sku text,
    product_id text,
    qty_on_hand numeric(14,4),
    qty_available numeric(14,4),
    avg_cost numeric(14,4),
    replacement_cost numeric(14,4),
    last_purchase_cost numeric(14,4),
    updated_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'stock_position');

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
), stock AS (
    SELECT DISTINCT ON (sku)
        sku,
        qty_available AS stock_available,
        COALESCE(NULLIF(replacement_cost,0), NULLIF(avg_cost,0), NULLIF(last_purchase_cost,0)) AS stock_unit_cost_brl,
        updated_at
    FROM swarm_src.stock_position
    ORDER BY sku, updated_at DESC NULLS LAST
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
    COALESCE(s.stock_available, l.internal_quantity) AS stock_available,
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
LEFT JOIN stock s ON s.sku = COALESCE(l.zanom_sku, l.seller_sku, lp.seller_sku);

COMMENT ON VIEW marketcloud_gold.full_control_product_candidates_v1 IS
    'Produtos candidatos a Full Control. Deriva campanhas por ASIN anunciado via AMC/SWARM e mostra metricas recentes; custo/estoque entram na tabela full_control_pilots.';
