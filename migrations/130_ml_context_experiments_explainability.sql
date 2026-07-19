-- =====================================================================
-- ML context v2: event-distance, hierarchical target signal,
-- controlled experiments and explanation surface.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_features.feature_calendar_event_distance_v1 AS
WITH days AS (
    SELECT data_date
    FROM marketcloud_features.feature_calendar_day_v1
), event_days AS (
    SELECT data_date, 'MOTHERS_DAY'::text AS event_name FROM marketcloud_features.feature_calendar_day_v1 WHERE is_mothers_day = 1
    UNION ALL
    SELECT data_date, 'FATHERS_DAY' FROM marketcloud_features.feature_calendar_day_v1 WHERE is_fathers_day = 1
    UNION ALL
    SELECT data_date, 'BLACK_FRIDAY' FROM marketcloud_features.feature_calendar_day_v1 WHERE is_black_friday = 1
    UNION ALL
    SELECT data_date, 'CHRISTMAS_RUNUP' FROM marketcloud_features.feature_calendar_day_v1 WHERE is_christmas_runup = 1
    UNION ALL
    SELECT data_date, 'BR_HOLIDAY' FROM marketcloud_features.feature_calendar_day_v1 WHERE is_br_holiday = 1
), nearest AS (
    SELECT
        d.data_date,
        e.event_name,
        (e.data_date - d.data_date)::int AS days_to_event,
        ABS((e.data_date - d.data_date)::int) AS abs_days_to_event,
        ROW_NUMBER() OVER (PARTITION BY d.data_date ORDER BY ABS((e.data_date - d.data_date)::int), e.data_date) AS rn
    FROM days d
    JOIN event_days e ON e.data_date BETWEEN d.data_date - 30 AND d.data_date + 30
)
SELECT
    d.data_date,
    COALESCE(n.days_to_event, 31) AS days_to_nearest_event,
    COALESCE(n.abs_days_to_event, 31) AS abs_days_to_nearest_event,
    CASE WHEN n.days_to_event BETWEEN 1 AND 30 THEN 1 ELSE 0 END::int AS is_pre_event_30d,
    CASE WHEN n.days_to_event BETWEEN 1 AND 14 THEN 1 ELSE 0 END::int AS is_pre_event_14d,
    CASE WHEN n.days_to_event BETWEEN 1 AND 7 THEN 1 ELSE 0 END::int AS is_pre_event_7d,
    CASE WHEN n.days_to_event = 0 THEN 1 ELSE 0 END::int AS is_event_day,
    CASE WHEN n.days_to_event BETWEEN -7 AND -1 THEN 1 ELSE 0 END::int AS is_post_event_7d,
    COALESCE(n.event_name, 'NONE') AS nearest_event_name
FROM days d
LEFT JOIN nearest n ON n.data_date = d.data_date AND n.rn = 1;

COMMENT ON VIEW marketcloud_features.feature_calendar_event_distance_v1 IS
    'Distância até evento comercial/feriado mais próximo. Usado como contexto sazonal do ML.';

CREATE OR REPLACE VIEW marketcloud_features.feature_campaign_calendar_context_v1 AS
SELECT
    a.campaign_id,
    a.event_hour,
    AVG(c.day_of_week)::numeric AS avg_day_of_week,
    AVG(c.is_weekend)::numeric AS weekend_share,
    AVG(c.day_of_month)::numeric AS avg_day_of_month,
    AVG(c.week_of_month)::numeric AS avg_week_of_month,
    AVG(c.month_of_year)::numeric AS avg_month_of_year,
    AVG(c.is_month_start)::numeric AS month_start_share,
    AVG(c.is_month_middle)::numeric AS month_middle_share,
    AVG(c.is_month_end)::numeric AS month_end_share,
    AVG(c.is_paycheck_window)::numeric AS paycheck_window_share,
    AVG(c.is_midmonth_window)::numeric AS midmonth_window_share,
    AVG(c.is_br_holiday)::numeric AS holiday_share,
    AVG(c.is_holiday_eve)::numeric AS holiday_eve_share,
    AVG(c.is_post_holiday)::numeric AS post_holiday_share,
    AVG(c.is_commercial_event)::numeric AS commercial_event_share,
    AVG(c.is_mothers_day)::numeric AS mothers_day_share,
    AVG(c.is_fathers_day)::numeric AS fathers_day_share,
    AVG(c.is_black_friday)::numeric AS black_friday_share,
    AVG(c.is_christmas_runup)::numeric AS christmas_runup_share,
    AVG(ed.days_to_nearest_event)::numeric AS avg_days_to_nearest_event,
    AVG(ed.abs_days_to_nearest_event)::numeric AS avg_abs_days_to_nearest_event,
    AVG(ed.is_pre_event_30d)::numeric AS pre_event_30d_share,
    AVG(ed.is_pre_event_14d)::numeric AS pre_event_14d_share,
    AVG(ed.is_pre_event_7d)::numeric AS pre_event_7d_share,
    AVG(ed.is_event_day)::numeric AS event_day_share,
    AVG(ed.is_post_event_7d)::numeric AS post_event_7d_share
