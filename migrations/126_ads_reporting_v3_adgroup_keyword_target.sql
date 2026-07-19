-- =====================================================================
-- Amazon Ads Reporting API v3 - adGroup / keyword / target
--
-- Complementa a migration 125. A primeira entrega ligou campanha diaria
-- (spCampaigns/campaign). Esta migration cria os destinos oficiais para:
--   - adGroup diario;
--   - keyword diario via spTargeting + filtro keywordType;
--   - target diario via spTargeting + filtro keywordType de targets.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_ops.ads_reporting_sp_adgroup_daily_v3 (
    profile_id TEXT NOT NULL,
    data_date DATE NOT NULL,
    campaign_id TEXT NOT NULL,
    campaign_name TEXT,
    ad_group_id TEXT NOT NULL,
    ad_group_name TEXT,
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
    PRIMARY KEY (profile_id, data_date, campaign_id, ad_group_id)
);

COMMENT ON TABLE marketcloud_ops.ads_reporting_sp_adgroup_daily_v3 IS
    'Sponsored Products adGroup daily baixado do Amazon Ads Reporting API v3.';

CREATE TABLE IF NOT EXISTS marketcloud_ops.ads_reporting_sp_targeting_daily_v3 (
    profile_id TEXT NOT NULL,
    data_date DATE NOT NULL,
    report_grain TEXT NOT NULL CHECK (report_grain IN ('KEYWORD','TARGET')),
    campaign_id TEXT NOT NULL,
    campaign_name TEXT,
    ad_group_id TEXT NOT NULL DEFAULT '',
    ad_group_name TEXT,
    keyword_id TEXT,
    target_id TEXT,
    target_entity_key TEXT NOT NULL,
    target_text TEXT,
    match_type TEXT,
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
    PRIMARY KEY (profile_id, data_date, report_grain, campaign_id, ad_group_id, target_entity_key)
);

COMMENT ON TABLE marketcloud_ops.ads_reporting_sp_targeting_daily_v3 IS
    'Sponsored Products targeting daily baixado do Amazon Ads Reporting API v3. KEYWORD e TARGET ficam separados por report_grain.';

CREATE OR REPLACE VIEW marketcloud_gold.v_ads_adgroups_daily_effective_v1 AS
SELECT
    data_date,
    profile_id,
    campaign_id,
    campaign_name,
    ad_group_id,
    ad_group_name,
    impressions::numeric AS impressions,
    clicks::numeric AS clicks,
    cost::numeric AS spend,
    purchases::numeric AS orders,
    attributed_sales::numeric AS sales,
    report_id,
    synced_at AS last_sync,
    'ADS_REPORTING_V3'::TEXT AS source
FROM marketcloud_ops.ads_reporting_sp_adgroup_daily_v3;

COMMENT ON VIEW marketcloud_gold.v_ads_adgroups_daily_effective_v1 IS
    'Fonte efetiva Ads adGroup daily. Hoje usa somente Ads Reporting API v3 local.';

CREATE OR REPLACE VIEW marketcloud_gold.v_ads_targeting_daily_effective_v1 AS
SELECT
    data_date,
    profile_id,
    report_grain,
    campaign_id,
    campaign_name,
    ad_group_id,
    ad_group_name,
    keyword_id,
    target_id,
    target_entity_key,
    target_text,
    match_type,
    impressions::numeric AS impressions,
    clicks::numeric AS clicks,
    cost::numeric AS spend,
    purchases::numeric AS orders,
    attributed_sales::numeric AS sales,
    report_id,
    synced_at AS last_sync,
    'ADS_REPORTING_V3'::TEXT AS source
FROM marketcloud_ops.ads_reporting_sp_targeting_daily_v3;

COMMENT ON VIEW marketcloud_gold.v_ads_targeting_daily_effective_v1 IS
    'Fonte efetiva Ads targeting daily separada entre KEYWORD e TARGET via Ads Reporting API v3 local.';

