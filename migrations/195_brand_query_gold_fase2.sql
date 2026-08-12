-- 195 — Fase 2 (lado MARCA da spec). O E001 agora traz dado real (searchQueryData
-- aninhado, medianas marca+mercado, totais). Aqui expomos as colunas novas no FDW e
-- construimos o gold central de query da marca: funil marca+mercado, share lift (§17),
-- price index (§18), signal_strength (§41) e classificacao como ROTULO DE FUNIL (§40).
--
-- IMPORTANTE (regra do dono): a classificacao e FATO descritivo do funil, nao decisao.
-- Nao aciona bid/preco; e sinal pro ML/telas. Decisao continua no ML/guardrails.
-- Shares vem em PERCENT crus da Amazon; lift/price-index sao razoes (unidade cancela).

-- 1) expor colunas novas do E001 no FDW
ALTER FOREIGN TABLE swarm_src.amazon_brand_analytics_search_query_performance
  ADD COLUMN IF NOT EXISTS total_impressions numeric,
  ADD COLUMN IF NOT EXISTS total_clicks numeric,
  ADD COLUMN IF NOT EXISTS total_cart_adds numeric,
  ADD COLUMN IF NOT EXISTS total_purchases numeric,
  ADD COLUMN IF NOT EXISTS search_query_volume numeric,
  ADD COLUMN IF NOT EXISTS search_query_score numeric,
  ADD COLUMN IF NOT EXISTS brand_median_click_price numeric,
  ADD COLUMN IF NOT EXISTS market_median_click_price numeric,
  ADD COLUMN IF NOT EXISTS brand_median_cart_price numeric,
  ADD COLUMN IF NOT EXISTS market_median_cart_price numeric,
  ADD COLUMN IF NOT EXISTS brand_median_purchase_price numeric,
  ADD COLUMN IF NOT EXISTS market_median_purchase_price numeric;

