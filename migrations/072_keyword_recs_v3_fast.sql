-- PERFORMANCE: a v3 da migration 070 levava 4m09s pra devolver 118 linhas — a
-- tela Keywords x hora ficava em "Carregando..." pra sempre e parecia travada.
--
-- Causa: ela juntava a gold_keyword_effective_multiplier, que faz
-- CROSS JOIN generate_series(0,23) sobre TODAS as ~3.8k keywords (92k linhas) e
-- resolve a hierarquia de cada uma, com lower(trim()) nas comparacoes. Ou seja:
-- calculava o universo inteiro pra depois filtrar as ~118 que interessam.
--
-- Fix: inverter. Partir das linhas da v2 (poucas) e resolver a hierarquia so
-- pra elas, com LATERAL. Mesma semantica, mesma precedencia
-- ENTITY>AD_GROUP>CAMPAIGN>GLOBAL — so que O(118) em vez de O(92k).
--
-- A gold_keyword_effective_multiplier continua existindo pra analise ad-hoc
-- ("qual o multiplicador de tudo?"), mas NAO deve ser usada dentro de join.
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
       v.campaign_action_type,
       CASE WHEN v.suggested_hour_multiplier > eff.multiplier THEN 'INCREASE_EFFECTIVE_BID' WHEN v.suggested_hour_multiplier < eff.multiplier THEN 'DECREASE_EFFECTIVE_BID' ELSE 'KEEP_EFFECTIVE_BID' END AS advisor_action,
       v.confidence,
       v.source_grain,
       v.sample_guard,
       v.execution_hint,
       v.base_bid,
       eff.multiplier::numeric AS current_hour_multiplier,
       v.suggested_hour_multiplier,
       (v.base_bid * eff.multiplier)::numeric AS current_effective_bid,
       v.suggested_effective_bid,
       (v.suggested_effective_bid - v.base_bid * eff.multiplier)::numeric AS effective_bid_delta,
       CASE WHEN v.base_bid * eff.multiplier > 0 THEN ((v.suggested_effective_bid - v.base_bid * eff.multiplier) / (v.base_bid * eff.multiplier) * 100)::numeric ELSE NULL END AS effective_bid_delta_percent,
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
       eff.scope AS current_multiplier_scope
FROM marketcloud_gold.gold_keyword_hourly_recommendations_v2 v
-- keyword_id vivo dessa linha (a v2 so tem texto+match)
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
-- multiplicador que essa keyword REALMENTE tem nessa hora
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
-- some o que ja esta no valor sugerido: nao ha o que aplicar
WHERE abs(v.suggested_hour_multiplier - coalesce(eff.multiplier, 1.0)) >= 0.001;

COMMENT ON VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v3 IS
    'Recomendacoes keyword x hora ja descontando a agenda propria da keyword. Resolve a hierarquia por LATERAL sobre as linhas da v2 (rapido); nao juntar com gold_keyword_effective_multiplier.';

COMMENT ON VIEW marketcloud_gold.gold_keyword_effective_multiplier IS
    'Multiplicador de TODAS as keywords x 24h (ENTITY>AD_GROUP>CAMPAIGN>GLOBAL). Uso ad-hoc/analise: sao ~92k linhas, NAO use dentro de join (foi o que travou a tela em 15/07).';
