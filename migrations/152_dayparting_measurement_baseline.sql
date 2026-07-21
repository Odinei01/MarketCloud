-- 152_dayparting_measurement_baseline.sql
-- Medicao para o historico de aprendizado do dayparting.
-- Metricas: ROAS (ad_sales/spend), ACOS (spend/ad_sales), TACOS (spend/venda TOTAL),
-- CPC (spend/clicks), CVR (orders/clicks). Fonte ads = bronze_amazon_ads_hourly
-- (campanha x hora, cobertura completa de gasto); venda total = swarm_src.amazon_sales_daily.

-- (1) Metricas DIARIAS (nivel global) — a serie do grafico.
CREATE OR REPLACE VIEW marketcloud_gold.v_dayparting_metrics_daily_v1 AS
WITH ad AS (
  SELECT data_date AS d, sum(spend) spend, sum(sales_7d) ad_sales,
         sum(clicks) clicks, sum(orders_7d) orders
  FROM marketcloud_bronze.bronze_amazon_ads_hourly GROUP BY 1
),
tot AS (SELECT date AS d, ordered_product_sales_amount AS total_sales FROM swarm_src.amazon_sales_daily)
SELECT a.d AS date,
  round(a.spend,2) AS spend, round(a.ad_sales,2) AS ad_sales,
  a.clicks::int AS clicks, a.orders::int AS orders,
  round(COALESCE(t.total_sales,0),2) AS total_sales,
  round(a.ad_sales/NULLIF(a.spend,0),2)              AS roas,
  round(100*a.spend/NULLIF(a.ad_sales,0),1)          AS acos,
  round(100*a.spend/NULLIF(t.total_sales,0),1)       AS tacos,
  round(a.spend/NULLIF(a.clicks,0),2)                AS cpc,
  round(100*a.orders/NULLIF(a.clicks,0),1)           AS cvr
FROM ad a LEFT JOIN tot t ON t.d=a.d
WHERE a.spend > 0
ORDER BY a.d;

-- (2) DoD / WoW / MoM — cada dia comparado com D-1, D-7, D-30 (mesmo dia ~mes atras).
CREATE OR REPLACE VIEW marketcloud_gold.v_dayparting_metrics_deltas_v1 AS
SELECT m.date,
  m.roas, m.tacos, m.cvr, m.cpc, m.acos, m.spend, m.total_sales,
  d1.roas  AS roas_dod, d7.roas  AS roas_wow, d30.roas  AS roas_mom,
  d1.tacos AS tacos_dod, d7.tacos AS tacos_wow, d30.tacos AS tacos_mom,
  d1.cvr   AS cvr_dod, d7.cvr   AS cvr_wow, d30.cvr   AS cvr_mom,
  d1.cpc   AS cpc_dod, d7.cpc   AS cpc_wow, d30.cpc   AS cpc_mom
FROM marketcloud_gold.v_dayparting_metrics_daily_v1 m
LEFT JOIN marketcloud_gold.v_dayparting_metrics_daily_v1 d1  ON d1.date  = m.date - 1
LEFT JOIN marketcloud_gold.v_dayparting_metrics_daily_v1 d7  ON d7.date  = m.date - 7
LEFT JOIN marketcloud_gold.v_dayparting_metrics_daily_v1 d30 ON d30.date = m.date - 30
ORDER BY m.date;

-- (3) Baseline HORA-A-HORA (dia x hora) — o historico fino de aprendizado.
CREATE OR REPLACE VIEW marketcloud_gold.v_dayparting_metrics_hourly_v1 AS
SELECT data_date AS date, event_hour AS hora,
  round(sum(spend),2) spend, round(sum(sales_7d),2) ad_sales,
  sum(clicks)::int clicks, sum(orders_7d)::int orders,
  round(sum(sales_7d)/NULLIF(sum(spend),0),2)   AS roas,
  round(sum(spend)/NULLIF(sum(clicks),0),2)     AS cpc,
  round(100*sum(orders_7d)/NULLIF(sum(clicks),0),1) AS cvr
FROM marketcloud_bronze.bronze_amazon_ads_hourly
GROUP BY 1,2 HAVING sum(spend)>0;
