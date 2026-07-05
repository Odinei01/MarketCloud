-- Migration 005: campaigns, ad_groups, targets, products

CREATE TYPE campaign_type AS ENUM (
    'SPONSORED_PRODUCTS', 'SPONSORED_BRANDS', 'SPONSORED_DISPLAY',
    'SPONSORED_TV', 'DSP'
);

CREATE TYPE targeting_type AS ENUM ('MANUAL', 'AUTO');

CREATE TABLE campaigns (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id            UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    amazon_profile_id   UUID REFERENCES amazon_ads_profiles(id),
    campaign_id         TEXT NOT NULL,
    campaign_name       TEXT NOT NULL,
    campaign_type       campaign_type NOT NULL,
    targeting_type      targeting_type NOT NULL DEFAULT 'MANUAL',
    status              TEXT NOT NULL DEFAULT 'ENABLED',
    daily_budget        NUMERIC(12,2),
    currency            CHAR(3) NOT NULL DEFAULT 'BRL',
    start_date          DATE,
    end_date            DATE,
    last_synced_at      TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, campaign_id)
);

CREATE INDEX idx_campaigns_tenant ON campaigns(tenant_id);
CREATE INDEX idx_campaigns_store ON campaigns(store_id);
CREATE INDEX idx_campaigns_profile ON campaigns(amazon_profile_id);
CREATE INDEX idx_campaigns_external ON campaigns(campaign_id);

CREATE TABLE ad_groups (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id            UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    campaign_id         UUID NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    amazon_ad_group_id  TEXT NOT NULL,
    name                TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'ENABLED',
    default_bid         NUMERIC(10,4),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, amazon_ad_group_id)
);

CREATE INDEX idx_ad_groups_tenant ON ad_groups(tenant_id);
CREATE INDEX idx_ad_groups_campaign ON ad_groups(campaign_id);

CREATE TYPE target_type AS ENUM (
    'KEYWORD', 'ASIN', 'CATEGORY', 'AUDIENCE',
    'AUTO_CLOSE_MATCH', 'AUTO_LOOSE_MATCH', 'AUTO_SUBSTITUTES', 'AUTO_COMPLEMENTS'
);

CREATE TABLE targets (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id        UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    campaign_id     UUID REFERENCES campaigns(id) ON DELETE CASCADE,
    ad_group_id     UUID REFERENCES ad_groups(id) ON DELETE CASCADE,
    target_id       TEXT NOT NULL,
    target_type     target_type NOT NULL,
    match_type      TEXT,
    expression      TEXT NOT NULL,
    bid             NUMERIC(10,4),
    status          TEXT NOT NULL DEFAULT 'ENABLED',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, target_id)
);

CREATE INDEX idx_targets_tenant ON targets(tenant_id);
CREATE INDEX idx_targets_campaign ON targets(campaign_id);
CREATE INDEX idx_targets_ad_group ON targets(ad_group_id);

CREATE TABLE products (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id    UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    asin        TEXT NOT NULL,
    seller_sku  TEXT,
    title       TEXT,
    brand       TEXT,
    category    TEXT,
    status      TEXT NOT NULL DEFAULT 'ACTIVE',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, store_id, asin)
);

CREATE INDEX idx_products_tenant ON products(tenant_id);
CREATE INDEX idx_products_store ON products(store_id);
CREATE INDEX idx_products_asin ON products(asin);
