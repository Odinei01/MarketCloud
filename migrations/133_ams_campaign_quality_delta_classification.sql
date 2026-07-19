-- =====================================================================
-- AMS campaign quality: do not raise campaign-day DIVERGENT alerts for
-- expected conversion-only / delta-only stream rows.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.v_ams_data_quality_score_v1 AS
SELECT
    r.*,
    CASE
        WHEN r.reconciliation_status = 'MATCH' THEN 'MATURE_RECONCILED'
        WHEN r.reconciliation_status = 'ADS_DAILY_MISSING' THEN 'ADS_MISSING'
        WHEN r.reconciliation_status = 'AMS_DELTA_ONLY' THEN 'DELTA_ONLY'
        WHEN r.reconciliation_status = 'FRESH_NOT_EXPECTED_TO_MATCH_DAILY' THEN 'FRESH'
        WHEN r.reconciliation_status = 'ATTRIBUTION_WINDOW_NOT_FINAL' THEN 'ATTRIBUTING'
        WHEN r.reconciliation_status = 'CHECK_DELTA'
         AND r.ams_impressions_clamped = 0
         AND r.ams_clicks_clamped = 0
         AND r.ams_spend_clamped = 0
         AND (
              r.ams_orders_7d > 0 OR r.ams_sales_7d > 0
           OR r.target_orders_7d > 0 OR r.target_sales_7d > 0
         ) THEN 'CONVERSION_DELTA'
        WHEN r.reconciliation_status = 'CHECK_DELTA'
         AND r.ams_impressions_clamped = 0
         AND r.ams_clicks_clamped = 0
         AND r.ams_spend_clamped = 0
         AND (
              r.ams_negative_rows > 0
           OR r.target_negative_rows > 0
           OR r.ams_hour_rows > 0
           OR r.target_rows > 0
         ) THEN 'DELTA_ONLY'
        WHEN r.reconciliation_status = 'CHECK_DELTA' THEN 'DIVERGENT'
        ELSE 'LOW_CONFIDENCE'
    END AS data_quality_status,
    CASE
        WHEN r.reconciliation_status = 'MATCH' THEN 95
        WHEN r.reconciliation_status = 'AMS_DELTA_ONLY' THEN 78
        WHEN r.reconciliation_status = 'ATTRIBUTION_WINDOW_NOT_FINAL' THEN 72
        WHEN r.reconciliation_status = 'FRESH_NOT_EXPECTED_TO_MATCH_DAILY' THEN 68
        WHEN r.reconciliation_status = 'ADS_DAILY_MISSING' THEN 45
        WHEN r.reconciliation_status = 'CHECK_DELTA'
         AND r.ams_impressions_clamped = 0
         AND r.ams_clicks_clamped = 0
         AND r.ams_spend_clamped = 0
         AND (
              r.ams_orders_7d > 0 OR r.ams_sales_7d > 0
           OR r.target_orders_7d > 0 OR r.target_sales_7d > 0
         ) THEN 82
        WHEN r.reconciliation_status = 'CHECK_DELTA'
         AND r.ams_impressions_clamped = 0
         AND r.ams_clicks_clamped = 0
         AND r.ams_spend_clamped = 0
         AND (
              r.ams_negative_rows > 0
           OR r.target_negative_rows > 0
           OR r.ams_hour_rows > 0
           OR r.target_rows > 0
         ) THEN 78
        WHEN r.reconciliation_status = 'CHECK_DELTA' THEN 35
        ELSE 50
    END::INTEGER AS data_quality_score,
    NOT (
        r.reconciliation_status = 'CHECK_DELTA'
        AND NOT (
            r.ams_impressions_clamped = 0
            AND r.ams_clicks_clamped = 0
            AND r.ams_spend_clamped = 0
            AND (
                 r.ams_orders_7d > 0 OR r.ams_sales_7d > 0
              OR r.target_orders_7d > 0 OR r.target_sales_7d > 0
              OR r.ams_negative_rows > 0 OR r.target_negative_rows > 0
              OR r.ams_hour_rows > 0 OR r.target_rows > 0
            )
        )
    ) AS traffic_usable_for_ml,
    (
        r.reconciliation_status IN ('MATCH','AMS_DELTA_ONLY')
        OR (
            r.reconciliation_status = 'CHECK_DELTA'
            AND r.ams_impressions_clamped = 0
            AND r.ams_clicks_clamped = 0
            AND r.ams_spend_clamped = 0
        )
    ) AS conversion_usable_for_ml,
    CASE
        WHEN r.reconciliation_status = 'MATCH' THEN 'OK'
        WHEN r.reconciliation_status = 'ADS_DAILY_MISSING' THEN 'REQUEST_ADS_REPORT_REPROCESS'
        WHEN r.reconciliation_status = 'AMS_DELTA_ONLY' THEN 'KEEP_AS_AMS_DELTA_WITH_CLAMPED_CANONICAL_SIGNAL'
        WHEN r.reconciliation_status = 'FRESH_NOT_EXPECTED_TO_MATCH_DAILY' THEN 'WAIT_DAILY_REPORT_AND_ATTRIBUTION'
        WHEN r.reconciliation_status = 'ATTRIBUTION_WINDOW_NOT_FINAL' THEN 'WAIT_ATTRIBUTION_OR_REPROCESS_D3_D7'
        WHEN r.reconciliation_status = 'CHECK_DELTA'
         AND r.ams_impressions_clamped = 0
         AND r.ams_clicks_clamped = 0
         AND r.ams_spend_clamped = 0
         AND (
              r.ams_orders_7d > 0 OR r.ams_sales_7d > 0
           OR r.target_orders_7d > 0 OR r.target_sales_7d > 0
         ) THEN 'KEEP_AS_AMS_CONVERSION_DELTA'
        WHEN r.reconciliation_status = 'CHECK_DELTA'
         AND r.ams_impressions_clamped = 0
         AND r.ams_clicks_clamped = 0
         AND r.ams_spend_clamped = 0 THEN 'KEEP_AS_AMS_DELTA_WITH_CLAMPED_CANONICAL_SIGNAL'
        WHEN r.reconciliation_status = 'CHECK_DELTA' THEN 'INVESTIGATE_DELTA_AND_REPROCESS_ADS_REPORT'
        ELSE 'REVIEW_DATA_QUALITY'
    END AS operator_action
FROM marketcloud_gold.v_ams_ads_reconciliation_daily_v1 r;

COMMENT ON VIEW marketcloud_gold.v_ams_data_quality_score_v1 IS
    'Classifica cada campanha/dia AMS x Ads com score 0-100, status operacional e flags de uso no ML, tratando delta/conversao-only esperado.';
