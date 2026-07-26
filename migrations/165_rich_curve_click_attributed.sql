-- 165_rich_curve_click_attributed.sql
-- FIX: o heatmap rico (v_daypart_curve_campaign_rich / _global_rich, migration 160)
-- somava sales_7d DIRETO, incluindo venda orfa (R$551 em linhas com 0 clique/0 gasto,
-- conversao carimbada na hora errada) -> ROAS inflado ~5%. Aplica a MESMA correcao de
-- venda-com-clique ja padronizada no greening/keyword/calibracao: sales = FILTER(clicks>0).
-- Colunas de saida inalteradas -> CREATE OR REPLACE nao mexe nos dependentes.

CREATE OR REPLACE VIEW marketcloud_gold.v_daypart_curve_campaign_rich AS
SELECT
  campaign_name,
  event_hour,
  sum(clicks)::int                                   AS clicks,
  round(sum(spend)::numeric,2)                       AS spend,
  round(COALESCE(sum(sales_7d) FILTER (WHERE clicks>0),0)::numeric,2)  AS sales,
  round(COALESCE(sum(orders_7d) FILTER (WHERE clicks>0),0)::numeric,1) AS orders,
  CASE WHEN sum(spend)>0 THEN round((COALESCE(sum(sales_7d) FILTER (WHERE clicks>0),0)/sum(spend))::numeric,2) ELSE 0 END AS roas,
  count(DISTINCT to_char(data_date,'IYYY-IW')) FILTER (WHERE clicks>0) AS weeks_active
FROM marketcloud_bronze.bronze_amazon_ads_hourly
WHERE data_date <= CURRENT_DATE - 7
GROUP BY 1,2;

CREATE OR REPLACE VIEW marketcloud_gold.v_daypart_curve_global_rich AS
WITH g AS (
  SELECT event_hour,
    sum(clicks)::int AS clicks,
    round(sum(spend)::numeric,2) AS spend,
    round(COALESCE(sum(sales_7d) FILTER (WHERE clicks>0),0)::numeric,2) AS sales,
    round(COALESCE(sum(orders_7d) FILTER (WHERE clicks>0),0)::numeric,1) AS orders,
    CASE WHEN sum(spend)>0 THEN round((COALESCE(sum(sales_7d) FILTER (WHERE clicks>0),0)/sum(spend))::numeric,2) ELSE 0 END AS roas
  FROM marketcloud_bronze.bronze_amazon_ads_hourly
  WHERE data_date <= CURRENT_DATE - 7
  GROUP BY 1
)
SELECT event_hour, clicks, spend, sales, orders, roas,
  CASE
    WHEN clicks < 15 THEN NULL
    WHEN roas >= 6 THEN 100
    WHEN roas >= 3 THEN 100
    WHEN roas >= 2 THEN 80
    WHEN roas >= 1 THEN 50
    ELSE 30
  END AS suggested_global_mult,
  CASE
    WHEN clicks < 15 THEN 'amostra fraca ('||clicks||' cl): herdar, nao mexer'
    WHEN roas >= 3 THEN 'hora lucrativa (ROAS '||roas||', '||clicks||' cl): manter cheio'
    WHEN roas >= 1 THEN 'marginal (ROAS '||roas||', '||clicks||' cl): trim'
    ELSE 'fraca (ROAS '||roas||', '||clicks||' cl): cortar'
  END AS reason
FROM g;
