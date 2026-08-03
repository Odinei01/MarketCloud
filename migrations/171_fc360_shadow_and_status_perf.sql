-- Migration 169: Status AMS+ML performance and Full Control 360 shadow coverage.
--
-- 1) The ML worker now generates 360 recommendations for every campaign/hour
--    as advisory/shadow when governance cannot control the campaign.
-- 2) Governance can have more than one row per campaign, so the 360 decision
--    and ledger sync must be deterministic per recommendation_id.

CREATE OR REPLACE VIEW marketcloud_gold.v_ml_full_control_360_decision_v1 AS
SELECT DISTINCT ON (a.recommendation_id)
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
    a.evidence_json,
    a.model_version,
    a.computed_at,
    a.expected_delta_spend,
    a.expected_delta_sales,
    a.expected_delta_roas,
    a.decision_class,
    a.execution_strategy,
    a.min_roas_used,
    a.data_sufficiency,
    a.operator_note,
    COALESCE(g.can_control, false) AS can_control_now,
    COALESCE(g.gate_reason, 'NO_GOVERNANCE_ROW') AS gate_reason,
    COALESCE(g.spend_today, 0)::numeric AS spend_today,
    COALESCE(g.orders_today, 0)::numeric AS orders_today,
    COALESCE(g.stock_available, 0)::numeric AS stock_available,
    COALESCE(g.max_daily_budget_brl, 0)::numeric AS max_daily_budget_brl,
    COALESCE(g.max_spend_without_order_brl, 0)::numeric AS max_spend_without_order_brl,
    COALESCE(g.min_roas, a.min_roas_used, 4)::numeric AS effective_min_roas,
    CASE
        WHEN a.guardrail_status = 'SHADOW_NOT_APPLICABLE'
            THEN 'AGUARDAR_DADOS'
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
        WHEN a.guardrail_status = 'SHADOW_NOT_APPLICABLE'
            THEN 'Shadow/advisor: recomendacao observavel, sem permissao de execucao real nesta campanha.'
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
     )
ORDER BY a.recommendation_id,
    CASE COALESCE(g.status, '') WHEN 'active' THEN 0 WHEN 'draft' THEN 1 ELSE 2 END,
    g.updated_at DESC NULLS LAST;

CREATE OR REPLACE FUNCTION marketcloud_recommendations.sync_ml_full_control_360_proposals()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    affected INTEGER;
BEGIN
    WITH src_raw AS (
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
    ), src AS (
        SELECT DISTINCT ON (recommendation_id) *
        FROM src_raw
        ORDER BY recommendation_id
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

COMMENT ON VIEW marketcloud_gold.v_ml_full_control_360_decision_v1 IS
    'Classificacao operacional deduplicada das propostas ML 360: aplica/testa quando governanca permite; shadow/advisor quando nao permite executar.';
