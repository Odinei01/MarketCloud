-- 220: DETECTOR DE QUERY BARATA QUE CONVERTE — "estar onde ninguém está".
--
-- POR QUE ESTA VIEW EXISTE, e por que ela contraria o senso comum de PPC:
--
-- Medi as 4.220 buscas pagas da conta em 90 dias, separadas por faixa de CPC:
--
--   ate R$0,50      242 termos   CVR 13,1%   ROAS 14,1   contribuicao  +428,47
--   R$0,50-1,00     577 termos   CVR 12,1%   ROAS  5,9   contribuicao +1.457,07
--   R$1,00-1,50     346 termos   CVR 11,4%   ROAS  3,8   contribuicao  +670,85
--   acima R$1,50    320 termos   CVR 12,7%   ROAS  3,0   contribuicao  -108,68
--
-- A CONVERSAO E A MESMA em todas as faixas. O clique caro nao compra intencao melhor —
-- so custa mais. E acima de R$1,50 a operacao DESTROI valor. Logo, a alavanca desta
-- conta nao e ganhar o leilao caro: e achar leilao que ninguem disputa.
--
-- O QUE OS CLIQUES BARATOS QUE VENDERAM TEM EM COMUM (medido, nao suposto):
--
--   atributo especifico   "220v", "android", "2 unidades", "vertuo", "iphone"
--                         quem digita o atributo ja decidiu; o generico nao disputa
--   grafia alternativa    "cosedora de ovos 220v" (com S), "smarttag" junto
--                         NINGUEM da lance em erro de digitacao — mesma intencao,
--                         um terco do preco
--   cauda longa           3 a 6 palavras, volume baixo, decisao madura
--
-- Por isso o §15 proibe autocorrigir ortografia na dim_search_query. Aquilo parecia
-- higiene de dado e e dinheiro: "cosedora" converteu a R$0,22 o clique.
--
-- A VIEW NAO PROMETE VENDA. Ela devolve candidatos a TESTE. Cada termo semente vendeu
-- com 1 ou 2 cliques — convincente no agregado, minusculo por termo. O valor esta em
-- testar dezenas por centavos, nao em acertar cada um.

