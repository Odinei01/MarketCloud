-- Migration 010: ZANOM Query Catalog — 40 operational queries

-- Extend query_family enum
ALTER TYPE query_family ADD VALUE IF NOT EXISTS 'KEYWORD_HARVEST';
ALTER TYPE query_family ADD VALUE IF NOT EXISTS 'MARGIN_ANALYSIS';
ALTER TYPE query_family ADD VALUE IF NOT EXISTS 'PRODUCT_INTEL';

-- ZANOM default parameters schema (reused as base)
-- target_roas=5.0, min_spend varies by product, lookback=14d, BRL, America/Sao_Paulo

INSERT INTO query_templates (
    tenant_id, name, code, description, query_family, query_goal,
    sql_template, parameters_schema, min_lookback_days, max_lookback_days,
    supported_campaign_types, supported_marketplaces
) VALUES

-- ──────────────────────────────────────────────────────────────
-- SPRINT 1 — DINHEIRO IMEDIATO
-- ──────────────────────────────────────────────────────────────

(NULL,
 'MC_ZANOM_Q001 — Desperdício por campanha',
 'MC_ZANOM_Q001',
 'Quais campanhas gastaram dinheiro e não geraram venda direta nem assistida?',
 'BUDGET_WASTE',
 'Identificar campanhas CUT_CANDIDATE: gasto acima do mínimo, zero venda direta, zero venda assistida.',
 $SQL$
SELECT
    c.campaign_id,
    c.campaign_name,
    c.campaign_type,
    {{product_group_label}} AS product_group,
    SUM(c.spend)                                                          AS spend,
    SUM(c.impressions)                                                    AS impressions,
    SUM(c.clicks)                                                         AS clicks,
    SAFE_DIVIDE(SUM(c.spend), NULLIF(SUM(c.clicks), 0))                   AS cpc,
    SAFE_DIVIDE(SUM(c.clicks), NULLIF(SUM(c.impressions), 0))             AS ctr,
    COALESCE(SUM(p.orders_direct), 0)                                     AS orders_direct,
    COALESCE(SUM(p.sales_direct), 0)                                      AS sales_direct,
    COALESCE(SUM(p.orders_assisted), 0)                                   AS orders_assisted,
    COALESCE(SUM(p.sales_assisted), 0)                                    AS sales_assisted,
    SAFE_DIVIDE(SUM(p.sales_direct), NULLIF(SUM(c.spend), 0))             AS direct_roas,
    SAFE_DIVIDE(SUM(p.sales_assisted), NULLIF(SUM(c.spend), 0))           AS assisted_roas,
    SAFE_DIVIDE(COALESCE(SUM(p.sales_direct),0)+COALESCE(SUM(p.sales_assisted),0), NULLIF(SUM(c.spend), 0)) AS total_roas,
    SUM(c.spend)                                                          AS waste_amount,
    CASE
        WHEN SUM(c.spend) >= {{min_spend}}
         AND COALESCE(SUM(p.orders_direct), 0) = 0
         AND COALESCE(SUM(p.orders_assisted), 0) = 0
        THEN 'CUT_CANDIDATE'
        WHEN SAFE_DIVIDE(COALESCE(SUM(p.sales_direct),0)+COALESCE(SUM(p.sales_assisted),0), NULLIF(SUM(c.spend),0)) < {{target_roas}}
        THEN 'WATCH'
        ELSE 'OK'
    END AS decision
FROM sponsored_ads_traffic_report c
LEFT JOIN amc_attributed_purchases p
    ON c.campaign_id = p.campaign_id
    AND p.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE c.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY c.campaign_id, c.campaign_name, c.campaign_type
HAVING SUM(c.spend) >= {{min_spend}}
ORDER BY waste_amount DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"min_spend":{"type":"number","default":30.0},"target_roas":{"type":"number","default":5.0},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 7, 90,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q002 — Desperdício por keyword',
 'MC_ZANOM_Q002',
 'Quais keywords gastam dinheiro sem gerar venda direta nem assistida?',
 'KEYWORD_HARVEST',
 'Listar keywords NEGATIVE_OR_CUT: spend acima do mínimo, clicks suficientes, zero conversão.',
 $SQL$
SELECT
    k.campaign_id,
    k.campaign_name,
    k.ad_group_id,
    k.ad_group_name,
    k.keyword_id,
    k.keyword_text,
    k.match_type,
    SUM(k.spend)                                                          AS spend,
    SUM(k.clicks)                                                         AS clicks,
    SUM(k.impressions)                                                    AS impressions,
    SAFE_DIVIDE(SUM(k.spend), NULLIF(SUM(k.clicks), 0))                   AS cpc,
    SAFE_DIVIDE(SUM(k.clicks), NULLIF(SUM(k.impressions), 0))             AS ctr,
    COALESCE(SUM(p.orders_direct), 0)                                     AS orders_direct,
    COALESCE(SUM(p.orders_assisted), 0)                                   AS orders_assisted,
    COALESCE(SUM(p.sales_direct), 0)                                      AS sales_direct,
    COALESCE(SUM(p.sales_assisted), 0)                                    AS sales_assisted,
    SAFE_DIVIDE(SUM(p.sales_direct), NULLIF(SUM(k.spend), 0))             AS direct_roas,
    SAFE_DIVIDE(COALESCE(SUM(p.orders_assisted),0),
        NULLIF(COALESCE(SUM(p.orders_direct),0)+COALESCE(SUM(p.orders_assisted),0), 0)) AS assist_rate,
    CASE
        WHEN SUM(k.spend) >= {{min_spend}}
         AND SUM(k.clicks) >= {{min_clicks}}
         AND COALESCE(SUM(p.orders_direct), 0) = 0
         AND COALESCE(SUM(p.orders_assisted), 0) = 0
        THEN 'NEGATIVE_OR_CUT'
        ELSE 'WATCH'
    END AS waste_score,
    CASE
        WHEN SUM(k.spend) >= {{min_spend}} AND COALESCE(SUM(p.orders_direct),0) = 0
         AND COALESCE(SUM(p.orders_assisted),0) = 0
        THEN 'NEGATIVE_OR_CUT'
        ELSE 'OK'
    END AS decision
FROM keyword_traffic_report k
LEFT JOIN amc_keyword_attributed_purchases p
    ON k.keyword_id = p.keyword_id
    AND p.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE k.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY k.campaign_id, k.campaign_name, k.ad_group_id, k.ad_group_name,
         k.keyword_id, k.keyword_text, k.match_type
HAVING SUM(k.spend) >= {{min_spend}}
ORDER BY spend DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"min_spend":{"type":"number","default":20.0},"min_clicks":{"type":"integer","default":8},"target_roas":{"type":"number","default":5.0},"campaign_filter":{"type":"string","default":""}}}',
 7, 60,
 ARRAY['SPONSORED_PRODUCTS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q003 — Termos vencedores para virar exata',
 'MC_ZANOM_Q003',
 'Quais termos de busca devem virar campanha exata ou ad group exato?',
 'KEYWORD_HARVEST',
 'Identificar search terms com conversão real e ROAS >= meta: PROMOTE_TO_EXACT.',
 $SQL$
SELECT
    st.search_term,
    st.matched_keyword,
    st.campaign_id,
    st.ad_group_id,
    {{product_group_label}} AS product_group,
    st.match_type,
    SUM(st.spend)                                                           AS spend,
    SUM(st.clicks)                                                          AS clicks,
    COALESCE(SUM(p.orders), 0)                                              AS orders,
    COALESCE(SUM(p.sales), 0)                                               AS sales,
    SAFE_DIVIDE(COALESCE(SUM(p.orders),0), NULLIF(SUM(st.clicks),0))        AS conversion_rate,
    SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(st.spend),0))          AS direct_roas,
    COALESCE(SUM(p.orders_assisted), 0)                                     AS assisted_orders,
    COALESCE(SUM(p.sales_assisted), 0)                                      AS assisted_sales,
    SAFE_DIVIDE(COALESCE(SUM(p.orders_assisted),0),
        NULLIF(COALESCE(SUM(p.orders),0)+COALESCE(SUM(p.orders_assisted),0),0)) AS assist_rate,
    SAFE_DIVIDE(SUM(st.spend), NULLIF(COALESCE(SUM(p.orders),0),0)) * {{target_roas}} AS recommended_exact_bid,
    CASE
        WHEN COALESCE(SUM(p.orders),0) >= {{min_orders_exact}}
         AND SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(st.spend),0)) >= {{target_roas}}
        THEN 'PROMOTE_TO_EXACT'
        WHEN COALESCE(SUM(p.orders_assisted),0) >= 2
        THEN 'CREATE_EXACT_TEST'
        ELSE 'WATCH_MORE_DATA'
    END AS decision
FROM search_term_report st
LEFT JOIN amc_search_term_purchases p
    ON st.search_term = p.search_term
    AND p.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE st.date BETWEEN {{period_start}} AND {{period_end}}
  AND st.match_type IN ('BROAD', 'PHRASE')
  {{campaign_filter}}
GROUP BY st.search_term, st.matched_keyword, st.campaign_id, st.ad_group_id, st.match_type
HAVING COALESCE(SUM(p.orders),0) >= 1 OR COALESCE(SUM(p.orders_assisted),0) >= 1
ORDER BY orders DESC, direct_roas DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"min_orders_exact":{"type":"integer","default":1},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 14, 90,
 ARRAY['SPONSORED_PRODUCTS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q004 — Termos para negativar',
 'MC_ZANOM_Q004',
 'Quais termos de busca devem entrar como negativos na campanha?',
 'KEYWORD_HARVEST',
 'Listar search terms irrelevantes ou com gasto sem retorno: NEGATIVE_EXACT ou NEGATIVE_PHRASE.',
 $SQL$
SELECT
    st.search_term,
    st.campaign_id,
    st.campaign_name,
    st.ad_group_id,
    {{product_group_label}} AS product_group,
    SUM(st.spend)                                                           AS spend,
    SUM(st.clicks)                                                          AS clicks,
    COALESCE(SUM(p.orders), 0)                                              AS orders,
    COALESCE(SUM(p.sales), 0)                                               AS sales,
    COALESCE(SUM(p.orders_assisted), 0)                                     AS assisted_orders,
    COALESCE(SUM(p.sales_assisted), 0)                                      AS assisted_sales,
    SAFE_DIVIDE(SUM(st.spend), NULLIF(SUM(st.clicks),0))                    AS cpc,
    SAFE_DIVIDE(SUM(st.clicks), NULLIF(SUM(st.impressions),0))              AS ctr,
    SAFE_DIVIDE(COALESCE(SUM(p.orders),0), NULLIF(SUM(st.clicks),0))        AS conversion_rate,
    CASE
        WHEN SUM(st.spend) >= {{min_spend}}
         AND COALESCE(SUM(p.orders),0) = 0
         AND COALESCE(SUM(p.orders_assisted),0) = 0
         AND LENGTH(st.search_term) > 15
        THEN 'Termo específico sem conversão'
        WHEN COALESCE(SUM(p.orders),0) = 0
         AND COALESCE(SUM(p.orders_assisted),0) = 0
        THEN 'Raiz irrelevante para categoria'
        ELSE 'Verificar manualmente'
    END AS reason,
    CASE
        WHEN SUM(st.spend) >= {{min_spend}}
         AND COALESCE(SUM(p.orders),0) = 0
         AND COALESCE(SUM(p.orders_assisted),0) = 0
         AND LENGTH(st.search_term) > 15
        THEN 'NEGATIVE_EXACT'
        WHEN COALESCE(SUM(p.orders),0) = 0 AND COALESCE(SUM(p.orders_assisted),0) = 0
        THEN 'NEGATIVE_PHRASE'
        ELSE 'WATCH'
    END AS negative_type_suggestion
FROM search_term_report st
LEFT JOIN amc_search_term_purchases p
    ON st.search_term = p.search_term
    AND p.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE st.date BETWEEN {{period_start}} AND {{period_end}}
  AND st.match_type IN ('BROAD', 'PHRASE')
  {{campaign_filter}}
GROUP BY st.search_term, st.campaign_id, st.campaign_name, st.ad_group_id
HAVING SUM(st.spend) >= {{min_spend}}
   AND COALESCE(SUM(p.orders),0) = 0
ORDER BY spend DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"min_spend":{"type":"number","default":20.0},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 7, 60,
 ARRAY['SPONSORED_PRODUCTS'],
 ARRAY['AMAZON_BR']
),

