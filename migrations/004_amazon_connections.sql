-- Migration 004: amazon_oauth_connections, amazon_ads_profiles, amc_instances

CREATE TABLE amazon_oauth_connections (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id            UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    amazon_user_id      TEXT,
    access_token        TEXT NOT NULL,
    refresh_token       TEXT NOT NULL,
    token_expires_at    TIMESTAMPTZ NOT NULL,
    scopes              TEXT[] NOT NULL DEFAULT '{}',
    status              TEXT NOT NULL DEFAULT 'ACTIVE',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, store_id)
);

CREATE INDEX idx_oauth_connections_tenant ON amazon_oauth_connections(tenant_id);
CREATE INDEX idx_oauth_connections_store ON amazon_oauth_connections(store_id);
CREATE INDEX idx_oauth_connections_expires ON amazon_oauth_connections(token_expires_at);

CREATE TYPE ads_account_type AS ENUM ('SELLER', 'VENDOR', 'AGENCY');

CREATE TABLE amazon_ads_profiles (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id                UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    marketplace_account_id  UUID REFERENCES marketplace_accounts(id),
    amazon_profile_id       TEXT NOT NULL,
    account_type            ads_account_type NOT NULL DEFAULT 'SELLER',
    country_code            CHAR(2) NOT NULL,
    currency_code           CHAR(3) NOT NULL,
    timezone                TEXT NOT NULL DEFAULT 'America/Sao_Paulo',
    status                  TEXT NOT NULL DEFAULT 'ACTIVE',
    last_synced_at          TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, amazon_profile_id)
);

CREATE INDEX idx_ads_profiles_tenant ON amazon_ads_profiles(tenant_id);
CREATE INDEX idx_ads_profiles_store ON amazon_ads_profiles(store_id);
CREATE INDEX idx_ads_profiles_external ON amazon_ads_profiles(amazon_profile_id);

CREATE TABLE amc_instances (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id            UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    amazon_profile_id   UUID REFERENCES amazon_ads_profiles(id),
    amc_instance_id     TEXT NOT NULL,
    name                TEXT NOT NULL,
    region              TEXT NOT NULL DEFAULT 'NA',
    country             CHAR(2) NOT NULL DEFAULT 'BR',
    status              TEXT NOT NULL DEFAULT 'ACTIVE',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, amc_instance_id)
);

CREATE INDEX idx_amc_instances_tenant ON amc_instances(tenant_id);
CREATE INDEX idx_amc_instances_store ON amc_instances(store_id);
CREATE INDEX idx_amc_instances_profile ON amc_instances(amazon_profile_id);
CREATE INDEX idx_amc_instances_external ON amc_instances(amc_instance_id);
