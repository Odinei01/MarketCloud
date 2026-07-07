-- 015_lake_bronze_e001.sql
-- MarketCloud ZANOM — PostgreSQL Lake v1
-- Schemas, control tables, bronze_amc_campaign_daily, ZANOM seed data

-- ─── Schemas ──────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS marketcloud_control;
CREATE SCHEMA IF NOT EXISTS marketcloud_bronze;
CREATE SCHEMA IF NOT EXISTS marketcloud_silver;
CREATE SCHEMA IF NOT EXISTS marketcloud_gold;
CREATE SCHEMA IF NOT EXISTS marketcloud_features;

-- ─── Control: AMC Instances ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS marketcloud_control.amc_instances (
    id                BIGSERIAL PRIMARY KEY,
    tenant_id         TEXT NOT NULL,
    advertiser_name   TEXT NOT NULL,
    amc_instance_id   TEXT NOT NULL,
    ads_profile_id    TEXT NOT NULL,
    marketplace_id    TEXT,
    marketplace_name  TEXT,
    aws_account_id    TEXT,
    status            TEXT NOT NULL DEFAULT 'active',
    created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMP NOT NULL DEFAULT NOW(),
    UNIQUE (tenant_id, amc_instance_id, ads_profile_id)
);

INSERT INTO marketcloud_control.amc_instances (
    tenant_id, advertiser_name, amc_instance_id, ads_profile_id,
    marketplace_name, aws_account_id, status
) VALUES (
    'zanom', 'ZANOM DIGITAL', 'amcoo5vzswt', '3084626225435227',
    'BR', '508859666731', 'active'
)
ON CONFLICT (tenant_id, amc_instance_id, ads_profile_id) DO UPDATE SET
    advertiser_name  = EXCLUDED.advertiser_name,
    marketplace_name = EXCLUDED.marketplace_name,
    aws_account_id   = EXCLUDED.aws_account_id,
    status           = EXCLUDED.status,
    updated_at       = NOW();

-- ─── Control: Extract Definitions ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS marketcloud_control.extract_definitions (
    id                    BIGSERIAL PRIMARY KEY,
    extract_code          TEXT NOT NULL UNIQUE,
    extract_name          TEXT NOT NULL,
    extract_family        TEXT NOT NULL,
    source_tables         TEXT[] NOT NULL,
    destination_schema    TEXT NOT NULL,
    destination_table     TEXT NOT NULL,
    schedule_type         TEXT NOT NULL,
    default_lookback_days INTEGER NOT NULL DEFAULT 35,
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMP NOT NULL DEFAULT NOW()
);

INSERT INTO marketcloud_control.extract_definitions (
    extract_code, extract_name, extract_family,
    source_tables, destination_schema, destination_table,
    schedule_type, default_lookback_days, is_active
) VALUES (
    'E001_CAMPAIGN_DAILY_EXTRACT',
    'Campaign Daily Performance Extract',
    'sponsored_ads',
    ARRAY['sponsored_ads_traffic','amazon_attributed_events_by_conversion_time'],
    'marketcloud_bronze',
    'bronze_amc_campaign_daily',
    'daily',
    35,
    TRUE
)
ON CONFLICT (extract_code) DO UPDATE SET
    extract_name          = EXCLUDED.extract_name,
    extract_family        = EXCLUDED.extract_family,
    source_tables         = EXCLUDED.source_tables,
    destination_schema    = EXCLUDED.destination_schema,
    destination_table     = EXCLUDED.destination_table,
    schedule_type         = EXCLUDED.schedule_type,
    default_lookback_days = EXCLUDED.default_lookback_days,
    is_active             = EXCLUDED.is_active,
    updated_at            = NOW();

