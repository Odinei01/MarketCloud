-- 194 — Fase 1 do lado MERCADO da spec ZANOM MARKETCLOUD (Brand Analytics).
-- Fonte: Search Terms (data_domain=MARKET_SEARCH_TERMS) — top-3 ASINs clicados por
-- termo, com searchFrequencyRank e click/conversion share (frações 0-1).
-- Entrega o que faltava: registry de concorrente (§26) + market search weekly com
-- concentração top3 e classe (§25/§34). FATO, não decisão — sem CASE que aciona ação.
-- rank_change_wow fica estruturado mas nulo enquanto houver 1 só semana ingerida.

CREATE SCHEMA IF NOT EXISTS marketcloud_gold;

-- ---------------------------------------------------------------------------
-- §26 dim_market_asin — registro persistente de todo ASIN visto no Search Terms,
-- independente do catálogo ZANOM. Descobre o concorrente real por comportamento
-- de busca (aparece repetido, domina top1/top3), não por categoria.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS marketcloud_gold.dim_market_asin_v1 CASCADE;
CREATE VIEW marketcloud_gold.dim_market_asin_v1 AS
WITH st AS (
  SELECT
    upper(trim(asin))                                       AS asin,
    search_query,
    period_start, period_end,
    NULLIF(raw_json_sanitized->>'clickShareRank','')::int   AS click_rank,
    COALESCE(brand_click_share,0)::float8                   AS click_share,
    COALESCE(brand_purchase_share,0)::float8                AS conversion_share,
    max(raw_json_sanitized->>'clickedItemName')             OVER (PARTITION BY upper(trim(asin))) AS item_name
  FROM swarm_src.amazon_brand_analytics_search_query_performance
  WHERE COALESCE(data_domain,'') = 'MARKET_SEARCH_TERMS'
    AND COALESCE(asin,'') <> ''
),
ours AS (
  SELECT DISTINCT upper(trim(asin)) AS asin FROM marketcloud_gold.dim_ba_brand_asin_v1 WHERE COALESCE(asin,'') <> ''
)
SELECT
  st.asin,
  max(st.item_name)                                          AS item_name,
  min(st.period_start)                                       AS first_seen,
  max(st.period_end)                                         AS last_seen,
  count(DISTINCT st.search_query)                            AS queries_count,
  count(*) FILTER (WHERE st.click_rank = 1)                  AS top1_count,
  count(*) FILTER (WHERE st.click_rank <= 3)                 AS top3_count,
  round(avg(st.click_share)::numeric, 4)                     AS avg_click_share,
  round(avg(st.conversion_share)::numeric, 4)               AS avg_conversion_share,
  (o.asin IS NOT NULL)                                       AS is_zanom
FROM st
LEFT JOIN ours o ON o.asin = st.asin
GROUP BY st.asin, o.asin;

COMMENT ON VIEW marketcloud_gold.dim_market_asin_v1 IS
  'Registry de ASIN de mercado (Search Terms), independente do catálogo ZANOM. §26. is_zanom marca os nossos. Descobre concorrente real por comportamento de busca.';

-- ---------------------------------------------------------------------------
-- §34 gold_market_search_weekly — visão de mercado por termo/semana: frequência,
-- top1/2/3 ASIN, concentração top3 e classe (§25). rank_change_wow via LAG (nulo
-- com 1 semana). §78: rank menor = posição melhor, então a variação inverte sinal.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS marketcloud_gold.gold_market_search_weekly_v1 CASCADE;
CREATE VIEW marketcloud_gold.gold_market_search_weekly_v1 AS
WITH st AS (
  SELECT
    period_start, period_end,
    search_query,
    upper(trim(asin))                                     AS asin,
    NULLIF(raw_json_sanitized->>'clickShareRank','')::int AS click_rank,
    COALESCE(query_rank,0)                                AS search_frequency_rank,
    COALESCE(brand_click_share,0)::float8                 AS click_share,
    COALESCE(brand_purchase_share,0)::float8              AS conversion_share
  FROM swarm_src.amazon_brand_analytics_search_query_performance
  WHERE COALESCE(data_domain,'') = 'MARKET_SEARCH_TERMS'
    AND COALESCE(search_query,'') <> ''
),
agg AS (
  SELECT
    period_start, period_end, search_query,
    min(NULLIF(search_frequency_rank,0))                                  AS search_frequency_rank,
    max(asin)             FILTER (WHERE click_rank = 1)                    AS top1_asin,
    max(click_share)      FILTER (WHERE click_rank = 1)                    AS top1_click_share,
    max(conversion_share) FILTER (WHERE click_rank = 1)                    AS top1_conversion_share,
    max(asin)             FILTER (WHERE click_rank = 2)                    AS top2_asin,
    max(click_share)      FILTER (WHERE click_rank = 2)                    AS top2_click_share,
    max(conversion_share) FILTER (WHERE click_rank = 2)                    AS top2_conversion_share,
    max(asin)             FILTER (WHERE click_rank = 3)                    AS top3_asin,
    max(click_share)      FILTER (WHERE click_rank = 3)                    AS top3_click_share,
    max(conversion_share) FILTER (WHERE click_rank = 3)                    AS top3_conversion_share,
    round(sum(click_share)      FILTER (WHERE click_rank <= 3)::numeric,4) AS top3_click_concentration,
    round(sum(conversion_share) FILTER (WHERE click_rank <= 3)::numeric,4) AS top3_conversion_concentration
  FROM st
  GROUP BY period_start, period_end, search_query
)
SELECT
  a.*,
  -- §25 classe de concentração (thresholds default; recalibráveis). FATO descritivo.
  CASE
    WHEN a.top3_click_concentration >= 0.80 THEN 'HIGHLY_CONCENTRATED'
    WHEN a.top3_click_concentration >= 0.60 THEN 'CONCENTRATED'
    WHEN a.top3_click_concentration >= 0.40 THEN 'FRAGMENTED'
    ELSE 'HIGHLY_FRAGMENTED'
  END AS market_concentration_class,
  -- §78 rank momentum: menor rank = melhor. rank_prev - rank_atual => positivo = subiu.
  ( LAG(a.search_frequency_rank) OVER (PARTITION BY a.search_query ORDER BY a.period_start)
    - a.search_frequency_rank ) AS rank_change_wow
FROM agg a;

COMMENT ON VIEW marketcloud_gold.gold_market_search_weekly_v1 IS
  'Mercado por termo/semana (§34): top1/2/3 ASIN, concentração top3 e classe (§25), rank momentum invertido (§78). Fonte Search Terms. rank_change_wow nulo enquanto 1 semana.';
