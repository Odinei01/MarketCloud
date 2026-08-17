-- 206_query_catalog_reconciliation.sql
-- §22: Reconciliacao Query x Catalog. Para cada ASIN x semana, compara a SOMA das
-- metricas de marca do Search Query (E001) com as metricas do Search Catalog (E002).
-- Os universos Amazon nao sao perfeitamente equivalentes -> diferenca NAO e erro;
-- e exploratorio. Status: MATCH / MINOR_VARIANCE / MAJOR_VARIANCE / NOT_COMPARABLE.
-- Thresholds default (5% / 20%), calibraveis depois.
CREATE OR REPLACE VIEW marketcloud_gold.v_brand_query_catalog_reconciliation_v1 AS
WITH q AS (
    SELECT asin, period_start, period_end,
           sum(brand_impressions) AS q_impr, sum(brand_clicks) AS q_clk,
           sum(brand_cart_adds) AS q_cart, sum(brand_purchases) AS q_purch,
           count(*) AS q_queries
    FROM marketcloud_gold.gold_brand_query_weekly_v1
    GROUP BY asin, period_start, period_end
),
cat AS (
    SELECT asin, period_start, period_end,
           catalog_impressions AS c_impr, catalog_clicks AS c_clk,
           catalog_cart_adds AS c_cart, catalog_purchases AS c_purch
    FROM marketcloud_silver.silver_brand_analytics_catalog_product_v1
)
SELECT
    COALESCE(q.asin, cat.asin) AS asin,
    COALESCE(q.period_start, cat.period_start) AS period_start,
    COALESCE(q.period_end, cat.period_end) AS period_end,
    q.q_queries, q.q_impr, q.q_clk, q.q_cart, q.q_purch,
    cat.c_impr, cat.c_clk, cat.c_cart, cat.c_purch,
    -- variancia relativa por metrica (base = catalog, o universo "todas as buscas")
    round((abs(q.q_clk   - cat.c_clk)   / NULLIF(cat.c_clk,0)  * 100)::numeric, 1) AS clicks_variance_pct,
    round((abs(q.q_purch - cat.c_purch) / NULLIF(cat.c_purch,0)* 100)::numeric, 1) AS purchases_variance_pct,
    CASE
      WHEN q.asin IS NULL OR cat.asin IS NULL THEN 'NOT_COMPARABLE'
      WHEN COALESCE(cat.c_clk,0) = 0 THEN 'NOT_COMPARABLE'
      WHEN abs(q.q_clk - cat.c_clk) / NULLIF(cat.c_clk,0) <= 0.05 THEN 'MATCH'
      WHEN abs(q.q_clk - cat.c_clk) / NULLIF(cat.c_clk,0) <= 0.20 THEN 'MINOR_VARIANCE'
      ELSE 'MAJOR_VARIANCE'
    END AS reconciliation_status
FROM q FULL OUTER JOIN cat
  ON q.asin = cat.asin AND q.period_start = cat.period_start AND q.period_end = cat.period_end;

COMMENT ON VIEW marketcloud_gold.v_brand_query_catalog_reconciliation_v1 IS
 '§22 Reconciliacao Query(E001) x Catalog(E002) por ASIN x semana. Exploratorio: universos Amazon nao equivalentes, diferenca nao e erro. Status MATCH/MINOR/MAJOR/NOT_COMPARABLE.';
