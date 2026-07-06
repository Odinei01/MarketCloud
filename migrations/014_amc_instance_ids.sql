-- Migration 014: add advertiser entity_id and marketplace_id to amc_instances
-- entity_id    = sponsored ads entity ID (Amazon-Advertising-API-AdvertiserId)
-- marketplace_id = marketplace string ID   (Amazon-Advertising-API-MarketplaceId)
ALTER TABLE amc_instances
    ADD COLUMN IF NOT EXISTS entity_id     TEXT,
    ADD COLUMN IF NOT EXISTS marketplace_id TEXT;

-- Backfill ZANOM values
UPDATE amc_instances
SET entity_id      = 'ENTITY1A6DL03BNNULZ',
    marketplace_id = 'A2Q3Y263D00KWC'
WHERE amc_instance_id = 'amcoo5vzswt';
