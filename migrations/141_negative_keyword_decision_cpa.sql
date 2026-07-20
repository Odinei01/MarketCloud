-- 141 - Regra padrao de negativacao por CPA-alvo (comportamento do robo).
--
-- Pedido do dono: keyword/termo com gasto sem venda deve ser negativado
-- automaticamente. Decisao (respondida): limiar = 1,5x o CPA-ALVO da campanha
-- (escala por produto), NAO um valor fixo. Baixo-ROAS-com-venda NAO e negativado
-- aqui (fica pro bid robot reduzir lance — "bid-down primeiro").
--
-- CPA-alvo por campanha = AOV da campanha / min_roas da campanha.
-- Negativa se: sales=0 AND clicks>=5 (confianca) AND spend >= 1,5*CPA-alvo
--   AND termo nao e da marca (zanom). EXACT se 5-7 cliques, PHRASE se >=8.
-- Esta VIEW e so a REGRA (deterministica). O executor (criar negativo via
-- SP-API) e gated aos 2 pilotos como o resto — proximo passo.

CREATE OR REPLACE VIEW marketcloud_gold.gold_negative_keyword_decisions_v1 AS
WITH cfg AS (
    SELECT campaign_id, MAX(min_roas) AS min_roas
    FROM marketcloud_gold.full_control_effective_governance_v1
    WHERE COALESCE(campaign_id, '') <> '' AND min_roas > 0
    GROUP BY campaign_id
), camp_aov AS (
    SELECT campaign_id,
           CASE WHEN SUM(orders) > 0 THEN SUM(sales) / SUM(orders) END AS aov
    FROM marketcloud_silver.silver_search_term_daily
    WHERE COALESCE(campaign_id, '') <> ''
    GROUP BY campaign_id
), term AS (
    SELECT s.campaign_id, s.campaign_name,
           lower(TRIM(s.customer_search_term)) AS search_term,
           SUM(s.clicks) AS clicks, SUM(s.spend) AS spend,
           SUM(s.orders) AS orders, SUM(s.sales) AS sales
    FROM marketcloud_silver.silver_search_term_daily s
    WHERE COALESCE(NULLIF(TRIM(s.customer_search_term), ''), '') <> ''
    GROUP BY s.campaign_id, s.campaign_name, lower(TRIM(s.customer_search_term))
)
SELECT
    t.campaign_id, t.campaign_name, t.search_term,
    t.clicks, t.spend, t.orders, t.sales,
    CASE WHEN t.spend > 0 THEN t.sales / t.spend ELSE 0 END AS roas,
    COALESCE(c.min_roas, 3.0) AS min_roas_used,
    COALESCE(a.aov, 40.0) AS aov_used,
    (COALESCE(a.aov, 40.0) / COALESCE(c.min_roas, 3.0)) AS target_cpa,
    (1.5 * COALESCE(a.aov, 40.0) / COALESCE(c.min_roas, 3.0)) AS negate_spend_threshold,
    CASE
        WHEN t.search_term LIKE '%zanom%' THEN NULL          -- nunca negativar marca
        WHEN t.sales = 0 AND t.clicks >= 5
             AND t.spend >= (1.5 * COALESCE(a.aov, 40.0) / COALESCE(c.min_roas, 3.0))
            THEN CASE WHEN t.clicks >= 8 THEN 'ADD_NEGATIVE_PHRASE'
                      ELSE 'ADD_NEGATIVE_EXACT' END
        ELSE NULL
    END AS decision,
    CASE
        WHEN t.sales = 0 AND t.clicks >= 5
             AND t.spend >= (1.5 * COALESCE(a.aov, 40.0) / COALESCE(c.min_roas, 3.0))
            THEN 'gasto R$ ' || ROUND(t.spend, 2) || ' sem venda em ' || t.clicks
                 || ' cliques (limiar 1,5x CPA-alvo R$ '
                 || ROUND(1.5 * COALESCE(a.aov, 40.0) / COALESCE(c.min_roas, 3.0), 2) || ')'
    END AS decision_reason
FROM term t
    LEFT JOIN cfg c ON c.campaign_id = t.campaign_id
    LEFT JOIN camp_aov a ON a.campaign_id = t.campaign_id;
