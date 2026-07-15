CREATE SCHEMA IF NOT EXISTS marketcloud_control;

CREATE TABLE IF NOT EXISTS marketcloud_control.ml_full_auto_campaign_flags (
    tenant_id UUID NOT NULL,
    campaign_id TEXT,
    campaign_name TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, campaign_name)
);

CREATE INDEX IF NOT EXISTS idx_ml_full_auto_campaign_flags_enabled
    ON marketcloud_control.ml_full_auto_campaign_flags (tenant_id, enabled);

CREATE INDEX IF NOT EXISTS idx_ml_full_auto_campaign_flags_campaign_id
    ON marketcloud_control.ml_full_auto_campaign_flags (tenant_id, campaign_id);
