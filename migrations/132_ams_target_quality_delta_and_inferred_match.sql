-- =====================================================================
-- AMS target quality: classify broad negative restatements and infer
-- conversion-only AMS rows when Ads Reporting has a unique same ad-group/day
-- target row that covers the AMS conversion metrics.
-- =====================================================================

DROP VIEW IF EXISTS marketcloud_gold.v_ams_target_quality_features_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_gold.v_ams_target_ads_reconciliation_daily_v1 CASCADE;

CREATE OR REPLACE VIEW marketcloud_gold.v_ams_target_ads_reconciliation_daily_v1 AS
WITH ams AS (
    SELECT
        data_date,
        campaign_id,
        MAX(campaign_name) AS campaign_name,
        COALESCE(ad_group_id,'') AS ad_group_id,
        MAX(ad_group_name) AS ad_group_name,
        target_entity_key,
        MAX(keyword_id) AS keyword_id,
        MAX(target_id) AS target_id,
        MAX(keyword_text) AS keyword_text,
        MAX(targeting) AS targeting,
        COALESCE(NULLIF(MAX(match_type),''),'UNKNOWN') AS match_type,
        SUM(COALESCE(impressions,0))::numeric AS ams_impressions,
        SUM(COALESCE(clicks,0))::numeric AS ams_clicks,
        SUM(COALESCE(spend,0))::numeric AS ams_spend,
        SUM(GREATEST(COALESCE(orders_14d,0), COALESCE(orders_7d,0), COALESCE(orders_1d,0), 0))::numeric AS ams_orders,
        SUM(GREATEST(COALESCE(sales_14d,0), COALESCE(sales_7d,0), COALESCE(sales_1d,0), 0))::numeric AS ams_sales,
        COUNT(*) AS ams_hour_rows,
        MAX(updated_at) AS ams_last_update
    FROM marketcloud_bronze.bronze_ams_hourly_target
    WHERE NULLIF(TRIM(COALESCE(target_entity_key,'')), '') IS NOT NULL
    GROUP BY data_date, campaign_id, COALESCE(ad_group_id,''), target_entity_key
), ads AS (
    SELECT *
    FROM marketcloud_gold.v_ads_targeting_daily_effective_v1
), ads_dates AS (
    SELECT data_date, report_grain, COUNT(*) AS report_rows
    FROM ads
    GROUP BY data_date, report_grain
), ads_adgroup_counts AS (
    SELECT
        data_date,
        campaign_id,
        COALESCE(ad_group_id,'') AS ad_group_id,
        COUNT(*) AS adgroup_target_rows
    FROM ads
    GROUP BY data_date, campaign_id, COALESCE(ad_group_id,'')
)
SELECT
    a.data_date,
    a.campaign_id,
    COALESCE(NULLIF(a.campaign_name,''), d.campaign_name) AS campaign_name,
    a.ad_group_id,
    COALESCE(a.ad_group_name, d.ad_group_name) AS ad_group_name,
    a.target_entity_key,
    a.keyword_id,
    a.target_id,
    COALESCE(NULLIF(a.keyword_text,''), NULLIF(a.targeting,''), d.target_text) AS target_text,
    CASE WHEN a.match_type = 'UNKNOWN' AND d.match_type IS NOT NULL THEN d.match_type ELSE a.match_type END AS match_type,
    COALESCE(d.report_grain, CASE WHEN NULLIF(a.keyword_id,'') IS NOT NULL OR a.match_type IN ('BROAD','PHRASE','EXACT') THEN 'KEYWORD' ELSE 'TARGET' END) AS ads_report_grain,
    a.ams_impressions,
    a.ams_clicks,
    a.ams_spend,
    a.ams_orders,
    a.ams_sales,
    COALESCE(d.impressions,0)::numeric AS ads_impressions,
    COALESCE(d.clicks,0)::numeric AS ads_clicks,
    COALESCE(d.spend,0)::numeric AS ads_spend,
    COALESCE(d.orders,0)::numeric AS ads_orders,
    COALESCE(d.sales,0)::numeric AS ads_sales,
    a.ams_impressions - COALESCE(d.impressions,0)::numeric AS delta_impressions,
    a.ams_clicks - COALESCE(d.clicks,0)::numeric AS delta_clicks,
    a.ams_spend - COALESCE(d.spend,0)::numeric AS delta_spend,
    a.ams_orders - COALESCE(d.orders,0)::numeric AS delta_orders,
    a.ams_sales - COALESCE(d.sales,0)::numeric AS delta_sales,
    a.ams_hour_rows,
    a.ams_last_update,
    d.last_sync AS ads_last_sync,
    COALESCE(d.source, 'NONE') AS ads_source,
    COALESCE(ad.report_rows, 0) AS ads_report_rows_for_date,
    CASE
        WHEN LEAST(a.ams_impressions, a.ams_clicks, a.ams_spend, a.ams_orders, a.ams_sales) < 0 THEN 'RESTATEMENT_DELTA'
        WHEN a.ams_impressions = 0 AND a.ams_clicks = 0 AND a.ams_spend = 0 AND (a.ams_orders > 0 OR a.ams_sales > 0) THEN 'CONVERSION_DELTA'
        WHEN a.ams_impressions = 0 AND a.ams_clicks = 0 AND a.ams_spend = 0 AND a.ams_orders = 0 AND a.ams_sales = 0 THEN 'ZERO_DELTA'
        WHEN a.data_date >= CURRENT_DATE - 1 THEN 'FRESH'
        WHEN COALESCE(ad.report_rows, 0) = 0 THEN 'ADS_REPORT_MISSING'
        WHEN d.target_entity_key IS NULL THEN 'ADS_TARGETING_MISSING'
        WHEN a.data_date >= CURRENT_DATE - 7 THEN 'ATTRIBUTING'
        WHEN abs(a.ams_spend - COALESCE(d.spend,0)::numeric) <= 0.05
         AND abs(a.ams_clicks - COALESCE(d.clicks,0)::numeric) <= 1 THEN 'MATCH'
        ELSE 'DIVERGENT'
    END AS target_quality_status,
    CASE
        WHEN LEAST(a.ams_impressions, a.ams_clicks, a.ams_spend, a.ams_orders, a.ams_sales) < 0 THEN 88
        WHEN a.ams_impressions = 0 AND a.ams_clicks = 0 AND a.ams_spend = 0 AND (a.ams_orders > 0 OR a.ams_sales > 0) THEN 82
        WHEN a.ams_impressions = 0 AND a.ams_clicks = 0 AND a.ams_spend = 0 AND a.ams_orders = 0 AND a.ams_sales = 0 THEN 78
        WHEN a.data_date >= CURRENT_DATE - 1 THEN 68
        WHEN COALESCE(ad.report_rows, 0) = 0 THEN 50
        WHEN d.target_entity_key IS NULL THEN 45
        WHEN a.data_date >= CURRENT_DATE - 7 THEN 72
        WHEN abs(a.ams_spend - COALESCE(d.spend,0)::numeric) <= 0.05
         AND abs(a.ams_clicks - COALESCE(d.clicks,0)::numeric) <= 1 THEN 95
        ELSE 35
    END::INT AS target_quality_score