-- ──────────────────────────────────────────────────────────────
-- SPRINT 2 — NÃO MATAR CAMPANHA ERRADA
-- ──────────────────────────────────────────────────────────────

(NULL,
 'MC_ZANOM_Q005 — Campanhas assistidas que não podem ser pausadas',
 'MC_ZANOM_Q005',
 'Quais campanhas parecem ruins no ROAS direto mas ajudam outras campanhas a vender?',
 'ASSISTED_CONVERSIONS',
 'Proteger campanhas com assist_rate >= 30%: decisão PROTECT mesmo com ROAS direto abaixo da meta.',
 $SQL$
SELECT
    c.campaign_id,
    c.campaign_name,
    {{product_group_label}} AS product_group,
    SUM(c.spend)                                                               AS spend,
    COUNT(DISTINCT CASE WHEN p.touchpoint_position='LAST' THEN p.user_id END)  AS direct_orders,
    SUM(CASE WHEN p.touchpoint_position='LAST' THEN p.purchase_value ELSE 0 END) AS direct_sales,
    SAFE_DIVIDE(
        SUM(CASE WHEN p.touchpoint_position='LAST' THEN p.purchase_value ELSE 0 END),
        NULLIF(SUM(c.spend),0))                                                AS direct_roas,
    COUNT(DISTINCT CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.user_id END) AS assisted_orders,
    SUM(CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.attributed_value ELSE 0 END) AS assisted_sales,
    SAFE_DIVIDE(
        SUM(CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.attributed_value ELSE 0 END),
        NULLIF(SUM(c.spend),0))                                                AS assisted_roas,
    SAFE_DIVIDE(
        COUNT(DISTINCT CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.user_id END),
        NULLIF(COUNT(DISTINCT p.user_id),0))                                   AS assist_rate,
    SAFE_DIVIDE(
        COUNT(DISTINCT CASE WHEN p.touchpoint_position='FIRST' THEN p.user_id END),
        NULLIF(COUNT(DISTINCT p.user_id),0))                                   AS first_touch_rate,
    SAFE_DIVIDE(
        COUNT(DISTINCT CASE WHEN p.touchpoint_position='MIDDLE' THEN p.user_id END),
        NULLIF(COUNT(DISTINCT p.user_id),0))                                   AS middle_touch_rate,
    SAFE_DIVIDE(
        COUNT(DISTINCT CASE WHEN p.touchpoint_position='LAST' THEN p.user_id END),
        NULLIF(COUNT(DISTINCT p.user_id),0))                                   AS last_touch_rate,
    CASE
        WHEN SAFE_DIVIDE(
                SUM(CASE WHEN p.touchpoint_position='LAST' THEN p.purchase_value ELSE 0 END),
                NULLIF(SUM(c.spend),0)) < {{target_roas}}
         AND SAFE_DIVIDE(
                COUNT(DISTINCT CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.user_id END),
                NULLIF(COUNT(DISTINCT p.user_id),0)) >= {{assist_rate_threshold}}
        THEN 'PROTECT'
        WHEN SAFE_DIVIDE(
                SUM(CASE WHEN p.touchpoint_position='LAST' THEN p.purchase_value ELSE 0 END),
                NULLIF(SUM(c.spend),0)) >= {{target_roas}}
        THEN 'OK_DIRECT_WINNER'
        ELSE 'REVIEW'
    END AS decision
FROM sponsored_ads_traffic_report c
JOIN amc_path_to_purchase p ON c.campaign_id = p.campaign_id
    AND p.impression_date BETWEEN {{period_start}} AND {{period_end}}
WHERE c.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY c.campaign_id, c.campaign_name
ORDER BY assist_rate DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"assist_rate_threshold":{"type":"number","default":0.30},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 14, 90,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q006 — Classificação da keyword por funil',
 'MC_ZANOM_Q006',
 'A keyword é descoberta, consideração, fechamento ou desperdício?',
 'KEYWORD_ROLE',
 'Classificar keywords por posição no funil: DISCOVERY / CONSIDERATION / CONVERSION / WASTE.',
 $SQL$
SELECT
    k.keyword_text,
    k.match_type,
    k.campaign_id,
    {{product_group_label}} AS product_group,
    SUM(k.spend)                                                                AS spend,
    SUM(k.clicks)                                                               AS clicks,
    COUNT(DISTINCT CASE WHEN p.touchpoint_position='FIRST'  THEN p.user_id END) AS first_touch_count,
    COUNT(DISTINCT CASE WHEN p.touchpoint_position='MIDDLE' THEN p.user_id END) AS middle_touch_count,
    COUNT(DISTINCT CASE WHEN p.touchpoint_position='LAST'   THEN p.user_id END) AS last_touch_count,
    COALESCE(SUM(p.direct_orders),0)                                            AS direct_orders,
    COALESCE(SUM(p.assisted_orders),0)                                          AS assisted_orders,
    SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN p.touchpoint_position='FIRST'  THEN p.user_id END), NULLIF(COUNT(DISTINCT p.user_id),0)) AS first_touch_rate,
    SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN p.touchpoint_position='MIDDLE' THEN p.user_id END), NULLIF(COUNT(DISTINCT p.user_id),0)) AS middle_touch_rate,
    SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN p.touchpoint_position='LAST'   THEN p.user_id END), NULLIF(COUNT(DISTINCT p.user_id),0)) AS last_touch_rate,
    SAFE_DIVIDE(COALESCE(SUM(p.sales_direct),0), NULLIF(SUM(k.spend),0))        AS direct_roas,
    SAFE_DIVIDE(COALESCE(SUM(p.assisted_orders),0), NULLIF(COUNT(DISTINCT p.user_id),0)) AS assist_rate,
    CASE
        WHEN SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN p.touchpoint_position='LAST' THEN p.user_id END), NULLIF(COUNT(DISTINCT p.user_id),0)) >= 0.5
        THEN 'CONVERSION'
        WHEN SAFE_DIVIDE(COUNT(DISTINCT CASE WHEN p.touchpoint_position='FIRST' THEN p.user_id END), NULLIF(COUNT(DISTINCT p.user_id),0)) >= 0.5
        THEN 'DISCOVERY'
        WHEN COALESCE(SUM(p.assisted_orders),0) > 0
        THEN 'CONSIDERATION'
        WHEN SUM(k.spend) >= {{min_spend}} AND COALESCE(SUM(p.direct_orders),0)=0 AND COALESCE(SUM(p.assisted_orders),0)=0
        THEN 'WASTE'
        ELSE 'UNKNOWN'
    END AS keyword_role
FROM keyword_traffic_report k
LEFT JOIN amc_keyword_paths p
    ON k.keyword_text = p.keyword AND k.campaign_id = p.campaign_id
    AND p.impression_date BETWEEN {{period_start}} AND {{period_end}}
WHERE k.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY k.keyword_text, k.match_type, k.campaign_id
ORDER BY spend DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"min_spend":{"type":"number","default":15.0},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 14, 90,
 ARRAY['SPONSORED_PRODUCTS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q007 — Jornada até a compra',
 'MC_ZANOM_Q007',
 'Qual caminho o cliente percorre antes de comprar um produto ZANOM?',
 'PATH_TO_PURCHASE',
 'Sequência real de campanhas tocadas antes da conversão — proteger topo, escalar fechamento.',
 $SQL$
SELECT
    {{product_group_label}} AS product_group,
    {{asin_filter_label}} AS asin,
    ARRAY_TO_STRING(path_campaigns, ' → ') AS path_sequence,
    path_campaigns[SAFE_OFFSET(0)] AS first_campaign,
    ARRAY_TO_STRING(ARRAY_SLICE(path_campaigns, 1, ARRAY_LENGTH(path_campaigns)-2), ', ') AS middle_campaigns,
    path_campaigns[SAFE_OFFSET(ARRAY_LENGTH(path_campaigns)-1)] AS last_campaign,
    COUNT(path_campaigns) AS touchpoints_count,
    COUNT(DISTINCT user_id) AS users,
    SUM(conversions) AS orders,
    SUM(purchase_value) AS sales,
    AVG(days_to_purchase) AS avg_days_to_purchase,
    AVG(ARRAY_LENGTH(path_campaigns)) AS avg_touchpoints,
    SAFE_DIVIDE(SUM(conversions), COUNT(DISTINCT user_id)) AS path_conversion_rate
FROM amc_paths
WHERE purchase_date BETWEEN {{period_start}} AND {{period_end}}
  AND conversions >= 1
  {{asin_filter}}
GROUP BY path_sequence, first_campaign, middle_campaigns, last_campaign
HAVING COUNT(DISTINCT user_id) >= 2
ORDER BY orders DESC, users DESC
LIMIT 50
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"asin":{"type":"string","default":""},"product_group_label":{"type":"string","default":"TODOS"},"asin_filter":{"type":"string","default":""},"asin_filter_label":{"type":"string","default":"TODOS"}}}',
 14, 90,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

-- ──────────────────────────────────────────────────────────────
-- SPRINT 3 — HORÁRIO E BUDGET
-- ──────────────────────────────────────────────────────────────

