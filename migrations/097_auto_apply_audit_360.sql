-- =====================================================================
-- Auto-Apply Audit 360
--
-- Leitura canonica do ciclo:
-- modelo propoe -> robo aplica -> AMS mede 1h/3h/24h -> verdict.
-- Nao executa nada; apenas organiza a trilha de auditoria para API/UI.
-- =====================================================================

UPDATE marketcloud_recommendations.recommendation_decisions d
SET tenant_id = t.id::text,
    updated_at = NOW()
FROM tenants t
WHERE d.tenant_id = t.slug
  AND t.slug = 'zanom';

CREATE OR REPLACE VIEW marketcloud_recommendations.v_auto_apply_audit_360_v1 AS
WITH outcome_pivot AS (
    SELECT
        o.recommendation_id,
        MAX(o.measured_at) AS last_measured_at,

        MAX(o.action_start_at) FILTER (WHERE o.outcome_window = '1h') AS action_start_at_1h,
        MAX(o.eval_window_end) FILTER (WHERE o.outcome_window = '1h') AS eval_window_end_1h,
        MAX(o.baseline_roas) FILTER (WHERE o.outcome_window = '1h') AS baseline_roas_1h,
        MAX(o.eval_roas) FILTER (WHERE o.outcome_window = '1h') AS eval_roas_1h,
        MAX(o.delta_roas) FILTER (WHERE o.outcome_window = '1h') AS delta_roas_1h,
        MAX(o.baseline_spend) FILTER (WHERE o.outcome_window = '1h') AS baseline_spend_1h,
        MAX(o.eval_spend) FILTER (WHERE o.outcome_window = '1h') AS eval_spend_1h,
        MAX(o.delta_spend) FILTER (WHERE o.outcome_window = '1h') AS delta_spend_1h,
        MAX(o.baseline_orders) FILTER (WHERE o.outcome_window = '1h') AS baseline_orders_1h,
        MAX(o.eval_orders) FILTER (WHERE o.outcome_window = '1h') AS eval_orders_1h,
        MAX(o.delta_orders) FILTER (WHERE o.outcome_window = '1h') AS delta_orders_1h,
        MAX(o.outcome_label) FILTER (WHERE o.outcome_window = '1h') AS outcome_label_1h,
        MAX(o.model_verdict) FILTER (WHERE o.outcome_window = '1h') AS model_verdict_1h,

        MAX(o.action_start_at) FILTER (WHERE o.outcome_window = '3h') AS action_start_at_3h,
        MAX(o.eval_window_end) FILTER (WHERE o.outcome_window = '3h') AS eval_window_end_3h,
        MAX(o.baseline_roas) FILTER (WHERE o.outcome_window = '3h') AS baseline_roas_3h,
        MAX(o.eval_roas) FILTER (WHERE o.outcome_window = '3h') AS eval_roas_3h,
        MAX(o.delta_roas) FILTER (WHERE o.outcome_window = '3h') AS delta_roas_3h,
        MAX(o.baseline_spend) FILTER (WHERE o.outcome_window = '3h') AS baseline_spend_3h,
        MAX(o.eval_spend) FILTER (WHERE o.outcome_window = '3h') AS eval_spend_3h,
        MAX(o.delta_spend) FILTER (WHERE o.outcome_window = '3h') AS delta_spend_3h,
        MAX(o.baseline_orders) FILTER (WHERE o.outcome_window = '3h') AS baseline_orders_3h,
        MAX(o.eval_orders) FILTER (WHERE o.outcome_window = '3h') AS eval_orders_3h,
        MAX(o.delta_orders) FILTER (WHERE o.outcome_window = '3h') AS delta_orders_3h,
        MAX(o.outcome_label) FILTER (WHERE o.outcome_window = '3h') AS outcome_label_3h,
        MAX(o.model_verdict) FILTER (WHERE o.outcome_window = '3h') AS model_verdict_3h,

        MAX(o.action_start_at) FILTER (WHERE o.outcome_window = '24h') AS action_start_at_24h,
        MAX(o.eval_window_end) FILTER (WHERE o.outcome_window = '24h') AS eval_window_end_24h,
        MAX(o.baseline_roas) FILTER (WHERE o.outcome_window = '24h') AS baseline_roas_24h,
        MAX(o.eval_roas) FILTER (WHERE o.outcome_window = '24h') AS eval_roas_24h,
        MAX(o.delta_roas) FILTER (WHERE o.outcome_window = '24h') AS delta_roas_24h,
        MAX(o.baseline_spend) FILTER (WHERE o.outcome_window = '24h') AS baseline_spend_24h,
        MAX(o.eval_spend) FILTER (WHERE o.outcome_window = '24h') AS eval_spend_24h,
        MAX(o.delta_spend) FILTER (WHERE o.outcome_window = '24h') AS delta_spend_24h,
        MAX(o.baseline_orders) FILTER (WHERE o.outcome_window = '24h') AS baseline_orders_24h,
        MAX(o.eval_orders) FILTER (WHERE o.outcome_window = '24h') AS eval_orders_24h,
        MAX(o.delta_orders) FILTER (WHERE o.outcome_window = '24h') AS delta_orders_24h,
        MAX(o.outcome_label) FILTER (WHERE o.outcome_window = '24h') AS outcome_label_24h,
        MAX(o.model_verdict) FILTER (WHERE o.outcome_window = '24h') AS model_verdict_24h,

        COUNT(*) FILTER (WHERE o.outcome_label IS NOT NULL) AS measured_windows,
        COUNT(*) FILTER (WHERE o.outcome_label = 'IMPROVED') AS improved_windows,
        COUNT(*) FILTER (WHERE o.outcome_label = 'WORSENED') AS worsened_windows,
        COUNT(*) FILTER (WHERE o.model_verdict = 'MODEL_RIGHT') AS model_right_windows,
        COUNT(*) FILTER (WHERE o.model_verdict = 'MODEL_WRONG') AS model_wrong_windows
    FROM marketcloud_recommendations.recommendation_hourly_outcomes o
    GROUP BY o.recommendation_id
)
SELECT
    d.decision_id,
    d.recommendation_id,
    d.tenant_id,
    d.amc_instance_id,
    d.ads_profile_id,
    d.entity_type,
    d.entity_key,
    d.campaign_id,
    d.campaign_name,
    d.ad_group_name,
    d.event_hour,
    d.recommended_action,
    d.recommended_bid_multiplier,
    d.priority_score,
    d.priority_bucket,
    d.final_risk_level,
    d.final_confidence_score,
    d.decision,
    d.decided_action,
    d.decided_bid_multiplier,
    d.decided_by,
    d.decision_notes,
    d.decided_at,
    d.execution_status,
    d.executed_at,
    d.gold_evidence_json,
    d.prediction_evidence_json,
    d.features_snapshot,

    p.action_start_at_1h, p.eval_window_end_1h,
    p.baseline_roas_1h, p.eval_roas_1h, p.delta_roas_1h,
    p.baseline_spend_1h, p.eval_spend_1h, p.delta_spend_1h,
    p.baseline_orders_1h, p.eval_orders_1h, p.delta_orders_1h,
    p.outcome_label_1h, p.model_verdict_1h,

    p.action_start_at_3h, p.eval_window_end_3h,
    p.baseline_roas_3h, p.eval_roas_3h, p.delta_roas_3h,
    p.baseline_spend_3h, p.eval_spend_3h, p.delta_spend_3h,
    p.baseline_orders_3h, p.eval_orders_3h, p.delta_orders_3h,
    p.outcome_label_3h, p.model_verdict_3h,

    p.action_start_at_24h, p.eval_window_end_24h,
    p.baseline_roas_24h, p.eval_roas_24h, p.delta_roas_24h,
    p.baseline_spend_24h, p.eval_spend_24h, p.delta_spend_24h,
    p.baseline_orders_24h, p.eval_orders_24h, p.delta_orders_24h,
    p.outcome_label_24h, p.model_verdict_24h,

    COALESCE(p.measured_windows, 0) AS measured_windows,
    COALESCE(p.improved_windows, 0) AS improved_windows,
    COALESCE(p.worsened_windows, 0) AS worsened_windows,
    COALESCE(p.model_right_windows, 0) AS model_right_windows,
    COALESCE(p.model_wrong_windows, 0) AS model_wrong_windows,
    CASE
        WHEN COALESCE(p.measured_windows, 0) = 0 THEN 'PENDING_MEASUREMENT'
        WHEN COALESCE(p.worsened_windows, 0) > COALESCE(p.improved_windows, 0) THEN 'LOSING'
        WHEN COALESCE(p.improved_windows, 0) > 0 THEN 'WINNING'
        ELSE 'NEUTRAL'
    END AS audit_result,
    CASE
        WHEN COALESCE(p.measured_windows, 0) = 0 THEN 'INCONCLUSIVE'
        WHEN COALESCE(p.model_wrong_windows, 0) > COALESCE(p.model_right_windows, 0) THEN 'MODEL_WRONG'
        WHEN COALESCE(p.model_right_windows, 0) > 0 THEN 'MODEL_RIGHT'
        ELSE 'INCONCLUSIVE'
    END AS model_result,
    p.last_measured_at
FROM marketcloud_recommendations.recommendation_decisions d
LEFT JOIN outcome_pivot p ON p.recommendation_id = d.recommendation_id
WHERE d.decided_by = 'ML_AUTO_APPLY'
   OR d.decision_notes ILIKE '%AUTO_APPLY%'
   OR d.gold_evidence_json->>'source' = 'MARKETCLOUD_ML_AUTO_APPLY';

COMMENT ON VIEW marketcloud_recommendations.v_auto_apply_audit_360_v1 IS
    'Audit trail operacional do full-auto 360: proposta, acao aplicada, resultados AMS 1h/3h/24h e verdict por recomendacao.';
