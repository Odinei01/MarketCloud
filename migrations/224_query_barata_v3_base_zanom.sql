-- 224: v3 do detector — base ZANOM, nao marketplace inteiro.
--
-- POR QUE A v2 PRODUZIU LIXO (o dono viu na primeira leitura):
--
-- O universo vinha de gold_market_search_weekly_v1, que vem do BA-E003 — o relatorio
-- de Search Terms da AMAZON INTEIRA. Sao os termos mais buscados do marketplace Brasil,
-- sem recorte de categoria. Por isso entrou "air fryer philips walita" e "case iphone
-- 17 pro max": buscas grandes da Amazon, nada a ver com a ZANOM.
--
-- E o gate de catalogo era SACO DE PALAVRAS contra titulos de produto. Medido, o que
-- ele estava aprovando:
--     "porta" -> 83 queries    "para" -> 45 queries    "iphone" -> 73 queries
-- "para" e preposicao: esta em "Suporte PARA Papel Toalha" e passou a validar qualquer
-- busca com "para". "porta" vem de "Porta Capsulas" e valida "porta retrato", "porta
-- joias". O gate respondia "essa busca usa alguma palavra de algum titulo meu?" —
-- pergunta quase sempre verdadeira e quase nunca util.
--
-- A BASE CERTA, e ela ja existia:
--
-- BA-E001 (Search Query Performance) registra as buscas em que a AMAZON mostra um ASIN
-- ZANOM. Sao 2.292 queries, e 2.130 delas a ZANOM NAO paga clique. A relevancia nao
-- precisa ser inferida por palavra: a propria Amazon associou a busca ao ASIN, e a
-- impressao aconteceu. Cada linha ja vem com asin, funil e share.
--
-- O QUE A v3 PROCURA: busca onde a ZANOM JA APARECE organicamente, JA CONVERTE, o
-- mercado NAO tem dono, e ela ainda NAO paga por clique. E entrar barato onde a
-- presenca ja esta provada — nao adivinhar mercado novo.

CREATE OR REPLACE VIEW marketcloud_gold.v_query_barata_v3 AS
WITH ba AS (
  -- o que a Amazon diz sobre a ZANOM em cada busca (grao asin x query)
  SELECT lower(btrim(q.search_query)) query,
         q.asin,
         SUM(q.brand_impressions)  impressoes_zanom,
         SUM(q.brand_clicks)       cliques_zanom,
         SUM(q.brand_purchases)    compras_zanom,
         MAX(q.search_query_volume) volume_busca,
         AVG(q.purchase_share_lift) lift_compra,
         AVG(q.click_price_index)   indice_preco
  FROM marketcloud_gold.gold_brand_query_weekly_v1 q
  WHERE COALESCE(q.search_query,'') <> ''
  GROUP BY 1,2
),
mercado AS (
  SELECT lower(btrim(search_query)) query,
         ROUND(AVG(top3_click_concentration::numeric),4) top3_concentracao,
         MAX(market_concentration_class) classe_mercado
  FROM marketcloud_gold.gold_market_search_weekly_v1
  WHERE COALESCE(search_query,'') <> ''
  GROUP BY 1
)
SELECT
  b.query, b.asin,
  b.volume_busca, b.impressoes_zanom, b.cliques_zanom, b.compras_zanom,
  ROUND(b.lift_compra::numeric,3)  lift_compra,
  ROUND(b.indice_preco::numeric,3) indice_preco,
  m.top3_concentracao, m.classe_mercado,
  -- Score sobre EVIDENCIA da propria busca, nao sobre semelhanca de palavra:
  ( CASE WHEN b.compras_zanom > 0 THEN 5 ELSE 0 END          -- ja vendeu ali
  + CASE WHEN b.cliques_zanom  > 0 THEN 2 ELSE 0 END          -- ja leva clique
  + CASE WHEN b.lift_compra > 1 THEN 3 ELSE 0 END             -- ganha share no funil
  -- preco competitivo: indice < 1 significa abaixo da mediana do mercado. E o sinal
  -- que o dono levantou — exposicao so funciona quando o preco nao afasta.
  + CASE WHEN b.indice_preco IS NOT NULL AND b.indice_preco <= 1.0 THEN 2 ELSE 0 END
  + CASE WHEN m.top3_concentracao < 0.30 THEN 3
         WHEN m.top3_concentracao < 0.55 THEN 1 ELSE 0 END    -- leilao sem dono
  ) AS score,
  CASE
    WHEN b.compras_zanom > 0 THEN 'JA_VENDE_SEM_PAGAR'
    WHEN b.cliques_zanom > 0 THEN 'JA_CLICA_SEM_PAGAR'
    ELSE 'SO_IMPRESSAO'
  END AS evidencia
FROM ba b
LEFT JOIN mercado m ON m.query = b.query
LEFT JOIN marketcloud_gold.qb_termo_ja_pago p ON p.query = b.query
WHERE p.query IS NULL              -- ainda nao paga clique
  AND b.impressoes_zanom > 0;      -- a Amazon ja mostrou o produto ali
