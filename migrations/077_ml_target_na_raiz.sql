-- O ALVO DO ML NA RAIZ (decisao do dono: "faça agora").
--
-- Contexto: 075 levou o alvo do ML pra LISTA do cockpit (actionable_v3), mas os
-- CARDS do topo leem gold_action_impact_summary_v2 -> gold_recommendation_priority_v2.
-- Duas fontes, um conserto so: a lista mudava (CUT_HOUR 81->32) e os cards nao.
-- O dono viu na hora: "as recomendacoes continuam as mesmas".
--
-- gold_recommendation_priority_v2 e um envelope simples sobre a unified_v2, e as
-- QUATRO views penduram nela (summary, actionable, review_queue,
-- campaign_action_plan). Trocando a FONTE aqui dentro, todas herdam de uma vez —
-- e o proprio corpo da view (action_weight, que faz CASE final_action_type) passa
-- a usar a acao corrigida sozinho.
--
-- As constantes chapadas nascem na unified_v2 (CUT_HOUR 0.50 / BID_DOWN 0.75 /
-- BID_UP 1.20), sem olhar ROAS nenhum. Nao mexo la: 17k chars decidindo TODAS as
-- acoes da conta (negativar, pausar, budget), e o alvo horario nao diz nada sobre
-- elas. O override fica no envelope, so nas acoes horarias.
CREATE OR REPLACE VIEW marketcloud_gold.gold_recommendation_priority_v2 AS
 SELECT recommendation_id,
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    source_gold_view,
    entity_type,
    entity_key,
    campaign_id,
    campaign_name,
    ad_product_type,
    ad_group_name,
    event_hour,
    customer_search_term,
    gold_action_type,
    gold_bid_multiplier,
    gold_reason_code,
    gold_risk_level,
    gold_confidence_score,
    gold_evidence_json,
    model_name,
    model_version,
    predicted_action_type,
    predicted_bid_multiplier,
    ml_confidence_score,
    prediction_risk_level,
    prediction_evidence_json,
    features_snapshot,
    agreement,
    action_conflict,
    spend,
    clicks,
    orders,
    sales,
    roas,
    cpc,
    conversion_rate,
    financial_impact_score,
    priority_score,
    final_action_type,
    final_bid_multiplier,
    final_confidence_score,
    final_risk_level,
    recommendation_status,
    created_at,
        CASE final_risk_level
            WHEN 'HIGH'::text THEN 100
            WHEN 'MEDIUM'::text THEN 60
            WHEN 'LOW'::text THEN 30
            WHEN 'WATCH'::text THEN 20
            ELSE 10
        END AS risk_score,
    round(final_confidence_score * 100::numeric, 2) AS confidence_weight,
    financial_impact_score AS impact_weight,
        CASE final_action_type
            WHEN 'CUT_HOUR'::text THEN 100
            WHEN 'ADD_NEGATIVE_EXACT'::text THEN 95
            WHEN 'ADD_NEGATIVE_PHRASE'::text THEN 95
            WHEN 'PAUSE_TARGET'::text THEN 90
            WHEN 'CUT_CAMPAIGN_BUDGET'::text THEN 85
            WHEN 'BID_DOWN'::text THEN 80
            WHEN 'REDUCE_BID'::text THEN 75
            WHEN 'BID_UP'::text THEN 65
            WHEN 'HARVEST_SEARCH_TERM'::text THEN 60
            WHEN 'MOVE_TO_EXACT'::text THEN 58
            WHEN 'SCALE_CAMPAIGN'::text THEN 55
            WHEN 'INCREASE_BID'::text THEN 55
            WHEN 'WATCH'::text THEN 20
            WHEN 'HOLD'::text THEN 10
            ELSE 15
        END AS action_weight,
    row_number() OVER (PARTITION BY tenant_id ORDER BY priority_score DESC, spend DESC NULLS LAST) AS priority_rank,
        CASE
            WHEN priority_score >= 85::numeric THEN 'P0_CRITICAL'::text
            WHEN priority_score >= 70::numeric THEN 'P1_HIGH'::text
            WHEN priority_score >= 50::numeric THEN 'P2_MEDIUM'::text
            ELSE 'P3_LOW'::text
        END AS priority_bucket
   FROM (
     SELECT
        x.recommendation_id,
        x.tenant_id,
        x.amc_instance_id,
        x.ads_profile_id,
        x.source_gold_view,
        x.entity_type,
        x.entity_key,
        x.campaign_id,
        x.campaign_name,
        x.ad_product_type,
        x.ad_group_name,
        x.event_hour,
        x.customer_search_term,
        x.gold_action_type,
        x.gold_bid_multiplier,
        x.gold_reason_code,
        x.gold_risk_level,
        x.gold_confidence_score,
        x.gold_evidence_json,
        x.model_name,
        x.model_version,
        x.predicted_action_type,
        x.predicted_bid_multiplier,
        x.ml_confidence_score,
        x.prediction_risk_level,
        x.prediction_evidence_json,
        x.features_snapshot,
        x.agreement,
        x.action_conflict,
        x.spend,
        x.clicks,
        x.orders,
        x.sales,
        x.roas,
        x.cpc,
        x.conversion_rate,
        x.financial_impact_score,
        x.priority_score,
        x.final_confidence_score,
        x.final_risk_level,
        x.recommendation_status,
        x.created_at
,
        -- acao horaria que o ML NAO sustenta vira WATCH: sem isso a tela diria
        -- "cortar" e o valor aplicado SUBIRIA o lance.
        CASE WHEN h.horaria AND t.ml_multiplier >= COALESCE(cur.multiplier, 1.0) - 0.05
             THEN 'WATCH'::text ELSE x.final_action_type END AS final_action_type,
        CASE WHEN h.horaria THEN t.ml_multiplier ELSE x.final_bid_multiplier END AS final_bid_multiplier
     FROM marketcloud_gold.gold_recommendation_unified_v2 x
     LEFT JOIN marketcloud_gold.gold_hourly_ml_target_mv t
       ON t.campaign_name = x.campaign_name AND t.event_hour = x.event_hour
     LEFT JOIN LATERAL (
        -- multiplicador que a campanha tem hoje naquela hora (escopo CAMPAIGN)
        SELECT s.multiplier FROM marketcloud_bronze.bronze_swarm_bid_schedule s
        WHERE lower(trim(s.campaign_name)) = lower(trim(x.campaign_name))
          AND s.hour_start <= x.event_hour AND s.hour_end > x.event_hour
          AND COALESCE(s.day_of_week,'') = ''
          AND COALESCE(s.profile_is_active, true) = true
          AND upper(COALESCE(s.profile_status,'')) = 'PUBLISHED'
          AND s.scope = 'CAMPAIGN'
        LIMIT 1
     ) cur ON TRUE
     CROSS JOIN LATERAL (
        SELECT (x.final_action_type IN ('CUT_HOUR','BID_DOWN')
                AND x.event_hour IS NOT NULL
                AND t.ml_multiplier IS NOT NULL) AS horaria
     ) h
   ) u;