FROM ams a
LEFT JOIN LATERAL (
    SELECT d.*
    FROM ads d
    LEFT JOIN ads_adgroup_counts c
      ON c.data_date = d.data_date
     AND c.campaign_id = d.campaign_id
     AND c.ad_group_id = COALESCE(d.ad_group_id,'')
    WHERE d.data_date = a.data_date
      AND (d.campaign_id = a.campaign_id OR COALESCE(d.ad_group_id,'') = COALESCE(a.ad_group_id,''))
      AND COALESCE(d.ad_group_id,'') = COALESCE(a.ad_group_id,'')
      AND (
            (NULLIF(a.keyword_id,'') IS NOT NULL AND d.keyword_id = a.keyword_id)
         OR (NULLIF(a.target_id,'') IS NOT NULL AND d.target_id = a.target_id)
         OR d.target_entity_key = a.target_entity_key
         OR (NULLIF(a.keyword_text,'') IS NOT NULL AND lower(trim(d.target_text)) = lower(trim(a.keyword_text)))
         OR (NULLIF(a.targeting,'') IS NOT NULL AND lower(trim(d.target_text)) = lower(trim(a.targeting)))
         OR (
                a.ams_impressions = 0
            AND a.ams_clicks = 0
            AND a.ams_spend = 0
            AND a.ams_orders = COALESCE(d.orders,0)::numeric
            AND abs(a.ams_sales - COALESCE(d.sales,0)::numeric) <= 0.05
         )
         OR (
                a.ams_impressions = 0
            AND a.ams_clicks = 0
            AND a.ams_spend = 0
            AND a.ams_orders > 0
            AND COALESCE(c.adgroup_target_rows,0) = 1
            AND COALESCE(d.orders,0)::numeric >= a.ams_orders
            AND COALESCE(d.sales,0)::numeric >= a.ams_sales
         )
      )
    ORDER BY
      CASE WHEN d.target_entity_key = a.target_entity_key THEN 0 ELSE 1 END,
      CASE
        WHEN a.ams_impressions = 0 AND a.ams_clicks = 0 AND a.ams_spend = 0
         AND a.ams_orders > 0
         AND COALESCE(c.adgroup_target_rows,0) = 1
         AND COALESCE(d.orders,0)::numeric >= a.ams_orders
         AND COALESCE(d.sales,0)::numeric >= a.ams_sales THEN 0
        ELSE 1
      END,
      d.last_sync DESC NULLS LAST
    LIMIT 1
) d ON TRUE
LEFT JOIN ads_dates ad
  ON ad.data_date = a.data_date
 AND ad.report_grain = COALESCE(d.report_grain, CASE WHEN NULLIF(a.keyword_id,'') IS NOT NULL OR a.match_type IN ('BROAD','PHRASE','EXACT') THEN 'KEYWORD' ELSE 'TARGET' END);

COMMENT ON VIEW marketcloud_gold.v_ams_target_ads_reconciliation_daily_v1 IS
    'Reconcilia AMS keyword/target diario com Ads Reporting v3 targeting, tratando restatement negativo e conversao-only inferida quando seguro.';

