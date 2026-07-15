-- v3: mesma recomendacao da v2, mas com o multiplicador ATUAL da keyword de
-- verdade (hierarquia ENTITY>AD_GROUP>CAMPAIGN>GLOBAL), nao o min() da campanha.
-- Sem isso a tela pedia pra subir lance que ja estava no valor sugerido:
-- 36 das 94 linhas aplicaveis em 15/07 eram esse fantasma.
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
       CASE WHEN v.suggested_hour_multiplier > eff.effective_multiplier THEN 'INCREASE_EFFECTIVE_BID' WHEN v.suggested_hour_multiplier < eff.effective_multiplier THEN 'DECREASE_EFFECTIVE_BID' ELSE 'KEEP_EFFECTIVE_BID' END AS advisor_action,
       v.confidence,
       v.source_grain,
       v.sample_guard,
       v.execution_hint,
       v.base_bid,
       eff.effective_multiplier::numeric AS current_hour_multiplier,
       v.suggested_hour_multiplier,
       (v.base_bid * eff.effective_multiplier)::numeric AS current_effective_bid,
       v.suggested_effective_bid,
       (v.suggested_effective_bid - v.base_bid * eff.effective_multiplier)::numeric AS effective_bid_delta,
       CASE WHEN v.base_bid * eff.effective_multiplier > 0 THEN ((v.suggested_effective_bid - v.base_bid * eff.effective_multiplier) / (v.base_bid * eff.effective_multiplier) * 100)::numeric ELSE NULL END AS effective_bid_delta_percent,
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
       eff.effective_scope AS current_multiplier_scope
FROM marketcloud_gold.gold_keyword_hourly_recommendations_v2 v
JOIN marketcloud_gold.gold_keyword_effective_multiplier eff
  ON eff.campaign_id = v.campaign_id
 AND coalesce(eff.ad_group_id,'') = coalesce(v.ad_group_id,'')
 AND lower(trim(eff.keyword_text)) = lower(trim(v.keyword_text))
 AND lower(trim(coalesce(eff.match_type,''))) = lower(trim(coalesce(v.match_type,'')))
 AND eff.event_hour = v.event_hour
-- some o que ja esta no valor sugerido: nao ha o que aplicar
WHERE abs(v.suggested_hour_multiplier - eff.effective_multiplier) >= 0.001;

COMMENT ON VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v3 IS
    'Recomendacoes keyword x hora ja descontando a agenda propria da keyword. Usada pela tela Keywords x hora.';
