-- 212: repoint do gold de MERCADO (Search Terms) da tabela SQP poluída para a tabela
-- dedicada swarm_src.amazon_brand_analytics_search_terms (E003, shape long limpo).
-- click_rank agora é COLUNA (click_share_rank), não mais raw_json->>'clickShareRank'.
-- Mesmas colunas de saída em todas as views/MVs → API e telas inalteradas.
--
-- Grafo do CASCADE (mv_gold_market_search_weekly inlina a query da SQP → precisa recriar):
--   mv_gold_market_search_weekly_v1 (MV, inlina)
--     └ gold_market_search_weekly_v1 (view passthrough)
--         ├ gold_product_opportunity_universe_v1
--         └ gold_query_competitor_weekly_v1
--             └ gold_competitor_overlap_score_v1
-- Fora do cascade (CREATE OR REPLACE, sem drop): dim_market_asin_v1 (view direta) e
-- gold_brand_analytics_market_query_v1 (view lida por mv_brand_analytics_market_query_v1
-- via SELECT *, então basta REPLACE + REFRESH).

-- ==========================================================================
-- (A) dim_market_asin_v1 — view direta sobre a fonte. CREATE OR REPLACE (sem cascade).
-- ==========================================================================
CREATE OR REPLACE VIEW marketcloud_gold.dim_market_asin_v1 AS
WITH st AS (
  SELECT
    upper(trim(clicked_asin))                              AS asin,
    search_term                                            AS search_query,
    period_start, period_end,
    click_share_rank                                       AS click_rank,
    COALESCE(click_share,0)::float8                        AS click_share,
    COALESCE(conversion_share,0)::float8                   AS conversion_share,
    max(clicked_item_name) OVER (PARTITION BY upper(trim(clicked_asin))) AS item_name
  FROM swarm_src.amazon_brand_analytics_search_terms
  WHERE COALESCE(clicked_asin,'') <> ''
),
ours AS (
  SELECT DISTINCT upper(trim(asin)) AS asin FROM marketcloud_gold.dim_ba_brand_asin_v1 WHERE COALESCE(asin,'') <> ''
)
SELECT
  st.asin,
  max(st.item_name)                                        AS item_name,
  min(st.period_start)                                     AS first_seen,
  max(st.period_end)                                       AS last_seen,
  count(DISTINCT st.search_query)                          AS queries_count,
  count(*) FILTER (WHERE st.click_rank = 1)                AS top1_count,
  count(*) FILTER (WHERE st.click_rank <= 3)               AS top3_count,
  round(avg(st.click_share)::numeric, 4)                   AS avg_click_share,
  round(avg(st.conversion_share)::numeric, 4)             AS avg_conversion_share,
  (o.asin IS NOT NULL)                                     AS is_zanom
FROM st LEFT JOIN ours o ON o.asin = st.asin
GROUP BY st.asin, o.asin;

-- ==========================================================================
-- (B) gold_brand_analytics_market_query_v1 — view lida pela MV mv_brand_analytics_market_query.
--     CREATE OR REPLACE (mesmas colunas) → MV segue válida → REFRESH no fim.
-- ==========================================================================
CREATE OR REPLACE VIEW marketcloud_gold.gold_brand_analytics_market_query_v1 AS
WITH ours AS (
  SELECT DISTINCT asin FROM marketcloud_gold.dim_ba_brand_asin_v1 WHERE COALESCE(asin,'') ILIKE 'B0%'
),
ranked AS (
  SELECT
    search_term                    AS search_query,
    clicked_asin                   AS asin,
    clicked_item_name              AS item_name,
    search_frequency_rank          AS query_rank,
    click_share                    AS brand_click_share,
    conversion_share               AS brand_purchase_share,
    period_start, period_end,
    row_number() OVER (PARTITION BY search_term
      ORDER BY COALESCE(conversion_share,0) DESC, COALESCE(click_share,0) DESC, clicked_asin) AS asin_rank
  FROM swarm_src.amazon_brand_analytics_search_terms
  WHERE COALESCE(search_term,'') <> ''
),
summary AS (
  SELECT
    search_query,
    min(query_rank)                                                       AS best_rank,
    count(DISTINCT asin)::integer                                         AS asin_count,
    count(DISTINCT asin) FILTER (WHERE asin IN (SELECT asin FROM ours))::integer AS our_asin_count,
    avg(NULLIF(brand_click_share,0))                                      AS avg_click_share,
    avg(NULLIF(brand_purchase_share,0))                                   AS avg_purchase_share,
    min(period_start)                                                     AS period_start,
    max(period_end)                                                       AS period_end
  FROM ranked GROUP BY search_query
)
SELECT
  s.search_query, s.best_rank, s.asin_count, s.our_asin_count,
  s.avg_click_share, s.avg_purchase_share, s.period_start, s.period_end,
  COALESCE(jsonb_agg(jsonb_build_object('asin', r.asin, 'item_name', r.item_name,
    'click_share', r.brand_click_share, 'purchase_share', r.brand_purchase_share, 'rank', r.query_rank)
    ORDER BY r.asin_rank) FILTER (WHERE r.asin_rank <= 5), '[]'::jsonb) AS top_asins
FROM summary s
LEFT JOIN ranked r ON r.search_query = s.search_query AND r.asin_rank <= 5
GROUP BY s.search_query, s.best_rank, s.asin_count, s.our_asin_count, s.avg_click_share, s.avg_purchase_share, s.period_start, s.period_end;

