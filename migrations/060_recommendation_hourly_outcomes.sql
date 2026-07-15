-- =====================================================================
-- ZMC Learning Loop Hourly Outcomes V1
--
-- Fecha o ciclo operacional: recomendacao -> acao executada -> AMS medido
-- em 1h/3h/24h -> label de resultado para auditoria e aprendizado.
-- Nada aqui executa na Amazon; apenas mede o que ja foi aplicado e gravado.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_recommendations.recommendation_hourly_outcomes (
    hourly_outcome_id BIGSERIAL PRIMARY KEY,
    recommendation_id TEXT NOT NULL,
    decision_id BIGINT REFERENCES marketcloud_recommendations.recommendation_decisions(decision_id) ON DELETE CASCADE,

    tenant_id TEXT NOT NULL,
    amc_instance_id TEXT NOT NULL,
    ads_profile_id TEXT NOT NULL,

    entity_type TEXT,
    entity_key TEXT,
    campaign_id TEXT,
    campaign_name TEXT,
    ad_group_name TEXT,
    event_hour INTEGER,

    recommended_action TEXT,
    recommended_bid_multiplier NUMERIC(18,4),
    decided_action TEXT,
    decided_bid_multiplier NUMERIC(18,4),
    decision TEXT,
    execution_status TEXT,
    executed_at TIMESTAMPTZ,

    outcome_window TEXT NOT NULL, -- 1h | 3h | 24h
    action_start_at TIMESTAMPTZ NOT NULL,
    eval_window_end TIMESTAMPTZ NOT NULL,

    baseline_spend NUMERIC(18,4),
    baseline_orders NUMERIC(18,4),
    baseline_sales NUMERIC(18,4),
    baseline_roas NUMERIC(18,4),
    baseline_hours INTEGER,

    eval_spend NUMERIC(18,4),
    eval_orders NUMERIC(18,4),
    eval_sales NUMERIC(18,4),
    eval_roas NUMERIC(18,4),
    eval_hours INTEGER,

    delta_spend NUMERIC(18,4),
    delta_orders NUMERIC(18,4),
    delta_sales NUMERIC(18,4),
    delta_roas NUMERIC(18,4),

    outcome_label TEXT NOT NULL, -- IMPROVED | NEUTRAL | WORSENED | NO_DATA
    model_verdict TEXT NOT NULL, -- MODEL_RIGHT | MODEL_WRONG | INCONCLUSIVE
    measured_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_recommendation_hourly_outcome UNIQUE (recommendation_id, outcome_window, action_start_at)
);

CREATE INDEX IF NOT EXISTS idx_recommendation_hourly_outcomes_measured
    ON marketcloud_recommendations.recommendation_hourly_outcomes (measured_at DESC);
CREATE INDEX IF NOT EXISTS idx_recommendation_hourly_outcomes_campaign
    ON marketcloud_recommendations.recommendation_hourly_outcomes (campaign_id, event_hour, outcome_window);
CREATE INDEX IF NOT EXISTS idx_recommendation_hourly_outcomes_label
    ON marketcloud_recommendations.recommendation_hourly_outcomes (outcome_label, model_verdict);

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
          AND d.campaign_id IS NOT NULL
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
            campaign_id,
            ((data_date::timestamp + (event_hour * interval '1 hour')) AT TIME ZONE 'America/Sao_Paulo') AS hour_at,
            COALESCE(spend, 0)::numeric AS spend,
            COALESCE(orders_7d, orders_1d, orders_14d, 0)::numeric AS orders,
            COALESCE(sales_7d, sales_1d, sales_14d, 0)::numeric AS sales
        FROM marketcloud_bronze.bronze_ams_hourly
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
            WHERE h.campaign_id = c.campaign_id
              AND h.hour_at >= c.action_start_at - c.duration
              AND h.hour_at < c.action_start_at
        ) b ON TRUE
        LEFT JOIN LATERAL (
            SELECT SUM(h.spend) AS spend, SUM(h.orders) AS orders, SUM(h.sales) AS sales, COUNT(*) AS hours
            FROM hourly h
            WHERE h.campaign_id = c.campaign_id
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

CREATE OR REPLACE VIEW marketcloud_recommendations.v_learning_loop_hourly_v1 AS
SELECT
    o.hourly_outcome_id,
    o.recommendation_id,
    o.campaign_id,
    o.campaign_name,
    o.ad_group_name,
    o.event_hour,
    o.recommended_action,
    o.recommended_bid_multiplier,
    o.decided_action,
    o.decided_bid_multiplier,
    o.executed_at,
    o.outcome_window,
    o.action_start_at,
    o.eval_window_end,
    o.baseline_roas,
    o.eval_roas,
    o.delta_roas,
    o.baseline_spend,
    o.eval_spend,
    o.delta_spend,
    o.baseline_orders,
    o.eval_orders,
    o.delta_orders,
    o.outcome_label,
    o.model_verdict,
    o.measured_at
FROM marketcloud_recommendations.recommendation_hourly_outcomes o;

-- Popular imediatamente para decisoes EXECUTED ja existentes.
SELECT marketcloud_recommendations.refresh_recommendation_hourly_outcomes();
