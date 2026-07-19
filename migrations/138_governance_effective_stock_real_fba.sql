-- 138 - full_control_effective_governance_v1: a trava NO_STOCK do executor passa
-- a usar o ESTOQUE FBA REAL (swarm_src.amazon_fba_inventory.available_quantity,
-- sincronizado da Amazon), nao o candidato/manual defasado.
--
-- Motivo (auditoria 2026-07-19, aprovado pelo dono): effective_stock_available
-- era COALESCE(c.stock_available, p.stock_available) = candidato/manual. Ex.:
-- Forma Silicone mostrava 99, FBA real=33. Se o estoque real zerasse, o executor
-- continuaria vendo 99 e NAO dispararia NO_STOCK -> gastaria em produto esgotado.
--
-- Fix: effective_stock_available = COALESCE(FBA ao vivo, candidato, manual).
-- Fallback preserva o comportamento se o FBA faltar; nunca bloqueia por join
-- vazio. Unica mudanca vs a definicao anterior: a CTE fba + o COALESCE do estoque.

CREATE OR REPLACE VIEW marketcloud_gold.full_control_effective_governance_v1 AS
WITH today AS (
    SELECT i.campaign_id,
        COALESCE(sum(u.spend), 0::numeric) AS spend_today,
        COALESCE(sum(u.orders_7d), 0::numeric) AS orders_today,
        COALESCE(sum(u.sales_7d), 0::numeric) AS sales_today,
        max(((u.data_date::timestamp without time zone + u.event_hour::double precision * '01:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text)) AS last_ams_update
    FROM marketcloud_gold.gold_hourly_signal_unified u
        JOIN marketcloud_gold.gold_campaign_identity i ON i.campaign_norm = lower(TRIM(BOTH FROM u.campaign_name))
    WHERE u.data_date = CURRENT_DATE
    GROUP BY i.campaign_id
), latest_campaign AS (
    SELECT DISTINCT ON (amazon_ads_campaigns_daily.campaign_id) amazon_ads_campaigns_daily.campaign_id,
        amazon_ads_campaigns_daily.campaign_name,
        amazon_ads_campaigns_daily.budget_amount::numeric AS current_budget_brl,
        amazon_ads_campaigns_daily.budget_type,
        amazon_ads_campaigns_daily.campaign_status,
        amazon_ads_campaigns_daily.date AS last_report_date,
        amazon_ads_campaigns_daily.synced_at
    FROM swarm_src.amazon_ads_campaigns_daily
    WHERE amazon_ads_campaigns_daily.campaign_id IS NOT NULL
    ORDER BY amazon_ads_campaigns_daily.campaign_id, amazon_ads_campaigns_daily.date DESC NULLS LAST, amazon_ads_campaigns_daily.synced_at DESC NULLS LAST
), fba AS (
    -- Estoque disponivel real na Amazon (FBA), agregado por ASIN.
    SELECT fi.asin,
        SUM(COALESCE(fi.available_quantity, 0))::numeric AS available_quantity
    FROM swarm_src.amazon_fba_inventory fi
    WHERE COALESCE(fi.asin, ''::text) <> ''::text
    GROUP BY fi.asin
), effective AS (
    SELECT p.pilot_id,
        p.tenant_id,
        p.product_asin,
        p.seller_sku,
        p.product_title,
        p.campaign_id,
        p.campaign_name,
        p.mode,
        p.status,
        p.sale_price_brl,
        p.unit_cost_brl,
        p.stock_available,
        p.gross_margin_brl,
        p.gross_margin_pct,
        p.max_daily_budget_brl,
        p.max_spend_without_order_brl,
        p.min_roas,
        p.max_acos,
        p.start_at,
        p.end_at,
        p.notes,
        p.created_by,
        p.updated_by,
        p.created_at,
        p.updated_at,
        p.max_top_of_search_pct,
        p.max_product_page_pct,
        p.max_rest_of_search_pct,
        p.strategy_config,
        COALESCE(c.sale_price_brl, p.sale_price_brl) AS effective_sale_price_brl,
        COALESCE(c.unit_cost_brl, p.unit_cost_brl) AS effective_unit_cost_brl,
        COALESCE(f.available_quantity, c.stock_available, p.stock_available) AS effective_stock_available,
        c.stock_local_available,
        COALESCE(f.available_quantity, c.stock_fba_available) AS stock_fba_available,
        c.stock_source,
        c.stock_updated_at,
        c.unit_cost_source
    FROM marketcloud_control.full_control_pilots p
        LEFT JOIN marketcloud_gold.full_control_product_candidates_v1 c ON c.tenant_id = p.tenant_id AND c.product_asin = p.product_asin
        LEFT JOIN fba f ON f.asin = p.product_asin
)
SELECT e.pilot_id,
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
    CASE
        WHEN e.effective_sale_price_brl IS NOT NULL AND e.effective_unit_cost_brl IS NOT NULL THEN e.effective_sale_price_brl - e.effective_unit_cost_brl
        ELSE NULL::numeric
    END AS gross_margin_brl,
    CASE
        WHEN e.effective_sale_price_brl > 0::numeric AND e.effective_unit_cost_brl IS NOT NULL THEN (e.effective_sale_price_brl - e.effective_unit_cost_brl) / e.effective_sale_price_brl
        ELSE NULL::numeric
    END AS gross_margin_pct,
    e.stock_local_available,
    e.stock_fba_available,
    e.stock_source,
    e.stock_updated_at,
    e.unit_cost_source,
    e.max_daily_budget_brl,
    e.max_spend_without_order_brl,
    e.min_roas,
    e.max_acos,
    COALESCE(t.spend_today, 0::numeric) AS spend_today,
    COALESCE(t.orders_today, 0::numeric) AS orders_today,
    COALESCE(t.sales_today, 0::numeric) AS sales_today,
    CASE
        WHEN COALESCE(t.spend_today, 0::numeric) > 0::numeric THEN COALESCE(t.sales_today, 0::numeric) / NULLIF(t.spend_today, 0::numeric)
        ELSE 0::numeric
    END AS roas_today,
    lc.current_budget_brl,
    lc.budget_type,
    lc.campaign_status,
    lc.last_report_date,
    t.last_ams_update,
    e.effective_sale_price_brl IS NOT NULL AND e.effective_sale_price_brl > 0::numeric AND e.effective_unit_cost_brl IS NOT NULL AND e.effective_unit_cost_brl > 0::numeric AND e.effective_stock_available IS NOT NULL AND e.effective_stock_available > 0::numeric AS economics_ready,
    e.mode = 'full_control'::text AND e.status = 'active'::text AND e.effective_sale_price_brl IS NOT NULL AND e.effective_sale_price_brl > 0::numeric AND e.effective_unit_cost_brl IS NOT NULL AND e.effective_unit_cost_brl > 0::numeric AND e.effective_stock_available IS NOT NULL AND e.effective_stock_available > 0::numeric AND e.max_daily_budget_brl > 0::numeric AND e.max_spend_without_order_brl > 0::numeric AND COALESCE(t.spend_today, 0::numeric) < e.max_daily_budget_brl AND NOT (COALESCE(t.orders_today, 0::numeric) = 0::numeric AND COALESCE(t.spend_today, 0::numeric) >= e.max_spend_without_order_brl) AS can_control,
    CASE
        WHEN e.mode <> 'full_control'::text THEN 'NOT_FULL_CONTROL'::text
        WHEN e.status <> 'active'::text THEN 'PILOT_NOT_ACTIVE'::text
        WHEN e.effective_sale_price_brl IS NULL OR e.effective_sale_price_brl <= 0::numeric THEN 'MISSING_PRICE'::text
        WHEN e.effective_unit_cost_brl IS NULL OR e.effective_unit_cost_brl <= 0::numeric THEN 'MISSING_COST'::text
        WHEN e.effective_stock_available IS NULL OR e.effective_stock_available <= 0::numeric THEN 'NO_STOCK'::text
        WHEN e.max_daily_budget_brl <= 0::numeric THEN 'MISSING_DAILY_BUDGET'::text
        WHEN e.max_spend_without_order_brl <= 0::numeric THEN 'MISSING_NO_ORDER_CAP'::text
        WHEN COALESCE(t.spend_today, 0::numeric) >= e.max_daily_budget_brl THEN 'DAILY_BUDGET_CAP_REACHED'::text
        WHEN COALESCE(t.orders_today, 0::numeric) = 0::numeric AND COALESCE(t.spend_today, 0::numeric) >= e.max_spend_without_order_brl THEN 'SPEND_WITHOUT_ORDER_CAP_REACHED'::text
        ELSE 'READY'::text
    END AS gate_reason,
    e.updated_at,
    e.max_top_of_search_pct,
    e.max_product_page_pct,
    e.max_rest_of_search_pct,
    e.strategy_config
FROM effective e
    LEFT JOIN today t ON t.campaign_id = e.campaign_id
    LEFT JOIN latest_campaign lc ON lc.campaign_id = e.campaign_id;
