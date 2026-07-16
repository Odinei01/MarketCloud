-- Fase 1 SaaS repetivel (16/07): Config Center por seller + modo por campanha.
-- A tabela centraliza as travas que antes ficavam espalhadas/env-hardcoded.

CREATE TABLE IF NOT EXISTS marketcloud_control.tenant_settings (
    tenant_id TEXT PRIMARY KEY,
    operational_mode TEXT NOT NULL DEFAULT 'advisor'
        CHECK (operational_mode IN ('advisor','semi_auto','full_auto')),
    min_roas NUMERIC(10,4) NOT NULL DEFAULT 4.0000
        CHECK (min_roas >= 0),
    ml_aggressiveness NUMERIC(5,4) NOT NULL DEFAULT 1.0000
        CHECK (ml_aggressiveness >= 0 AND ml_aggressiveness <= 1),
    risk_budget_brl NUMERIC(18,4) NOT NULL DEFAULT 0
        CHECK (risk_budget_brl >= 0),
    protected_hours INT[] NOT NULL DEFAULT '{}'::INT[],
    telegram_chat_id TEXT,
    notes TEXT,
    updated_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_tenant_settings_hours CHECK (
        protected_hours <@ ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23]::INT[]
    )
);

INSERT INTO marketcloud_control.tenant_settings (
    tenant_id, operational_mode, min_roas, ml_aggressiveness, risk_budget_brl,
    protected_hours, notes
)
SELECT DISTINCT
    tenant_id,
    CASE WHEN EXISTS (
        SELECT 1 FROM marketcloud_control.ml_full_auto_campaign_flags f
        WHERE f.tenant_id::text = src.tenant_id AND f.enabled IS TRUE
    ) THEN 'full_auto' ELSE 'advisor' END,
    4.0000,
    1.0000,
    0,
    '{}'::INT[],
    'Criado pela migration 096 Config Center.'
FROM (
    SELECT tenant_id::text AS tenant_id FROM marketcloud_control.ml_full_auto_campaign_flags
    UNION
    SELECT tenant_id::text AS tenant_id FROM marketcloud_control.amc_instances
) src
ON CONFLICT (tenant_id) DO NOTHING;

ALTER TABLE marketcloud_control.ml_full_auto_campaign_flags
    ADD COLUMN IF NOT EXISTS automation_mode TEXT;

UPDATE marketcloud_control.ml_full_auto_campaign_flags
SET automation_mode = CASE WHEN enabled THEN 'full_auto' ELSE 'advisor' END
WHERE automation_mode IS NULL OR automation_mode = '';

-- Dados legados: algumas flags foram criadas no tenant system. Para a operacao
-- ZANOM, flags de campanha devem pertencer ao tenant zanom; caso contrario a
-- UI do admin ZANOM nao enxerga a liberacao que o worker ainda usaria.
UPDATE marketcloud_control.ml_full_auto_campaign_flags f
SET tenant_id = z.id,
    updated_at = NOW(),
    notes = COALESCE(f.notes,'') || ' [migration 096: movida do tenant system para zanom]'
FROM tenants z
WHERE z.slug = 'zanom'
  AND f.tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND NOT EXISTS (
      SELECT 1
      FROM marketcloud_control.ml_full_auto_campaign_flags existing
      WHERE existing.tenant_id = z.id
        AND lower(trim(existing.campaign_name)) = lower(trim(f.campaign_name))
  );

ALTER TABLE marketcloud_control.ml_full_auto_campaign_flags
    ALTER COLUMN automation_mode SET DEFAULT 'advisor';

ALTER TABLE marketcloud_control.ml_full_auto_campaign_flags
    DROP CONSTRAINT IF EXISTS chk_campaign_automation_mode;
ALTER TABLE marketcloud_control.ml_full_auto_campaign_flags
    ADD CONSTRAINT chk_campaign_automation_mode
    CHECK (automation_mode IN ('advisor','semi_auto','full_auto'));

-- Mantem compatibilidade com consumidores antigos: enabled=true significa full_auto.
UPDATE marketcloud_control.ml_full_auto_campaign_flags
SET enabled = (automation_mode = 'full_auto');

CREATE OR REPLACE VIEW marketcloud_gold.gold_campaign_automation_governance AS
SELECT
    f.tenant_id,
    f.campaign_id,
    f.campaign_name,
    COALESCE(f.automation_mode, CASE WHEN f.enabled THEN 'full_auto' ELSE 'advisor' END) AS campaign_mode,
    f.enabled AS full_auto_enabled,
    s.operational_mode AS tenant_mode,
    s.min_roas,
    s.ml_aggressiveness,
    s.risk_budget_brl,
    s.protected_hours,
    CASE
        WHEN s.operational_mode = 'advisor' THEN FALSE
        WHEN COALESCE(f.automation_mode,'advisor') <> 'full_auto' THEN FALSE
        WHEN s.operational_mode <> 'full_auto' THEN FALSE
        WHEN COALESCE(f.campaign_id,'') = '' THEN FALSE
        ELSE TRUE
    END AS can_auto_apply,
    f.notes,
    f.updated_at
FROM marketcloud_control.ml_full_auto_campaign_flags f
LEFT JOIN marketcloud_control.tenant_settings s ON s.tenant_id = f.tenant_id::text;

COMMENT ON TABLE marketcloud_control.tenant_settings IS
    'Config Center por seller: teto operacional, ROAS minimo, agressividade ML, orcamento de risco, horarios protegidos e Telegram.';

COMMENT ON VIEW marketcloud_gold.gold_campaign_automation_governance IS
    'Governanca efetiva por campanha: seller define o teto e campanha opta dentro dele. can_auto_apply=true e a liberacao final para o worker.';
