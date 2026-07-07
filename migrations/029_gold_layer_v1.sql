-- =====================================================================
-- MarketCloud AMC Gold Layer V1
-- ZANOM / Amazon Marketing Cloud
--
-- Conteúdo:
--   G001 gold_campaign_health           (fonte: S001)
--   G004 gold_hourly_bid_schedule       (fonte: S004) — prioridade máxima
--   G005 gold_negative_keyword_candidates (fonte: S003)
--   G006 gold_scale_candidates          (fontes: S001 + S002 + S003)
--   G007 gold_cut_candidates            (fontes: S001 + S002 + S003)
--
-- Regras obrigatórias:
--   - Apenas views (CREATE OR REPLACE VIEW)
--   - Nenhuma alteração automática de campanha
--   - Nenhuma chamada a API externa
--   - Toda recomendação tem action_type + reason_code + evidence_json
--   - Divisão por zero: CASE WHEN denominador > 0 THEN ... ELSE 0 END
--   - Sem marketplace_id / marketplace_name
--   - Negativos nunca incluem termos com 'zanom'
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS marketcloud_gold;

-- =====================================================================
-- G001 — gold_campaign_health
-- Fonte: marketcloud_silver.silver_campaign_daily
-- Janela: últimos 35 dias disponíveis
-- Grão: tenant_id / amc_instance_id / ads_profile_id
--       / campaign_id / ad_product_type
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.gold_campaign_health AS
WITH agg AS (
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        campaign_id,
        MAX(campaign_name)        AS campaign_name,
        ad_product_type,
        MIN(data_date)            AS first_data_date,
        MAX(data_date)            AS last_data_date,
        COUNT(DISTINCT data_date) AS active_days,
        SUM(impressions)          AS impressions,
        SUM(clicks)               AS clicks,
        SUM(spend)                AS spend,
        SUM(orders)               AS orders,
        SUM(sales)                AS sales,
        SUM(combined_sales)       AS combined_sales,
        CASE WHEN SUM(impressions) > 0
             THEN SUM(clicks)::NUMERIC / SUM(impressions)       ELSE 0 END AS ctr,
        CASE WHEN SUM(clicks) > 0
             THEN SUM(spend) / SUM(clicks)                      ELSE 0 END AS cpc,
        CASE WHEN SUM(spend) > 0
             THEN SUM(sales) / SUM(spend)                       ELSE 0 END AS roas,
        CASE WHEN SUM(spend) > 0
             THEN SUM(combined_sales) / SUM(spend)              ELSE 0 END AS total_roas,
        CASE WHEN SUM(sales) > 0
             THEN SUM(spend) / SUM(sales)                       ELSE 0 END AS acos,
        CASE WHEN SUM(clicks) > 0
             THEN SUM(orders)::NUMERIC / SUM(clicks)            ELSE 0 END AS conversion_rate,
        CASE WHEN SUM(orders) > 0
             THEN SUM(spend) / SUM(orders)                      ELSE 0 END AS cpa,
        CASE WHEN SUM(orders) > 0
             THEN SUM(sales) / SUM(orders)                      ELSE 0 END AS aov
    FROM marketcloud_silver.silver_campaign_daily
    WHERE data_date >= (
        SELECT MAX(data_date) - INTERVAL '34 days'
        FROM marketcloud_silver.silver_campaign_daily
    )
    GROUP BY tenant_id, amc_instance_id, ads_profile_id, campaign_id, ad_product_type
)
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    campaign_id, campaign_name, ad_product_type,
    first_data_date, last_data_date, active_days,
    impressions, clicks, spend, orders, sales, combined_sales,
    ctr, cpc, roas, total_roas, acos, conversion_rate, cpa, aov,
    CASE
        WHEN spend = 0                      THEN 'NO_SPEND'
        WHEN spend > 0 AND sales = 0        THEN 'SPEND_NO_SALE'
        WHEN roas < 3                       THEN 'LOW_ROAS'
        WHEN roas >= 3 AND roas < 7         THEN 'GOOD_ROAS'
        WHEN roas >= 7                      THEN 'STRONG_ROAS'
        ELSE                                     'WATCH'
    END AS health_bucket,
    CASE
        WHEN (spend > 0 AND sales = 0) OR (roas > 0 AND roas < 3) THEN 'HIGH'
        WHEN roas >= 7 AND orders >= 2                              THEN 'LOW'
        ELSE                                                             'MEDIUM'
    END AS risk_level,
    NOW() AS created_at
