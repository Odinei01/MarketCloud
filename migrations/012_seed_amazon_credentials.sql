-- Migration 012: Real Amazon credentials for ZANOM tenant
-- Credentials sourced from mercado-data-app/.env (Amazon Ads LWA)
-- access_token starts as placeholder — connector auto-refreshes on first use

INSERT INTO amazon_oauth_connections (
    tenant_id, store_id, amazon_user_id,
    access_token, refresh_token, token_expires_at, scopes, status
)
VALUES (
    'd7ec8c23-3f86-4cd1-b4cb-2a753a74c5f9',
    'f1a59d8d-2966-45c1-83be-8e20c87ea1e0',
    'ASQLT2MYDN3WG',
    'placeholder-will-be-refreshed-on-first-use',
    'Atzr|IwEBIHWkG2aZM8pmqqkZXNGpH8PA-SDWY9Gy13n6wvvKVlQmkPXJdNZh0X7FabHkLPot0iBik6TtQpLHSDGR75g1BHwj4WTGAyrFdtvEObQX0xUbtZn00L4dm4dP_HY--ojLAw9myS9lyezh-g-qjYRLpACiPfvirEWKzNnKmnX7WBdXwFBrJy2MJdHTi3f3RKlDQqeIBr4pMYLQE4u_XBgZtWS_neMo7zfTXMFmnaEvI-vaWbB8gEQMXBx9_3u6xSGCYg-i6z4kFPJd3LXyqHGnjHn7Zsn5emkjJb2yADNGLWgXhaOQVWPFbfC9ZQ6OS3Y75MjNZGGrp9JFXPvVe9o8b1_tvYORg8O-MOq55GLQGzTSDKsLabpdIhS5zg_P-L7CbKZAR4zB5kBrCQETbMMmimgT-lkpTCkD5-zn-GuV9ykPtwEpVuSoz-_swuzw4YP9JEM21gEXR6ChPG1fMVO6yhoImO009uwWDDqKUPuw0rIJJknPm4GUbcdjX6DPh-rqvQ7AdiiTwjtCIiFnPZFhyf2GOiWzuTgxr6G5gtunC8XvoQ',
    NOW() - INTERVAL '1 hour',
    ARRAY['advertising::campaign_management', 'advertising::reporting'],
    'ACTIVE'
)
ON CONFLICT (tenant_id, store_id) DO UPDATE SET
    refresh_token    = EXCLUDED.refresh_token,
    token_expires_at = NOW() - INTERVAL '1 hour',
    status           = 'ACTIVE',
    updated_at       = NOW();

INSERT INTO amazon_ads_profiles (
    tenant_id, store_id, amazon_profile_id,
    account_type, country_code, currency_code, timezone, status
)
VALUES (
    'd7ec8c23-3f86-4cd1-b4cb-2a753a74c5f9',
    'f1a59d8d-2966-45c1-83be-8e20c87ea1e0',
    '3084626225435227',
    'SELLER', 'BR', 'BRL', 'America/Sao_Paulo', 'ACTIVE'
)
ON CONFLICT (tenant_id, amazon_profile_id) DO UPDATE SET
    store_id = EXCLUDED.store_id, status = 'ACTIVE', updated_at = NOW();

INSERT INTO amc_instances (
    tenant_id, store_id, amazon_profile_id,
    amc_instance_id, name, region, country, status
)
SELECT
    'd7ec8c23-3f86-4cd1-b4cb-2a753a74c5f9',
    'f1a59d8d-2966-45c1-83be-8e20c87ea1e0',
    p.id,
    'amcoo5vzswt',
    'ZANOM Brasil AMC',
    'NA', 'BR', 'ACTIVE'
FROM amazon_ads_profiles p
WHERE p.tenant_id = 'd7ec8c23-3f86-4cd1-b4cb-2a753a74c5f9'
  AND p.amazon_profile_id = '3084626225435227'
ON CONFLICT (tenant_id, amc_instance_id) DO UPDATE SET
    status = 'ACTIVE', region = 'NA', updated_at = NOW();