(NULL,
 'MC_ZANOM_Q008 — Saturação de frequência',
 'MC_ZANOM_Q008',
 'Estou mostrando anúncio demais para o mesmo público?',
 'FREQUENCY_ANALYSIS',
 'Identificar saturação: frequência ótima de conversão vs frequência cara sem retorno.',
 $SQL$
SELECT
    c.campaign_id,
    c.campaign_name,
    {{product_group_label}} AS product_group,
    f.frequency_bucket,
    COUNT(DISTINCT f.user_id) AS users,
    SUM(f.impressions) AS impressions,
    SUM(f.clicks) AS clicks,
    SUM(c.spend) AS spend,
    COALESCE(SUM(p.orders),0) AS orders,
    COALESCE(SUM(p.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(p.orders),0), NULLIF(COUNT(DISTINCT f.user_id),0)) AS conversion_rate,
    SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(c.spend),0)) AS roas,
    CASE
        WHEN f.frequency_bucket >= 6
         AND SAFE_DIVIDE(COALESCE(SUM(p.orders),0), NULLIF(COUNT(DISTINCT f.user_id),0)) <
             LAG(SAFE_DIVIDE(COALESCE(SUM(p.orders),0), NULLIF(COUNT(DISTINCT f.user_id),0)))
             OVER (PARTITION BY c.campaign_id ORDER BY f.frequency_bucket)
        THEN SUM(c.spend)
        ELSE 0
    END AS waste_after_frequency,
    CASE
        WHEN f.frequency_bucket >= 6 THEN 'REDUCE_PRESSURE'
        WHEN f.frequency_bucket BETWEEN 2 AND 3 THEN 'OPTIMAL_RANGE'
        ELSE 'MONITOR'
    END AS decision
FROM amc_frequency f
JOIN sponsored_ads_traffic_report c ON f.campaign_id = c.campaign_id
LEFT JOIN amc_attributed_purchases p ON f.user_id = p.user_id AND f.campaign_id = p.campaign_id
WHERE f.exposure_date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY c.campaign_id, c.campaign_name, f.frequency_bucket
ORDER BY c.campaign_id, f.frequency_bucket
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 7, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q009 — Campanha boa sem orçamento',
 'MC_ZANOM_Q009',
 'Quais campanhas boas da ZANOM estão ficando sem orçamento?',
 'BUDGET_WASTE',
 'Identificar campanhas com ROAS alto que esgotam budget cedo: oportunidade de escalar.',
 $SQL$
SELECT
    c.campaign_id,
    c.campaign_name,
    {{product_group_label}} AS product_group,
    c.daily_budget,
    SUM(c.spend) AS spend,
    SAFE_DIVIDE(SUM(c.spend), NULLIF(c.daily_budget,0)) AS budget_usage_rate,
    COALESCE(SUM(p.sales),0) AS sales,
    COALESCE(SUM(p.orders),0) AS orders,
    SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(c.spend),0)) AS roas,
    SAFE_DIVIDE(SUM(c.spend), NULLIF(COALESCE(SUM(p.sales),0),0)) AS acos,
    MIN(CASE WHEN c.spend >= c.daily_budget * 0.95 THEN c.hour_of_day END) AS hour_budget_depleted,
    CASE
        WHEN SAFE_DIVIDE(SUM(c.spend), NULLIF(c.daily_budget,0)) >= 0.95
         AND SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(c.spend),0)) >= {{target_roas}}
        THEN TRUE ELSE FALSE
    END AS lost_opportunity_flag,
    CASE
        WHEN SAFE_DIVIDE(SUM(c.spend), NULLIF(c.daily_budget,0)) >= 0.95
         AND SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(c.spend),0)) >= {{target_roas}}
        THEN c.daily_budget * 1.5
        ELSE c.daily_budget
    END AS recommended_budget
FROM sponsored_ads_hourly_report c
LEFT JOIN amc_attributed_purchases p ON c.campaign_id = p.campaign_id
    AND p.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE c.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY c.campaign_id, c.campaign_name, c.daily_budget
HAVING SAFE_DIVIDE(SUM(c.spend), NULLIF(c.daily_budget,0)) >= 0.85
ORDER BY roas DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 7, 30,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q010 — Topo de busca vale a pena?',
 'MC_ZANOM_Q010',
 'Topo de busca está vendendo ou só encarecendo CPC?',
 'PLACEMENT_IMPACT',
 'Comparar ROAS e ACoS por placement: TOP_OF_SEARCH vs PRODUCT_PAGE vs OTHER.',
 $SQL$
SELECT
    c.campaign_id,
    c.campaign_name,
    r.placement,
    SUM(r.spend) AS spend,
    SUM(r.clicks) AS clicks,
    SAFE_DIVIDE(SUM(r.spend), NULLIF(SUM(r.clicks),0)) AS cpc,
    COALESCE(SUM(p.orders),0) AS orders,
    COALESCE(SUM(p.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(r.spend),0)) AS roas,
    SAFE_DIVIDE(SUM(r.spend), NULLIF(COALESCE(SUM(p.sales),0),0)) AS acos,
    SAFE_DIVIDE(COALESCE(SUM(p.orders),0), NULLIF(SUM(r.clicks),0)) AS conversion_rate,
    SAFE_DIVIDE(
        SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(r.spend),0)),
        NULLIF(SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(r.spend),0)) + 0.1, 0)
    ) AS placement_efficiency,
    CASE
        WHEN r.placement = 'TOP_OF_SEARCH'
         AND SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(r.spend),0)) >= {{target_roas}}
        THEN 'INCREASE_TOP_OF_SEARCH'
        WHEN r.placement = 'TOP_OF_SEARCH'
         AND SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(r.spend),0)) < {{target_roas}}
        THEN 'REDUCE_TOP_OF_SEARCH'
        ELSE 'MONITOR'
    END AS decision
FROM placement_performance_report r
JOIN sponsored_ads_traffic_report c ON r.campaign_id = c.campaign_id
LEFT JOIN amc_attributed_purchases p ON r.campaign_id = p.campaign_id
    AND p.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE r.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY c.campaign_id, c.campaign_name, r.placement
ORDER BY roas DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"campaign_filter":{"type":"string","default":""}}}',
 7, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q011 — Melhor horário por campanha',
 'MC_ZANOM_Q011',
 'Quais horários vendem e quais horários só gastam?',
 'PLACEMENT_IMPACT',
 'Identificar hora-pico de conversão e hora cara sem retorno — base para agenda de bid.',
 $SQL$
SELECT
    c.campaign_id,
    c.campaign_name,
    {{product_group_label}} AS product_group,
    h.hour_of_day,
    h.day_of_week,
    SUM(h.spend) AS spend,
    SUM(h.clicks) AS clicks,
    COALESCE(SUM(p.orders),0) AS orders,
    COALESCE(SUM(p.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(h.spend),0)) AS roas,
    SAFE_DIVIDE(SUM(h.spend), NULLIF(COALESCE(SUM(p.sales),0),0)) AS acos,
    SAFE_DIVIDE(SUM(h.spend), NULLIF(SUM(h.clicks),0)) AS cpc,
    SAFE_DIVIDE(COALESCE(SUM(p.orders),0), NULLIF(SUM(h.clicks),0)) AS conversion_rate,
    CASE
        WHEN SUM(h.spend) >= {{min_spend_hour}}
         AND COALESCE(SUM(p.orders),0) = 0
        THEN TRUE ELSE FALSE
    END AS waste_flag,
    CASE
        WHEN SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(h.spend),0)) >= {{target_roas}} * 1.2
        THEN 1.3
        WHEN SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(h.spend),0)) >= {{target_roas}}
        THEN 1.1
        WHEN SUM(h.spend) >= {{min_spend_hour}} AND COALESCE(SUM(p.orders),0) = 0
        THEN 0.5
        ELSE 1.0
    END AS recommended_bid_multiplier
FROM sponsored_ads_hourly_report h
JOIN sponsored_ads_traffic_report c ON h.campaign_id = c.campaign_id
LEFT JOIN amc_attributed_purchases p
    ON h.campaign_id = p.campaign_id
    AND p.purchase_hour = h.hour_of_day
    AND p.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE h.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY c.campaign_id, c.campaign_name, h.hour_of_day, h.day_of_week
ORDER BY c.campaign_id, h.hour_of_day
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"min_spend_hour":{"type":"number","default":5.0},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 7, 30,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q013 — Horário caro sem conversão',
 'MC_ZANOM_Q013',
 'Em quais horários eu gasto e não vendo nada?',
 'BUDGET_WASTE',
 'Identificar janelas horárias com gasto alto e zero conversão — base para circuit breaker.',
 $SQL$
SELECT
    h.campaign_id,
    h.hour_of_day,
    SUM(h.spend) AS spend,
    SUM(h.clicks) AS clicks,
    COALESCE(SUM(p.orders),0) AS orders,
    COALESCE(SUM(p.orders_assisted),0) AS assisted_orders,
    SUM(h.spend) AS waste_amount,
    CASE
        WHEN SUM(h.spend) >= {{min_spend_hour}} AND COALESCE(SUM(p.orders),0) = 0 AND COALESCE(SUM(p.orders_assisted),0) = 0
        THEN 'REDUCE_BID'
        WHEN SUM(h.spend) >= {{min_spend_hour}} * 2 AND COALESCE(SUM(p.orders),0) = 0
        THEN 'BLOCK_HOUR'
        ELSE 'MONITOR'
    END AS recommended_action
FROM sponsored_ads_hourly_report h
LEFT JOIN amc_attributed_purchases p
    ON h.campaign_id = p.campaign_id AND p.purchase_hour = h.hour_of_day
    AND p.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE h.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY h.campaign_id, h.hour_of_day
HAVING SUM(h.spend) >= {{min_spend_hour}} AND COALESCE(SUM(p.orders),0) = 0
ORDER BY waste_amount DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"min_spend_hour":{"type":"number","default":5.0},"campaign_filter":{"type":"string","default":""}}}',
 7, 30,
 ARRAY['SPONSORED_PRODUCTS'],
 ARRAY['AMAZON_BR']
),

-- ──────────────────────────────────────────────────────────────
-- SPRINT 4 — PRODUTO E MARGEM
-- ──────────────────────────────────────────────────────────────

