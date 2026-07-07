-- Migration 026: bronze_amc_audience_segment_weekly (E011)
-- Grain: week_start_date / campaign_id / line_item_id / behavior_segment_id
--        / behavior_segment_matched / currency_iso_code
--
-- behavior_segment_matched is NUMERIC — part of GROUP BY in AMC (distinct match-rate per segment).
-- impression_cost: 100000 millicents = 1 currency unit.
-- audience_fee: 100000000 microcents = 1 currency unit (conversion done in SQL).
-- Names (campaign_name, line_item_name, behavior_segment_name) are non-key labels updated on conflict.
-- Source: dsp_impressions_by_user_segments (DSP paid table).

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_audience_segment_weekly (
    -- Identity
    tenant_id          TEXT        NOT NULL,
    amc_instance_id    TEXT        NOT NULL,
    ads_profile_id     TEXT        NOT NULL,
    workflow_run_id    BIGINT,

    -- Grain
    week_start_date            DATE          NOT NULL,
    campaign_id                TEXT          NOT NULL,
    line_item_id               TEXT          NOT NULL DEFAULT 'NO_LINE_ITEM',
    behavior_segment_id        TEXT          NOT NULL,
    behavior_segment_matched   NUMERIC(18,4) NOT NULL DEFAULT 0,
    currency_iso_code          TEXT          NOT NULL DEFAULT 'UNKNOWN',

    -- Non-key dimensions (labels)
    campaign_name              TEXT          NOT NULL DEFAULT '',
    line_item_name             TEXT          NOT NULL DEFAULT 'NO_LINE_ITEM',
    behavior_segment_name      TEXT          NOT NULL DEFAULT 'NO_SEGMENT_NAME',

    -- Row count
    impression_rows            BIGINT        NOT NULL DEFAULT 0,

    -- Core metrics
    impressions                BIGINT        NOT NULL DEFAULT 0,

    -- Spend (converted from millicents / 100000)
    spend                      NUMERIC(18,6) NOT NULL DEFAULT 0,

    -- Audience fee (converted from microcents / 100000000)
    audience_fee               NUMERIC(18,6) NOT NULL DEFAULT 0,

    -- Derived KPIs
    cost_per_impression        NUMERIC(18,10) NOT NULL DEFAULT 0,
    audience_fee_per_impression NUMERIC(18,10) NOT NULL DEFAULT 0,

    loaded_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (
        tenant_id, amc_instance_id, ads_profile_id,
        week_start_date, campaign_id, line_item_id,
        behavior_segment_id, behavior_segment_matched, currency_iso_code
    )
);

CREATE INDEX IF NOT EXISTS idx_bronze_audience_week
    ON marketcloud_bronze.bronze_amc_audience_segment_weekly (tenant_id, amc_instance_id, week_start_date);

CREATE INDEX IF NOT EXISTS idx_bronze_audience_campaign
    ON marketcloud_bronze.bronze_amc_audience_segment_weekly (tenant_id, amc_instance_id, campaign_id);

CREATE INDEX IF NOT EXISTS idx_bronze_audience_segment
    ON marketcloud_bronze.bronze_amc_audience_segment_weekly (tenant_id, amc_instance_id, behavior_segment_id);

-- E011 extract definition
INSERT INTO marketcloud_control.extract_definitions (
    extract_code, extract_name, extract_family,
    source_tables, destination_schema, destination_table,
    schedule_type, default_lookback_days, is_active
) VALUES (
    'E011_AUDIENCE_SEGMENT_WEEKLY_EXTRACT',
    'Audience Segment Weekly Extract',
    'AMC_DSP',
    ARRAY['dsp_impressions_by_user_segments'],
    'marketcloud_bronze',
    'bronze_amc_audience_segment_weekly',
    'WEEKLY',
    35,
    true
) ON CONFLICT (extract_code) DO NOTHING;
