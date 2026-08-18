-- 213: repoint do check universe_presence do DQ gate pra contar o universo de
-- MERCADO da tabela dedicada amazon_brand_analytics_search_terms (E003), fechando
-- o ultimo leitor de MARKET_SEARCH_TERMS na SQP. Marca (E001) segue na SQP.
CREATE OR REPLACE VIEW marketcloud_gold.v_brand_analytics_data_quality AS
 WITH b AS (
         SELECT gold_brand_query_weekly_v1.marketplace_id,
            gold_brand_query_weekly_v1.period_start,
            gold_brand_query_weekly_v1.period_end,
            gold_brand_query_weekly_v1.asin,
            gold_brand_query_weekly_v1.search_query,
            gold_brand_query_weekly_v1.search_query_volume,
            gold_brand_query_weekly_v1.search_query_score,
            gold_brand_query_weekly_v1.brand_impressions,
            gold_brand_query_weekly_v1.brand_clicks,
            gold_brand_query_weekly_v1.brand_cart_adds,
            gold_brand_query_weekly_v1.brand_purchases,
            gold_brand_query_weekly_v1.market_impressions,
            gold_brand_query_weekly_v1.market_clicks,
            gold_brand_query_weekly_v1.market_cart_adds,
            gold_brand_query_weekly_v1.market_purchases,
            gold_brand_query_weekly_v1.brand_impression_share,
            gold_brand_query_weekly_v1.brand_click_share,
            gold_brand_query_weekly_v1.brand_cart_add_share,
            gold_brand_query_weekly_v1.brand_purchase_share,
            gold_brand_query_weekly_v1.brand_median_click_price,
            gold_brand_query_weekly_v1.market_median_click_price,
            gold_brand_query_weekly_v1.brand_median_purchase_price,
            gold_brand_query_weekly_v1.market_median_purchase_price,
            gold_brand_query_weekly_v1.brand_ctr,
            gold_brand_query_weekly_v1.brand_click_to_cart,
            gold_brand_query_weekly_v1.brand_cart_to_purchase,
            gold_brand_query_weekly_v1.brand_search_conversion,
            gold_brand_query_weekly_v1.click_share_lift,
            gold_brand_query_weekly_v1.cart_share_lift,
            gold_brand_query_weekly_v1.purchase_share_lift,
            gold_brand_query_weekly_v1.click_price_index,
            gold_brand_query_weekly_v1.purchase_price_index,
            gold_brand_query_weekly_v1.signal_strength,
            gold_brand_query_weekly_v1.funnel_label
           FROM marketcloud_gold.gold_brand_query_weekly_v1
        ), today AS (
         SELECT (now() AT TIME ZONE 'America/Sao_Paulo'::text)::date AS d
        )
 SELECT 'freshness'::text AS check_name,
        CASE
            WHEN max(b.period_end) IS NULL THEN 'FAIL'::text
            WHEN ((( SELECT today.d
               FROM today)) - max(b.period_end)) > 21 THEN 'FAIL'::text
            WHEN ((( SELECT today.d
               FROM today)) - max(b.period_end)) > 12 THEN 'WARN'::text
            ELSE 'OK'::text
        END AS status,
    (((( SELECT today.d
           FROM today)) - max(b.period_end))::text) || ' dias desde a ultima semana'::text AS detail,
    max(b.period_end)::text AS metric
   FROM b
UNION ALL
 SELECT 'share_bounds'::text AS check_name,
        CASE
            WHEN count(*) FILTER (WHERE b.brand_click_share < 0::double precision OR b.brand_click_share > 100::double precision OR b.brand_impression_share < 0::double precision OR b.brand_impression_share > 100::double precision OR b.brand_purchase_share < 0::double precision OR b.brand_purchase_share > 100::double precision) > 0 THEN 'FAIL'::text
            ELSE 'OK'::text
        END AS status,
    count(*) FILTER (WHERE b.brand_click_share < 0::double precision OR b.brand_click_share > 100::double precision)::text || ' shares fora de [0,100]'::text AS detail,
    count(*)::text || ' linhas'::text AS metric
   FROM b
UNION ALL
 SELECT 'funnel_monotonicity'::text AS check_name,
        CASE
            WHEN count(*) FILTER (WHERE b.brand_impressions < b.brand_clicks OR b.brand_clicks < b.brand_cart_adds OR b.brand_cart_adds < b.brand_purchases) > 0 THEN 'FAIL'::text
            ELSE 'OK'::text
        END AS status,
    count(*) FILTER (WHERE b.brand_impressions < b.brand_clicks OR b.brand_clicks < b.brand_cart_adds OR b.brand_cart_adds < b.brand_purchases)::text || ' funis invertidos'::text AS detail,
    count(*)::text || ' linhas'::text AS metric
   FROM b
UNION ALL
 SELECT 'price_index_positive'::text AS check_name,
        CASE
            WHEN count(*) FILTER (WHERE b.click_price_index < 0::double precision OR b.purchase_price_index < 0::double precision) > 0 THEN 'FAIL'::text
            ELSE 'OK'::text
        END AS status,
    count(*) FILTER (WHERE b.click_price_index < 0::double precision OR b.purchase_price_index < 0::double precision)::text || ' price index negativo'::text AS detail,
    count(*) FILTER (WHERE b.click_price_index IS NOT NULL)::text || ' com price index'::text AS metric
   FROM b
UNION ALL
 SELECT 'brand_coverage'::text AS check_name,
        CASE
            WHEN count(DISTINCT b.asin) = 0 THEN 'FAIL'::text
            WHEN count(DISTINCT b.asin) < 5 THEN 'WARN'::text
            ELSE 'OK'::text
        END AS status,
    count(DISTINCT b.asin)::text || ' ASINs de marca com dado'::text AS detail,
    count(DISTINCT b.asin)::text || ' asins'::text AS metric
   FROM b
UNION ALL
 SELECT 'universe_presence'::text AS check_name,
        CASE
            WHEN (SELECT count(*) FROM swarm_src.amazon_brand_analytics_search_query_performance WHERE data_domain = 'PROPRIETARY_SEARCH_QUERY') = 0
              OR (SELECT count(*) FROM swarm_src.amazon_brand_analytics_search_terms) = 0
            THEN 'WARN'::text
            ELSE 'OK'::text
        END AS status,
    ('marca='::text || (SELECT count(*) FROM swarm_src.amazon_brand_analytics_search_query_performance WHERE data_domain = 'PROPRIETARY_SEARCH_QUERY')::text)
      || ' / mercado='::text || (SELECT count(*) FROM swarm_src.amazon_brand_analytics_search_terms)::text AS detail,
    ((SELECT count(*) FROM swarm_src.amazon_brand_analytics_search_query_performance WHERE data_domain = 'PROPRIETARY_SEARCH_QUERY')
     + (SELECT count(*) FROM swarm_src.amazon_brand_analytics_search_terms))::text || ' linhas nas origens'::text AS metric;
