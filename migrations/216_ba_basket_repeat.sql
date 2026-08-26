-- 216: expõe Market Basket (E004) e Repeat Purchase (E005) ao MarketCloud e cria a
-- camada Silver dos dois.
--
-- Contexto: os dois relatórios ficaram semanas com ZERO linhas por serem pedidos para
-- um período impossível (mês anterior à elegibilidade de marca). Corrigido no
-- mercado-data-app; agora entram dados de verdade e o FDW precisa enxergá-los — sem
-- estas foreign tables o MarketCloud não vê nada, por mais dado que a origem tenha.
--
-- DECISÃO DE MODELAGEM QUE IMPORTA: a Silver carrega weeks_observed e signal_strength.
--
-- No grão semanal esse dado é ruído até maturar. Evidência medida em 26/08 sobre as
-- semanas 09-15 e 16-22/08: de 32 pares de co-compra, 31 apareceram em UMA única
-- semana e apenas 1 nas duas. combination_pct = 1,0 ali significa uma cesta só, não
-- afinidade. Sem expor a contagem de semanas, um "100% comprados juntos" viraria
-- decisão de bundle baseada em um pedido.
--
-- Mesma razão no Repeat Purchase: em janela de 7 dias o mesmo cliente não volta, então
-- repeat_customers = 0 é ARTEFATO DA JANELA, não comportamento do cliente. A view
-- marca isso explicitamente em vez de deixar o zero passar por resultado.

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_brand_analytics_market_basket (
  report_id text,
  data_domain text,
  period text,
  period_start date,
  period_end date,
  marketplace_id text,
  zanom_asin text,
  purchased_with_asin text,
  purchased_with_name text,
  purchased_with_rank integer,
  combination_pct numeric,
  raw_json_sanitized jsonb,
  synced_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_brand_analytics_market_basket');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_brand_analytics_repeat_purchase (
  report_id text,
  data_domain text,
  period text,
  period_start date,
  period_end date,
  marketplace_id text,
  asin text,
  orders numeric,
  unique_customers numeric,
  repeat_customers numeric,
  repeat_purchase_rate numeric,
  repeat_purchase_revenue numeric,
  raw_json_sanitized jsonb,
  synced_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_brand_analytics_repeat_purchase');

-- SILVER Market Basket (spec §28). Grão: período × ASIN ZANOM × ASIN parceiro.
CREATE OR REPLACE VIEW marketcloud_silver.silver_ba_market_basket_v1 AS
SELECT
  b.marketplace_id,
  b.period,
  b.period_start,
  b.period_end,
  b.zanom_asin,
  b.purchased_with_asin,
  b.purchased_with_name,
  b.purchased_with_rank,
  b.combination_pct,
  -- em quantos períodos ESTE par já apareceu: é o que separa afinidade de coincidência
  COUNT(*) OVER (PARTITION BY b.zanom_asin, b.purchased_with_asin) AS periodos_observados,
  b.synced_at
FROM swarm_src.amazon_brand_analytics_market_basket b
WHERE COALESCE(b.zanom_asin,'') <> '' AND COALESCE(b.purchased_with_asin,'') <> '';

-- SILVER Repeat Purchase (spec §30).
CREATE OR REPLACE VIEW marketcloud_silver.silver_ba_repeat_purchase_v1 AS
SELECT
  r.marketplace_id,
  r.period,
  r.period_start,
  r.period_end,
  r.asin,
  r.orders,
  r.unique_customers,
  r.repeat_customers,
  r.repeat_purchase_rate,
  r.repeat_purchase_revenue,
  -- §50: zero mascarado é pior que "sem dado". Numa janela de 7 dias o cliente não
  -- tem como voltar, então o zero não significa "ninguém recomprou".
  CASE
    WHEN r.period = 'WEEK' THEN 'JANELA_CURTA_DEMAIS'
    WHEN COALESCE(r.unique_customers,0) < 30 THEN 'AMOSTRA_INSUFICIENTE'
    ELSE 'OK'
  END AS leitura_possivel,
  r.synced_at
FROM swarm_src.amazon_brand_analytics_repeat_purchase r
WHERE COALESCE(r.asin,'') <> '';

-- GOLD Basket Affinity (spec §29). Agrega o par ao longo do tempo e declara a força
-- do sinal — nenhum consumidor deve ler combination_pct sem saber em quantos períodos
-- aquele par se repetiu.
CREATE OR REPLACE VIEW marketcloud_gold.gold_product_affinity_v1 AS
SELECT
  zanom_asin,
  purchased_with_asin,
  MAX(purchased_with_name)          AS purchased_with_name,
  COUNT(DISTINCT period_start)      AS periodos_observados,
  ROUND(AVG(combination_pct)::numeric, 4) AS combination_pct_medio,
  ROUND(MAX(combination_pct)::numeric, 4) AS combination_pct_maximo,
  MIN(purchased_with_rank)          AS melhor_rank,
  MIN(period_start)                 AS visto_desde,
  MAX(period_end)                   AS visto_ate,
  -- Um par visto uma vez só não é afinidade, é coincidência. Só vira sinal quando
  -- reaparece: é a única evidência disponível de que a co-compra não foi acaso.
  CASE
    WHEN COUNT(DISTINCT period_start) >= 4 THEN 'ALTO'
    WHEN COUNT(DISTINCT period_start) >= 2 THEN 'MEDIO'
    ELSE 'COINCIDENCIA_POSSIVEL'
  END AS forca_do_sinal
FROM marketcloud_silver.silver_ba_market_basket_v1
GROUP BY zanom_asin, purchased_with_asin;
