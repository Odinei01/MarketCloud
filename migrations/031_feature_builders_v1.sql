-- =====================================================================
-- MarketCloud Feature Builders V1
-- Popula feature_hourly_campaign_adgroup e feature_search_term_daily
-- a partir de Silver/Gold.
--
-- Idempotente: ON CONFLICT DO UPDATE — pode ser re-executado no mesmo dia.
-- feature_date = CURRENT_DATE (snapshot de hoje).
-- =====================================================================

-- =====================================================================
-- Builder 1 — feature_hourly_campaign_adgroup
-- Fonte: marketcloud_gold.gold_hourly_bid_schedule (G004)
-- G004 já agrega todo o histórico disponível por campanha/adgroup/hora.
-- =====================================================================

INSERT INTO marketcloud_features.feature_hourly_campaign_adgroup (
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    feature_date,
    generated_at,
    campaign_id,
    campaign_name,
    ad_product_type,
    ad_group_name,
    event_hour,
    day_part,
    sample_days,
    impressions_35d,
    clicks_35d,
    spend_35d,
    orders_35d,
    sales_35d,
    combined_sales_35d,
    ctr_35d,
    cpc_35d,
    roas_35d,
    total_roas_35d,
    acos_35d,
    conversion_rate_35d,
    cpa_35d,
    aov_35d,
    has_spend,
    has_click,
    has_order,
    has_sale,
    is_madrugada,
    is_manha,
    is_tarde,
    is_noite,
    gold_action_type,
    gold_bid_multiplier,
    gold_reason_code,
    gold_risk_level,
    gold_confidence_score,
    gold_evidence_json
)
SELECT
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    CURRENT_DATE                                AS feature_date,
    NOW()                                       AS generated_at,
    campaign_id,
    campaign_name,
    ad_product_type,
    ad_group_name,
    event_hour,
    day_part,
    sample_days,
    COALESCE(impressions,     0)                AS impressions_35d,
    COALESCE(clicks,          0)                AS clicks_35d,
    COALESCE(spend,           0)                AS spend_35d,
    COALESCE(orders,          0)                AS orders_35d,
    COALESCE(sales,           0)                AS sales_35d,
    COALESCE(combined_sales,  0)                AS combined_sales_35d,
    avg_ctr                                     AS ctr_35d,
    avg_cpc                                     AS cpc_35d,
    roas                                        AS roas_35d,
    total_roas                                  AS total_roas_35d,
    acos                                        AS acos_35d,
    conversion_rate                             AS conversion_rate_35d,
    cpa                                         AS cpa_35d,
    CASE WHEN COALESCE(orders, 0) > 0
         THEN sales / orders
         ELSE 0
    END                                         AS aov_35d,
    (COALESCE(spend,  0) > 0)                   AS has_spend,
    (COALESCE(clicks, 0) > 0)                   AS has_click,
    (COALESCE(orders, 0) > 0)                   AS has_order,
    (COALESCE(sales,  0) > 0)                   AS has_sale,
    (day_part = 'MADRUGADA')                    AS is_madrugada,
    (day_part = 'MANHA')                        AS is_manha,
    (day_part = 'TARDE')                        AS is_tarde,
    (day_part = 'NOITE')                        AS is_noite,
    action_type                                 AS gold_action_type,
    bid_multiplier                              AS gold_bid_multiplier,
    reason_code                                 AS gold_reason_code,
    risk_level                                  AS gold_risk_level,
    confidence_score                            AS gold_confidence_score,
    evidence_json                               AS gold_evidence_json
FROM marketcloud_gold.gold_hourly_bid_schedule
ON CONFLICT ON CONSTRAINT uq_feature_hourly_campaign_adgroup
DO UPDATE SET
    generated_at        = NOW(),
    campaign_name       = EXCLUDED.campaign_name,
    day_part            = EXCLUDED.day_part,
    sample_days         = EXCLUDED.sample_days,
    impressions_35d     = EXCLUDED.impressions_35d,
    clicks_35d          = EXCLUDED.clicks_35d,
    spend_35d           = EXCLUDED.spend_35d,
    orders_35d          = EXCLUDED.orders_35d,
    sales_35d           = EXCLUDED.sales_35d,
    combined_sales_35d  = EXCLUDED.combined_sales_35d,
    ctr_35d             = EXCLUDED.ctr_35d,
    cpc_35d             = EXCLUDED.cpc_35d,
    roas_35d            = EXCLUDED.roas_35d,
    total_roas_35d      = EXCLUDED.total_roas_35d,
    acos_35d            = EXCLUDED.acos_35d,
    conversion_rate_35d = EXCLUDED.conversion_rate_35d,
    cpa_35d             = EXCLUDED.cpa_35d,
    aov_35d             = EXCLUDED.aov_35d,
    has_spend           = EXCLUDED.has_spend,
    has_click           = EXCLUDED.has_click,
    has_order           = EXCLUDED.has_order,
    has_sale            = EXCLUDED.has_sale,
    is_madrugada        = EXCLUDED.is_madrugada,
    is_manha            = EXCLUDED.is_manha,
    is_tarde            = EXCLUDED.is_tarde,
    is_noite            = EXCLUDED.is_noite,
    gold_action_type      = EXCLUDED.gold_action_type,
    gold_bid_multiplier   = EXCLUDED.gold_bid_multiplier,
    gold_reason_code      = EXCLUDED.gold_reason_code,
    gold_risk_level       = EXCLUDED.gold_risk_level,
    gold_confidence_score = EXCLUDED.gold_confidence_score,
    gold_evidence_json    = EXCLUDED.gold_evidence_json;


