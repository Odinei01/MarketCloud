-- =====================================================================
-- Ads Reporting v3 health + target/keyword quality
--
-- Fecha a leitura operacional pos §126:
--   1. status por grao dos reports D-1/D-3/D-7/D-14;
--   2. reconciliacao AMS target x Ads Reporting v3 targeting;
--   3. features de qualidade para o ML target.
-- =====================================================================

DROP VIEW IF EXISTS marketcloud_gold.v_ams_ml_operational_alerts_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_gold.v_ams_target_quality_features_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_gold.v_ams_target_ads_reconciliation_daily_v1 CASCADE;

CREATE OR REPLACE VIEW marketcloud_gold.v_ads_reporting_reprocess_health_v1 AS
SELECT
    r.id,
    r.data_date,
    r.window_label,
    r.status AS window_status,
    r.updated_at,
    r.completed_at,
    r.error_message,
    'CAMPAIGN'::TEXT AS grain,
    COALESCE(r.metadata_json->>'sp_campaign_report_id',
        (SELECT MAX(report_id) FROM marketcloud_ops.ads_reporting_sp_campaign_daily_v3 c WHERE c.data_date = r.data_date)) AS report_id,
    COALESCE(NULLIF(r.metadata_json->>'sp_campaign_rows_ingested','')::INT,
        (SELECT COUNT(*)::INT FROM marketcloud_ops.ads_reporting_sp_campaign_daily_v3 c WHERE c.data_date = r.data_date), 0) AS rows_ingested,
    COALESCE(r.metadata_json->>'campaign_last_poll_status',
             CASE WHEN EXISTS (SELECT 1 FROM marketcloud_ops.ads_reporting_sp_campaign_daily_v3 c WHERE c.data_date = r.data_date) THEN 'COMPLETED' ELSE NULL END,
             CASE WHEN r.metadata_json ? 'sp_campaign_rows_ingested' THEN 'COMPLETED' ELSE NULL END) AS grain_status
FROM marketcloud_ops.ads_reporting_reprocess_requests r
UNION ALL
SELECT
    r.id, r.data_date, r.window_label, r.status, r.updated_at, r.completed_at, r.error_message,
    'AD_GROUP',
    COALESCE(r.metadata_json->>'sp_adgroup_report_id',
        (SELECT MAX(report_id) FROM marketcloud_ops.ads_reporting_sp_adgroup_daily_v3 g WHERE g.data_date = r.data_date)),
    COALESCE(NULLIF(r.metadata_json->>'sp_adgroup_rows_ingested','')::INT,
        (SELECT COUNT(*)::INT FROM marketcloud_ops.ads_reporting_sp_adgroup_daily_v3 g WHERE g.data_date = r.data_date), 0),
    COALESCE(r.metadata_json->>'adgroup_last_poll_status',
             CASE WHEN EXISTS (SELECT 1 FROM marketcloud_ops.ads_reporting_sp_adgroup_daily_v3 g WHERE g.data_date = r.data_date) THEN 'COMPLETED' ELSE NULL END,
             CASE WHEN r.metadata_json ? 'sp_adgroup_rows_ingested' THEN 'COMPLETED' ELSE NULL END)
FROM marketcloud_ops.ads_reporting_reprocess_requests r
UNION ALL
SELECT
    r.id, r.data_date, r.window_label, r.status, r.updated_at, r.completed_at, r.error_message,
    'KEYWORD',
    COALESCE(r.metadata_json->>'sp_keyword_report_id',
        (SELECT MAX(report_id) FROM marketcloud_ops.ads_reporting_sp_targeting_daily_v3 k WHERE k.data_date = r.data_date AND k.report_grain = 'KEYWORD')),
    COALESCE(NULLIF(r.metadata_json->>'sp_keyword_rows_ingested','')::INT,
        (SELECT COUNT(*)::INT FROM marketcloud_ops.ads_reporting_sp_targeting_daily_v3 k WHERE k.data_date = r.data_date AND k.report_grain = 'KEYWORD'), 0),
    COALESCE(r.metadata_json->>'keyword_last_poll_status',
             CASE WHEN EXISTS (SELECT 1 FROM marketcloud_ops.ads_reporting_sp_targeting_daily_v3 k WHERE k.data_date = r.data_date AND k.report_grain = 'KEYWORD') THEN 'COMPLETED' ELSE NULL END,
             CASE WHEN r.metadata_json ? 'sp_keyword_rows_ingested' THEN 'COMPLETED' ELSE NULL END)
