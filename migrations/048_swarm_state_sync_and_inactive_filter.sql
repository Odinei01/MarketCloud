-- =====================================================================
-- SWARM account-state sync v2
--
-- Adds campaign/ad-group status to the SWARM bronze snapshot, exposes a
-- repeatable refresh function for the orchestrator, and keeps archived/paused
-- campaigns or ad groups out of the actionable Gold queue.
-- =====================================================================

ALTER TABLE marketcloud_bronze.bronze_swarm_negatives
    ADD COLUMN IF NOT EXISTS ad_group_name TEXT,
    ADD COLUMN IF NOT EXISTS campaign_status TEXT,
    ADD COLUMN IF NOT EXISTS ad_group_status TEXT;

ALTER TABLE marketcloud_bronze.bronze_swarm_bid_schedule
    ADD COLUMN IF NOT EXISTS ad_group_name TEXT,
    ADD COLUMN IF NOT EXISTS profile_status TEXT,
    ADD COLUMN IF NOT EXISTS profile_is_active BOOLEAN,
    ADD COLUMN IF NOT EXISTS campaign_status TEXT,
    ADD COLUMN IF NOT EXISTS ad_group_status TEXT;

ALTER TABLE marketcloud_bronze.bronze_swarm_current_bids
    ADD COLUMN IF NOT EXISTS ad_group_name TEXT,
    ADD COLUMN IF NOT EXISTS campaign_status TEXT,
    ADD COLUMN IF NOT EXISTS ad_group_status TEXT;

ALTER TABLE marketcloud_bronze.bronze_swarm_campaign_metrics
    ADD COLUMN IF NOT EXISTS campaign_status TEXT;

CREATE INDEX IF NOT EXISTS idx_swarm_neg_status
    ON marketcloud_bronze.bronze_swarm_negatives (campaign_id, campaign_status, ad_group_status);
CREATE INDEX IF NOT EXISTS idx_swarm_sched_status
    ON marketcloud_bronze.bronze_swarm_bid_schedule (campaign_id, campaign_status, ad_group_status);
CREATE INDEX IF NOT EXISTS idx_swarm_bids_status
    ON marketcloud_bronze.bronze_swarm_current_bids (campaign_id, campaign_status, ad_group_status);

