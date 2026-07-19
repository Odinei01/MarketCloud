-- =====================================================================
-- AMS x Amazon Ads reconciliation audit
--
-- Objetivo: auditar o que chega do Amazon Marketing Stream contra as fontes
-- Ads/reporting ja disponiveis no lake/SWARM, separando dados frescos,
-- janela de atribuicao e dias maduros. Nao muta dado; apenas cria leitura.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.v_ams_ads_reconciliation_daily_v1 AS
WITH ams_daily AS (
    SELECT
        a.data_date,
        a.campaign_id,
        COALESCE(i.campaign_name, MAX(NULLIF(a.campaign_name,'')), MAX(d.campaign_name)) AS campaign_name,
        SUM(COALESCE(a.impressions,0))::numeric AS ams_impressions_raw,
        SUM(COALESCE(a.clicks,0))::numeric AS ams_clicks_raw,
        SUM(COALESCE(a.spend,0))::numeric AS ams_spend_raw,
        SUM(GREATEST(COALESCE(a.impressions,0),0))::numeric AS ams_impressions_clamped,
        SUM(GREATEST(COALESCE(a.clicks,0),0))::numeric AS ams_clicks_clamped,
        SUM(GREATEST(COALESCE(a.spend,0),0))::numeric AS ams_spend_clamped,
        SUM(COALESCE(a.orders_1d,0))::numeric AS ams_orders_1d,
        SUM(COALESCE(a.sales_1d,0))::numeric AS ams_sales_1d,
        SUM(COALESCE(a.orders_7d,0))::numeric AS ams_orders_7d,
        SUM(COALESCE(a.sales_7d,0))::numeric AS ams_sales_7d,
        SUM(COALESCE(a.orders_14d,0))::numeric AS ams_orders_14d,
        SUM(COALESCE(a.sales_14d,0))::numeric AS ams_sales_14d,
        COUNT(*) AS ams_hour_rows,
        COUNT(*) FILTER (
            WHERE COALESCE(a.impressions,0)<0
               OR COALESCE(a.clicks,0)<0
               OR COALESCE(a.spend,0)<0
               OR COALESCE(a.orders_7d,0)<0
               OR COALESCE(a.sales_7d,0)<0
        ) AS ams_negative_rows,
        MAX(a.updated_at) AS ams_last_update
    FROM marketcloud_bronze.bronze_ams_hourly a
    LEFT JOIN marketcloud_gold.gold_campaign_identity i
      ON i.campaign_id = a.campaign_id
    LEFT JOIN swarm_src.amazon_ads_campaigns_daily d
      ON d.campaign_id = a.campaign_id
     AND d.date = a.data_date
    GROUP BY a.data_date, a.campaign_id, i.campaign_name
), ams_target_daily AS (
    SELECT
        data_date,
        campaign_id,
        SUM(COALESCE(impressions,0))::numeric AS target_impressions_raw,
        SUM(COALESCE(clicks,0))::numeric AS target_clicks_raw,
        SUM(COALESCE(spend,0))::numeric AS target_spend_raw,
        SUM(COALESCE(orders_7d,0))::numeric AS target_orders_7d,
        SUM(COALESCE(sales_7d,0))::numeric AS target_sales_7d,
        COUNT(*) AS target_rows,
        COUNT(DISTINCT target_entity_key) AS target_entities,
        COUNT(*) FILTER (
            WHERE COALESCE(impressions,0)<0
               OR COALESCE(clicks,0)<0
               OR COALESCE(spend,0)<0
               OR COALESCE(orders_7d,0)<0
               OR COALESCE(sales_7d,0)<0
        ) AS target_negative_rows,
        MAX(updated_at) AS target_last_update
    FROM marketcloud_bronze.bronze_ams_hourly_target
    GROUP BY data_date, campaign_id
), ads_daily AS (
    SELECT
        date AS data_date,
        campaign_id,
        MAX(campaign_name) AS ads_campaign_name,
        SUM(COALESCE(impressions,0))::numeric AS ads_impressions,
        SUM(COALESCE(clicks,0))::numeric AS ads_clicks,
        SUM(COALESCE(cost,0))::numeric AS ads_spend,
        SUM(COALESCE(purchases,0))::numeric AS ads_orders,
        SUM(COALESCE(attributed_sales,0))::numeric AS ads_sales,
        MAX(synced_at) AS ads_last_sync
    FROM swarm_src.amazon_ads_campaigns_daily
    WHERE campaign_id IS NOT NULL
    GROUP BY date, campaign_id
)
SELECT
    a.data_date,
    CASE
        WHEN a.data_date >= CURRENT_DATE - 1 THEN 'D0_D1_FRESH'
        WHEN a.data_date >= CURRENT_DATE - 7 THEN 'D2_D7_ATTRIBUTING'
        ELSE 'D8_PLUS_MATURE_OR_DELTA'
    END AS maturity_bucket,
    a.campaign_id,
    COALESCE(a.campaign_name, d.ads_campaign_name, 'campaign ' || a.campaign_id) AS campaign_name,
    a.ams_hour_rows,
    COALESCE(t.target_rows,0) AS target_rows,
    COALESCE(t.target_entities,0) AS target_entities,
    a.ams_negative_rows,
    COALESCE(t.target_negative_rows,0) AS target_negative_rows,
    a.ams_impressions_raw,
    a.ams_clicks_raw,
    a.ams_spend_raw,
    a.ams_impressions_clamped,
    a.ams_clicks_clamped,
    a.ams_spend_clamped,
    a.ams_orders_7d,
    a.ams_sales_7d,
    COALESCE(t.target_impressions_raw,0) AS target_impressions_raw,
    COALESCE(t.target_clicks_raw,0) AS target_clicks_raw,
    COALESCE(t.target_spend_raw,0) AS target_spend_raw,
    COALESCE(t.target_orders_7d,0) AS target_orders_7d,
    COALESCE(t.target_sales_7d,0) AS target_sales_7d,
    COALESCE(d.ads_impressions,0) AS ads_impressions,
    COALESCE(d.ads_clicks,0) AS ads_clicks,
    COALESCE(d.ads_spend,0) AS ads_spend,
    COALESCE(d.ads_orders,0) AS ads_orders,
    COALESCE(d.ads_sales,0) AS ads_sales,
    a.ams_impressions_clamped - COALESCE(d.ads_impressions,0) AS delta_ads_impressions,
    a.ams_clicks_clamped - COALESCE(d.ads_clicks,0) AS delta_ads_clicks,
    a.ams_spend_clamped - COALESCE(d.ads_spend,0) AS delta_ads_spend,
    a.ams_orders_7d - COALESCE(d.ads_orders,0) AS delta_ads_orders,
    a.ams_sales_7d - COALESCE(d.ads_sales,0) AS delta_ads_sales,
    a.ams_impressions_raw - COALESCE(t.target_impressions_raw,0) AS delta_target_impressions,
    a.ams_clicks_raw - COALESCE(t.target_clicks_raw,0) AS delta_target_clicks,
    a.ams_spend_raw - COALESCE(t.target_spend_raw,0) AS delta_target_spend,
    a.ams_orders_7d - COALESCE(t.target_orders_7d,0) AS delta_target_orders,
    a.ams_sales_7d - COALESCE(t.target_sales_7d,0) AS delta_target_sales,
    CASE
        WHEN d.campaign_id IS NULL THEN 'ADS_DAILY_MISSING'
        WHEN a.data_date >= CURRENT_DATE - 1 THEN 'FRESH_NOT_EXPECTED_TO_MATCH_DAILY'
        WHEN a.data_date >= CURRENT_DATE - 7 THEN 'ATTRIBUTION_WINDOW_NOT_FINAL'
        WHEN a.ams_negative_rows > 0 AND a.ams_impressions_clamped = 0 AND a.ams_spend_clamped = 0 THEN 'AMS_DELTA_ONLY'
        WHEN abs(a.ams_spend_clamped - COALESCE(d.ads_spend,0)) <= 0.05
         AND abs(a.ams_clicks_clamped - COALESCE(d.ads_clicks,0)) <= 1 THEN 'MATCH'
        ELSE 'CHECK_DELTA'
    END AS reconciliation_status,
    a.ams_last_update,
    t.target_last_update,
    d.ads_last_sync
