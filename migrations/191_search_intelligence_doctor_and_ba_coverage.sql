-- 191: Search Intelligence Fase 3/4.
-- Fase 3: Query Doctor explicativo (sem action matrix).
-- Fase 4: cobertura didatica Brand Analytics / fontes minimas por ASIN.

CREATE SCHEMA IF NOT EXISTS marketcloud_gold;

DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_query_doctor_v1;
DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_asin_source_coverage_v1;
DROP VIEW IF EXISTS marketcloud_gold.gold_search_intelligence_ba_coverage_summary_v1;

CREATE OR REPLACE VIEW marketcloud_gold.gold_search_intelligence_asin_source_coverage_v1 AS
SELECT
  asin,
  product_name,
  seller_sku,
  gross_sales,
  total_units,
  total_orders,
  ebitda_estimated,
  ebitda_margin,
  finance_status,
  scp_status,
  sqp_status,
  ads_search_terms_status,
  minimum_decision_status,
  scp_impressions,
  scp_clicks,
  scp_cart_adds,
  scp_purchases,
  scp_sales,
  scp_ctr,
  scp_click_to_purchase_cvr,
  sqp_query_rows,
  sqp_impressions,
  sqp_clicks,
  sqp_cart_adds,
  sqp_purchases,
  sqp_avg_impression_share,
  sqp_avg_click_share,
  sqp_avg_cart_add_share,
  sqp_avg_purchase_share,
  ads_search_terms,
  ads_search_term_spend,
  ads_search_term_orders,
  ads_search_term_sales,
  ads_search_term_roas,
  (
    CASE WHEN finance_status IN ('READY','PARTIAL') THEN 1 ELSE 0 END
    + CASE WHEN scp_status = 'READY' THEN 1 ELSE 0 END
    + CASE WHEN sqp_status = 'READY' THEN 1 ELSE 0 END
    + CASE WHEN ads_search_terms_status = 'READY' THEN 1 ELSE 0 END
  )::int AS ready_source_count,
  jsonb_strip_nulls(jsonb_build_object(
    'financeiro_asin', CASE WHEN finance_status IN ('READY','PARTIAL') THEN NULL ELSE 'Sem venda/custo suficiente na camada financeira por ASIN' END,
    'scp_catalogo_asin', CASE WHEN scp_status = 'READY' THEN NULL ELSE 'SCP por ASIN ausente: sem funil absoluto de busca do produto' END,
    'sqp_proprietario_asin', CASE WHEN sqp_status = 'READY' THEN NULL ELSE 'SQP proprietario por ASIN/query ausente: sem share proprietario por busca' END,
    'ads_search_terms', CASE WHEN ads_search_terms_status = 'READY' THEN NULL ELSE 'Ads Search Terms nao resolveu termos para este ASIN' END
  )) AS missing_sources_json,
  CASE
    WHEN minimum_decision_status = 'READY_FOR_DECISION' THEN 'COBERTURA_COMPLETA'
    WHEN finance_status IN ('READY','PARTIAL') AND scp_status = 'READY' AND ads_search_terms_status = 'READY' THEN 'COBERTURA_OPERACIONAL_SEM_SQP'
    WHEN finance_status IN ('READY','PARTIAL') AND ads_search_terms_status = 'READY' THEN 'ADS_E_FINANCEIRO_SEM_BA_COMPLETO'
    WHEN finance_status IN ('READY','PARTIAL') THEN 'FINANCEIRO_APENAS'
    ELSE 'COBERTURA_INSUFICIENTE'
  END AS coverage_label
FROM marketcloud_gold.gold_search_intelligence_minimum_decision_matrix_v1;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_asin_source_coverage_v1 IS
'Cobertura por ASIN das fontes minimas: financeiro, SCP, SQP proprietario e Ads Search Terms. Explica lacunas; nao decide acao.';

