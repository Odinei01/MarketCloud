-- O cockpit de recomendacoes tambem passa a usar o alvo do ML (decisao do dono,
-- 15/07: "leva o alvo do ML tambem").
--
-- Antes: CUT_HOUR aplicava 0.50 e BID_DOWN 0.75 — CONSTANTES CHAPADAS. Toda
-- hora marcada pra cortar levava o mesmo 0.5, tendo ela ROAS 0 ou ROAS 4. E
-- havia linha pedindo "cortar para 0.50" numa hora que JA estava em 0.50.
--
-- Agora: nas acoes horarias (CUT_HOUR/BID_DOWN, as unicas que mexem em
-- multiplicador de hora), o alvo vem de gold_hourly_ml_target_multiplier.
--
-- TRAVA IMPORTANTE: se o alvo do ML NAO justifica o corte (ml >= atual - 0.05),
-- a linha vira WATCH em vez de CUT_HOUR. Sem isso a tela mandaria "cortar" e o
-- valor aplicado SUBIRIA o lance — a mesma contradicao que a tela de keywords
-- tinha ("reduzir de 0.20 para 0.70"). Aqui e pior: 4 campanhas aplicam sozinhas.
--
-- Acoes nao-horarias (negativar, pausar target, budget, REDUCE_BID que nao tem
-- event_hour) NAO sao tocadas: o alvo horario nao diz nada sobre elas.
CREATE OR REPLACE VIEW marketcloud_gold.gold_review_queue_actionable_v3 AS
SELECT
       v.tenant_id,
       v.amc_instance_id,
       v.ads_profile_id,
       v.recommendation_id,
       v.priority_rank,
       v.priority_bucket,
       v.priority_score,
       v.entity_type,
       v.entity_key,
       v.campaign_id,
       v.campaign_name,
       v.ad_product_type,
       v.ad_group_name,
       v.event_hour,
       v.customer_search_term,
       CASE WHEN horaria.ok AND t.ml_multiplier >= v.current_hour_multiplier - 0.05 THEN 'WATCH' ELSE v.final_action_type END AS final_action_type,
       CASE WHEN horaria.ok THEN t.ml_multiplier ELSE v.final_bid_multiplier END AS final_bid_multiplier,
       v.final_confidence_score,
       v.final_risk_level,
       v.agreement,
       v.action_conflict,
       v.recommendation_status,
       v.spend,
       v.clicks,
       v.orders,
       v.sales,
       v.roas,
       v.cpc,
       v.conversion_rate,
       v.campaign_status,
       v.ad_group_status,
       v.swarm_entity_status,
       v.already_negative,
       v.current_hour_multiplier,
       v.campaign_avg_bid,
       v.swarm_roas_35d,
       v.swarm_state,
       CASE WHEN horaria.ok THEN round((v.campaign_avg_bid * t.ml_multiplier)::numeric, 2) ELSE v.target_bid END AS target_bid,
       v.human_decision_status,
       v.execution_status,
       v.decided_by,
       v.decided_at,
       v.gold_evidence_json,
       v.prediction_evidence_json,
       v.features_snapshot,
       v.created_at
,
       horaria.ok AS ml_target_aplicado,
       t.roas_observado::numeric AS ml_roas_observado,
       t.roas_ancora::numeric    AS ml_roas_ancora
FROM marketcloud_gold.gold_review_queue_actionable_v2 v
LEFT JOIN marketcloud_gold.gold_hourly_ml_target_multiplier t
  ON t.campaign_name = v.campaign_name AND t.event_hour = v.event_hour
CROSS JOIN LATERAL (
    SELECT (v.final_action_type IN ('CUT_HOUR','BID_DOWN')
            AND v.event_hour IS NOT NULL
            AND t.ml_multiplier IS NOT NULL) AS ok
) horaria;

COMMENT ON VIEW marketcloud_gold.gold_review_queue_actionable_v3 IS
    'Fila do cockpit com o alvo do ML nas acoes horarias (CUT_HOUR/BID_DOWN). Corte que o ML nao sustenta vira WATCH. Demais acoes intocadas.';
