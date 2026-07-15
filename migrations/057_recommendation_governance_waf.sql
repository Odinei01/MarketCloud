-- =====================================================================
-- Recommendation Governance V1 — aplica o Amazon Ads Well-Architected
-- Framework de Insights/Recomendacoes ao Marketcloud.
--
-- Objetivo: separar ingestao/descoberta da implementacao, explicitar freshness,
-- lifecycle e guardrails de automacao. Nao executa nenhuma acao na Amazon.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS marketcloud_recommendations;

CREATE TABLE IF NOT EXISTS marketcloud_recommendations.recommendation_source_policies (
    source_type             TEXT PRIMARY KEY,
    source_description      TEXT NOT NULL,
    expected_refresh_sla    INTERVAL NOT NULL,
    time_sensitivity        TEXT NOT NULL,
    default_lifecycle_stage TEXT NOT NULL DEFAULT 'DISCOVERED',
    requires_human_approval BOOLEAN NOT NULL DEFAULT TRUE,
    automation_allowed      BOOLEAN NOT NULL DEFAULT FALSE,
    notes                   TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_rec_source_time_sensitivity CHECK (time_sensitivity IN ('NEAR_REAL_TIME','DAILY','FLEXIBLE')),
    CONSTRAINT chk_rec_source_lifecycle CHECK (default_lifecycle_stage IN ('DISCOVERED','VALIDATED','APPROVED','IMPLEMENTED','MEASURED'))
);

INSERT INTO marketcloud_recommendations.recommendation_source_policies (
    source_type, source_description, expected_refresh_sla, time_sensitivity,
    default_lifecycle_stage, requires_human_approval, automation_allowed, notes
) VALUES
    (
      'ADS_HOURLY_REAL',
      'Recomendacoes campanha x hora baseadas no relatorio horario real e, quando disponivel, AMS reconciliado.',
      INTERVAL '36 hours',
      'NEAR_REAL_TIME',
      'DISCOVERED',
      TRUE,
      FALSE,
      'Well-Architected: recomendacao sensivel ao tempo; validar contra Robo/ML antes de implementar.'
    ),
    (
      'ADS_KEYWORD_HOURLY_REAL',
      'Recomendacoes keyword/target x hora derivadas do sinal horario campanha x agenda/base bid.',
      INTERVAL '36 hours',
      'NEAR_REAL_TIME',
      'DISCOVERED',
      TRUE,
      FALSE,
      'Fase 6: usar AMS target quando disponivel; enquanto herdado de campanha, manter revisao humana.'
    ),
    (
      'SWARM_ROBOT_DECISION',
      'Historico de decisoes do Robo ZANOM usado como sinal observacional e label de outcome.',
      INTERVAL '24 hours',
      'DAILY',
      'MEASURED',
      TRUE,
      FALSE,
      'Dataset majoritariamente dry-run/observacional; nao usar como prova causal isolada.'
    ),
    (
      'PARTNER_OPPORTUNITIES',
      'Amazon Ads Partner Opportunities API para oportunidades/recomendacoes consolidadas.',
      INTERVAL '24 hours',
      'DAILY',
      'DISCOVERED',
      TRUE,
      FALSE,
      'Ainda nao implementado; candidato futuro para centralizar recomendacoes oficiais da Amazon.'
    )
ON CONFLICT (source_type) DO UPDATE SET
    source_description      = EXCLUDED.source_description,
    expected_refresh_sla    = EXCLUDED.expected_refresh_sla,
    time_sensitivity        = EXCLUDED.time_sensitivity,
    default_lifecycle_stage = EXCLUDED.default_lifecycle_stage,
    requires_human_approval = EXCLUDED.requires_human_approval,
    automation_allowed      = EXCLUDED.automation_allowed,
    notes                   = EXCLUDED.notes,
    updated_at              = NOW();

CREATE OR REPLACE VIEW marketcloud_recommendations.v_hourly_recommendation_governance_v1 AS
SELECT
    'ADS_HOURLY_REAL'::text AS source_type,
    p.time_sensitivity,
    r.recommendation_id,
    'CAMPAIGN_HOUR'::text AS recommendation_grain,
    r.campaign_name,
    NULL::text AS ad_group_name,
    NULL::text AS keyword_text,
    NULL::text AS match_type,
    r.event_hour,
    r.action_type AS recommended_action,
    r.confidence,
    r.priority_score,
    r.window_from,
    r.window_to,
    (r.window_to::timestamp + p.expected_refresh_sla) AS freshness_expires_at,
    CASE
        WHEN r.window_to::timestamp + p.expected_refresh_sla < NOW() THEN 'STALE'
        ELSE 'FRESH'
    END AS freshness_status,
    r.ml_agrees,
    r.schedule_overlap_status,
    r.rules_still_need_change,
    r.rules_already_aligned,
    p.default_lifecycle_stage AS lifecycle_stage,
    CASE
        WHEN r.window_to::timestamp + p.expected_refresh_sla < NOW() THEN 'DO_NOT_ACT_STALE'
        WHEN r.confidence = 'LOW' THEN 'VALIDATE_LOW_CONFIDENCE'
        WHEN r.ml_agrees IS FALSE THEN 'VALIDATE_ML_DISAGREES'
        WHEN r.schedule_overlap_status = 'PARTIALLY_CORRECTED' THEN 'VALIDATE_PARTIALLY_CORRECTED'
        WHEN r.rules_still_need_change = 0 AND r.rules_already_aligned > 0 THEN 'ALREADY_IMPLEMENTED_OR_ALIGNED'
        ELSE 'READY_FOR_HUMAN_REVIEW'
    END AS governance_status,
    FALSE AS automation_allowed_now,
    p.requires_human_approval,
    p.notes