-- ==========================================================================
-- (C) mv_gold_market_search_weekly_v1 — inlina a query da SQP. DROP CASCADE + recria
--     a MV (nova fonte, mesmas colunas) + índices + as 4 views do cascade verbatim.
-- ==========================================================================
DROP MATERIALIZED VIEW marketcloud_gold.mv_gold_market_search_weekly_v1 CASCADE;

CREATE MATERIALIZED VIEW marketcloud_gold.mv_gold_market_search_weekly_v1 AS
WITH st AS (
  SELECT
    period_start, period_end,
    search_term                             AS search_query,
    upper(trim(clicked_asin))               AS asin,
    click_share_rank                        AS click_rank,
    COALESCE(search_frequency_rank,0)       AS search_frequency_rank,
    COALESCE(click_share,0)::float8         AS click_share,
    COALESCE(conversion_share,0)::float8    AS conversion_share
  FROM swarm_src.amazon_brand_analytics_search_terms
  WHERE COALESCE(search_term,'') <> ''
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
  FROM st GROUP BY period_start, period_end, search_query
)
SELECT
  period_start, period_end, search_query, search_frequency_rank,
  top1_asin, top1_click_share, top1_conversion_share,
  top2_asin, top2_click_share, top2_conversion_share,
  top3_asin, top3_click_share, top3_conversion_share,
  top3_click_concentration, top3_conversion_concentration,
  CASE
    WHEN top3_click_concentration >= 0.80 THEN 'HIGHLY_CONCENTRATED'
    WHEN top3_click_concentration >= 0.60 THEN 'CONCENTRATED'
    WHEN top3_click_concentration >= 0.40 THEN 'FRAGMENTED'
    ELSE 'HIGHLY_FRAGMENTED'
  END AS market_concentration_class,
  lag(search_frequency_rank) OVER (PARTITION BY search_query ORDER BY period_start) - search_frequency_rank AS rank_change_wow
FROM agg a;

CREATE UNIQUE INDEX uq_mv_market_search_weekly ON marketcloud_gold.mv_gold_market_search_weekly_v1 (period_start, period_end, search_query);
CREATE INDEX ix_mv_market_search_top1 ON marketcloud_gold.mv_gold_market_search_weekly_v1 (top1_asin);

-- passthrough (nome estável)
CREATE VIEW marketcloud_gold.gold_market_search_weekly_v1 AS
  SELECT period_start, period_end, search_query, search_frequency_rank,
    top1_asin, top1_click_share, top1_conversion_share,
    top2_asin, top2_click_share, top2_conversion_share,
    top3_asin, top3_click_share, top3_conversion_share,
    top3_click_concentration, top3_conversion_concentration,
    market_concentration_class, rank_change_wow
  FROM marketcloud_gold.mv_gold_market_search_weekly_v1;

-- §26+ opportunity universe (verbatim, fonte = view passthrough)
CREATE VIEW marketcloud_gold.gold_product_opportunity_universe_v1 AS
WITH zanom AS (
  SELECT DISTINCT upper(trim(asin)) AS asin FROM marketcloud_gold.dim_ba_brand_asin_v1 WHERE COALESCE(asin,'') <> ''
)
SELECT
  period_start, period_end, search_query, search_frequency_rank,
  top1_asin, top1_click_share, top3_click_concentration, market_concentration_class,
  (top1_asin IN (SELECT asin FROM zanom)) OR (top2_asin IN (SELECT asin FROM zanom)) OR (top3_asin IN (SELECT asin FROM zanom)) AS zanom_in_top3,
  rank_change_wow
FROM marketcloud_gold.gold_market_search_weekly_v1 m;

-- §46 query competitor weekly (verbatim, fonte = view passthrough)
CREATE VIEW marketcloud_gold.gold_query_competitor_weekly_v1 AS
WITH zq AS (
  SELECT DISTINCT lower(btrim(search_query)) AS qn FROM marketcloud_gold.gold_brand_query_weekly_v1 WHERE search_query IS NOT NULL
),
mkt AS (
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
brand_asins AS (
  SELECT DISTINCT asin FROM marketcloud_gold.dim_ba_brand_asin_v1
)
SELECT
  m.period_start, m.period_end, m.search_query, m.search_frequency_rank,
  m.competitor_asin, m.competitor_rank,
  m.click_share AS competitor_click_share, m.conversion_share AS competitor_conversion_share,
  (m.competitor_asin IN (SELECT asin FROM brand_asins)) AS is_zanom
FROM mkt m JOIN zq ON zq.qn = m.qn;

-- §47 competitor overlap score (verbatim, fonte = query competitor weekly)
CREATE VIEW marketcloud_gold.gold_competitor_overlap_score_v1 AS
SELECT
  competitor_asin,
  count(DISTINCT search_query)                                       AS queries_shared_with_zanom,
  count(DISTINCT search_query) FILTER (WHERE competitor_rank = 1)    AS queries_where_top1,
  count(DISTINCT search_query) FILTER (WHERE competitor_rank <= 3)   AS queries_where_top3,
  round(avg(competitor_click_share)::numeric, 4)                     AS avg_click_share,
  round(avg(competitor_conversion_share)::numeric, 4)               AS avg_conversion_share,
  round(sum(competitor_click_share)::numeric, 4)                     AS weighted_overlap
FROM marketcloud_gold.gold_query_competitor_weekly_v1
WHERE NOT is_zanom AND competitor_asin IS NOT NULL
GROUP BY competitor_asin
ORDER BY count(DISTINCT search_query) DESC, round(sum(competitor_click_share)::numeric, 4) DESC;

-- refresh a MV que passou a ler a view (B) repontada
REFRESH MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_market_query_v1;