CREATE OR REPLACE FUNCTION marketcloud_bronze.refresh_swarm_account_state()
RETURNS TABLE(source_table TEXT, rows_inserted BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    n BIGINT;
BEGIN
    TRUNCATE marketcloud_bronze.bronze_swarm_negatives;
    INSERT INTO marketcloud_bronze.bronze_swarm_negatives (
        campaign_id, campaign_name, ad_group_id, ad_group_name,
        keyword_text, keyword_norm, match_type, state,
        campaign_status, ad_group_status, ingested_at
    )
    SELECT DISTINCT ON (CAST(campaign_id AS TEXT), LOWER(TRIM(keyword_text)), match_type)
        CAST(campaign_id AS TEXT),
        campaign_name,
        CAST(ad_group_id AS TEXT),
        ad_group_name,
        keyword_text,
        LOWER(TRIM(keyword_text)),
        match_type,
        state,
        campaign_status,
        ad_group_status,
        NOW()
    FROM swarm_src.amazon_ads_targeting_inventory
    WHERE is_negative = TRUE
      AND keyword_text IS NOT NULL
      AND campaign_id IS NOT NULL
    ORDER BY
        CAST(campaign_id AS TEXT),
        LOWER(TRIM(keyword_text)),
        match_type,
        CASE WHEN UPPER(COALESCE(state,'')) = 'ENABLED' THEN 0 ELSE 1 END,
        updated_at DESC NULLS LAST;
    GET DIAGNOSTICS n = ROW_COUNT;
    source_table := 'bronze_swarm_negatives';
    rows_inserted := n;
    RETURN NEXT;

    TRUNCATE marketcloud_bronze.bronze_swarm_bid_schedule;
    INSERT INTO marketcloud_bronze.bronze_swarm_bid_schedule (
        profile_id_ref, campaign_id, campaign_name, ad_group_id, ad_group_name,
        entity_type, day_of_week, hour_start, hour_end, multiplier, label, risk_flag,
        profile_status, profile_is_active, campaign_status, ad_group_status, ingested_at
    )
    SELECT
        CAST(r.profile_id_ref AS TEXT),
        CAST(p.campaign_id AS TEXT),
        p.campaign_name,
        CAST(p.ad_group_id AS TEXT),
        p.ad_group_name,
        p.entity_type,
        r.day_of_week,
        r.hour_start,
        r.hour_end,
        r.multiplier,
        r.label,
        CAST(r.risk_flag AS TEXT),
        p.status,
        p.is_active,
        st.campaign_status,
        st.ad_group_status,
        NOW()
    FROM swarm_src.zanom_ads_bid_schedule_rules r
    LEFT JOIN swarm_src.zanom_ads_bid_schedule_profiles p
        ON CAST(p.id AS TEXT) = CAST(r.profile_id_ref AS TEXT)
    LEFT JOIN LATERAL (
        SELECT t.campaign_status, t.ad_group_status
        FROM swarm_src.amazon_ads_targeting_inventory t
        WHERE CAST(t.campaign_id AS TEXT) = CAST(p.campaign_id AS TEXT)
          AND (
              p.ad_group_id IS NULL
              OR CAST(p.ad_group_id AS TEXT) = ''
              OR CAST(t.ad_group_id AS TEXT) = CAST(p.ad_group_id AS TEXT)
              OR LOWER(COALESCE(t.ad_group_name,'')) = LOWER(COALESCE(p.ad_group_name,''))
          )
        ORDER BY
            CASE WHEN UPPER(COALESCE(t.state,'')) = 'ENABLED' THEN 0 ELSE 1 END,
            t.updated_at DESC NULLS LAST
        LIMIT 1
    ) st ON TRUE
    WHERE COALESCE(p.is_active, TRUE) = TRUE
      AND UPPER(COALESCE(p.status, 'ACTIVE')) NOT IN ('ARCHIVED', 'PAUSED', 'DELETED');
    GET DIAGNOSTICS n = ROW_COUNT;
    source_table := 'bronze_swarm_bid_schedule';
    rows_inserted := n;
    RETURN NEXT;

    TRUNCATE marketcloud_bronze.bronze_swarm_current_bids;
    INSERT INTO marketcloud_bronze.bronze_swarm_current_bids (
        campaign_id, campaign_name, ad_group_id, ad_group_name,
        keyword_text, match_type, bid, state, serving_status,
        campaign_status, ad_group_status, ingested_at
    )
    SELECT
        CAST(campaign_id AS TEXT),
        campaign_name,
        CAST(ad_group_id AS TEXT),
        ad_group_name,
        keyword_text,
        match_type,
        bid,
        state,
        serving_status,
        campaign_status,
        ad_group_status,
        NOW()
    FROM swarm_src.amazon_ads_targeting_inventory
    WHERE COALESCE(is_negative, FALSE) = FALSE
      AND campaign_id IS NOT NULL;
    GET DIAGNOSTICS n = ROW_COUNT;
    source_table := 'bronze_swarm_current_bids';
    rows_inserted := n;
    RETURN NEXT;

    TRUNCATE marketcloud_bronze.bronze_swarm_campaign_metrics;
    INSERT INTO marketcloud_bronze.bronze_swarm_campaign_metrics (
        data_date, campaign_id, campaign_name, campaign_status,
        cost, attributed_sales, purchases, roas, acos, ingested_at
    )
    SELECT
        date,
        CAST(campaign_id AS TEXT),
        MAX(campaign_name),
        MAX(campaign_status),
        SUM(cost),
        SUM(attributed_sales),
        SUM(purchases),
        CASE WHEN SUM(cost) > 0 THEN SUM(attributed_sales)/SUM(cost) ELSE 0 END,
        CASE WHEN SUM(attributed_sales) > 0 THEN SUM(cost)/SUM(attributed_sales) ELSE 0 END,
        NOW()
    FROM swarm_src.amazon_ads_campaigns_daily
    WHERE date IS NOT NULL
      AND campaign_id IS NOT NULL
      AND UPPER(COALESCE(campaign_status, 'ENABLED')) NOT IN ('ARCHIVED', 'PAUSED', 'DELETED')
    GROUP BY date, CAST(campaign_id AS TEXT);
    GET DIAGNOSTICS n = ROW_COUNT;
    source_table := 'bronze_swarm_campaign_metrics';
    rows_inserted := n;
    RETURN NEXT;
END;
$$;

DROP VIEW IF EXISTS marketcloud_gold.gold_review_queue_actionable_v2;
CREATE OR REPLACE VIEW marketcloud_gold.gold_review_queue_actionable_v2 AS
WITH q AS (
    SELECT p.*, LOWER(TRIM(COALESCE(p.customer_search_term,''))) AS term_norm
    FROM marketcloud_gold.gold_recommendation_priority_v2 p
),
enriched AS (
    SELECT q.*,
        status.campaign_status,
        status.ad_group_status,
        CASE
            WHEN UPPER(COALESCE(status.campaign_status,'')) IN ('ARCHIVED','PAUSED','DELETED') THEN 'CAMPAIGN_INACTIVE'
            WHEN UPPER(COALESCE(status.ad_group_status,'')) IN ('ARCHIVED','PAUSED','DELETED') THEN 'AD_GROUP_INACTIVE'
            ELSE 'ACTIVE_OR_UNKNOWN'
        END AS swarm_entity_status,
        CASE WHEN q.final_action_type IN ('ADD_NEGATIVE_EXACT','ADD_NEGATIVE_PHRASE') THEN
            EXISTS(SELECT 1 FROM marketcloud_bronze.bronze_swarm_negatives n
                WHERE n.campaign_id = q.campaign_id
                  AND n.state = 'ENABLED'
                  AND UPPER(COALESCE(n.campaign_status, 'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
                  AND UPPER(COALESCE(n.ad_group_status, 'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
                  AND (n.keyword_norm = q.term_norm
                       OR (n.match_type LIKE '%PHRASE%' AND q.term_norm LIKE '%' || n.keyword_norm || '%')))
        ELSE NULL END AS already_negative,
        (SELECT s.multiplier FROM marketcloud_bronze.bronze_swarm_bid_schedule s
            WHERE s.campaign_id = q.campaign_id
              AND q.event_hour >= s.hour_start
              AND q.event_hour < s.hour_end
              AND UPPER(COALESCE(s.campaign_status, 'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
              AND UPPER(COALESCE(s.ad_group_status, 'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
            ORDER BY s.multiplier ASC LIMIT 1) AS current_hour_multiplier,
        (SELECT ROUND(AVG(bid)::numeric,4) FROM marketcloud_bronze.bronze_swarm_current_bids b
            WHERE b.campaign_id = q.campaign_id
              AND b.bid > 0
              AND UPPER(COALESCE(b.campaign_status, 'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
              AND UPPER(COALESCE(b.ad_group_status, 'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')) AS campaign_avg_bid,
        (SELECT ROUND((CASE WHEN SUM(cost) > 0 THEN SUM(attributed_sales)/SUM(cost) ELSE 0 END)::numeric,2)
            FROM marketcloud_bronze.bronze_swarm_campaign_metrics m
            WHERE m.campaign_id = q.campaign_id
              AND UPPER(COALESCE(m.campaign_status, 'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
              AND m.data_date >= (SELECT MAX(data_date) - INTERVAL '34 days' FROM marketcloud_bronze.bronze_swarm_campaign_metrics)
        ) AS swarm_roas_35d
    FROM q
    LEFT JOIN LATERAL (
        SELECT s.campaign_status, s.ad_group_status
        FROM (
            SELECT campaign_id, ad_group_name, campaign_status, ad_group_status, state, ingested_at
            FROM marketcloud_bronze.bronze_swarm_current_bids
            UNION ALL
            SELECT campaign_id, ad_group_name, campaign_status, ad_group_status, state, ingested_at
            FROM marketcloud_bronze.bronze_swarm_negatives
            UNION ALL
            SELECT campaign_id, ad_group_name, campaign_status, ad_group_status, NULL::TEXT AS state, ingested_at
            FROM marketcloud_bronze.bronze_swarm_bid_schedule
        ) s
        WHERE s.campaign_id = q.campaign_id
          AND (
              COALESCE(q.ad_group_name,'') = ''
              OR COALESCE(s.ad_group_name,'') = ''
              OR LOWER(s.ad_group_name) = LOWER(q.ad_group_name)
          )
        ORDER BY
            CASE WHEN COALESCE(q.ad_group_name,'') <> '' AND LOWER(COALESCE(s.ad_group_name,'')) = LOWER(q.ad_group_name) THEN 0 ELSE 1 END,
            CASE WHEN UPPER(COALESCE(s.state,'')) = 'ENABLED' THEN 0 ELSE 1 END,
            s.ingested_at DESC NULLS LAST
        LIMIT 1
    ) status ON TRUE
)
SELECT
    e.tenant_id, e.amc_instance_id, e.ads_profile_id,
    e.recommendation_id, e.priority_rank, e.priority_bucket, e.priority_score,
    e.entity_type, e.entity_key,
    e.campaign_id, e.campaign_name, e.ad_product_type, e.ad_group_name, e.event_hour, e.customer_search_term,
    e.final_action_type, e.final_bid_multiplier, e.final_confidence_score, e.final_risk_level,
    e.agreement, e.action_conflict, e.recommendation_status,
    e.spend, e.clicks, e.orders, e.sales, e.roas, e.cpc, e.conversion_rate,
    e.campaign_status, e.ad_group_status, e.swarm_entity_status,
    e.already_negative,
    e.current_hour_multiplier,
    e.campaign_avg_bid,
    e.swarm_roas_35d,
    CASE
        WHEN e.already_negative IS TRUE THEN 'ALREADY_NEGATIVE'
        WHEN e.final_action_type IN ('CUT_HOUR','BID_DOWN','REDUCE_BID')
             AND e.current_hour_multiplier IS NOT NULL AND e.current_hour_multiplier < 1.0 THEN 'ALREADY_SCHEDULED'
        ELSE 'NEW'
    END AS swarm_state,
    CASE WHEN e.campaign_avg_bid IS NOT NULL AND e.final_bid_multiplier IS NOT NULL
         THEN ROUND((e.campaign_avg_bid * e.final_bid_multiplier)::numeric, 2) END AS target_bid,
    COALESCE(d.decision, 'NOT_DECIDED')          AS human_decision_status,
    COALESCE(d.execution_status, 'NOT_EXECUTED') AS execution_status,
    d.decided_by, d.decided_at,
    e.gold_evidence_json, e.prediction_evidence_json, e.features_snapshot,
    e.created_at
FROM enriched e
LEFT JOIN marketcloud_recommendations.recommendation_decisions d
    ON d.recommendation_id = e.recommendation_id
WHERE e.swarm_entity_status = 'ACTIVE_OR_UNKNOWN';

SELECT * FROM marketcloud_bronze.refresh_swarm_account_state();
