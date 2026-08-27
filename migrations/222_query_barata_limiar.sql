-- 222: determinismo e limiar do detector de query barata.
--
-- SINTOMA: a mesma consulta devolvia 611 linhas sem ORDER BY e 634 com ORDER BY,
-- de forma ESTAVEL nas duas formas. Estavel por plano e diferente entre planos nao e
-- leitura suja — e aritmetica de ponto flutuante.
--
-- CAUSA 1, determinismo: top3_concentracao vinha de AVG() sobre double precision. A
-- soma de floats depende da ORDEM das parcelas, e a ordem muda com o plano. Duas
-- execucoes da mesma media davam valores que diferiam na ultima casa.
--
-- CAUSA 2, e a mais grave: o limiar do veredito era >= 0.50, e os dados se AMONTOAM
-- exatamente ali. Medido: 272 queries entre 0,495 e 0,505, sendo 52 EXATAMENTE em
-- 0,500. Um corte em cima do monte faz dezenas de linhas trocarem de lado com uma
-- diferenca na 15a casa decimal. O numero nao era reproduzivel porque o corte estava
-- no pior lugar possivel.
--
-- CORRECAO:
--   AVG(x::numeric) — soma exata, independente de ordem
--   ROUND(...,4) antes de comparar — decisao sobre valor estavel
--   limiar movido de 0,50 para 0,55, longe do amontoado
--
-- Mover o limiar MUDA a classificacao de propósito: as 52 queries que estavam
-- exatamente no corte passam a ser CANDIDATAS. Elas tem top-3 levando metade dos
-- cliques — apertado, mas ainda nao e mercado dominado, e o custo de testa-las e
-- centavos.

CREATE OR REPLACE VIEW marketcloud_gold.v_query_barata_candidata AS
WITH sementes AS (
  SELECT lower(btrim(search_term)) q,
         SUM(units_sold) un,
         SUM(cost) / NULLIF(SUM(clicks), 0) cpc
  FROM swarm_src.amazon_ads_search_terms_daily
  WHERE date >= CURRENT_DATE - 90 AND COALESCE(search_term,'') <> ''
  GROUP BY 1
  HAVING SUM(units_sold) > 0 AND SUM(cost) / NULLIF(SUM(clicks), 0) < 0.80
),
tokens_semente AS (
  SELECT DISTINCT tok
  FROM sementes, LATERAL unnest(string_to_array(q, ' ')) tok
  WHERE length(tok) >= 4
    AND tok NOT IN ('para','com','sem','por','uma','dois','mais','tipo','kit')
),
ja_paga AS (
  SELECT DISTINCT lower(btrim(search_term)) q
  FROM swarm_src.amazon_ads_search_terms_daily
  WHERE date >= CURRENT_DATE - 90 AND COALESCE(search_term,'') <> ''
),
mercado AS (
  SELECT lower(btrim(m.search_query)) q,
         MIN(m.search_frequency_rank) rank_busca,
         -- numeric, nao float: soma exata e independente da ordem do plano
         ROUND(AVG(m.top3_click_concentration::numeric), 4) top3_concentracao,
         MAX(m.market_concentration_class) classe_mercado,
         MAX(m.top1_asin) lider_asin,
         ROUND(AVG(m.top1_click_share::numeric), 4) lider_click_share,
         COUNT(DISTINCT m.period_start) semanas
  FROM marketcloud_gold.gold_market_search_weekly_v1 m
  WHERE COALESCE(m.search_query,'') <> ''
  GROUP BY 1
),
pontuado AS (
  SELECT mk.q AS query, mk.rank_busca, mk.top3_concentracao, mk.classe_mercado,
         mk.lider_asin, mk.lider_click_share, mk.semanas,
         array_length(string_to_array(mk.q, ' '), 1) palavras,
         (SELECT COUNT(*) FROM unnest(string_to_array(mk.q,' ')) t
           WHERE t IN (SELECT tok FROM tokens_semente)) tokens_provados,
         (mk.q ~ '(^| )(220|110|127|bivolt|volt|v)( |$)'
          OR mk.q ~ 'android|iphone|ios|usb|otg|bluetooth|vertuo|dolce|nespresso'
          OR mk.q ~ '[0-9]+ ?(un|unidades|pcs|pecas|w|ml|mm|cm|litros)') tem_atributo
  FROM mercado mk
  LEFT JOIN ja_paga p ON p.q = mk.q
  WHERE p.q IS NULL
)
SELECT *,
  ( LEAST(tokens_provados, 3) * 3
  + CASE WHEN tem_atributo THEN 3 ELSE 0 END
  + CASE WHEN palavras BETWEEN 3 AND 6 THEN 2 ELSE 0 END
  + CASE WHEN top3_concentracao < 0.30 THEN 3
         WHEN top3_concentracao < 0.55 THEN 1 ELSE 0 END
  + CASE WHEN semanas >= 2 THEN 1 ELSE 0 END
  ) AS score,
  CASE
    WHEN tokens_provados = 0 THEN 'SEM_PARENTESCO'
    WHEN top3_concentracao >= 0.55 THEN 'MERCADO_DOMINADO'
    ELSE 'CANDIDATA'
  END AS veredito
FROM pontuado;
