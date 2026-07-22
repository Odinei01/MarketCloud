-- 160_daypart_curve_rich_foundation.sql
-- FUNDACAO CORRETA do dayparting: curva campanha x hora e global x hora a partir da
-- fonte RICA bronze_amazon_ads_hourly (desde 31/05, ~3257 cliques, cobre tambem as
-- expressoes auto tipo close-match). Substitui a base esparsa bronze_ams_hourly_target
-- (desde 19/06, ~492 cliques) que induziu o corte da madrugada ERRADO.
-- Somente leitura. Este e o backbone; keyword vira desvio encolhido sobre ele.
--
-- Metricas ja vem calculadas na fonte (orders_7d, sales_7d, roas). Janela madura
-- = ate CURRENT_DATE-7 (atribuicao 7d fechada). Curva "full" = toda a historia.

DROP VIEW IF EXISTS marketcloud_gold.v_daypart_curve_global_rich;
DROP VIEW IF EXISTS marketcloud_gold.v_daypart_curve_campaign_rich;

CREATE VIEW marketcloud_gold.v_daypart_curve_campaign_rich AS
SELECT
  campaign_name,
  event_hour,
  sum(clicks)::int                                   AS clicks,
  round(sum(spend)::numeric,2)                       AS spend,
  round(sum(sales_7d)::numeric,2)                    AS sales,
  round(sum(orders_7d)::numeric,1)                   AS orders,
  CASE WHEN sum(spend)>0 THEN round((sum(sales_7d)/sum(spend))::numeric,2) ELSE 0 END AS roas,
  count(DISTINCT to_char(data_date,'IYYY-IW')) FILTER (WHERE clicks>0) AS weeks_active
FROM marketcloud_bronze.bronze_amazon_ads_hourly
WHERE data_date <= CURRENT_DATE - 7           -- janela madura (atribuicao fechada)
GROUP BY 1,2;

CREATE VIEW marketcloud_gold.v_daypart_curve_global_rich AS
WITH g AS (
  SELECT event_hour,
    sum(clicks)::int AS clicks,
    round(sum(spend)::numeric,2) AS spend,
    round(sum(sales_7d)::numeric,2) AS sales,
    round(sum(orders_7d)::numeric,1) AS orders,
    CASE WHEN sum(spend)>0 THEN round((sum(sales_7d)/sum(spend))::numeric,2) ELSE 0 END AS roas
  FROM marketcloud_bronze.bronze_amazon_ads_hourly
  WHERE data_date <= CURRENT_DATE - 7
  GROUP BY 1
)
SELECT event_hour, clicks, spend, sales, orders, roas,
  -- sugestao de multiplicador GLOBAL (deterministico), so onde ha amostra (>=15 cliques):
  --   >= 45 cliques decide; entre 15-45 sonda leve; < 15 nao mexe (NULL = herda).
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
