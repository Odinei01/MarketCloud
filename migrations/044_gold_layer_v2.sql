-- =====================================================================
-- ZMC Gold Layer V2 — camada operacional (recomendação + prioridade + ML)
--   G010 gold_recommendation_unified_v2   (unifica G004/G005/G006/G007 + ML)
--   G011 gold_recommendation_priority_v2  (priorização)
--   G012 gold_action_impact_summary_v2    (resumo por ação)
--   G013 gold_campaign_action_plan_v2     (plano por campanha)
--   G014 gold_ml_disagreement_v2          (conflitos Gold vs ML)
--   G015 gold_review_queue_v2             (fila de revisão humana)
--
-- Regra soberana: camada de RECOMENDAÇÃO. Nenhuma view executa ação nem
-- chama API. Gold continua soberana (final_action_type = gold_action_type),
-- exceto safety ZANOM (negativo com 'zanom' -> WATCH / SAFETY_BLOCKED).
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS marketcloud_gold;

-- =====================================================================
-- G010 — gold_recommendation_unified_v2
-- =====================================================================
CREATE OR REPLACE VIEW marketcloud_gold.gold_recommendation_unified_v2 AS
WITH base AS (
    -- HOURLY (G004)
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        'gold_hourly_bid_schedule'::text AS source_gold_view,
        'HOURLY_CAMPAIGN_ADGROUP'::text  AS entity_type,
        campaign_id || '|' || ad_product_type || '|' || ad_group_name || '|' || event_hour::text AS entity_key,
        campaign_id, campaign_name, ad_product_type, ad_group_name,
        event_hour::int AS event_hour,
        NULL::text AS customer_search_term,
        action_type      AS gold_action_type,
        bid_multiplier   AS gold_bid_multiplier,
        reason_code      AS gold_reason_code,
        risk_level       AS gold_risk_level,
        confidence_score AS gold_confidence_score,
        evidence_json    AS gold_evidence_json,
        spend, clicks, orders, sales, roas,
        avg_cpc          AS cpc,
        conversion_rate
    FROM marketcloud_gold.gold_hourly_bid_schedule

    UNION ALL
    -- NEGATIVES (G005)
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        'gold_negative_keyword_candidates', 'SEARCH_TERM',
        campaign_id || '|' || ad_product_type || '|' || search_term_normalized,
        campaign_id, campaign_name, ad_product_type, NULL::text,
        NULL::int, customer_search_term,
        action_type, NULL::numeric, reason_code, risk_level, confidence_score, evidence_json,
        spend, clicks, orders, sales, roas, cpc, NULL::numeric
    FROM marketcloud_gold.gold_negative_keyword_candidates

    UNION ALL
    -- SCALE (G006)
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        'gold_scale_candidates',
        CASE source_view WHEN 'S001' THEN 'CAMPAIGN' WHEN 'S002' THEN 'TARGET' ELSE 'SEARCH_TERM' END,
        CASE source_view
            WHEN 'S001' THEN campaign_id || '|' || ad_product_type
            WHEN 'S002' THEN campaign_id || '|' || ad_product_type || '|' || COALESCE(targeting,'') || '|' || COALESCE(match_type,'')
            ELSE campaign_id || '|' || ad_product_type || '|' || LOWER(TRIM(COALESCE(customer_search_term,'')))
        END,
        campaign_id, campaign_name, ad_product_type, ad_group_name,
        NULL::int, customer_search_term,
        action_type, NULL::numeric, reason_code, risk_level, confidence_score, evidence_json,
        spend, clicks, orders, sales, roas, cpc, NULL::numeric
    FROM marketcloud_gold.gold_scale_candidates

    UNION ALL
    -- CUT (G007)
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        'gold_cut_candidates',
        CASE source_view WHEN 'S001' THEN 'CAMPAIGN' WHEN 'S002' THEN 'TARGET' ELSE 'SEARCH_TERM' END,
        CASE source_view
            WHEN 'S001' THEN campaign_id || '|' || ad_product_type
            WHEN 'S002' THEN campaign_id || '|' || ad_product_type || '|' || COALESCE(targeting,'') || '|' || COALESCE(match_type,'')
            ELSE campaign_id || '|' || ad_product_type || '|' || LOWER(TRIM(COALESCE(customer_search_term,'')))
        END,
        campaign_id, campaign_name, ad_product_type, ad_group_name,
        NULL::int, customer_search_term,
        action_type, NULL::numeric, reason_code, risk_level, confidence_score, evidence_json,
        spend, clicks, orders, sales, roas, cpc, NULL::numeric
    FROM marketcloud_gold.gold_cut_candidates
),
ml AS (
    SELECT DISTINCT ON (entity_type, entity_key)
        entity_type, entity_key, model_name, model_version,
        predicted_action_type, predicted_bid_multiplier,
        confidence_score AS ml_confidence_score,
        prediction_risk_level, prediction_evidence_json, features_snapshot
    FROM marketcloud_features.model_predictions
    ORDER BY entity_type, entity_key, generated_at DESC
),
joined AS (
    SELECT b.*,
        m.model_name, m.model_version, m.predicted_action_type, m.predicted_bid_multiplier,
        m.ml_confidence_score, m.prediction_risk_level, m.prediction_evidence_json, m.features_snapshot
    FROM base b
    LEFT JOIN ml m ON m.entity_type = b.entity_type AND m.entity_key = b.entity_key
),
computed AS (
    SELECT j.*,
        -- ZANOM safety
        (gold_action_type IN ('ADD_NEGATIVE_EXACT','ADD_NEGATIVE_PHRASE')
         AND LOWER(COALESCE(customer_search_term,'')) LIKE '%zanom%') AS zanom_block,
        -- agreement
        CASE WHEN predicted_action_type IS NULL THEN NULL
             ELSE (gold_action_type = predicted_action_type) END AS agreement,
        -- action_conflict
        CASE WHEN predicted_action_type IS NULL THEN NULL
             WHEN gold_action_type = predicted_action_type THEN FALSE ELSE TRUE END AS action_conflict,
        -- final_confidence (raw, pré-zanom)
        CASE
            WHEN gold_confidence_score IS NOT NULL AND ml_confidence_score IS NOT NULL AND gold_action_type = predicted_action_type
                THEN (gold_confidence_score + ml_confidence_score) / 2.0
            WHEN gold_confidence_score IS NOT NULL AND ml_confidence_score IS NOT NULL
                THEN LEAST(gold_confidence_score, ml_confidence_score)
            WHEN gold_confidence_score IS NOT NULL THEN gold_confidence_score
            WHEN ml_confidence_score IS NOT NULL   THEN ml_confidence_score
            ELSE 0.50
        END AS final_confidence_raw,
        -- final_risk (raw, pré-zanom)
        CASE
            WHEN gold_risk_level = 'HIGH'   OR prediction_risk_level = 'HIGH'   THEN 'HIGH'
            WHEN gold_risk_level = 'MEDIUM' OR prediction_risk_level = 'MEDIUM' THEN 'MEDIUM'
            WHEN gold_risk_level = 'LOW'    OR prediction_risk_level = 'LOW'    THEN 'LOW'
            ELSE 'WATCH'
        END AS final_risk_raw
    FROM joined j
),
finalized AS (
    SELECT c.*,
        -- final_action_type (Gold soberana; zanom -> WATCH)
        CASE WHEN zanom_block THEN 'WATCH' ELSE gold_action_type END AS final_action_type,
        -- final_bid_multiplier
        CASE WHEN zanom_block THEN 1.00
             ELSE COALESCE(gold_bid_multiplier,
                CASE gold_action_type
                    WHEN 'CUT_HOUR' THEN 0.50 WHEN 'BID_DOWN' THEN 0.75
                    WHEN 'HOLD' THEN 1.00 WHEN 'WATCH' THEN 1.00 WHEN 'BID_UP' THEN 1.20
                    WHEN 'REDUCE_BID' THEN 0.75 WHEN 'PAUSE_TARGET' THEN 0.00
                    WHEN 'CUT_CAMPAIGN_BUDGET' THEN 0.80 ELSE 1.00
                END)
        END AS final_bid_multiplier,
        final_confidence_raw AS final_confidence_score,
        CASE WHEN zanom_block THEN 'LOW' ELSE final_risk_raw END AS final_risk_level,
        CASE WHEN zanom_block THEN 'SAFETY_BLOCKED'
             WHEN action_conflict IS TRUE THEN 'NEEDS_REVIEW_CONFLICT'
             ELSE 'PENDING_REVIEW' END AS recommendation_status,
        CASE WHEN spend >= 100 THEN 100 WHEN spend >= 50 THEN 75
             WHEN spend >= 20 THEN 50 WHEN spend > 0 THEN 25 ELSE 10 END AS financial_impact_score
    FROM computed c
)
SELECT
    md5(source_gold_view || '|' || entity_key || '|' || COALESCE(gold_action_type,'')) AS recommendation_id,
    tenant_id, amc_instance_id, ads_profile_id,
    source_gold_view, entity_type, entity_key,
    campaign_id, campaign_name, ad_product_type, ad_group_name, event_hour, customer_search_term,
    gold_action_type, gold_bid_multiplier, gold_reason_code, gold_risk_level, gold_confidence_score, gold_evidence_json,
    model_name, model_version, predicted_action_type, predicted_bid_multiplier,
    ml_confidence_score, prediction_risk_level, prediction_evidence_json, features_snapshot,
    agreement, action_conflict,
    spend, clicks, orders, sales, roas, cpc, conversion_rate,
    financial_impact_score,
    -- priority_score (action*0.35 + risk*0.25 + impact*0.25 + confidence*0.15)
    ROUND((
        (CASE final_action_type
            WHEN 'CUT_HOUR' THEN 100 WHEN 'ADD_NEGATIVE_EXACT' THEN 95 WHEN 'ADD_NEGATIVE_PHRASE' THEN 95
            WHEN 'PAUSE_TARGET' THEN 90 WHEN 'CUT_CAMPAIGN_BUDGET' THEN 85 WHEN 'BID_DOWN' THEN 80
            WHEN 'REDUCE_BID' THEN 75 WHEN 'BID_UP' THEN 65 WHEN 'HARVEST_SEARCH_TERM' THEN 60
            WHEN 'MOVE_TO_EXACT' THEN 58 WHEN 'SCALE_CAMPAIGN' THEN 55 WHEN 'INCREASE_BID' THEN 55
            WHEN 'WATCH' THEN 20 WHEN 'HOLD' THEN 10 ELSE 15 END) * 0.35
      + (CASE final_risk_level WHEN 'HIGH' THEN 100 WHEN 'MEDIUM' THEN 60 WHEN 'LOW' THEN 30 WHEN 'WATCH' THEN 20 ELSE 10 END) * 0.25
      + financial_impact_score * 0.25
      + (final_confidence_score * 100) * 0.15
    )::numeric, 2) AS priority_score,
    final_action_type,
    final_bid_multiplier,
    final_confidence_score,
    final_risk_level,
    recommendation_status,
    NOW() AS created_at
