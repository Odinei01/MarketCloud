-- =====================================================================
-- Full Control commercial wizard strategy fields
--
-- Guarda a parametrizacao comercial do piloto alem dos tetos ja existentes:
-- budget, stop-loss, ROAS e limites de posicionamento. Esses campos sao
-- configuracao do piloto e tambem viram features para o ML.
-- =====================================================================

ALTER TABLE marketcloud_control.full_control_pilots
    ADD COLUMN IF NOT EXISTS max_top_of_search_pct NUMERIC(10,4) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS max_product_page_pct NUMERIC(10,4) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS max_rest_of_search_pct NUMERIC(10,4) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS strategy_config JSONB NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN marketcloud_control.full_control_pilots.max_top_of_search_pct IS
    'Limite/allowance de ajuste Top of Search definido no wizard comercial do piloto.';
COMMENT ON COLUMN marketcloud_control.full_control_pilots.max_product_page_pct IS
    'Limite/allowance de ajuste Product Page definido no wizard comercial do piloto.';
COMMENT ON COLUMN marketcloud_control.full_control_pilots.max_rest_of_search_pct IS
    'Limite/allowance de ajuste Rest of Search definido no wizard comercial do piloto.';
COMMENT ON COLUMN marketcloud_control.full_control_pilots.strategy_config IS
    'Snapshot JSON do wizard comercial: etapa, operador, observacoes e parametros auxiliares.';

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
    e.updated_at,
    e.max_top_of_search_pct,
    e.max_product_page_pct,
    e.max_rest_of_search_pct,
    e.strategy_config
FROM effective e
LEFT JOIN today t ON t.campaign_id = e.campaign_id
LEFT JOIN latest_campaign lc ON lc.campaign_id = e.campaign_id;

COMMENT ON VIEW marketcloud_gold.full_control_effective_governance_v1 IS
    'Governanca efetiva de Full Control usando economia atual, estoque unificado SWARM, gasto/pedido diario canonico e parametros comerciais do wizard.';

