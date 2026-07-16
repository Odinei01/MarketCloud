-- 088: os 4 consumidores passam a ler a materialized view (P0 perf).
-- Troca gold_recommendation_priority_v2 -> _mv. A v2 (custosa) so e lida
-- pelo refresh da _mv agora, nao por request. Definicao identica no resto.

CREATE OR REPLACE VIEW marketcloud_gold.gold_action_impact_summary_v2 AS
SELECT tenant_id,
    amc_instance_id,
    ads_profile_id,
    final_action_type,
    final_risk_level,
    priority_bucket,
    count(*) AS recommendations_count,
    count(DISTINCT entity_key) AS entities_count,
    COALESCE(sum(spend), 0::numeric) AS total_spend,
    COALESCE(sum(clicks), 0::numeric) AS total_clicks,
    COALESCE(sum(orders), 0::numeric) AS total_orders,
    COALESCE(sum(sales), 0::numeric) AS total_sales,
    round(avg(roas), 4) AS avg_roas,
    round(avg(cpc), 4) AS avg_cpc,
    round(avg(final_confidence_score), 4) AS avg_confidence,
    round(avg(priority_score), 2) AS avg_priority_score,
    count(*) FILTER (WHERE priority_bucket = 'P0_CRITICAL'::text) AS p0_count,
    count(*) FILTER (WHERE priority_bucket = 'P1_HIGH'::text) AS p1_count,
    count(*) FILTER (WHERE priority_bucket = 'P2_MEDIUM'::text) AS p2_count,
    count(*) FILTER (WHERE priority_bucket = 'P3_LOW'::text) AS p3_count,
    count(*) FILTER (WHERE action_conflict IS TRUE) AS conflict_count
   FROM marketcloud_gold.gold_recommendation_priority_mv
  GROUP BY tenant_id, amc_instance_id, ads_profile_id, final_action_type, final_risk_level, priority_bucket;;

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
           FROM marketcloud_gold.gold_recommendation_priority_mv p
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
                  WHERE s.campaign_id = q.campaign_id AND q.event_hour >= s.hour_start AND q.event_hour < s.hour_end AND (upper(COALESCE(s.campaign_status, 'ENABLED'::text)) <> ALL (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text])) AND (COALESCE(s.ad_group_id, ''::text) = ''::text OR (upper(COALESCE(s.ad_group_status, 'ENABLED'::text)) <> ALL (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text]))) AND s.scope = 'CAMPAIGN'::text AND COALESCE(s.profile_is_active, true) = true AND upper(COALESCE(s.profile_status, ''::text)) = 'PUBLISHED'::text
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

CREATE OR REPLACE VIEW marketcloud_gold.gold_review_queue_v2 AS
SELECT p.tenant_id,
    p.amc_instance_id,
    p.ads_profile_id,
    p.recommendation_id,
    p.priority_rank,
    p.priority_bucket,
    p.priority_score,
    p.entity_type,
    p.entity_key,
    p.campaign_id,
    p.campaign_name,
    p.ad_product_type,
    p.ad_group_name,
    p.event_hour,
    p.customer_search_term,
    p.final_action_type,
    p.final_bid_multiplier,
    p.final_confidence_score,
    p.final_risk_level,
    p.agreement,
    p.action_conflict,
    p.recommendation_status,
    p.spend,
    p.clicks,
    p.orders,
    p.sales,
    p.roas,
    p.cpc,
    p.conversion_rate,
    COALESCE(d.decision, 'NOT_DECIDED'::text) AS human_decision_status,
    COALESCE(d.execution_status, 'NOT_EXECUTED'::text) AS execution_status,
    d.decided_by,
    d.decided_at,
    d.decision_notes,
    p.gold_evidence_json,
    p.prediction_evidence_json,
    p.features_snapshot,
    p.created_at
   FROM marketcloud_gold.gold_recommendation_priority_mv p
     LEFT JOIN marketcloud_recommendations.recommendation_decisions d ON d.recommendation_id = p.recommendation_id;;