FROM ams_daily a
LEFT JOIN ams_target_daily t USING (data_date, campaign_id)
LEFT JOIN ads_daily d USING (data_date, campaign_id);

COMMENT ON VIEW marketcloud_gold.v_ams_ads_reconciliation_daily_v1 IS
    'Reconcilia AMS campanha/target com Ads daily/reporting por dia/campanha, separando fresco, atribuicao e deltas.';

CREATE OR REPLACE VIEW marketcloud_gold.v_ams_quality_audit_v1 AS
WITH campaign AS (
    SELECT
        COUNT(*) AS rows,
        MIN(data_date) AS min_date,
        MAX(data_date) AS max_date,
        MAX(updated_at) AS last_updated,
        COUNT(*) FILTER (WHERE COALESCE(impressions,0)>0 OR COALESCE(clicks,0)>0 OR COALESCE(spend,0)>0) AS traffic_rows,
        COUNT(*) FILTER (WHERE COALESCE(orders_7d,0)>0 OR COALESCE(sales_7d,0)>0) AS conversion_rows,
        COUNT(*) FILTER (WHERE campaign_name IS NULL OR campaign_name='') AS blank_campaign_name,
        COUNT(*) FILTER (WHERE COALESCE(impressions,0)<0 OR COALESCE(clicks,0)<0 OR COALESCE(spend,0)<0 OR COALESCE(orders_7d,0)<0 OR COALESCE(sales_7d,0)<0) AS negative_rows,
        SUM(COALESCE(impressions,0)) AS impressions,
        SUM(COALESCE(clicks,0)) AS clicks,
        SUM(COALESCE(spend,0)) AS spend,
        SUM(COALESCE(orders_7d,0)) AS orders_7d,
        SUM(COALESCE(sales_7d,0)) AS sales_7d
    FROM marketcloud_bronze.bronze_ams_hourly
), target AS (
    SELECT
        COUNT(*) AS rows,
        COUNT(DISTINCT campaign_id) AS campaigns,
        COUNT(DISTINCT target_entity_key) AS targets,
        MIN(data_date) AS min_date,
        MAX(data_date) AS max_date,
        MAX(updated_at) AS last_updated,
        COUNT(*) FILTER (WHERE COALESCE(impressions,0)>0 OR COALESCE(clicks,0)>0 OR COALESCE(spend,0)>0) AS traffic_rows,
        COUNT(*) FILTER (WHERE COALESCE(orders_7d,0)>0 OR COALESCE(sales_7d,0)>0) AS conversion_rows,
        COUNT(*) FILTER (WHERE COALESCE(keyword_text,targeting,'')='') AS blank_target_text,
        COUNT(*) FILTER (WHERE COALESCE(impressions,0)<0 OR COALESCE(clicks,0)<0 OR COALESCE(spend,0)<0 OR COALESCE(orders_7d,0)<0 OR COALESCE(sales_7d,0)<0) AS negative_rows,
        SUM(COALESCE(impressions,0)) AS impressions,
        SUM(COALESCE(clicks,0)) AS clicks,
        SUM(COALESCE(spend,0)) AS spend,
        SUM(COALESCE(orders_7d,0)) AS orders_7d,
        SUM(COALESCE(sales_7d,0)) AS sales_7d
    FROM marketcloud_bronze.bronze_ams_hourly_target
), rec AS (
    SELECT
        COUNT(*) AS rows,
        COUNT(*) FILTER (WHERE reconciliation_status = 'MATCH') AS match_rows,
        COUNT(*) FILTER (WHERE reconciliation_status = 'CHECK_DELTA') AS check_delta_rows,
        COUNT(*) FILTER (WHERE reconciliation_status = 'ADS_DAILY_MISSING') AS ads_missing_rows,
        COUNT(*) FILTER (WHERE reconciliation_status = 'AMS_DELTA_ONLY') AS delta_only_rows,
        COUNT(*) FILTER (WHERE reconciliation_status IN ('FRESH_NOT_EXPECTED_TO_MATCH_DAILY','ATTRIBUTION_WINDOW_NOT_FINAL')) AS expected_lag_rows,
        SUM(delta_target_impressions) AS sum_delta_target_impressions,
        SUM(delta_target_clicks) AS sum_delta_target_clicks,
        SUM(delta_target_spend) AS sum_delta_target_spend,
        SUM(delta_target_orders) AS sum_delta_target_orders,
        SUM(delta_target_sales) AS sum_delta_target_sales
    FROM marketcloud_gold.v_ams_ads_reconciliation_daily_v1
)
SELECT 'AMS_CAMPAIGN' AS audit_area, to_jsonb(campaign.*) AS payload FROM campaign
UNION ALL
SELECT 'AMS_TARGET', to_jsonb(target.*) FROM target
UNION ALL
SELECT 'RECONCILIATION', to_jsonb(rec.*) FROM rec;

COMMENT ON VIEW marketcloud_gold.v_ams_quality_audit_v1 IS
    'Resumo de qualidade AMS: volume, negativos/deltas, conversoes e status de reconciliacao com Ads/reporting.';
