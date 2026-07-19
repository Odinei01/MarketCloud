-- =====================================================================
-- AMS data quality score + Ads Reporting reprocess ledger
--
-- Objetivo:
--   1. transformar a auditoria AMS x Ads em um score operacional;
--   2. deixar claro o que o ML pode usar como sinal maduro;
--   3. registrar as janelas oficiais que precisam de reprocessamento
--      pelo Amazon Ads Reporting API v3 (D-1/D-3/D-7/D-14).
--
-- Nao simula chamada externa. A tabela abaixo e uma fila/ledger real para
-- o executor oficial de Ads Reporting consumir.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS marketcloud_ops;

CREATE TABLE IF NOT EXISTS marketcloud_ops.ads_reporting_reprocess_requests (
    id BIGSERIAL PRIMARY KEY,
    source TEXT NOT NULL DEFAULT 'AMS_RECONCILIATION',
    data_date DATE NOT NULL,
    window_label TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'WAITING_REAL_ADS_REPORT_EXECUTOR',
    reason TEXT NOT NULL,
    requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    error_message TEXT,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (source, data_date, window_label)
);

COMMENT ON TABLE marketcloud_ops.ads_reporting_reprocess_requests IS
    'Fila/ledger de janelas D-1/D-3/D-7/D-14 que devem ser reprocessadas no Amazon Ads Reporting API v3 antes da reconciliacao final AMS x Ads.';

CREATE OR REPLACE FUNCTION marketcloud_ops.enqueue_ads_reporting_reprocess_windows()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected INTEGER := 0;
BEGIN
    WITH windows(days_back, window_label, reason) AS (
        VALUES
            (1,  'D-1',  'Atualizar relatorio Ads diario para comparar com AMS fresco. Conversoes ainda podem mudar.'),
            (3,  'D-3',  'Reprocessar Ads diario para pegar deltas de atribuicao recentes.'),
            (7,  'D-7',  'Reprocessar Ads diario no fechamento principal de atribuicao 7d.'),
            (14, 'D-14', 'Reprocessar Ads diario para confirmar cauda longa e deltas finais.')
    ), upserted AS (
        INSERT INTO marketcloud_ops.ads_reporting_reprocess_requests (
            data_date, window_label, status, reason, requested_at, updated_at, metadata_json
        )
        SELECT
            CURRENT_DATE - days_back,
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
                'comparison_view', 'marketcloud_gold.v_ams_ads_reconciliation_daily_v1'
            )
        FROM windows
        ON CONFLICT (source, data_date, window_label) DO UPDATE SET
            updated_at = now(),
            reason = EXCLUDED.reason,
            metadata_json = EXCLUDED.metadata_json,
            status = CASE
                WHEN marketcloud_ops.ads_reporting_reprocess_requests.status IN ('COMPLETED','RUNNING') THEN marketcloud_ops.ads_reporting_reprocess_requests.status
                ELSE EXCLUDED.status
            END
        RETURNING 1
    )
    SELECT COUNT(*) INTO affected FROM upserted;

    RETURN affected;
END;
$$;

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

SELECT marketcloud_ops.enqueue_ads_reporting_reprocess_windows();