FROM marketcloud_bronze.bronze_ams_hourly a
JOIN marketcloud_features.feature_calendar_day_v1 c ON c.data_date = a.data_date
JOIN marketcloud_features.feature_calendar_event_distance_v1 ed ON ed.data_date = a.data_date
WHERE COALESCE(a.campaign_id,'') <> ''
GROUP BY a.campaign_id, a.event_hour;

CREATE OR REPLACE VIEW marketcloud_features.feature_target_calendar_context_v1 AS
SELECT
    a.campaign_id,
    COALESCE(a.ad_group_id,'') AS ad_group_id,
    a.target_entity_key,
    a.event_hour,
    AVG(c.day_of_week)::numeric AS avg_day_of_week,
    AVG(c.is_weekend)::numeric AS weekend_share,
    AVG(c.day_of_month)::numeric AS avg_day_of_month,
    AVG(c.week_of_month)::numeric AS avg_week_of_month,
    AVG(c.month_of_year)::numeric AS avg_month_of_year,
    AVG(c.is_month_start)::numeric AS month_start_share,
    AVG(c.is_month_middle)::numeric AS month_middle_share,
    AVG(c.is_month_end)::numeric AS month_end_share,
    AVG(c.is_paycheck_window)::numeric AS paycheck_window_share,
    AVG(c.is_midmonth_window)::numeric AS midmonth_window_share,
    AVG(c.is_br_holiday)::numeric AS holiday_share,
    AVG(c.is_holiday_eve)::numeric AS holiday_eve_share,
    AVG(c.is_post_holiday)::numeric AS post_holiday_share,
    AVG(c.is_commercial_event)::numeric AS commercial_event_share,
    AVG(c.is_mothers_day)::numeric AS mothers_day_share,
    AVG(c.is_fathers_day)::numeric AS fathers_day_share,
    AVG(c.is_black_friday)::numeric AS black_friday_share,
    AVG(c.is_christmas_runup)::numeric AS christmas_runup_share,
    AVG(ed.days_to_nearest_event)::numeric AS avg_days_to_nearest_event,
    AVG(ed.abs_days_to_nearest_event)::numeric AS avg_abs_days_to_nearest_event,
    AVG(ed.is_pre_event_30d)::numeric AS pre_event_30d_share,
    AVG(ed.is_pre_event_14d)::numeric AS pre_event_14d_share,
    AVG(ed.is_pre_event_7d)::numeric AS pre_event_7d_share,
    AVG(ed.is_event_day)::numeric AS event_day_share,
    AVG(ed.is_post_event_7d)::numeric AS post_event_7d_share
FROM marketcloud_bronze.bronze_ams_hourly_target a
JOIN marketcloud_features.feature_calendar_day_v1 c ON c.data_date = a.data_date
JOIN marketcloud_features.feature_calendar_event_distance_v1 ed ON ed.data_date = a.data_date
WHERE NULLIF(TRIM(COALESCE(a.target_entity_key,'')), '') IS NOT NULL
GROUP BY a.campaign_id, COALESCE(a.ad_group_id,''), a.target_entity_key, a.event_hour;

