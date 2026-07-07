-- =====================================================================
-- Gold V2 — Fila ACIONÁVEL (cruza recomendação AMC com o estado real do
-- Robô ZANOM já ingerido no lake). Remove o ruído: recomendações já feitas.
--
-- Validado: 60 de 86 recs horárias já estavam no schedule; 14 de 45 negativas
-- já existiam. Só o que é NEW deve chegar ao humano.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.gold_review_queue_actionable_v2 AS
WITH q AS (
    SELECT p.*, LOWER(TRIM(COALESCE(p.customer_search_term,''))) AS term_norm
    FROM marketcloud_gold.gold_recommendation_priority_v2 p
),
enriched AS (
    SELECT q.*,
        -- negativa já existe (EXACT igual OU PHRASE contida), ENABLED?
        CASE WHEN q.final_action_type IN ('ADD_NEGATIVE_EXACT','ADD_NEGATIVE_PHRASE') THEN
            EXISTS(SELECT 1 FROM marketcloud_bronze.bronze_swarm_negatives n
                WHERE n.campaign_id = q.campaign_id AND n.state = 'ENABLED'
                  AND (n.keyword_norm = q.term_norm
                       OR (n.match_type LIKE '%PHRASE%' AND q.term_norm LIKE '%' || n.keyword_norm || '%')))
        ELSE NULL END AS already_negative,
        -- hora já reduzida no schedule?
        (SELECT s.multiplier FROM marketcloud_bronze.bronze_swarm_bid_schedule s
            WHERE s.campaign_id = q.campaign_id AND q.event_hour >= s.hour_start AND q.event_hour < s.hour_end
            ORDER BY s.multiplier ASC LIMIT 1) AS current_hour_multiplier,
        -- bid atual da campanha (referência p/ a ação concreta)
        (SELECT ROUND(AVG(bid)::numeric,4) FROM marketcloud_bronze.bronze_swarm_current_bids b
            WHERE b.campaign_id = q.campaign_id AND b.bid > 0) AS campaign_avg_bid,
        -- ROAS real do Robô (últimos 35 dias)
        (SELECT ROUND((CASE WHEN SUM(cost) > 0 THEN SUM(attributed_sales)/SUM(cost) ELSE 0 END)::numeric,2)
            FROM marketcloud_bronze.bronze_swarm_campaign_metrics m
            WHERE m.campaign_id = q.campaign_id
              AND m.data_date >= (SELECT MAX(data_date) - INTERVAL '34 days' FROM marketcloud_bronze.bronze_swarm_campaign_metrics)
        ) AS swarm_roas_35d
    FROM q
)
SELECT
    e.tenant_id, e.amc_instance_id, e.ads_profile_id,
    e.recommendation_id, e.priority_rank, e.priority_bucket, e.priority_score,
    e.entity_type, e.entity_key,
    e.campaign_id, e.campaign_name, e.ad_product_type, e.ad_group_name, e.event_hour, e.customer_search_term,
    e.final_action_type, e.final_bid_multiplier, e.final_confidence_score, e.final_risk_level,
    e.agreement, e.action_conflict, e.recommendation_status,
    e.spend, e.clicks, e.orders, e.sales, e.roas, e.cpc, e.conversion_rate,
    -- estado no Robô ZANOM
    e.already_negative,
    e.current_hour_multiplier,
    e.campaign_avg_bid,
    e.swarm_roas_35d,
    -- veredito de acionabilidade
    CASE
        WHEN e.already_negative IS TRUE THEN 'ALREADY_NEGATIVE'
        WHEN e.final_action_type IN ('CUT_HOUR','BID_DOWN','REDUCE_BID')
             AND e.current_hour_multiplier IS NOT NULL AND e.current_hour_multiplier < 1.0 THEN 'ALREADY_SCHEDULED'
        ELSE 'NEW'
    END AS swarm_state,
    -- alvo concreto: bid efetivo sugerido na hora (bid médio × multiplicador)
    CASE WHEN e.campaign_avg_bid IS NOT NULL AND e.final_bid_multiplier IS NOT NULL
         THEN ROUND((e.campaign_avg_bid * e.final_bid_multiplier)::numeric, 2) END AS target_bid,
    COALESCE(d.decision, 'NOT_DECIDED')          AS human_decision_status,
    COALESCE(d.execution_status, 'NOT_EXECUTED') AS execution_status,
    d.decided_by, d.decided_at,
    e.gold_evidence_json, e.prediction_evidence_json, e.features_snapshot,
    e.created_at
FROM enriched e
LEFT JOIN marketcloud_recommendations.recommendation_decisions d ON d.recommendation_id = e.recommendation_id;