CREATE OR REPLACE VIEW marketcloud_gold.gold_search_intelligence_ba_coverage_summary_v1 AS
WITH m AS (
  SELECT * FROM marketcloud_gold.gold_search_intelligence_asin_source_coverage_v1
)
SELECT
  'FINANCEIRO_ASIN'::text AS source_key,
  'Financeiro do ASIN'::text AS source_label,
  count(*)::int AS total_asins,
  count(*) FILTER (WHERE finance_status IN ('READY','PARTIAL'))::int AS ready_asins,
  count(*) FILTER (WHERE finance_status = 'MISSING')::int AS missing_asins,
  sum(gross_sales)::numeric AS gross_sales,
  sum(total_units)::numeric AS total_units,
  sum(total_orders)::numeric AS total_orders,
  null::numeric AS impressions,
  null::numeric AS clicks,
  null::numeric AS purchases,
  'Receita, unidades, CMV, fees, imposto, COPER, Ads e EBITDA por ASIN.'::text AS explanation
FROM m
UNION ALL
SELECT
  'SEARCH_CATALOG_PERFORMANCE',
  'SCP por ASIN',
  count(*)::int,
  count(*) FILTER (WHERE scp_status = 'READY')::int,
  count(*) FILTER (WHERE scp_status <> 'READY')::int,
  null::numeric,
  null::numeric,
  null::numeric,
  sum(scp_impressions)::numeric,
  sum(scp_clicks)::numeric,
  sum(scp_purchases)::numeric,
  'Funil absoluto do produto: impressoes, cliques, carrinhos, compras, vendas e CVR. Nao traz share competitivo.'
FROM m
UNION ALL
SELECT
  'SEARCH_QUERY_PERFORMANCE',
  'SQP proprietario por ASIN/query',
  count(*)::int,
  count(*) FILTER (WHERE sqp_status = 'READY')::int,
  count(*) FILTER (WHERE sqp_status <> 'READY')::int,
  null::numeric,
  null::numeric,
  null::numeric,
  sum(sqp_impressions)::numeric,
  sum(sqp_clicks)::numeric,
  sum(sqp_purchases)::numeric,
  'Share proprietario por busca/ASIN. E o principal gargalo quando a Amazon ainda retorna zero linhas.'
FROM m
UNION ALL
SELECT
  'ADS_SEARCH_TERMS',
  'Ads Search Terms por ASIN',
  count(*)::int,
  count(*) FILTER (WHERE ads_search_terms_status = 'READY')::int,
  count(*) FILTER (WHERE ads_search_terms_status <> 'READY')::int,
  sum(ads_search_term_sales)::numeric,
  null::numeric,
  sum(ads_search_term_orders)::numeric,
  null::numeric,
  null::numeric,
  sum(ads_search_term_orders)::numeric,
  'Termos comprados em Ads, custo, pedidos, vendas, ROAS e ACOS por ASIN resolvido.'
FROM m
UNION ALL
SELECT
  'BRAND_QUERY_COMPREHENSIVE',
  'Brand Query Comprehensive',
  count(DISTINCT search_query)::int,
  count(DISTINCT search_query) FILTER (WHERE search_query_volume IS NOT NULL)::int,
  0::int,
  null::numeric,
  null::numeric,
  null::numeric,
  sum(impression_total_count)::numeric,
  sum(click_total_count)::numeric,
  sum(purchase_total_count)::numeric,
  'Dado de mercado por query: volume, shares de marca, precos medianos e competicao. Nao e funil proprietario por ASIN.'
FROM marketcloud_gold.mv_brand_analytics_brand_query_comprehensive_v1;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_ba_coverage_summary_v1 IS
'Resumo didatico das fontes Brand Analytics/Search Intelligence e suas lacunas atuais.';

