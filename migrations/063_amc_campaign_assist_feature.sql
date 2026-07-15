-- Passo 2/3: leva o sinal AMC de assist (Q005) pro bronze e o junta como
-- feature de contexto (lenta) na camada horaria que o ML consome.
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_campaign_assist (
    campaign_id        TEXT,
    campaign_name      TEXT,
    product_group      TEXT,
    spend              NUMERIC,
    direct_orders      NUMERIC,
    direct_sales       NUMERIC,
    direct_roas        NUMERIC,
    assisted_orders    NUMERIC,
    assisted_sales     NUMERIC,
    assisted_roas      NUMERIC,
    assist_rate        NUMERIC,
    first_touch_rate   NUMERIC,
    middle_touch_rate  NUMERIC,
    last_touch_rate    NUMERIC,
    decision           TEXT,
    updated_at         TIMESTAMPTZ DEFAULT NOW()
);

-- Feature view: gold horario + sinal AMC de assist por campanha (join por nome).
-- Nao altera gold_hourly_signal_unified (nova view, aditiva).
CREATE OR REPLACE VIEW marketcloud_gold.gold_hourly_signal_amc AS
SELECT g.*,
       COALESCE(a.assist_rate, 0)      AS amc_assist_rate,
       COALESCE(a.first_touch_rate, 0) AS amc_first_touch_rate,
       a.assisted_roas                 AS amc_assisted_roas,
       (a.decision = 'PROTECT')        AS amc_protect
FROM marketcloud_gold.gold_hourly_signal_unified g
LEFT JOIN marketcloud_bronze.bronze_amc_campaign_assist a
       ON LOWER(TRIM(a.campaign_name)) = LOWER(TRIM(g.campaign_name));