FROM agg;


-- =====================================================================
-- G004 — gold_hourly_bid_schedule
-- Fonte: marketcloud_silver.silver_hourly_campaign_adgroup (todo histórico)
-- Grão: tenant_id / amc_instance_id / ads_profile_id
--       / campaign_id / ad_product_type / ad_group_name / event_hour
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.gold_hourly_bid_schedule AS
WITH hourly_agg AS (
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        campaign_id,
        MAX(campaign_name)        AS campaign_name,
        ad_product_type,
        ad_group_name,
        event_hour,
        MAX(day_part)             AS day_part,
        COUNT(DISTINCT data_date) AS sample_days,
        SUM(impressions)          AS impressions,
        SUM(clicks)               AS clicks,
        SUM(spend)                AS spend,
        SUM(orders)               AS orders,
        SUM(sales)                AS sales,
        SUM(combined_sales)       AS combined_sales,
        CASE WHEN SUM(impressions) > 0
             THEN SUM(clicks)::NUMERIC / SUM(impressions)        ELSE 0 END AS avg_ctr,
        CASE WHEN SUM(clicks) > 0
             THEN SUM(spend) / SUM(clicks)                       ELSE 0 END AS avg_cpc,
        CASE WHEN SUM(spend) > 0
             THEN SUM(sales) / SUM(spend)                        ELSE 0 END AS roas,
        CASE WHEN SUM(spend) > 0
             THEN SUM(combined_sales) / SUM(spend)               ELSE 0 END AS total_roas,
        CASE WHEN SUM(sales) > 0
             THEN SUM(spend) / SUM(sales)                        ELSE 0 END AS acos,
        CASE WHEN SUM(clicks) > 0
             THEN SUM(orders)::NUMERIC / SUM(clicks)             ELSE 0 END AS conversion_rate,
        CASE WHEN SUM(orders) > 0
             THEN SUM(spend) / SUM(orders)                       ELSE 0 END AS cpa
    FROM marketcloud_silver.silver_hourly_campaign_adgroup
    GROUP BY tenant_id, amc_instance_id, ads_profile_id,
             campaign_id, ad_product_type, ad_group_name, event_hour
),
hourly_scored AS (
    SELECT
        *,
        CASE
            WHEN clicks >= 5 AND spend > 0 AND sales = 0 THEN 'CUT_HOUR'
            WHEN spend > 0 AND sales > 0 AND roas < 3     THEN 'BID_DOWN'
            WHEN roas >= 7 AND orders >= 1                 THEN 'BID_UP'
            WHEN roas >= 3 AND roas < 7                    THEN 'HOLD'
            ELSE                                                'WATCH'
        END AS action_type,
        CASE
            WHEN clicks >= 5 AND spend > 0 AND sales = 0 THEN 0.50
            WHEN spend > 0 AND sales > 0 AND roas < 3     THEN 0.75
            WHEN roas >= 7 AND orders >= 1                 THEN 1.20
            ELSE                                                1.00
        END AS bid_multiplier,
        CASE
            WHEN clicks >= 5 AND spend > 0 AND sales = 0 THEN 'CLICKS_NO_CONVERSION'
            WHEN spend > 0 AND sales > 0 AND roas < 3     THEN 'BELOW_TARGET_ROAS'
            WHEN roas >= 7 AND orders >= 1                 THEN 'STRONG_ROAS_OPPORTUNITY'
            WHEN roas >= 3 AND roas < 7                    THEN 'ACCEPTABLE_ROAS'
            ELSE                                                'INSUFFICIENT_DATA'
        END AS reason_code,
        CASE
            WHEN clicks >= 10 OR orders >= 2  THEN 0.80
            WHEN clicks >= 5  OR orders >= 1  THEN 0.50
            ELSE                                   0.20
        END AS confidence_score,
        ROUND(CASE
            WHEN spend = 0                           THEN 0
            WHEN sales = 0 AND clicks >= 5           THEN GREATEST(0, 2.0 - clicks::NUMERIC / 5.0)
            WHEN roas >= 7                           THEN LEAST(10, roas)
            WHEN roas >= 3                           THEN roas * 0.8
            ELSE                                          roas * 0.5
        END::NUMERIC, 2) AS hour_score
    FROM hourly_agg
)
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    campaign_id, campaign_name, ad_product_type, ad_group_name,
    event_hour, day_part, sample_days,
    impressions, clicks, spend, orders, sales, combined_sales,
    avg_ctr, avg_cpc, roas, total_roas, acos, conversion_rate, cpa,
    hour_score,
    action_type,
    bid_multiplier,
    reason_code,
    CASE
        WHEN action_type IN ('CUT_HOUR', 'BID_DOWN') AND spend > 5 THEN 'HIGH'
        WHEN action_type = 'BID_UP' AND roas >= 7 AND orders >= 1  THEN 'LOW'
        ELSE                                                             'MEDIUM'
    END AS risk_level,
    confidence_score,
    jsonb_build_object(
        'window',           'available_s004_history',
        'sample_days',      sample_days,
        'impressions',      impressions,
        'clicks',           clicks,
        'spend',            ROUND(spend::NUMERIC, 4),
        'orders',           orders,
        'sales',            ROUND(sales::NUMERIC, 4),
        'roas',             ROUND(roas::NUMERIC, 4),
        'cpc',              ROUND(avg_cpc::NUMERIC, 4),
        'conversion_rate',  ROUND(conversion_rate::NUMERIC, 6),
        'rule',             reason_code
    ) AS evidence_json,
    NOW() AS created_at