FROM marketcloud_gold.gold_hourly_recommendations_v1 r
JOIN marketcloud_recommendations.recommendation_source_policies p
  ON p.source_type = 'ADS_HOURLY_REAL';

CREATE OR REPLACE VIEW marketcloud_recommendations.v_keyword_hourly_recommendation_governance_v1 AS
SELECT
    'ADS_KEYWORD_HOURLY_REAL'::text AS source_type,
    p.time_sensitivity,
    r.keyword_hour_recommendation_id AS recommendation_id,
    'KEYWORD_HOUR'::text AS recommendation_grain,
    r.campaign_name,
    r.ad_group_name,
    r.keyword_text,
    r.match_type,
    r.event_hour,
    r.advisor_action AS recommended_action,
    r.confidence,
    r.priority_score,
    r.window_from,
    r.window_to,
    (r.window_to::timestamp + p.expected_refresh_sla) AS freshness_expires_at,
    CASE
        WHEN r.window_to::timestamp + p.expected_refresh_sla < NOW() THEN 'STALE'
        ELSE 'FRESH'
    END AS freshness_status,
    r.ml_agrees,
    r.source_grain,
    r.sample_guard,
    p.default_lifecycle_stage AS lifecycle_stage,
    CASE
        WHEN r.window_to::timestamp + p.expected_refresh_sla < NOW() THEN 'DO_NOT_ACT_STALE'
        WHEN r.confidence = 'LOW' THEN 'VALIDATE_LOW_CONFIDENCE'
        WHEN r.ml_agrees IS FALSE THEN 'VALIDATE_ML_DISAGREES'
        WHEN r.source_grain <> 'TARGET_HOUR_OBSERVED' THEN 'VALIDATE_INHERITED_SIGNAL'
        ELSE 'READY_FOR_HUMAN_REVIEW'
    END AS governance_status,
    FALSE AS automation_allowed_now,
    p.requires_human_approval,
    p.notes
FROM marketcloud_gold.gold_keyword_hourly_recommendations_v1 r
JOIN marketcloud_recommendations.recommendation_source_policies p
  ON p.source_type = 'ADS_KEYWORD_HOURLY_REAL';

CREATE OR REPLACE VIEW marketcloud_recommendations.v_recommendation_governance_summary_v1 AS
SELECT source_type, recommendation_grain, freshness_status, governance_status,
       COUNT(*)::int AS recommendations_count,
       ROUND(SUM(COALESCE(priority_score, 0))::numeric, 2) AS priority_score_sum
FROM (
    SELECT source_type, recommendation_grain, freshness_status, governance_status, priority_score
    FROM marketcloud_recommendations.v_hourly_recommendation_governance_v1
    UNION ALL
    SELECT source_type, recommendation_grain, freshness_status, governance_status, priority_score
    FROM marketcloud_recommendations.v_keyword_hourly_recommendation_governance_v1
) g
GROUP BY source_type, recommendation_grain, freshness_status, governance_status;

COMMENT ON TABLE marketcloud_recommendations.recommendation_source_policies IS
'Politicas por fonte de recomendacao alinhadas ao Amazon Ads Well-Architected: freshness, lifecycle, aprovacao humana e automacao.';
COMMENT ON VIEW marketcloud_recommendations.v_hourly_recommendation_governance_v1 IS
'Governanca das recomendacoes campanha x hora: freshness, lifecycle e guardrails antes de qualquer acao.';
COMMENT ON VIEW marketcloud_recommendations.v_keyword_hourly_recommendation_governance_v1 IS
'Governanca das recomendacoes keyword/target x hora: evita agir em sinal herdado, stale ou discordante do ML sem revisao.';
COMMENT ON VIEW marketcloud_recommendations.v_recommendation_governance_summary_v1 IS
'Resumo operacional para cards/observabilidade de recomendacoes por freshness e status de governanca.';