CREATE OR REPLACE VIEW marketcloud_features.feature_full_control_campaign_hour_v1 AS
WITH hourly AS (
    SELECT
        lower(trim(g.campaign_name)) AS campaign_norm,
        MAX(g.campaign_name) AS campaign_name,
        MAX(i.campaign_id) AS campaign_id,
        g.event_hour,
        COUNT(DISTINCT g.data_date) AS days_observed,
        SUM(g.impressions)::numeric AS impressions,
        SUM(g.clicks)::numeric AS clicks,
        SUM(g.spend)::numeric AS spend,
        COALESCE(SUM(g.orders_7d) FILTER (WHERE g.conversion_trustworthy),0)::numeric AS orders,
        COALESCE(SUM(g.sales_7d) FILTER (WHERE g.conversion_trustworthy),0)::numeric AS sales,
        COALESCE(SUM(g.spend) FILTER (WHERE g.conversion_trustworthy),0)::numeric AS spend_mature,
        COUNT(DISTINCT g.data_date) FILTER (WHERE g.conversion_trustworthy) AS mature_days,
        COALESCE(MAX(g.amc_assist_rate),0)::numeric AS amc_assist_rate,
        COALESCE(MAX(g.amc_first_touch_rate),0)::numeric AS amc_first_touch_rate,
        COALESCE(MAX(g.amc_new_customer_rate),0)::numeric AS amc_new_customer_rate,
        COALESCE(MAX(g.amc_dpv_count),0)::numeric AS amc_dpv_count,
        COALESCE(MAX(g.amc_cart_adds),0)::numeric AS amc_cart_adds,
        COALESCE(MAX(g.learn_roas_delta_avg),0)::numeric AS learn_roas_delta_avg,
        COALESCE(MAX(g.learn_win_rate),0.5)::numeric AS learn_win_rate,
        MAX(g.campaign_status) AS campaign_status
    FROM marketcloud_gold.gold_hourly_signal_amc g
    LEFT JOIN marketcloud_gold.gold_campaign_identity i
      ON i.campaign_norm = lower(trim(g.campaign_name))
    WHERE UPPER(COALESCE(g.campaign_status,'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
    GROUP BY lower(trim(g.campaign_name)), g.event_hour
), latest_structure AS (
    SELECT DISTINCT ON (campaign_id)
        campaign_id,
        budget_amount::numeric AS current_budget_brl,
        budget_type,
        bidding_strategy,
        COALESCE(top_of_search_bid_adjustment,0)::numeric AS top_of_search_bid_adjustment,
        campaign_status AS structure_campaign_status,
        synced_at AS structure_synced_at
    FROM swarm_src.amazon_ads_campaigns_daily
    WHERE COALESCE(campaign_id,'') <> ''
    ORDER BY campaign_id, date DESC NULLS LAST, synced_at DESC NULLS LAST
), placement AS (
    SELECT
        campaign_id,
        SUM(spend)::numeric AS placement_spend,
        SUM(clicks)::numeric AS placement_clicks,
        SUM(impressions)::numeric AS placement_impressions,
        SUM(spend) FILTER (WHERE placement_type = 'Top of Search on-Amazon')::numeric AS top_search_spend,
        SUM(clicks) FILTER (WHERE placement_type = 'Top of Search on-Amazon')::numeric AS top_search_clicks,
        SUM(impressions) FILTER (WHERE placement_type = 'Top of Search on-Amazon')::numeric AS top_search_impressions,
        SUM(spend) FILTER (WHERE placement_type = 'Detail Page on-Amazon')::numeric AS product_page_spend,
        SUM(clicks) FILTER (WHERE placement_type = 'Detail Page on-Amazon')::numeric AS product_page_clicks,
        SUM(impressions) FILTER (WHERE placement_type = 'Detail Page on-Amazon')::numeric AS product_page_impressions,
        SUM(spend) FILTER (WHERE placement_type = 'Other on-Amazon')::numeric AS rest_search_spend,
        SUM(clicks) FILTER (WHERE placement_type = 'Other on-Amazon')::numeric AS rest_search_clicks,
        SUM(impressions) FILTER (WHERE placement_type = 'Other on-Amazon')::numeric AS rest_search_impressions
    FROM marketcloud_silver.silver_placement_creative_daily
    WHERE COALESCE(campaign_id,'') <> ''
      AND data_date >= CURRENT_DATE - 45
    GROUP BY campaign_id
), pilot AS (
    SELECT DISTINCT ON (campaign_id)
        campaign_id,
        mode,
        status,
        COALESCE(sale_price_brl,0)::numeric AS sale_price_brl,
        COALESCE(unit_cost_brl,0)::numeric AS unit_cost_brl,
        COALESCE(stock_available,0)::numeric AS stock_available,
        COALESCE(gross_margin_brl,0)::numeric AS gross_margin_brl,
        COALESCE(gross_margin_pct,0)::numeric AS gross_margin_pct,
        COALESCE(max_daily_budget_brl,0)::numeric AS max_daily_budget_brl,
        COALESCE(max_spend_without_order_brl,0)::numeric AS max_spend_without_order_brl,
        COALESCE(min_roas,0)::numeric AS min_roas,
        COALESCE(max_top_of_search_pct,0)::numeric AS max_top_of_search_pct,
        COALESCE(max_product_page_pct,0)::numeric AS max_product_page_pct,
        COALESCE(max_rest_of_search_pct,0)::numeric AS max_rest_of_search_pct,
        COALESCE(current_budget_brl,0)::numeric AS governance_current_budget_brl,
        COALESCE(can_control,false) AS can_control,
        gate_reason
    FROM marketcloud_gold.full_control_effective_governance_v1
    WHERE COALESCE(campaign_id,'') <> ''
    ORDER BY campaign_id,
        CASE status WHEN 'active' THEN 0 WHEN 'draft' THEN 1 ELSE 2 END,
        updated_at DESC
)
SELECT
    h.campaign_norm,
    h.campaign_name,
    h.campaign_id,
    h.event_hour,
    h.days_observed,
    h.impressions,
    h.clicks,
    h.spend,
    h.orders,
    h.sales,
    h.spend_mature,
    h.mature_days,
    h.amc_assist_rate,
    h.amc_first_touch_rate,
    h.amc_new_customer_rate,
    h.amc_dpv_count,
    h.amc_cart_adds,
    h.learn_roas_delta_avg,
    h.learn_win_rate,
    COALESCE(ls.current_budget_brl, 0) AS current_budget_brl,
    CASE WHEN COALESCE(ls.current_budget_brl,0) > 0 THEN h.spend / NULLIF(ls.current_budget_brl,0) ELSE 0 END AS spend_to_budget_ratio,
    COALESCE(ls.top_of_search_bid_adjustment, 0) AS top_of_search_bid_adjustment,
    COALESCE(ls.top_of_search_bid_adjustment, 0) / 100.0 AS top_of_search_multiplier_delta,
    CASE WHEN ls.bidding_strategy ILIKE '%LEGACY%' THEN 1 ELSE 0 END AS bidding_legacy_for_sales,
    COALESCE(p.sale_price_brl,0) AS sale_price_brl,
    COALESCE(p.unit_cost_brl,0) AS unit_cost_brl,
    COALESCE(p.stock_available,0) AS stock_available,
    COALESCE(p.gross_margin_brl,0) AS gross_margin_brl,
    COALESCE(p.gross_margin_pct,0) AS gross_margin_pct,
    COALESCE(p.max_daily_budget_brl,0) AS max_daily_budget_brl,
    COALESCE(p.max_spend_without_order_brl,0) AS max_spend_without_order_brl,
    COALESCE(p.min_roas,0) AS min_roas,
    CASE WHEN COALESCE(p.max_daily_budget_brl,0) > 0 THEN h.spend / NULLIF(p.max_daily_budget_brl,0) ELSE 0 END AS spend_to_fc_daily_cap_ratio,
    CASE WHEN COALESCE(p.max_spend_without_order_brl,0) > 0 THEN h.spend / NULLIF(p.max_spend_without_order_brl,0) ELSE 0 END AS spend_to_stop_loss_ratio,
    CASE WHEN p.mode = 'full_control' THEN 1 ELSE 0 END AS is_full_control_pilot,
    CASE WHEN p.status = 'active' THEN 1 ELSE 0 END AS is_active_pilot,
    CASE WHEN COALESCE(p.can_control,false) THEN 1 ELSE 0 END AS can_control_flag,
    COALESCE(pl.placement_spend,0) AS placement_spend_45d,
    COALESCE(pl.placement_clicks,0) AS placement_clicks_45d,
    COALESCE(pl.placement_impressions,0) AS placement_impressions_45d,
    COALESCE(pl.top_search_spend,0) AS top_search_spend_45d,
    COALESCE(pl.product_page_spend,0) AS product_page_spend_45d,
    COALESCE(pl.rest_search_spend,0) AS rest_search_spend_45d,
    CASE WHEN COALESCE(pl.placement_spend,0) > 0 THEN COALESCE(pl.top_search_spend,0) / NULLIF(pl.placement_spend,0) ELSE 0 END AS top_search_spend_share_45d,
    CASE WHEN COALESCE(pl.placement_spend,0) > 0 THEN COALESCE(pl.product_page_spend,0) / NULLIF(pl.placement_spend,0) ELSE 0 END AS product_page_spend_share_45d,
    CASE WHEN COALESCE(pl.placement_spend,0) > 0 THEN COALESCE(pl.rest_search_spend,0) / NULLIF(pl.placement_spend,0) ELSE 0 END AS rest_search_spend_share_45d,
    CASE WHEN COALESCE(pl.top_search_clicks,0) > 0 THEN COALESCE(pl.top_search_spend,0) / NULLIF(pl.top_search_clicks,0) ELSE 0 END AS top_search_cpc_45d,
    CASE WHEN COALESCE(pl.product_page_clicks,0) > 0 THEN COALESCE(pl.product_page_spend,0) / NULLIF(pl.product_page_clicks,0) ELSE 0 END AS product_page_cpc_45d,
    CASE WHEN COALESCE(pl.rest_search_clicks,0) > 0 THEN COALESCE(pl.rest_search_spend,0) / NULLIF(pl.rest_search_clicks,0) ELSE 0 END AS rest_search_cpc_45d,
    COALESCE(p.max_top_of_search_pct,0) AS max_top_of_search_pct,
    COALESCE(p.max_product_page_pct,0) AS max_product_page_pct,
    COALESCE(p.max_rest_of_search_pct,0) AS max_rest_of_search_pct
FROM hourly h
LEFT JOIN latest_structure ls ON ls.campaign_id = h.campaign_id
LEFT JOIN placement pl ON pl.campaign_id = h.campaign_id
LEFT JOIN pilot p ON p.campaign_id = h.campaign_id;

COMMENT ON VIEW marketcloud_features.feature_full_control_campaign_hour_v1 IS
    'Features campanha x hora para ML Full Control: horario + funil AMC + budget + stop loss + produto + placement traffic + parametros comerciais do wizard, sem orders/sales/roas como X.';
