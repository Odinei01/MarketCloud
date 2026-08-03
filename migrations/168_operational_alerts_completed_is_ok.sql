-- Migration 168: Status AMS + ML operational alerts should not flag completed grains.
-- A reprocess window can still carry an error_message while one grain is already
-- completed. The alert must describe the grain state, not punish completed data.

CREATE OR REPLACE VIEW marketcloud_gold.v_ams_ml_operational_alerts_v1 AS
WITH reprocess_alerts AS (
    SELECT
        CASE
            WHEN COALESCE(grain_status,'') = 'COMPLETED' THEN 'ok'
            WHEN COALESCE(grain_status,'') IN ('FAILED','CANCELLED','ERROR')
                 OR COALESCE(error_message,'') <> '' THEN 'critical'
            WHEN COALESCE(grain_status,'') IN ('PENDING','PROCESSING','UNKNOWN','')
                 AND updated_at < now() - interval '2 hours' THEN 'critical'
            WHEN window_status IN ('RUNNING','SUBMITTED')
                 AND updated_at < now() - interval '2 hours' THEN 'warning'
            ELSE 'ok'
        END AS severity,
        'ads_reporting_reprocess_' || lower(grain) || '_' || data_date::text AS alert_key,
        'Ads Reporting v3 ' || grain || ' ' || COALESCE(NULLIF(grain_status,''),'UNKNOWN') AS title,
        window_label || ' / ' || data_date::text || ' / linhas=' || rows_ingested::text AS detail,
        grain AS entity_type,
        report_id AS entity_id,
        updated_at AS observed_at
    FROM marketcloud_gold.v_ads_reporting_reprocess_health_v1
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
    'Alertas operacionais canonicos para Status AMS + ML: COMPLETED e ok; alertas ficam restritos a falha/stale/reprocess incompleto, qualidade target e freshness do ML target.';
