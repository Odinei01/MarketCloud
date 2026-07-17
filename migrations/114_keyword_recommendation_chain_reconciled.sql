-- =====================================================================
-- 114: Reconciliacao do chain de recomendacao keyword x hora.
--
-- Corrige a colisao/incoerencia entre a soft_cut (minha) e a cadeia de
-- auditoria (109-113 paralela), que ficaram desconectadas:
--   - candidates_v1 era orfa (nenhuma migration a criava) -> nao reprodutivel;
--   - v3 vivo era a soft_cut standalone, nao consumia o audit;
--   - dois arquivos 109_*.
--
-- Arquitetura final (uma migration, self-contained, reprodutivel):
--   candidates_v1  = TODOS os candidatos, multiplicador SUAVIZADO por evidencia
--                    (w=min(1,cliques/10), toward current), veto/sem_dado,
--                    observabilidade (evidence_weight, raw_suggested_multiplier).
--   audit_v1       = parecer APPROVED/REVIEW/BLOCKED + dedup por celula.
--   v3             = fila ACIONAVEL = APPROVED, acao real, sem duplicata.
-- =====================================================================

DROP VIEW IF EXISTS marketcloud_gold.gold_keyword_hourly_recommendations_v3;
DROP VIEW IF EXISTS marketcloud_gold.gold_keyword_hourly_recommendation_audit_v1;
DROP VIEW IF EXISTS marketcloud_gold.gold_keyword_hourly_recommendations_candidates_v1;

-- ---------- 1) candidates_v1: observavel + suavizado ----------
CREATE VIEW marketcloud_gold.gold_keyword_hourly_recommendations_candidates_v1 AS
WITH raw AS (
    SELECT
        v.keyword_hour_recommendation_id, v.campaign_id, v.campaign_name,
        v.ad_group_id, v.ad_group_name, v.keyword_text, v.match_type, v.event_hour,
        v.confidence, v.source_grain, v.sample_guard, v.execution_hint, v.base_bid,
        v.spend, v.orders, v.sales, v.roas, v.clicks, v.impressions, v.days_observed,
        v.window_from, v.window_to, v.ml_conversion_probability, v.ml_expected_roas,
        v.ml_good_hour, v.ml_agrees, v.priority_score, v.target_hour_has_data,
        v.target_impressions, v.target_clicks, v.target_spend, v.target_orders, v.target_sales,
        v.computed_at, v.target_ml_click_probability, v.target_ml_conversion_probability,
        v.target_ml_expected_roas, v.target_ml_good_hour, v.target_ml_label_caveat, v.target_ml_computed_at,
        t.ml_multiplier AS raw_mult,
        COALESCE(t.cliques_observados, 0) AS hour_clicks,
        t.alvo_roas, t.roas_ancora, t.roas_observado, t.gasto_observado,
        COALESCE(eff.multiplier, 1.0) AS cur_mult,
        eff.scope AS cur_scope
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
                        WHEN 'ENTITY'::text THEN 4 WHEN 'AD_GROUP'::text THEN 3
                        WHEN 'CAMPAIGN'::text THEN 2 WHEN 'GLOBAL'::text THEN 1 ELSE 0
                    END) DESC
             LIMIT 1) eff ON true
      WHERE NOT EXISTS (
          SELECT 1 FROM marketcloud_control.holdout_cells hc
          WHERE hc.campaign_name = v.campaign_name AND hc.event_hour = v.event_hour AND hc.grupo = 'CONTROLE'
      )
), soft AS (
    SELECT raw.*,
        LEAST(1.0, GREATEST(0, raw.hour_clicks)::numeric / 10.0) AS evidence_weight,
        GREATEST(0.30, LEAST(1.00,
            round( (raw.cur_mult + (raw.raw_mult - raw.cur_mult) * LEAST(1.0, GREATEST(0, raw.hour_clicks)::numeric / 10.0)) / 0.05 ) * 0.05
        )) AS mult
    FROM raw
), b AS (
    SELECT s.*,
        CASE
            WHEN s.mult > s.cur_mult THEN 'BID_UP'::text
            WHEN s.mult <= 0.35 THEN 'CUT_HOUR'::text
            ELSE 'BID_DOWN'::text
        END AS campaign_action_type_raw,
        CASE
            WHEN s.mult > s.cur_mult THEN 'INCREASE_EFFECTIVE_BID'::text
            ELSE 'DECREASE_EFFECTIVE_BID'::text
        END AS advisor_action_raw,
        CASE
            WHEN s.source_grain = 'CAMPAIGN_HOUR_INHERITED'
             AND s.mult > s.cur_mult
             AND s.target_ml_click_probability IS NOT NULL
             AND COALESCE(s.target_hour_has_data, false) = true
            THEN
                CASE
                    WHEN COALESCE(s.target_clicks, 0) >= 3 THEN
                        CASE
                            WHEN COALESCE(s.target_ml_expected_roas, 0) <= 0.01 THEN 'VETO:TARGET_ROAS_ZERO'
                            WHEN COALESCE(s.target_ml_conversion_probability, 0) <= 0.01 THEN 'VETO:TARGET_CONV_ZERO'
                            WHEN s.alvo_roas IS NOT NULL AND s.target_ml_expected_roas IS NOT NULL
                                 AND s.target_ml_expected_roas < s.alvo_roas * 0.60 THEN 'VETO:TARGET_ROAS_BELOW_60PCT_ALVO'
                            ELSE NULL::text
                        END
                    ELSE
                        CASE
                            WHEN COALESCE(s.target_ml_expected_roas, 0) <= 0.01
                              OR COALESCE(s.target_ml_conversion_probability, 0) <= 0.01 THEN 'SEMDADO:TARGET_SEM_EVIDENCIA'
                            ELSE NULL::text
                        END
                END
            ELSE NULL::text
        END AS hold_tag
    FROM soft s
)
SELECT
    b.keyword_hour_recommendation_id, b.campaign_id, b.campaign_name,
    b.ad_group_id, b.ad_group_name, b.keyword_text, b.match_type, b.event_hour,
    CASE
        WHEN b.hold_tag LIKE 'VETO:%' THEN 'BID_UP_VETOED'::text
        WHEN b.hold_tag LIKE 'SEMDADO:%' THEN 'BID_UP_SEM_DADO'::text
        ELSE b.campaign_action_type_raw
    END AS campaign_action_type,
    CASE
        WHEN b.hold_tag LIKE 'VETO:%' THEN 'HOLD_VETOED'::text
        WHEN b.hold_tag LIKE 'SEMDADO:%' THEN 'HOLD_NO_DATA'::text
        ELSE b.advisor_action_raw
    END AS advisor_action,
    b.confidence, b.source_grain, b.sample_guard, b.execution_hint, b.base_bid,
    b.cur_mult AS current_hour_multiplier,
    b.mult AS suggested_hour_multiplier,
    b.base_bid * b.cur_mult AS current_effective_bid,
    b.base_bid * b.mult AS suggested_effective_bid,
    b.base_bid * (b.mult - b.cur_mult) AS effective_bid_delta,
    CASE WHEN b.cur_mult > 0::numeric THEN (b.mult - b.cur_mult) / b.cur_mult * 100::numeric ELSE NULL::numeric END AS effective_bid_delta_percent,
    b.spend, b.orders, b.sales, b.roas, b.clicks, b.impressions, b.days_observed,
    b.window_from, b.window_to, b.ml_conversion_probability, b.ml_expected_roas,
    b.ml_good_hour, b.ml_agrees, b.priority_score, b.target_hour_has_data,
    b.target_impressions, b.target_clicks, b.target_spend, b.target_orders, b.target_sales,
    b.computed_at, b.target_ml_click_probability, b.target_ml_conversion_probability,
    b.target_ml_expected_roas, b.target_ml_good_hour, b.target_ml_label_caveat, b.target_ml_computed_at,
    b.cur_scope AS current_multiplier_scope,
    b.alvo_roas AS ml_target_roas,
    b.roas_ancora AS ml_roas_ancora,
    b.roas_observado AS ml_roas_observado,
    b.gasto_observado AS ml_gasto_observado,
    (b.hold_tag IS NOT NULL) AS vetoed,
    split_part(b.hold_tag, ':', 2) AS veto_reason,
    round(b.evidence_weight, 3) AS evidence_weight,
    b.raw_mult AS raw_suggested_multiplier
