-- 153_dayparting_metrics_campaign_and_snapshot.sql
-- (a) Medicao por CAMPANHA (alem do global) + (b) SNAPSHOT semanal (historico de
--     aprendizado congelado — a atribuicao muda ao longo do tempo, entao congelamos).

-- (a) Metricas diarias por CAMPANHA.
CREATE OR REPLACE VIEW marketcloud_gold.v_dayparting_metrics_campaign_daily_v1 AS
SELECT data_date AS date, campaign_name,
  round(sum(spend),2) spend, round(sum(sales_7d),2) ad_sales,
  sum(clicks)::int clicks, sum(orders_7d)::int orders,
  round(sum(sales_7d)/NULLIF(sum(spend),0),2)       AS roas,
  round(100*sum(spend)/NULLIF(sum(sales_7d),0),1)   AS acos,
  round(sum(spend)/NULLIF(sum(clicks),0),2)         AS cpc,
  round(100*sum(orders_7d)/NULLIF(sum(clicks),0),1) AS cvr
FROM marketcloud_bronze.bronze_amazon_ads_hourly
GROUP BY 1,2 HAVING sum(spend)>0;

-- (b) Snapshot semanal (congela metricas p/ o historico de aprendizado).
CREATE TABLE IF NOT EXISTS marketcloud_gold.gold_dayparting_metrics_snapshot (
    snapshot_at   timestamptz NOT NULL DEFAULT now(),
    iso_week      text        NOT NULL,          -- IYYY-IW
    grain         text        NOT NULL,          -- DAILY | HOURLY
    level         text        NOT NULL,          -- GLOBAL | CAMPAIGN
    campaign_name text,
    metric_date   date,
    event_hour    smallint,
    spend numeric, ad_sales numeric, total_sales numeric,
    clicks int, orders int,
    roas numeric, acos numeric, tacos numeric, cpc numeric, cvr numeric
);
CREATE INDEX IF NOT EXISTS idx_dp_metrics_snapshot ON marketcloud_gold.gold_dayparting_metrics_snapshot (iso_week, level, grain);

-- snapshot_dayparting_metrics: congela a semana atual (idempotente por semana).
CREATE OR REPLACE FUNCTION marketcloud_gold.snapshot_dayparting_metrics() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_week text := to_char(CURRENT_DATE,'IYYY-IW'); v_n int;
BEGIN
  DELETE FROM marketcloud_gold.gold_dayparting_metrics_snapshot WHERE iso_week=v_week;

  -- GLOBAL diario (com TACOS)
  INSERT INTO marketcloud_gold.gold_dayparting_metrics_snapshot
    (iso_week,grain,level,metric_date,spend,ad_sales,total_sales,clicks,orders,roas,acos,tacos,cpc,cvr)
  SELECT v_week,'DAILY','GLOBAL',date,spend,ad_sales,total_sales,clicks,orders,roas,acos,tacos,cpc,cvr
  FROM marketcloud_gold.v_dayparting_metrics_daily_v1 WHERE date > CURRENT_DATE - 14;

  -- GLOBAL hora-a-hora (baseline fino)
  INSERT INTO marketcloud_gold.gold_dayparting_metrics_snapshot
    (iso_week,grain,level,metric_date,event_hour,spend,ad_sales,clicks,orders,roas,cpc,cvr)
  SELECT v_week,'HOURLY','GLOBAL',date,hora,spend,ad_sales,clicks,orders,roas,cpc,cvr
  FROM marketcloud_gold.v_dayparting_metrics_hourly_v1 WHERE date > CURRENT_DATE - 14;

  -- CAMPANHA diario
  INSERT INTO marketcloud_gold.gold_dayparting_metrics_snapshot
    (iso_week,grain,level,campaign_name,metric_date,spend,ad_sales,clicks,orders,roas,acos,cpc,cvr)
  SELECT v_week,'DAILY','CAMPAIGN',campaign_name,date,spend,ad_sales,clicks,orders,roas,acos,cpc,cvr
  FROM marketcloud_gold.v_dayparting_metrics_campaign_daily_v1 WHERE date > CURRENT_DATE - 14;

  SELECT count(*) INTO v_n FROM marketcloud_gold.gold_dayparting_metrics_snapshot WHERE iso_week=v_week;
  RETURN v_n;
END;$$;