(NULL,
 'MC_ZANOM_Q012 — Dia da semana por produto',
 'MC_ZANOM_Q012',
 'Qual dia da semana é melhor para cada produto da ZANOM?',
 'PLACEMENT_IMPACT',
 'Identificar padrão de conversão por dia da semana e produto.',
 $SQL$
SELECT
    {{product_group_label}} AS product_group,
    CASE EXTRACT(DAYOFWEEK FROM h.date)
        WHEN 1 THEN 'Domingo' WHEN 2 THEN 'Segunda' WHEN 3 THEN 'Terça'
        WHEN 4 THEN 'Quarta' WHEN 5 THEN 'Quinta' WHEN 6 THEN 'Sexta'
        WHEN 7 THEN 'Sábado'
    END AS day_of_week,
    EXTRACT(DAYOFWEEK FROM h.date) AS day_num,
    SUM(h.spend) AS spend,
    SUM(h.clicks) AS clicks,
    COALESCE(SUM(p.orders),0) AS orders,
    COALESCE(SUM(p.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(h.spend),0)) AS roas,
    SAFE_DIVIDE(COALESCE(SUM(p.orders),0), NULLIF(SUM(h.clicks),0)) AS conversion_rate,
    SAFE_DIVIDE(SUM(h.spend), NULLIF(SUM(h.clicks),0)) AS avg_cpc,
    CASE
        WHEN SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(h.spend),0)) >= {{target_roas}} * 1.2 THEN 'SCALE'
        WHEN SAFE_DIVIDE(COALESCE(SUM(p.sales),0), NULLIF(SUM(h.spend),0)) < {{target_roas}} * 0.5 THEN 'REDUCE'
        ELSE 'MAINTAIN'
    END AS decision
FROM sponsored_ads_hourly_report h
LEFT JOIN amc_attributed_purchases p ON h.campaign_id = p.campaign_id
    AND p.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE h.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY product_group, day_of_week, day_num
ORDER BY roas DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 14, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q024 — CPC alto pelo ticket do produto',
 'MC_ZANOM_Q024',
 'O CPC está alto demais para o ticket e margem do produto?',
 'MARGIN_ANALYSIS',
 'Calcular CPC de equilíbrio por produto e comparar com CPC atual.',
 $SQL$
SELECT
    p.asin,
    {{product_group_label}} AS product_group,
    p.campaign_id,
    AVG(p.price) AS avg_ticket,
    AVG(p.estimated_margin_rate) * AVG(p.price) AS estimated_margin,
    SAFE_DIVIDE(SUM(t.spend), NULLIF(SUM(t.clicks),0)) AS avg_cpc,
    SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.clicks),0)) AS conversion_rate,
    AVG(p.estimated_margin_rate) * AVG(p.price)
        * SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.clicks),0)) AS break_even_cpc,
    SAFE_DIVIDE(
        SAFE_DIVIDE(SUM(t.spend), NULLIF(SUM(t.clicks),0)),
        NULLIF(AVG(p.estimated_margin_rate) * AVG(p.price)
            * SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.clicks),0)), 0)
    ) AS current_cpc_vs_break_even,
    CASE
        WHEN SAFE_DIVIDE(SUM(t.spend), NULLIF(SUM(t.clicks),0)) >
             AVG(p.estimated_margin_rate) * AVG(p.price)
             * SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.clicks),0)) * 1.2
        THEN 'REDUCE_BID'
        ELSE 'OK'
    END AS decision
FROM product_metrics p
JOIN sponsored_ads_traffic_report t ON p.campaign_id = t.campaign_id
LEFT JOIN amc_attributed_purchases a ON p.campaign_id = a.campaign_id
    AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE t.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY p.asin, product_group, p.campaign_id
ORDER BY current_cpc_vs_break_even DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 7, 60,
 ARRAY['SPONSORED_PRODUCTS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q026 — Campanha por margem real do produto',
 'MC_ZANOM_Q026',
 'A campanha parece boa em ROAS mas presta depois de custo, taxa e margem?',
 'MARGIN_ANALYSIS',
 'Calcular lucro real após Ads, COGS e taxas Amazon. Evitar escalar campanha com ROAS bom e lucro ruim.',
 $SQL$
SELECT
    t.campaign_id,
    p.asin,
    {{product_group_label}} AS product_group,
    COALESCE(SUM(a.sales),0) AS sales,
    SUM(t.spend) AS ad_spend,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) AS roas,
    AVG(p.estimated_cogs) * COALESCE(SUM(a.orders),0) AS estimated_cogs,
    AVG(p.amazon_fee_rate) * COALESCE(SUM(a.sales),0) AS amazon_fees_estimate,
    COALESCE(SUM(a.sales),0)
        - AVG(p.estimated_cogs) * COALESCE(SUM(a.orders),0)
        - AVG(p.amazon_fee_rate) * COALESCE(SUM(a.sales),0)                AS estimated_margin,
    COALESCE(SUM(a.sales),0)
        - AVG(p.estimated_cogs) * COALESCE(SUM(a.orders),0)
        - AVG(p.amazon_fee_rate) * COALESCE(SUM(a.sales),0)
        - SUM(t.spend)                                                      AS profit_after_ads,
    CASE
        WHEN COALESCE(SUM(a.sales),0)
            - AVG(p.estimated_cogs) * COALESCE(SUM(a.orders),0)
            - AVG(p.amazon_fee_rate) * COALESCE(SUM(a.sales),0)
            - SUM(t.spend) > 0
        THEN 'PROFITABLE'
        ELSE 'LOSS'
    END AS profitability_flag
FROM sponsored_ads_traffic_report t
JOIN product_metrics p ON t.campaign_id = p.campaign_id
LEFT JOIN amc_attributed_purchases a ON t.campaign_id = a.campaign_id
    AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE t.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY t.campaign_id, p.asin, product_group
ORDER BY profit_after_ads DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 14, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q027 — Ranking de produtos para receber Ads',
 'MC_ZANOM_Q027',
 'Qual produto da ZANOM merece mais investimento em Ads?',
 'MARGIN_ANALYSIS',
 'Score de prioridade de Ads por produto: estoque + margem + conversão + reviews.',
 $SQL$
SELECT
    p.asin,
    {{product_group_label}} AS product_group,
    p.stock_available,
    p.days_of_cover,
    p.estimated_margin_rate AS margin,
    SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.clicks),0)) AS conversion_rate,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) AS roas,
    p.review_count,
    p.rating,
    (
        CASE WHEN p.days_of_cover >= 30 THEN 30 ELSE p.days_of_cover END * 0.2 +
        p.estimated_margin_rate * 100 * 0.3 +
        SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.clicks),0)) * 1000 * 0.3 +
        SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) / {{target_roas}} * 20 * 0.2
    ) AS ad_efficiency_score,
    CASE
        WHEN p.days_of_cover < 7 THEN 'STOCK_RISK_HOLD'
        WHEN p.estimated_margin_rate < 0.1 THEN 'LOW_MARGIN_HOLD'
        WHEN SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) >= {{target_roas}}
         AND p.days_of_cover >= 30 THEN 'INVEST_NOW'
        WHEN SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) >= {{target_roas}} * 0.7
        THEN 'INVEST_CAREFULLY'
        ELSE 'MONITOR'
    END AS investment_priority
FROM product_metrics p
LEFT JOIN sponsored_ads_traffic_report t ON p.campaign_id = t.campaign_id
    AND t.date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN amc_attributed_purchases a ON p.campaign_id = a.campaign_id
    AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
GROUP BY p.asin, product_group, p.stock_available, p.days_of_cover,
         p.estimated_margin_rate, p.review_count, p.rating
ORDER BY ad_efficiency_score DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"product_group_label":{"type":"string","default":"TODOS"}}}',
 14, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q028 — Risco de escalar sem estoque',
 'MC_ZANOM_Q028',
 'Estou aumentando Ads de produto que vai romper estoque?',
 'MARGIN_ANALYSIS',
 'Cruzar VMD com estoque disponível e taxa de crescimento de Ads para detectar risco de ruptura.',
 $SQL$
SELECT
    p.asin,
    {{product_group_label}} AS product_group,
    t.campaign_id,
    p.stock_available,
    p.vmd,
    SAFE_DIVIDE(p.stock_available, NULLIF(p.vmd,0)) AS days_of_cover,
    SAFE_DIVIDE(
        SUM(CASE WHEN t.date >= DATE_SUB({{period_end}}, INTERVAL 7 DAY) THEN t.spend ELSE 0 END),
        NULLIF(SUM(CASE WHEN t.date < DATE_SUB({{period_end}}, INTERVAL 7 DAY) THEN t.spend ELSE 0 END), 0)
    ) - 1.0 AS ad_growth_rate,
    CASE
        WHEN SAFE_DIVIDE(p.stock_available, NULLIF(p.vmd,0)) < 7 THEN 'CRITICAL'
        WHEN SAFE_DIVIDE(p.stock_available, NULLIF(p.vmd,0)) < 14 THEN 'HIGH'
        WHEN SAFE_DIVIDE(p.stock_available, NULLIF(p.vmd,0)) < 30 THEN 'MEDIUM'
        ELSE 'LOW'
    END AS risk_of_stockout,
    CASE
        WHEN SAFE_DIVIDE(p.stock_available, NULLIF(p.vmd,0)) < 14
        THEN 'DO_NOT_SCALE'
        WHEN SAFE_DIVIDE(p.stock_available, NULLIF(p.vmd,0)) < 30
        THEN 'SCALE_CAREFULLY'
        ELSE 'SCALE_NOW'
    END AS decision
FROM product_metrics p
JOIN sponsored_ads_traffic_report t ON p.campaign_id = t.campaign_id
WHERE t.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY p.asin, product_group, t.campaign_id, p.stock_available, p.vmd
ORDER BY days_of_cover ASC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 7, 30,
 ARRAY['SPONSORED_PRODUCTS'],
 ARRAY['AMAZON_BR']
),

-- ──────────────────────────────────────────────────────────────
-- SPRINT 5 — ASIN E CROSS-SELL
-- ──────────────────────────────────────────────────────────────

(NULL,
 'MC_ZANOM_Q014 — ASIN target vencedor',
 'MC_ZANOM_Q014',
 'Quais ASINs concorrentes ou complementares geram venda?',
 'ASIN_CROSS_SELL',
 'Identificar ASINs de product targeting que convertem: KEEP_ASIN_TARGET ou INCREASE_ASIN_BID.',
 $SQL$
SELECT
    pt.target_asin,
    pt.target_title,
    pt.campaign_id,
    {{product_group_label}} AS product_group,
    SUM(pt.spend) AS spend,
    SUM(pt.clicks) AS clicks,
    COALESCE(SUM(a.orders),0) AS orders,
    COALESCE(SUM(a.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(pt.spend),0)) AS direct_roas,
    COALESCE(SUM(a.orders_assisted),0) AS assisted_orders,
    COALESCE(SUM(a.sales_assisted),0) AS assisted_sales,
    SUM(pt.detail_page_views) AS detail_page_views,
    CASE
        WHEN SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(pt.spend),0)) >= {{target_roas}}
        THEN 'INCREASE_ASIN_BID'
        WHEN SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(pt.spend),0)) >= {{target_roas}} * 0.5
        THEN 'KEEP_ASIN_TARGET'
        ELSE 'CUT_ASIN_TARGET'
    END AS decision
FROM product_targeting_report pt
LEFT JOIN amc_attributed_purchases a ON pt.target_asin = a.purchased_asin
    AND pt.campaign_id = a.campaign_id
    AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE pt.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY pt.target_asin, pt.target_title, pt.campaign_id, product_group
