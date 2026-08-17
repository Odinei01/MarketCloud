-- 203_brand_analytics_materialize_fase4.sql
-- FASE 4 (infra) — PERFORMANCE: materializa as views gold BA que hoje computam
-- AO VIVO sobre o FDW cross-DB (swarm_src, 66k linhas) e levam ~2-3min -> tela
-- inutilizavel. Materializa as 2 RAIZES (market_search_weekly, brand_query_weekly)
-- em MVs locais; as views raiz viram passthrough (mesmo nome -> API e downstream
-- inalterados); downstream (opportunity_universe, brand_product_weekly) passam a
-- ler dado ja materializado. Refresh via refresh_brand_analytics_gold() (worker).
-- Indice UNICO em cada MV habilita REFRESH ... CONCURRENTLY (sem travar leitura).

-- ===== MV raiz: market_search_weekly =====
CREATE MATERIALIZED VIEW marketcloud_gold.mv_gold_market_search_weekly_v1 AS
 WITH st AS (
         SELECT amazon_brand_analytics_search_query_performance.period_start,
            amazon_brand_analytics_search_query_performance.period_end,
            amazon_brand_analytics_search_query_performance.search_query,
            upper(TRIM(BOTH FROM amazon_brand_analytics_search_query_performance.asin)) AS asin,
            NULLIF(amazon_brand_analytics_search_query_performance.raw_json_sanitized ->> 'clickShareRank'::text, ''::text)::integer AS click_rank,
            COALESCE(amazon_brand_analytics_search_query_performance.query_rank, 0) AS search_frequency_rank,
            COALESCE(amazon_brand_analytics_search_query_performance.brand_click_share, 0::numeric)::double precision AS click_share,
            COALESCE(amazon_brand_analytics_search_query_performance.brand_purchase_share, 0::numeric)::double precision AS conversion_share
           FROM swarm_src.amazon_brand_analytics_search_query_performance
          WHERE COALESCE(amazon_brand_analytics_search_query_performance.data_domain, ''::text) = 'MARKET_SEARCH_TERMS'::text AND COALESCE(amazon_brand_analytics_search_query_performance.search_query, ''::text) <> ''::text
        ), agg AS (
         SELECT st.period_start,
            st.period_end,
            st.search_query,
            min(NULLIF(st.search_frequency_rank, 0)) AS search_frequency_rank,
            max(st.asin) FILTER (WHERE st.click_rank = 1) AS top1_asin,
            max(st.click_share) FILTER (WHERE st.click_rank = 1) AS top1_click_share,
            max(st.conversion_share) FILTER (WHERE st.click_rank = 1) AS top1_conversion_share,
            max(st.asin) FILTER (WHERE st.click_rank = 2) AS top2_asin,
            max(st.click_share) FILTER (WHERE st.click_rank = 2) AS top2_click_share,
            max(st.conversion_share) FILTER (WHERE st.click_rank = 2) AS top2_conversion_share,
            max(st.asin) FILTER (WHERE st.click_rank = 3) AS top3_asin,
            max(st.click_share) FILTER (WHERE st.click_rank = 3) AS top3_click_share,
            max(st.conversion_share) FILTER (WHERE st.click_rank = 3) AS top3_conversion_share,
            round(sum(st.click_share) FILTER (WHERE st.click_rank <= 3)::numeric, 4) AS top3_click_concentration,
            round(sum(st.conversion_share) FILTER (WHERE st.click_rank <= 3)::numeric, 4) AS top3_conversion_concentration
           FROM st
          GROUP BY st.period_start, st.period_end, st.search_query
        )
 SELECT period_start,
    period_end,
    search_query,
    search_frequency_rank,
    top1_asin,
    top1_click_share,
    top1_conversion_share,
    top2_asin,
    top2_click_share,
    top2_conversion_share,
    top3_asin,
    top3_click_share,
    top3_conversion_share,
    top3_click_concentration,
    top3_conversion_concentration,
        CASE
            WHEN top3_click_concentration >= 0.80 THEN 'HIGHLY_CONCENTRATED'::text
            WHEN top3_click_concentration >= 0.60 THEN 'CONCENTRATED'::text
            WHEN top3_click_concentration >= 0.40 THEN 'FRAGMENTED'::text
            ELSE 'HIGHLY_FRAGMENTED'::text
        END AS market_concentration_class,
    lag(search_frequency_rank) OVER (PARTITION BY search_query ORDER BY period_start) - search_frequency_rank AS rank_change_wow
   FROM agg a;
