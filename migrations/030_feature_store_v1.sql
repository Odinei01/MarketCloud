-- =====================================================================
-- MarketCloud Feature Store V1
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS marketcloud_features;

-- =====================================================================
-- Tabela 1 — feature_hourly_campaign_adgroup
-- Fonte: silver_hourly_campaign_adgroup + gold_hourly_bid_schedule
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_features.feature_hourly_campaign_adgroup (
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

    sample_days     INTEGER DEFAULT 0,

    impressions_35d     NUMERIC(18,4) DEFAULT 0,
    clicks_35d          NUMERIC(18,4) DEFAULT 0,
    spend_35d           NUMERIC(18,4) DEFAULT 0,
    orders_35d          NUMERIC(18,4) DEFAULT 0,
    sales_35d           NUMERIC(18,4) DEFAULT 0,
    combined_sales_35d  NUMERIC(18,4) DEFAULT 0,

    ctr_35d             NUMERIC(18,8),
    cpc_35d             NUMERIC(18,4),
    roas_35d            NUMERIC(18,4),
    total_roas_35d      NUMERIC(18,4),
    acos_35d            NUMERIC(18,8),
    conversion_rate_35d NUMERIC(18,8),
    cpa_35d             NUMERIC(18,4),
    aov_35d             NUMERIC(18,4),

    has_spend   BOOLEAN DEFAULT FALSE,
    has_click   BOOLEAN DEFAULT FALSE,
    has_order   BOOLEAN DEFAULT FALSE,
    has_sale    BOOLEAN DEFAULT FALSE,

    is_madrugada BOOLEAN DEFAULT FALSE,
    is_manha     BOOLEAN DEFAULT FALSE,
    is_tarde     BOOLEAN DEFAULT FALSE,
    is_noite     BOOLEAN DEFAULT FALSE,

    gold_action_type     TEXT,
    gold_bid_multiplier  NUMERIC(18,4),
    gold_reason_code     TEXT,
    gold_risk_level      TEXT,
    gold_confidence_score NUMERIC(18,8),
    gold_evidence_json   JSONB,

    created_at TIMESTAMP NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_feature_hourly_campaign_adgroup UNIQUE (
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

CREATE INDEX IF NOT EXISTS idx_feature_hourly_campaign_adgroup_date
    ON marketcloud_features.feature_hourly_campaign_adgroup (tenant_id, feature_date);

CREATE INDEX IF NOT EXISTS idx_feature_hourly_campaign_adgroup_campaign
    ON marketcloud_features.feature_hourly_campaign_adgroup (tenant_id, campaign_id, event_hour);

CREATE INDEX IF NOT EXISTS idx_feature_hourly_campaign_adgroup_gold_action
    ON marketcloud_features.feature_hourly_campaign_adgroup (tenant_id, gold_action_type);


-- =====================================================================
-- Tabela 2 — feature_search_term_daily
-- Fonte: silver_search_term_daily + gold_negative_keyword_candidates
--        + gold_scale_candidates
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_features.feature_search_term_daily (
    feature_id      BIGSERIAL PRIMARY KEY,

    tenant_id       TEXT NOT NULL,
    amc_instance_id TEXT NOT NULL,
    ads_profile_id  TEXT NOT NULL,

    feature_date    DATE NOT NULL,
    generated_at    TIMESTAMP NOT NULL DEFAULT NOW(),

    campaign_id     TEXT NOT NULL,
    campaign_name   TEXT NOT NULL,
    ad_product_type TEXT NOT NULL,

    ad_group_name TEXT,
    targeting     TEXT,
    match_type    TEXT,

    customer_search_term  TEXT NOT NULL,
    search_term_normalized TEXT NOT NULL,

    term_length     INTEGER,
    term_word_count INTEGER,

    is_branded_zanom BOOLEAN DEFAULT FALSE,

    impressions_35d     NUMERIC(18,4) DEFAULT 0,
    clicks_35d          NUMERIC(18,4) DEFAULT 0,
    spend_35d           NUMERIC(18,4) DEFAULT 0,
    orders_35d          NUMERIC(18,4) DEFAULT 0,
    sales_35d           NUMERIC(18,4) DEFAULT 0,
    combined_sales_35d  NUMERIC(18,4) DEFAULT 0,

    ctr_35d             NUMERIC(18,8),
    cpc_35d             NUMERIC(18,4),
    roas_35d            NUMERIC(18,4),
    total_roas_35d      NUMERIC(18,4),
    acos_35d            NUMERIC(18,8),
    conversion_rate_35d NUMERIC(18,8),
    cpa_35d             NUMERIC(18,4),
    aov_35d             NUMERIC(18,4),

    gold_action_type      TEXT,
    gold_reason_code      TEXT,
    gold_risk_level       TEXT,
    gold_confidence_score NUMERIC(18,8),
    gold_evidence_json    JSONB,

    created_at TIMESTAMP NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_feature_search_term_daily UNIQUE (
        tenant_id,
        amc_instance_id,
        ads_profile_id,
        feature_date,
        campaign_id,
        ad_product_type,
        search_term_normalized
    )
);

CREATE INDEX IF NOT EXISTS idx_feature_search_term_daily_date
    ON marketcloud_features.feature_search_term_daily (tenant_id, feature_date);

CREATE INDEX IF NOT EXISTS idx_feature_search_term_daily_term
    ON marketcloud_features.feature_search_term_daily (tenant_id, search_term_normalized);

CREATE INDEX IF NOT EXISTS idx_feature_search_term_daily_gold_action
    ON marketcloud_features.feature_search_term_daily (tenant_id, gold_action_type);


-- =====================================================================
-- Tabela 3 — model_registry
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_features.model_registry (
    model_id      BIGSERIAL PRIMARY KEY,

    model_name    TEXT NOT NULL,
    model_version TEXT NOT NULL,

    model_type    TEXT NOT NULL,
    target_name   TEXT NOT NULL,

    training_window_start DATE,
    training_window_end   DATE,

    training_rows INTEGER DEFAULT 0,

    metrics_json         JSONB,
    feature_columns_json JSONB,

    artifact_path TEXT,

    status TEXT NOT NULL DEFAULT 'TRAINED',

    created_at TIMESTAMP NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_model_registry UNIQUE (model_name, model_version)
);


-- =====================================================================
-- Tabela 4 — model_predictions
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_features.model_predictions (
    prediction_id BIGSERIAL PRIMARY KEY,

    tenant_id       TEXT NOT NULL,
    amc_instance_id TEXT NOT NULL,
    ads_profile_id  TEXT NOT NULL,

    model_name    TEXT NOT NULL,
    model_version TEXT NOT NULL,

    prediction_date DATE NOT NULL,
    generated_at    TIMESTAMP NOT NULL DEFAULT NOW(),

    entity_type TEXT NOT NULL,
    entity_key  TEXT NOT NULL,

    campaign_id     TEXT,
    campaign_name   TEXT,
    ad_product_type TEXT,
    ad_group_name   TEXT,
    event_hour      INTEGER,
    customer_search_term TEXT,

    gold_action_type TEXT,

    predicted_action_type    TEXT,
    predicted_bid_multiplier NUMERIC(18,4),

    conversion_probability NUMERIC(18,8),
    expected_orders        NUMERIC(18,4),
    expected_sales         NUMERIC(18,4),
    expected_roas          NUMERIC(18,4),

    confidence_score      NUMERIC(18,8),
    prediction_risk_level TEXT,

    features_snapshot       JSONB,
    prediction_evidence_json JSONB,

    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_model_predictions_date
    ON marketcloud_features.model_predictions (tenant_id, prediction_date);

CREATE INDEX IF NOT EXISTS idx_model_predictions_model
    ON marketcloud_features.model_predictions (model_name, model_version);

CREATE INDEX IF NOT EXISTS idx_model_predictions_entity
    ON marketcloud_features.model_predictions (tenant_id, entity_type, entity_key);

CREATE INDEX IF NOT EXISTS idx_model_predictions_campaign
    ON marketcloud_features.model_predictions (tenant_id, campaign_id, prediction_date);
