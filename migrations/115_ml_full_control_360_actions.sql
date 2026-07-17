-- =====================================================================
-- ML Full Control 360 actions
--
-- Saida operacional do ML para Full Control alem do BID horario:
-- budget, stop-loss e placement. Esta tabela e advisor/auditavel; aplicacao
-- real desses tipos depende de endpoints especificos do Robo/Ads.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_gold.ml_full_control_action_recommendations_v1 (
    recommendation_id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL DEFAULT 'zanom',
    campaign_id TEXT,
    campaign_name TEXT NOT NULL,
    event_hour INTEGER NOT NULL,
    action_type TEXT NOT NULL,
    action_scope TEXT NOT NULL DEFAULT 'FULL_CONTROL_360',
    current_value NUMERIC(18,4),
    recommended_value NUMERIC(18,4),
    expected_roas NUMERIC(10,4),
    conversion_probability NUMERIC(6,4),
    confidence TEXT NOT NULL DEFAULT 'MEDIUM',
    priority_score NUMERIC(18,4) NOT NULL DEFAULT 0,
    guardrail_status TEXT NOT NULL DEFAULT 'ADVISORY',
    reason TEXT,
    evidence_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    model_version TEXT NOT NULL DEFAULT 'v2',
    computed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ml_fc360_campaign
    ON marketcloud_gold.ml_full_control_action_recommendations_v1 (campaign_id, event_hour, action_type);

CREATE INDEX IF NOT EXISTS idx_ml_fc360_action
    ON marketcloud_gold.ml_full_control_action_recommendations_v1 (action_type, confidence, computed_at DESC);

COMMENT ON TABLE marketcloud_gold.ml_full_control_action_recommendations_v1 IS
    'Recomendacoes ML Full Control 360: budget, stop-loss e placement, geradas junto do hourly_real_v2. Advisor/auditavel ate existir executor especifico.';