FROM hourly_scored;


-- =====================================================================
-- G005 — gold_negative_keyword_candidates
-- Fonte: marketcloud_silver.silver_search_term_daily (todo histórico)
-- Grão: tenant_id / amc_instance_id / ads_profile_id
--       / campaign_id / ad_product_type / customer_search_term
-- Regra de segurança: nunca negativar termo contendo 'zanom'
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.gold_negative_keyword_candidates AS
WITH term_agg AS (
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        campaign_id,
        MAX(campaign_name) AS campaign_name,
        ad_product_type,
        customer_search_term,
        LOWER(TRIM(customer_search_term)) AS search_term_normalized,
        SUM(impressions)  AS impressions,
        SUM(clicks)       AS clicks,
        SUM(spend)        AS spend,
        SUM(orders)       AS orders,
        SUM(sales)        AS sales,
        SUM(combined_sales) AS combined_sales,
        CASE WHEN SUM(spend) > 0  THEN SUM(sales) / SUM(spend)  ELSE 0 END AS roas,
        CASE WHEN SUM(clicks) > 0 THEN SUM(spend) / SUM(clicks) ELSE 0 END AS cpc
    FROM marketcloud_silver.silver_search_term_daily
    GROUP BY tenant_id, amc_instance_id, ads_profile_id,
             campaign_id, ad_product_type, customer_search_term
),
candidates AS (
    SELECT *,
        -- action_type: zanom nunca é negativado
        CASE
            WHEN LOWER(customer_search_term) LIKE '%zanom%'        THEN 'WATCH'
            WHEN clicks >= 8 AND sales = 0                          THEN 'ADD_NEGATIVE_PHRASE'
            WHEN clicks >= 5 AND sales = 0                          THEN 'ADD_NEGATIVE_EXACT'
            ELSE                                                          'WATCH'
        END AS action_type,
        CASE
            WHEN LOWER(customer_search_term) NOT LIKE '%zanom%'
             AND clicks >= 8 AND sales = 0                          THEN 'PHRASE'
            WHEN LOWER(customer_search_term) NOT LIKE '%zanom%'
             AND clicks >= 5 AND sales = 0                          THEN 'EXACT'
            ELSE                                                          'NONE'
        END AS suggested_match_type,
        CASE
            WHEN LOWER(customer_search_term) LIKE '%zanom%'        THEN 'PROTECTED_BRAND_TERM'
            WHEN clicks >= 8 AND sales = 0                          THEN 'HIGH_CLICKS_NO_SALE'
            WHEN clicks >= 5 AND sales = 0                          THEN 'CLICKS_NO_SALE'
            ELSE                                                          'INSUFFICIENT_DATA'
        END AS reason_code,
        CASE
            WHEN clicks >= 10 THEN 0.80
            WHEN clicks >= 5  THEN 0.50
            ELSE                   0.20
        END AS confidence_score
    FROM term_agg
    WHERE clicks > 0 OR spend > 0
)
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    campaign_id, campaign_name, ad_product_type,
    customer_search_term, search_term_normalized,
    impressions, clicks, spend, orders, sales, combined_sales,
    roas, cpc,
    action_type,
    reason_code,
    suggested_match_type,
    CASE
        WHEN action_type IN ('ADD_NEGATIVE_EXACT', 'ADD_NEGATIVE_PHRASE') THEN 'HIGH'
        ELSE                                                                    'LOW'
    END AS risk_level,
    confidence_score,
    jsonb_build_object(
        'window',        'available_s003_history',
        'clicks',        clicks,
        'spend',         ROUND(spend::NUMERIC, 4),
        'sales',         sales,
        'orders',        orders,
        'roas',          ROUND(roas::NUMERIC, 4),
        'contains_brand', (LOWER(customer_search_term) LIKE '%zanom%'),
        'rule',          reason_code
    ) AS evidence_json,
    NOW() AS created_at
