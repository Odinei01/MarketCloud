-- =====================================================================
-- ML Full Control 360 decision + outcome layer
--
-- Completa o loop sem mock:
--   ML proposes -> proposal is classified -> optional real executor records
--   recommendation_decisions -> AMS/gold canonical signal measures outcomes.
--
-- Budget/placement are not auto-executed here. If no real executor recorded
-- execution_status=EXECUTED, the audit remains PENDING_EXECUTION by design.
-- =====================================================================

ALTER TABLE marketcloud_gold.ml_full_control_action_recommendations_v1
    ADD COLUMN IF NOT EXISTS expected_delta_spend NUMERIC(18,4),
    ADD COLUMN IF NOT EXISTS expected_delta_sales NUMERIC(18,4),
    ADD COLUMN IF NOT EXISTS expected_delta_roas NUMERIC(10,4),
    ADD COLUMN IF NOT EXISTS decision_class TEXT NOT NULL DEFAULT 'WAIT_MORE_DATA',
    ADD COLUMN IF NOT EXISTS execution_strategy TEXT NOT NULL DEFAULT 'ADVISORY',
    ADD COLUMN IF NOT EXISTS min_roas_used NUMERIC(10,4),
    ADD COLUMN IF NOT EXISTS data_sufficiency TEXT NOT NULL DEFAULT 'UNKNOWN',
    ADD COLUMN IF NOT EXISTS operator_note TEXT;

CREATE INDEX IF NOT EXISTS idx_ml_fc360_decision
    ON marketcloud_gold.ml_full_control_action_recommendations_v1
    (decision_class, guardrail_status, confidence, priority_score DESC);

CREATE OR REPLACE VIEW marketcloud_gold.v_ml_full_control_360_decision_v1 AS
SELECT
    a.*,
    COALESCE(g.can_control, false) AS can_control_now,
    COALESCE(g.gate_reason, 'NO_GOVERNANCE_ROW') AS gate_reason,
    COALESCE(g.spend_today, 0)::numeric AS spend_today,
    COALESCE(g.orders_today, 0)::numeric AS orders_today,
    COALESCE(g.stock_available, 0)::numeric AS stock_available,
    COALESCE(g.max_daily_budget_brl, 0)::numeric AS max_daily_budget_brl,
    COALESCE(g.max_spend_without_order_brl, 0)::numeric AS max_spend_without_order_brl,
    COALESCE(g.min_roas, a.min_roas_used, 4)::numeric AS effective_min_roas,
    CASE
        WHEN a.guardrail_status <> 'READY' OR COALESCE(g.can_control, false) IS NOT TRUE
            THEN 'BLOQUEAR'
        WHEN a.action_type IN ('STOP_LOSS_PROTECT','REDUCE_DAILY_BUDGET','REDUCE_TOP_OF_SEARCH')
             AND COALESCE(a.expected_roas, 0) < COALESCE(g.min_roas, a.min_roas_used, 4)
            THEN 'APLICAR_SEGURANCA'
        WHEN a.confidence = 'HIGH'
             AND COALESCE(a.expected_roas, 0) >= COALESCE(g.min_roas, a.min_roas_used, 4) * 1.15
             AND COALESCE(a.conversion_probability, 0) >= 0.55
            THEN 'APLICAR'
        WHEN a.confidence IN ('HIGH','MEDIUM')
             AND COALESCE(a.expected_roas, 0) >= COALESCE(g.min_roas, a.min_roas_used, 4)
            THEN 'TESTAR_CONTROLADO'
        WHEN a.data_sufficiency IN ('LOW_DATA','TARGET_CONFLICT')
            THEN 'AGUARDAR_DADOS'
        ELSE 'AGUARDAR_DADOS'
    END AS operator_decision,
    CASE
        WHEN a.guardrail_status <> 'READY' OR COALESCE(g.can_control, false) IS NOT TRUE
            THEN COALESCE(g.gate_reason, a.guardrail_status)
        WHEN a.action_type IN ('STOP_LOSS_PROTECT','REDUCE_DAILY_BUDGET','REDUCE_TOP_OF_SEARCH')
             AND COALESCE(a.expected_roas, 0) < COALESCE(g.min_roas, a.min_roas_used, 4)
            THEN 'Acao defensiva: reduzir risco quando o ROAS previsto esta abaixo do minimo.'
        WHEN a.confidence = 'HIGH'
             AND COALESCE(a.expected_roas, 0) >= COALESCE(g.min_roas, a.min_roas_used, 4) * 1.15
             AND COALESCE(a.conversion_probability, 0) >= 0.55
            THEN 'Sinal forte: modelo, ROAS esperado e probabilidade sustentam aplicacao.'
        WHEN a.confidence IN ('HIGH','MEDIUM')
             AND COALESCE(a.expected_roas, 0) >= COALESCE(g.min_roas, a.min_roas_used, 4)
            THEN 'Sinal suficiente para teste controlado, nao para mudanca agressiva.'
        ELSE 'Volume/confianca insuficiente para acao automatica.'
    END AS operator_reason
