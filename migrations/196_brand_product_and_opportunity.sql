-- 196 — fecha Fase 1 (§44 opportunity universe) + gold de produto da marca (§31/§32).
-- gold_brand_product_weekly agrega o query gold por ASIN com WEIGHTED SHARES (§32:
-- SUM(brand)/SUM(market), nunca AVG dos shares). opportunity_universe (§44) preserva
-- demanda/concorrencia/fragmentacao do mercado pra o Product Discovery futuro.

-- §31/§32 gold de produto da marca (grao marketplace+week+asin)
DROP VIEW IF EXISTS marketcloud_gold.gold_brand_product_weekly_v1 CASCADE;
CREATE VIEW marketcloud_gold.gold_brand_product_weekly_v1 AS
SELECT
  marketplace_id, period_start, period_end, asin,
  count(*)                                             AS queries_count,
  count(*) FILTER (WHERE brand_impressions > 0)        AS active_queries,
  count(*) FILTER (WHERE brand_clicks > 0)             AS queries_with_click,
  count(*) FILTER (WHERE brand_purchases > 0)          AS queries_with_purchase,
  sum(brand_impressions)                               AS search_impressions,
  sum(brand_clicks)                                    AS search_clicks,
  sum(brand_cart_adds)                                 AS search_cart_adds,
  sum(brand_purchases)                                 AS search_purchases,
  -- §32 WEIGHTED shares (ponderadas pelo volume do mercado, nao media simples)
  CASE WHEN sum(market_impressions) > 0 THEN sum(brand_impressions)/sum(market_impressions) END AS weighted_impression_share,
  CASE WHEN sum(market_clicks)      > 0 THEN sum(brand_clicks)/sum(market_clicks)           END AS weighted_click_share,
  CASE WHEN sum(market_cart_adds)   > 0 THEN sum(brand_cart_adds)/sum(market_cart_adds)     END AS weighted_cart_share,
  CASE WHEN sum(market_purchases)   > 0 THEN sum(brand_purchases)/sum(market_purchases)     END AS weighted_purchase_share,
  -- funil agregado
  CASE WHEN sum(brand_impressions) > 0 THEN sum(brand_clicks)/sum(brand_impressions) END    AS search_ctr,
  CASE WHEN sum(brand_clicks)      > 0 THEN sum(brand_purchases)/sum(brand_clicks)   END    AS search_conversion,
  (array_agg(search_query ORDER BY search_query_volume DESC NULLS LAST))[1]                 AS top_query_by_volume,
  (array_agg(search_query ORDER BY brand_purchases DESC NULLS LAST))[1]                     AS top_query_by_purchase
FROM marketcloud_gold.gold_brand_query_weekly_v1
GROUP BY marketplace_id, period_start, period_end, asin;

COMMENT ON VIEW marketcloud_gold.gold_brand_product_weekly_v1 IS
  'Gold de produto da marca (§31): funil agregado por ASIN + WEIGHTED shares (§32, SUM/SUM nao AVG). Fonte gold_brand_query_weekly.';

-- §44 fundacao do Product Discovery: preserva sinal de mercado por termo pra scoring futuro
DROP VIEW IF EXISTS marketcloud_gold.gold_product_opportunity_universe_v1 CASCADE;
CREATE VIEW marketcloud_gold.gold_product_opportunity_universe_v1 AS
WITH zanom AS (SELECT DISTINCT upper(trim(asin)) asin FROM marketcloud_gold.dim_ba_brand_asin_v1 WHERE COALESCE(asin,'') <> '')
SELECT
  m.period_start, m.period_end, m.search_query,
  m.search_frequency_rank,                                    -- DEMANDA (ordinal Amazon, §78)
  m.top1_asin, m.top1_click_share,
  m.top3_click_concentration,                                 -- CONCORRENCIA/CONCENTRACAO
  m.market_concentration_class,                               -- FRAGMENTACAO (§25)
  -- presenca ZANOM: hoje aparece no top3 deste termo de mercado?
  (m.top1_asin IN (SELECT asin FROM zanom)
   OR m.top2_asin IN (SELECT asin FROM zanom)
   OR m.top3_asin IN (SELECT asin FROM zanom))               AS zanom_in_top3,
  m.rank_change_wow
FROM marketcloud_gold.gold_market_search_weekly_v1 m;

COMMENT ON VIEW marketcloud_gold.gold_product_opportunity_universe_v1 IS
  'Fundacao do Product Discovery (§44): por termo de mercado preserva demanda (rank), concorrencia (top1/concentracao), fragmentacao (classe) e presenca ZANOM. Base pra Opportunity Score futuro; sem decisao automatica.';
