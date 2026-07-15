-- ALVO DO LANCE VEM DO ML (decisao do dono, 15/07/2026).
--
-- Antes: suggested = mult_min + 0.3 (BID_UP) / mult_max - 0.3 (BID_DOWN).
-- Isso e um alvo MOVEL: calculado em cima do multiplicador atual, entao aplicar
-- muda o proprio alvo e a recomendacao renasce. 31 pins aplicados as 19:13
-- voltaram por isso. Pior: como o mult_min/max e da CAMPANHA inteira (mistura
-- todos os escopos), aparecia "reduzir de 0.20 para 0.70".
--
-- Agora: alvo ABSOLUTO, por campanha x hora, que nao depende do lance atual.
-- Aplicou -> alinhou -> sai da lista. Sem esteira.
--
-- Formula (Bayes empirico com prior do ML):
--   alvo_roas(h) = (venda_real(h) + m * roas_previsto_ml(h)) / (gasto_real(h) + m)
--   mult(h)      = clamp( alvo_roas(h) / roas_da_campanha , 0.30 , 1.00 )
--
-- Por que assim:
--  * O ML da o palpite (ele enxerga AMC assist/NTB/mid-funnel e os 23k outcomes
--    medidos do robo). O dado real corrige com peso proporcional a evidencia:
--    hora com muito gasto manda no resultado, hora rasa herda o palpite do ML.
--    Isso e o "importa a recorrencia": evidencia que se repete pesa mais.
--  * A ancora e a PROPRIA campanha (aprendida do dado), nao uma meta chutada.
--  * m = 20 e o pseudo-gasto: "R$20 de gasto real empata com o palpite do ML".
--    E o botao de confianca modelo-vs-historico. Calibravel.
--
-- NAO usamos conversion_probability como alvo, apesar do AUC 0.96: o alvo dela
-- e has_order ("essa hora tem pelo menos 1 pedido?"), que na pratica e "essa
-- hora tem trafego?". Testado em 15/07: satura em ~1.0 e daria lance cheio pras
-- 20h (ROAS 3.37) igual as 18h (ROAS 7.05). Ela fica na tela como apoio.
CREATE OR REPLACE VIEW marketcloud_gold.gold_hourly_ml_target_multiplier AS
WITH camp AS (
    SELECT campaign_name,
           sum(sales_7d) / NULLIF(sum(spend),0) AS roas_campanha,
           sum(spend) AS gasto_total
    FROM marketcloud_gold.gold_hourly_signal_amc
    GROUP BY 1
    HAVING sum(spend) > 0
), hora AS (
    SELECT campaign_name, event_hour,
           sum(sales_7d) AS venda, sum(spend) AS gasto, sum(clicks) AS cliques
    FROM marketcloud_gold.gold_hourly_signal_amc
    GROUP BY 1,2
)
SELECT h.campaign_name,
       h.event_hour,
       p.expected_roas::numeric                                        AS prior_ml_roas,
       p.conversion_probability::numeric                               AS ml_conversion_probability,
       h.gasto::numeric                                                AS gasto_observado,
       h.cliques                                                       AS cliques_observados,
       (h.venda / NULLIF(h.gasto,0))::numeric                          AS roas_observado,
       c.roas_campanha::numeric                                        AS roas_ancora,
       ((h.venda + 20 * p.expected_roas) / (h.gasto + 20))::numeric    AS alvo_roas,
       GREATEST(0.30, LEAST(1.00,
           round((((h.venda + 20 * p.expected_roas) / (h.gasto + 20)) / c.roas_campanha * 20)::numeric) / 20
       ))                                                              AS ml_multiplier
FROM hora h
JOIN marketcloud_gold.hourly_ml_predictions_v2 p
  ON p.campaign_name = h.campaign_name AND p.event_hour = h.event_hour
JOIN camp c ON c.campaign_name = h.campaign_name
WHERE c.roas_campanha > 0;

COMMENT ON VIEW marketcloud_gold.gold_hourly_ml_target_multiplier IS
    'Multiplicador ALVO por campanha x hora: Bayes empirico com prior do ML (expected_roas) corrigido pelo gasto/venda real, ancorado no ROAS da propria campanha. Alvo absoluto: nao depende do lance atual.';