FROM finalized;


-- =====================================================================
-- G011 — gold_recommendation_priority_v2
-- =====================================================================
CREATE OR REPLACE VIEW marketcloud_gold.gold_recommendation_priority_v2 AS
SELECT u.*,
    (CASE final_risk_level WHEN 'HIGH' THEN 100 WHEN 'MEDIUM' THEN 60 WHEN 'LOW' THEN 30 WHEN 'WATCH' THEN 20 ELSE 10 END) AS risk_score,
    ROUND((final_confidence_score * 100)::numeric, 2) AS confidence_weight,
    financial_impact_score AS impact_weight,
    (CASE final_action_type
        WHEN 'CUT_HOUR' THEN 100 WHEN 'ADD_NEGATIVE_EXACT' THEN 95 WHEN 'ADD_NEGATIVE_PHRASE' THEN 95
        WHEN 'PAUSE_TARGET' THEN 90 WHEN 'CUT_CAMPAIGN_BUDGET' THEN 85 WHEN 'BID_DOWN' THEN 80
        WHEN 'REDUCE_BID' THEN 75 WHEN 'BID_UP' THEN 65 WHEN 'HARVEST_SEARCH_TERM' THEN 60
        WHEN 'MOVE_TO_EXACT' THEN 58 WHEN 'SCALE_CAMPAIGN' THEN 55 WHEN 'INCREASE_BID' THEN 55
        WHEN 'WATCH' THEN 20 WHEN 'HOLD' THEN 10 ELSE 15 END) AS action_weight,
    ROW_NUMBER() OVER (PARTITION BY tenant_id ORDER BY priority_score DESC, spend DESC NULLS LAST) AS priority_rank,
    CASE
        WHEN priority_score >= 85 THEN 'P0_CRITICAL'
        WHEN priority_score >= 70 THEN 'P1_HIGH'
        WHEN priority_score >= 50 THEN 'P2_MEDIUM'
        ELSE 'P3_LOW'
    END AS priority_bucket
