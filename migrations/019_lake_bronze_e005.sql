-- Migration 019: bronze_amc_product_asin_daily (E005)
-- Grain: data_date / product_role / campaign_id / ad_product_type / ad_group_key
--        / targeting / match_type / customer_search_term / product_asin
--
-- product_role: ADVERTISED_ASIN | CONVERTED_ASIN
-- No join between creative_asin and tracked_asin — avoids spend duplication.

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_product_asin_daily (
    -- Identity
    tenant_id          TEXT        NOT NULL,
    amc_instance_id    TEXT        NOT NULL,
    ads_profile_id     TEXT        NOT NULL,
    workflow_run_id    BIGINT,

    -- Grain
    data_date              DATE        NOT NULL,
    product_role           TEXT        NOT NULL,
    campaign_id            TEXT        NOT NULL,
    campaign_name          TEXT        NOT NULL,
    ad_product_type        TEXT        NOT NULL,
    ad_group_name          TEXT,
    ad_group_key           TEXT        NOT NULL DEFAULT 'NO_AD_GROUP',
    targeting              TEXT        NOT NULL DEFAULT 'NO_TARGETING',
    match_type             TEXT        NOT NULL DEFAULT 'NO_MATCH_TYPE',
    customer_search_term   TEXT        NOT NULL DEFAULT 'NO_SEARCH_TERM',
    product_asin           TEXT        NOT NULL,

    -- Dimensions
    currency_iso_code  TEXT,
    purchase_currency  TEXT,
    portfolio_id       TEXT,
    portfolio_name     TEXT,

    -- Traffic metrics (zero for CONVERTED_ASIN rows)
    activity_rows          BIGINT      NOT NULL DEFAULT 0,
    impressions            BIGINT      NOT NULL DEFAULT 0,
    clicks                 BIGINT      NOT NULL DEFAULT 0,
    spend                  NUMERIC(18,6) NOT NULL DEFAULT 0,
    viewable_impressions   BIGINT      NOT NULL DEFAULT 0,
    five_sec_views         BIGINT      NOT NULL DEFAULT 0,

    -- Conversion metrics (zero for ADVERTISED_ASIN rows)
    orders                 NUMERIC(18,4) NOT NULL DEFAULT 0,
    sales                  NUMERIC(18,4) NOT NULL DEFAULT 0,
    units_sold             NUMERIC(18,4) NOT NULL DEFAULT 0,
    add_to_cart            NUMERIC(18,4) NOT NULL DEFAULT 0,
    detail_page_views      NUMERIC(18,4) NOT NULL DEFAULT 0,
    brand_halo_orders      NUMERIC(18,4) NOT NULL DEFAULT 0,
    brand_halo_sales       NUMERIC(18,4) NOT NULL DEFAULT 0,
    new_to_brand_orders    NUMERIC(18,4) NOT NULL DEFAULT 0,
    new_to_brand_sales     NUMERIC(18,4) NOT NULL DEFAULT 0,
    purchases_clicks       NUMERIC(18,4) NOT NULL DEFAULT 0,
    purchases_views        NUMERIC(18,4) NOT NULL DEFAULT 0,
    product_sales_clicks   NUMERIC(18,4) NOT NULL DEFAULT 0,
    product_sales_views    NUMERIC(18,4) NOT NULL DEFAULT 0,
    off_amazon_sales       NUMERIC(18,4) NOT NULL DEFAULT 0,
    combined_sales         NUMERIC(18,4) NOT NULL DEFAULT 0,

    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (
        tenant_id, amc_instance_id, ads_profile_id,
        data_date, product_role, campaign_id, ad_product_type,
        ad_group_key, targeting, match_type, customer_search_term, product_asin
    )
);

CREATE INDEX IF NOT EXISTS idx_bronze_product_date
    ON marketcloud_bronze.bronze_amc_product_asin_daily (tenant_id, amc_instance_id, data_date);

CREATE INDEX IF NOT EXISTS idx_bronze_product_asin
    ON marketcloud_bronze.bronze_amc_product_asin_daily (tenant_id, amc_instance_id, product_asin);

CREATE INDEX IF NOT EXISTS idx_bronze_product_role_date
    ON marketcloud_bronze.bronze_amc_product_asin_daily (tenant_id, amc_instance_id, product_role, data_date);

-- E005 extract definition
INSERT INTO marketcloud_control.extract_definitions (
    extract_code, extract_name, extract_family,
    source_tables, destination_schema, destination_table,
    schedule_type, default_lookback_days, is_active
) VALUES (
    'E005_PRODUCT_ASIN_DAILY_EXTRACT',
    'Product ASIN Daily Performance Extract',
    'AMC_SPONSORED_ADS',
    ARRAY['sponsored_ads_traffic','amazon_attributed_events_by_conversion_time'],
    'marketcloud_bronze',
    'bronze_amc_product_asin_daily',
    'DAILY',
    35,
    true
) ON CONFLICT (extract_code) DO NOTHING;