CREATE OR REPLACE VIEW marketcloud_gold.v_query_barata_candidata AS
WITH sementes AS (
  -- o que a ZANOM JA vendeu com clique barato: a prova viva do padrao
  SELECT lower(btrim(search_term)) q,
         SUM(units_sold) un,
         SUM(cost) / NULLIF(SUM(clicks), 0) cpc
  FROM swarm_src.amazon_ads_search_terms_daily
  WHERE date >= CURRENT_DATE - 90 AND COALESCE(search_term,'') <> ''
  GROUP BY 1
  HAVING SUM(units_sold) > 0 AND SUM(cost) / NULLIF(SUM(clicks), 0) < 0.80
),
tokens_semente AS (
  -- vocabulario que comprovadamente vende barato, sem palavra curta/vazia
  SELECT DISTINCT tok
  FROM sementes, LATERAL unnest(string_to_array(q, ' ')) tok
  WHERE length(tok) >= 4
    AND tok NOT IN ('para','com','sem','por','uma','dois','mais','tipo','kit')
),
ja_paga AS (
  -- onde a ZANOM ja aparece pagando: nao e "onde ninguem esta"
  SELECT DISTINCT lower(btrim(search_term)) q
  FROM swarm_src.amazon_ads_search_terms_daily
  WHERE date >= CURRENT_DATE - 90 AND COALESCE(search_term,'') <> ''
),
mercado AS (
  -- o universo: o que a Amazon registra que o mercado busca
  SELECT lower(btrim(m.search_query)) q,
         MIN(m.search_frequency_rank) rank_busca,
         AVG(m.top3_click_concentration) top3_concentracao,
         MAX(m.market_concentration_class) classe_mercado,
         MAX(m.top1_asin) lider_asin,
         AVG(m.top1_click_share) lider_click_share,
         COUNT(DISTINCT m.period_start) semanas
  FROM marketcloud_gold.gold_market_search_weekly_v1 m
  WHERE COALESCE(m.search_query,'') <> ''
  GROUP BY 1
),
pontuado AS (
  SELECT
    mk.q AS query,
    mk.rank_busca,
    ROUND(mk.top3_concentracao::numeric, 4) top3_concentracao,
    mk.classe_mercado,
    mk.lider_asin,
    ROUND(mk.lider_click_share::numeric, 4) lider_click_share,
    mk.semanas,
    array_length(string_to_array(mk.q, ' '), 1) palavras,
    -- quantos tokens desta query ja aparecem em termo que a ZANOM vendeu barato.
    -- E o sinal mais forte: nao e semelhanca semantica inventada, e vocabulario com
    -- venda comprovada na propria conta.
    (SELECT COUNT(*) FROM unnest(string_to_array(mk.q,' ')) t
      WHERE t IN (SELECT tok FROM tokens_semente)) tokens_provados,
    -- atributo que estreita a intencao. Quem busca "220v" nao quer ver generico.
    (mk.q ~ '(^| )(220|110|127|bivolt|volt|v)( |$)'
     OR mk.q ~ 'android|iphone|ios|usb|otg|bluetooth|vertuo|dolce|nespresso'
     OR mk.q ~ '[0-9]+ ?(un|unidades|pcs|pecas|w|ml|mm|cm|litros)') tem_atributo
  FROM mercado mk
  LEFT JOIN ja_paga p ON p.q = mk.q
  WHERE p.q IS NULL          -- onde a ZANOM ainda NAO esta
)
SELECT *,
  -- Score deliberadamente simples e legivel. Nada de peso magico: cada parcela
  -- corresponde a um padrao que foi MEDIDO nos cliques baratos que venderam.
  ( LEAST(tokens_provados, 3) * 3                                    -- vocabulario provado
  + CASE WHEN tem_atributo THEN 3 ELSE 0 END                         -- intencao estreita
  + CASE WHEN palavras BETWEEN 3 AND 6 THEN 2 ELSE 0 END             -- cauda longa
  -- mercado sem dono = leilao barato. Concentracao alta significa que alguem
  -- grande esta pagando caro para segurar a posicao, e entrar ali sai caro.
  + CASE WHEN top3_concentracao < 0.30 THEN 3
         WHEN top3_concentracao < 0.50 THEN 1 ELSE 0 END
  + CASE WHEN semanas >= 2 THEN 1 ELSE 0 END                         -- nao e ruido de 1 semana
  ) AS score,
  CASE
    WHEN tokens_provados = 0 THEN 'SEM_PARENTESCO'
    WHEN top3_concentracao >= 0.50 THEN 'MERCADO_DOMINADO'
    ELSE 'CANDIDATA'
  END AS veredito
FROM pontuado;

-- ----------------------------------------------------------------------------
-- TRAVA DE CATALOGO (adicionada apos a primeira leitura da view).
--
-- A primeira versao recomendou "capinha iphone 13" e "case iphone 17 pro max".
-- Sao queries baratas e fragmentadas de verdade — e a ZANOM NAO VENDE CAPINHA.
-- Entrar ali seria pagar clique por produto inexistente, provando o oposto da tese.
--
-- Barato so vale quando existe o que vender. A view passa a exigir que a query
-- compartilhe vocabulario com algum titulo do catalogo real.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW marketcloud_gold.v_query_barata_candidata_v2 AS
WITH cat AS (
  -- vocabulario do que a ZANOM realmente vende
  SELECT DISTINCT lower(tok) tok
  FROM swarm_src.amazon_listings l,
       LATERAL unnest(string_to_array(
         regexp_replace(lower(COALESCE(l.title,'')), '[^a-z0-9áàâãéêíóôõúç ]', ' ', 'g'), ' ')) tok
  WHERE COALESCE(l.title,'') <> '' AND length(tok) >= 4
)
SELECT c.*,
       (SELECT COUNT(*) FROM unnest(string_to_array(c.query,' ')) t
         WHERE lower(t) IN (SELECT tok FROM cat)) AS tokens_do_catalogo
FROM marketcloud_gold.v_query_barata_candidata c;