-- 2) gold central de query da marca (§33 + §16-19 + §40-41)
DROP VIEW IF EXISTS marketcloud_gold.gold_brand_query_weekly_v1 CASCADE;
CREATE VIEW marketcloud_gold.gold_brand_query_weekly_v1 AS
WITH src AS (
  -- §58 is_latest: multiplos report_id pro mesmo (periodo,asin,query) quando o report
  -- e re-disparado; fica so o mais recente (senao weighted shares dobram).
  SELECT DISTINCT ON (period_start, upper(trim(asin)), search_query)
    marketplace_id, period_start, period_end,
    upper(trim(asin)) AS asin,
    search_query,
    COALESCE(search_query_volume,0)::float8      AS search_query_volume,
    COALESCE(search_query_score,0)::float8        AS search_query_score,
    COALESCE(impressions,0)::float8               AS brand_impressions,
    COALESCE(clicks,0)::float8                    AS brand_clicks,
    COALESCE(cart_adds,0)::float8                 AS brand_cart_adds,
    COALESCE(purchases,0)::float8                 AS brand_purchases,
    COALESCE(total_impressions,0)::float8         AS market_impressions,
    COALESCE(total_clicks,0)::float8              AS market_clicks,
    COALESCE(total_cart_adds,0)::float8           AS market_cart_adds,
    COALESCE(total_purchases,0)::float8           AS market_purchases,
    COALESCE(brand_impression_share,0)::float8    AS brand_impression_share,
    COALESCE(brand_click_share,0)::float8         AS brand_click_share,
    COALESCE(brand_cart_add_share,0)::float8      AS brand_cart_add_share,
    COALESCE(brand_purchase_share,0)::float8      AS brand_purchase_share,
    NULLIF(brand_median_click_price,0)::float8    AS brand_median_click_price,
    NULLIF(market_median_click_price,0)::float8   AS market_median_click_price,
    NULLIF(brand_median_purchase_price,0)::float8 AS brand_median_purchase_price,
    NULLIF(market_median_purchase_price,0)::float8 AS market_median_purchase_price
  FROM swarm_src.amazon_brand_analytics_search_query_performance
  WHERE COALESCE(data_domain,'') = 'PROPRIETARY_SEARCH_QUERY'
    AND COALESCE(search_query,'') <> '' AND COALESCE(asin,'') <> ''
  ORDER BY period_start, upper(trim(asin)), search_query, synced_at DESC
),
calc AS (
  SELECT s.*,
    -- §16 funil da marca (protecao denominador zero)
    CASE WHEN brand_impressions>0 THEN brand_clicks/brand_impressions END        AS brand_ctr,
    CASE WHEN brand_clicks>0 THEN brand_cart_adds/brand_clicks END               AS brand_click_to_cart,
    CASE WHEN brand_cart_adds>0 THEN brand_purchases/brand_cart_adds END         AS brand_cart_to_purchase,
    CASE WHEN brand_clicks>0 THEN brand_purchases/brand_clicks END               AS brand_search_conversion,
    -- §17 share lift (>1 marca ganha participacao ao longo do funil)
    CASE WHEN brand_impression_share>0 THEN brand_click_share/brand_impression_share END    AS click_share_lift,
    CASE WHEN brand_impression_share>0 THEN brand_cart_add_share/brand_impression_share END  AS cart_share_lift,
    CASE WHEN brand_impression_share>0 THEN brand_purchase_share/brand_impression_share END  AS purchase_share_lift,
    -- §18 price index (so quando ha os dois precos)
    CASE WHEN brand_median_click_price IS NOT NULL AND market_median_click_price IS NOT NULL AND market_median_click_price>0
         THEN brand_median_click_price/market_median_click_price END                        AS click_price_index,
    CASE WHEN brand_median_purchase_price IS NOT NULL AND market_median_purchase_price IS NOT NULL AND market_median_purchase_price>0
         THEN brand_median_purchase_price/market_median_purchase_price END                  AS purchase_price_index,
    -- §41 signal_strength: forca do sinal PROPRIO (cliques+compras da marca + volume)
    CASE
      WHEN brand_clicks>=30 OR brand_purchases>=5 THEN 'VERY_HIGH'
      WHEN brand_clicks>=10 OR brand_purchases>=2 THEN 'HIGH'
      WHEN brand_clicks>=3  OR brand_purchases>=1 THEN 'MEDIUM'
      WHEN brand_impressions>=30 OR search_query_volume>=100 THEN 'LOW'
      ELSE 'VERY_LOW'
    END AS signal_strength
  FROM src s
)
SELECT c.*,
  -- §40 classificacao = ROTULO DE FUNIL (fato, nao decisao). Thresholds default.
  CASE
    WHEN signal_strength IN ('VERY_LOW','LOW') THEN 'LOW_SIGNAL'
    WHEN COALESCE(purchase_share_lift,0) > 1.10 AND brand_purchases >= 1 THEN 'SCALE_VISIBILITY'
    WHEN COALESCE(brand_click_share,0) > 0 AND COALESCE(brand_purchase_share,0) < 0.5*brand_click_share THEN 'CONVERSION_GAP'
    WHEN COALESCE(brand_impression_share,0) > 0 AND COALESCE(brand_click_share,0) < 0.5*brand_impression_share THEN 'CLICK_GAP'
    WHEN COALESCE(brand_click_share,0) > 0 AND COALESCE(brand_cart_add_share,0) < 0.5*brand_click_share THEN 'CART_GAP'
    WHEN COALESCE(click_price_index,1) < 1 AND COALESCE(purchase_share_lift,0) > 1 THEN 'PRICE_TEST_UP'
    WHEN brand_purchases >= 1 AND COALESCE(brand_purchase_share,0) >= brand_impression_share THEN 'DEFEND'
    WHEN market_purchases >= 5 AND brand_impressions <= 1 THEN 'DISCOVER'
    ELSE 'WATCH'
  END AS funnel_label
FROM calc c;

COMMENT ON VIEW marketcloud_gold.gold_brand_query_weekly_v1 IS
  'Gold central de query da marca (§33): funil marca+mercado, share lift (§17), price index (§18), signal_strength (§41), funnel_label (§40 = FATO descritivo, nao decisao). Fonte E001 PROPRIETARY_SEARCH_QUERY.';
