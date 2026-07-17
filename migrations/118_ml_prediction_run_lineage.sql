-- =====================================================================
-- 118: Rastreabilidade predicao -> rodada de treino (P1-6, versionamento).
--
-- Ate aqui as predicoes/recs 360 eram TRUNCATE+reescrita a cada rodada, sem
-- ligacao com o modelo que as gerou. O historico de rodada JA existe (append
-- em marketcloud_gold.ml_hourly_run_status, 404 rodadas com metricas_json,
-- incluindo roc_auc_cross_campaign). Faltava so carimbar cada predicao com o
-- run_id da rodada -> agora da pra auditar "essa predicao veio da rodada X com
-- AUC Y" e ver o modelo derivar no tempo.
-- =====================================================================

ALTER TABLE marketcloud_gold.hourly_ml_predictions_v2
    ADD COLUMN IF NOT EXISTS run_id BIGINT;
ALTER TABLE marketcloud_gold.ml_full_control_action_recommendations_v1
    ADD COLUMN IF NOT EXISTS run_id BIGINT;
ALTER TABLE marketcloud_gold.hourly_target_ml_predictions_v3
    ADD COLUMN IF NOT EXISTS run_id BIGINT;

CREATE INDEX IF NOT EXISTS idx_hourly_pred_v2_run
    ON marketcloud_gold.hourly_ml_predictions_v2 (run_id);
CREATE INDEX IF NOT EXISTS idx_ml_fc360_run
    ON marketcloud_gold.ml_full_control_action_recommendations_v1 (run_id);
CREATE INDEX IF NOT EXISTS idx_hourly_target_pred_v3_run
    ON marketcloud_gold.hourly_target_ml_predictions_v3 (run_id);

-- Linhagem: cada predicao viva -> rodada -> metricas do modelo (incl a metrica
-- honesta cross-campanha). Fonte unica para auditar procedencia da predicao.
CREATE OR REPLACE VIEW marketcloud_gold.v_ml_prediction_lineage_v1 AS
SELECT
    p.campaign_name,
    p.event_hour,
    p.conversion_probability,
    p.expected_roas,
    p.run_id,
    r.run_kind,
    r.model_version,
    r.status AS run_status,
    r.finished_at AS run_finished_at,
    (r.metrics_json->'conversion'->>'roc_auc')::numeric AS run_auc,
    (r.metrics_json->'conversion'->>'roc_auc_cross_campaign')::numeric AS run_auc_cross_campaign,
    (r.metrics_json->'conversion'->>'positives')::numeric AS run_positives,
    (r.metrics_json->'expected_roas'->>'mae')::numeric AS run_mae,
    (r.metrics_json->'expected_roas'->>'mae_cross_campaign')::numeric AS run_mae_cross_campaign
FROM marketcloud_gold.hourly_ml_predictions_v2 p
LEFT JOIN marketcloud_gold.ml_hourly_run_status r ON r.id = p.run_id;

COMMENT ON VIEW marketcloud_gold.v_ml_prediction_lineage_v1 IS
    'Linhagem de cada predicao horaria -> rodada de treino que a gerou -> metricas do modelo (AUC operacional e cross-campanha, MAE, positivos). Fecha o P1-6: predicao rastreavel ao modelo.';

-- Linhagem do modelo target keyword/hora (V3).
CREATE OR REPLACE VIEW marketcloud_gold.v_ml_target_prediction_lineage_v1 AS
SELECT
    p.*,
    r.run_kind,
    r.status AS run_status,
    r.finished_at AS run_finished_at,
    r.metrics_json AS run_metrics_json
FROM marketcloud_gold.hourly_target_ml_predictions_v3 p
LEFT JOIN marketcloud_gold.ml_hourly_run_status r ON r.id = p.run_id;

COMMENT ON VIEW marketcloud_gold.v_ml_target_prediction_lineage_v1 IS
    'Linhagem das predicoes target keyword/hora (V3) -> rodada de treino -> metricas. Fecha o P1-6 tambem no grao target.';
