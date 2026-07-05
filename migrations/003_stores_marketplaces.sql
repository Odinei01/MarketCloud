-- Migration 003: stores, marketplace_accounts

CREATE TABLE stores (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    organization_id  UUID REFERENCES organizations(id),
    name             TEXT NOT NULL,
    brand_name       TEXT,
    country          CHAR(2) NOT NULL DEFAULT 'BR',
    default_currency CHAR(3) NOT NULL DEFAULT 'BRL',
    timezone         TEXT NOT NULL DEFAULT 'America/Sao_Paulo',
    status           TEXT NOT NULL DEFAULT 'ACTIVE',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_stores_tenant ON stores(tenant_id);
CREATE INDEX idx_stores_org ON stores(organization_id);

-- Update user_store_access FK now that stores table exists
ALTER TABLE user_store_access ADD CONSTRAINT fk_usa_store
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE CASCADE;

CREATE TYPE marketplace_type AS ENUM (
    'AMAZON_BR', 'AMAZON_US', 'AMAZON_MX', 'AMAZON_CA'
);

CREATE TABLE marketplace_accounts (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    store_id         UUID NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    marketplace      marketplace_type NOT NULL,
    seller_id        TEXT,
    vendor_code      TEXT,
    country          CHAR(2) NOT NULL,
    region           TEXT,
    status           TEXT NOT NULL DEFAULT 'ACTIVE',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, store_id, marketplace)
);

CREATE INDEX idx_marketplace_accounts_tenant ON marketplace_accounts(tenant_id);
CREATE INDEX idx_marketplace_accounts_store ON marketplace_accounts(store_id);
