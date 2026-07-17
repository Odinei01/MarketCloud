-- =====================================================================
-- 108: Veto de target ruim — agora HONESTO (gate por evidencia) e OBSERVAVEL.
--
-- Correcao de 2 defeitos da 107:
--
-- (1) A 107 vetava BID_UP herdado com base no ML de target mesmo quando o
--     target NAO tinha evidencia (modelo raso sobre 0-poucos cliques prev v
--     ROAS/conv ~0 pra quase tudo). "AMS_TARGET_HOURLY_ADVISOR_ONLY" e selo
--     GLOBAL do modelo (147/147 linhas), nao serve de gate por-linha. Aqui o
--     gate de confianca passa a ser VOLUME REAL do target na hora:
--     target_hour_has_data AND target_clicks >= 5. Sem esse minimo, o veredito
--     pessimista do target nao e evidencia — a linha NAO e vetada (segue como
--     advisor, visivel pro humano decidir).
--
-- (2) A 107 DROPAVA a linha vetada da view — veto invisivel, o loop nao media
--     se acertou. Aqui a linha PERMANECE, marcada com vetoed=true + veto_reason.
--     Pra nao acionar sozinha, o action vira 'BID_UP_VETOED'/'HOLD_VETOED'
--     (sai do filtro BID_UP), mas o suggested_* fica pra auditoria.
--
-- Cortes de exposicao (BID_DOWN/CUT_HOUR) nunca sao vetados — so aumento.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v3 AS
WITH b AS (
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
            END AS campaign_action_type_raw,
            CASE
                WHEN t.ml_multiplier > eff.multiplier THEN 'INCREASE_EFFECTIVE_BID'::text
                ELSE 'DECREASE_EFFECTIVE_BID'::text
            END AS advisor_action_raw,
        -- Tri-estado do BID_UP herdado quando HA modelo de target:
        --   VETO    = evidencia real (>=3 cliques) de que o target e ruim.
        --   SEMDADO = sem evidencia (<3 cliques) e leitura degenerada (roas/conv 0):
        --             nao e "ruim", e "sem dado pra confirmar o aumento".
        --   (null)  = sem modelo de target OU target confirma -> BID_UP confiante.
        CASE
            WHEN v.source_grain = 'CAMPAIGN_HOUR_INHERITED'
             AND t.ml_multiplier > eff.multiplier
             AND v.target_ml_click_probability IS NOT NULL
             AND COALESCE(v.target_hour_has_data, false) = true
            THEN
                CASE
                    WHEN COALESCE(v.target_clicks, 0) >= 3 THEN
                        CASE
                            WHEN COALESCE(v.target_ml_expected_roas, 0) <= 0.01 THEN 'VETO:TARGET_ROAS_ZERO'
                            WHEN COALESCE(v.target_ml_conversion_probability, 0) <= 0.01 THEN 'VETO:TARGET_CONV_ZERO'
                            WHEN t.alvo_roas IS NOT NULL
                                 AND v.target_ml_expected_roas IS NOT NULL
                                 AND v.target_ml_expected_roas < t.alvo_roas * 0.60 THEN 'VETO:TARGET_ROAS_BELOW_60PCT_ALVO'
                            ELSE NULL::text
                        END
                    ELSE  -- < 3 cliques: sem evidencia pra vetar; se o target le degenerado, e SEM_DADO
                        CASE
                            WHEN COALESCE(v.target_ml_expected_roas, 0) <= 0.01
                              OR COALESCE(v.target_ml_conversion_probability, 0) <= 0.01 THEN 'SEMDADO:TARGET_SEM_EVIDENCIA'
                            ELSE NULL::text
                        END
                END
            ELSE NULL::text
        END AS hold_tag,
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
)
SELECT
    b.keyword_hour_recommendation_id,
    b.campaign_id,
    b.campaign_name,
    b.ad_group_id,
    b.ad_group_name,
    b.keyword_text,
    b.match_type,
    b.event_hour,
    -- Held (veto ou sem_dado): sai do filtro BID_UP (nao aciona), mas fica visivel.
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
    b.confidence,
    b.source_grain,
    b.sample_guard,
    b.execution_hint,
    b.base_bid,
    b.current_hour_multiplier,
    b.suggested_hour_multiplier,
    b.current_effective_bid,
    b.suggested_effective_bid,
    b.effective_bid_delta,
    b.effective_bid_delta_percent,
    b.spend,
    b.orders,
    b.sales,
    b.roas,
    b.clicks,
    b.impressions,
    b.days_observed,
    b.window_from,
    b.window_to,
    b.ml_conversion_probability,
    b.ml_expected_roas,
    b.ml_good_hour,
    b.ml_agrees,
    b.priority_score,
    b.target_hour_has_data,
    b.target_impressions,
    b.target_clicks,
    b.target_spend,
    b.target_orders,
    b.target_sales,
    b.computed_at,
    b.target_ml_click_probability,
    b.target_ml_conversion_probability,
    b.target_ml_expected_roas,
    b.target_ml_good_hour,
    b.target_ml_label_caveat,
    b.target_ml_computed_at,
    b.current_multiplier_scope,
    b.ml_target_roas,
    b.ml_roas_ancora,
    b.ml_roas_observado,
    b.ml_gasto_observado,
    -- Colunas novas no FIM (CREATE OR REPLACE so permite append).
    -- vetoed = "held" (veto OU sem_dado); o motivo distingue qual.
    (b.hold_tag IS NOT NULL) AS vetoed,
    split_part(b.hold_tag, ':', 2) AS veto_reason
FROM b;

COMMENT ON VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v3 IS
    'Keywords x hora. Veto de BID_UP herdado agora exige EVIDENCIA real do target (has_data + >=5 cliques) e e OBSERVAVEL: vetoed/veto_reason ficam na linha, action vira BID_UP_VETOED (sai do acionamento, entra na auditoria).';
