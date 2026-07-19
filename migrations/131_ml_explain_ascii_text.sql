-- =====================================================================
-- ML explainability text normalization.
-- Keeps the math from migration 130 and replaces operator-facing text with
-- ASCII-only strings to avoid mojibake in the dashboard.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.v_keyword_hourly_experiment_candidates_v1 AS
SELECT
    r.keyword_hour_recommendation_id,
    r.campaign_id,
    r.campaign_name,
    r.ad_group_id,
    r.keyword_text,
    r.event_hour,
    CASE
        WHEN r.vetoed THEN 'BLOCKED'
        WHEN r.campaign_action_type = 'BID_UP'
         AND COALESCE(r.target_ml_click_probability,0) >= 0.50
         AND COALESCE(r.target_ml_conversion_probability,0) BETWEEN 0.02 AND 0.20
         AND COALESCE(r.target_ml_expected_roas,0) < COALESCE(r.ml_expected_roas,0) * 0.95 THEN 'CONTROLLED_UPSIDE_TEST'
        WHEN r.campaign_action_type IN ('BID_DOWN','CUT_HOUR')
         AND COALESCE(r.target_ml_click_probability,0) >= 0.50
         AND COALESCE(r.target_ml_expected_roas,0) >= COALESCE(r.ml_target_roas, r.ml_expected_roas,0) THEN 'PROTECT_HOLDOUT'
        WHEN r.confidence = 'LOW' THEN 'OBSERVE_MORE'
        ELSE 'STANDARD'
    END AS experiment_policy,
    CASE
        WHEN r.vetoed THEN 'Nao testar: veto ativo.'
        WHEN r.campaign_action_type = 'BID_UP'
         AND COALESCE(r.target_ml_click_probability,0) >= 0.50
         AND COALESCE(r.target_ml_conversion_probability,0) BETWEEN 0.02 AND 0.20
         AND COALESCE(r.target_ml_expected_roas,0) < COALESCE(r.ml_expected_roas,0) * 0.95
          THEN 'Teste pequeno: target tem clique, mas conversao/ROAS ainda nao confirmou campanha.'
        WHEN r.campaign_action_type IN ('BID_DOWN','CUT_HOUR')
         AND COALESCE(r.target_ml_click_probability,0) >= 0.50
         AND COALESCE(r.target_ml_expected_roas,0) >= COALESCE(r.ml_target_roas, r.ml_expected_roas,0)
          THEN 'Manter parte em controle: target parece melhor que o corte sugerido pela campanha.'
        WHEN r.confidence = 'LOW' THEN 'Pouca confianca: esperar mais AMS antes de aplicar.'
        ELSE 'Aplicacao padrao com monitoramento.'
    END AS experiment_reason,
    CASE
        WHEN r.confidence = 'HIGH' THEN 0.10
        WHEN r.confidence = 'MEDIUM' THEN 0.07
        ELSE 0.03
    END::numeric AS suggested_test_fraction,
    CASE
        WHEN r.campaign_action_type = 'BID_UP'
          THEN LEAST(COALESCE(r.suggested_hour_multiplier,1), COALESCE(r.current_hour_multiplier,1) + 0.20)
        ELSE r.suggested_hour_multiplier
    END::numeric AS capped_test_multiplier
FROM marketcloud_gold.gold_keyword_hourly_recommendations_v3 r;