FROM marketcloud_ops.ads_reporting_reprocess_requests r
UNION ALL
SELECT
    r.id, r.data_date, r.window_label, r.status, r.updated_at, r.completed_at, r.error_message,
    'TARGET',
    COALESCE(r.metadata_json->>'sp_target_report_id',
        (SELECT MAX(report_id) FROM marketcloud_ops.ads_reporting_sp_targeting_daily_v3 t WHERE t.data_date = r.data_date AND t.report_grain = 'TARGET')),
    COALESCE(NULLIF(r.metadata_json->>'sp_target_rows_ingested','')::INT,
        (SELECT COUNT(*)::INT FROM marketcloud_ops.ads_reporting_sp_targeting_daily_v3 t WHERE t.data_date = r.data_date AND t.report_grain = 'TARGET'), 0),
    COALESCE(r.metadata_json->>'target_last_poll_status',
             CASE WHEN EXISTS (SELECT 1 FROM marketcloud_ops.ads_reporting_sp_targeting_daily_v3 t WHERE t.data_date = r.data_date AND t.report_grain = 'TARGET') THEN 'COMPLETED' ELSE NULL END,
             CASE WHEN r.metadata_json ? 'sp_target_rows_ingested' THEN 'COMPLETED' ELSE NULL END)
FROM marketcloud_ops.ads_reporting_reprocess_requests r;

COMMENT ON VIEW marketcloud_gold.v_ads_reporting_reprocess_health_v1 IS
    'Status operacional por grao dos reprocessamentos Ads Reporting v3 D-1/D-3/D-7/D-14.';

CREATE OR REPLACE FUNCTION marketcloud_ops.enqueue_ads_reporting_reprocess_windows()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected INTEGER := 0;
BEGIN
    WITH windows(data_date, window_label, reason) AS (
        SELECT CURRENT_DATE - days_back, window_label, reason
        FROM (
            VALUES
                (1,  'D-1',  'Atualizar relatorio Ads diario para comparar com AMS fresco. Conversoes ainda podem mudar.'),
                (3,  'D-3',  'Reprocessar Ads diario para pegar deltas de atribuicao recentes.'),
                (7,  'D-7',  'Reprocessar Ads diario no fechamento principal de atribuicao 7d.'),
                (14, 'D-14', 'Reprocessar Ads diario para confirmar cauda longa e deltas finais.')
        ) AS w(days_back, window_label, reason)
        UNION
        SELECT DISTINCT
            a.data_date,
            'AMS-MISSING-' || a.data_date::text,
            'Backfill automatico: AMS target existe, mas ainda nao ha Ads Reporting v3 targeting para conciliacao fina.'
        FROM marketcloud_bronze.bronze_ams_hourly_target a
        WHERE a.data_date < CURRENT_DATE - 1
          AND a.data_date >= CURRENT_DATE - 60
          AND NULLIF(TRIM(COALESCE(a.target_entity_key,'')), '') IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM marketcloud_gold.v_ads_targeting_daily_effective_v1 d
              WHERE d.data_date = a.data_date
          )
    ), upserted AS (
        INSERT INTO marketcloud_ops.ads_reporting_reprocess_requests (
            data_date, window_label, status, reason, requested_at, updated_at, metadata_json
        )
        SELECT
            data_date,
            window_label,
            'WAITING_REAL_ADS_REPORT_EXECUTOR',
            reason,
            now(),
            now(),
            jsonb_build_object(
                'required_reports', jsonb_build_array(
                    'SponsoredProducts campaign daily',
                    'SponsoredProducts adGroup daily',
                    'SponsoredProducts keyword daily',
                    'SponsoredProducts target daily'
                ),
                'comparison_view', 'marketcloud_gold.v_ams_ads_reconciliation_daily_v1',
                'target_quality_view', 'marketcloud_gold.v_ams_target_ads_reconciliation_daily_v1'
            )
        FROM windows
        ON CONFLICT (source, data_date, window_label) DO UPDATE SET
            updated_at = now(),
            reason = EXCLUDED.reason,
            metadata_json = CASE
                WHEN marketcloud_ops.ads_reporting_reprocess_requests.status IN ('COMPLETED','RUNNING','SUBMITTED') THEN marketcloud_ops.ads_reporting_reprocess_requests.metadata_json
                ELSE EXCLUDED.metadata_json
            END,
            status = CASE
                WHEN marketcloud_ops.ads_reporting_reprocess_requests.status IN ('COMPLETED','RUNNING','SUBMITTED') THEN marketcloud_ops.ads_reporting_reprocess_requests.status
                ELSE EXCLUDED.status
            END
        RETURNING 1
    )
    SELECT COUNT(*) INTO affected FROM upserted;

    RETURN affected;
