-- =====================================================================
-- 107: Veto de target ruim em recomendacao herdada de campanha.
--
-- Problema: uma hora de CAMPANHA pode estar boa, mas uma keyword/target
-- especifica pode ter modelo V3 claramente ruim. Nesses casos, a tela
-- Keywords x hora nao pode transformar sinal herdado em BID_UP.
--
-- Regra:
-- - recomendacao herdada da campanha continua podendo reduzir/cortar;
-- - para aumentar exposicao, se houver ML do target e ele estiver ruim,
--   a linha sai da view e nao chega na UI/acao humana.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v3 AS
SELECT v.keyword_hour_recommendation_id,
    v.campaign_id,
    v.campaign_name,
    v.ad_group_id,
    v.ad_group_name,
    v.keyword_text,
    v.match_type,
    v.event_hour,
        CASE
            WHEN t.ml_multiplier > eff.multiplier THEN 'BID_UP'::text
            WHEN t.ml_multiplier <= 0.35 THEN 'CUT_HOUR'::text
            ELSE 'BID_DOWN'::text
        END AS campaign_action_type,
        CASE
            WHEN t.ml_multiplier > eff.multiplier THEN 'INCREASE_EFFECTIVE_BID'::text
            ELSE 'DECREASE_EFFECTIVE_BID'::text
        END AS advisor_action,
    v.confidence,
    v.source_grain,
    v.sample_guard,
    v.execution_hint,
    v.base_bid,
    eff.multiplier AS current_hour_multiplier,
    t.ml_multiplier AS suggested_hour_multiplier,
    v.base_bid * eff.multiplier AS current_effective_bid,
    v.base_bid * t.ml_multiplier AS suggested_effective_bid,
    v.base_bid * (t.ml_multiplier - eff.multiplier) AS effective_bid_delta,
        CASE
            WHEN eff.multiplier > 0::numeric THEN (t.ml_multiplier - eff.multiplier) / eff.multiplier * 100::numeric
            ELSE NULL::numeric
        END AS effective_bid_delta_percent,
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
    v.target_ml_computed_at,
    eff.scope AS current_multiplier_scope,
    t.alvo_roas AS ml_target_roas,
    t.roas_ancora AS ml_roas_ancora,
    t.roas_observado AS ml_roas_observado,
    t.gasto_observado AS ml_gasto_observado
   FROM marketcloud_gold.gold_keyword_hourly_recommendations_v2 v
     JOIN marketcloud_gold.gold_hourly_ml_target_multiplier t ON t.campaign_name = v.campaign_name AND t.event_hour = v.event_hour
     JOIN LATERAL ( SELECT b.keyword_id
           FROM marketcloud_bronze.bronze_swarm_current_bids b
          WHERE b.campaign_id = v.campaign_id
            AND COALESCE(b.ad_group_id, ''::text) = COALESCE(v.ad_group_id, ''::text)
            AND lower(TRIM(BOTH FROM b.keyword_text)) = lower(TRIM(BOTH FROM v.keyword_text))
            AND lower(TRIM(BOTH FROM COALESCE(b.match_type, ''::text))) = lower(TRIM(BOTH FROM COALESCE(v.match_type, ''::text)))
            AND upper(COALESCE(b.state, ''::text)) = 'ENABLED'::text
            AND COALESCE(b.keyword_id, ''::text) <> ''::text
         LIMIT 1) k ON true
     LEFT JOIN LATERAL ( SELECT COALESCE(s.multiplier, 1.0) AS multiplier,
            COALESCE(s.scope, 'DEFAULT'::text) AS scope
           FROM marketcloud_bronze.bronze_swarm_bid_schedule s
          WHERE s.hour_start <= v.event_hour
            AND s.hour_end > v.event_hour
            AND COALESCE(s.day_of_week, ''::text) = ''::text
            AND COALESCE(s.profile_is_active, true) = true
            AND upper(COALESCE(s.profile_status, ''::text)) = 'PUBLISHED'::text
            AND s.multiplier IS NOT NULL
            AND (
                s.scope = 'ENTITY'::text AND s.campaign_id = v.campaign_id
                    AND (s.entity_id = k.keyword_id OR COALESCE(s.entity_id, ''::text) = ''::text AND lower(TRIM(BOTH FROM COALESCE(s.entity_label, ''::text))) = lower(TRIM(BOTH FROM v.keyword_text)))
                OR s.scope = 'AD_GROUP'::text AND s.campaign_id = v.campaign_id AND s.ad_group_id = v.ad_group_id
                OR s.scope = 'CAMPAIGN'::text AND s.campaign_id = v.campaign_id
                OR s.scope = 'GLOBAL'::text
            )
          ORDER BY (
                CASE s.scope
                    WHEN 'ENTITY'::text THEN 4
                    WHEN 'AD_GROUP'::text THEN 3
                    WHEN 'CAMPAIGN'::text THEN 2
                    WHEN 'GLOBAL'::text THEN 1
                    ELSE 0
                END) DESC
         LIMIT 1) eff ON true
  WHERE abs(t.ml_multiplier - COALESCE(eff.multiplier, 1.0)) >= 0.05
  AND NOT EXISTS (
      SELECT 1 FROM marketcloud_control.holdout_cells hc
      WHERE hc.campaign_name = v.campaign_name
        AND hc.event_hour = v.event_hour
        AND hc.grupo = 'CONTROLE'
  )
  AND NOT (
      v.source_grain = 'CAMPAIGN_HOUR_INHERITED'
      AND t.ml_multiplier > eff.multiplier
      AND v.target_ml_click_probability IS NOT NULL
      AND (
          COALESCE(v.target_ml_expected_roas, 0) <= 0.01
          OR COALESCE(v.target_ml_conversion_probability, 0) <= 0.01
          OR COALESCE(v.target_ml_click_probability, 0) < 0.15
          OR (
              t.alvo_roas IS NOT NULL
              AND v.target_ml_expected_roas IS NOT NULL
              AND v.target_ml_expected_roas < t.alvo_roas * 0.60
          )
      )
  );

COMMENT ON VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v3 IS
    'Keywords x hora: alvo do ML vs multiplicador efetivo real da keyword. BID_UP herdado da campanha e vetado quando ML target indica baixa eficiencia.';
