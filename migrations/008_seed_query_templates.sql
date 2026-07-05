-- Migration 008: seed global query templates (Phase 1 priorities)

INSERT INTO query_templates (
    tenant_id, name, code, description, query_family, query_goal,
    sql_template, parameters_schema, min_lookback_days, max_lookback_days,
    supported_campaign_types, supported_marketplaces
) VALUES

-- ASSISTED_CONVERSIONS
(NULL,
 'Assisted Conversions',
 'ASSISTED_CONVERSIONS',
 'Identifica quais campanhas assistem conversões mesmo com ROAS direto baixo.',
 'ASSISTED_CONVERSIONS',
 'Classificar papel de cada campanha: DISCOVERY, CONVERSION, ASSISTED_CONVERSION, WASTE.',
 $SQL$
SELECT
    campaign_id,
    campaign_name,
    COUNT(DISTINCT CASE WHEN touchpoint_position = 'LAST' AND conversion = 1 THEN user_id END) AS direct_conversions,
    COUNT(DISTINCT CASE WHEN touchpoint_position != 'LAST' AND path_had_conversion = 1 THEN user_id END) AS assisted_conversions,
    SUM(CASE WHEN touchpoint_position = 'LAST' AND conversion = 1 THEN purchase_value ELSE 0 END) AS direct_sales,
    SUM(CASE WHEN touchpoint_position != 'LAST' AND path_had_conversion = 1 THEN attributed_value ELSE 0 END) AS assisted_sales,
    SUM(spend) AS total_spend,
    MIN(impression_date) AS period_start,
    MAX(impression_date) AS period_end
FROM amc_path_to_purchase
WHERE impression_date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY campaign_id, campaign_name
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"campaign_ids":{"type":"array","items":{"type":"string"}},"asin":{"type":"string"},"target_roas":{"type":"number","default":4.0}}}',
 7, 90,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

-- PATH_TO_PURCHASE
(NULL,
 'Path to Purchase',
 'PATH_TO_PURCHASE',
 'Mostra a sequência de campanhas que aparece antes da compra.',
 'PATH_TO_PURCHASE',
 'Entender a jornada completa do comprador: primeiro toque, intermediário, fechamento.',
 $SQL$
SELECT
    path,
    COUNT(DISTINCT path_id) AS paths_count,
    COUNT(DISTINCT user_id) AS users,
    SUM(conversions) AS conversions,
    SAFE_DIVIDE(SUM(conversions), COUNT(DISTINCT user_id)) AS conversion_rate,
    SUM(purchase_value) AS sales,
    AVG(days_to_purchase) AS avg_days_to_purchase
FROM amc_paths
WHERE purchase_date BETWEEN {{period_start}} AND {{period_end}}
GROUP BY path
ORDER BY conversions DESC
LIMIT 50
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"campaign_ids":{"type":"array","items":{"type":"string"}},"min_touchpoints":{"type":"integer","default":1}}}',
 14, 90,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

-- FREQUENCY_ANALYSIS
(NULL,
 'Frequency Analysis',
 'FREQUENCY_ANALYSIS',
 'Identifica qual frequência de exposição gera melhor conversão.',
 'FREQUENCY_ANALYSIS',
 'Detectar saturação de frequência e frequência ótima por campanha.',
 $SQL$
SELECT
    frequency_bucket,
    COUNT(DISTINCT user_id) AS users,
    SUM(conversions) AS conversions,
    SAFE_DIVIDE(SUM(conversions), COUNT(DISTINCT user_id)) AS conversion_rate,
    SUM(purchase_value) AS sales,
    SUM(spend) AS spend,
    SAFE_DIVIDE(SUM(purchase_value), NULLIF(SUM(spend), 0)) AS roas
FROM amc_frequency
WHERE exposure_date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY frequency_bucket
ORDER BY frequency_bucket ASC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"campaign_ids":{"type":"array","items":{"type":"string"}}}}',
 7, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

-- REMARKETING_POOL
(NULL,
 'Remarketing Pool',
 'REMARKETING_POOL',
 'Identifica públicos que demonstraram interesse mas ainda não compraram.',
 'REMARKETING_POOL',
 'Criar pool de remarketing com score de prioridade por recência e engajamento.',
 $SQL$
SELECT
    segment_type,
    COUNT(DISTINCT user_id) AS estimated_size,
    recency_window,
    engagement_type,
    AVG(engagement_score) AS avg_engagement_score
FROM amc_intent_signals
WHERE signal_date BETWEEN {{period_start}} AND {{period_end}}
  AND converted = 0
GROUP BY segment_type, recency_window, engagement_type
ORDER BY avg_engagement_score DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"recency_window_days":{"type":"integer","default":30}}}',
 7, 60,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_DISPLAY'],
 ARRAY['AMAZON_BR']
),

-- KEYWORD_ROLE
(NULL,
 'Keyword Role',
 'KEYWORD_ROLE',
 'Classifica cada keyword como descoberta, consideração ou fechamento.',
 'KEYWORD_ROLE',
 'Identificar keywords de topo de funil vs fundo de funil.',
 $SQL$
SELECT
    keyword,
    match_type,
    COUNT(DISTINCT CASE WHEN touchpoint_position = 'FIRST' THEN user_id END) AS first_touch_users,
    COUNT(DISTINCT CASE WHEN touchpoint_position = 'MIDDLE' THEN user_id END) AS middle_touch_users,
    COUNT(DISTINCT CASE WHEN touchpoint_position = 'LAST' THEN user_id END) AS last_touch_users,
    COUNT(DISTINCT user_id) AS total_users,
    SUM(CASE WHEN touchpoint_position = 'LAST' AND conversion = 1 THEN purchase_value ELSE 0 END) AS direct_sales,
    SUM(spend) AS spend
FROM amc_keyword_paths
WHERE impression_date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY keyword, match_type
HAVING COUNT(DISTINCT user_id) >= 5
ORDER BY total_users DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"campaign_ids":{"type":"array","items":{"type":"string"}},"min_users":{"type":"integer","default":5}}}',
 14, 90,
 ARRAY['SPONSORED_PRODUCTS'],
 ARRAY['AMAZON_BR']
),

-- ASIN_CROSS_SELL
(NULL,
 'ASIN Cross-Sell',
 'ASIN_CROSS_SELL',
 'Identifica quais ASINs se ajudam mutuamente.',
 'ASIN_CROSS_SELL',
 'Descobrir oportunidades de cross-sell entre produtos.',
 $SQL$
SELECT
    source_asin,
    target_asin,
    COUNT(DISTINCT user_id) AS overlap_users,
    SAFE_DIVIDE(
        COUNT(DISTINCT CASE WHEN purchased_both = 1 THEN user_id END),
        COUNT(DISTINCT user_id)
    ) AS cross_purchase_rate
FROM amc_asin_overlap
WHERE purchase_date BETWEEN {{period_start}} AND {{period_end}}
  {{asin_filter}}
GROUP BY source_asin, target_asin
HAVING COUNT(DISTINCT user_id) >= 10
ORDER BY cross_purchase_rate DESC
$SQL$,
 '{"type":"object","properties":{"period_start":{"type":"string","format":"date"},"period_end":{"type":"string","format":"date"},"asin":{"type":"string"},"min_overlap_users":{"type":"integer","default":10}}}',
 30, 90,
 ARRAY['SPONSORED_PRODUCTS','SPONSORED_BRANDS'],
 ARRAY['AMAZON_BR']
);
