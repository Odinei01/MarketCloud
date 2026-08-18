-- 214: materializa as 4 views pesadas da Search Intelligence que travavam a pagina
-- (query_doctor 3m20s, competitor_radar 1m27s, product_daily 30s, coverage 20s).
-- Sao views LIVE que computam ads+ML+concorrente sobre FDW a cada request. Mesmo
-- padrao da migration 203 (market_search/brand_query): snapshot em MV + refresh no
-- refresh_brand_analytics_gold() diario. Pagina passa de ~3min pra sub-segundo.
-- Snapshot via SELECT * (nao reimplementa a logica; a view segue a fonte de verdade).

CREATE MATERIALIZED VIEW IF NOT EXISTS marketcloud_gold.mv_gold_search_intelligence_product_daily_v1 AS
  SELECT * FROM marketcloud_gold.gold_search_intelligence_product_daily_v1;

CREATE MATERIALIZED VIEW IF NOT EXISTS marketcloud_gold.mv_gold_search_intelligence_query_doctor_v1 AS
  SELECT * FROM marketcloud_gold.gold_search_intelligence_query_doctor_v1;

CREATE MATERIALIZED VIEW IF NOT EXISTS marketcloud_gold.mv_gold_search_intelligence_competitor_radar_v1 AS
  SELECT * FROM marketcloud_gold.gold_search_intelligence_competitor_radar_v1;

CREATE MATERIALIZED VIEW IF NOT EXISTS marketcloud_gold.mv_gold_search_intelligence_asin_source_coverage_v1 AS
  SELECT * FROM marketcloud_gold.gold_search_intelligence_asin_source_coverage_v1;

-- indices leves p/ os filtros que os endpoints aplicam (asin/data_date)
CREATE INDEX IF NOT EXISTS ix_mv_si_product_daily_asin_date ON marketcloud_gold.mv_gold_search_intelligence_product_daily_v1 (asin, data_date);
CREATE INDEX IF NOT EXISTS ix_mv_si_query_doctor_asin ON marketcloud_gold.mv_gold_search_intelligence_query_doctor_v1 (asin);
CREATE INDEX IF NOT EXISTS ix_mv_si_query_doctor_class ON marketcloud_gold.mv_gold_search_intelligence_query_doctor_v1 (doctor_evidence_class);

-- entra no refresh diario (nao-CONCURRENTLY, coerente com o resto da funcao).
-- Inclui tambem mv_brand_analytics_market_query, que estava fora do refresh.
CREATE OR REPLACE FUNCTION marketcloud_gold.refresh_brand_analytics_gold()
RETURNS text LANGUAGE plpgsql AS $function$
BEGIN
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_market_search_weekly_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_brand_query_weekly_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_brand_analytics_market_query_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_product_daily_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_query_doctor_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_competitor_radar_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_search_intelligence_asin_source_coverage_v1;
  RETURN 'brand_analytics_gold refreshed at '||now();
END;
$function$;
