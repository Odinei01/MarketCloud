-- =====================================================================
-- Audit 360 outcome measurement: scope outcomes to the changed hour and do
-- not call tiny one-hour samples a model win/loss.
-- =====================================================================

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
            u.event_hour,
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
              AND h.event_hour = c.measured_hour
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
              AND h.event_hour = c.measured_hour
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
                WHEN m.baseline_hours = 0 THEN 'NEUTRAL'
                WHEN (m.baseline_orders + m.eval_orders) < 2
                  OR (m.baseline_spend + m.eval_spend) < 20 THEN 'NEUTRAL'
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

COMMENT ON FUNCTION marketcloud_recommendations.refresh_recommendation_hourly_outcomes IS
    'Recalcula outcomes 1h/3h/24h no escopo da hora alterada e evita win/loss conclusivo com amostra minima.';