FROM candidates;


-- =====================================================================
-- G006 — gold_scale_candidates
-- Fontes: S001 (campanha) + S002 (target) + S003 (search term)
-- Action types: SCALE_CAMPAIGN / INCREASE_BID / HARVEST_SEARCH_TERM
--               / MOVE_TO_EXACT / WATCH
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.gold_scale_candidates AS
WITH campaign_agg AS (
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        campaign_id, MAX(campaign_name) AS campaign_name, ad_product_type,
        NULL::TEXT AS ad_group_name,
        NULL::TEXT AS targeting,
        NULL::TEXT AS match_type,
        NULL::TEXT AS customer_search_term,
        SUM(impressions) AS impressions, SUM(clicks) AS clicks,
        SUM(spend) AS spend, SUM(orders) AS orders,
        SUM(sales) AS sales, SUM(combined_sales) AS combined_sales,
        CASE WHEN SUM(spend) > 0  THEN SUM(sales) / SUM(spend)  ELSE 0 END AS roas,
        CASE WHEN SUM(clicks) > 0 THEN SUM(spend) / SUM(clicks) ELSE 0 END AS cpc,
        CASE WHEN SUM(sales) > 0  THEN SUM(spend) / SUM(sales)  ELSE 0 END AS acos
    FROM marketcloud_silver.silver_campaign_daily
    GROUP BY tenant_id, amc_instance_id, ads_profile_id, campaign_id, ad_product_type
),
target_agg AS (
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        campaign_id, MAX(campaign_name) AS campaign_name, ad_product_type,
        ad_group_name, targeting, match_type,
        NULL::TEXT AS customer_search_term,
        SUM(impressions) AS impressions, SUM(clicks) AS clicks,
        SUM(spend) AS spend, SUM(orders) AS orders,
        SUM(sales) AS sales, SUM(combined_sales) AS combined_sales,
        CASE WHEN SUM(spend) > 0  THEN SUM(sales) / SUM(spend)  ELSE 0 END AS roas,
        CASE WHEN SUM(clicks) > 0 THEN SUM(spend) / SUM(clicks) ELSE 0 END AS cpc,
        CASE WHEN SUM(sales) > 0  THEN SUM(spend) / SUM(sales)  ELSE 0 END AS acos
    FROM marketcloud_silver.silver_target_daily
    GROUP BY tenant_id, amc_instance_id, ads_profile_id,
             campaign_id, ad_product_type, ad_group_name, targeting, match_type
),
term_agg AS (
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        campaign_id, MAX(campaign_name) AS campaign_name, ad_product_type,
        ad_group_name, targeting, match_type, customer_search_term,
        SUM(impressions) AS impressions, SUM(clicks) AS clicks,
        SUM(spend) AS spend, SUM(orders) AS orders,
        SUM(sales) AS sales, SUM(combined_sales) AS combined_sales,
        CASE WHEN SUM(spend) > 0  THEN SUM(sales) / SUM(spend)  ELSE 0 END AS roas,
        CASE WHEN SUM(clicks) > 0 THEN SUM(spend) / SUM(clicks) ELSE 0 END AS cpc,
        CASE WHEN SUM(sales) > 0  THEN SUM(spend) / SUM(sales)  ELSE 0 END AS acos
    FROM marketcloud_silver.silver_search_term_daily
    GROUP BY tenant_id, amc_instance_id, ads_profile_id,
             campaign_id, ad_product_type, ad_group_name, targeting, match_type,
             customer_search_term
)
-- SCALE_CAMPAIGN: campanha com ROAS forte e pedidos
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    'S001'::TEXT AS source_view,
    campaign_id, campaign_name, ad_product_type,
    ad_group_name, targeting, match_type, customer_search_term,
    impressions, clicks, spend, orders, sales, combined_sales,
    roas, cpc, acos,
    'SCALE_CAMPAIGN'::TEXT AS action_type,
    'HIGH_ROAS_HIGH_ORDERS'::TEXT AS reason_code,
    CASE WHEN orders >= 5 THEN 0.80 WHEN orders >= 2 THEN 0.50 ELSE 0.30 END AS confidence_score,
    'LOW'::TEXT AS risk_level,
    jsonb_build_object('window','all_s001','spend',ROUND(spend::NUMERIC,4),'roas',ROUND(roas::NUMERIC,4),'orders',orders,'rule','SCALE_CAMPAIGN') AS evidence_json,
    NOW() AS created_at