FROM marketcloud_gold.gold_recommendation_unified_v2 u;


-- =====================================================================
-- G012 — gold_action_impact_summary_v2
-- =====================================================================
CREATE OR REPLACE VIEW marketcloud_gold.gold_action_impact_summary_v2 AS
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    final_action_type, final_risk_level, priority_bucket,
    COUNT(*)                                   AS recommendations_count,
    COUNT(DISTINCT entity_key)                 AS entities_count,
    COALESCE(SUM(spend),0)                     AS total_spend,
    COALESCE(SUM(clicks),0)                    AS total_clicks,
    COALESCE(SUM(orders),0)                    AS total_orders,
    COALESCE(SUM(sales),0)                     AS total_sales,
    ROUND(AVG(roas)::numeric,4)                AS avg_roas,
    ROUND(AVG(cpc)::numeric,4)                 AS avg_cpc,
    ROUND(AVG(final_confidence_score)::numeric,4) AS avg_confidence,
    ROUND(AVG(priority_score)::numeric,2)      AS avg_priority_score,
    COUNT(*) FILTER (WHERE priority_bucket='P0_CRITICAL') AS p0_count,
    COUNT(*) FILTER (WHERE priority_bucket='P1_HIGH')     AS p1_count,
    COUNT(*) FILTER (WHERE priority_bucket='P2_MEDIUM')   AS p2_count,
    COUNT(*) FILTER (WHERE priority_bucket='P3_LOW')      AS p3_count,
    COUNT(*) FILTER (WHERE action_conflict IS TRUE)       AS conflict_count