CREATE OR REPLACE VIEW marketcloud_gold.v_keyword_hourly_recommendation_explain_v1 AS
SELECT
    r.keyword_hour_recommendation_id,
    jsonb_build_object(
        'summary',
            CASE
                WHEN r.vetoed THEN 'Recomendacao bloqueada por veto de seguranca.'
                WHEN e.experiment_policy = 'CONTROLLED_UPSIDE_TEST' THEN 'Oportunidade boa para teste controlado, nao para aposta cega.'
                WHEN e.experiment_policy = 'PROTECT_HOLDOUT' THEN 'Corte/reducao com ressalva: target tem sinais para segurar parte em controle.'
                WHEN COALESCE(r.ml_agrees,false) THEN 'Campanha e modelo concordam com a direcao.'
                ELSE 'Ha conflito entre regra/campanha e ML; revisar antes de aplicar amplo.'
            END,
        'commercial', jsonb_build_object(
            'sale_price_brl', COALESCE(cx.sale_price_brl,0),
            'unit_cost_brl', COALESCE(cx.unit_cost_brl,0),
            'stock_available', COALESCE(cx.stock_available,0),
            'gross_margin_pct', COALESCE(cx.gross_margin_pct,0),
            'stock_days_of_cover', COALESCE(cx.stock_days_of_cover,0),
            'has_competitor_price', COALESCE(cx.has_competitor_price,0),
            'has_bsr', COALESCE(cx.has_bsr,0)
        ),
        'calendar', jsonb_build_object(
            'weekend_share', COALESCE(tc.weekend_share, cc.weekend_share,0),
            'month_start_share', COALESCE(tc.month_start_share, cc.month_start_share,0),
            'month_middle_share', COALESCE(tc.month_middle_share, cc.month_middle_share,0),
            'month_end_share', COALESCE(tc.month_end_share, cc.month_end_share,0),
            'paycheck_window_share', COALESCE(tc.paycheck_window_share, cc.paycheck_window_share,0),
            'pre_event_30d_share', COALESCE(tc.pre_event_30d_share, cc.pre_event_30d_share,0),
            'pre_event_14d_share', COALESCE(tc.pre_event_14d_share, cc.pre_event_14d_share,0),
            'pre_event_7d_share', COALESCE(tc.pre_event_7d_share, cc.pre_event_7d_share,0),
            'event_day_share', COALESCE(tc.event_day_share, cc.event_day_share,0),
            'post_event_7d_share', COALESCE(tc.post_event_7d_share, cc.post_event_7d_share,0)
        ),
        'ml', jsonb_build_object(
            'campaign_conversion_probability', r.ml_conversion_probability,
            'campaign_expected_roas', r.ml_expected_roas,
            'target_click_probability', r.target_ml_click_probability,
            'target_conversion_probability', r.target_ml_conversion_probability,
            'target_expected_roas', r.target_ml_expected_roas,
            'target_roas_30d', COALESCE(hc.target_roas_30d,0),
            'target_cvr_30d', COALESCE(hc.target_cvr_30d,0),
            'campaign_roas_30d', COALESCE(hc.campaign_roas_30d,0)
        ),
        'experiment', jsonb_build_object(
            'policy', e.experiment_policy,
            'reason', e.experiment_reason,
            'suggested_test_fraction', e.suggested_test_fraction,
            'capped_test_multiplier', e.capped_test_multiplier
        ),
        'coverage', jsonb_build_object(
            'competitor_price_available', COALESCE(cx.has_competitor_price,0) = 1,
            'bsr_available', COALESCE(cx.has_bsr,0) = 1,
            'target_ml_available', r.target_ml_click_probability IS NOT NULL,
            'commercial_available', cx.campaign_id IS NOT NULL
        )
    ) AS explanation_json
FROM marketcloud_gold.gold_keyword_hourly_recommendations_v3 r
LEFT JOIN marketcloud_gold.v_keyword_hourly_experiment_candidates_v1 e
  ON e.keyword_hour_recommendation_id = r.keyword_hour_recommendation_id
LEFT JOIN marketcloud_features.feature_campaign_commercial_context_v1 cx
  ON cx.campaign_id = r.campaign_id
LEFT JOIN marketcloud_features.feature_campaign_calendar_context_v1 cc
  ON cc.campaign_id = r.campaign_id AND cc.event_hour = r.event_hour
LEFT JOIN LATERAL (
    SELECT p.target_entity_key
    FROM marketcloud_gold.hourly_target_ml_predictions_v3 p
    WHERE p.campaign_id = r.campaign_id
      AND COALESCE(p.ad_group_id,'') = COALESCE(r.ad_group_id,'')
      AND p.event_hour = r.event_hour
      AND lower(trim(COALESCE(p.keyword_text, p.targeting, ''))) = lower(trim(COALESCE(r.keyword_text,'')))
    LIMIT 1
) tk ON TRUE
LEFT JOIN marketcloud_features.feature_target_calendar_context_v1 tc
  ON tc.campaign_id = r.campaign_id
 AND COALESCE(tc.ad_group_id,'') = COALESCE(r.ad_group_id,'')
 AND tc.target_entity_key = tk.target_entity_key
 AND tc.event_hour = r.event_hour
LEFT JOIN marketcloud_features.feature_target_hierarchical_context_v1 hc
  ON hc.campaign_id = r.campaign_id
 AND COALESCE(hc.ad_group_id,'') = COALESCE(r.ad_group_id,'')
 AND hc.event_hour = r.event_hour
 AND hc.target_entity_key = tk.target_entity_key;

COMMENT ON VIEW marketcloud_gold.v_keyword_hourly_recommendation_explain_v1 IS
    'ASCII explanation per keyword-hour recommendation: commercial, calendar, ML and controlled experiment policy.';
