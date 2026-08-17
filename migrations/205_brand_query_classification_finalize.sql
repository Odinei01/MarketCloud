-- 205_brand_query_classification_finalize.sql
-- Finaliza a classificacao de query (§40-41): adiciona a 9a classe LONG_TAIL_WINNER
-- e o campo classification_confidence (derivado do signal_strength, §41). Feito no
-- passthrough por cima da MV (sem rebuild): LONG_TAIL_WINNER = winner de baixo volume
-- (um SCALE_VISIBILITY com search_query_volume < limiar). Confidence 3-niveis.
CREATE OR REPLACE VIEW marketcloud_gold.gold_brand_query_weekly_v1 AS
SELECT
    marketplace_id, period_start, period_end, asin, search_query,
    search_query_volume, search_query_score,
    brand_impressions, brand_clicks, brand_cart_adds, brand_purchases,
    market_impressions, market_clicks, market_cart_adds, market_purchases,
    brand_impression_share, brand_click_share, brand_cart_add_share, brand_purchase_share,
    brand_median_click_price, market_median_click_price,
    brand_median_purchase_price, market_median_purchase_price,
    brand_ctr, brand_click_to_cart, brand_cart_to_purchase, brand_search_conversion,
    click_share_lift, cart_share_lift, purchase_share_lift,
    click_price_index, purchase_price_index,
    signal_strength,
    -- §40: 9a classe LONG_TAIL_WINNER = winner (SCALE_VISIBILITY) de baixo volume.
    -- Limiar 50 buscas/semana (conta magra: mediana=8). Winner de alto volume segue
    -- SCALE_VISIBILITY. As outras 8 classes vem da MV inalteradas.
    CASE
      WHEN funnel_label = 'SCALE_VISIBILITY' AND COALESCE(search_query_volume, 0) < 50
        THEN 'LONG_TAIL_WINNER'
      ELSE funnel_label
    END AS funnel_label,
    -- §41: confidence exibido junto da classificacao (mapeia signal_strength -> 3 niveis).
    CASE signal_strength
      WHEN 'VERY_HIGH' THEN 'HIGH'
      WHEN 'HIGH'      THEN 'HIGH'
      WHEN 'MEDIUM'    THEN 'MEDIUM'
      ELSE 'LOW'
    END AS classification_confidence
FROM marketcloud_gold.mv_gold_brand_query_weekly_v1;
