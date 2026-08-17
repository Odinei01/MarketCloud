-- 204_brand_analytics_data_quality.sql
-- FASE 4 (infra) — DATA-QUALITY GATE do Brand Analytics (§11/§55/§56).
-- Filosofia (mesma do FINANCIAL_DATA_UNRELIABLE): provar o dado antes de confiar.
-- Cada checagem devolve status OK/WARN/FAIL + metrica + detalhe. Hoje o dado passa
-- (shares percentuais 0-100 consistentes, funil monotonico, price index > 0); a
-- view existe como GATE GO-FORWARD: pega o dia que a ingestao quebrar/mudar unidade.
-- Convencao confirmada: shares em PERCENTUAL (0-100); lifts e labels comparam
-- share vs share (mesma unidade) -> consistente.

CREATE OR REPLACE VIEW marketcloud_gold.v_brand_analytics_data_quality AS
WITH b AS (SELECT * FROM marketcloud_gold.gold_brand_query_weekly_v1),
today AS (SELECT (now() AT TIME ZONE 'America/Sao_Paulo')::date AS d)
-- 1) FRESHNESS: dado semanal; alerta se a ultima semana fechada tem > 12 dias
SELECT 'freshness' AS check_name,
       CASE WHEN max(period_end) IS NULL THEN 'FAIL'
            WHEN (SELECT d FROM today) - max(period_end) > 21 THEN 'FAIL'
            WHEN (SELECT d FROM today) - max(period_end) > 12 THEN 'WARN'
            ELSE 'OK' END AS status,
       ((SELECT d FROM today) - max(period_end))::text || ' dias desde a ultima semana' AS detail,
       max(period_end)::text AS metric
FROM b
UNION ALL
-- 2) SHARE BOUNDS: percentuais devem ficar em [0,100]
SELECT 'share_bounds',
       CASE WHEN count(*) FILTER (WHERE brand_click_share < 0 OR brand_click_share > 100
             OR brand_impression_share < 0 OR brand_impression_share > 100
             OR brand_purchase_share < 0 OR brand_purchase_share > 100) > 0 THEN 'FAIL' ELSE 'OK' END,
       count(*) FILTER (WHERE brand_click_share < 0 OR brand_click_share > 100)::text || ' shares fora de [0,100]',
       count(*)::text || ' linhas'
FROM b
UNION ALL
-- 3) FUNIL MONOTONICO: impressao >= clique >= cart >= compra (contagens da marca)
SELECT 'funnel_monotonicity',
       CASE WHEN count(*) FILTER (WHERE brand_impressions < brand_clicks
             OR brand_clicks < brand_cart_adds OR brand_cart_adds < brand_purchases) > 0 THEN 'FAIL' ELSE 'OK' END,
       count(*) FILTER (WHERE brand_impressions < brand_clicks
             OR brand_clicks < brand_cart_adds OR brand_cart_adds < brand_purchases)::text || ' funis invertidos',
       count(*)::text || ' linhas'
FROM b
UNION ALL
-- 4) PRICE INDEX POSITIVO onde ha preco
SELECT 'price_index_positive',
       CASE WHEN count(*) FILTER (WHERE click_price_index < 0 OR purchase_price_index < 0) > 0 THEN 'FAIL' ELSE 'OK' END,
       count(*) FILTER (WHERE click_price_index < 0 OR purchase_price_index < 0)::text || ' price index negativo',
       count(*) FILTER (WHERE click_price_index IS NOT NULL)::text || ' com price index'
FROM b
UNION ALL
-- 5) COBERTURA DE MARCA: quantos ASINs de marca com dado (esperado ~12 registrados)
SELECT 'brand_coverage',
       CASE WHEN count(DISTINCT asin) = 0 THEN 'FAIL'
            WHEN count(DISTINCT asin) < 5 THEN 'WARN' ELSE 'OK' END,
       count(DISTINCT asin)::text || ' ASINs de marca com dado',
       count(DISTINCT asin)::text || ' asins'
FROM b
UNION ALL
-- 6) UNIVERSO: ambos os dominios presentes na origem (marca + mercado nao misturam)
SELECT 'universe_presence',
       CASE WHEN count(*) FILTER (WHERE data_domain='PROPRIETARY_SEARCH_QUERY') = 0
             OR count(*) FILTER (WHERE data_domain='MARKET_SEARCH_TERMS') = 0 THEN 'WARN' ELSE 'OK' END,
       'marca=' || count(*) FILTER (WHERE data_domain='PROPRIETARY_SEARCH_QUERY')::text
             || ' / mercado=' || count(*) FILTER (WHERE data_domain='MARKET_SEARCH_TERMS')::text,
       count(*)::text || ' linhas na origem'
FROM swarm_src.amazon_brand_analytics_search_query_performance;

COMMENT ON VIEW marketcloud_gold.v_brand_analytics_data_quality IS
 'Data-quality gate do Brand Analytics (Fase 4). 6 checagens OK/WARN/FAIL sobre o gold de marca + universo da origem. Gate go-forward: hoje passa, pega quebra futura de ingestao/unidade.';
