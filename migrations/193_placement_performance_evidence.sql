-- 193 — Fase B (consumo): expoe amazon_ads_placement_daily via FDW + view de evidencia
-- de ROAS por placement (28d). NAO e feature do V3: o V3 e agregado por hora/target
-- sobre todas as datas (sem as_of_date), entao performance por placement VAZARIA o
-- rotulo (mesma classe do ba_query_ads_* removido). Esta camada e base do V4
-- point-in-time e serve de evidencia na tela ja agora.

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_ads_placement_daily (
  date date, campaign_id text, campaign_name text, placement text, placement_raw text,
  impressions bigint, clicks bigint, cost numeric, attributed_sales numeric, purchases bigint,
  report_id text, synced_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_ads_placement_daily');

CREATE OR REPLACE VIEW marketcloud_gold.gold_campaign_placement_performance_v1 AS
SELECT campaign_id, campaign_name, placement,
  SUM(impressions) impressions, SUM(clicks) clicks, ROUND(SUM(cost),2) cost,
  ROUND(SUM(attributed_sales),2) sales, SUM(purchases) orders,
  ROUND(SUM(attributed_sales)/NULLIF(SUM(cost),0),2) roas
FROM swarm_src.amazon_ads_placement_daily
WHERE date >= current_date - 28
GROUP BY campaign_id, campaign_name, placement;