-- v3 passa a sugerir o alvo do ML em vez de "atual +/- 0.3".
-- Faixa morta de 0.05: mudanca menor que isso nao vale um clique nem um
-- registro no loop de aprendizado.
CREATE OR REPLACE VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v3 AS
SELECT
       v.keyword_hour_recommendation_id,
       v.campaign_id,
       v.campaign_name,
       v.ad_group_id,
       v.ad_group_name,
       v.keyword_text,
       v.match_type,
       v.event_hour,
       CASE WHEN t.ml_multiplier > eff.multiplier THEN 'BID_UP' WHEN t.ml_multiplier <= 0.35 THEN 'CUT_HOUR' ELSE 'BID_DOWN' END AS campaign_action_type,
       CASE WHEN t.ml_multiplier > eff.multiplier THEN 'INCREASE_EFFECTIVE_BID' ELSE 'DECREASE_EFFECTIVE_BID' END AS advisor_action,
       v.confidence,
       v.source_grain,
       v.sample_guard,
       v.execution_hint,
       v.base_bid,
       eff.multiplier::numeric AS current_hour_multiplier,
       t.ml_multiplier::numeric AS suggested_hour_multiplier,
       (v.base_bid * eff.multiplier)::numeric AS current_effective_bid,
       (v.base_bid * t.ml_multiplier)::numeric AS suggested_effective_bid,
       (v.base_bid * (t.ml_multiplier - eff.multiplier))::numeric AS effective_bid_delta,
       CASE WHEN eff.multiplier > 0 THEN ((t.ml_multiplier - eff.multiplier)/eff.multiplier*100)::numeric ELSE NULL END AS effective_bid_delta_percent,
       v.spend,
       v.orders,
       v.sales,
       v.roas,
       v.clicks,
       v.impressions,
       v.days_observed,
       v.window_from,
       v.window_to,
       v.ml_conversion_probability,
       v.ml_expected_roas,
       v.ml_good_hour,
       v.ml_agrees,
       v.priority_score,
       v.target_hour_has_data,
       v.target_impressions,
       v.target_clicks,
       v.target_spend,
       v.target_orders,
       v.target_sales,
       v.computed_at,
       v.target_ml_click_probability,
       v.target_ml_conversion_probability,
       v.target_ml_expected_roas,
       v.target_ml_good_hour,
       v.target_ml_label_caveat,
       v.target_ml_computed_at
,
       eff.scope AS current_multiplier_scope,
       t.alvo_roas::numeric      AS ml_target_roas,
       t.roas_ancora::numeric    AS ml_roas_ancora,
       t.roas_observado::numeric AS ml_roas_observado,
       t.gasto_observado::numeric AS ml_gasto_observado
FROM marketcloud_gold.gold_keyword_hourly_recommendations_v2 v
JOIN marketcloud_gold.gold_hourly_ml_target_multiplier t
  ON t.campaign_name = v.campaign_name AND t.event_hour = v.event_hour
JOIN LATERAL (
    SELECT b.keyword_id
    FROM marketcloud_bronze.bronze_swarm_current_bids b
    WHERE b.campaign_id = v.campaign_id
      AND coalesce(b.ad_group_id,'') = coalesce(v.ad_group_id,'')
      AND lower(trim(b.keyword_text)) = lower(trim(v.keyword_text))
      AND lower(trim(coalesce(b.match_type,''))) = lower(trim(coalesce(v.match_type,'')))
      AND upper(coalesce(b.state,'')) = 'ENABLED'
      AND coalesce(b.keyword_id,'') <> ''
    LIMIT 1
) k ON TRUE
LEFT JOIN LATERAL (
    SELECT coalesce(s.multiplier, 1.0) AS multiplier, coalesce(s.scope,'DEFAULT') AS scope
    FROM marketcloud_bronze.bronze_swarm_bid_schedule s
    WHERE s.hour_start <= v.event_hour AND s.hour_end > v.event_hour
      AND coalesce(s.day_of_week,'') = ''
      AND coalesce(s.profile_is_active, true) = true
      AND upper(coalesce(s.profile_status,'')) = 'PUBLISHED'
      AND s.multiplier IS NOT NULL
      AND (
            (s.scope = 'ENTITY'   AND s.campaign_id = v.campaign_id
                                  AND (s.entity_id = k.keyword_id
                                       OR (coalesce(s.entity_id,'') = ''
                                           AND lower(trim(coalesce(s.entity_label,''))) = lower(trim(v.keyword_text)))))
         OR (s.scope = 'AD_GROUP' AND s.campaign_id = v.campaign_id AND s.ad_group_id = v.ad_group_id)
         OR (s.scope = 'CAMPAIGN' AND s.campaign_id = v.campaign_id)
         OR (s.scope = 'GLOBAL')
      )
    ORDER BY CASE s.scope WHEN 'ENTITY' THEN 4 WHEN 'AD_GROUP' THEN 3
                          WHEN 'CAMPAIGN' THEN 2 WHEN 'GLOBAL' THEN 1 ELSE 0 END DESC
    LIMIT 1
) eff ON TRUE
WHERE abs(t.ml_multiplier - coalesce(eff.multiplier, 1.0)) >= 0.05;

COMMENT ON VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v3 IS
    'Keywords x hora: alvo do ML (gold_hourly_ml_target_multiplier) vs multiplicador efetivo real da keyword. Alvo absoluto -> aplicou, sai da lista.';
