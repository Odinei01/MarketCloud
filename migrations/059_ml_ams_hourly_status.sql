-- =====================================================================
-- ML + AMS hourly status — historico operacional para tela de status.
--
-- Registra cada ciclo horario dos workers de ML e permite cruzar com o que
-- chegou do Amazon Marketing Stream por data/hora.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_gold.ml_hourly_run_status (
    id                  BIGSERIAL PRIMARY KEY,
    run_kind            TEXT NOT NULL,
    model_version       TEXT NOT NULL,
    grain               TEXT NOT NULL,
    status              TEXT NOT NULL,
    training_rows       INTEGER NOT NULL DEFAULT 0,
    positive_click_rows INTEGER,
    positive_order_rows INTEGER,
    predictions_written INTEGER NOT NULL DEFAULT 0,
    metrics_json        JSONB,
    started_at          TIMESTAMPTZ,
    finished_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_ml_hourly_run_status CHECK (status IN ('COMPLETED','PARTIAL','INSUFFICIENT_DATA','FAILED'))
);

CREATE INDEX IF NOT EXISTS idx_ml_hourly_run_status_finished
    ON marketcloud_gold.ml_hourly_run_status (finished_at DESC);

CREATE INDEX IF NOT EXISTS idx_ml_hourly_run_status_kind
    ON marketcloud_gold.ml_hourly_run_status (run_kind, finished_at DESC);

COMMENT ON TABLE marketcloud_gold.ml_hourly_run_status IS
'Historico de execucoes dos workers ML horarios, usado pela tela de status AMS/ML.';

CREATE OR REPLACE VIEW marketcloud_gold.v_ams_hourly_status_v1 AS
WITH campaign_hour AS (
    SELECT
        data_date,
        event_hour,
        COUNT(*)::int AS campaign_rows,
        SUM(COALESCE(impressions,0))::numeric(18,4) AS campaign_impressions,
        SUM(COALESCE(clicks,0))::numeric(18,4) AS campaign_clicks,
        SUM(COALESCE(spend,0))::numeric(18,4) AS campaign_spend,
        SUM(GREATEST(COALESCE(orders_14d,0), COALESCE(orders_7d,0), COALESCE(orders_1d,0)))::numeric(18,4) AS campaign_orders,
        SUM(GREATEST(COALESCE(sales_14d,0), COALESCE(sales_7d,0), COALESCE(sales_1d,0)))::numeric(18,4) AS campaign_sales,
        MAX(updated_at) AS campaign_last_update
    FROM marketcloud_bronze.bronze_ams_hourly
    GROUP BY data_date, event_hour
),
target_hour AS (
    SELECT
        data_date,
        event_hour,
        COUNT(*)::int AS target_rows,
        COUNT(DISTINCT target_entity_key)::int AS target_entities,
        SUM(COALESCE(impressions,0))::numeric(18,4) AS target_impressions,
        SUM(COALESCE(clicks,0))::numeric(18,4) AS target_clicks,
        SUM(COALESCE(spend,0))::numeric(18,4) AS target_spend,
        SUM(GREATEST(COALESCE(orders_14d,0), COALESCE(orders_7d,0), COALESCE(orders_1d,0)))::numeric(18,4) AS target_orders,
        SUM(GREATEST(COALESCE(sales_14d,0), COALESCE(sales_7d,0), COALESCE(sales_1d,0)))::numeric(18,4) AS target_sales,
        MAX(updated_at) AS target_last_update
    FROM marketcloud_bronze.bronze_ams_hourly_target
    GROUP BY data_date, event_hour
)
SELECT
    COALESCE(c.data_date, t.data_date) AS data_date,
    COALESCE(c.event_hour, t.event_hour) AS event_hour,
    COALESCE(c.campaign_rows, 0) AS campaign_rows,
    COALESCE(t.target_rows, 0) AS target_rows,
    COALESCE(t.target_entities, 0) AS target_entities,
    COALESCE(c.campaign_impressions, 0) AS campaign_impressions,
    COALESCE(c.campaign_clicks, 0) AS campaign_clicks,
    COALESCE(c.campaign_spend, 0) AS campaign_spend,
    COALESCE(c.campaign_orders, 0) AS campaign_orders,
    COALESCE(c.campaign_sales, 0) AS campaign_sales,
    COALESCE(t.target_impressions, 0) AS target_impressions,
    COALESCE(t.target_clicks, 0) AS target_clicks,
    COALESCE(t.target_spend, 0) AS target_spend,
    COALESCE(t.target_orders, 0) AS target_orders,
    COALESCE(t.target_sales, 0) AS target_sales,
    GREATEST(c.campaign_last_update, t.target_last_update) AS last_update
FROM campaign_hour c
FULL OUTER JOIN target_hour t
  ON t.data_date = c.data_date AND t.event_hour = c.event_hour;

COMMENT ON VIEW marketcloud_gold.v_ams_hourly_status_v1 IS
'Resumo hora a hora do que chegou do Amazon Marketing Stream nos graos campanha e keyword/target.';
