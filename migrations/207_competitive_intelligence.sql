-- 207_competitive_intelligence.sql
-- COMPETITIVE INTELLIGENCE (§46-47). Fonte: Search Terms E003 (top1/2/3 por busca),
-- escopado as buscas onde a ZANOM tem query propria (E001), casadas por texto normalizado.
-- §46: gold_query_competitor_weekly = semana x query x competidor (base do leader tracking).
-- §47: gold_competitor_overlap_score = agrega por competidor (quem sao os concorrentes reais).

CREATE OR REPLACE VIEW marketcloud_gold.gold_query_competitor_weekly_v1 AS
WITH zq AS (  -- buscas onde a ZANOM participa (query propria E001), normalizadas
    SELECT DISTINCT lower(btrim(search_query)) AS qn
    FROM marketcloud_gold.gold_brand_query_weekly_v1 WHERE search_query IS NOT NULL
),
mkt AS (  -- top1/2/3 do mercado (E003) desempilhados em linhas
    SELECT period_start, period_end, search_query, search_frequency_rank, lower(btrim(search_query)) AS qn,
           top1_asin AS competitor_asin, 1 AS competitor_rank, top1_click_share AS click_share, top1_conversion_share AS conversion_share
    FROM marketcloud_gold.gold_market_search_weekly_v1 WHERE top1_asin IS NOT NULL
    UNION ALL
    SELECT period_start, period_end, search_query, search_frequency_rank, lower(btrim(search_query)),
           top2_asin, 2, top2_click_share, top2_conversion_share
    FROM marketcloud_gold.gold_market_search_weekly_v1 WHERE top2_asin IS NOT NULL
    UNION ALL
    SELECT period_start, period_end, search_query, search_frequency_rank, lower(btrim(search_query)),
           top3_asin, 3, top3_click_share, top3_conversion_share
    FROM marketcloud_gold.gold_market_search_weekly_v1 WHERE top3_asin IS NOT NULL
),
brand_asins AS (SELECT DISTINCT asin FROM marketcloud_gold.dim_ba_brand_asin_v1)
SELECT m.period_start, m.period_end, m.search_query, m.search_frequency_rank,
       m.competitor_asin, m.competitor_rank, m.click_share AS competitor_click_share,
       m.conversion_share AS competitor_conversion_share,
       (m.competitor_asin IN (SELECT asin FROM brand_asins)) AS is_zanom
FROM mkt m JOIN zq ON zq.qn = m.qn;

COMMENT ON VIEW marketcloud_gold.gold_query_competitor_weekly_v1 IS
 '§46 semana x query x competidor nas buscas onde a ZANOM tem query (E001 x E003 por texto). is_zanom separa a propria marca dos concorrentes.';

-- §47: quem sao os concorrentes REAIS (aparecem repetidamente nas buscas da ZANOM).
CREATE OR REPLACE VIEW marketcloud_gold.gold_competitor_overlap_score_v1 AS
SELECT
    competitor_asin,
    count(DISTINCT search_query)                                          AS queries_shared_with_zanom,
    count(DISTINCT search_query) FILTER (WHERE competitor_rank = 1)       AS queries_where_top1,
    count(DISTINCT search_query) FILTER (WHERE competitor_rank <= 3)      AS queries_where_top3,
    round(avg(competitor_click_share)::numeric, 4)                        AS avg_click_share,
    round(avg(competitor_conversion_share)::numeric, 4)                   AS avg_conversion_share,
    -- weighted_overlap: soma do click share do competidor nas buscas compartilhadas
    -- (domina muitas buscas da ZANOM com share alto -> concorrente mais forte).
    round(sum(competitor_click_share)::numeric, 4)                        AS weighted_overlap
FROM marketcloud_gold.gold_query_competitor_weekly_v1
WHERE NOT is_zanom AND competitor_asin IS NOT NULL
GROUP BY competitor_asin
ORDER BY queries_shared_with_zanom DESC, weighted_overlap DESC;

COMMENT ON VIEW marketcloud_gold.gold_competitor_overlap_score_v1 IS
 '§47 competitor_overlap_score: concorrentes reais da ZANOM por comportamento de busca (nao categoria). Ranqueado por buscas compartilhadas + overlap ponderado.';