-- =====================================================================
-- Builder 2 — feature_search_term_daily
-- Fonte: silver_search_term_daily (últimos 35 dias)
-- Join com gold_negative_keyword_candidates e gold_scale_candidates
-- Precedência: negativo > scale/harvest > WATCH
-- =====================================================================

WITH window_start AS (
    SELECT MAX(data_date) - INTERVAL '34 days' AS cutoff
    FROM marketcloud_silver.silver_search_term_daily
),
term_agg AS (
    SELECT
        s.tenant_id,
        s.amc_instance_id,
        s.ads_profile_id,
        s.campaign_id,
        MAX(s.campaign_name)        AS campaign_name,
        s.ad_product_type,
        MAX(s.ad_group_name)        AS ad_group_name,
        MAX(s.targeting)            AS targeting,
        MAX(s.match_type)           AS match_type,
        s.customer_search_term,
        LOWER(TRIM(s.customer_search_term)) AS search_term_normalized,
        SUM(s.impressions)          AS impressions_35d,
        SUM(s.clicks)               AS clicks_35d,
        SUM(s.spend)                AS spend_35d,
        SUM(s.orders)               AS orders_35d,
        SUM(s.sales)                AS sales_35d,
        SUM(s.combined_sales)       AS combined_sales_35d,
        CASE WHEN SUM(s.impressions) > 0
             THEN SUM(s.clicks)::NUMERIC / SUM(s.impressions) ELSE NULL END AS ctr_35d,
        CASE WHEN SUM(s.clicks) > 0
             THEN SUM(s.spend) / SUM(s.clicks) ELSE NULL END AS cpc_35d,
        CASE WHEN SUM(s.spend) > 0
             THEN SUM(s.sales) / SUM(s.spend) ELSE NULL END AS roas_35d,
        CASE WHEN SUM(s.spend) > 0
             THEN SUM(s.combined_sales) / SUM(s.spend) ELSE NULL END AS total_roas_35d,
        CASE WHEN SUM(s.sales) > 0
             THEN SUM(s.spend) / SUM(s.sales) ELSE NULL END AS acos_35d,
        CASE WHEN SUM(s.clicks) > 0
             THEN SUM(s.orders)::NUMERIC / SUM(s.clicks) ELSE NULL END AS conversion_rate_35d,
        CASE WHEN SUM(s.orders) > 0
             THEN SUM(s.spend) / SUM(s.orders) ELSE NULL END AS cpa_35d,
        CASE WHEN SUM(s.orders) > 0
             THEN SUM(s.sales) / SUM(s.orders) ELSE NULL END AS aov_35d
    FROM marketcloud_silver.silver_search_term_daily s
    CROSS JOIN window_start w
    WHERE s.data_date >= w.cutoff
    GROUP BY s.tenant_id, s.amc_instance_id, s.ads_profile_id,
             s.campaign_id, s.ad_product_type, s.customer_search_term
),
-- Melhor sinal de escala por termo (MOVE_TO_EXACT > HARVEST_SEARCH_TERM)
best_scale AS (
    SELECT DISTINCT ON (tenant_id, campaign_id, ad_product_type, customer_search_term)
        tenant_id, campaign_id, ad_product_type, customer_search_term,
        action_type, reason_code, risk_level, confidence_score, evidence_json
    FROM marketcloud_gold.gold_scale_candidates
    WHERE source_view = 'S003'
      AND action_type IN ('HARVEST_SEARCH_TERM', 'MOVE_TO_EXACT')
    ORDER BY tenant_id, campaign_id, ad_product_type, customer_search_term,
        CASE action_type WHEN 'MOVE_TO_EXACT' THEN 1 ELSE 2 END
)
INSERT INTO marketcloud_features.feature_search_term_daily (
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    feature_date,
    generated_at,
    campaign_id,
    campaign_name,
    ad_product_type,
    ad_group_name,
    targeting,
    match_type,
    customer_search_term,
    search_term_normalized,
    term_length,
    term_word_count,
    is_branded_zanom,
    impressions_35d,
    clicks_35d,
    spend_35d,
    orders_35d,
    sales_35d,
    combined_sales_35d,
    ctr_35d,
    cpc_35d,
    roas_35d,
    total_roas_35d,
    acos_35d,
    conversion_rate_35d,
    cpa_35d,
    aov_35d,
    gold_action_type,
    gold_reason_code,
    gold_risk_level,
    gold_confidence_score,
    gold_evidence_json
)
SELECT
    a.tenant_id,
    a.amc_instance_id,
    a.ads_profile_id,
    CURRENT_DATE                            AS feature_date,
    NOW()                                   AS generated_at,
    a.campaign_id,
    a.campaign_name,
    a.ad_product_type,
    a.ad_group_name,
    a.targeting,
    a.match_type,
    a.customer_search_term,
    a.search_term_normalized,
    LENGTH(a.search_term_normalized)        AS term_length,
    COALESCE(
        ARRAY_LENGTH(STRING_TO_ARRAY(TRIM(a.customer_search_term), ' '), 1),
        1
    )                                       AS term_word_count,
    (a.search_term_normalized LIKE '%zanom%') AS is_branded_zanom,
    COALESCE(a.impressions_35d,    0),
    COALESCE(a.clicks_35d,         0),
    COALESCE(a.spend_35d,          0),
    COALESCE(a.orders_35d,         0),
    COALESCE(a.sales_35d,          0),
    COALESCE(a.combined_sales_35d, 0),
    a.ctr_35d,
    a.cpc_35d,
    a.roas_35d,
    a.total_roas_35d,
    a.acos_35d,
    a.conversion_rate_35d,
    a.cpa_35d,
    a.aov_35d,
    -- Precedência: negativo > scale > WATCH
    COALESCE(gnk.action_type, bs.action_type, 'WATCH')           AS gold_action_type,
    COALESCE(gnk.reason_code, bs.reason_code, 'NO_SIGNAL')       AS gold_reason_code,
    COALESCE(gnk.risk_level,  bs.risk_level,  'LOW')             AS gold_risk_level,
    COALESCE(gnk.confidence_score, bs.confidence_score, 0.20)    AS gold_confidence_score,
    COALESCE(
        gnk.evidence_json,
        bs.evidence_json,
        '{"source":"no_gold_signal"}'::JSONB
    )                                                              AS gold_evidence_json