FROM b
WHERE abs(b.mult - b.cur_mult) >= 0.05;

COMMENT ON VIEW marketcloud_gold.gold_keyword_hourly_recommendations_candidates_v1 IS
    'TODOS os candidatos keyword x hora (inclui BID_UP_VETOED/BID_UP_SEM_DADO). Multiplicador suavizado por evidencia (toward current). Base observavel do audit e da fila acionavel.';

-- ---------- 2) audit_v1: parecer + dedup ----------
CREATE VIEW marketcloud_gold.gold_keyword_hourly_recommendation_audit_v1 AS
WITH ranked AS (
    SELECT
        c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.campaign_id, COALESCE(c.ad_group_id,''),
                lower(trim(COALESCE(c.keyword_text,''))), lower(trim(COALESCE(c.match_type,''))),
                c.event_hour, c.campaign_action_type, c.current_hour_multiplier, c.suggested_hour_multiplier
            ORDER BY c.priority_score DESC, c.keyword_hour_recommendation_id
        ) AS duplicate_rank,
        COUNT(*) OVER (
            PARTITION BY c.campaign_id, COALESCE(c.ad_group_id,''),
                lower(trim(COALESCE(c.keyword_text,''))), lower(trim(COALESCE(c.match_type,''))),
                c.event_hour, c.campaign_action_type, c.current_hour_multiplier, c.suggested_hour_multiplier
        ) AS duplicate_count
    FROM marketcloud_gold.gold_keyword_hourly_recommendations_candidates_v1 c
)
SELECT
    r.*,
    CASE
        WHEN r.duplicate_rank > 1 THEN 'BLOCKED'
        WHEN r.campaign_action_type = 'BID_UP_VETOED' THEN 'BLOCKED'
        WHEN r.campaign_action_type = 'BID_UP_SEM_DADO' THEN 'BLOCKED'
        WHEN r.campaign_action_type = 'BID_UP' AND r.confidence = 'LOW' AND r.target_ml_click_probability IS NULL THEN 'REVIEW'
        WHEN r.campaign_action_type = 'BID_UP' AND r.target_ml_click_probability IS NOT NULL
             AND (COALESCE(r.target_ml_expected_roas,0) < COALESCE(r.ml_target_roas, r.ml_expected_roas, 0) * 0.75
                  OR COALESCE(r.target_ml_conversion_probability,0) < 0.05) THEN 'REVIEW'
        -- "target looks strong" so questiona o corte com EVIDENCIA real: >=3 cliques
        -- E >=1 pedido no target. Sem isso, ROAS previsto alto e miragem de dado ralo.
        WHEN r.campaign_action_type IN ('BID_DOWN','CUT_HOUR') AND r.target_ml_expected_roas IS NOT NULL AND r.ml_target_roas IS NOT NULL
             AND r.target_ml_expected_roas > r.ml_target_roas * 1.25 AND COALESCE(r.target_ml_click_probability,0) >= 0.50
             AND COALESCE(r.target_clicks,0) >= 3 AND COALESCE(r.target_orders,0) >= 1 THEN 'REVIEW'
        WHEN r.campaign_action_type IN ('BID_DOWN','CUT_HOUR') AND r.confidence = 'LOW' AND COALESCE(r.clicks,0) < 5 THEN 'REVIEW'
        ELSE 'APPROVED'
    END AS audit_decision,
    CASE
        WHEN r.duplicate_rank > 1 THEN 'DUPLICATE_RECOMMENDATION'
        WHEN r.campaign_action_type = 'BID_UP_VETOED' THEN COALESCE(NULLIF(r.veto_reason,''), 'TARGET_VETO')
        WHEN r.campaign_action_type = 'BID_UP_SEM_DADO' THEN COALESCE(NULLIF(r.veto_reason,''), 'TARGET_SEM_EVIDENCIA')
        WHEN r.campaign_action_type = 'BID_UP' AND r.confidence = 'LOW' AND r.target_ml_click_probability IS NULL THEN 'BID_UP_LOW_CONFIDENCE_WITHOUT_TARGET_ML'
        WHEN r.campaign_action_type = 'BID_UP' AND r.target_ml_click_probability IS NOT NULL
             AND (COALESCE(r.target_ml_expected_roas,0) < COALESCE(r.ml_target_roas, r.ml_expected_roas, 0) * 0.75
                  OR COALESCE(r.target_ml_conversion_probability,0) < 0.05) THEN 'BID_UP_TARGET_WEAK_RELATIVE_TO_CAMPAIGN'
        WHEN r.campaign_action_type IN ('BID_DOWN','CUT_HOUR') AND r.target_ml_expected_roas IS NOT NULL AND r.ml_target_roas IS NOT NULL
             AND r.target_ml_expected_roas > r.ml_target_roas * 1.25 AND COALESCE(r.target_ml_click_probability,0) >= 0.50
             AND COALESCE(r.target_clicks,0) >= 3 AND COALESCE(r.target_orders,0) >= 1 THEN 'REDUCE_BUT_TARGET_LOOKS_STRONG'
        WHEN r.campaign_action_type IN ('BID_DOWN','CUT_HOUR') AND r.confidence = 'LOW' AND COALESCE(r.clicks,0) < 5 THEN 'REDUCE_LOW_CONFIDENCE_LOW_VOLUME'
        WHEN r.campaign_action_type = 'BID_UP' THEN 'BID_UP_COHERENT'
        WHEN r.campaign_action_type = 'BID_DOWN' THEN 'BID_DOWN_COHERENT'
        WHEN r.campaign_action_type = 'CUT_HOUR' THEN 'CUT_HOUR_COHERENT'
        ELSE 'UNCLASSIFIED'
    END AS audit_reason
FROM ranked r;

COMMENT ON VIEW marketcloud_gold.gold_keyword_hourly_recommendation_audit_v1 IS
    'Parecer programatico de todos os candidatos: APPROVED/REVIEW/BLOCKED + duplicate_rank. Nao muda a fila acionavel; da motivo auditavel.';

-- ---------- 3) v3: fila acionavel (so APPROVED) ----------
CREATE VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v3 AS
SELECT *
FROM marketcloud_gold.gold_keyword_hourly_recommendation_audit_v1
WHERE audit_decision = 'APPROVED'
  AND campaign_action_type IN ('BID_UP', 'BID_DOWN', 'CUT_HOUR')
  AND duplicate_rank = 1;

COMMENT ON VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v3 IS
    'Fila ACIONAVEL keyword x hora: apenas APPROVED, acao real, sem duplicata. VETO/SEM_DADO/REVIEW ficam em audit_v1/candidates_v1.';
