-- =====================================================================
-- ZMC Robust ML V1 — Builder de features por janela
-- Popula marketcloud_features.feature_hourly_windows_v1 a partir de:
--   marketcloud_silver.silver_hourly_campaign_adgroup  (métricas por janela)
--   marketcloud_gold.gold_hourly_bid_schedule          (label Gold por entidade)
--
-- Janelas ancoradas em MAX(data_date) da Silver (não CURRENT_DATE), para não
-- abrir buraco quando não há carga nova. Idempotente (ON CONFLICT DO UPDATE).
-- =====================================================================

INSERT INTO marketcloud_features.feature_hourly_windows_v1 (
    tenant_id, amc_instance_id, ads_profile_id,
    feature_date, generated_at,
    campaign_id, campaign_name, ad_product_type, ad_group_name,
    event_hour, day_part,
    sample_days_1d, sample_days_3d, sample_days_7d, sample_days_14d, sample_days_35d,
    spend_1d, spend_3d, spend_7d, spend_14d, spend_35d,
    clicks_1d, clicks_3d, clicks_7d, clicks_14d, clicks_35d,
    impressions_1d, impressions_3d, impressions_7d, impressions_14d, impressions_35d,
    orders_1d, orders_3d, orders_7d, orders_14d, orders_35d,
    sales_1d, sales_3d, sales_7d, sales_14d, sales_35d,
    ctr_7d, cpc_7d, roas_7d, acos_7d, conversion_rate_7d, cpa_7d, aov_7d,
    ctr_35d, cpc_35d, roas_35d, acos_35d, conversion_rate_35d, cpa_35d, aov_35d,
    spend_delta_7d_vs_35d, clicks_delta_7d_vs_35d, orders_delta_7d_vs_35d,
    sales_delta_7d_vs_35d, roas_delta_7d_vs_35d, cpc_delta_7d_vs_35d,
    ctr_delta_7d_vs_35d, conversion_rate_delta_7d_vs_35d,
    has_spend_7d, has_click_7d, has_order_7d, has_sale_7d,
    is_madrugada, is_manha, is_tarde, is_noite,
    gold_action_type, gold_bid_multiplier, gold_risk_level,
    gold_confidence_score, gold_evidence_json
)
WITH bounds AS (
    SELECT MAX(data_date) AS max_date
    FROM marketcloud_silver.silver_hourly_campaign_adgroup
),
agg AS (
    SELECT
        s.tenant_id, s.amc_instance_id, s.ads_profile_id,
        s.campaign_id,
        MAX(s.campaign_name) AS campaign_name,
        s.ad_product_type, s.ad_group_name, s.event_hour,

        -- sample days por janela
        COUNT(DISTINCT s.data_date) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '1 day')   AS sample_days_1d,
        COUNT(DISTINCT s.data_date) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '3 days')  AS sample_days_3d,
        COUNT(DISTINCT s.data_date) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '7 days')  AS sample_days_7d,
        COUNT(DISTINCT s.data_date) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '14 days') AS sample_days_14d,
        COUNT(DISTINCT s.data_date) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '35 days') AS sample_days_35d,

        -- spend
        COALESCE(SUM(s.spend) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '1 day'),   0) AS spend_1d,
        COALESCE(SUM(s.spend) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '3 days'),  0) AS spend_3d,
        COALESCE(SUM(s.spend) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '7 days'),  0) AS spend_7d,
        COALESCE(SUM(s.spend) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '14 days'), 0) AS spend_14d,
        COALESCE(SUM(s.spend) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '35 days'), 0) AS spend_35d,

        -- clicks
        COALESCE(SUM(s.clicks) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '1 day'),   0) AS clicks_1d,
        COALESCE(SUM(s.clicks) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '3 days'),  0) AS clicks_3d,
        COALESCE(SUM(s.clicks) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '7 days'),  0) AS clicks_7d,
        COALESCE(SUM(s.clicks) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '14 days'), 0) AS clicks_14d,
        COALESCE(SUM(s.clicks) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '35 days'), 0) AS clicks_35d,

        -- impressions
        COALESCE(SUM(s.impressions) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '1 day'),   0) AS impressions_1d,
        COALESCE(SUM(s.impressions) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '3 days'),  0) AS impressions_3d,
        COALESCE(SUM(s.impressions) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '7 days'),  0) AS impressions_7d,
        COALESCE(SUM(s.impressions) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '14 days'), 0) AS impressions_14d,
        COALESCE(SUM(s.impressions) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '35 days'), 0) AS impressions_35d,

        -- orders
        COALESCE(SUM(s.orders) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '1 day'),   0) AS orders_1d,
        COALESCE(SUM(s.orders) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '3 days'),  0) AS orders_3d,
        COALESCE(SUM(s.orders) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '7 days'),  0) AS orders_7d,
        COALESCE(SUM(s.orders) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '14 days'), 0) AS orders_14d,
        COALESCE(SUM(s.orders) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '35 days'), 0) AS orders_35d,

        -- sales
        COALESCE(SUM(s.sales) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '1 day'),   0) AS sales_1d,
        COALESCE(SUM(s.sales) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '3 days'),  0) AS sales_3d,
        COALESCE(SUM(s.sales) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '7 days'),  0) AS sales_7d,
        COALESCE(SUM(s.sales) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '14 days'), 0) AS sales_14d,
        COALESCE(SUM(s.sales) FILTER (WHERE s.data_date >= b.max_date - INTERVAL '35 days'), 0) AS sales_35d
    FROM marketcloud_silver.silver_hourly_campaign_adgroup s
    CROSS JOIN bounds b
    WHERE s.data_date >= b.max_date - INTERVAL '35 days'
    GROUP BY s.tenant_id, s.amc_instance_id, s.ads_profile_id,
             s.campaign_id, s.ad_product_type, s.ad_group_name, s.event_hour
),
kpi AS (
    SELECT
        agg.*,
        -- KPIs 7d
        CASE WHEN impressions_7d > 0 THEN clicks_7d / impressions_7d ELSE 0 END AS ctr_7d,
        CASE WHEN clicks_7d      > 0 THEN spend_7d  / clicks_7d      ELSE 0 END AS cpc_7d,
        CASE WHEN spend_7d       > 0 THEN sales_7d  / spend_7d       ELSE 0 END AS roas_7d,
        CASE WHEN sales_7d       > 0 THEN spend_7d  / sales_7d       ELSE 0 END AS acos_7d,
        CASE WHEN clicks_7d      > 0 THEN orders_7d / clicks_7d      ELSE 0 END AS conversion_rate_7d,
        CASE WHEN orders_7d      > 0 THEN spend_7d  / orders_7d      ELSE 0 END AS cpa_7d,
        CASE WHEN orders_7d      > 0 THEN sales_7d  / orders_7d      ELSE 0 END AS aov_7d,
        -- KPIs 35d
        CASE WHEN impressions_35d > 0 THEN clicks_35d / impressions_35d ELSE 0 END AS ctr_35d,
        CASE WHEN clicks_35d      > 0 THEN spend_35d  / clicks_35d      ELSE 0 END AS cpc_35d,
        CASE WHEN spend_35d       > 0 THEN sales_35d  / spend_35d       ELSE 0 END AS roas_35d,
        CASE WHEN sales_35d       > 0 THEN spend_35d  / sales_35d       ELSE 0 END AS acos_35d,
        CASE WHEN clicks_35d      > 0 THEN orders_35d / clicks_35d      ELSE 0 END AS conversion_rate_35d,
        CASE WHEN orders_35d      > 0 THEN spend_35d  / orders_35d      ELSE 0 END AS cpa_35d,
        CASE WHEN orders_35d      > 0 THEN sales_35d  / orders_35d      ELSE 0 END AS aov_35d
    FROM agg
)
SELECT
    k.tenant_id, k.amc_instance_id, k.ads_profile_id,
    CURRENT_DATE, NOW(),
    k.campaign_id, k.campaign_name, k.ad_product_type, k.ad_group_name,
    k.event_hour,
    CASE
        WHEN k.event_hour BETWEEN 0 AND 5   THEN 'MADRUGADA'
        WHEN k.event_hour BETWEEN 6 AND 11  THEN 'MANHA'
        WHEN k.event_hour BETWEEN 12 AND 17 THEN 'TARDE'
        ELSE                                     'NOITE'
    END AS day_part,
    k.sample_days_1d, k.sample_days_3d, k.sample_days_7d, k.sample_days_14d, k.sample_days_35d,
    k.spend_1d, k.spend_3d, k.spend_7d, k.spend_14d, k.spend_35d,
    k.clicks_1d, k.clicks_3d, k.clicks_7d, k.clicks_14d, k.clicks_35d,
    k.impressions_1d, k.impressions_3d, k.impressions_7d, k.impressions_14d, k.impressions_35d,
    k.orders_1d, k.orders_3d, k.orders_7d, k.orders_14d, k.orders_35d,
    k.sales_1d, k.sales_3d, k.sales_7d, k.sales_14d, k.sales_35d,
    k.ctr_7d, k.cpc_7d, k.roas_7d, k.acos_7d, k.conversion_rate_7d, k.cpa_7d, k.aov_7d,
    k.ctr_35d, k.cpc_35d, k.roas_35d, k.acos_35d, k.conversion_rate_35d, k.cpa_35d, k.aov_35d,
    -- deltas absolutos 7d - 35d
    (k.spend_7d           - k.spend_35d),
    (k.clicks_7d          - k.clicks_35d),
    (k.orders_7d          - k.orders_35d),
    (k.sales_7d           - k.sales_35d),
    (k.roas_7d            - k.roas_35d),
    (k.cpc_7d             - k.cpc_35d),
    (k.ctr_7d             - k.ctr_35d),
    (k.conversion_rate_7d - k.conversion_rate_35d),
    -- binary signals (7d)
    (k.spend_7d  > 0), (k.clicks_7d > 0), (k.orders_7d > 0), (k.sales_7d > 0),
    -- day part flags
    (k.event_hour BETWEEN 0 AND 5),
    (k.event_hour BETWEEN 6 AND 11),
    (k.event_hour BETWEEN 12 AND 17),
    (k.event_hour BETWEEN 18 AND 23),
    -- Gold label (por entidade; view agrega todo o histórico)
    g.action_type, g.bid_multiplier, g.risk_level, g.confidence_score, g.evidence_json