HAVING SUM(pt.clicks) >= 5
ORDER BY direct_roas DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 14, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q015 — ASIN target que só rouba clique',
 'MC_ZANOM_Q015',
 'Quais ASINs concorrentes geram clique caro e não vendem?',
 'BUDGET_WASTE',
 'Identificar ASINs de product targeting com gasto alto e zero conversão: CUT_ASIN_TARGET.',
 $SQL$
SELECT
    pt.target_asin,
    pt.campaign_id,
    SUM(pt.spend) AS spend,
    SUM(pt.clicks) AS clicks,
    COALESCE(SUM(a.orders),0) AS orders,
    COALESCE(SUM(a.orders_assisted),0) AS assisted_orders,
    SAFE_DIVIDE(SUM(pt.spend), NULLIF(SUM(pt.clicks),0)) AS cpc,
    SUM(pt.spend) AS waste_amount,
    'CUT_ASIN_TARGET' AS decision
FROM product_targeting_report pt
LEFT JOIN amc_attributed_purchases a ON pt.target_asin = a.purchased_asin
    AND pt.campaign_id = a.campaign_id
    AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE pt.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY pt.target_asin, pt.campaign_id
HAVING SUM(pt.spend) >= {{min_spend}}
   AND COALESCE(SUM(a.orders),0) = 0
   AND COALESCE(SUM(a.orders_assisted),0) = 0
ORDER BY waste_amount DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"min_spend":{"type":"number","default":20.0},"campaign_filter":{"type":"string","default":""}}}',
 7, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q016 — Cross-sell entre produtos ZANOM',
 'MC_ZANOM_Q016',
 'Quem compra um produto ZANOM tem chance de comprar outro?',
 'ASIN_CROSS_SELL',
 'Descobrir sobreposição de compradores entre produtos ZANOM para criar campanhas cross-sell.',
 $SQL$
SELECT
    o.source_asin,
    {{source_product_group}} AS source_product_group,
    o.target_asin,
    {{target_product_group}} AS target_product_group,
    COUNT(DISTINCT o.user_id) AS overlap_users,
    COALESCE(SUM(o.cross_purchase_orders),0) AS cross_purchase_orders,
    SAFE_DIVIDE(
        COALESCE(SUM(o.cross_purchase_orders),0),
        NULLIF(COUNT(DISTINCT o.user_id),0)
    ) AS cross_purchase_rate,
    CASE
        WHEN SAFE_DIVIDE(COALESCE(SUM(o.cross_purchase_orders),0), NULLIF(COUNT(DISTINCT o.user_id),0)) >= 0.15
        THEN 'CREATE_CROSS_SELL_CAMPAIGN'
        WHEN SAFE_DIVIDE(COALESCE(SUM(o.cross_purchase_orders),0), NULLIF(COUNT(DISTINCT o.user_id),0)) >= 0.05
        THEN 'TEST_BUNDLE'
        ELSE 'MONITOR'
    END AS recommended_action
FROM amc_asin_overlap o
WHERE o.purchase_date BETWEEN {{period_start}} AND {{period_end}}
  AND o.source_asin IN ({{zanom_asins}})
  AND o.target_asin IN ({{zanom_asins}})
  AND o.source_asin != o.target_asin
GROUP BY o.source_asin, source_product_group, o.target_asin, target_product_group
HAVING COUNT(DISTINCT o.user_id) >= 5
ORDER BY cross_purchase_rate DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"zanom_asins":{"type":"string","default":"\"B0H2NL3S6T\""},"source_product_group":{"type":"string","default":"\"LOCALIZADOR\""},"target_product_group":{"type":"string","default":"\"TODOS\""}}}',
 30, 90,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q035 — Campanha de produto complementar',
 'MC_ZANOM_Q035',
 'Quais produtos complementares posso atacar com product targeting?',
 'ASIN_CROSS_SELL',
 'Identificar categorias/ASINs complementares com sinal de conversão para criar targeting.',
 $SQL$
SELECT
    s.source_product_group,
    s.complement_category,
    s.target_term_or_asin,
    COUNT(DISTINCT o.user_id) AS overlap_signal,
    COALESCE(SUM(o.cross_purchase_orders),0) AS conversion_signal,
    CASE
        WHEN COALESCE(SUM(o.cross_purchase_orders),0) >= 5 AND s.asin_target IS NOT NULL
        THEN 'SPONSORED_DISPLAY_ASIN'
        WHEN COALESCE(SUM(o.cross_purchase_orders),0) >= 2
        THEN 'SPONSORED_PRODUCTS_KEYWORD'
        ELSE 'TEST_SMALL'
    END AS recommended_campaign_type
FROM zanom_complement_map s
LEFT JOIN amc_asin_overlap o ON s.target_asin = o.target_asin
    AND o.purchase_date BETWEEN {{period_start}} AND {{period_end}}
GROUP BY s.source_product_group, s.complement_category, s.target_term_or_asin, s.asin_target
ORDER BY conversion_signal DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"}}}',
 30, 90,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

-- ──────────────────────────────────────────────────────────────
-- SPRINT 6 — INTELIGÊNCIA AVANÇADA
-- ──────────────────────────────────────────────────────────────

(NULL,
 'MC_ZANOM_Q019 — Novo cliente vs cliente recorrente',
 'MC_ZANOM_Q019',
 'Ads está trazendo cliente novo ou só recomprador?',
 'NEW_TO_BRAND',
 'Classificar campanha como ACQUISITION, DEFENSE ou RETENTION.',
 $SQL$
SELECT
    t.campaign_id,
    {{product_group_label}} AS product_group,
    COALESCE(SUM(ntb.new_to_brand_orders),0) AS new_to_brand_orders,
    COALESCE(SUM(a.orders),0) - COALESCE(SUM(ntb.new_to_brand_orders),0) AS returning_orders,
    COALESCE(SUM(ntb.new_to_brand_sales),0) AS new_to_brand_sales,
    COALESCE(SUM(a.sales),0) - COALESCE(SUM(ntb.new_to_brand_sales),0) AS returning_sales,
    SAFE_DIVIDE(
        COALESCE(SUM(ntb.new_to_brand_orders),0),
        NULLIF(COALESCE(SUM(a.orders),0),0)
    ) AS new_customer_rate,
    CASE
        WHEN SAFE_DIVIDE(COALESCE(SUM(ntb.new_to_brand_orders),0), NULLIF(COALESCE(SUM(a.orders),0),0)) >= 0.6
        THEN 'ACQUISITION'
        WHEN SAFE_DIVIDE(COALESCE(SUM(ntb.new_to_brand_orders),0), NULLIF(COALESCE(SUM(a.orders),0),0)) <= 0.3
        THEN 'RETENTION'
        ELSE 'DEFENSE'
    END AS decision
FROM sponsored_ads_traffic_report t
LEFT JOIN amc_new_to_brand ntb ON t.campaign_id = ntb.campaign_id
    AND ntb.purchase_date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN amc_attributed_purchases a ON t.campaign_id = a.campaign_id
    AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE t.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY t.campaign_id, product_group
ORDER BY new_customer_rate DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 14, 90,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q020 — Tempo até conversão',
 'MC_ZANOM_Q020',
 'Quanto tempo o cliente demora para comprar depois do primeiro contato?',
 'PATH_TO_PURCHASE',
 'Definir janela de remarketing e evitar cortar campanha cedo demais.',
 $SQL$
SELECT
    {{product_group_label}} AS product_group,
    t.campaign_id,
    CASE
        WHEN p.days_to_purchase = 0 THEN '0 dias'
        WHEN p.days_to_purchase = 1 THEN '1 dia'
        WHEN p.days_to_purchase BETWEEN 2 AND 3 THEN '2-3 dias'
        WHEN p.days_to_purchase BETWEEN 4 AND 7 THEN '4-7 dias'
        WHEN p.days_to_purchase BETWEEN 8 AND 14 THEN '8-14 dias'
        ELSE '15+ dias'
    END AS days_to_purchase_bucket,
    CASE
        WHEN p.days_to_purchase = 0 THEN 0
        WHEN p.days_to_purchase = 1 THEN 1
        WHEN p.days_to_purchase BETWEEN 2 AND 3 THEN 2
        WHEN p.days_to_purchase BETWEEN 4 AND 7 THEN 4
        WHEN p.days_to_purchase BETWEEN 8 AND 14 THEN 8
        ELSE 15
    END AS bucket_sort,
    COUNT(DISTINCT p.user_id) AS users,
    SUM(p.conversions) AS orders,
    SUM(p.purchase_value) AS sales,
    SAFE_DIVIDE(SUM(p.conversions), NULLIF(COUNT(DISTINCT p.user_id),0)) AS conversion_rate
FROM amc_paths p
JOIN sponsored_ads_traffic_report t ON p.first_campaign_id = t.campaign_id
WHERE p.purchase_date BETWEEN {{period_start}} AND {{period_end}}
  AND p.conversions >= 1
  {{campaign_filter}}
GROUP BY product_group, t.campaign_id, days_to_purchase_bucket, bucket_sort
ORDER BY t.campaign_id, bucket_sort
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 14, 90,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q021 — Campanha de defesa da marca',
 'MC_ZANOM_Q021',
 'Preciso pagar anúncio para quem já procura ZANOM?',
 'STORE_JOURNEY',
 'Avaliar se termos de marca têm concorrência no leilão e se defesa é necessária.',
 $SQL$
SELECT
    st.search_term,
    t.campaign_id,
    SUM(t.spend) AS spend,
    COALESCE(SUM(a.orders),0) AS orders,
    COALESCE(SUM(a.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) AS roas,
    CASE
        WHEN LOWER(st.search_term) LIKE '%zanom%' THEN TRUE ELSE FALSE
    END AS brand_term_flag,
    SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.spend),0)) * 100 AS defense_need_score,
    CASE
        WHEN SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) >= {{target_roas}} * 1.5
        THEN 'MAINTAIN_DEFENSE'
        WHEN SUM(t.spend) >= 50 AND COALESCE(SUM(a.orders),0) > 0
        THEN 'MAINTAIN_DEFENSE'
        ELSE 'REDUCE_BRAND_BID'
    END AS decision
FROM search_term_report st
JOIN sponsored_ads_traffic_report t ON st.campaign_id = t.campaign_id
LEFT JOIN amc_attributed_purchases a ON t.campaign_id = a.campaign_id
    AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE t.date BETWEEN {{period_start}} AND {{period_end}}
  AND (LOWER(st.search_term) LIKE '%zanom%'
       OR LOWER(st.search_term) LIKE '%zanom localizador%'
       OR LOWER(st.search_term) LIKE '%zanom carregador%')
