-- Migration 002: users, roles, api_clients

CREATE TYPE user_role AS ENUM (
    'SUPER_ADMIN', 'TENANT_ADMIN', 'AGENCY_MANAGER',
    'STORE_MANAGER', 'ANALYST', 'READ_ONLY', 'API_CLIENT'
);

CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    email           TEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    name            TEXT NOT NULL,
    role            user_role NOT NULL DEFAULT 'ANALYST',
    status          TEXT NOT NULL DEFAULT 'ACTIVE',
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, email)
);

CREATE INDEX idx_users_tenant ON users(tenant_id);
CREATE INDEX idx_users_email ON users(email);

-- Store-scoped access: which stores a user can access
CREATE TABLE user_store_access (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    store_id    UUID NOT NULL,
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, store_id)
);

CREATE TABLE api_clients (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    api_key         TEXT NOT NULL UNIQUE,
    api_secret_hash TEXT NOT NULL,
    scopes          TEXT[] NOT NULL DEFAULT '{}',
    store_ids       UUID[] NOT NULL DEFAULT '{}',
    status          TEXT NOT NULL DEFAULT 'ACTIVE',
    last_used_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_api_clients_tenant ON api_clients(tenant_id);
CREATE INDEX idx_api_clients_key ON api_clients(api_key);

-- Refresh tokens
CREATE TABLE refresh_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tenant_id   UUID NOT NULL,
    token_hash  TEXT NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    revoked     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_refresh_tokens_user ON refresh_tokens(user_id);
CREATE INDEX idx_refresh_tokens_hash ON refresh_tokens(token_hash);