FROM kpi k
LEFT JOIN marketcloud_gold.gold_hourly_bid_schedule g
    ON  g.tenant_id       = k.tenant_id
    AND g.amc_instance_id = k.amc_instance_id
    AND g.ads_profile_id  = k.ads_profile_id
    AND g.campaign_id     = k.campaign_id
    AND g.ad_product_type = k.ad_product_type
    AND g.ad_group_name   = k.ad_group_name
    AND g.event_hour      = k.event_hour
ON CONFLICT ON CONSTRAINT uq_feature_hourly_windows_v1
DO UPDATE SET
    generated_at        = NOW(),
    campaign_name       = EXCLUDED.campaign_name,
    day_part            = EXCLUDED.day_part,
    sample_days_1d = EXCLUDED.sample_days_1d, sample_days_3d = EXCLUDED.sample_days_3d,
    sample_days_7d = EXCLUDED.sample_days_7d, sample_days_14d = EXCLUDED.sample_days_14d,
    sample_days_35d = EXCLUDED.sample_days_35d,
    spend_1d = EXCLUDED.spend_1d, spend_3d = EXCLUDED.spend_3d, spend_7d = EXCLUDED.spend_7d,
    spend_14d = EXCLUDED.spend_14d, spend_35d = EXCLUDED.spend_35d,
    clicks_1d = EXCLUDED.clicks_1d, clicks_3d = EXCLUDED.clicks_3d, clicks_7d = EXCLUDED.clicks_7d,
    clicks_14d = EXCLUDED.clicks_14d, clicks_35d = EXCLUDED.clicks_35d,
    impressions_1d = EXCLUDED.impressions_1d, impressions_3d = EXCLUDED.impressions_3d,
    impressions_7d = EXCLUDED.impressions_7d, impressions_14d = EXCLUDED.impressions_14d,
    impressions_35d = EXCLUDED.impressions_35d,
    orders_1d = EXCLUDED.orders_1d, orders_3d = EXCLUDED.orders_3d, orders_7d = EXCLUDED.orders_7d,
    orders_14d = EXCLUDED.orders_14d, orders_35d = EXCLUDED.orders_35d,
    sales_1d = EXCLUDED.sales_1d, sales_3d = EXCLUDED.sales_3d, sales_7d = EXCLUDED.sales_7d,
    sales_14d = EXCLUDED.sales_14d, sales_35d = EXCLUDED.sales_35d,
    ctr_7d = EXCLUDED.ctr_7d, cpc_7d = EXCLUDED.cpc_7d, roas_7d = EXCLUDED.roas_7d,
    acos_7d = EXCLUDED.acos_7d, conversion_rate_7d = EXCLUDED.conversion_rate_7d,
    cpa_7d = EXCLUDED.cpa_7d, aov_7d = EXCLUDED.aov_7d,
    ctr_35d = EXCLUDED.ctr_35d, cpc_35d = EXCLUDED.cpc_35d, roas_35d = EXCLUDED.roas_35d,
    acos_35d = EXCLUDED.acos_35d, conversion_rate_35d = EXCLUDED.conversion_rate_35d,
    cpa_35d = EXCLUDED.cpa_35d, aov_35d = EXCLUDED.aov_35d,
    spend_delta_7d_vs_35d = EXCLUDED.spend_delta_7d_vs_35d,
    clicks_delta_7d_vs_35d = EXCLUDED.clicks_delta_7d_vs_35d,
    orders_delta_7d_vs_35d = EXCLUDED.orders_delta_7d_vs_35d,
    sales_delta_7d_vs_35d = EXCLUDED.sales_delta_7d_vs_35d,
    roas_delta_7d_vs_35d = EXCLUDED.roas_delta_7d_vs_35d,
    cpc_delta_7d_vs_35d = EXCLUDED.cpc_delta_7d_vs_35d,
    ctr_delta_7d_vs_35d = EXCLUDED.ctr_delta_7d_vs_35d,
    conversion_rate_delta_7d_vs_35d = EXCLUDED.conversion_rate_delta_7d_vs_35d,
    has_spend_7d = EXCLUDED.has_spend_7d, has_click_7d = EXCLUDED.has_click_7d,
    has_order_7d = EXCLUDED.has_order_7d, has_sale_7d = EXCLUDED.has_sale_7d,
    is_madrugada = EXCLUDED.is_madrugada, is_manha = EXCLUDED.is_manha,
    is_tarde = EXCLUDED.is_tarde, is_noite = EXCLUDED.is_noite,
    gold_action_type = EXCLUDED.gold_action_type,
    gold_bid_multiplier = EXCLUDED.gold_bid_multiplier,
    gold_risk_level = EXCLUDED.gold_risk_level,
    gold_confidence_score = EXCLUDED.gold_confidence_score,
    gold_evidence_json = EXCLUDED.gold_evidence_json;
