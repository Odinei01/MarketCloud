-- 208_recommendation_engine_v1.sql
-- RECOMMENDATION ENGINE V1 (§67). So recomendacoes EXPLICAVEIS: action + reason +
-- evidence + confidence. Deterministico (mapeia o funnel_label §40 + metricas em uma
-- acao recomendada). NAO executa nada (§68 Observe->Explain->Recommend). E FATO +
-- sugestao auditavel, nao um cerebro que decide sozinho — a decisao/execucao segue
-- no ML/guardrails/dono. Confidence herda do classification_confidence (§41).
CREATE OR REPLACE VIEW marketcloud_gold.gold_brand_query_recommendation_v1 AS
SELECT
    marketplace_id, period_start, period_end, asin, search_query,
    funnel_label, classification_confidence AS rec_confidence, signal_strength,
    search_query_volume, brand_purchases,
    -- §67 ACTION: uma acao curta por rotulo de funil.
    CASE funnel_label
      WHEN 'SCALE_VISIBILITY'  THEN 'Aumentar visibilidade em busca'
      WHEN 'LONG_TAIL_WINNER'  THEN 'Escalar cauda longa vencedora'
      WHEN 'CONVERSION_GAP'    THEN 'Investigar conversao (listing/preco/reviews)'
      WHEN 'CLICK_GAP'         THEN 'Melhorar relevancia/CTR (titulo/imagem/preco)'
      WHEN 'CART_GAP'          THEN 'Investigar carrinho -> compra'
      WHEN 'PRICE_TEST_UP'     THEN 'Testar preco para cima'
      WHEN 'DEFEND'            THEN 'Defender posicao'
      WHEN 'DISCOVER'          THEN 'Explorar oportunidade (entrar na busca)'
      ELSE 'Coletar mais dado / monitorar'
    END AS rec_action,
    -- §67 REASON: por que (explicavel em uma frase).
    CASE funnel_label
      WHEN 'SCALE_VISIBILITY'  THEN 'Purchase share supera impression share (ganha share no funil).'
      WHEN 'LONG_TAIL_WINNER'  THEN 'Busca de baixo volume que converte acima da media.'
      WHEN 'CONVERSION_GAP'    THEN 'Click share aceitavel, mas purchase share bem menor.'
      WHEN 'CLICK_GAP'         THEN 'Impression share forte, mas click share bem menor.'
      WHEN 'CART_GAP'          THEN 'Click share forte, mas cart share fraco.'
      WHEN 'PRICE_TEST_UP'     THEN 'Preco abaixo da mediana e ainda ganha share (poder de preco).'
      WHEN 'DEFEND'            THEN 'Alta participacao e boa conversao — proteger.'
      WHEN 'DISCOVER'          THEN 'Mercado compra nesta busca e a ZANOM quase nao aparece.'
      ELSE 'Amostra insuficiente para recomendar com confianca.'
    END AS rec_reason,
    -- §67 EVIDENCE: os numeros que sustentam (impr/click/purch share + lift + price idx).
    format('Impr %s%% | Click %s%% | Cart %s%% | Purch %s%% | Lift %s | PriceIdx %s | Compras %s',
      to_char(COALESCE(brand_impression_share,0),'FM990.00'),
      to_char(COALESCE(brand_click_share,0),'FM990.00'),
      to_char(COALESCE(brand_cart_add_share,0),'FM990.00'),
      to_char(COALESCE(brand_purchase_share,0),'FM990.00'),
      to_char(COALESCE(purchase_share_lift,0),'FM990.00'),
      to_char(COALESCE(purchase_price_index,0),'FM990.00'),
      to_char(COALESCE(brand_purchases,0),'FM999990')
    ) AS rec_evidence,
    -- prioridade p/ ordenar o feed de recomendacoes (acionavel + confianca + volume).
    (CASE funnel_label
       WHEN 'SCALE_VISIBILITY' THEN 90 WHEN 'LONG_TAIL_WINNER' THEN 85
       WHEN 'CONVERSION_GAP' THEN 80 WHEN 'CART_GAP' THEN 75 WHEN 'CLICK_GAP' THEN 70
       WHEN 'PRICE_TEST_UP' THEN 65 WHEN 'DISCOVER' THEN 60 WHEN 'DEFEND' THEN 50
       ELSE 10 END
     + CASE classification_confidence WHEN 'HIGH' THEN 6 WHEN 'MEDIUM' THEN 3 ELSE 0 END
    )::int AS rec_priority,
    (funnel_label NOT IN ('LOW_SIGNAL','WATCH')) AS is_actionable
FROM marketcloud_gold.gold_brand_query_weekly_v1;

COMMENT ON VIEW marketcloud_gold.gold_brand_query_recommendation_v1 IS
 '§67 Recommendation Engine V1: action+reason+evidence+confidence por ASIN x query. Deterministico, explicavel, NAO executa (§68). FATO+sugestao, decisao segue no ML/dono.';