-- Recria a reconciliacao diaria acrescentando sinais oficiais de targeting.
-- Como a view ganha colunas no meio do contrato, e necessario derrubar a cadeia
-- dependente e recria-la logo abaixo.
DROP VIEW IF EXISTS marketcloud_gold.v_gold_hourly_signal_quality_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_gold.v_ams_quality_summary_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_gold.v_ams_data_quality_score_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_gold.v_ams_ads_reconciliation_daily_v1 CASCADE;

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
), ads_targeting_daily AS (
    SELECT
        data_date,
        campaign_id,
        COUNT(*) AS ads_targeting_rows,
        COUNT(*) FILTER (WHERE report_grain='KEYWORD') AS ads_keyword_rows,
        COUNT(*) FILTER (WHERE report_grain='TARGET') AS ads_target_rows,
        COUNT(DISTINCT target_entity_key) AS ads_targeting_entities,
        SUM(COALESCE(impressions,0))::numeric AS ads_targeting_impressions,
        SUM(COALESCE(clicks,0))::numeric AS ads_targeting_clicks,
        SUM(COALESCE(spend,0))::numeric AS ads_targeting_spend,
        SUM(COALESCE(orders,0))::numeric AS ads_targeting_orders,
        SUM(COALESCE(sales,0))::numeric AS ads_targeting_sales,
        MAX(last_sync) AS ads_targeting_last_sync,
        MAX(source) AS ads_targeting_source
    FROM marketcloud_gold.v_ads_targeting_daily_effective_v1
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
    COALESCE(at.ads_targeting_rows,0) AS ads_targeting_rows,
    COALESCE(at.ads_keyword_rows,0) AS ads_keyword_rows,
    COALESCE(at.ads_target_rows,0) AS ads_target_rows,
    COALESCE(at.ads_targeting_entities,0) AS ads_targeting_entities,
    COALESCE(at.ads_targeting_impressions,0) AS ads_targeting_impressions,
    COALESCE(at.ads_targeting_clicks,0) AS ads_targeting_clicks,
    COALESCE(at.ads_targeting_spend,0) AS ads_targeting_spend,
    COALESCE(at.ads_targeting_orders,0) AS ads_targeting_orders,
    COALESCE(at.ads_targeting_sales,0) AS ads_targeting_sales,
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
    COALESCE(t.target_impressions_raw,0) - COALESCE(at.ads_targeting_impressions,0) AS delta_ads_targeting_impressions,
    COALESCE(t.target_clicks_raw,0) - COALESCE(at.ads_targeting_clicks,0) AS delta_ads_targeting_clicks,
    COALESCE(t.target_spend_raw,0) - COALESCE(at.ads_targeting_spend,0) AS delta_ads_targeting_spend,
    COALESCE(t.target_orders_7d,0) - COALESCE(at.ads_targeting_orders,0) AS delta_ads_targeting_orders,
    COALESCE(t.target_sales_7d,0) - COALESCE(at.ads_targeting_sales,0) AS delta_ads_targeting_sales,
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
    at.ads_targeting_last_sync,
    COALESCE(d.ads_source, 'NONE') AS ads_source,
    COALESCE(at.ads_targeting_source, 'NONE') AS ads_targeting_source
FROM ams_daily a
LEFT JOIN ams_target_daily t USING (data_date, campaign_id)
LEFT JOIN ads_daily d USING (data_date, campaign_id)
LEFT JOIN ads_targeting_daily at USING (data_date, campaign_id);

COMMENT ON VIEW marketcloud_gold.v_ams_ads_reconciliation_daily_v1 IS
    'Reconcilia AMS campanha/target com Ads daily/reporting por dia/campanha. Prefere Ads Reporting API v3 local quando reprocessado, incluindo targeting quando disponivel.';

CREATE OR REPLACE VIEW marketcloud_gold.v_ams_data_quality_score_v1 AS
SELECT
    r.*,
    CASE
        WHEN r.reconciliation_status = 'MATCH' THEN 'MATURE_RECONCILED'
        WHEN r.reconciliation_status = 'CHECK_DELTA' THEN 'DIVERGENT'
        WHEN r.reconciliation_status = 'ADS_DAILY_MISSING' THEN 'ADS_MISSING'
        WHEN r.reconciliation_status = 'AMS_DELTA_ONLY' THEN 'DELTA_ONLY'
        WHEN r.reconciliation_status = 'FRESH_NOT_EXPECTED_TO_MATCH_DAILY' THEN 'FRESH'
        WHEN r.reconciliation_status = 'ATTRIBUTION_WINDOW_NOT_FINAL' THEN 'ATTRIBUTING'
        ELSE 'LOW_CONFIDENCE'
    END AS data_quality_status,
    CASE
        WHEN r.reconciliation_status = 'MATCH' THEN 95
        WHEN r.reconciliation_status = 'AMS_DELTA_ONLY' THEN 78
        WHEN r.reconciliation_status = 'ATTRIBUTION_WINDOW_NOT_FINAL' THEN 72
        WHEN r.reconciliation_status = 'FRESH_NOT_EXPECTED_TO_MATCH_DAILY' THEN 68
        WHEN r.reconciliation_status = 'ADS_DAILY_MISSING' THEN 45
        WHEN r.reconciliation_status = 'CHECK_DELTA' THEN 35
        ELSE 50
    END::INTEGER AS data_quality_score,
    (r.reconciliation_status <> 'CHECK_DELTA') AS traffic_usable_for_ml,
    (r.reconciliation_status IN ('MATCH','AMS_DELTA_ONLY')) AS conversion_usable_for_ml,
    CASE
        WHEN r.reconciliation_status = 'MATCH' THEN 'OK'
        WHEN r.reconciliation_status = 'CHECK_DELTA' THEN 'INVESTIGATE_DELTA_AND_REPROCESS_ADS_REPORT'
        WHEN r.reconciliation_status = 'ADS_DAILY_MISSING' THEN 'REQUEST_ADS_REPORT_REPROCESS'
        WHEN r.reconciliation_status = 'AMS_DELTA_ONLY' THEN 'KEEP_AS_AMS_DELTA_WITH_CLAMPED_CANONICAL_SIGNAL'
        WHEN r.reconciliation_status = 'FRESH_NOT_EXPECTED_TO_MATCH_DAILY' THEN 'WAIT_DAILY_REPORT_AND_ATTRIBUTION'
        WHEN r.reconciliation_status = 'ATTRIBUTION_WINDOW_NOT_FINAL' THEN 'WAIT_ATTRIBUTION_OR_REPROCESS_D3_D7'
        ELSE 'REVIEW_DATA_QUALITY'
    END AS operator_action
FROM marketcloud_gold.v_ams_ads_reconciliation_daily_v1 r;

COMMENT ON VIEW marketcloud_gold.v_ams_data_quality_score_v1 IS
    'Classifica cada campanha/dia AMS x Ads com score 0-100, status operacional e flags de uso no ML.';

CREATE OR REPLACE VIEW marketcloud_gold.v_ams_quality_summary_v1 AS
SELECT
    data_quality_status,
    operator_action,
    COUNT(*) AS rows,
    MIN(data_date) AS min_date,
    MAX(data_date) AS max_date,
    ROUND(AVG(data_quality_score)::numeric, 2) AS avg_quality_score,
    SUM(ams_spend_clamped)::numeric AS ams_spend,
    SUM(ads_spend)::numeric AS ads_spend,
    SUM(delta_ads_spend)::numeric AS delta_ads_spend,
    SUM(ams_orders_7d)::numeric AS ams_orders_7d,
    SUM(ads_orders)::numeric AS ads_orders,
    SUM(delta_ads_orders)::numeric AS delta_ads_orders,
    MAX(ams_last_update) AS last_ams_update,
    MAX(ads_last_sync) AS last_ads_sync
FROM marketcloud_gold.v_ams_data_quality_score_v1
GROUP BY data_quality_status, operator_action;

COMMENT ON VIEW marketcloud_gold.v_ams_quality_summary_v1 IS
    'Resumo executivo do score de qualidade AMS x Ads para painel operacional.';

CREATE OR REPLACE VIEW marketcloud_gold.v_gold_hourly_signal_quality_v1 AS
SELECT
    h.*,
    COALESCE(q.data_quality_status, 'NO_RECONCILIATION') AS data_quality_status,
    COALESCE(q.data_quality_score, 50) AS data_quality_score,
    COALESCE(q.traffic_usable_for_ml, true) AS traffic_usable_for_ml,
    COALESCE(q.conversion_usable_for_ml, false) AS conversion_usable_for_ml,
    COALESCE(q.operator_action, 'REVIEW_DATA_QUALITY') AS data_quality_operator_action
FROM marketcloud_gold.gold_hourly_signal_unified h
LEFT JOIN marketcloud_gold.gold_campaign_identity i
  ON lower(trim(i.campaign_name)) = lower(trim(h.campaign_name))
LEFT JOIN marketcloud_gold.v_ams_data_quality_score_v1 q
  ON q.data_date = h.data_date
 AND (
      q.campaign_id = i.campaign_id
      OR lower(trim(q.campaign_name)) = lower(trim(h.campaign_name))
 );

COMMENT ON VIEW marketcloud_gold.v_gold_hourly_signal_quality_v1 IS
    'Camada canonica horaria com score de qualidade AMS x Ads anexado para auditoria e ML.';

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
        SUM(delta_target_sales) AS sum_delta_target_sales,
        SUM(delta_ads_targeting_impressions) AS sum_delta_ads_targeting_impressions,
        SUM(delta_ads_targeting_clicks) AS sum_delta_ads_targeting_clicks,
        SUM(delta_ads_targeting_spend) AS sum_delta_ads_targeting_spend,
        SUM(delta_ads_targeting_orders) AS sum_delta_ads_targeting_orders,
        SUM(delta_ads_targeting_sales) AS sum_delta_ads_targeting_sales
    FROM marketcloud_gold.v_ams_ads_reconciliation_daily_v1
)
SELECT 'AMS_CAMPAIGN' AS audit_area, to_jsonb(campaign.*) AS payload FROM campaign
UNION ALL
SELECT 'AMS_TARGET', to_jsonb(target.*) FROM target
UNION ALL
SELECT 'RECONCILIATION', to_jsonb(rec.*) FROM rec;

COMMENT ON VIEW marketcloud_gold.v_ams_quality_audit_v1 IS
    'Resumo de qualidade AMS: volume, negativos/deltas, conversoes e status de reconciliacao com Ads/reporting, incluindo targeting Ads v3 quando disponivel.';

-- Linhas ja completas apenas com campanha devem voltar a rodar para buscar os
-- tres graos novos. Nao mexe em requests que ainda estao RUNNING.
UPDATE marketcloud_ops.ads_reporting_reprocess_requests
SET status='WAITING_REAL_ADS_REPORT_EXECUTOR',
    completed_at=NULL,
    updated_at=NOW(),
    metadata_json = metadata_json || jsonb_build_object(
        'needs_adgroup_keyword_target_reports', true,
        'reset_for_v126_at', NOW()
    )
WHERE status='COMPLETED'
  AND NOT (
      metadata_json ? 'sp_adgroup_report_id'
      AND metadata_json ? 'sp_keyword_report_id'
      AND metadata_json ? 'sp_target_report_id'
  );
