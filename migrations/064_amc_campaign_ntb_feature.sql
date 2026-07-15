-- #3: sinal AMC de new-to-brand (Q019) -> feature de contexto do ML.
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_campaign_ntb (
    campaign_id         TEXT,
    campaign_name       TEXT,
    product_group       TEXT,
    new_to_brand_orders NUMERIC,
    returning_orders    NUMERIC,
    new_to_brand_sales  NUMERIC,
    returning_sales     NUMERIC,
    new_customer_rate   NUMERIC,
    decision            TEXT,
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Estende a feature view: + new_customer_rate/amc_acquisition (join por nome).
CREATE OR REPLACE VIEW marketcloud_gold.gold_hourly_signal_amc AS
SELECT g.*,
       COALESCE(a.assist_rate, 0)      AS amc_assist_rate,
       COALESCE(a.first_touch_rate, 0) AS amc_first_touch_rate,
       a.assisted_roas                 AS amc_assisted_roas,
       (a.decision = 'PROTECT')        AS amc_protect,
       COALESCE(n.new_customer_rate, 0) AS amc_new_customer_rate,
       (n.decision = 'ACQUISITION')     AS amc_acquisition
FROM marketcloud_gold.gold_hourly_signal_unified g
LEFT JOIN marketcloud_bronze.bronze_amc_campaign_assist a
       ON LOWER(TRIM(a.campaign_name)) = LOWER(TRIM(g.campaign_name))
LEFT JOIN marketcloud_bronze.bronze_amc_campaign_ntb n
       ON LOWER(TRIM(n.campaign_name)) = LOWER(TRIM(g.campaign_name));