FROM campaign_agg
WHERE roas >= 7 AND orders >= 2 AND spend > 0

UNION ALL

-- INCREASE_BID: target com ROAS forte
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    'S002'::TEXT,
    campaign_id, campaign_name, ad_product_type,
    ad_group_name, targeting, match_type, customer_search_term,
    impressions, clicks, spend, orders, sales, combined_sales,
    roas, cpc, acos,
    'INCREASE_BID'::TEXT,
    'HIGH_ROAS_TARGET'::TEXT,
    CASE WHEN orders >= 2 THEN 0.80 WHEN orders >= 1 THEN 0.50 ELSE 0.30 END,
    'LOW'::TEXT,
    jsonb_build_object('window','all_s002','spend',ROUND(spend::NUMERIC,4),'roas',ROUND(roas::NUMERIC,4),'orders',orders,'targeting',targeting,'rule','INCREASE_BID'),
    NOW()
FROM target_agg
WHERE roas >= 7 AND orders >= 1

UNION ALL

-- HARVEST_SEARCH_TERM: termo com venda, fora de EXACT
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    'S003'::TEXT,
    campaign_id, campaign_name, ad_product_type,
    ad_group_name, targeting, match_type, customer_search_term,
    impressions, clicks, spend, orders, sales, combined_sales,
    roas, cpc, acos,
    'HARVEST_SEARCH_TERM'::TEXT,
    'CONVERTING_TERM_NOT_EXACT'::TEXT,
    CASE WHEN orders >= 2 THEN 0.80 WHEN orders >= 1 THEN 0.50 ELSE 0.20 END,
    'LOW'::TEXT,
    jsonb_build_object('window','all_s003','clicks',clicks,'orders',orders,'sales',ROUND(sales::NUMERIC,4),'match_type',match_type,'rule','HARVEST_SEARCH_TERM'),
    NOW()
FROM term_agg
WHERE sales > 0 AND orders >= 1 AND match_type <> 'EXACT'

UNION ALL

-- MOVE_TO_EXACT: termo com conversão e ROAS suficiente
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    'S003'::TEXT,
    campaign_id, campaign_name, ad_product_type,
    ad_group_name, targeting, match_type, customer_search_term,
    impressions, clicks, spend, orders, sales, combined_sales,
    roas, cpc, acos,
    'MOVE_TO_EXACT'::TEXT,
    'CONVERTING_TERM_FOR_EXACT_MATCH'::TEXT,
    CASE WHEN orders >= 2 THEN 0.80 WHEN orders >= 1 THEN 0.60 ELSE 0.20 END,
    'LOW'::TEXT,
    jsonb_build_object('window','all_s003','clicks',clicks,'orders',orders,'roas',ROUND(roas::NUMERIC,4),'match_type',match_type,'rule','MOVE_TO_EXACT'),
    NOW()
FROM term_agg
WHERE orders >= 1 AND roas >= 5 AND match_type <> 'EXACT';


