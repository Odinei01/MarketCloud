-- Migration 020: bronze_amc_traffic_attribution_hourly (E006)
-- Grain: traffic_date / traffic_hour / campaign_id / ad_product_type
--        / targeting / match_type / customer_search_term
--
-- Source: amazon_attributed_events_by_traffic_time
-- No spend column — use E004 or E001 to get spend, then cross-join in Silver for assisted ROAS.

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_traffic_attribution_hourly (
    -- Identity
    tenant_id          TEXT        NOT NULL,
    amc_instance_id    TEXT        NOT NULL,
    ads_profile_id     TEXT        NOT NULL,
    workflow_run_id    BIGINT,

    -- Grain
    traffic_date           DATE        NOT NULL,
    traffic_hour           SMALLINT    NOT NULL,
    campaign_id            TEXT        NOT NULL,
    campaign_name          TEXT        NOT NULL,
    ad_product_type        TEXT        NOT NULL,
    targeting              TEXT        NOT NULL DEFAULT 'NO_TARGETING',
    match_type             TEXT        NOT NULL DEFAULT 'NO_MATCH_TYPE',
    customer_search_term   TEXT        NOT NULL DEFAULT 'NO_SEARCH_TERM',

    -- Dimension
    purchase_currency  TEXT,

    -- Row count
    attribution_rows       BIGINT      NOT NULL DEFAULT 0,

    -- Traffic signals
    attributed_impressions BIGINT      NOT NULL DEFAULT 0,
    attributed_clicks      BIGINT      NOT NULL DEFAULT 0,

    -- Conversion metrics
    attributed_orders         NUMERIC(18,4) NOT NULL DEFAULT 0,
    attributed_sales          NUMERIC(18,4) NOT NULL DEFAULT 0,
    attributed_units_sold     NUMERIC(18,4) NOT NULL DEFAULT 0,
    attributed_add_to_cart    NUMERIC(18,4) NOT NULL DEFAULT 0,
    attributed_detail_page_views NUMERIC(18,4) NOT NULL DEFAULT 0,

    -- Brand / NTB / channel split
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

    -- Derived attribution KPIs (computed in SQL, stored for query performance)
    click_conversion_rate  NUMERIC(10,8) NOT NULL DEFAULT 0,
    view_conversion_rate   NUMERIC(10,8) NOT NULL DEFAULT 0,
    click_attribution_share NUMERIC(10,8) NOT NULL DEFAULT 0,

    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (
        tenant_id, amc_instance_id, ads_profile_id,
        traffic_date, traffic_hour, campaign_id, ad_product_type,
        targeting, match_type, customer_search_term
    )
);

CREATE INDEX IF NOT EXISTS idx_bronze_tattr_date
    ON marketcloud_bronze.bronze_amc_traffic_attribution_hourly (tenant_id, amc_instance_id, traffic_date);

CREATE INDEX IF NOT EXISTS idx_bronze_tattr_campaign
    ON marketcloud_bronze.bronze_amc_traffic_attribution_hourly (tenant_id, amc_instance_id, campaign_id);

CREATE INDEX IF NOT EXISTS idx_bronze_tattr_date_hour
    ON marketcloud_bronze.bronze_amc_traffic_attribution_hourly (tenant_id, amc_instance_id, traffic_date, traffic_hour);

-- E006 extract definition
INSERT INTO marketcloud_control.extract_definitions (
    extract_code, extract_name, extract_family,
    source_tables, destination_schema, destination_table,
    schedule_type, default_lookback_days, is_active
) VALUES (
    'E006_TRAFFIC_TIME_ATTRIBUTION_EXTRACT',
    'Traffic Time Attribution Hourly Extract',
    'AMC_SPONSORED_ADS',
    ARRAY['amazon_attributed_events_by_traffic_time'],
    'marketcloud_bronze',
    'bronze_amc_traffic_attribution_hourly',
    'DAILY',
    35,
    true
) ON CONFLICT (extract_code) DO NOTHING;
