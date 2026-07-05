-- Migration 007: insights, recommendations, audiences, webhooks, usage

CREATE TYPE insight_type AS ENUM (
    'CAMPAIGN_ASSISTS_CONVERSIONS', 'CAMPAIGN_DIRECT_CONVERTER', 'CAMPAIGN_WASTES_BUDGET',
    'KEYWORD_DISCOVERY_ROLE', 'KEYWORD_CONVERSION_ROLE',
    'AUDIENCE_HIGH_INTENT', 'AUDIENCE_REMARKETING_OPPORTUNITY',
    'FREQUENCY_SATURATION', 'FREQUENCY_UNDEREXPOSED',
    'ASIN_CROSS_SELL_OPPORTUNITY', 'PRODUCT_DETAIL_PAGE_INTEREST',
    'NEW_TO_BRAND_OPPORTUNITY', 'BID_BOOST_OPPORTUNITY', 'DO_NOT_PAUSE_WARNING'
);

CREATE TYPE insight_severity AS ENUM ('INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL');

CREATE TABLE insights (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id            UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    profile_id          UUID REFERENCES amazon_ads_profiles(id),
    amc_instance_id     UUID REFERENCES amc_instances(id),
    query_run_id        UUID REFERENCES query_runs(id),
    insight_type        insight_type NOT NULL,
    entity_type         TEXT NOT NULL,
    entity_id           TEXT NOT NULL,
    entity_name         TEXT,
    severity            insight_severity NOT NULL DEFAULT 'MEDIUM',
    confidence          NUMERIC(4,3) NOT NULL DEFAULT 0,
    score               NUMERIC(4,3),
    title               TEXT NOT NULL,
    summary             TEXT NOT NULL,
    evidence_json       JSONB NOT NULL DEFAULT '{}',
    recommended_action  TEXT,
    period_start        DATE,
    period_end          DATE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_insights_tenant ON insights(tenant_id);
CREATE INDEX idx_insights_store ON insights(store_id);
CREATE INDEX idx_insights_entity ON insights(entity_type, entity_id);
CREATE INDEX idx_insights_type ON insights(insight_type);
CREATE INDEX idx_insights_severity ON insights(severity);
CREATE INDEX idx_insights_created ON insights(created_at DESC);

CREATE TYPE recommendation_action AS ENUM (
    'DO_NOT_PAUSE', 'INCREASE_BID', 'DECREASE_BID', 'INCREASE_BUDGET', 'DECREASE_BUDGET',
    'CREATE_AUDIENCE', 'APPLY_AUDIENCE_BID_BOOST', 'CREATE_REMARKETING_CAMPAIGN',
    'MOVE_TO_DISCOVERY_BUCKET', 'MOVE_TO_CONVERSION_BUCKET',
    'REVIEW_NEGATIVE_KEYWORD', 'REVIEW_TARGET_EXCLUSION',
    'PROTECT_CAMPAIGN', 'EXPORT_TO_SWARM'
);

CREATE TYPE recommendation_status AS ENUM (
    'PENDING', 'APPROVED', 'REJECTED', 'EXPORTED', 'APPLIED_EXTERNALLY', 'EXPIRED', 'SUPERSEDED'
);

CREATE TABLE recommendations (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id            UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    source_insight_id   UUID REFERENCES insights(id),
    target_type         TEXT NOT NULL,
    target_id           TEXT NOT NULL,
    target_name         TEXT,
    action_type         recommendation_action NOT NULL,
    current_value       JSONB,
    recommended_value   JSONB,
    impact_estimate     JSONB,
    reason              TEXT NOT NULL,
    confidence          NUMERIC(4,3) NOT NULL DEFAULT 0,
    status              recommendation_status NOT NULL DEFAULT 'PENDING',
    reviewed_by         UUID REFERENCES users(id),
    reviewed_at         TIMESTAMPTZ,
    expires_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_recommendations_tenant ON recommendations(tenant_id);
CREATE INDEX idx_recommendations_store ON recommendations(store_id);
CREATE INDEX idx_recommendations_status ON recommendations(status);
CREATE INDEX idx_recommendations_target ON recommendations(target_type, target_id);
CREATE INDEX idx_recommendations_created ON recommendations(created_at DESC);

-- Audiences
CREATE TYPE audience_type AS ENUM (
    'RULE_BASED', 'LOOKALIKE', 'REMARKETING', 'HIGH_INTENT', 'CROSS_SELL',
    'NEW_TO_BRAND', 'LAPSED_BUYERS', 'VIEWED_NOT_PURCHASED', 'CLICKED_NOT_PURCHASED'
);

CREATE TABLE audiences (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id                UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    profile_id              UUID REFERENCES amazon_ads_profiles(id),
    amc_instance_id         UUID REFERENCES amc_instances(id),
    source_query_run_id     UUID REFERENCES query_runs(id),
    name                    TEXT NOT NULL,
    description             TEXT,
    audience_type           audience_type NOT NULL,
    rule_json               JSONB NOT NULL DEFAULT '{}',
    external_audience_id    TEXT,
    estimated_size          INTEGER,
    status                  TEXT NOT NULL DEFAULT 'DRAFT',
    activation_targets      TEXT[] NOT NULL DEFAULT '{}',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audiences_tenant ON audiences(tenant_id);
CREATE INDEX idx_audiences_store ON audiences(store_id);
CREATE INDEX idx_audiences_status ON audiences(status);

-- Webhooks
CREATE TABLE webhook_subscriptions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    url         TEXT NOT NULL,
    events      TEXT[] NOT NULL,
    secret      TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'ACTIVE',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_webhook_subs_tenant ON webhook_subscriptions(tenant_id);

CREATE TABLE webhook_deliveries (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subscription_id     UUID NOT NULL REFERENCES webhook_subscriptions(id),
    tenant_id           UUID NOT NULL,
    event               TEXT NOT NULL,
    payload             JSONB NOT NULL,
    status              TEXT NOT NULL DEFAULT 'PENDING',
    attempt_count       INTEGER NOT NULL DEFAULT 0,
    last_attempt_at     TIMESTAMPTZ,
    next_attempt_at     TIMESTAMPTZ,
    response_code       INTEGER,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_webhook_deliveries_sub ON webhook_deliveries(subscription_id);
CREATE INDEX idx_webhook_deliveries_status ON webhook_deliveries(status, next_attempt_at);

-- Usage tracking
CREATE TABLE usage_records (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    store_id        UUID REFERENCES stores(id),
    metric          TEXT NOT NULL,
    value           NUMERIC NOT NULL DEFAULT 1,
    period_month    CHAR(7) NOT NULL,  -- 'YYYY-MM'
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_usage_tenant_month ON usage_records(tenant_id, period_month);
