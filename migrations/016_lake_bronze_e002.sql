-- 016_lake_bronze_e002.sql
-- MarketCloud ZANOM — Bronze Target Daily

INSERT INTO marketcloud_control.extract_definitions (
    extract_code, extract_name, extract_family,
    source_tables, destination_schema, destination_table,
    schedule_type, default_lookback_days, is_active
) VALUES (
    'E002_TARGET_DAILY_EXTRACT',
    'Target Daily Performance Extract',
    'sponsored_ads',
    ARRAY['sponsored_ads_traffic','amazon_attributed_events_by_conversion_time'],
    'marketcloud_bronze',
    'bronze_amc_target_daily',
    'daily',
    35,
    TRUE
)
ON CONFLICT (extract_code) DO UPDATE SET
    extract_name          = EXCLUDED.extract_name,
    source_tables         = EXCLUDED.source_tables,
    destination_schema    = EXCLUDED.destination_schema,
    destination_table     = EXCLUDED.destination_table,
    schedule_type         = EXCLUDED.schedule_type,
    default_lookback_days = EXCLUDED.default_lookback_days,
    is_active             = EXCLUDED.is_active,
    updated_at            = NOW();

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_target_daily (
    tenant_id         TEXT NOT NULL,
    amc_instance_id   TEXT NOT NULL,
    ads_profile_id    TEXT NOT NULL,
    workflow_run_id   BIGINT,

    data_date         DATE NOT NULL,
    campaign_id       TEXT NOT NULL,
    campaign_name     TEXT NOT NULL,
    ad_product_type   TEXT NOT NULL,
    ad_group_name     TEXT,
    targeting         TEXT NOT NULL,
    match_type        TEXT NOT NULL,

    marketplace_name  TEXT,
    currency_iso_code TEXT,
    purchase_currency TEXT,
    portfolio_id      TEXT,
    portfolio_name    TEXT,

    activity_rows       BIGINT       DEFAULT 0,
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

    PRIMARY KEY (tenant_id, amc_instance_id, ads_profile_id, data_date, campaign_id, ad_product_type, targeting, match_type)
);

CREATE INDEX IF NOT EXISTS idx_bronze_target_daily_date
    ON marketcloud_bronze.bronze_amc_target_daily (tenant_id, data_date);
CREATE INDEX IF NOT EXISTS idx_bronze_target_daily_campaign
    ON marketcloud_bronze.bronze_amc_target_daily (tenant_id, campaign_id);
CREATE INDEX IF NOT EXISTS idx_bronze_target_daily_targeting
    ON marketcloud_bronze.bronze_amc_target_daily (tenant_id, targeting, data_date);
