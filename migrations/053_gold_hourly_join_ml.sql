-- =====================================================================
-- Liga o ML V2 (dado real) na camada de recomendacao horaria: Gold x ML.
-- Acrescenta P(pedido), ROAS esperado, "ML concorda?" e diagnostico de
-- regras sobrepostas do Robo.
-- =====================================================================

DROP VIEW IF EXISTS marketcloud_gold.gold_keyword_hourly_recommendations_v1;
DROP VIEW IF EXISTS marketcloud_gold.gold_hourly_recommendations_v1;

CREATE VIEW marketcloud_gold.gold_hourly_recommendations_v1 AS
WITH scored AS (
    SELECT p.*,
        CASE
            WHEN p.orders >= 3 AND p.clicks >= 20 THEN 'HIGH'
            WHEN p.orders >= 1 AND p.spend    >= 5 THEN 'MEDIUM'
            ELSE 'LOW'
        END AS confidence,
        CASE
            WHEN p.roas >= 4.0 AND p.orders >= 1 AND p.spend >= 2
                 AND p.has_schedule AND p.mult_min < 1.0
                THEN 'BID_UP'
            WHEN p.spend >= 8 AND (p.orders = 0 OR p.roas < 1.0)
                 AND p.has_schedule AND p.mult_max >= 1.0
                THEN 'CUT_HOUR'
            WHEN p.spend >= 5 AND p.roas < 2.0 AND p.roas >= 1.0
                 AND p.has_schedule AND p.mult_max >= 1.0
                THEN 'BID_DOWN'
            WHEN p.roas >= 4.0 AND p.orders >= 1 AND p.has_schedule AND p.mult_min >= 1.0
                THEN 'KEEP_STRONG'
            ELSE 'WATCH'
        END AS action_type
    FROM marketcloud_gold.gold_hourly_perf_v1 p
),
recommendations AS (
    SELECT
        md5(s.campaign_norm || '|' || s.event_hour || '|' || s.action_type) AS recommendation_id,
        s.campaign_norm, s.campaign_name, s.event_hour, s.action_type, s.confidence,
        s.spend, s.orders, s.sales, s.roas, s.cvr, s.clicks, s.impressions, s.days_observed,
        s.mult_min AS current_multiplier, s.mult_max, s.has_schedule,
        CASE s.action_type
            WHEN 'BID_UP'   THEN LEAST(1.0, ROUND((s.mult_min + 0.3)::numeric, 2))
            WHEN 'CUT_HOUR' THEN 0.3
            WHEN 'BID_DOWN' THEN GREATEST(0.5, ROUND((s.mult_max - 0.3)::numeric, 2))
            ELSE s.mult_min
        END AS suggested_multiplier,
        ROUND((
            CASE s.action_type
                WHEN 'BID_UP'   THEN s.sales * LEAST(s.roas, 20) / 10.0
                WHEN 'CUT_HOUR' THEN s.spend * 2.0
                WHEN 'BID_DOWN' THEN s.spend * 1.0
                ELSE 0
            END
            * CASE s.confidence WHEN 'HIGH' THEN 1.0 WHEN 'MEDIUM' THEN 0.6 ELSE 0.3 END
        )::numeric, 2) AS priority_score,
        'REAL_HOURLY_OBSERVATIONAL'::text AS label_caveat,
        s.min_d AS window_from, s.max_d AS window_to,
        NOW() AS computed_at
    FROM scored s
    WHERE s.action_type IN ('BID_UP','CUT_HOUR','BID_DOWN','KEEP_STRONG')
),
sched_overlap AS (
    SELECT
        r.recommendation_id,
        COUNT(s.*)::int AS overlap_rule_count,
        COUNT(*) FILTER (
            WHERE
                (r.action_type = 'BID_UP' AND s.multiplier < r.suggested_multiplier)
                OR (r.action_type IN ('CUT_HOUR','BID_DOWN') AND s.multiplier > r.suggested_multiplier)
        )::int AS rules_still_need_change,
        COUNT(*) FILTER (
            WHERE
                (r.action_type = 'BID_UP' AND s.multiplier >= r.suggested_multiplier)
                OR (r.action_type IN ('CUT_HOUR','BID_DOWN') AND s.multiplier <= r.suggested_multiplier)
                OR r.action_type = 'KEEP_STRONG'
        )::int AS rules_already_aligned,
        MIN(s.multiplier) AS overlap_mult_min,
        MAX(s.multiplier) AS overlap_mult_max,
        STRING_AGG(
            DISTINCT COALESCE(NULLIF(s.label, ''), ROUND(s.multiplier::numeric, 2)::text),
            ', ' ORDER BY COALESCE(NULLIF(s.label, ''), ROUND(s.multiplier::numeric, 2)::text)
        ) AS overlap_labels,
        COALESCE(JSONB_AGG(JSONB_BUILD_OBJECT(
            'profile_id', s.profile_id_ref,
            'campaign_name', s.campaign_name,
            'ad_group_id', s.ad_group_id,
            'ad_group_name', s.ad_group_name,
            'entity_type', s.entity_type,
            'hour_start', s.hour_start,
            'hour_end', s.hour_end,
            'multiplier', s.multiplier,
            'label', s.label,
            'status', CASE
                WHEN (r.action_type = 'BID_UP' AND s.multiplier < r.suggested_multiplier)
                  OR (r.action_type IN ('CUT_HOUR','BID_DOWN') AND s.multiplier > r.suggested_multiplier)
                    THEN 'PENDING'
                ELSE 'ALIGNED'
            END
        ) ORDER BY
            CASE
                WHEN (r.action_type = 'BID_UP' AND s.multiplier < r.suggested_multiplier)
                  OR (r.action_type IN ('CUT_HOUR','BID_DOWN') AND s.multiplier > r.suggested_multiplier)
                    THEN 0
                ELSE 1
            END,
            s.multiplier, s.hour_start, s.hour_end) FILTER (WHERE s.profile_id_ref IS NOT NULL), '[]'::jsonb) AS overlap_rule_details
    FROM recommendations r
    LEFT JOIN marketcloud_bronze.bronze_swarm_bid_schedule s
      ON LOWER(TRIM(s.campaign_name)) = r.campaign_norm
     AND s.hour_start <= r.event_hour
     AND s.hour_end > r.event_hour
     AND UPPER(COALESCE(s.campaign_status,'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
     AND UPPER(COALESCE(s.ad_group_status,'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
     AND COALESCE(s.profile_is_active, TRUE) = TRUE
     AND UPPER(COALESCE(s.profile_status, 'ACTIVE')) NOT IN ('ARCHIVED', 'PAUSED', 'DELETED')
    GROUP BY r.recommendation_id
)
SELECT
    r.recommendation_id,
    r.campaign_name, r.event_hour, r.action_type, r.confidence,
    r.spend, r.orders, r.sales, r.roas, r.cvr, r.clicks, r.impressions, r.days_observed,
    r.current_multiplier, r.mult_max, r.has_schedule,
    r.suggested_multiplier,
    COALESCE(so.overlap_rule_count, 0) AS overlap_rule_count,
    COALESCE(so.rules_still_need_change, 0) AS rules_still_need_change,
    COALESCE(so.rules_already_aligned, 0) AS rules_already_aligned,
    so.overlap_mult_min,
    so.overlap_mult_max,
    so.overlap_labels,
    so.overlap_rule_details,
    CASE
        WHEN COALESCE(so.overlap_rule_count, 0) <= 1 THEN 'SINGLE_RULE'
        WHEN COALESCE(so.rules_still_need_change, 0) > 0
         AND COALESCE(so.rules_already_aligned, 0) > 0 THEN 'PARTIALLY_CORRECTED'
        WHEN COALESCE(so.rules_still_need_change, 0) > 0 THEN 'NEEDS_CHANGE'
        WHEN COALESCE(so.overlap_rule_count, 0) > 1 THEN 'OVERLAPPED_ALIGNED'
        ELSE 'SINGLE_RULE'
    END AS schedule_overlap_status,
    r.priority_score,
    r.label_caveat,
    r.window_from, r.window_to,
    r.computed_at,
    ml.conversion_probability AS ml_conversion_probability,
    ml.expected_roas          AS ml_expected_roas,
    ml.predicted_good_hour    AS ml_good_hour,
    CASE
        WHEN ml.predicted_good_hour IS NULL THEN NULL
        WHEN r.action_type IN ('BID_UP','KEEP_STRONG') THEN ml.predicted_good_hour
        WHEN r.action_type IN ('CUT_HOUR','BID_DOWN')  THEN (NOT ml.predicted_good_hour)
        ELSE NULL
    END AS ml_agrees
FROM recommendations r
LEFT JOIN sched_overlap so ON so.recommendation_id = r.recommendation_id
LEFT JOIN marketcloud_gold.hourly_ml_predictions_v2 ml
    ON LOWER(TRIM(ml.campaign_name)) = r.campaign_norm AND ml.event_hour = r.event_hour;

