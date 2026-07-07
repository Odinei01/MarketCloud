-- Migration 021: bronze_amc_placement_creative_daily (E007)
-- Grain: data_date / campaign_id / ad_product_type / ad_group_name
--        / targeting / match_type / placement_type / creative / creative_type / creative_asin
--
-- Source: sponsored_ads_traffic (traffic-only, no conversion metrics).
-- Cross with E001/E002/E005 in Silver/Gold for placement-level ROAS.

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_placement_creative_daily (
    -- Identity
    tenant_id          TEXT        NOT NULL,
    amc_instance_id    TEXT        NOT NULL,
    ads_profile_id     TEXT        NOT NULL,
    workflow_run_id    BIGINT,

    -- Grain
    data_date          DATE        NOT NULL,
    campaign_id        TEXT        NOT NULL,
    campaign_name      TEXT        NOT NULL,
    ad_product_type    TEXT        NOT NULL,
    ad_group_name      TEXT        NOT NULL DEFAULT 'NO_AD_GROUP',
    targeting          TEXT        NOT NULL DEFAULT 'NO_TARGETING',
    match_type         TEXT        NOT NULL DEFAULT 'NO_MATCH_TYPE',
    placement_type     TEXT        NOT NULL DEFAULT 'NO_PLACEMENT',
    creative           TEXT        NOT NULL DEFAULT 'NO_CREATIVE',
    creative_type      TEXT        NOT NULL DEFAULT 'NO_CREATIVE_TYPE',
    creative_asin      TEXT        NOT NULL DEFAULT 'NO_CREATIVE_ASIN',

    -- Dimensions
    currency_iso_code  TEXT,
    portfolio_id       TEXT        NOT NULL DEFAULT 'NO_PORTFOLIO',
    portfolio_name     TEXT        NOT NULL DEFAULT 'NO_PORTFOLIO',

    -- Traffic metrics
    activity_rows              BIGINT        NOT NULL DEFAULT 0,
    impressions                BIGINT        NOT NULL DEFAULT 0,
    clicks                     BIGINT        NOT NULL DEFAULT 0,
    spend                      NUMERIC(18,6) NOT NULL DEFAULT 0,
    viewable_impressions       BIGINT        NOT NULL DEFAULT 0,
    five_sec_views             BIGINT        NOT NULL DEFAULT 0,

    -- Video metrics
    video_first_quartile_views BIGINT        NOT NULL DEFAULT 0,
    video_midpoint_views       BIGINT        NOT NULL DEFAULT 0,
    video_third_quartile_views BIGINT        NOT NULL DEFAULT 0,
    video_complete_views       BIGINT        NOT NULL DEFAULT 0,
    video_unmutes              BIGINT        NOT NULL DEFAULT 0,

    -- Derived KPIs (computed in SQL, stored for query performance)
    ctr                    NUMERIC(10,8) NOT NULL DEFAULT 0,
    cpc                    NUMERIC(18,6) NOT NULL DEFAULT 0,
    viewability_rate       NUMERIC(10,8) NOT NULL DEFAULT 0,
    video_completion_rate  NUMERIC(10,8) NOT NULL DEFAULT 0,

    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (
        tenant_id, amc_instance_id, ads_profile_id,
        data_date, campaign_id, ad_product_type, ad_group_name,
        targeting, match_type, placement_type, creative, creative_type, creative_asin
    )
);

CREATE INDEX IF NOT EXISTS idx_bronze_placement_date
    ON marketcloud_bronze.bronze_amc_placement_creative_daily (tenant_id, amc_instance_id, data_date);

CREATE INDEX IF NOT EXISTS idx_bronze_placement_campaign
    ON marketcloud_bronze.bronze_amc_placement_creative_daily (tenant_id, amc_instance_id, campaign_id);

CREATE INDEX IF NOT EXISTS idx_bronze_placement_type_date
    ON marketcloud_bronze.bronze_amc_placement_creative_daily (tenant_id, amc_instance_id, placement_type, data_date);

CREATE INDEX IF NOT EXISTS idx_bronze_placement_asin_date
    ON marketcloud_bronze.bronze_amc_placement_creative_daily (tenant_id, amc_instance_id, creative_asin, data_date);

-- E007 extract definition
INSERT INTO marketcloud_control.extract_definitions (
    extract_code, extract_name, extract_family,
    source_tables, destination_schema, destination_table,
    schedule_type, default_lookback_days, is_active
) VALUES (
    'E007_PLACEMENT_CREATIVE_DAILY_EXTRACT',
    'Placement Creative Daily Performance Extract',
    'AMC_SPONSORED_ADS',
    ARRAY['sponsored_ads_traffic'],
    'marketcloud_bronze',
    'bronze_amc_placement_creative_daily',
    'DAILY',
    35,
    true
) ON CONFLICT (extract_code) DO NOTHING;