GROUP BY st.search_term, t.campaign_id
ORDER BY spend DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0}}}',
 14, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q023 — Impacto de cupom/promoção',
 'MC_ZANOM_Q023',
 'Cupom aumenta conversão ou só reduz margem?',
 'AUDIENCE_DISCOVERY',
 'Comparar periods com e sem cupom: conversão, ROAS e margem estimada.',
 $SQL$
SELECT
    p.asin,
    {{product_group_label}} AS product_group,
    CASE WHEN pr.coupon_active THEN TRUE ELSE FALSE END AS coupon_active,
    pr.period,
    SUM(pr.sessions) AS sessions,
    COALESCE(SUM(a.orders),0) AS orders,
    COALESCE(SUM(a.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(pr.sessions),0)) AS conversion_rate,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) AS roas,
    AVG(p.estimated_margin_rate) * COALESCE(SUM(a.sales),0)
        - COALESCE(SUM(pr.coupon_cost),0) AS margin_proxy,
    CASE
        WHEN SAFE_DIVIDE(COALESCE(SUM(a.orders), 0) FILTER (WHERE pr.coupon_active),
             NULLIF(SUM(pr.sessions) FILTER (WHERE pr.coupon_active),0)) >
             SAFE_DIVIDE(COALESCE(SUM(a.orders), 0) FILTER (WHERE NOT pr.coupon_active),
             NULLIF(SUM(pr.sessions) FILTER (WHERE NOT pr.coupon_active),0)) * 1.2
        THEN 'KEEP_COUPON'
        ELSE 'REVIEW_COUPON'
    END AS decision
FROM promotion_report pr
JOIN product_metrics p ON pr.asin = p.asin
LEFT JOIN sponsored_ads_traffic_report t ON p.campaign_id = t.campaign_id
    AND t.date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN amc_attributed_purchases a ON p.campaign_id = a.campaign_id
    AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE pr.date BETWEEN {{period_start}} AND {{period_end}}
  {{product_filter}}
GROUP BY p.asin, product_group, coupon_active, pr.period
ORDER BY p.asin, coupon_active DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"product_group_label":{"type":"string","default":"TODOS"},"product_filter":{"type":"string","default":""}}}',
 14, 90,
 ARRAY['SPONSORED_PRODUCTS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q034 — Canibalização entre campanhas',
 'MC_ZANOM_Q034',
 'Tenho campanhas competindo pela mesma venda?',
 'CAMPAIGN_OVERLAP',
 'Identificar sobreposição de usuários/termos entre campanhas e estimar verba duplicada.',
 $SQL$
SELECT
    o.campaign_a,
    o.campaign_b,
    COUNT(DISTINCT o.user_id) AS overlap_users,
    ARRAY_AGG(DISTINCT o.search_term LIMIT 10) AS overlap_search_terms,
    SAFE_DIVIDE(COUNT(DISTINCT o.user_id),
        NULLIF((SELECT COUNT(DISTINCT user_id) FROM amc_campaign_users WHERE campaign_id = o.campaign_a),0)
    ) AS overlap_rate,
    SUM(o.duplicated_spend) AS duplicated_spend_estimate,
    CASE
        WHEN SAFE_DIVIDE(SUM(ca.sales), NULLIF(SUM(ca.spend),0)) >
             SAFE_DIVIDE(SUM(cb.sales), NULLIF(SUM(cb.spend),0))
        THEN o.campaign_a ELSE o.campaign_b
    END AS winner_campaign,
    CASE
        WHEN SAFE_DIVIDE(COUNT(DISTINCT o.user_id),
            NULLIF((SELECT COUNT(DISTINCT user_id) FROM amc_campaign_users WHERE campaign_id = o.campaign_a),0)) >= 0.3
        THEN 'CONSOLIDATE'
        ELSE 'MONITOR'
    END AS decision
FROM amc_campaign_overlap o
JOIN sponsored_ads_traffic_report ca ON o.campaign_a = ca.campaign_id
    AND ca.date BETWEEN {{period_start}} AND {{period_end}}
JOIN sponsored_ads_traffic_report cb ON o.campaign_b = cb.campaign_id
    AND cb.date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN amc_attributed_purchases ap_a ON o.campaign_a = ap_a.campaign_id
LEFT JOIN amc_attributed_purchases ap_b ON o.campaign_b = ap_b.campaign_id
WHERE o.overlap_date BETWEEN {{period_start}} AND {{period_end}}
GROUP BY o.campaign_a, o.campaign_b
HAVING COUNT(DISTINCT o.user_id) >= 10
ORDER BY overlap_rate DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"}}}',
 14, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q037 — Score de escalabilidade por campanha',
 'MC_ZANOM_Q037',
 'Qual campanha aguenta mais verba sem quebrar ROAS?',
 'PRODUCT_INTEL',
 'Score composto: ROAS + assist_rate + saturação + estoque + margem → SCALE_NOW / SCALE_CAREFULLY / DO_NOT_SCALE.',
 $SQL$
SELECT
    t.campaign_id,
    t.campaign_name,
    AVG(t.daily_budget) AS current_budget,
    SUM(t.spend) AS current_spend,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) AS roas,
    SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.clicks),0)) AS conversion_rate,
    SAFE_DIVIDE(
        COUNT(DISTINCT CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.user_id END),
        NULLIF(COUNT(DISTINCT p.user_id),0)
    ) AS assist_rate,
    CASE WHEN MAX(f.frequency_bucket) >= 6 THEN 0.5 ELSE 1.0 END AS frequency_saturation,
    CASE WHEN MIN(pm.days_of_cover) < 14 THEN 0.3 ELSE 1.0 END AS stock_risk,
    CASE WHEN AVG(pm.estimated_margin_rate) < 0.15 THEN 0.5 ELSE 1.0 END AS margin_risk,
    (
        SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) / {{target_roas}} * 40 +
        SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.clicks),0)) * 1000 * 20 +
        SAFE_DIVIDE(
            COUNT(DISTINCT CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.user_id END),
            NULLIF(COUNT(DISTINCT p.user_id),0)
        ) * 20 +
        CASE WHEN MAX(f.frequency_bucket) >= 6 THEN 0 ELSE 10 END +
        CASE WHEN MIN(pm.days_of_cover) >= 30 THEN 10 ELSE 0 END
    ) AS scalability_score,
    CASE
        WHEN SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) >= {{target_roas}} * 1.3
         AND MIN(pm.days_of_cover) >= 30
         AND MAX(f.frequency_bucket) < 6
        THEN 'SCALE_NOW'
        WHEN SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) >= {{target_roas}}
        THEN 'SCALE_CAREFULLY'
        ELSE 'DO_NOT_SCALE'
    END AS decision
FROM sponsored_ads_traffic_report t
LEFT JOIN amc_attributed_purchases a ON t.campaign_id = a.campaign_id
    AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN amc_path_to_purchase p ON t.campaign_id = p.campaign_id
LEFT JOIN amc_frequency f ON t.campaign_id = f.campaign_id
LEFT JOIN product_metrics pm ON t.campaign_id = pm.campaign_id
WHERE t.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY t.campaign_id, t.campaign_name
ORDER BY scalability_score DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"campaign_filter":{"type":"string","default":""}}}',
 14, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'],
 ARRAY['AMAZON_BR']
),

(NULL,
 'MC_ZANOM_Q040 — Resumo executivo diário',
 'MC_ZANOM_Q040',
 'O que eu devo fazer hoje nas campanhas da ZANOM?',
 'STORE_JOURNEY',
 'Plano de ação diário: cortar, proteger, escalar, negativar, budget alert, estoque.',
 $SQL$
WITH campaign_summary AS (
    SELECT
        t.campaign_id,
        t.campaign_name,
        SUM(t.spend) AS spend,
        COALESCE(SUM(a.sales),0) AS sales,
        SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) AS roas,
        COALESCE(SUM(a.orders),0) AS orders,
        SAFE_DIVIDE(
            COUNT(DISTINCT CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.user_id END),
            NULLIF(COUNT(DISTINCT p.user_id),0)
        ) AS assist_rate,
        SAFE_DIVIDE(SUM(t.spend), NULLIF(AVG(t.daily_budget),0)) AS budget_usage_rate
    FROM sponsored_ads_traffic_report t
    LEFT JOIN amc_attributed_purchases a ON t.campaign_id = a.campaign_id
        AND a.purchase_date = {{today}}
    LEFT JOIN amc_path_to_purchase p ON t.campaign_id = p.campaign_id
    WHERE t.date = {{today}}
    GROUP BY t.campaign_id, t.campaign_name
)
SELECT
    {{today}} AS date,
    {{store_id}} AS store_id,
    SUM(spend) AS total_spend,
    SUM(sales) AS total_sales,
    SAFE_DIVIDE(SUM(sales), NULLIF(SUM(spend),0)) AS overall_roas,
    ARRAY_AGG(DISTINCT campaign_name ORDER BY spend DESC LIMIT 3)
        FILTER (WHERE roas < {{target_roas}} * 0.5 AND orders = 0) AS cut_candidates,
    ARRAY_AGG(DISTINCT campaign_name ORDER BY assist_rate DESC LIMIT 3)
        FILTER (WHERE assist_rate >= 0.3 AND roas < {{target_roas}}) AS protect_campaigns,
    ARRAY_AGG(DISTINCT campaign_name ORDER BY roas DESC LIMIT 3)
        FILTER (WHERE roas >= {{target_roas}} * 1.3) AS scale_candidates,
    ARRAY_AGG(DISTINCT campaign_name LIMIT 3)
        FILTER (WHERE budget_usage_rate >= 0.95 AND roas >= {{target_roas}}) AS budget_alerts,
    CONCAT(
        'Cortar: ', CAST(COUNT(*) FILTER (WHERE roas < {{target_roas}} * 0.5 AND orders = 0) AS STRING), ' | ',
        'Proteger: ', CAST(COUNT(*) FILTER (WHERE assist_rate >= 0.3 AND roas < {{target_roas}}) AS STRING), ' | ',
        'Escalar: ', CAST(COUNT(*) FILTER (WHERE roas >= {{target_roas}} * 1.3) AS STRING)
    ) AS top_3_actions
FROM campaign_summary
$SQL$,
 '{"type":"object","properties":{"today":{"type":"string","format":"date"},"store_id":{"type":"string"},"target_roas":{"type":"number","default":5.0}}}',
 1, 7,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

-- Remaining P1 queries (Q017, Q018, Q022, Q025, Q029, Q030, Q031, Q032, Q033, Q036, Q038, Q039)