FROM term_agg a
LEFT JOIN marketcloud_gold.gold_negative_keyword_candidates gnk
    ON  gnk.tenant_id       = a.tenant_id
    AND gnk.campaign_id     = a.campaign_id
    AND gnk.ad_product_type = a.ad_product_type
    AND gnk.customer_search_term = a.customer_search_term
    AND gnk.action_type <> 'WATCH'
LEFT JOIN best_scale bs
    ON  bs.tenant_id        = a.tenant_id
    AND bs.campaign_id      = a.campaign_id
    AND bs.ad_product_type  = a.ad_product_type
    AND bs.customer_search_term = a.customer_search_term
ON CONFLICT ON CONSTRAINT uq_feature_search_term_daily
DO UPDATE SET
    generated_at        = NOW(),
    campaign_name       = EXCLUDED.campaign_name,
    ad_group_name       = EXCLUDED.ad_group_name,
    targeting           = EXCLUDED.targeting,
    match_type          = EXCLUDED.match_type,
    term_length         = EXCLUDED.term_length,
    term_word_count     = EXCLUDED.term_word_count,
    is_branded_zanom    = EXCLUDED.is_branded_zanom,
    impressions_35d     = EXCLUDED.impressions_35d,
    clicks_35d          = EXCLUDED.clicks_35d,
    spend_35d           = EXCLUDED.spend_35d,
    orders_35d          = EXCLUDED.orders_35d,
    sales_35d           = EXCLUDED.sales_35d,
    combined_sales_35d  = EXCLUDED.combined_sales_35d,
    ctr_35d             = EXCLUDED.ctr_35d,
    cpc_35d             = EXCLUDED.cpc_35d,
    roas_35d            = EXCLUDED.roas_35d,
    total_roas_35d      = EXCLUDED.total_roas_35d,
    acos_35d            = EXCLUDED.acos_35d,
    conversion_rate_35d = EXCLUDED.conversion_rate_35d,
    cpa_35d             = EXCLUDED.cpa_35d,
    aov_35d             = EXCLUDED.aov_35d,
    gold_action_type      = EXCLUDED.gold_action_type,
    gold_reason_code      = EXCLUDED.gold_reason_code,
    gold_risk_level       = EXCLUDED.gold_risk_level,
    gold_confidence_score = EXCLUDED.gold_confidence_score,
    gold_evidence_json    = EXCLUDED.gold_evidence_json;
