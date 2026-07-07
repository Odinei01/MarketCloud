-- =====================================================================
-- ZMC Robust ML V1 — Feature Store por múltiplas janelas
--   feature_hourly_windows_v1 : features 1d/3d/7d/14d/35d + tendência
--   training_datasets         : datasets de treino versionados
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS marketcloud_features;

CREATE TABLE IF NOT EXISTS marketcloud_features.feature_hourly_windows_v1 (
    feature_id      BIGSERIAL PRIMARY KEY,

    tenant_id       TEXT NOT NULL,
    amc_instance_id TEXT NOT NULL,
    ads_profile_id  TEXT NOT NULL,

    feature_date    DATE NOT NULL,
    generated_at    TIMESTAMP NOT NULL DEFAULT NOW(),

    campaign_id     TEXT NOT NULL,
    campaign_name   TEXT NOT NULL,
    ad_product_type TEXT NOT NULL,
    ad_group_name   TEXT NOT NULL,

    event_hour      INTEGER NOT NULL,
    day_part        TEXT,

    -- sample
    sample_days_1d  INTEGER DEFAULT 0,
    sample_days_3d  INTEGER DEFAULT 0,
    sample_days_7d  INTEGER DEFAULT 0,
    sample_days_14d INTEGER DEFAULT 0,
    sample_days_35d INTEGER DEFAULT 0,

    -- spend
    spend_1d  NUMERIC(18,4) DEFAULT 0,
    spend_3d  NUMERIC(18,4) DEFAULT 0,
    spend_7d  NUMERIC(18,4) DEFAULT 0,
    spend_14d NUMERIC(18,4) DEFAULT 0,
    spend_35d NUMERIC(18,4) DEFAULT 0,

    -- clicks
    clicks_1d  NUMERIC(18,4) DEFAULT 0,
    clicks_3d  NUMERIC(18,4) DEFAULT 0,
    clicks_7d  NUMERIC(18,4) DEFAULT 0,
    clicks_14d NUMERIC(18,4) DEFAULT 0,
    clicks_35d NUMERIC(18,4) DEFAULT 0,

    -- impressions
    impressions_1d  NUMERIC(18,4) DEFAULT 0,
    impressions_3d  NUMERIC(18,4) DEFAULT 0,
    impressions_7d  NUMERIC(18,4) DEFAULT 0,
    impressions_14d NUMERIC(18,4) DEFAULT 0,
    impressions_35d NUMERIC(18,4) DEFAULT 0,

    -- orders
    orders_1d  NUMERIC(18,4) DEFAULT 0,
    orders_3d  NUMERIC(18,4) DEFAULT 0,
    orders_7d  NUMERIC(18,4) DEFAULT 0,
    orders_14d NUMERIC(18,4) DEFAULT 0,
    orders_35d NUMERIC(18,4) DEFAULT 0,

    -- sales
    sales_1d  NUMERIC(18,4) DEFAULT 0,
    sales_3d  NUMERIC(18,4) DEFAULT 0,
    sales_7d  NUMERIC(18,4) DEFAULT 0,
    sales_14d NUMERIC(18,4) DEFAULT 0,
    sales_35d NUMERIC(18,4) DEFAULT 0,

    -- KPIs 7d
    ctr_7d             NUMERIC(18,8),
    cpc_7d             NUMERIC(18,4),
    roas_7d            NUMERIC(18,4),
    acos_7d            NUMERIC(18,8),
    conversion_rate_7d NUMERIC(18,8),
    cpa_7d             NUMERIC(18,4),
    aov_7d             NUMERIC(18,4),

    -- KPIs 35d
    ctr_35d             NUMERIC(18,8),
    cpc_35d             NUMERIC(18,4),
    roas_35d            NUMERIC(18,4),
    acos_35d            NUMERIC(18,8),
    conversion_rate_35d NUMERIC(18,8),
    cpa_35d             NUMERIC(18,4),
    aov_35d             NUMERIC(18,4),

    -- trend features (delta absoluto 7d - 35d)
    spend_delta_7d_vs_35d           NUMERIC(18,8),
    clicks_delta_7d_vs_35d          NUMERIC(18,8),
    orders_delta_7d_vs_35d          NUMERIC(18,8),
    sales_delta_7d_vs_35d           NUMERIC(18,8),
    roas_delta_7d_vs_35d            NUMERIC(18,8),
    cpc_delta_7d_vs_35d             NUMERIC(18,8),
    ctr_delta_7d_vs_35d             NUMERIC(18,8),
    conversion_rate_delta_7d_vs_35d NUMERIC(18,8),

    -- binary signals
    has_spend_7d BOOLEAN DEFAULT FALSE,
    has_click_7d BOOLEAN DEFAULT FALSE,
    has_order_7d BOOLEAN DEFAULT FALSE,
    has_sale_7d  BOOLEAN DEFAULT FALSE,

    is_madrugada BOOLEAN DEFAULT FALSE,
    is_manha     BOOLEAN DEFAULT FALSE,
    is_tarde     BOOLEAN DEFAULT FALSE,
    is_noite     BOOLEAN DEFAULT FALSE,

    -- Gold label
    gold_action_type      TEXT,
    gold_bid_multiplier   NUMERIC(18,4),
    gold_risk_level       TEXT,
    gold_confidence_score NUMERIC(18,8),
    gold_evidence_json    JSONB,

    created_at TIMESTAMP NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_feature_hourly_windows_v1 UNIQUE (
        tenant_id,
        amc_instance_id,
        ads_profile_id,
        feature_date,
        campaign_id,
        ad_product_type,
        ad_group_name,
        event_hour
    )
);

CREATE INDEX IF NOT EXISTS idx_feature_hourly_windows_v1_date
    ON marketcloud_features.feature_hourly_windows_v1 (tenant_id, feature_date);

CREATE INDEX IF NOT EXISTS idx_feature_hourly_windows_v1_entity
    ON marketcloud_features.feature_hourly_windows_v1 (
        tenant_id, campaign_id, ad_product_type, ad_group_name, event_hour);

CREATE INDEX IF NOT EXISTS idx_feature_hourly_windows_v1_action
    ON marketcloud_features.feature_hourly_windows_v1 (tenant_id, gold_action_type);


-- =====================================================================
-- training_datasets — datasets de treino versionados
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_features.training_datasets (
    dataset_id      BIGSERIAL PRIMARY KEY,

    dataset_name    TEXT NOT NULL,
    dataset_version TEXT NOT NULL,

    entity_type     TEXT NOT NULL,
    target_name     TEXT NOT NULL,

    source_table    TEXT NOT NULL,

    row_count       INTEGER DEFAULT 0,
    class_distribution_json JSONB,
    feature_columns_json    JSONB,

    train_start_date DATE,
    train_end_date   DATE,

    created_at TIMESTAMP NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_training_datasets UNIQUE (dataset_name, dataset_version)
);
