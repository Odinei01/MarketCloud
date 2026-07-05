-- Migration 006: query_templates, query_runs

CREATE TYPE query_family AS ENUM (
    'PATH_TO_PURCHASE', 'ASSISTED_CONVERSIONS', 'FREQUENCY_ANALYSIS',
    'AUDIENCE_DISCOVERY', 'REMARKETING_POOL', 'NEW_TO_BRAND',
    'CAMPAIGN_OVERLAP', 'ASIN_CROSS_SELL', 'KEYWORD_ROLE',
    'PLACEMENT_IMPACT', 'BUDGET_WASTE', 'DSP_TO_SPONSORED_ADS', 'STORE_JOURNEY'
);

CREATE TYPE query_run_status AS ENUM (
    'CREATED', 'QUEUED', 'SUBMITTED', 'RUNNING', 'SUCCEEDED',
    'FAILED', 'CANCELLED', 'TIMEOUT', 'RESULT_DOWNLOADED',
    'MODELING_STARTED', 'MODELING_COMPLETED', 'INSIGHTS_GENERATED'
);

CREATE TYPE query_run_type AS ENUM (
    'MANUAL', 'SCHEDULED', 'API', 'BACKFILL', 'SYSTEM_REPROCESS'
);

CREATE TABLE query_templates (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   UUID REFERENCES tenants(id),   -- NULL = global template
    name                        TEXT NOT NULL,
    code                        TEXT NOT NULL,
    description                 TEXT,
    query_family                query_family NOT NULL,
    query_goal                  TEXT NOT NULL,
    sql_template                TEXT NOT NULL,
    parameters_schema           JSONB NOT NULL DEFAULT '{}',
    min_lookback_days           INTEGER NOT NULL DEFAULT 7,
    max_lookback_days           INTEGER NOT NULL DEFAULT 90,
    supported_campaign_types    TEXT[] NOT NULL DEFAULT '{}',
    supported_marketplaces      TEXT[] NOT NULL DEFAULT '{"AMAZON_BR"}',
    version                     INTEGER NOT NULL DEFAULT 1,
    status                      TEXT NOT NULL DEFAULT 'ACTIVE',
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(code, version)
);

CREATE INDEX idx_query_templates_family ON query_templates(query_family);
CREATE INDEX idx_query_templates_code ON query_templates(code);

CREATE TABLE query_runs (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id                    UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    amazon_profile_id           UUID REFERENCES amazon_ads_profiles(id),
    amc_instance_id             UUID REFERENCES amc_instances(id),
    query_template_id           UUID NOT NULL REFERENCES query_templates(id),
    run_type                    query_run_type NOT NULL DEFAULT 'MANUAL',
    parameters_json             JSONB NOT NULL DEFAULT '{}',
    idempotency_key             TEXT NOT NULL,
    status                      query_run_status NOT NULL DEFAULT 'CREATED',
    submitted_at                TIMESTAMPTZ,
    started_at                  TIMESTAMPTZ,
    finished_at                 TIMESTAMPTZ,
    external_query_execution_id TEXT,
    result_object_path          TEXT,
    error_code                  TEXT,
    error_message               TEXT,
    created_by                  UUID REFERENCES users(id),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(idempotency_key)
);

CREATE INDEX idx_query_runs_tenant ON query_runs(tenant_id);
CREATE INDEX idx_query_runs_store ON query_runs(store_id);
CREATE INDEX idx_query_runs_status ON query_runs(status);
CREATE INDEX idx_query_runs_amc ON query_runs(amc_instance_id);
CREATE INDEX idx_query_runs_created ON query_runs(created_at DESC);

-- Status history
CREATE TABLE query_run_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    query_run_id    UUID NOT NULL REFERENCES query_runs(id) ON DELETE CASCADE,
    status          query_run_status NOT NULL,
    message         TEXT,
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_query_run_events_run ON query_run_events(query_run_id);