-- =====================================================================
-- G007 — gold_cut_candidates
-- Fontes: S001 (campanha) + S002 (target) + S003 (search term)
-- Action types: REDUCE_BID / PAUSE_TARGET / CUT_CAMPAIGN_BUDGET / WATCH
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.gold_cut_candidates AS
WITH campaign_agg AS (
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        campaign_id, MAX(campaign_name) AS campaign_name, ad_product_type,
        NULL::TEXT AS ad_group_name,
        NULL::TEXT AS targeting,
        NULL::TEXT AS match_type,
        NULL::TEXT AS customer_search_term,
        SUM(impressions) AS impressions, SUM(clicks) AS clicks,
        SUM(spend) AS spend, SUM(orders) AS orders,
        SUM(sales) AS sales, SUM(combined_sales) AS combined_sales,
        CASE WHEN SUM(spend) > 0  THEN SUM(sales) / SUM(spend)  ELSE 0 END AS roas,
        CASE WHEN SUM(clicks) > 0 THEN SUM(spend) / SUM(clicks) ELSE 0 END AS cpc,
        CASE WHEN SUM(sales) > 0  THEN SUM(spend) / SUM(sales)  ELSE 0 END AS acos
    FROM marketcloud_silver.silver_campaign_daily
    GROUP BY tenant_id, amc_instance_id, ads_profile_id, campaign_id, ad_product_type
),
target_agg AS (
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        campaign_id, MAX(campaign_name) AS campaign_name, ad_product_type,
        ad_group_name, targeting, match_type,
        NULL::TEXT AS customer_search_term,
        SUM(impressions) AS impressions, SUM(clicks) AS clicks,
        SUM(spend) AS spend, SUM(orders) AS orders,
        SUM(sales) AS sales, SUM(combined_sales) AS combined_sales,
        CASE WHEN SUM(spend) > 0  THEN SUM(sales) / SUM(spend)  ELSE 0 END AS roas,
        CASE WHEN SUM(clicks) > 0 THEN SUM(spend) / SUM(clicks) ELSE 0 END AS cpc,
        CASE WHEN SUM(sales) > 0  THEN SUM(spend) / SUM(sales)  ELSE 0 END AS acos
    FROM marketcloud_silver.silver_target_daily
    GROUP BY tenant_id, amc_instance_id, ads_profile_id,
             campaign_id, ad_product_type, ad_group_name, targeting, match_type
),
term_agg AS (
    SELECT
        tenant_id, amc_instance_id, ads_profile_id,
        campaign_id, MAX(campaign_name) AS campaign_name, ad_product_type,
        ad_group_name, targeting, match_type, customer_search_term,
        SUM(impressions) AS impressions, SUM(clicks) AS clicks,
        SUM(spend) AS spend, SUM(orders) AS orders,
        SUM(sales) AS sales, SUM(combined_sales) AS combined_sales,
        CASE WHEN SUM(spend) > 0  THEN SUM(sales) / SUM(spend)  ELSE 0 END AS roas,
        CASE WHEN SUM(clicks) > 0 THEN SUM(spend) / SUM(clicks) ELSE 0 END AS cpc,
        CASE WHEN SUM(sales) > 0  THEN SUM(spend) / SUM(sales)  ELSE 0 END AS acos
    FROM marketcloud_silver.silver_search_term_daily
    GROUP BY tenant_id, amc_instance_id, ads_profile_id,
             campaign_id, ad_product_type, ad_group_name, targeting, match_type,
             customer_search_term
)
-- CUT_CAMPAIGN_BUDGET: campanha com gasto relevante, ROAS ruim, poucos pedidos
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    'S001'::TEXT AS source_view,
    campaign_id, campaign_name, ad_product_type,
    ad_group_name, targeting, match_type, customer_search_term,
    impressions, clicks, spend, orders, sales, combined_sales,
    roas, cpc, acos,
    'CUT_CAMPAIGN_BUDGET'::TEXT AS action_type,
    'LOW_ROAS_RELEVANT_SPEND'::TEXT AS reason_code,
    CASE WHEN spend > 100 THEN 0.80 WHEN spend > 30 THEN 0.60 ELSE 0.40 END AS confidence_score,
    'HIGH'::TEXT AS risk_level,
    jsonb_build_object('window','all_s001','spend',ROUND(spend::NUMERIC,4),'roas',ROUND(roas::NUMERIC,4),'orders',orders,'rule','CUT_CAMPAIGN_BUDGET') AS evidence_json,
    NOW() AS created_at
FROM campaign_agg
WHERE roas < 2 AND orders <= 1 AND spend > 20

UNION ALL

