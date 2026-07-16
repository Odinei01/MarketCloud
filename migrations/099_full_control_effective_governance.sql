-- =====================================================================
-- Full Control Effective Governance
--
-- Trava efetiva para o robo: so pode controlar campanha/produto se o piloto
-- estiver ativo, economico e dentro dos tetos de gasto/estoque.
-- =====================================================================

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
)
SELECT
    p.pilot_id,
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
        p.sale_price_brl IS NOT NULL AND p.sale_price_brl > 0
        AND p.unit_cost_brl IS NOT NULL AND p.unit_cost_brl > 0
        AND p.stock_available IS NOT NULL AND p.stock_available > 0
    ) AS economics_ready,
    (
        p.mode = 'full_control'
        AND p.status = 'active'
        AND p.sale_price_brl IS NOT NULL AND p.sale_price_brl > 0
        AND p.unit_cost_brl IS NOT NULL AND p.unit_cost_brl > 0
        AND p.stock_available IS NOT NULL AND p.stock_available > 0
        AND p.max_daily_budget_brl > 0
        AND p.max_spend_without_order_brl > 0
        AND COALESCE(t.spend_today,0) < p.max_daily_budget_brl
        AND NOT (COALESCE(t.orders_today,0) = 0 AND COALESCE(t.spend_today,0) >= p.max_spend_without_order_brl)
    ) AS can_control,
    CASE
        WHEN p.mode <> 'full_control' THEN 'NOT_FULL_CONTROL'
        WHEN p.status <> 'active' THEN 'PILOT_NOT_ACTIVE'
        WHEN p.sale_price_brl IS NULL OR p.sale_price_brl <= 0 THEN 'MISSING_PRICE'
        WHEN p.unit_cost_brl IS NULL OR p.unit_cost_brl <= 0 THEN 'MISSING_COST'
        WHEN p.stock_available IS NULL OR p.stock_available <= 0 THEN 'NO_STOCK'
        WHEN p.max_daily_budget_brl <= 0 THEN 'MISSING_DAILY_BUDGET'
        WHEN p.max_spend_without_order_brl <= 0 THEN 'MISSING_NO_ORDER_CAP'
        WHEN COALESCE(t.spend_today,0) >= p.max_daily_budget_brl THEN 'DAILY_BUDGET_CAP_REACHED'
        WHEN COALESCE(t.orders_today,0) = 0 AND COALESCE(t.spend_today,0) >= p.max_spend_without_order_brl THEN 'SPEND_WITHOUT_ORDER_CAP_REACHED'
        ELSE 'READY'
    END AS gate_reason,
    p.updated_at
FROM marketcloud_control.full_control_pilots p
LEFT JOIN today t ON t.campaign_id = p.campaign_id
LEFT JOIN latest_campaign lc ON lc.campaign_id = p.campaign_id;

COMMENT ON VIEW marketcloud_gold.full_control_effective_governance_v1 IS
    'Governanca efetiva de Full Control: piloto, economia, gasto do dia, estoque e motivo de bloqueio/liberacao para worker.';