CREATE OR REPLACE VIEW marketcloud_gold.v_ams_target_quality_features_v1 AS
SELECT
    campaign_id,
    COALESCE(ad_group_id,'') AS ad_group_id,
    target_entity_key,
    ROUND(AVG(target_quality_score)::numeric,2) AS avg_target_quality_score_30d,
    COUNT(*) FILTER (WHERE target_quality_status = 'MATCH') AS target_match_days_30d,
    COUNT(*) FILTER (WHERE target_quality_status = 'DIVERGENT') AS target_divergent_days_30d,
    COUNT(*) FILTER (WHERE target_quality_status = 'ADS_TARGETING_MISSING') AS target_ads_missing_days_30d,
    COUNT(*) FILTER (WHERE target_quality_status IN ('FRESH','ATTRIBUTING')) AS target_attributing_days_30d,
    COUNT(*) FILTER (WHERE target_quality_status IN ('MATCH','FRESH','ATTRIBUTING','RESTATEMENT_DELTA','CONVERSION_DELTA','ZERO_DELTA')) AS target_usable_days_30d
FROM marketcloud_gold.v_ams_target_ads_reconciliation_daily_v1
WHERE data_date >= CURRENT_DATE - 30
GROUP BY campaign_id, COALESCE(ad_group_id,''), target_entity_key;

COMMENT ON VIEW marketcloud_gold.v_ams_target_quality_features_v1 IS
    'Features de qualidade AMS target x Ads Reporting v3 para o modelo HourlyTargetRealV3.';

CREATE OR REPLACE VIEW marketcloud_gold.v_ams_ml_operational_alerts_v1 AS
WITH reprocess_alerts AS (
    SELECT
        CASE
            WHEN COALESCE(grain_status,'') IN ('FAILED','CANCELLED','ERROR') OR COALESCE(error_message,'') <> '' THEN 'critical'
            WHEN window_status IN ('RUNNING','SUBMITTED') AND updated_at < now() - interval '2 hours' THEN 'warning'
            ELSE 'ok'
        END AS severity,
        'ads_reporting_reprocess_' || lower(grain) || '_' || data_date::text AS alert_key,
        'Ads Reporting v3 ' || grain || ' ' || COALESCE(grain_status,'UNKNOWN') AS title,
        window_label || ' / ' || data_date::text || ' / linhas=' || rows_ingested::text AS detail,
        grain AS entity_type,
        report_id AS entity_id,
        updated_at AS observed_at
    FROM marketcloud_gold.v_ads_reporting_reprocess_health_v1
    WHERE COALESCE(grain_status,'') IN ('FAILED','CANCELLED','ERROR')
       OR COALESCE(error_message,'') <> ''
       OR (window_status IN ('RUNNING','SUBMITTED') AND updated_at < now() - interval '2 hours')
), target_quality AS (
    SELECT
        CASE
            WHEN target_quality_status = 'DIVERGENT' THEN 'critical'
            WHEN target_quality_status = 'ADS_TARGETING_MISSING' THEN 'warning'
            ELSE 'ok'
        END AS severity,
        'ams_target_quality_' || lower(target_quality_status) AS alert_key,
        'AMS target ' || target_quality_status AS title,
        COUNT(*)::text || ' linhas / score medio=' || ROUND(AVG(target_quality_score)::numeric,1)::text AS detail,
        'TARGET_QUALITY'::text AS entity_type,
        target_quality_status AS entity_id,
        MAX(GREATEST(COALESCE(ams_last_update, TIMESTAMPTZ 'epoch'), COALESCE(ads_last_sync, TIMESTAMPTZ 'epoch'))) AS observed_at
    FROM marketcloud_gold.v_ams_target_ads_reconciliation_daily_v1
    WHERE target_quality_status IN ('DIVERGENT','ADS_TARGETING_MISSING')
    GROUP BY target_quality_status
), ml_stale AS (
    SELECT
        CASE
            WHEN MAX(finished_at) IS NULL THEN 'critical'
            WHEN MAX(finished_at) < now() - interval '2 hours' THEN 'warning'
            ELSE 'ok'
        END AS severity,
        'ml_target_v3_freshness'::text AS alert_key,
        'ML target V3 freshness'::text AS title,
        'ultimo finished_at=' || COALESCE(MAX(finished_at)::text, 'nunca') AS detail,
        'ML_RUN'::text AS entity_type,
        'hourly_target_real_v3'::text AS entity_id,
        MAX(finished_at) AS observed_at
    FROM marketcloud_gold.ml_hourly_run_status
    WHERE run_kind = 'hourly_target_real_v3'
)
SELECT *
FROM reprocess_alerts
WHERE severity <> 'ok'
UNION ALL
SELECT *
FROM target_quality
WHERE severity <> 'ok'
UNION ALL
SELECT *
FROM ml_stale
WHERE severity <> 'ok';

COMMENT ON VIEW marketcloud_gold.v_ams_ml_operational_alerts_v1 IS
    'Alertas operacionais canonicos para Status AMS + ML: reprocess v3, qualidade target e freshness do ML target.';
