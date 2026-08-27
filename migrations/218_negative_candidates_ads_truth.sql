-- 218: repõe o motor de negativação sobre o relatório de Ads, não sobre o AMC.
--
-- ACHADO QUE MOTIVOU: mais da METADE do que o robô mandaria negativar, vende.
-- Medido em 26/08 sobre os 85 candidatos acionáveis da conta: 43 têm venda no
-- relatório de Ads (R$4.319,22) e o motor os classificava como "cliques sem venda".
-- Entre eles, os campeões da operação ZM19 — "cozedor de ovos eletrico 220v"
-- (R$185,15) e "parafusadeira" (R$174,89).
--
-- CAUSA RAIZ: silver_search_term_daily lê bronze_amc_search_term_daily. O AMC
-- SUPRIME linha de baixo volume, então a venda simplesmente não aparece: de 16.993
-- linhas, apenas 73 (0,43%) carregam venda. Um motor que decide por "sales = 0"
-- construído sobre uma fonte onde 99,6% das linhas têm sales = 0 não está medindo
-- venda — está medindo a supressão do AMC.
--
-- Comparando ZM19 nas duas fontes: AMC vê R$179,76 de venda; o relatório de Ads vê
-- R$1.167,44. 85% invisível.
--
-- É a mesma classe de erro já encontrada no cockpit horário, onde o AMC mostrava 25
-- de 361 horas com venda. Fonte errada, conclusão confiante, decisão cara.
--
-- DECISÃO: o relatório de Ads passa a ser a verdade para gasto, cliques e venda —
-- é nele que a Amazon cobra e atribui. O AMC continua valioso para jornada e
-- assistência, mas não pode arbitrar "esse termo não vende".
--
-- Segunda correção, aproveitando: a versão anterior agregava DESDE SEMPRE (dado
-- desde 31/05). Um termo que falhou em junho e vende hoje era julgado pelo histórico
-- inteiro. Passa a olhar janela móvel de 60 dias.

CREATE OR REPLACE VIEW marketcloud_gold.gold_negative_keyword_candidates AS
WITH term_agg AS (
  SELECT
    'zanom'::text                                   AS tenant_id,
    NULL::text                                      AS amc_instance_id,
    MAX(profile_id)                                 AS ads_profile_id,
    campaign_id,
    MAX(campaign_name)                              AS campaign_name,
    'SPONSORED_PRODUCTS'::text                      AS ad_product_type,
    search_term                                     AS customer_search_term,
    lower(btrim(search_term))                       AS search_term_normalized,
    SUM(impressions)::numeric                       AS impressions,
    SUM(clicks)::numeric                            AS clicks,
    SUM(cost)::numeric                              AS spend,
    SUM(purchases)::numeric                         AS orders,
    SUM(attributed_sales)::numeric                  AS sales,
    SUM(attributed_sales)::numeric                  AS combined_sales,
    CASE WHEN SUM(cost) > 0 THEN SUM(attributed_sales)/SUM(cost) ELSE 0 END   AS roas,
    CASE WHEN SUM(clicks) > 0 THEN SUM(cost)/SUM(clicks) ELSE 0 END           AS cpc
  FROM swarm_src.amazon_ads_search_terms_daily
  WHERE COALESCE(search_term,'') <> ''
    AND date >= CURRENT_DATE - 60
  GROUP BY campaign_id, search_term
)
SELECT
  tenant_id, amc_instance_id, ads_profile_id, campaign_id, campaign_name,
  ad_product_type, customer_search_term, search_term_normalized,
  impressions, clicks, spend, orders, sales, combined_sales, roas, cpc,
  CASE
    -- termo de marca nunca é negativado: quem busca "zanom" já quer a marca
    WHEN lower(customer_search_term) LIKE '%zanom%' THEN 'WATCH'
    -- venda em QUALQUER momento da janela protege o termo. Cliques sem venda são
    -- suspeita; venda medida é fato, e fato vence suspeita.
    WHEN sales > 0 THEN 'WATCH'
    WHEN clicks >= 8 AND sales = 0 THEN 'ADD_NEGATIVE_PHRASE'
    WHEN clicks >= 5 AND sales = 0 THEN 'ADD_NEGATIVE_EXACT'
    ELSE 'WATCH'
  END AS action_type,
  -- reason_code vem ANTES de suggested_match_type: CREATE OR REPLACE exige a mesma
  -- ordem de colunas da view existente.
  CASE
    WHEN lower(customer_search_term) LIKE '%zanom%' THEN 'PROTECTED_BRAND_TERM'
    WHEN sales > 0 THEN 'PROTECTED_HAS_SALES'
    WHEN clicks >= 8 AND sales = 0 THEN 'HIGH_CLICKS_NO_SALE'
    WHEN clicks >= 5 AND sales = 0 THEN 'CLICKS_NO_SALE'
    ELSE 'INSUFFICIENT_DATA'
  END AS reason_code,
  CASE
    WHEN lower(customer_search_term) LIKE '%zanom%' OR sales > 0 THEN 'NONE'
    WHEN clicks >= 8 AND sales = 0 THEN 'PHRASE'
    WHEN clicks >= 5 AND sales = 0 THEN 'EXACT'
    ELSE 'NONE'
  END AS suggested_match_type,
  CASE
    WHEN clicks >= 12 AND sales = 0 THEN 'ALTO'
    WHEN clicks >= 8  AND sales = 0 THEN 'MEDIO'
    ELSE 'BAIXO'
  END AS risk_level,
  -- confianca cresce com o numero de cliques sem venda: 5 cliques e suspeita,
  -- 20 e evidencia. Teto em 1 para nao prometer certeza que nao existe.
  LEAST(1.0, GREATEST(0.0, (clicks - 4) / 16.0))::numeric AS confidence_score,
  jsonb_build_object(
    'fonte', 'AMAZON_ADS_SEARCH_TERM_REPORT',
    'janela_dias', 60,
    'clicks', clicks, 'spend', spend, 'sales', sales, 'orders', orders
  ) AS evidence_json,
  NOW() AS created_at
FROM term_agg;