;
CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_market_search_weekly ON marketcloud_gold.mv_gold_market_search_weekly_v1 (period_start, period_end, search_query);
CREATE INDEX IF NOT EXISTS ix_mv_market_search_top1 ON marketcloud_gold.mv_gold_market_search_weekly_v1 (top1_asin);

-- ===== MV raiz: brand_query_weekly =====
CREATE MATERIALIZED VIEW marketcloud_gold.mv_gold_brand_query_weekly_v1 AS
 WITH src AS (
         SELECT DISTINCT ON (amazon_brand_analytics_search_query_performance.period_start, (upper(TRIM(BOTH FROM amazon_brand_analytics_search_query_performance.asin))), amazon_brand_analytics_search_query_performance.search_query) amazon_brand_analytics_search_query_performance.marketplace_id,
            amazon_brand_analytics_search_query_performance.period_start,
            amazon_brand_analytics_search_query_performance.period_end,
            upper(TRIM(BOTH FROM amazon_brand_analytics_search_query_performance.asin)) AS asin,
            amazon_brand_analytics_search_query_performance.search_query,
            COALESCE(amazon_brand_analytics_search_query_performance.search_query_volume, 0::numeric)::double precision AS search_query_volume,
            COALESCE(amazon_brand_analytics_search_query_performance.search_query_score, 0::numeric)::double precision AS search_query_score,
            COALESCE(amazon_brand_analytics_search_query_performance.impressions, 0::numeric)::double precision AS brand_impressions,
            COALESCE(amazon_brand_analytics_search_query_performance.clicks, 0::numeric)::double precision AS brand_clicks,
            COALESCE(amazon_brand_analytics_search_query_performance.cart_adds, 0::numeric)::double precision AS brand_cart_adds,
            COALESCE(amazon_brand_analytics_search_query_performance.purchases, 0::numeric)::double precision AS brand_purchases,
            COALESCE(amazon_brand_analytics_search_query_performance.total_impressions, 0::numeric)::double precision AS market_impressions,
            COALESCE(amazon_brand_analytics_search_query_performance.total_clicks, 0::numeric)::double precision AS market_clicks,
            COALESCE(amazon_brand_analytics_search_query_performance.total_cart_adds, 0::numeric)::double precision AS market_cart_adds,
            COALESCE(amazon_brand_analytics_search_query_performance.total_purchases, 0::numeric)::double precision AS market_purchases,
            COALESCE(amazon_brand_analytics_search_query_performance.brand_impression_share, 0::numeric)::double precision AS brand_impression_share,
            COALESCE(amazon_brand_analytics_search_query_performance.brand_click_share, 0::numeric)::double precision AS brand_click_share,
            COALESCE(amazon_brand_analytics_search_query_performance.brand_cart_add_share, 0::numeric)::double precision AS brand_cart_add_share,
            COALESCE(amazon_brand_analytics_search_query_performance.brand_purchase_share, 0::numeric)::double precision AS brand_purchase_share,
            NULLIF(amazon_brand_analytics_search_query_performance.brand_median_click_price, 0::numeric)::double precision AS brand_median_click_price,
            NULLIF(amazon_brand_analytics_search_query_performance.market_median_click_price, 0::numeric)::double precision AS market_median_click_price,
            NULLIF(amazon_brand_analytics_search_query_performance.brand_median_purchase_price, 0::numeric)::double precision AS brand_median_purchase_price,
            NULLIF(amazon_brand_analytics_search_query_performance.market_median_purchase_price, 0::numeric)::double precision AS market_median_purchase_price
           FROM swarm_src.amazon_brand_analytics_search_query_performance
          WHERE COALESCE(amazon_brand_analytics_search_query_performance.data_domain, ''::text) = 'PROPRIETARY_SEARCH_QUERY'::text AND COALESCE(amazon_brand_analytics_search_query_performance.search_query, ''::text) <> ''::text AND COALESCE(amazon_brand_analytics_search_query_performance.asin, ''::text) <> ''::text
          ORDER BY amazon_brand_analytics_search_query_performance.period_start, (upper(TRIM(BOTH FROM amazon_brand_analytics_search_query_performance.asin))), amazon_brand_analytics_search_query_performance.search_query, amazon_brand_analytics_search_query_performance.synced_at DESC
        ), calc AS (
         SELECT s.marketplace_id,
            s.period_start,
            s.period_end,
            s.asin,
            s.search_query,
            s.search_query_volume,
            s.search_query_score,
            s.brand_impressions,
            s.brand_clicks,
            s.brand_cart_adds,
            s.brand_purchases,
            s.market_impressions,
            s.market_clicks,
            s.market_cart_adds,
            s.market_purchases,
            s.brand_impression_share,
            s.brand_click_share,
            s.brand_cart_add_share,
            s.brand_purchase_share,
            s.brand_median_click_price,
            s.market_median_click_price,
            s.brand_median_purchase_price,
            s.market_median_purchase_price,
                CASE
                    WHEN s.brand_impressions > 0::double precision THEN s.brand_clicks / s.brand_impressions
                    ELSE NULL::double precision
                END AS brand_ctr,
                CASE
                    WHEN s.brand_clicks > 0::double precision THEN s.brand_cart_adds / s.brand_clicks
                    ELSE NULL::double precision
                END AS brand_click_to_cart,
                CASE
                    WHEN s.brand_cart_adds > 0::double precision THEN s.brand_purchases / s.brand_cart_adds
                    ELSE NULL::double precision
                END AS brand_cart_to_purchase,
                CASE
                    WHEN s.brand_clicks > 0::double precision THEN s.brand_purchases / s.brand_clicks
                    ELSE NULL::double precision
                END AS brand_search_conversion,
                CASE
                    WHEN s.brand_impression_share > 0::double precision THEN s.brand_click_share / s.brand_impression_share
                    ELSE NULL::double precision
                END AS click_share_lift,
                CASE
                    WHEN s.brand_impression_share > 0::double precision THEN s.brand_cart_add_share / s.brand_impression_share
                    ELSE NULL::double precision
                END AS cart_share_lift,
                CASE
                    WHEN s.brand_impression_share > 0::double precision THEN s.brand_purchase_share / s.brand_impression_share
                    ELSE NULL::double precision
                END AS purchase_share_lift,
                CASE
                    WHEN s.brand_median_click_price IS NOT NULL AND s.market_median_click_price IS NOT NULL AND s.market_median_click_price > 0::double precision THEN s.brand_median_click_price / s.market_median_click_price
                    ELSE NULL::double precision
                END AS click_price_index,
                CASE
                    WHEN s.brand_median_purchase_price IS NOT NULL AND s.market_median_purchase_price IS NOT NULL AND s.market_median_purchase_price > 0::double precision THEN s.brand_median_purchase_price / s.market_median_purchase_price
                    ELSE NULL::double precision
                END AS purchase_price_index,
                CASE
                    WHEN s.brand_clicks >= 30::double precision OR s.brand_purchases >= 5::double precision THEN 'VERY_HIGH'::text
                    WHEN s.brand_clicks >= 10::double precision OR s.brand_purchases >= 2::double precision THEN 'HIGH'::text
                    WHEN s.brand_clicks >= 3::double precision OR s.brand_purchases >= 1::double precision THEN 'MEDIUM'::text
                    WHEN s.brand_impressions >= 30::double precision OR s.search_query_volume >= 100::double precision THEN 'LOW'::text
                    ELSE 'VERY_LOW'::text
                END AS signal_strength
           FROM src s
        )
 SELECT marketplace_id,
    period_start,
    period_end,
    asin,
    search_query,
    search_query_volume,
    search_query_score,
    brand_impressions,
    brand_clicks,
    brand_cart_adds,
    brand_purchases,
    market_impressions,
    market_clicks,
    market_cart_adds,
    market_purchases,
    brand_impression_share,
    brand_click_share,
    brand_cart_add_share,
    brand_purchase_share,
    brand_median_click_price,
    market_median_click_price,
    brand_median_purchase_price,
    market_median_purchase_price,
    brand_ctr,
    brand_click_to_cart,
    brand_cart_to_purchase,
    brand_search_conversion,
    click_share_lift,
    cart_share_lift,
    purchase_share_lift,
    click_price_index,
    purchase_price_index,
    signal_strength,
        CASE
            WHEN signal_strength = ANY (ARRAY['VERY_LOW'::text, 'LOW'::text]) THEN 'LOW_SIGNAL'::text
            WHEN COALESCE(purchase_share_lift, 0::double precision) > 1.10::double precision AND brand_purchases >= 1::double precision THEN 'SCALE_VISIBILITY'::text
            WHEN COALESCE(brand_click_share, 0::double precision) > 0::double precision AND COALESCE(brand_purchase_share, 0::double precision) < (0.5::double precision * brand_click_share) THEN 'CONVERSION_GAP'::text
            WHEN COALESCE(brand_impression_share, 0::double precision) > 0::double precision AND COALESCE(brand_click_share, 0::double precision) < (0.5::double precision * brand_impression_share) THEN 'CLICK_GAP'::text
            WHEN COALESCE(brand_click_share, 0::double precision) > 0::double precision AND COALESCE(brand_cart_add_share, 0::double precision) < (0.5::double precision * brand_click_share) THEN 'CART_GAP'::text
            WHEN COALESCE(click_price_index, 1::double precision) < 1::double precision AND COALESCE(purchase_share_lift, 0::double precision) > 1::double precision THEN 'PRICE_TEST_UP'::text
            WHEN brand_purchases >= 1::double precision AND COALESCE(brand_purchase_share, 0::double precision) >= brand_impression_share THEN 'DEFEND'::text
            WHEN market_purchases >= 5::double precision AND brand_impressions <= 1::double precision THEN 'DISCOVER'::text
            ELSE 'WATCH'::text
        END AS funnel_label
   FROM calc c;