END;
$$;

CREATE OR REPLACE VIEW marketcloud_gold.v_ams_target_ads_reconciliation_daily_v1 AS
WITH ams AS (
    SELECT
        data_date,
        campaign_id,
        COALESCE(ad_group_id,'') AS ad_group_id,
        target_entity_key,
        MAX(campaign_name) AS campaign_name,
        MAX(ad_group_name) AS ad_group_name,
        MAX(keyword_id) AS keyword_id,
        MAX(target_id) AS target_id,
        MAX(keyword_text) AS keyword_text,
        MAX(targeting) AS targeting,
        COALESCE(NULLIF(MAX(match_type),''),'UNKNOWN') AS match_type,
        SUM(COALESCE(impressions,0))::numeric AS ams_impressions,
        SUM(COALESCE(clicks,0))::numeric AS ams_clicks,
        SUM(COALESCE(spend,0))::numeric AS ams_spend,
        SUM(COALESCE(orders_7d,0))::numeric AS ams_orders,
        SUM(COALESCE(sales_7d,0))::numeric AS ams_sales,
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
)
SELECT
    a.data_date,
    a.campaign_id,
    a.campaign_name,
    a.ad_group_id,
    COALESCE(a.ad_group_name, d.ad_group_name) AS ad_group_name,
    a.target_entity_key,
    a.keyword_id,
    a.target_id,
    COALESCE(a.keyword_text, a.targeting, d.target_text) AS target_text,
    a.match_type,
    COALESCE(d.report_grain, CASE WHEN a.match_type IN ('BROAD','PHRASE','EXACT') THEN 'KEYWORD' ELSE 'TARGET' END) AS ads_report_grain,
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
        WHEN a.ams_impressions < 0 AND a.ams_clicks = 0 AND a.ams_spend = 0 AND a.ams_orders = 0 THEN 'RESTATEMENT_DELTA'
        WHEN a.data_date >= CURRENT_DATE - 1 THEN 'FRESH'
        WHEN COALESCE(ad.report_rows, 0) = 0 THEN 'ADS_REPORT_MISSING'
        WHEN d.target_entity_key IS NULL THEN 'ADS_TARGETING_MISSING'
        WHEN a.data_date >= CURRENT_DATE - 7 THEN 'ATTRIBUTING'
        WHEN abs(a.ams_spend - COALESCE(d.spend,0)::numeric) <= 0.05
         AND abs(a.ams_clicks - COALESCE(d.clicks,0)::numeric) <= 1 THEN 'MATCH'
        ELSE 'DIVERGENT'
    END AS target_quality_status,
    CASE
        WHEN a.ams_impressions < 0 AND a.ams_clicks = 0 AND a.ams_spend = 0 AND a.ams_orders = 0 THEN 88
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
      )
    ORDER BY
      CASE WHEN d.target_entity_key = a.target_entity_key THEN 0 ELSE 1 END,
      CASE
        WHEN a.ams_impressions = 0 AND a.ams_clicks = 0 AND a.ams_spend = 0
         AND a.ams_orders = COALESCE(d.orders,0)::numeric
         AND abs(a.ams_sales - COALESCE(d.sales,0)::numeric) <= 0.05 THEN 0
        ELSE 1
      END,
      d.last_sync DESC NULLS LAST
    LIMIT 1
) d ON TRUE
LEFT JOIN ads_dates ad
  ON ad.data_date = a.data_date
 AND ad.report_grain = COALESCE(d.report_grain, CASE WHEN a.match_type IN ('BROAD','PHRASE','EXACT') THEN 'KEYWORD' ELSE 'TARGET' END);

COMMENT ON VIEW marketcloud_gold.v_ams_target_ads_reconciliation_daily_v1 IS
    'Reconcilia AMS keyword/target diario com Ads Reporting v3 targeting no mesmo grao quando possivel.';

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
    COUNT(*) FILTER (WHERE target_quality_status IN ('MATCH','FRESH','ATTRIBUTING')) AS target_usable_days_30d,
    MAX(ads_last_sync) AS target_ads_last_sync
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
    'Alertas operacionais canônicos para Status AMS + ML: reprocess v3, qualidade target e freshness do ML target.';
