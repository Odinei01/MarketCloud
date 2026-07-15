-- 080: o "Atual" da linha de campanha pegava o MENOR multiplicador entre
-- escopos misturados (ORDER BY s.multiplier LIMIT 1) — inclusive o de keywords
-- individuais. Ex.: Seladora 13h mostrava "atual 0.70" (uma keyword) quando a
-- CAMPANHA esta em 1.00 PUBLISHED; 19h mostrava 0.50 quando a campanha esta em
-- 0.70. Numa recomendacao de CAMPANHA o atual e o da campanha: filtra
-- scope=CAMPAIGN + PUBLISHED + ativo, igual o resolver do robo faz.
-- Mesmo bug de escopo misturado que a migration 069 corrigiu no lado keyword.
-- +1: a regra de CAMPANHA vem do sync com ad_group_status=PAUSED mesmo sem ter
-- ad group (ad_group_id vazio) — o LATERAL do sync carimba o status de um grupo
-- qualquer da campanha. O filtro de status de grupo so vale quando ha grupo.
CREATE OR REPLACE VIEW marketcloud_gold.gold_review_queue_actionable_v2 AS
WITH q AS (
         SELECT p.recommendation_id,
            p.tenant_id,
            p.amc_instance_id,
            p.ads_profile_id,
            p.source_gold_view,
            p.entity_type,
            p.entity_key,
            p.campaign_id,
            p.campaign_name,
            p.ad_product_type,
            p.ad_group_name,
            p.event_hour,
            p.customer_search_term,
            p.gold_action_type,
            p.gold_bid_multiplier,
            p.gold_reason_code,
            p.gold_risk_level,
            p.gold_confidence_score,
            p.gold_evidence_json,
            p.model_name,
            p.model_version,
            p.predicted_action_type,
            p.predicted_bid_multiplier,
            p.ml_confidence_score,
            p.prediction_risk_level,
            p.prediction_evidence_json,
            p.features_snapshot,
            p.agreement,
            p.action_conflict,
            p.spend,
            p.clicks,
            p.orders,
            p.sales,
            p.roas,
            p.cpc,
            p.conversion_rate,
            p.financial_impact_score,
            p.priority_score,
            p.final_action_type,
            p.final_bid_multiplier,
            p.final_confidence_score,
            p.final_risk_level,
            p.recommendation_status,
            p.created_at,
            p.risk_score,
            p.confidence_weight,
            p.impact_weight,
            p.action_weight,
            p.priority_rank,
            p.priority_bucket,
            lower(TRIM(BOTH FROM COALESCE(p.customer_search_term, ''::text))) AS term_norm
           FROM marketcloud_gold.gold_recommendation_priority_v2 p
        ), enriched AS (
         SELECT q.recommendation_id,
            q.tenant_id,
            q.amc_instance_id,
            q.ads_profile_id,
            q.source_gold_view,
            q.entity_type,
            q.entity_key,
            q.campaign_id,
            q.campaign_name,
            q.ad_product_type,
            q.ad_group_name,
            q.event_hour,
            q.customer_search_term,
            q.gold_action_type,
            q.gold_bid_multiplier,
            q.gold_reason_code,
            q.gold_risk_level,
            q.gold_confidence_score,
            q.gold_evidence_json,
            q.model_name,
            q.model_version,
            q.predicted_action_type,
            q.predicted_bid_multiplier,
            q.ml_confidence_score,
            q.prediction_risk_level,
            q.prediction_evidence_json,
            q.features_snapshot,
            q.agreement,
            q.action_conflict,
            q.spend,
            q.clicks,
            q.orders,
            q.sales,
            q.roas,
            q.cpc,
            q.conversion_rate,
            q.financial_impact_score,
            q.priority_score,
            q.final_action_type,
            q.final_bid_multiplier,
            q.final_confidence_score,
            q.final_risk_level,
            q.recommendation_status,
            q.created_at,
            q.risk_score,
            q.confidence_weight,
            q.impact_weight,
            q.action_weight,
            q.priority_rank,
            q.priority_bucket,
            q.term_norm,
            status.campaign_status,
            status.ad_group_status,
                CASE
                    WHEN upper(COALESCE(status.campaign_status, ''::text)) = ANY (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text]) THEN 'CAMPAIGN_INACTIVE'::text
                    WHEN upper(COALESCE(status.ad_group_status, ''::text)) = ANY (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text]) THEN 'AD_GROUP_INACTIVE'::text
                    ELSE 'ACTIVE_OR_UNKNOWN'::text
                END AS swarm_entity_status,
                CASE
                    WHEN q.final_action_type = ANY (ARRAY['ADD_NEGATIVE_EXACT'::text, 'ADD_NEGATIVE_PHRASE'::text]) THEN (EXISTS ( SELECT 1
                       FROM marketcloud_bronze.bronze_swarm_negatives n
                      WHERE n.campaign_id = q.campaign_id AND n.state = 'ENABLED'::text AND (upper(COALESCE(n.campaign_status, 'ENABLED'::text)) <> ALL (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text])) AND (upper(COALESCE(n.ad_group_status, 'ENABLED'::text)) <> ALL (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text])) AND (n.keyword_norm = q.term_norm OR n.match_type ~~ '%PHRASE%'::text AND q.term_norm ~~ (('%'::text || n.keyword_norm) || '%'::text))))
                    ELSE NULL::boolean
                END AS already_negative,
            ( SELECT s.multiplier
                   FROM marketcloud_bronze.bronze_swarm_bid_schedule s
                  WHERE s.campaign_id = q.campaign_id AND q.event_hour >= s.hour_start AND q.event_hour < s.hour_end AND (upper(COALESCE(s.campaign_status, 'ENABLED'::text)) <> ALL (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text])) AND (COALESCE(s.ad_group_id, ''::text) = ''::text
                         OR (upper(COALESCE(s.ad_group_status, 'ENABLED'::text)) <> ALL (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text])))
                    AND s.scope = 'CAMPAIGN'::text
                    AND COALESCE(s.profile_is_active, true) = true
                    AND upper(COALESCE(s.profile_status, ''::text)) = 'PUBLISHED'::text
                 LIMIT 1) AS current_hour_multiplier,
            ( SELECT round(avg(b.bid), 4) AS round
                   FROM marketcloud_bronze.bronze_swarm_current_bids b
                  WHERE b.campaign_id = q.campaign_id AND b.bid > 0::numeric AND (upper(COALESCE(b.campaign_status, 'ENABLED'::text)) <> ALL (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text])) AND (upper(COALESCE(b.ad_group_status, 'ENABLED'::text)) <> ALL (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text]))) AS campaign_avg_bid,
            ( SELECT round(
                        CASE
                            WHEN sum(m.cost) > 0::numeric THEN sum(m.attributed_sales) / sum(m.cost)
                            ELSE 0::numeric
                        END, 2) AS round
                   FROM marketcloud_bronze.bronze_swarm_campaign_metrics m
                  WHERE m.campaign_id = q.campaign_id AND (upper(COALESCE(m.campaign_status, 'ENABLED'::text)) <> ALL (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text])) AND m.data_date >= (( SELECT max(bronze_swarm_campaign_metrics.data_date) - '34 days'::interval
                           FROM marketcloud_bronze.bronze_swarm_campaign_metrics))) AS swarm_roas_35d
           FROM q
             LEFT JOIN LATERAL ( SELECT s.campaign_status,
                    s.ad_group_status
                   FROM ( SELECT bronze_swarm_current_bids.campaign_id,
                            bronze_swarm_current_bids.ad_group_name,
                            bronze_swarm_current_bids.campaign_status,
                            bronze_swarm_current_bids.ad_group_status,
                            bronze_swarm_current_bids.state,
                            bronze_swarm_current_bids.ingested_at
                           FROM marketcloud_bronze.bronze_swarm_current_bids
                        UNION ALL
                         SELECT bronze_swarm_negatives.campaign_id,
                            bronze_swarm_negatives.ad_group_name,
                            bronze_swarm_negatives.campaign_status,
                            bronze_swarm_negatives.ad_group_status,
                            bronze_swarm_negatives.state,
                            bronze_swarm_negatives.ingested_at
                           FROM marketcloud_bronze.bronze_swarm_negatives
                        UNION ALL
                         SELECT bronze_swarm_bid_schedule.campaign_id,
                            bronze_swarm_bid_schedule.ad_group_name,
                            bronze_swarm_bid_schedule.campaign_status,
                            bronze_swarm_bid_schedule.ad_group_status,
                            NULL::text AS state,
                            bronze_swarm_bid_schedule.ingested_at
                           FROM marketcloud_bronze.bronze_swarm_bid_schedule) s
                  WHERE s.campaign_id = q.campaign_id AND (COALESCE(q.ad_group_name, ''::text) = ''::text OR COALESCE(s.ad_group_name, ''::text) = ''::text OR lower(s.ad_group_name) = lower(q.ad_group_name))
                  ORDER BY (
                        CASE
                            WHEN COALESCE(q.ad_group_name, ''::text) <> ''::text AND lower(COALESCE(s.ad_group_name, ''::text)) = lower(q.ad_group_name) THEN 0
                            ELSE 1
                        END), (
                        CASE
                            WHEN upper(COALESCE(s.state, ''::text)) = 'ENABLED'::text THEN 0
                            ELSE 1
                        END), s.ingested_at DESC NULLS LAST
                 LIMIT 1) status ON true
        )
 SELECT e.tenant_id,
    e.amc_instance_id,
    e.ads_profile_id,
    e.recommendation_id,
    e.priority_rank,
    e.priority_bucket,
    e.priority_score,
    e.entity_type,
    e.entity_key,
    e.campaign_id,
    e.campaign_name,
    e.ad_product_type,
    e.ad_group_name,
    e.event_hour,
    e.customer_search_term,
    e.final_action_type,
    e.final_bid_multiplier,
    e.final_confidence_score,
    e.final_risk_level,
    e.agreement,
    e.action_conflict,
    e.recommendation_status,
    e.spend,
    e.clicks,
    e.orders,
    e.sales,
    e.roas,
    e.cpc,
    e.conversion_rate,
    e.campaign_status,
    e.ad_group_status,
    e.swarm_entity_status,
    e.already_negative,
    e.current_hour_multiplier,
    e.campaign_avg_bid,
    e.swarm_roas_35d,
        CASE
            WHEN e.already_negative IS TRUE THEN 'ALREADY_NEGATIVE'::text
            WHEN (e.final_action_type = ANY (ARRAY['CUT_HOUR'::text, 'BID_DOWN'::text, 'REDUCE_BID'::text])) AND e.current_hour_multiplier IS NOT NULL AND e.current_hour_multiplier < 1.0 THEN 'ALREADY_SCHEDULED'::text
            ELSE 'NEW'::text
        END AS swarm_state,
        CASE
            WHEN e.campaign_avg_bid IS NOT NULL AND e.final_bid_multiplier IS NOT NULL THEN round(e.campaign_avg_bid * e.final_bid_multiplier, 2)
            ELSE NULL::numeric
        END AS target_bid,
    COALESCE(d.decision, 'NOT_DECIDED'::text) AS human_decision_status,
    COALESCE(d.execution_status, 'NOT_EXECUTED'::text) AS execution_status,
    d.decided_by,
    d.decided_at,
    e.gold_evidence_json,
    e.prediction_evidence_json,
    e.features_snapshot,
    e.created_at
   FROM enriched e
     LEFT JOIN marketcloud_recommendations.recommendation_decisions d ON d.recommendation_id = e.recommendation_id
  WHERE e.swarm_entity_status = 'ACTIVE_OR_UNKNOWN'::text;;