CREATE OR REPLACE VIEW marketcloud_features.feature_target_hierarchical_context_v1 AS
WITH target_30d AS (
    SELECT
        campaign_id,
        COALESCE(ad_group_id,'') AS ad_group_id,
        target_entity_key,
        event_hour,
        COUNT(DISTINCT data_date)::numeric AS target_days_30d,
        SUM(GREATEST(COALESCE(impressions,0),0))::numeric AS target_impressions_30d,
        SUM(GREATEST(COALESCE(clicks,0),0))::numeric AS target_clicks_30d,
        SUM(GREATEST(COALESCE(spend,0),0))::numeric AS target_spend_30d,
        SUM(GREATEST(COALESCE(orders_14d,0), COALESCE(orders_7d,0), COALESCE(orders_1d,0), 0))::numeric AS target_orders_30d,
        SUM(GREATEST(COALESCE(sales_14d,0), COALESCE(sales_7d,0), COALESCE(sales_1d,0), 0))::numeric AS target_sales_30d
    FROM marketcloud_bronze.bronze_ams_hourly_target
    WHERE data_date >= CURRENT_DATE - 30
      AND NULLIF(TRIM(COALESCE(target_entity_key,'')), '') IS NOT NULL
    GROUP BY campaign_id, COALESCE(ad_group_id,''), target_entity_key, event_hour
), campaign_30d AS (
    SELECT
        campaign_id,
        event_hour,
        COUNT(DISTINCT data_date)::numeric AS campaign_days_30d,
        SUM(GREATEST(COALESCE(impressions,0),0))::numeric AS campaign_impressions_30d,
        SUM(GREATEST(COALESCE(clicks,0),0))::numeric AS campaign_clicks_30d,
        SUM(GREATEST(COALESCE(spend,0),0))::numeric AS campaign_spend_30d,
        SUM(GREATEST(COALESCE(orders_14d,0), COALESCE(orders_7d,0), COALESCE(orders_1d,0), 0))::numeric AS campaign_orders_30d,
        SUM(GREATEST(COALESCE(sales_14d,0), COALESCE(sales_7d,0), COALESCE(sales_1d,0), 0))::numeric AS campaign_sales_30d
    FROM marketcloud_bronze.bronze_ams_hourly
    WHERE data_date >= CURRENT_DATE - 30
      AND COALESCE(campaign_id,'') <> ''
    GROUP BY campaign_id, event_hour
)
SELECT
    t.campaign_id,
    t.ad_group_id,
    t.target_entity_key,
    t.event_hour,
    t.target_days_30d,
    t.target_impressions_30d,
    t.target_clicks_30d,
    t.target_spend_30d,
    t.target_orders_30d,
    t.target_sales_30d,
    CASE WHEN t.target_impressions_30d > 0 THEN t.target_clicks_30d / NULLIF(t.target_impressions_30d,0) ELSE 0 END::numeric AS target_ctr_30d,
    CASE WHEN t.target_clicks_30d > 0 THEN t.target_orders_30d / NULLIF(t.target_clicks_30d,0) ELSE 0 END::numeric AS target_cvr_30d,
    CASE WHEN t.target_spend_30d > 0 THEN t.target_sales_30d / NULLIF(t.target_spend_30d,0) ELSE 0 END::numeric AS target_roas_30d,
    COALESCE(c.campaign_days_30d,0)::numeric AS campaign_days_30d,
    COALESCE(c.campaign_impressions_30d,0)::numeric AS campaign_impressions_30d,
    COALESCE(c.campaign_clicks_30d,0)::numeric AS campaign_clicks_30d,
    COALESCE(c.campaign_spend_30d,0)::numeric AS campaign_spend_30d,
    COALESCE(c.campaign_orders_30d,0)::numeric AS campaign_orders_30d,
    COALESCE(c.campaign_sales_30d,0)::numeric AS campaign_sales_30d,
    CASE WHEN COALESCE(c.campaign_impressions_30d,0) > 0 THEN c.campaign_clicks_30d / NULLIF(c.campaign_impressions_30d,0) ELSE 0 END::numeric AS campaign_ctr_30d,
    CASE WHEN COALESCE(c.campaign_clicks_30d,0) > 0 THEN c.campaign_orders_30d / NULLIF(c.campaign_clicks_30d,0) ELSE 0 END::numeric AS campaign_cvr_30d,
    CASE WHEN COALESCE(c.campaign_spend_30d,0) > 0 THEN c.campaign_sales_30d / NULLIF(c.campaign_spend_30d,0) ELSE 0 END::numeric AS campaign_roas_30d,
    COALESCE(p.conversion_probability,0)::numeric AS campaign_ml_conversion_probability,
    COALESCE(p.expected_roas,0)::numeric AS campaign_ml_expected_roas,
    CASE WHEN p.predicted_good_hour THEN 1 ELSE 0 END::int AS campaign_ml_good_hour
