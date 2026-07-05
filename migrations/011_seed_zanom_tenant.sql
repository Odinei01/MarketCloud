-- Migration 011: ZANOM tenant seed completo com seller ID real
-- Reproduz o estado criado via API + seller ID Amazon real

INSERT INTO tenants (id, name, slug, status, plan, billing_status)
VALUES (
  'd7ec8c23-3f86-4cd1-b4cb-2a753a74c5f9',
  'ZANOM Marketplace',
  'zanom',
  'ACTIVE',
  'STARTER',
  'ACTIVE'
) ON CONFLICT (id) DO NOTHING;

-- Hash bcrypt cost=12 de "Zanom@123"
INSERT INTO users (id, tenant_id, email, password_hash, name, role, status)
VALUES (
  'fa5220d1-9f8d-4938-8b60-25cb33677f1f',
  'd7ec8c23-3f86-4cd1-b4cb-2a753a74c5f9',
  'admin@zanom.com',
  '$2b$12$LK9.G5M7F0YS5BQ6Yw7JlO9kMpNfEsHr3ZjKx8YwQdVuR6M4TeLoa',
  'Admin ZANOM',
  'TENANT_ADMIN',
  'ACTIVE'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO stores (id, tenant_id, name, brand_name, country, default_currency, timezone, status)
VALUES (
  'f1a59d8d-2966-45c1-83be-8e20c87ea1e0',
  'd7ec8c23-3f86-4cd1-b4cb-2a753a74c5f9',
  'ZANOM Brasil',
  'ZANOM',
  'BR',
  'BRL',
  'America/Sao_Paulo',
  'ACTIVE'
) ON CONFLICT (id) DO UPDATE SET
  name       = 'ZANOM Brasil',
  brand_name = 'ZANOM',
  updated_at = NOW();

INSERT INTO marketplace_accounts (tenant_id, store_id, marketplace, seller_id, country, region, status)
VALUES (
  'd7ec8c23-3f86-4cd1-b4cb-2a753a74c5f9',
  'f1a59d8d-2966-45c1-83be-8e20c87ea1e0',
  'AMAZON_BR',
  'ASQLT2MYDN3WG',
  'BR',
  'FE',
  'ACTIVE'
) ON CONFLICT (tenant_id, store_id, marketplace) DO UPDATE SET
  seller_id  = 'ASQLT2MYDN3WG',
  updated_at = NOW();
