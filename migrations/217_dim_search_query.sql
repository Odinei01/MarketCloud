-- 217: dim_search_query (spec §35) com a normalização do §15.
--
-- É a peça que faltava para os dois universos se encontrarem. Hoje Search Query
-- Performance (o que a ZANOM captura) e Search Terms (o que o mercado busca) vivem
-- separados: a mesma busca aparece com grafias diferentes nos dois e ninguém consegue
-- responder "quanto desse termo eu pego?" sem casar na mão. É também a chave que o §69
-- exige para o join futuro com os search terms de Ads.
--
-- REGRA DO §15 QUE NÃO PODE SER VIOLADA: não autocorrigir erro de digitação.
-- "Cozeror de Ovos" continua sendo uma query própria, separada de "cozedor de ovos".
-- Quem digita errado tem intenção de compra igual, e juntar as duas apagaria demanda
-- real — a versão sem acento existe para APROXIMAR grafias, não para corrigir palavra.
--
-- Por isso três níveis, do mais fiel ao mais permissivo:
--   query_raw        = exatamente o que veio da Amazon
--   query_normalized = minúscula, sem espaço duplicado, sem pontuação de borda
--   query_no_accent  = a anterior sem acento, para casar "cafe" com "café"
-- canonical_query = query_no_accent nesta versão (§35 permite; cluster semântico fica
-- para quando houver histórico que justifique).

CREATE OR REPLACE FUNCTION marketcloud_silver.normaliza_query(p text)
RETURNS text AS $fn$
  SELECT NULLIF(
    regexp_replace(
      regexp_replace(
        btrim(lower(COALESCE(p,''))),
        '[[:punct:]]+$', '', 'g'),      -- pontuação só nas bordas; hífen interno fica
      '\s+', ' ', 'g'),                  -- espaço duplicado vira um
  '')
$fn$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION marketcloud_silver.query_sem_acento(p text)
RETURNS text AS $fn$
  SELECT translate(COALESCE(p,''),
    'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
    'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN')
$fn$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE VIEW marketcloud_gold.dim_search_query_v1 AS
WITH todas AS (
  -- lado ZANOM: as queries em que a marca aparece
  SELECT search_query AS q, period_start, period_end, 'PROPRIETARY'::text AS origem
  FROM swarm_src.amazon_brand_analytics_search_query_performance
  WHERE COALESCE(search_query,'') <> ''
    AND COALESCE(data_domain,'PROPRIETARY_SEARCH_QUERY') = 'PROPRIETARY_SEARCH_QUERY'
  UNION ALL
  -- lado MERCADO: o que a Amazon inteira busca, tenha a ZANOM ou não
  SELECT search_term, period_start, period_end, 'MARKET'
  FROM swarm_src.amazon_brand_analytics_search_terms
  WHERE COALESCE(search_term,'') <> ''
),
norm AS (
  SELECT
    q AS query_raw,
    marketcloud_silver.normaliza_query(q) AS query_normalized,
    marketcloud_silver.query_sem_acento(marketcloud_silver.normaliza_query(q)) AS query_no_accent,
    period_start, period_end, origem
  FROM todas
)
SELECT
  md5(query_no_accent)                       AS query_id,
  MIN(query_raw)                             AS query_raw,
  query_normalized,
  query_no_accent,
  query_no_accent                            AS canonical_query,
  NULL::text                                 AS semantic_cluster_id,
  NULL::text                                 AS intent_type,
  MIN(period_start)                          AS first_seen,
  MAX(period_end)                            AS last_seen,
  COUNT(DISTINCT period_start)               AS periodos_observados,
  -- o valor real da dimensão: dizer de que lado a query existe.
  -- AMBOS = dá para comparar captura da ZANOM contra demanda do mercado.
  -- MARKET = mercado busca e a ZANOM não aparece (matéria-prima de §44/oportunidade).
  -- PROPRIETARY = a ZANOM captura mas o termo não figura no top do mercado.
  CASE
    WHEN bool_or(origem='PROPRIETARY') AND bool_or(origem='MARKET') THEN 'AMBOS'
    WHEN bool_or(origem='MARKET') THEN 'SO_MERCADO'
    ELSE 'SO_ZANOM'
  END                                        AS cobertura
FROM norm
WHERE query_normalized IS NOT NULL
GROUP BY query_normalized, query_no_accent;
