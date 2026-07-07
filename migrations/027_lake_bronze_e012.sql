-- Migration 027: bronze_amc_retail_purchases_weekly (E012)
-- Grain: week_start_date / asin / parent_asin / purchase_currency
--
-- NOT ads-attributed — raw retail demand from amazon_retail_purchases (ARP scope).
-- product_title and brand are non-key labels (updated on conflict).
-- purchase_sales = unit_price * purchase_units_sold (computed in SQL).
-- No category column in source — enrich in Silver/Gold with own catalog.
-- Source: amazon_retail_purchases (subscribable ARP table).

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_retail_purchases_weekly (
    -- Identity
    tenant_id          TEXT        NOT NULL,
    amc_instance_id    TEXT        NOT NULL,
    ads_profile_id     TEXT        NOT NULL,
    workflow_run_id    BIGINT,

    -- Grain
    week_start_date    DATE          NOT NULL,
    asin               TEXT          NOT NULL,
    parent_asin        TEXT          NOT NULL DEFAULT 'NO_PARENT_ASIN',
    purchase_currency  TEXT          NOT NULL DEFAULT 'UNKNOWN',

    -- Non-key dimensions
    product_title      TEXT          NOT NULL DEFAULT 'NO_PRODUCT_TITLE',
    brand              TEXT          NOT NULL DEFAULT 'NO_BRAND',

    -- Row count
    purchase_rows      BIGINT        NOT NULL DEFAULT 0,

    -- Core metrics
    units_purchased    NUMERIC(18,4) NOT NULL DEFAULT 0,
    purchase_sales     NUMERIC(18,4) NOT NULL DEFAULT 0,

    -- Derived KPIs
    units_per_purchase     NUMERIC(18,6) NOT NULL DEFAULT 0,
    average_unit_price     NUMERIC(18,4) NOT NULL DEFAULT 0,
    average_purchase_value NUMERIC(18,4) NOT NULL DEFAULT 0,

    loaded_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (
        tenant_id, amc_instance_id, ads_profile_id,
        week_start_date, asin, parent_asin, purchase_currency
    )
);

CREATE INDEX IF NOT EXISTS idx_bronze_retail_week
    ON marketcloud_bronze.bronze_amc_retail_purchases_weekly (tenant_id, amc_instance_id, week_start_date);

CREATE INDEX IF NOT EXISTS idx_bronze_retail_asin
    ON marketcloud_bronze.bronze_amc_retail_purchases_weekly (tenant_id, amc_instance_id, asin);

CREATE INDEX IF NOT EXISTS idx_bronze_retail_parent_asin
    ON marketcloud_bronze.bronze_amc_retail_purchases_weekly (tenant_id, amc_instance_id, parent_asin);

-- E012 extract definition
INSERT INTO marketcloud_control.extract_definitions (
    extract_code, extract_name, extract_family,
    source_tables, destination_schema, destination_table,
    schedule_type, default_lookback_days, is_active
) VALUES (
    'E012_RETAIL_PURCHASES_WEEKLY_EXTRACT',
    'Retail Purchases Weekly Extract',
    'AMC_RETAIL',
    ARRAY['amazon_retail_purchases'],
    'marketcloud_bronze',
    'bronze_amc_retail_purchases_weekly',
    'WEEKLY',
    35,
    true
) ON CONFLICT (extract_code) DO NOTHING;