(NULL, 'MC_ZANOM_Q017 — Produto com clique bom e página ruim', 'MC_ZANOM_Q017',
 'O anúncio atrai clique, mas a página não converte?',
 'AUDIENCE_DISCOVERY',
 'Detectar problema de página: alta CTR + baixa conversão = REVIEW_PRODUCT_PAGE.',
 $SQL$
SELECT p.asin, {{product_group_label}} AS product_group, t.campaign_id,
    SAFE_DIVIDE(SUM(t.clicks), NULLIF(SUM(t.impressions),0)) AS ctr,
    SAFE_DIVIDE(SUM(t.spend), NULLIF(SUM(t.clicks),0)) AS cpc,
    SUM(pr.sessions) AS sessions,
    COALESCE(SUM(a.orders),0) AS orders,
    SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(pr.sessions),0)) AS conversion_rate,
    0.12 AS benchmark_conversion,
    CASE WHEN SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(pr.sessions),0)) < 0.06
         AND SUM(t.clicks) >= 20 THEN TRUE ELSE FALSE END AS page_problem_flag,
    CASE WHEN SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(pr.sessions),0)) < 0.06
         AND SUM(t.clicks) >= 20 THEN 'REVIEW_PRODUCT_PAGE' ELSE 'OK' END AS decision
FROM sponsored_ads_traffic_report t
JOIN product_metrics p ON t.campaign_id = p.campaign_id
LEFT JOIN business_report pr ON p.asin = pr.asin AND pr.date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN amc_attributed_purchases a ON t.campaign_id = a.campaign_id AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE t.date BETWEEN {{period_start}} AND {{period_end}} {{campaign_filter}}
GROUP BY p.asin, product_group, t.campaign_id
ORDER BY ctr DESC, conversion_rate ASC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 7, 60, ARRAY['SPONSORED_PRODUCTS'], ARRAY['AMAZON_BR']),

(NULL, 'MC_ZANOM_Q018 — Produto que vende sem precisar de tanto Ads', 'MC_ZANOM_Q018',
 'Qual produto vende bem organicamente e talvez esteja recebendo Ads demais?',
 'PRODUCT_INTEL',
 'Estimar dependência de Ads vs venda orgânica para decidir redução de budget defensivo.',
 $SQL$
SELECT p.asin, {{product_group_label}} AS product_group,
    COALESCE(SUM(a.sales),0) AS ad_sales,
    SUM(br.ordered_product_sales) - COALESCE(SUM(a.sales),0) AS organic_sales_estimate,
    SUM(br.ordered_product_sales) AS total_sales,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(br.ordered_product_sales),0)) AS ad_dependency_rate,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) AS roas,
    CASE WHEN SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(br.ordered_product_sales),0)) < 0.3
         THEN 'REDUCE_ADS_DEFENSE' ELSE 'MAINTAIN' END AS decision
FROM product_metrics p
JOIN business_report br ON p.asin = br.asin AND br.date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN sponsored_ads_traffic_report t ON p.campaign_id = t.campaign_id AND t.date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN amc_attributed_purchases a ON p.campaign_id = a.campaign_id AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
GROUP BY p.asin, product_group ORDER BY ad_dependency_rate ASC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"product_group_label":{"type":"string","default":"TODOS"}}}',
 14, 60, ARRAY['SPONSORED_PRODUCTS'], ARRAY['AMAZON_BR']),

(NULL, 'MC_ZANOM_Q022 — Concorrente roubando venda', 'MC_ZANOM_Q022',
 'Quais concorrentes aparecem na jornada antes do cliente comprar ou abandonar?',
 'AUDIENCE_DISCOVERY',
 'Mapear concorrentes que interceptam jornadas ZANOM para campanha de conquesting.',
 $SQL$
SELECT co.competitor_asin, co.competitor_brand,
    COUNT(DISTINCT CASE WHEN co.path_had_conversion=0 THEN co.user_id END) AS overlap_users,
    COUNT(DISTINCT CASE WHEN co.path_had_conversion=0 AND co.competitor_touched=1 THEN co.user_id END) AS lost_users,
    COUNT(DISTINCT CASE WHEN co.path_had_conversion=1 THEN co.user_id END) AS converted_users,
    SAFE_DIVIDE(
        COUNT(DISTINCT CASE WHEN co.path_had_conversion=0 AND co.competitor_touched=1 THEN co.user_id END),
        NULLIF(COUNT(DISTINCT co.user_id),0)
    ) AS conquesting_opportunity
FROM amc_competitor_overlap co
WHERE co.overlap_date BETWEEN {{period_start}} AND {{period_end}}
  AND co.zanom_asin IN ({{zanom_asins}})
GROUP BY co.competitor_asin, co.competitor_brand
HAVING COUNT(DISTINCT co.user_id) >= 10
ORDER BY conquesting_opportunity DESC LIMIT 20
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"zanom_asins":{"type":"string","default":"\"B0H2NL3S6T\""}}}',
 14, 60, ARRAY['SPONSORED_DISPLAY'], ARRAY['AMAZON_BR']),

(NULL, 'MC_ZANOM_Q025 — Budget shift: tirar de ruim e colocar em bom', 'MC_ZANOM_Q025',
 'De onde tirar orçamento e para onde mandar?',
 'BUDGET_WASTE',
 'Gerar pares source/target para realocação de budget baseada em ROAS.',
 $SQL$
WITH ranked AS (
    SELECT t.campaign_id, t.campaign_name,
        SUM(t.spend) AS spend,
        COALESCE(SUM(a.sales),0) AS sales,
        SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) AS roas,
        AVG(t.daily_budget) AS budget,
        SAFE_DIVIDE(SUM(t.spend), NULLIF(AVG(t.daily_budget),0)) AS budget_usage_rate
    FROM sponsored_ads_traffic_report t
    LEFT JOIN amc_attributed_purchases a ON t.campaign_id = a.campaign_id
        AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
    WHERE t.date BETWEEN {{period_start}} AND {{period_end}}
    GROUP BY t.campaign_id, t.campaign_name
)
SELECT s.campaign_id AS source_campaign_id, s.campaign_name AS source_campaign_name,
    s.spend * (1 - s.roas/{{target_roas}}) AS source_waste_amount,
    g.campaign_id AS target_campaign_id, g.campaign_name AS target_campaign_name,
    g.roas AS target_roas_actual,
    g.budget_usage_rate >= 0.9 AS target_budget_limited_flag,
    s.spend * 0.2 AS recommended_shift_amount
FROM ranked s
CROSS JOIN ranked g
WHERE s.roas < {{target_roas}} * 0.5
  AND g.roas >= {{target_roas}} * 1.2
  AND g.budget_usage_rate >= 0.85
ORDER BY source_waste_amount DESC LIMIT 10
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0}}}',
 7, 30, ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'], ARRAY['AMAZON_BR']),

(NULL, 'MC_ZANOM_Q029 — FBA vs MFN impacto na conversão', 'MC_ZANOM_Q029',
 'Produto vendido via FBA converte melhor que envio próprio?',
 'ASIN_CROSS_SELL',
 'Comparar conversão e ROAS por fulfillment type para priorizar FBA.',
 $SQL$
SELECT p.asin, {{product_group_label}} AS product_group, p.fulfillment_type,
    SUM(br.sessions) AS sessions, SUM(t.clicks) AS clicks,
    COALESCE(SUM(a.orders),0) AS orders,
    SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(br.sessions),0)) AS conversion_rate,
    COALESCE(SUM(a.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) AS roas,
    CASE WHEN p.fulfillment_type='FBA' AND SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(br.sessions),0)) > 0.1
         THEN 'PRIORITIZE_FBA' ELSE 'MONITOR' END AS decision
FROM product_metrics p
JOIN business_report br ON p.asin = br.asin AND br.date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN sponsored_ads_traffic_report t ON p.campaign_id = t.campaign_id AND t.date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN amc_attributed_purchases a ON p.campaign_id = a.campaign_id AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE {{product_filter}}
GROUP BY p.asin, product_group, p.fulfillment_type
ORDER BY conversion_rate DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"product_group_label":{"type":"string","default":"TODOS"},"product_filter":{"type":"string","default":"1=1"}}}',
 14, 60, ARRAY['SPONSORED_PRODUCTS'], ARRAY['AMAZON_BR']),

(NULL, 'MC_ZANOM_Q030 — Campanha automática: mineração de termos', 'MC_ZANOM_Q030',
 'O que a campanha automática descobriu que vale levar para manual?',
 'KEYWORD_HARVEST',
 'Extrair search terms com conversão de auto campaigns para promover a manual EXACT/PHRASE.',
 $SQL$
SELECT ac.auto_campaign_id, st.search_term, st.targeting_clause,
    SUM(st.spend) AS spend, SUM(st.clicks) AS clicks,
    COALESCE(SUM(a.orders),0) AS orders, COALESCE(SUM(a.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(st.spend),0)) AS roas,
    COALESCE(SUM(a.orders_assisted),0) AS assisted_orders,
    CASE WHEN COALESCE(SUM(a.orders),0) >= 1 AND SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(st.spend),0)) >= {{target_roas}}
         THEN 'PROMOTE_TO_MANUAL_EXACT'
         WHEN COALESCE(SUM(a.orders),0) >= 1 THEN 'PROMOTE_TO_MANUAL_PHRASE'
         WHEN SUM(st.spend) >= {{min_spend}} AND COALESCE(SUM(a.orders),0)=0 THEN 'NEGATIVE_IN_AUTO'
         ELSE 'WATCH' END AS decision
FROM auto_campaign_report ac
JOIN search_term_report st ON ac.auto_campaign_id = st.campaign_id
LEFT JOIN amc_attributed_purchases a ON st.search_term = a.search_term AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE st.date BETWEEN {{period_start}} AND {{period_end}}
GROUP BY ac.auto_campaign_id, st.search_term, st.targeting_clause
ORDER BY orders DESC, roas DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"min_spend":{"type":"number","default":15.0}}}',
 7, 60, ARRAY['SPONSORED_PRODUCTS'], ARRAY['AMAZON_BR']),

(NULL, 'MC_ZANOM_Q031 — Campanha manual: termo vazando', 'MC_ZANOM_Q031',
 'Minha campanha ampla/frase está capturando termo que deveria estar na exata?',
 'KEYWORD_HARVEST',
 'Detectar search terms convertendo via BROAD/PHRASE que já deveriam ter campanha EXACT dedicada.',
 $SQL$
SELECT st.search_term, st.campaign_id AS source_campaign, st.match_type AS source_match_type,
    CASE WHEN ec.campaign_id IS NOT NULL THEN TRUE ELSE FALSE END AS exact_campaign_exists,
    COALESCE(SUM(a.orders),0) AS orders, COALESCE(SUM(a.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(st.spend),0)) AS roas,
    CASE WHEN ec.campaign_id IS NULL AND COALESCE(SUM(a.orders),0) >= 1 THEN 'MOVE_TO_EXACT'
         WHEN ec.campaign_id IS NOT NULL THEN 'ALREADY_EXACT_EXISTS'
         ELSE 'WATCH' END AS decision
FROM search_term_report st
LEFT JOIN amc_attributed_purchases a ON st.search_term = a.search_term AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN (SELECT DISTINCT keyword_text, campaign_id FROM keyword_traffic_report WHERE match_type='EXACT') ec
    ON LOWER(st.search_term) = LOWER(ec.keyword_text)
WHERE st.date BETWEEN {{period_start}} AND {{period_end}}
  AND st.match_type IN ('BROAD','PHRASE')
  AND COALESCE((SELECT SUM(orders) FROM amc_attributed_purchases WHERE search_term=st.search_term),0) >= 1
GROUP BY st.search_term, st.campaign_id, st.match_type, exact_campaign_exists, ec.campaign_id
ORDER BY orders DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"}}}',
 14, 60, ARRAY['SPONSORED_PRODUCTS'], ARRAY['AMAZON_BR']),