FROM marketcloud_gold.ml_full_control_action_recommendations_v1 a
LEFT JOIN marketcloud_gold.full_control_effective_governance_v1 g
  ON (
      COALESCE(a.campaign_id, '') <> ''
      AND g.campaign_id = a.campaign_id
     )
  OR (
      COALESCE(a.campaign_id, '') = ''
      AND lower(trim(g.campaign_name)) = lower(trim(a.campaign_name))
     );

COMMENT ON VIEW marketcloud_gold.v_ml_full_control_360_decision_v1 IS
    'Classificacao operacional das propostas ML 360: aplicar, testar, aguardar ou bloquear, sempre rechecando governanca atual.';

CREATE OR REPLACE FUNCTION marketcloud_recommendations.sync_ml_full_control_360_proposals()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected INTEGER;
BEGIN
    WITH src AS (
        SELECT
            d.recommendation_id,
            COALESCE(NULLIF(d.tenant_id,''), COALESCE(g.tenant_id::text, 'zanom')) AS tenant_id,
            COALESCE(i.amc_instance_id, 'amcoo5vzswt') AS amc_instance_id,
            COALESCE(i.ads_profile_id, '3084626225435227') AS ads_profile_id,
            d.campaign_id,
            d.campaign_name,
            d.event_hour,
            d.action_type,
            d.current_value,
            d.recommended_value,
            d.priority_score,
            d.confidence,
            d.expected_roas,
            d.conversion_probability,
            d.guardrail_status,
            d.reason,
            d.evidence_json,
            d.expected_delta_spend,
            d.expected_delta_sales,
            d.expected_delta_roas,
            d.decision_class,
            d.execution_strategy,
            d.data_sufficiency,
            d.operator_decision,
            d.operator_reason
        FROM marketcloud_gold.v_ml_full_control_360_decision_v1 d
        LEFT JOIN marketcloud_gold.full_control_effective_governance_v1 g
          ON (d.campaign_id IS NOT NULL AND d.campaign_id = g.campaign_id)
          OR (d.campaign_id IS NULL AND lower(trim(d.campaign_name)) = lower(trim(g.campaign_name)))
        LEFT JOIN LATERAL (
            SELECT amc_instance_id, ads_profile_id
            FROM marketcloud_control.amc_instances
            LIMIT 1
        ) i ON TRUE
    ), upserted AS (
        INSERT INTO marketcloud_recommendations.recommendation_decisions (
            recommendation_id, tenant_id, amc_instance_id, ads_profile_id,
            entity_type, entity_key, campaign_id, campaign_name, ad_product_type,
            event_hour, recommended_action, recommended_bid_multiplier,
            priority_score, priority_bucket, final_risk_level, final_confidence_score,
            gold_evidence_json, prediction_evidence_json, features_snapshot,
            decision, decided_action, decided_bid_multiplier, decided_by, decision_notes,
            execution_status, updated_at
        )
        SELECT
            s.recommendation_id, s.tenant_id, s.amc_instance_id, s.ads_profile_id,
            'FULL_CONTROL_360',
            COALESCE(s.campaign_id, s.campaign_name) || ':' || s.event_hour || ':' || s.action_type,
            s.campaign_id, s.campaign_name, 'SPONSORED_PRODUCTS',
            s.event_hour, s.action_type, NULL,
            s.priority_score, s.confidence, s.decision_class, s.conversion_probability,
            jsonb_build_object(
                'source', 'MARKETCLOUD_ML_FULL_CONTROL_360',
                'current_value', s.current_value,
                'recommended_value', s.recommended_value,
                'expected_delta_spend', s.expected_delta_spend,
                'expected_delta_sales', s.expected_delta_sales,
                'expected_delta_roas', s.expected_delta_roas,
                'guardrail_status', s.guardrail_status,
                'reason', s.reason
            ),
            jsonb_build_object(
                'expected_roas', s.expected_roas,
                'conversion_probability', s.conversion_probability,
                'confidence', s.confidence,
                'decision_class', s.decision_class,
                'execution_strategy', s.execution_strategy,
                'data_sufficiency', s.data_sufficiency,
                'operator_decision', s.operator_decision,
                'operator_reason', s.operator_reason
            ),
            COALESCE(s.evidence_json, '{}'::jsonb),
            'NOT_DECIDED',
            NULL,
            NULL,
            'ML_FULL_CONTROL_360',
            s.operator_reason,
            'NOT_EXECUTED',
            NOW()
        FROM src s
        ON CONFLICT (recommendation_id) DO UPDATE SET
            recommended_action = EXCLUDED.recommended_action,
            priority_score = EXCLUDED.priority_score,
            priority_bucket = EXCLUDED.priority_bucket,
            final_risk_level = EXCLUDED.final_risk_level,
            final_confidence_score = EXCLUDED.final_confidence_score,
            gold_evidence_json = EXCLUDED.gold_evidence_json,
            prediction_evidence_json = EXCLUDED.prediction_evidence_json,
            features_snapshot = EXCLUDED.features_snapshot,
            decision_notes = CASE
                WHEN marketcloud_recommendations.recommendation_decisions.execution_status = 'EXECUTED'
                    THEN marketcloud_recommendations.recommendation_decisions.decision_notes
                ELSE EXCLUDED.decision_notes
            END,
            updated_at = NOW()
        WHERE marketcloud_recommendations.recommendation_decisions.execution_status <> 'EXECUTED'
        RETURNING 1
    )
    SELECT COUNT(*) INTO affected FROM upserted;

    RETURN affected;