FROM marketcloud_gold.gold_recommendation_priority_v2
GROUP BY tenant_id, amc_instance_id, ads_profile_id, final_action_type, final_risk_level, priority_bucket;


-- =====================================================================
-- G013 — gold_campaign_action_plan_v2
-- =====================================================================
CREATE OR REPLACE VIEW marketcloud_gold.gold_campaign_action_plan_v2 AS
WITH agg AS (
    SELECT
        tenant_id, amc_instance_id, ads_profile_id, campaign_id, ad_product_type,
        MAX(campaign_name) AS campaign_name,
        COUNT(*) AS total_recommendations,
        COUNT(*) FILTER (WHERE priority_bucket='P0_CRITICAL') AS p0_count,
        COUNT(*) FILTER (WHERE priority_bucket='P1_HIGH')     AS p1_count,
        COUNT(*) FILTER (WHERE final_risk_level='HIGH')       AS high_risk_count,
        COUNT(*) FILTER (WHERE action_conflict IS TRUE)       AS conflict_count,
        COUNT(*) FILTER (WHERE final_action_type='CUT_HOUR')            AS cut_hour_count,
        COUNT(*) FILTER (WHERE final_action_type='BID_DOWN')            AS bid_down_count,
        COUNT(*) FILTER (WHERE final_action_type='BID_UP')             AS bid_up_count,
        COUNT(*) FILTER (WHERE final_action_type IN ('ADD_NEGATIVE_EXACT','ADD_NEGATIVE_PHRASE')) AS negative_count,
        COUNT(*) FILTER (WHERE final_action_type='HARVEST_SEARCH_TERM') AS harvest_count,
        COUNT(*) FILTER (WHERE final_action_type='CUT_CAMPAIGN_BUDGET') AS cut_budget_count,
        COUNT(*) FILTER (WHERE final_action_type='PAUSE_TARGET')        AS pause_target_count,
        COUNT(*) FILTER (WHERE final_action_type='REDUCE_BID')          AS reduce_bid_count,
        COALESCE(SUM(spend) FILTER (WHERE final_risk_level='HIGH'),0)   AS total_spend_at_risk,
        COALESCE(SUM(sales),0) AS total_sales,
        ROUND(AVG(roas)::numeric,4) AS avg_roas,
        MAX(priority_score) AS max_priority_score
    FROM marketcloud_gold.gold_recommendation_priority_v2
    GROUP BY tenant_id, amc_instance_id, ads_profile_id, campaign_id, ad_product_type
)
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    campaign_id, campaign_name, ad_product_type,
    total_recommendations, p0_count, p1_count, high_risk_count, conflict_count,
    cut_hour_count, bid_down_count, bid_up_count, negative_count, harvest_count,
    cut_budget_count, pause_target_count, reduce_bid_count,
    total_spend_at_risk, total_sales, avg_roas, max_priority_score,
    CASE
        WHEN cut_hour_count   > 0 THEN 'CUT_HOUR_REVIEW'
        WHEN cut_budget_count > 0 THEN 'BUDGET_REVIEW'
        WHEN negative_count   > 0 THEN 'NEGATIVE_REVIEW'
        WHEN bid_up_count     > 0 THEN 'SCALE_REVIEW'
        ELSE 'WATCH'
    END AS dominant_action,
    CASE
        WHEN p0_count > 0 OR high_risk_count >= 3 THEN 'URGENT_CUT_REVIEW'
        WHEN negative_count > 0 THEN 'NEGATIVE_KEYWORD_REVIEW'
        WHEN bid_up_count > 0 OR harvest_count > 0 THEN 'SCALE_OPPORTUNITY'
        WHEN bid_down_count > 0 OR bid_up_count > 0 THEN 'BID_OPTIMIZATION'
        ELSE 'WATCH'
    END AS campaign_plan_bucket,
    jsonb_build_object(
        'total', total_recommendations, 'p0', p0_count, 'p1', p1_count,
        'high_risk', high_risk_count, 'conflicts', conflict_count,
        'cut_hour', cut_hour_count, 'bid_down', bid_down_count, 'bid_up', bid_up_count,
        'negative', negative_count, 'harvest', harvest_count, 'cut_budget', cut_budget_count,
        'pause_target', pause_target_count, 'reduce_bid', reduce_bid_count,
        'spend_at_risk', ROUND(total_spend_at_risk::numeric,2)
    ) AS evidence_summary_json,
    NOW() AS created_at
