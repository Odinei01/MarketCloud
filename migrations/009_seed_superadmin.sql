-- Bootstrap: tenant raiz + superadmin
-- Senha padrão: Admin@123 (trocar em produção)
-- Hash bcrypt cost=12 de "Admin@123"

INSERT INTO tenants (id, name, slug, status, plan, billing_status)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'Sistema MarketCloud',
  'system',
  'ACTIVE',
  'ENTERPRISE',
  'ACTIVE'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO users (id, tenant_id, email, password_hash, name, role, status)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  'superadmin@marketcloud.io',
  '$2b$12$0q.TDVW0WleqZ8YSzsSF9eGOSHxQixkVophvhz3ML2MaU6Rs6VHD.',
  'Super Admin',
  'SUPER_ADMIN',
  'ACTIVE'
) ON CONFLICT (id) DO NOTHING;
