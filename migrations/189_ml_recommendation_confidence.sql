-- 189 — Fase 1: score de confiança sobre as recomendações do ML.
-- Motivo (auditoria top-20): as recs saem com ml_conversion_probability ~0,996
-- (memorização de células que já converteram) e um label categórico "HIGH" que
-- faz rec de 3 pedidos parecer certeza. Este score torna EXPLÍCITO o volume de
-- dado atrás da rec, o dinheiro em jogo e a direção da ação — e separa o que é
-- seguro escalar do que é arriscado (cortar bid em keyword que converte).
--
-- v1 gateia no que é limpo e já está no rec view (pedidos/cliques/ação/ROAS_ml).
-- v2 (quando keyword->ASIN unificar) acrescenta estoque, margem e concorrência.

CREATE OR REPLACE VIEW marketcloud_gold.gold_keyword_hourly_recommendation_confidence_v1 AS
SELECT
  r.keyword_hour_recommendation_id,
  r.keyword_text,
  r.event_hour,
  r.ad_group_name,
  r.campaign_name,
  r.advisor_action,
  r.confidence                                              AS legacy_confidence_label,
  COALESCE(r.orders, 0)                                     AS data_orders,
  COALESCE(r.clicks, 0)                                     AS data_clicks,
  round(COALESCE(r.spend, 0), 2)                            AS observed_spend,
  round(COALESCE(r.ml_expected_roas, 0), 2)                AS ml_expected_roas,
  round(COALESCE(r.ml_conversion_probability, 0), 3)       AS ml_conversion_probability,
  round(r.suggested_effective_bid::numeric, 2)             AS suggested_effective_bid,
  -- dinheiro em jogo se aplicar: bid sugerido x cliques observados na hora (piso 1)
  round(r.suggested_effective_bid::numeric * GREATEST(COALESCE(r.clicks, 0), 1), 2) AS financial_risk_brl,

  -- força de evidência PURAMENTE por volume de conversão observado
  CASE
    WHEN COALESCE(r.orders, 0) >= 5 THEN 'FORTE'
    WHEN COALESCE(r.orders, 0) BETWEEN 1 AND 4 THEN 'FRACA'
    ELSE 'NENHUMA'
  END                                                       AS evidence_strength,

  -- tier acionável (o coração do score)
  CASE
    WHEN COALESCE(r.orders, 0) = 0 THEN 'SEM_DADO'
    WHEN r.advisor_action = 'DECREASE_EFFECTIVE_BID' AND COALESCE(r.orders, 0) >= 5 THEN 'SEGURAR_REVISAR'
    WHEN r.advisor_action = 'INCREASE_EFFECTIVE_BID' AND COALESCE(r.orders, 0) >= 5 AND COALESCE(r.ml_expected_roas, 0) >= 3 THEN 'ESCALAR'
    ELSE 'TESTAR'
  END                                                       AS confidence_tier,

  -- auto-elegível: só escala com lastro real (usado depois pela automação por camadas)
  (COALESCE(r.orders, 0) >= 5
     AND r.advisor_action = 'INCREASE_EFFECTIVE_BID'
     AND COALESCE(r.ml_expected_roas, 0) >= 3)              AS auto_eligible,

  CASE
    WHEN COALESCE(r.orders, 0) = 0
      THEN 'sem pedido observado: coletar dado, nao recomendar'
    WHEN r.advisor_action = 'DECREASE_EFFECTIVE_BID' AND COALESCE(r.orders, 0) >= 5
      THEN 'corte em keyword que converte (' || r.orders || ' pedidos): checar posicao antes, nao auto-cortar'
    WHEN r.advisor_action = 'INCREASE_EFFECTIVE_BID' AND COALESCE(r.orders, 0) >= 5 AND COALESCE(r.ml_expected_roas, 0) >= 3
      THEN 'aumento com ' || r.orders || ' pedidos e ROAS_ml ' || round(COALESCE(r.ml_expected_roas,0), 1) || ': escalar'
    ELSE 'evidencia fraca (' || COALESCE(r.orders, 0) || ' pedidos): testar pequeno / holdout'
  END                                                       AS confidence_reason,

  r.priority_score
FROM marketcloud_gold.gold_keyword_hourly_recommendations_v3 r;

COMMENT ON VIEW marketcloud_gold.gold_keyword_hourly_recommendation_confidence_v1 IS
  'Fase 1 — score de confianca por rec: volume de dado (pedidos), risco financeiro, forca de evidencia e tier acionavel (SEM_DADO/TESTAR/SEGURAR_REVISAR/ESCALAR). auto_eligible = escala com lastro. v2 acrescenta estoque/margem/concorrencia.';
