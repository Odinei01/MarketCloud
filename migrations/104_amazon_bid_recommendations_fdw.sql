-- Expose Amazon Ads bid recommendation cache from SWARM.
--
-- This is the source of Amazon's lower/median/upper suggested keyword bid range.
-- The target V3 ML worker must prefer this cache over amazon_ads_bid_decisions,
-- because decisions can be generated before the recommendation endpoint is
-- called and then persist zeros.

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_ads_bid_recommendations (
    id bigint,
    profile_id text,
    campaign_id text,
    ad_group_id text,
    target_id text,
    keyword_id text,
    entity_type text,
    recommended_bid_lower numeric(14,2),
    recommended_bid_median numeric(14,2),
    recommended_bid_upper numeric(14,2),
    currency text,
    raw_payload_sanitized jsonb,
    fetched_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_ads_bid_recommendations');

COMMENT ON FOREIGN TABLE swarm_src.amazon_ads_bid_recommendations IS
'SWARM cache of Amazon Ads /v2/sp/keywords/bidRecommendations. Used by HourlyTargetRealV3 as Amazon bid-range context.';