CREATE OR REPLACE VIEW marketcloud_gold.gold_campaign_action_plan_v2 AS
WITH agg AS (
         SELECT gold_recommendation_priority_mv.tenant_id,
            gold_recommendation_priority_mv.amc_instance_id,
            gold_recommendation_priority_mv.ads_profile_id,
            gold_recommendation_priority_mv.campaign_id,
            gold_recommendation_priority_mv.ad_product_type,
            max(gold_recommendation_priority_mv.campaign_name) AS campaign_name,
            count(*) AS total_recommendations,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.priority_bucket = 'P0_CRITICAL'::text) AS p0_count,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.priority_bucket = 'P1_HIGH'::text) AS p1_count,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.final_risk_level = 'HIGH'::text) AS high_risk_count,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.action_conflict IS TRUE) AS conflict_count,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.final_action_type = 'CUT_HOUR'::text) AS cut_hour_count,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.final_action_type = 'BID_DOWN'::text) AS bid_down_count,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.final_action_type = 'BID_UP'::text) AS bid_up_count,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.final_action_type = ANY (ARRAY['ADD_NEGATIVE_EXACT'::text, 'ADD_NEGATIVE_PHRASE'::text])) AS negative_count,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.final_action_type = 'HARVEST_SEARCH_TERM'::text) AS harvest_count,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.final_action_type = 'CUT_CAMPAIGN_BUDGET'::text) AS cut_budget_count,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.final_action_type = 'PAUSE_TARGET'::text) AS pause_target_count,
            count(*) FILTER (WHERE gold_recommendation_priority_mv.final_action_type = 'REDUCE_BID'::text) AS reduce_bid_count,
            COALESCE(sum(gold_recommendation_priority_mv.spend) FILTER (WHERE gold_recommendation_priority_mv.final_risk_level = 'HIGH'::text), 0::numeric) AS total_spend_at_risk,
            COALESCE(sum(gold_recommendation_priority_mv.sales), 0::numeric) AS total_sales,
            round(avg(gold_recommendation_priority_mv.roas), 4) AS avg_roas,
            max(gold_recommendation_priority_mv.priority_score) AS max_priority_score
           FROM marketcloud_gold.gold_recommendation_priority_mv
          GROUP BY gold_recommendation_priority_mv.tenant_id, gold_recommendation_priority_mv.amc_instance_id, gold_recommendation_priority_mv.ads_profile_id, gold_recommendation_priority_mv.campaign_id, gold_recommendation_priority_mv.ad_product_type
        )
 SELECT tenant_id,
    amc_instance_id,
    ads_profile_id,
    campaign_id,
    campaign_name,
    ad_product_type,
    total_recommendations,
    p0_count,
    p1_count,
    high_risk_count,
    conflict_count,
    cut_hour_count,
    bid_down_count,
    bid_up_count,
    negative_count,
    harvest_count,
    cut_budget_count,
    pause_target_count,
    reduce_bid_count,
    total_spend_at_risk,
    total_sales,
    avg_roas,
    max_priority_score,
        CASE
            WHEN cut_hour_count > 0 THEN 'CUT_HOUR_REVIEW'::text
            WHEN cut_budget_count > 0 THEN 'BUDGET_REVIEW'::text
            WHEN negative_count > 0 THEN 'NEGATIVE_REVIEW'::text
            WHEN bid_up_count > 0 THEN 'SCALE_REVIEW'::text
            ELSE 'WATCH'::text
        END AS dominant_action,
        CASE
            WHEN p0_count > 0 OR high_risk_count >= 3 THEN 'URGENT_CUT_REVIEW'::text
            WHEN negative_count > 0 THEN 'NEGATIVE_KEYWORD_REVIEW'::text
            WHEN bid_up_count > 0 OR harvest_count > 0 THEN 'SCALE_OPPORTUNITY'::text
            WHEN bid_down_count > 0 OR bid_up_count > 0 THEN 'BID_OPTIMIZATION'::text
            ELSE 'WATCH'::text
        END AS campaign_plan_bucket,
    jsonb_build_object('total', total_recommendations, 'p0', p0_count, 'p1', p1_count, 'high_risk', high_risk_count, 'conflicts', conflict_count, 'cut_hour', cut_hour_count, 'bid_down', bid_down_count, 'bid_up', bid_up_count, 'negative', negative_count, 'harvest', harvest_count, 'cut_budget', cut_budget_count, 'pause_target', pause_target_count, 'reduce_bid', reduce_bid_count, 'spend_at_risk', round(total_spend_at_risk, 2)) AS evidence_summary_json,
    now() AS created_at
   FROM agg;;

