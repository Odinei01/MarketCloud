-- Migration 025: bronze_amc_brand_store_daily (E010)
-- Grain: store_event_date / store_id / page_id / ingress_type / referrer_domain
--        / channel / device_type / campaign_id / event_sub_type / widget_type
--        / widget_sub_type / asin
--
-- page_title excluded from PK — it is a label that can change without invalidating the row.
-- campaign_id comes from reference_id in both source tables.
-- Sources: amazon_brand_store_page_views + amazon_brand_store_engagement_events (paid/subscribable).
-- page_views-driven: every page_view row enters even with no matching engagement.
-- No spend — cross with E001/E008/E009 in Silver/Gold for ROAS.

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_brand_store_daily (
    -- Identity
    tenant_id          TEXT        NOT NULL,
    amc_instance_id    TEXT        NOT NULL,
    ads_profile_id     TEXT        NOT NULL,
    workflow_run_id    BIGINT,

    -- Grain
    store_event_date   DATE        NOT NULL,
    store_id           TEXT        NOT NULL DEFAULT 'NO_STORE',
    page_id            TEXT        NOT NULL DEFAULT 'NO_PAGE',
    ingress_type       TEXT        NOT NULL DEFAULT 'NO_INGRESS',
    referrer_domain    TEXT        NOT NULL DEFAULT 'NO_REFERRER',
    channel            TEXT        NOT NULL DEFAULT 'NO_CHANNEL',
    device_type        TEXT        NOT NULL DEFAULT 'NO_DEVICE',
    campaign_id        TEXT        NOT NULL DEFAULT 'NO_CAMPAIGN',
    event_sub_type     TEXT        NOT NULL DEFAULT 'NO_EVENT_SUBTYPE',
    widget_type        TEXT        NOT NULL DEFAULT 'NO_WIDGET_TYPE',
    widget_sub_type    TEXT        NOT NULL DEFAULT 'NO_WIDGET_SUBTYPE',
    asin               TEXT        NOT NULL DEFAULT 'NO_ASIN',

    -- Non-key dimension
    page_title         TEXT        NOT NULL DEFAULT 'NO_PAGE_TITLE',

    -- Page view metrics
    page_view_rows             BIGINT        NOT NULL DEFAULT 0,
    total_dwell_time_seconds   NUMERIC(18,4) NOT NULL DEFAULT 0,
    avg_dwell_time_seconds     NUMERIC(18,4) NOT NULL DEFAULT 0,

    -- Engagement metrics
    engagement_rows            BIGINT        NOT NULL DEFAULT 0,

    loaded_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (
        tenant_id, amc_instance_id, ads_profile_id,
        store_event_date, store_id, page_id,
        ingress_type, referrer_domain, channel, device_type,
        campaign_id, event_sub_type, widget_type, widget_sub_type, asin
    )
);

CREATE INDEX IF NOT EXISTS idx_bronze_store_date
    ON marketcloud_bronze.bronze_amc_brand_store_daily (tenant_id, amc_instance_id, store_event_date);

CREATE INDEX IF NOT EXISTS idx_bronze_store_page
    ON marketcloud_bronze.bronze_amc_brand_store_daily (tenant_id, amc_instance_id, store_id, page_id);

CREATE INDEX IF NOT EXISTS idx_bronze_store_campaign
    ON marketcloud_bronze.bronze_amc_brand_store_daily (tenant_id, amc_instance_id, campaign_id);

CREATE INDEX IF NOT EXISTS idx_bronze_store_asin
    ON marketcloud_bronze.bronze_amc_brand_store_daily (tenant_id, amc_instance_id, asin);

-- E010 extract definition
INSERT INTO marketcloud_control.extract_definitions (
    extract_code, extract_name, extract_family,
    source_tables, destination_schema, destination_table,
    schedule_type, default_lookback_days, is_active
) VALUES (
    'E010_BRAND_STORE_DAILY_EXTRACT',
    'Brand Store Daily Extract',
    'AMC_BRAND_STORE',
    ARRAY['amazon_brand_store_page_views','amazon_brand_store_engagement_events'],
    'marketcloud_bronze',
    'bronze_amc_brand_store_daily',
    'DAILY',
    35,
    true
) ON CONFLICT (extract_code) DO NOTHING;
