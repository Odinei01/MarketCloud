-- 184: cache local para Search Intelligence.
-- Evita que a tela dependa de views FDW pesadas em cada abertura.

DROP MATERIALIZED VIEW IF EXISTS marketcloud_gold.mv_brand_analytics_market_query_v1;
CREATE MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_market_query_v1 AS
SELECT *
FROM marketcloud_gold.gold_brand_analytics_market_query_v1;

CREATE INDEX IF NOT EXISTS idx_mv_ba_market_query_period
  ON marketcloud_gold.mv_brand_analytics_market_query_v1 (period_start, period_end);
CREATE INDEX IF NOT EXISTS idx_mv_ba_market_query_order
  ON marketcloud_gold.mv_brand_analytics_market_query_v1 (best_rank, avg_purchase_share, avg_click_share);

DROP MATERIALIZED VIEW IF EXISTS marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1;
CREATE MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1 AS
SELECT *
FROM marketcloud_gold.gold_brand_analytics_brand_query_comprehensive_v1;

CREATE INDEX IF NOT EXISTS idx_mv_ba_brand_query_period
  ON marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1 (period_start, period_end);
CREATE INDEX IF NOT EXISTS idx_mv_ba_brand_query_order
  ON marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1 (query_score, purchase_brand_count, search_query_volume);

DROP MATERIALIZED VIEW IF EXISTS marketcloud_gold.mv_search_intelligence_minimum_source_status_v1;
CREATE MATERIALIZED VIEW marketcloud_gold.mv_search_intelligence_minimum_source_status_v1 AS
SELECT *
FROM marketcloud_gold.gold_search_intelligence_minimum_source_status_v1;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_si_min_source_key
  ON marketcloud_gold.mv_search_intelligence_minimum_source_status_v1 (source_key);

CREATE OR REPLACE FUNCTION marketcloud_gold.refresh_search_intelligence_cache_v1()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_market_query_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_search_intelligence_minimum_source_status_v1;
END;
$$;

COMMENT ON MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_market_query_v1 IS
'Cache local da demanda/concorrencia por query para a tela Search Intelligence.';

COMMENT ON MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1 IS
'Cache local do relatorio Exibicao de marca Abrangente para a tela Search Intelligence.';

COMMENT ON MATERIALIZED VIEW marketcloud_gold.mv_search_intelligence_minimum_source_status_v1 IS
'Cache local do status das 4 fontes minimas para automatizacao.';
