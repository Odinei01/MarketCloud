-- =====================================================================
-- Amazon Ads Reporting API v3 executor storage
--
-- Guarda reports oficiais reprocessados dentro do MarketCloud. A
-- reconciliacao AMS x Ads passa a preferir essa fonte local quando existir,
-- caindo para o FDW `swarm_src.amazon_ads_campaigns_daily` quando ainda nao
-- houver reprocessamento v3.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_ops.ads_reporting_sp_campaign_daily_v3 (
    profile_id TEXT NOT NULL,
    data_date DATE NOT NULL,
    campaign_id TEXT NOT NULL,
    campaign_name TEXT,
    campaign_status TEXT,
    impressions BIGINT NOT NULL DEFAULT 0,
    clicks BIGINT NOT NULL DEFAULT 0,
    cost NUMERIC(14,2) NOT NULL DEFAULT 0,
    attributed_sales NUMERIC(14,2) NOT NULL DEFAULT 0,
    purchases BIGINT NOT NULL DEFAULT 0,
    units_sold BIGINT NOT NULL DEFAULT 0,
    currency TEXT,
    report_id TEXT NOT NULL,
    raw_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    synced_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (profile_id, data_date, campaign_id)
);

COMMENT ON TABLE marketcloud_ops.ads_reporting_sp_campaign_daily_v3 IS
    'Sponsored Products campaign daily baixado do Amazon Ads Reporting API v3 para reconciliar AMS x Ads sem depender do FDW do SWARM.';

CREATE OR REPLACE VIEW marketcloud_gold.v_ads_campaigns_daily_effective_v1 AS
SELECT
    s.date AS data_date,
    s.profile_id,
    s.campaign_id,
    s.campaign_name,
    s.campaign_status,
    s.impressions::numeric AS impressions,
    s.clicks::numeric AS clicks,
    s.cost::numeric AS spend,
    s.purchases::numeric AS orders,
    s.attributed_sales::numeric AS sales,
    s.report_id,
    s.synced_at AS last_sync,
    'SWARM_FDW'::TEXT AS source
FROM swarm_src.amazon_ads_campaigns_daily s
WHERE NOT EXISTS (
    SELECT 1
    FROM marketcloud_ops.ads_reporting_sp_campaign_daily_v3 v3
    WHERE v3.profile_id = s.profile_id
      AND v3.data_date = s.date
      AND v3.campaign_id = s.campaign_id
)
UNION ALL
SELECT
    v3.data_date,
    v3.profile_id,
    v3.campaign_id,
    v3.campaign_name,
    v3.campaign_status,
    v3.impressions::numeric,
    v3.clicks::numeric,
    v3.cost::numeric,
    v3.purchases::numeric,
    v3.attributed_sales::numeric,
    v3.report_id,
    v3.synced_at,
    'ADS_REPORTING_V3'::TEXT AS source
FROM marketcloud_ops.ads_reporting_sp_campaign_daily_v3 v3;

COMMENT ON VIEW marketcloud_gold.v_ads_campaigns_daily_effective_v1 IS
    'Fonte efetiva de Ads daily: reports v3 reprocessados localmente sobrepoem o snapshot FDW do SWARM.';

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
    LEFT JOIN marketcloud_gold.v_ads_campaigns_daily_effective_v1 d
      ON d.campaign_id = a.campaign_id
     AND d.data_date = a.data_date
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
        data_date,
        campaign_id,
        MAX(campaign_name) AS ads_campaign_name,
        SUM(COALESCE(impressions,0))::numeric AS ads_impressions,
        SUM(COALESCE(clicks,0))::numeric AS ads_clicks,
        SUM(COALESCE(spend,0))::numeric AS ads_spend,
        SUM(COALESCE(orders,0))::numeric AS ads_orders,
        SUM(COALESCE(sales,0))::numeric AS ads_sales,
        MAX(last_sync) AS ads_last_sync,
        MAX(source) AS ads_source
    FROM marketcloud_gold.v_ads_campaigns_daily_effective_v1
    WHERE campaign_id IS NOT NULL
    GROUP BY data_date, campaign_id
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
    d.ads_last_sync,
    COALESCE(d.ads_source, 'NONE') AS ads_source
FROM ams_daily a
LEFT JOIN ams_target_daily t USING (data_date, campaign_id)
LEFT JOIN ads_daily d USING (data_date, campaign_id);

COMMENT ON VIEW marketcloud_gold.v_ams_ads_reconciliation_daily_v1 IS
    'Reconcilia AMS campanha/target com Ads daily/reporting por dia/campanha. Prefere Ads Reporting API v3 local quando reprocessado.';