-- PAUSE_TARGET: target com muitos cliques sem venda (alta prioridade)
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    'S002'::TEXT,
    campaign_id, campaign_name, ad_product_type,
    ad_group_name, targeting, match_type, customer_search_term,
    impressions, clicks, spend, orders, sales, combined_sales,
    roas, cpc, acos,
    'PAUSE_TARGET'::TEXT,
    'CLICKS_NO_SALE_HIGH_VOLUME'::TEXT,
    CASE WHEN clicks >= 20 THEN 0.80 WHEN clicks >= 10 THEN 0.60 ELSE 0.40 END,
    'HIGH'::TEXT,
    jsonb_build_object('window','all_s002','clicks',clicks,'spend',ROUND(spend::NUMERIC,4),'sales',sales,'targeting',targeting,'rule','PAUSE_TARGET'),
    NOW()
FROM target_agg
WHERE clicks >= 10 AND sales = 0

UNION ALL

-- REDUCE_BID: target com gasto e cliques sem venda (volume menor que PAUSE)
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    'S002'::TEXT,
    campaign_id, campaign_name, ad_product_type,
    ad_group_name, targeting, match_type, customer_search_term,
    impressions, clicks, spend, orders, sales, combined_sales,
    roas, cpc, acos,
    'REDUCE_BID'::TEXT,
    'SPEND_NO_SALE'::TEXT,
    CASE WHEN clicks >= 8 THEN 0.60 ELSE 0.40 END,
    'MEDIUM'::TEXT,
    jsonb_build_object('window','all_s002','clicks',clicks,'spend',ROUND(spend::NUMERIC,4),'sales',sales,'targeting',targeting,'rule','REDUCE_BID'),
    NOW()
FROM target_agg
WHERE clicks >= 5 AND clicks < 10 AND sales = 0 AND spend > 0

UNION ALL

-- REDUCE_BID no nível de search term (não zanom)
SELECT
    tenant_id, amc_instance_id, ads_profile_id,
    'S003'::TEXT,
    campaign_id, campaign_name, ad_product_type,
    ad_group_name, targeting, match_type, customer_search_term,
    impressions, clicks, spend, orders, sales, combined_sales,
    roas, cpc, acos,
    'REDUCE_BID'::TEXT,
    'TERM_SPEND_NO_SALE'::TEXT,
    CASE WHEN clicks >= 8 THEN 0.60 ELSE 0.40 END,
    'MEDIUM'::TEXT,
    jsonb_build_object('window','all_s003','clicks',clicks,'spend',ROUND(spend::NUMERIC,4),'sales',sales,'customer_search_term',customer_search_term,'rule','REDUCE_BID'),
    NOW()
FROM term_agg
WHERE clicks >= 5 AND sales = 0 AND spend > 0
  AND LOWER(customer_search_term) NOT LIKE '%zanom%';


-- =====================================================================
-- Validações (executar após criação das views)
-- =====================================================================

-- Contagens Gold:
-- SELECT 'G001' AS gold, COUNT(*) FROM marketcloud_gold.gold_campaign_health
-- UNION ALL SELECT 'G004', COUNT(*) FROM marketcloud_gold.gold_hourly_bid_schedule
-- UNION ALL SELECT 'G005', COUNT(*) FROM marketcloud_gold.gold_negative_keyword_candidates
-- UNION ALL SELECT 'G006', COUNT(*) FROM marketcloud_gold.gold_scale_candidates
-- UNION ALL SELECT 'G007', COUNT(*) FROM marketcloud_gold.gold_cut_candidates;

-- Distribuição de ações G004:
-- SELECT action_type, COUNT(*) FROM marketcloud_gold.gold_hourly_bid_schedule
-- GROUP BY action_type ORDER BY count DESC;

-- Recomendações horárias por campanha:
-- SELECT campaign_name, action_type, COUNT(*), SUM(spend), SUM(sales), AVG(roas)
-- FROM marketcloud_gold.gold_hourly_bid_schedule
-- GROUP BY campaign_name, action_type ORDER BY campaign_name, action_type;

-- Candidatos negativos:
-- SELECT action_type, COUNT(*), SUM(clicks), SUM(spend), SUM(sales)
-- FROM marketcloud_gold.gold_negative_keyword_candidates
-- GROUP BY action_type ORDER BY count DESC;

-- =====================================================================
-- End of file
-- =====================================================================