END;
$$;

CREATE OR REPLACE VIEW marketcloud_recommendations.v_ml_full_control_360_audit_v1 AS
WITH outcome_pivot AS (
    SELECT
        recommendation_id,
        MAX(measured_at) AS last_measured_at,
        MAX(outcome_label) FILTER (WHERE outcome_window = '1h') AS outcome_label_1h,
        MAX(delta_roas) FILTER (WHERE outcome_window = '1h') AS delta_roas_1h,
        MAX(outcome_label) FILTER (WHERE outcome_window = '3h') AS outcome_label_3h,
        MAX(delta_roas) FILTER (WHERE outcome_window = '3h') AS delta_roas_3h,
        MAX(outcome_label) FILTER (WHERE outcome_window = '24h') AS outcome_label_24h,
        MAX(delta_roas) FILTER (WHERE outcome_window = '24h') AS delta_roas_24h,
        COUNT(*) FILTER (WHERE outcome_label IS NOT NULL) AS measured_windows,
        COUNT(*) FILTER (WHERE outcome_label = 'IMPROVED') AS improved_windows,
        COUNT(*) FILTER (WHERE outcome_label = 'WORSENED') AS worsened_windows
    FROM marketcloud_recommendations.recommendation_hourly_outcomes
    GROUP BY recommendation_id
)
SELECT
    a.recommendation_id,
    a.tenant_id,
    a.campaign_id,
    a.campaign_name,
    a.event_hour,
    a.action_type,
    a.action_scope,
    a.current_value,
    a.recommended_value,
    a.expected_roas,
    a.conversion_probability,
    a.confidence,
    a.priority_score,
    a.guardrail_status,
    a.reason,
    a.expected_delta_spend,
    a.expected_delta_sales,
    a.expected_delta_roas,
    a.decision_class,
    a.execution_strategy,
    a.data_sufficiency,
    a.operator_decision,
    a.operator_reason,
    d.decision,
    d.execution_status,
    d.executed_at,
    d.decided_at,
    COALESCE(o.measured_windows, 0) AS measured_windows,
    o.outcome_label_1h,
    o.delta_roas_1h,
    o.outcome_label_3h,
    o.delta_roas_3h,
    o.outcome_label_24h,
    o.delta_roas_24h,
    CASE
        WHEN d.execution_status IS DISTINCT FROM 'EXECUTED' THEN 'PENDING_EXECUTION'
        WHEN COALESCE(o.measured_windows,0) = 0 THEN 'PENDING_MEASUREMENT'
        WHEN COALESCE(o.worsened_windows,0) > COALESCE(o.improved_windows,0) THEN 'LOSING'
        WHEN COALESCE(o.improved_windows,0) > 0 THEN 'WINNING'
        ELSE 'NEUTRAL'
    END AS audit_result,
    o.last_measured_at,
    a.computed_at,
    a.evidence_json,
    a.min_roas_used,
    a.operator_note
FROM marketcloud_gold.v_ml_full_control_360_decision_v1 a
LEFT JOIN marketcloud_recommendations.recommendation_decisions d
  ON d.recommendation_id = a.recommendation_id
