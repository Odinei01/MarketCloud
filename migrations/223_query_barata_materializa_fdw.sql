-- 223: materializa as entradas de FDW do detector. Sem isto o numero nao se repete.
--
-- SINTOMA, e o caminho ate a causa:
--
--   mesma consulta, sem ORDER BY -> 701 linhas
--   mesma consulta, com ORDER BY -> 726 linhas
--
-- Estavel nas duas formas, em 3 rodadas. Testei dentro de UMA transacao REPEATABLE
-- READ: a divergencia PERMANECE. Logo nao e leitura suja entre transacoes — e o plano.
--
-- Entre as 25 linhas a mais aparecia "abridor de vinho eletrico", termo que a ZANOM JA
-- PAGA e que o filtro ja_paga deveria excluir. Ou seja, o anti-join sobre a foreign
-- table swarm_src.amazon_ads_search_terms_daily produzia resultado diferente conforme
-- o plano escolhido — e essa tabela e reescrita pelo worker de sync (DELETE + INSERT
-- da janela) enquanto e lida.
--
-- Nao fui atras do mecanismo exato dentro do postgres_fdw porque a correcao e a mesma
-- em qualquer hipotese, e e a correcao certa de qualquer forma: DECISAO NAO SE APOIA
-- EM VARREDURA REPETIDA DE TABELA REMOTA VIVA. Materializa uma vez, decide sobre o
-- que foi materializado.
--
-- Ganho colateral: para de cruzar o FDW a cada consulta da tela.

CREATE TABLE IF NOT EXISTS marketcloud_gold.qb_termo_ja_pago (
  query text PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS marketcloud_gold.qb_token_semente (
  token text PRIMARY KEY
);

CREATE OR REPLACE FUNCTION marketcloud_gold.refresh_query_barata_insumos()
  RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE n_pago int; n_tok int; n_cat int;
BEGIN
  -- 1) tudo que a ZANOM ja paga: uma varredura, gravada local
  DELETE FROM marketcloud_gold.qb_termo_ja_pago;
  INSERT INTO marketcloud_gold.qb_termo_ja_pago (query)
  SELECT DISTINCT lower(btrim(search_term))
  FROM swarm_src.amazon_ads_search_terms_daily
  WHERE date >= CURRENT_DATE - 90 AND COALESCE(search_term,'') <> ''
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n_pago = ROW_COUNT;

  -- 2) vocabulario que ja vendeu com clique barato
  DELETE FROM marketcloud_gold.qb_token_semente;
  INSERT INTO marketcloud_gold.qb_token_semente (token)
  SELECT DISTINCT tok FROM (
    SELECT lower(btrim(search_term)) q
    FROM swarm_src.amazon_ads_search_terms_daily
    WHERE date >= CURRENT_DATE - 90 AND COALESCE(search_term,'') <> ''
    GROUP BY 1
    HAVING SUM(units_sold) > 0 AND SUM(cost)/NULLIF(SUM(clicks),0) < 0.80
  ) s, LATERAL unnest(string_to_array(s.q,' ')) tok
  WHERE length(tok) >= 4
    AND tok NOT IN ('para','com','sem','por','uma','dois','mais','tipo','kit')
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n_tok = ROW_COUNT;

  n_cat := marketcloud_gold.refresh_vocabulario_catalogo();
  RETURN format('ja_pago=%s tokens_semente=%s vocab_catalogo=%s', n_pago, n_tok, n_cat);
END $fn$;

SELECT marketcloud_gold.refresh_query_barata_insumos();

CREATE OR REPLACE VIEW marketcloud_gold.v_query_barata_candidata AS
WITH mercado AS (
  SELECT lower(btrim(m.search_query)) q,
         MIN(m.search_frequency_rank) rank_busca,
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
           JOIN marketcloud_gold.qb_token_semente s ON s.token = t) tokens_provados,
         (mk.q ~ '(^| )(220|110|127|bivolt|volt|v)( |$)'
          OR mk.q ~ 'android|iphone|ios|usb|otg|bluetooth|vertuo|dolce|nespresso'
          OR mk.q ~ '[0-9]+ ?(un|unidades|pcs|pecas|w|ml|mm|cm|litros)') tem_atributo
  FROM mercado mk
  LEFT JOIN marketcloud_gold.qb_termo_ja_pago p ON p.query = mk.q
  WHERE p.query IS NULL
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