(NULL, 'MC_ZANOM_Q032 — Produto com clique bom e página ruim', 'MC_ZANOM_Q032',
 'O anúncio atrai clique, mas a página não converte?',
 'PRODUCT_INTEL',
 'Alta CTR + baixa CVR = problema de página. Diagnóstico: imagem, preço, reviews, título.',
 $SQL$
SELECT p.asin, {{product_group_label}} AS product_group, t.campaign_id,
    SAFE_DIVIDE(SUM(t.clicks), NULLIF(SUM(t.impressions),0)) AS ctr,
    SAFE_DIVIDE(SUM(t.spend), NULLIF(SUM(t.clicks),0)) AS cpc,
    SUM(br.sessions) AS sessions, COALESCE(SUM(a.orders),0) AS orders,
    SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(br.sessions),0)) AS conversion_rate,
    0.10 AS benchmark_conversion,
    CASE WHEN SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(br.sessions),0)) < 0.05
         AND SUM(t.clicks) >= 15 THEN 'REVIEW_PAGE'
         ELSE 'OK' END AS decision
FROM sponsored_ads_traffic_report t
JOIN product_metrics p ON t.campaign_id = p.campaign_id
LEFT JOIN business_report br ON p.asin = br.asin AND br.date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN amc_attributed_purchases a ON t.campaign_id = a.campaign_id AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE t.date BETWEEN {{period_start}} AND {{period_end}} {{campaign_filter}}
GROUP BY p.asin, product_group, t.campaign_id
HAVING SUM(t.clicks) >= 10
ORDER BY conversion_rate ASC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 7, 60, ARRAY['SPONSORED_PRODUCTS'], ARRAY['AMAZON_BR']),

(NULL, 'MC_ZANOM_Q033 — Variação kit vs unitário', 'MC_ZANOM_Q033',
 'Kit vende melhor que unitário?',
 'PRODUCT_INTEL',
 'Comparar performance entre variações de produto: kit 2x vs unit, ticket, margem e conversão.',
 $SQL$
SELECT pv.parent_asin, pv.child_asin, pv.variation_type,
    SUM(br.sessions) AS sessions, COALESCE(SUM(a.orders),0) AS orders,
    COALESCE(SUM(a.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(br.sessions),0)) AS conversion_rate,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(COALESCE(SUM(a.orders),1),0)) AS avg_ticket,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) AS roas,
    CASE WHEN pv.variation_type='KIT' AND SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(br.sessions),0)) >
              (SELECT SAFE_DIVIDE(COALESCE(SUM(a2.orders),0), NULLIF(SUM(br2.sessions),0))
               FROM product_variations pv2 JOIN business_report br2 ON pv2.child_asin=br2.asin
               LEFT JOIN amc_attributed_purchases a2 ON pv2.child_asin=a2.purchased_asin
               WHERE pv2.parent_asin=pv.parent_asin AND pv2.variation_type='UNIT')
         THEN 'PRIORITIZE_KIT'
         ELSE 'MONITOR' END AS decision
FROM product_variations pv
JOIN business_report br ON pv.child_asin = br.asin AND br.date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN sponsored_ads_traffic_report t ON pv.campaign_id = t.campaign_id AND t.date BETWEEN {{period_start}} AND {{period_end}}
LEFT JOIN amc_attributed_purchases a ON pv.child_asin = a.purchased_asin AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE pv.parent_asin IN ({{zanom_parent_asins}})
GROUP BY pv.parent_asin, pv.child_asin, pv.variation_type
ORDER BY roas DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"zanom_parent_asins":{"type":"string","default":"\"B0H2NL3S6T\""}}}',
 14, 90, ARRAY['SPONSORED_PRODUCTS'], ARRAY['AMAZON_BR']),

(NULL, 'MC_ZANOM_Q036 — Campanha por intenção de uso', 'MC_ZANOM_Q036',
 'Qual intenção de uso converte melhor?',
 'KEYWORD_ROLE',
 'Agrupar search terms por cluster de intenção e comparar ROAS: mala, chave, cachorro, cozinha etc.',
 $SQL$
SELECT
    CASE
        WHEN LOWER(st.search_term) LIKE '%mala%' OR LOWER(st.search_term) LIKE '%bagagem%' THEN 'localizador_mala'
        WHEN LOWER(st.search_term) LIKE '%chave%' OR LOWER(st.search_term) LIKE '%chaveiro%' THEN 'localizador_chave'
        WHEN LOWER(st.search_term) LIKE '%cachorro%' OR LOWER(st.search_term) LIKE '%pet%' THEN 'localizador_pet'
        WHEN LOWER(st.search_term) LIKE '%carteira%' OR LOWER(st.search_term) LIKE '%wallet%' THEN 'localizador_carteira'
        WHEN LOWER(st.search_term) LIKE '%air fryer%' THEN 'forma_air_fryer'
        WHEN LOWER(st.search_term) LIKE '%iphone%' OR LOWER(st.search_term) LIKE '%apple%' THEN 'carregador_iphone'
        WHEN LOWER(st.search_term) LIKE '%android%' OR LOWER(st.search_term) LIKE '%samsung%' THEN 'carregador_android'
        WHEN LOWER(st.search_term) LIKE '%rapido%' OR LOWER(st.search_term) LIKE '%fast%' THEN 'carregador_rapido'
        ELSE 'outros'
    END AS intent_cluster,
    {{product_group_label}} AS product_group,
    ARRAY_AGG(DISTINCT st.search_term LIMIT 5) AS search_terms,
    SUM(st.spend) AS spend, SUM(st.clicks) AS clicks,
    COALESCE(SUM(a.orders),0) AS orders, COALESCE(SUM(a.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(st.spend),0)) AS roas,
    CASE WHEN SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(st.spend),0)) >= {{target_roas}} THEN 'SCALE_INTENT'
         WHEN SUM(st.spend) >= {{min_spend}} AND COALESCE(SUM(a.orders),0)=0 THEN 'CUT_INTENT'
         ELSE 'MONITOR' END AS decision
FROM search_term_report st
LEFT JOIN amc_attributed_purchases a ON st.search_term = a.search_term AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE st.date BETWEEN {{period_start}} AND {{period_end}} {{campaign_filter}}
GROUP BY intent_cluster, product_group
ORDER BY roas DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"min_spend":{"type":"number","default":20.0},"product_group_label":{"type":"string","default":"TODOS"},"campaign_filter":{"type":"string","default":""}}}',
 7, 60, ARRAY['SPONSORED_PRODUCTS'], ARRAY['AMAZON_BR']),

(NULL, 'MC_ZANOM_Q038 — Campanha com bom ROAS mas pouco volume', 'MC_ZANOM_Q038',
 'Qual campanha é pequena mas promissora?',
 'PRODUCT_INTEL',
 'Identificar campanhas com ROAS alto mas budget limitado — oportunidade de crescer com cautela.',
 $SQL$
SELECT t.campaign_id, t.campaign_name,
    SUM(t.spend) AS spend, COALESCE(SUM(a.orders),0) AS orders,
    COALESCE(SUM(a.sales),0) AS sales,
    SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) AS roas,
    SAFE_DIVIDE(SUM(t.impressions), NULLIF(SUM(t.impressions)+1000000,0)) AS impression_share_proxy,
    SAFE_DIVIDE(SUM(t.spend), NULLIF(AVG(t.daily_budget),0)) AS budget_usage,
    CASE WHEN SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) >= {{target_roas}} * 1.5
         AND SUM(t.spend) < 100 THEN 'HIGH_GROWTH_OPPORTUNITY'
         WHEN SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) >= {{target_roas}}
         AND SUM(t.spend) < 200 THEN 'MODERATE_GROWTH'
         ELSE 'OK' END AS growth_opportunity
FROM sponsored_ads_traffic_report t
LEFT JOIN amc_attributed_purchases a ON t.campaign_id = a.campaign_id AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE t.date BETWEEN {{period_start}} AND {{period_end}} {{campaign_filter}}
GROUP BY t.campaign_id, t.campaign_name
HAVING SAFE_DIVIDE(COALESCE(SUM(a.sales),0), NULLIF(SUM(t.spend),0)) >= {{target_roas}}
   AND SUM(t.spend) < 500
ORDER BY roas DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"target_roas":{"type":"number","default":5.0},"campaign_filter":{"type":"string","default":""}}}',
 7, 30, ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'], ARRAY['AMAZON_BR']),

(NULL, 'MC_ZANOM_Q039 — Campanha com muito clique e baixa conversão', 'MC_ZANOM_Q039',
 'A campanha chama atenção mas não vende?',
 'PRODUCT_INTEL',
 'Alta CTR de campanha + baixa CVR = problema de oferta ou landing page.',
 $SQL$
SELECT t.campaign_id, t.campaign_name,
    SAFE_DIVIDE(SUM(t.clicks), NULLIF(SUM(t.impressions),0)) AS ctr,
    SUM(t.clicks) AS clicks, SUM(t.spend) AS spend,
    COALESCE(SUM(a.orders),0) AS orders,
    SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.clicks),0)) AS conversion_rate,
    CASE WHEN SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.clicks),0)) < 0.005
         AND SUM(t.clicks) >= 30 THEN 'REVIEW_OFFER'
         WHEN SAFE_DIVIDE(COALESCE(SUM(a.orders),0), NULLIF(SUM(t.clicks),0)) < 0.01
         AND SUM(t.clicks) >= 50 THEN 'REVIEW_BID_INTENT'
         ELSE 'OK' END AS decision
FROM sponsored_ads_traffic_report t
LEFT JOIN amc_attributed_purchases a ON t.campaign_id = a.campaign_id AND a.purchase_date BETWEEN {{period_start}} AND {{period_end}}
WHERE t.date BETWEEN {{period_start}} AND {{period_end}} {{campaign_filter}}
GROUP BY t.campaign_id, t.campaign_name
HAVING SUM(t.clicks) >= 20
ORDER BY ctr DESC, conversion_rate ASC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"campaign_filter":{"type":"string","default":""}}}',
 7, 30, ARRAY['SPONSORED_PRODUCTS'], ARRAY['AMAZON_BR'])

ON CONFLICT (code, version) DO NOTHING;