LEFT JOIN outcome_pivot o
  ON o.recommendation_id = a.recommendation_id;

COMMENT ON VIEW marketcloud_recommendations.v_ml_full_control_360_audit_v1 IS
    'Audit 360 das propostas Full Control: proposta, classificacao, execucao real se houver e outcomes AMS/gold.';

-- Recria o medidor horario usando a fonte canonica unificada, nao bronze SP-only.
CREATE OR REPLACE FUNCTION marketcloud_recommendations.refresh_recommendation_hourly_outcomes()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected INTEGER;
BEGIN
    WITH decisions AS (
        SELECT
            d.*,
            COALESCE(d.event_hour, EXTRACT(HOUR FROM d.executed_at AT TIME ZONE 'America/Sao_Paulo')::INTEGER) AS measured_hour,
            d.executed_at AT TIME ZONE 'America/Sao_Paulo' AS executed_local
        FROM marketcloud_recommendations.recommendation_decisions d
        WHERE d.execution_status = 'EXECUTED'
          AND d.decision IN ('APPROVED','MODIFIED')
          AND d.executed_at IS NOT NULL
          AND (d.campaign_id IS NOT NULL OR d.campaign_name IS NOT NULL)
    ), starts AS (
        SELECT
            d.*,
            CASE
                WHEN (date_trunc('day', d.executed_local) + (d.measured_hour * interval '1 hour')) <= d.executed_local
                    THEN (date_trunc('day', d.executed_local) + (d.measured_hour * interval '1 hour') + interval '1 day') AT TIME ZONE 'America/Sao_Paulo'
                ELSE (date_trunc('day', d.executed_local) + (d.measured_hour * interval '1 hour')) AT TIME ZONE 'America/Sao_Paulo'
            END AS action_start_at
        FROM decisions d
    ), windows AS (
        SELECT '1h'::TEXT AS outcome_window, interval '1 hour' AS duration
        UNION ALL SELECT '3h'::TEXT, interval '3 hours'
        UNION ALL SELECT '24h'::TEXT, interval '24 hours'
    ), candidates AS (
        SELECT s.*, w.outcome_window, w.duration, s.action_start_at + w.duration AS eval_window_end
        FROM starts s
        CROSS JOIN windows w
        WHERE s.action_start_at + w.duration <= NOW()
    ), hourly AS (
        SELECT
            i.campaign_id,
            lower(trim(u.campaign_name)) AS campaign_norm,
            ((u.data_date::timestamp + (u.event_hour * interval '1 hour')) AT TIME ZONE 'America/Sao_Paulo') AS hour_at,
            COALESCE(u.spend, 0)::numeric AS spend,
            COALESCE(u.orders_7d, 0)::numeric AS orders,
            COALESCE(u.sales_7d, 0)::numeric AS sales
        FROM marketcloud_gold.gold_hourly_signal_unified u
        LEFT JOIN marketcloud_gold.gold_campaign_identity i
          ON i.campaign_norm = lower(trim(u.campaign_name))
    ), measured AS (
        SELECT
            c.*,
            COALESCE(b.spend,0)::numeric AS baseline_spend,
            COALESCE(b.orders,0)::numeric AS baseline_orders,
            COALESCE(b.sales,0)::numeric AS baseline_sales,
            CASE WHEN COALESCE(b.spend,0) > 0 THEN (b.sales / NULLIF(b.spend,0)) ELSE 0 END::numeric AS baseline_roas,
            COALESCE(b.hours,0)::integer AS baseline_hours,
            COALESCE(e.spend,0)::numeric AS eval_spend,
            COALESCE(e.orders,0)::numeric AS eval_orders,
            COALESCE(e.sales,0)::numeric AS eval_sales,
            CASE WHEN COALESCE(e.spend,0) > 0 THEN (e.sales / NULLIF(e.spend,0)) ELSE 0 END::numeric AS eval_roas,
            COALESCE(e.hours,0)::integer AS eval_hours
        FROM candidates c
        LEFT JOIN LATERAL (
            SELECT SUM(h.spend) AS spend, SUM(h.orders) AS orders, SUM(h.sales) AS sales, COUNT(*) AS hours
            FROM hourly h
            WHERE (
                    (c.campaign_id IS NOT NULL AND h.campaign_id = c.campaign_id)
                 OR (c.campaign_id IS NULL AND h.campaign_norm = lower(trim(c.campaign_name)))
                  )
              AND h.hour_at >= c.action_start_at - c.duration
              AND h.hour_at < c.action_start_at
        ) b ON TRUE
        LEFT JOIN LATERAL (
            SELECT SUM(h.spend) AS spend, SUM(h.orders) AS orders, SUM(h.sales) AS sales, COUNT(*) AS hours
            FROM hourly h
            WHERE (
                    (c.campaign_id IS NOT NULL AND h.campaign_id = c.campaign_id)
                 OR (c.campaign_id IS NULL AND h.campaign_norm = lower(trim(c.campaign_name)))
                  )
              AND h.hour_at >= c.action_start_at
              AND h.hour_at < c.eval_window_end
        ) e ON TRUE
    ), labeled AS (
        SELECT
            m.*,
            (m.eval_spend - m.baseline_spend) AS delta_spend,
            (m.eval_orders - m.baseline_orders) AS delta_orders,
            (m.eval_sales - m.baseline_sales) AS delta_sales,
            (m.eval_roas - m.baseline_roas) AS delta_roas,
            CASE
                WHEN m.eval_hours = 0 THEN 'NO_DATA'
                WHEN (m.eval_roas - m.baseline_roas) > 0.50 THEN 'IMPROVED'
                WHEN (m.eval_roas - m.baseline_roas) < -0.50 THEN 'WORSENED'
                ELSE 'NEUTRAL'
            END AS outcome_label
        FROM measured m
    ), upserted AS (
        INSERT INTO marketcloud_recommendations.recommendation_hourly_outcomes (
            recommendation_id, decision_id, tenant_id, amc_instance_id, ads_profile_id,
            entity_type, entity_key, campaign_id, campaign_name, ad_group_name, event_hour,
            recommended_action, recommended_bid_multiplier, decided_action, decided_bid_multiplier,
            decision, execution_status, executed_at, outcome_window, action_start_at, eval_window_end,
            baseline_spend, baseline_orders, baseline_sales, baseline_roas, baseline_hours,
            eval_spend, eval_orders, eval_sales, eval_roas, eval_hours,
            delta_spend, delta_orders, delta_sales, delta_roas,
            outcome_label, model_verdict, measured_at
        )
        SELECT
            l.recommendation_id, l.decision_id, l.tenant_id, l.amc_instance_id, l.ads_profile_id,
            l.entity_type, l.entity_key, l.campaign_id, l.campaign_name, l.ad_group_name, l.measured_hour,
            l.recommended_action, l.recommended_bid_multiplier, l.decided_action, l.decided_bid_multiplier,
            l.decision, l.execution_status, l.executed_at, l.outcome_window, l.action_start_at, l.eval_window_end,
            l.baseline_spend, l.baseline_orders, l.baseline_sales, l.baseline_roas, l.baseline_hours,
            l.eval_spend, l.eval_orders, l.eval_sales, l.eval_roas, l.eval_hours,
            l.delta_spend, l.delta_orders, l.delta_sales, l.delta_roas,
            l.outcome_label,
            CASE
                WHEN l.outcome_label = 'IMPROVED' THEN 'MODEL_RIGHT'
                WHEN l.outcome_label = 'WORSENED' THEN 'MODEL_WRONG'
                ELSE 'INCONCLUSIVE'
            END AS model_verdict,
            NOW()
        FROM labeled l
        ON CONFLICT (recommendation_id, outcome_window, action_start_at) DO UPDATE SET
            baseline_spend = EXCLUDED.baseline_spend,
            baseline_orders = EXCLUDED.baseline_orders,
            baseline_sales = EXCLUDED.baseline_sales,
            baseline_roas = EXCLUDED.baseline_roas,
            baseline_hours = EXCLUDED.baseline_hours,
            eval_spend = EXCLUDED.eval_spend,
            eval_orders = EXCLUDED.eval_orders,
            eval_sales = EXCLUDED.eval_sales,
            eval_roas = EXCLUDED.eval_roas,
            eval_hours = EXCLUDED.eval_hours,
            delta_spend = EXCLUDED.delta_spend,
            delta_orders = EXCLUDED.delta_orders,
            delta_sales = EXCLUDED.delta_sales,
            delta_roas = EXCLUDED.delta_roas,
            outcome_label = EXCLUDED.outcome_label,
            model_verdict = EXCLUDED.model_verdict,
            measured_at = NOW()
        RETURNING 1
    )
    SELECT COUNT(*) INTO affected FROM upserted;

    RETURN affected;
END;
$$;

SELECT marketcloud_recommendations.sync_ml_full_control_360_proposals();
SELECT marketcloud_recommendations.refresh_recommendation_hourly_outcomes();
