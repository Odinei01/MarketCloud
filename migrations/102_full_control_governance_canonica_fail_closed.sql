-- =====================================================================
-- Full Control governance: fonte canonica para gasto/pedido do dia.
--
-- A versao anterior lia marketcloud_bronze.bronze_ams_hourly, que e cega
-- para parte do funil/ad products. O gate economico precisa usar a mesma
-- fonte canonica do Audit 360: gold_hourly_signal_unified + identidade.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.full_control_effective_governance_v1 AS
WITH today AS (
    SELECT
        i.campaign_id,
        COALESCE(SUM(u.spend),0)::numeric AS spend_today,
        COALESCE(SUM(u.orders_7d),0)::numeric AS orders_today,
        COALESCE(SUM(u.sales_7d),0)::numeric AS sales_today,
        MAX((u.data_date::timestamp + (u.event_hour * interval '1 hour')) AT TIME ZONE 'America/Sao_Paulo') AS last_ams_update
    FROM marketcloud_gold.gold_hourly_signal_unified u
    JOIN marketcloud_gold.gold_campaign_identity i
      ON i.campaign_norm = lower(trim(u.campaign_name))
    WHERE u.data_date = CURRENT_DATE
    GROUP BY i.campaign_id
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
    'Governanca efetiva de Full Control usando economia atual, estoque unificado SWARM e gasto/pedido diario da fonte canonica gold_hourly_signal_unified.';