FROM agg;


-- =====================================================================
-- G014 — gold_ml_disagreement_v2
-- =====================================================================
CREATE OR REPLACE VIEW marketcloud_gold.gold_ml_disagreement_v2 AS
SELECT
    recommendation_id, entity_type, entity_key,
    campaign_id, campaign_name, ad_product_type, ad_group_name, event_hour, customer_search_term,
    gold_action_type, predicted_action_type,
    gold_confidence_score, ml_confidence_score,
    gold_risk_level, prediction_risk_level,
    spend, clicks, orders, sales, roas,
    CASE
        WHEN gold_action_type IN ('CUT_HOUR','BID_DOWN','CUT_CAMPAIGN_BUDGET','REDUCE_BID','PAUSE_TARGET')
             AND predicted_action_type IN ('BID_UP','SCALE_CAMPAIGN','INCREASE_BID') THEN 'CUT_VS_SCALE'
        WHEN gold_action_type IN ('ADD_NEGATIVE_EXACT','ADD_NEGATIVE_PHRASE')
             AND predicted_action_type IN ('HARVEST_SEARCH_TERM','MOVE_TO_EXACT') THEN 'NEGATIVE_VS_HARVEST'
        WHEN gold_action_type = 'BID_DOWN' AND predicted_action_type = 'BID_UP' THEN 'DOWN_VS_UP'
        WHEN gold_action_type = 'WATCH' OR predicted_action_type = 'WATCH' THEN 'WATCH_VS_ACTION'
        ELSE 'OTHER'
    END AS conflict_type,
    CASE
        WHEN (gold_action_type='CUT_HOUR' AND predicted_action_type='BID_UP')
          OR (gold_action_type='ADD_NEGATIVE_EXACT' AND predicted_action_type='HARVEST_SEARCH_TERM')
          OR (gold_action_type='CUT_CAMPAIGN_BUDGET' AND predicted_action_type='SCALE_CAMPAIGN') THEN 'HIGH'
        WHEN (gold_action_type='BID_DOWN' AND predicted_action_type='HOLD')
          OR (gold_action_type='WATCH' AND predicted_action_type='BID_UP')
          OR (gold_action_type='WATCH' AND predicted_action_type='ADD_NEGATIVE_EXACT') THEN 'MEDIUM'
        ELSE 'LOW'
    END AS conflict_severity,
    'gold=' || COALESCE(gold_action_type,'-') || ' vs ml=' || COALESCE(predicted_action_type,'-') AS conflict_reason,
    gold_evidence_json, prediction_evidence_json, features_snapshot,
    created_at
FROM marketcloud_gold.gold_recommendation_unified_v2
WHERE action_conflict IS TRUE OR agreement IS FALSE;


-- =====================================================================
-- G015 — gold_review_queue_v2
-- =====================================================================
CREATE OR REPLACE VIEW marketcloud_gold.gold_review_queue_v2 AS
SELECT
    recommendation_id, priority_rank, priority_bucket, priority_score,
    entity_type, entity_key,
    campaign_id, campaign_name, ad_product_type, ad_group_name, event_hour, customer_search_term,
    final_action_type, final_bid_multiplier, final_confidence_score, final_risk_level,
    agreement, action_conflict, recommendation_status,
    spend, clicks, orders, sales, roas, cpc, conversion_rate,
    'NOT_DECIDED'::text  AS human_decision_status,
    'NOT_EXECUTED'::text AS execution_status,
    gold_evidence_json, prediction_evidence_json, features_snapshot,
    created_at
FROM marketcloud_gold.gold_recommendation_priority_v2;
