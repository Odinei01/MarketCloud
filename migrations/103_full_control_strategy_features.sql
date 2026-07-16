-- =====================================================================
-- Full Control Strategy Features
--
-- Feature view para o ML campanha x hora aprender nao apenas "hora boa",
-- mas tambem o contexto economico/operacional do piloto:
-- budget, stop loss, estoque/margem, top-of-search e placement traffic.
--
-- Nao usa orders/sales/roas como feature; esses continuam sendo labels.
-- =====================================================================

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
    CASE WHEN COALESCE(pl.rest_search_clicks,0) > 0 THEN COALESCE(pl.rest_search_spend,0) / NULLIF(pl.rest_search_clicks,0) ELSE 0 END AS rest_search_cpc_45d
FROM hourly h
LEFT JOIN latest_structure ls ON ls.campaign_id = h.campaign_id
LEFT JOIN placement pl ON pl.campaign_id = h.campaign_id
LEFT JOIN pilot p ON p.campaign_id = h.campaign_id;

COMMENT ON VIEW marketcloud_features.feature_full_control_campaign_hour_v1 IS
    'Features campanha x hora para ML Full Control: horario + funil AMC + budget + stop loss + produto + placement traffic, sem orders/sales/roas como X.';