-- ─── Control: Workflow Runs ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS marketcloud_control.workflow_runs (
    id                    BIGSERIAL PRIMARY KEY,
    tenant_id             TEXT NOT NULL,
    amc_instance_id       TEXT NOT NULL,
    ads_profile_id        TEXT NOT NULL,
    extract_code          TEXT NOT NULL,
    workflow_execution_id TEXT,
    workflow_status       TEXT NOT NULL,
    window_start          TIMESTAMP NOT NULL,
    window_end            TIMESTAMP NOT NULL,
    requested_at          TIMESTAMP NOT NULL DEFAULT NOW(),
    started_at            TIMESTAMP,
    completed_at          TIMESTAMP,
    s3_output_path        TEXT,
    row_count             INTEGER,
    checksum              TEXT,
    error_code            TEXT,
    error_message         TEXT,
    created_at            TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_workflow_runs_tenant_extract_window
    ON marketcloud_control.workflow_runs (tenant_id, extract_code, window_start, window_end);
CREATE INDEX IF NOT EXISTS idx_workflow_runs_status
    ON marketcloud_control.workflow_runs (workflow_status);
CREATE INDEX IF NOT EXISTS idx_workflow_runs_execution_id
    ON marketcloud_control.workflow_runs (workflow_execution_id);

-- ─── Bronze: bronze_amc_campaign_daily ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_campaign_daily (
    tenant_id         TEXT NOT NULL,
    amc_instance_id   TEXT NOT NULL,
    ads_profile_id    TEXT NOT NULL,
    workflow_run_id   BIGINT,
    data_date         DATE NOT NULL,
    campaign_id       TEXT NOT NULL,
    campaign_name     TEXT NOT NULL,
    ad_product_type   TEXT NOT NULL,
    marketplace_id    TEXT,
    marketplace_name  TEXT,
    currency_iso_code TEXT,
    purchase_currency TEXT,
    portfolio_id      TEXT,
    portfolio_name    TEXT,
    impressions         BIGINT       DEFAULT 0,
    clicks              BIGINT       DEFAULT 0,
    spend               NUMERIC(18,4) DEFAULT 0,
    viewable_impressions BIGINT      DEFAULT 0,
    five_sec_views      BIGINT       DEFAULT 0,
    orders              NUMERIC(18,4) DEFAULT 0,
    sales               NUMERIC(18,4) DEFAULT 0,
    units_sold          NUMERIC(18,4) DEFAULT 0,
    add_to_cart         NUMERIC(18,4) DEFAULT 0,
    detail_page_views   NUMERIC(18,4) DEFAULT 0,
    brand_halo_orders   NUMERIC(18,4) DEFAULT 0,
    brand_halo_sales    NUMERIC(18,4) DEFAULT 0,
    new_to_brand_orders NUMERIC(18,4) DEFAULT 0,
    new_to_brand_sales  NUMERIC(18,4) DEFAULT 0,
    purchases_clicks    NUMERIC(18,4) DEFAULT 0,
    purchases_views     NUMERIC(18,4) DEFAULT 0,
    product_sales_clicks NUMERIC(18,4) DEFAULT 0,
    product_sales_views  NUMERIC(18,4) DEFAULT 0,
    off_amazon_sales    NUMERIC(18,4) DEFAULT 0,
    combined_sales      NUMERIC(18,4) DEFAULT 0,
    ctr               NUMERIC(18,8),
    cpc               NUMERIC(18,4),
    roas              NUMERIC(18,4),
    total_roas        NUMERIC(18,4),
    conversion_rate   NUMERIC(18,8),
    loaded_at         TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, amc_instance_id, ads_profile_id, data_date, campaign_id, ad_product_type)
);

CREATE INDEX IF NOT EXISTS idx_bronze_campaign_daily_date
    ON marketcloud_bronze.bronze_amc_campaign_daily (tenant_id, data_date);
CREATE INDEX IF NOT EXISTS idx_bronze_campaign_daily_campaign
    ON marketcloud_bronze.bronze_amc_campaign_daily (tenant_id, campaign_id);
CREATE INDEX IF NOT EXISTS idx_bronze_campaign_daily_product_type
    ON marketcloud_bronze.bronze_amc_campaign_daily (tenant_id, ad_product_type, data_date);