;
CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_brand_query_weekly ON marketcloud_gold.mv_gold_brand_query_weekly_v1 (marketplace_id, period_start, period_end, asin, search_query);
CREATE INDEX IF NOT EXISTS ix_mv_brand_query_asin ON marketcloud_gold.mv_gold_brand_query_weekly_v1 (asin, period_start);

-- ===== views raiz viram passthrough (nome estavel; API/downstream nao mudam) =====
CREATE OR REPLACE VIEW marketcloud_gold.gold_market_search_weekly_v1 AS
  SELECT * FROM marketcloud_gold.mv_gold_market_search_weekly_v1;
CREATE OR REPLACE VIEW marketcloud_gold.gold_brand_query_weekly_v1 AS
  SELECT * FROM marketcloud_gold.mv_gold_brand_query_weekly_v1;

-- ===== rotina de refresh =====
-- REFRESH normal (nao CONCURRENTLY): CONCURRENTLY nao pode rodar dentro de funcao
-- nem de transacao. Lock breve e aceitavel num refresh diario off-peak de dado
-- semanal. O indice unico continua util (correcao/dedup e futuros usos).
CREATE OR REPLACE FUNCTION marketcloud_gold.refresh_brand_analytics_gold()
  RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_market_search_weekly_v1;
  REFRESH MATERIALIZED VIEW marketcloud_gold.mv_gold_brand_query_weekly_v1;
  RETURN 'brand_analytics_gold refreshed at '||now();
END;
$fn$;