FROM target_30d t
LEFT JOIN campaign_30d c ON c.campaign_id = t.campaign_id AND c.event_hour = t.event_hour
LEFT JOIN marketcloud_gold.gold_campaign_identity gi ON gi.campaign_id = t.campaign_id
LEFT JOIN marketcloud_gold.hourly_ml_predictions_v2 p
  ON p.campaign_name = gi.campaign_name
 AND p.event_hour = t.event_hour;

COMMENT ON VIEW marketcloud_features.feature_target_hierarchical_context_v1 IS
    'Sinais hierárquicos para o V3 target: histórico do target, campanha/hora e previsão campanha/hora.';

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
        WHEN r.vetoed THEN 'Não testar: veto ativo.'
        WHEN r.campaign_action_type = 'BID_UP'
         AND COALESCE(r.target_ml_click_probability,0) >= 0.50
         AND COALESCE(r.target_ml_conversion_probability,0) BETWEEN 0.02 AND 0.20
         AND COALESCE(r.target_ml_expected_roas,0) < COALESCE(r.ml_expected_roas,0) * 0.95
          THEN 'Teste pequeno: target tem clique, mas conversão/ROAS ainda não confirmou campanha.'
        WHEN r.campaign_action_type IN ('BID_DOWN','CUT_HOUR')
         AND COALESCE(r.target_ml_click_probability,0) >= 0.50
         AND COALESCE(r.target_ml_expected_roas,0) >= COALESCE(r.ml_target_roas, r.ml_expected_roas,0)
          THEN 'Manter parte em controle: target parece melhor que o corte sugerido pela campanha.'
        WHEN r.confidence = 'LOW' THEN 'Pouca confiança: esperar mais AMS antes de aplicar.'
        ELSE 'Aplicação padrão com monitoramento.'
    END AS experiment_reason,
    CASE
        WHEN r.confidence = 'HIGH' THEN 0.10
        WHEN r.confidence = 'MEDIUM' THEN 0.07
        ELSE 0.03
    END::numeric AS suggested_test_fraction,
    CASE WHEN r.campaign_action_type = 'BID_UP' THEN LEAST(COALESCE(r.suggested_hour_multiplier,1), COALESCE(r.current_hour_multiplier,1) + 0.20) ELSE r.suggested_hour_multiplier END::numeric AS capped_test_multiplier
FROM marketcloud_gold.gold_keyword_hourly_recommendations_v3 r;

CREATE OR REPLACE VIEW marketcloud_gold.v_keyword_hourly_recommendation_explain_v1 AS
SELECT
    r.keyword_hour_recommendation_id,
    jsonb_build_object(
        'summary',
            CASE
                WHEN r.vetoed THEN 'Recomendação bloqueada por veto de segurança.'
                WHEN e.experiment_policy = 'CONTROLLED_UPSIDE_TEST' THEN 'Oportunidade boa para teste controlado, não para aposta cega.'
                WHEN e.experiment_policy = 'PROTECT_HOLDOUT' THEN 'Corte/redução com ressalva: target tem sinais para segurar parte em controle.'
                WHEN COALESCE(r.ml_agrees,false) THEN 'Campanha e modelo concordam com a direção.'
                ELSE 'Há conflito entre regra/campanha e ML; revisar antes de aplicar amplo.'
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
LEFT JOIN marketcloud_features.feature_target_calendar_context_v1 tc
  ON tc.campaign_id = r.campaign_id
 AND COALESCE(tc.ad_group_id,'') = COALESCE(r.ad_group_id,'')
 AND tc.target_entity_key = (
      SELECT p.target_entity_key
      FROM marketcloud_gold.hourly_target_ml_predictions_v3 p
      WHERE p.campaign_id = r.campaign_id
        AND COALESCE(p.ad_group_id,'') = COALESCE(r.ad_group_id,'')
        AND p.event_hour = r.event_hour
        AND lower(trim(COALESCE(p.keyword_text, p.targeting, ''))) = lower(trim(COALESCE(r.keyword_text,'')))
      LIMIT 1
 )
 AND tc.event_hour = r.event_hour
LEFT JOIN marketcloud_features.feature_target_hierarchical_context_v1 hc
  ON hc.campaign_id = r.campaign_id
 AND COALESCE(hc.ad_group_id,'') = COALESCE(r.ad_group_id,'')
 AND hc.event_hour = r.event_hour
 AND hc.target_entity_key = tc.target_entity_key;

COMMENT ON VIEW marketcloud_gold.v_keyword_hourly_recommendation_explain_v1 IS
    'Explicação estruturada por recomendação keyword/hora: comercial, calendário, ML e política de teste controlado.';
