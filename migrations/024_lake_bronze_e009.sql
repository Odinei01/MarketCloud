-- Migration 024: bronze_amc_conversions_unified_daily (E009)
-- Grain: attribution_mode / attribution_date / campaign_id / ad_product_type
--        / targeting / match_type / customer_search_term / tracked_asin
--
-- attribution_mode: CONVERSION_TIME | TRAFFIC_TIME
-- tracked_asin uses NO_ASIN sentinel to preserve add_to_cart/dpv events without a purchased ASIN.
-- No spend — cross with E001/E002/E003/E004 in Silver for ROAS and CPA.

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_conversions_unified_daily (
    -- Identity
    tenant_id          TEXT        NOT NULL,
    amc_instance_id    TEXT        NOT NULL,
    ads_profile_id     TEXT        NOT NULL,
    workflow_run_id    BIGINT,

    -- Grain
    attribution_mode       TEXT        NOT NULL,
    attribution_date       DATE        NOT NULL,
    campaign_id            TEXT        NOT NULL,
    campaign_name          TEXT        NOT NULL,
    ad_product_type        TEXT        NOT NULL,
    targeting              TEXT        NOT NULL DEFAULT 'NO_TARGETING',
    match_type             TEXT        NOT NULL DEFAULT 'NO_MATCH_TYPE',
    customer_search_term   TEXT        NOT NULL DEFAULT 'NO_SEARCH_TERM',
    tracked_asin           TEXT        NOT NULL DEFAULT 'NO_ASIN',

    -- Dimension
    purchase_currency  TEXT,

    -- Row count
    conversion_rows        BIGINT      NOT NULL DEFAULT 0,

    -- Core conversion metrics
    orders                 NUMERIC(18,4) NOT NULL DEFAULT 0,
    sales                  NUMERIC(18,4) NOT NULL DEFAULT 0,
    units_sold             NUMERIC(18,4) NOT NULL DEFAULT 0,
    add_to_cart            NUMERIC(18,4) NOT NULL DEFAULT 0,
    detail_page_views      NUMERIC(18,4) NOT NULL DEFAULT 0,

    -- Brand halo
    brand_halo_orders      NUMERIC(18,4) NOT NULL DEFAULT 0,
    brand_halo_sales       NUMERIC(18,4) NOT NULL DEFAULT 0,

    -- New to brand
    new_to_brand_orders    NUMERIC(18,4) NOT NULL DEFAULT 0,
    new_to_brand_sales     NUMERIC(18,4) NOT NULL DEFAULT 0,

    -- Click vs view split
    purchases_clicks       NUMERIC(18,4) NOT NULL DEFAULT 0,
    purchases_views        NUMERIC(18,4) NOT NULL DEFAULT 0,
    product_sales_clicks   NUMERIC(18,4) NOT NULL DEFAULT 0,
    product_sales_views    NUMERIC(18,4) NOT NULL DEFAULT 0,

    -- Extended
    off_amazon_sales       NUMERIC(18,4) NOT NULL DEFAULT 0,
    combined_sales         NUMERIC(18,4) NOT NULL DEFAULT 0,

    -- Derived KPIs
    brand_halo_order_share    NUMERIC(10,8) NOT NULL DEFAULT 0,
    new_to_brand_order_share  NUMERIC(10,8) NOT NULL DEFAULT 0,
    new_to_brand_sales_share  NUMERIC(10,8) NOT NULL DEFAULT 0,
    click_attribution_share   NUMERIC(10,8) NOT NULL DEFAULT 0,
    average_order_value       NUMERIC(18,4) NOT NULL DEFAULT 0,

    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (
        tenant_id, amc_instance_id, ads_profile_id,
        attribution_mode, attribution_date, campaign_id, ad_product_type,
        targeting, match_type, customer_search_term, tracked_asin
    )
);

CREATE INDEX IF NOT EXISTS idx_bronze_conv_unified_date
    ON marketcloud_bronze.bronze_amc_conversions_unified_daily (tenant_id, amc_instance_id, attribution_date);

CREATE INDEX IF NOT EXISTS idx_bronze_conv_unified_mode_date
    ON marketcloud_bronze.bronze_amc_conversions_unified_daily (tenant_id, amc_instance_id, attribution_mode, attribution_date);

CREATE INDEX IF NOT EXISTS idx_bronze_conv_unified_campaign
    ON marketcloud_bronze.bronze_amc_conversions_unified_daily (tenant_id, amc_instance_id, campaign_id);

CREATE INDEX IF NOT EXISTS idx_bronze_conv_unified_asin
    ON marketcloud_bronze.bronze_amc_conversions_unified_daily (tenant_id, amc_instance_id, tracked_asin);

-- E009 extract definition
INSERT INTO marketcloud_control.extract_definitions (
    extract_code, extract_name, extract_family,
    source_tables, destination_schema, destination_table,
    schedule_type, default_lookback_days, is_active
) VALUES (
    'E009_CONVERSIONS_UNIFIED_EXTRACT',
    'Conversions Unified Daily Extract',
    'AMC_SPONSORED_ADS',
    ARRAY['amazon_attributed_events_by_conversion_time','amazon_attributed_events_by_traffic_time'],
    'marketcloud_bronze',
    'bronze_amc_conversions_unified_daily',
    'DAILY',
    35,
    true
) ON CONFLICT (extract_code) DO NOTHING;