CREATE OR REPLACE VIEW marketcloud_gold.gold_search_intelligence_query_doctor_v1 AS
SELECT
  q.asin,
  q.campaign_id,
  q.seller_sku,
  q.product_name,
  q.query_key,
  q.search_query,
  q.campaign_name,
  q.ad_group_name,
  q.keyword_or_target,
  q.match_type,
  q.ads_impressions,
  q.ads_clicks,
  q.ads_spend,
  q.ads_orders,
  q.ads_sales,
  q.ads_cpc,
  q.ads_roas,
  q.ads_ctr,
  q.ads_cvr,
  q.gross_sales,
  q.total_units,
  q.ebitda_estimated,
  q.ebitda_margin,
  q.current_price,
  q.avg_realized_price,
  q.scp_impressions,
  q.scp_clicks,
  q.scp_cart_adds,
  q.scp_purchases,
  q.scp_ctr,
  q.scp_cvr,
  q.search_query_volume,
  q.brand_impression_share,
  q.brand_click_share,
  q.brand_cart_share,
  q.brand_purchase_share,
  q.brand_purchase_share_lift,
  q.query_purchase_median_price,
  q.brand_purchase_median_price,
  q.competitor_count,
  q.top_competitor_click_share,
  q.top_competitor_purchase_share,
  q.competitors,
  q.ml_computed_at,
  q.ml_cells,
  q.ml_max_click_probability,
  q.ml_max_conversion_probability,
  q.ml_max_expected_roas,
  q.ml_best_hour,
  q.spend_7d_lag,
  q.orders_7d_lag,
  q.sales_7d_lag,
  q.roas_7d_lag,
  q.spend_28d_lag,
  q.orders_28d_lag,
  q.sales_28d_lag,
  q.roas_28d_lag,
  q.ml_explain_label,
  q.ml_explain_score,
  c.coverage_label,
  c.finance_status,
  c.scp_status,
  c.sqp_status,
  c.ads_search_terms_status,
  c.missing_sources_json,
  CASE
    WHEN q.ml_cells > 0 AND q.competitor_count > 0 AND q.search_query_volume IS NOT NULL THEN 'ML_COMPETITION_AND_MARKET'
    WHEN q.ml_cells > 0 THEN 'ML_ONLY'
    WHEN q.competitor_count > 0 AND q.search_query_volume IS NOT NULL THEN 'MARKET_COMPETITION_ONLY'
    WHEN q.ads_spend > 0 THEN 'ADS_FACT_ONLY'
    ELSE 'LOW_SIGNAL'
  END AS doctor_evidence_class,
  jsonb_build_object(
    'ml', jsonb_build_object(
      'cells', q.ml_cells,
      'expected_roas', q.ml_max_expected_roas,
      'conversion_probability', q.ml_max_conversion_probability,
      'best_hour', q.ml_best_hour,
      'label', q.ml_explain_label
    ),
    'ads', jsonb_build_object(
      'spend', q.ads_spend,
      'orders', q.ads_orders,
      'sales', q.ads_sales,
      'roas', q.ads_roas,
      'cpc', q.ads_cpc
    ),
    'brand_analytics', jsonb_build_object(
      'query_volume', q.search_query_volume,
      'brand_impression_share', q.brand_impression_share,
      'brand_click_share', q.brand_click_share,
      'brand_cart_share', q.brand_cart_share,
      'brand_purchase_share', q.brand_purchase_share,
      'query_purchase_median_price', q.query_purchase_median_price
    ),
    'competitors', jsonb_build_object(
      'count', q.competitor_count,
      'top_click_share', q.top_competitor_click_share,
      'top_purchase_share', q.top_competitor_purchase_share,
      'items', q.competitors
    ),
    'coverage', jsonb_build_object(
      'label', c.coverage_label,
      'finance', c.finance_status,
      'scp', c.scp_status,
      'sqp', c.sqp_status,
      'ads_search_terms', c.ads_search_terms_status,
      'missing', c.missing_sources_json
    )
  ) AS doctor_json
FROM marketcloud_gold.gold_search_intelligence_asin_query_v1 q
LEFT JOIN marketcloud_gold.gold_search_intelligence_asin_source_coverage_v1 c
  ON c.asin = q.asin;

COMMENT ON VIEW marketcloud_gold.gold_search_intelligence_query_doctor_v1 IS
'Doutor de Query: evidencia explicativa ASIN/query para UI e ML. Nao contem recomendacao deterministica nem action matrix.';
