-- =====================================================================
-- Validação grão-a-grão: cada extrato vs AMC
--
-- Como usar (para cada extrato):
--   (A) rode a query GRÃO no console do AMC, some a coluna `orders`.
--       Deve bater com o "nosso bronze" indicado (prova de ingestão fiel).
--   (B) rode a query COARSE (mesmos filtros, agrupada só por dia), some
--       `orders`. Mostra o total real daquele escopo, sem supressão.
--   Diferença (B) - (A) = supressão do AMC naquele grão.
--
-- Referência do nosso bronze (janela 31/05..06/07):
--   E013 daily total ........ 213   (baseline coarse, sem supressão)
--   E001 campaign ........... 150
--   E009 unified (conv) ...... 60
--   E008 NTB halo ............ 60
--   E004 hourly .............. 51
--   E002 target ............... 8
--   E003 search term .......... 3
--   E005 product ASIN ......... 0   (filtro tracked_asin — ver E005 abaixo)
--
-- Ajuste o time window do workflow AMC para 2026-05-31 .. 2026-07-07.
-- =====================================================================


-- ─────────────────────────────────────────────────────────────────────
-- E001 — Campaign daily  (deve somar ~150; coarse ~213)
-- ─────────────────────────────────────────────────────────────────────
-- GRÃO:
SELECT conversion_event_date, campaign_id, ad_product_type,
       SUM(total_purchases) AS orders, SUM(total_product_sales) AS sales
FROM amazon_attributed_events_by_conversion_time
WHERE conversion_event_date IS NOT NULL AND campaign_id IS NOT NULL
GROUP BY conversion_event_date, campaign_id, ad_product_type;
-- COARSE (mesmo escopo, só por dia):
SELECT conversion_event_date,
       SUM(total_purchases) AS orders
FROM amazon_attributed_events_by_conversion_time
WHERE conversion_event_date IS NOT NULL AND campaign_id IS NOT NULL
GROUP BY conversion_event_date;


-- ─────────────────────────────────────────────────────────────────────
-- E002 — Target daily  (deve somar ~8)
-- Escopo: só conversões COM targeting (por isso é subconjunto).
-- ─────────────────────────────────────────────────────────────────────
SELECT conversion_event_date, campaign_id, ad_product_type, targeting, match_type,
       SUM(total_purchases) AS orders
FROM amazon_attributed_events_by_conversion_time
WHERE conversion_event_date IS NOT NULL AND campaign_id IS NOT NULL
  AND targeting IS NOT NULL
GROUP BY conversion_event_date, campaign_id, ad_product_type, targeting, match_type;
-- COARSE do escopo "com targeting":
SELECT conversion_event_date, SUM(total_purchases) AS orders
FROM amazon_attributed_events_by_conversion_time
WHERE conversion_event_date IS NOT NULL AND campaign_id IS NOT NULL AND targeting IS NOT NULL
GROUP BY conversion_event_date;


-- ─────────────────────────────────────────────────────────────────────
-- E003 — Search term daily  (deve somar ~3)
-- Escopo: só conversões COM targeting E customer_search_term.
-- ─────────────────────────────────────────────────────────────────────
SELECT conversion_event_date, campaign_id, ad_product_type, targeting, match_type,
       customer_search_term,
       SUM(total_purchases) AS orders
FROM amazon_attributed_events_by_conversion_time
WHERE conversion_event_date IS NOT NULL AND campaign_id IS NOT NULL
  AND targeting IS NOT NULL AND customer_search_term IS NOT NULL
GROUP BY conversion_event_date, campaign_id, ad_product_type, targeting, match_type,
         customer_search_term;
-- COARSE do escopo "com search term":
SELECT conversion_event_date, SUM(total_purchases) AS orders
FROM amazon_attributed_events_by_conversion_time
WHERE conversion_event_date IS NOT NULL AND campaign_id IS NOT NULL
  AND targeting IS NOT NULL AND customer_search_term IS NOT NULL
GROUP BY conversion_event_date;


-- ─────────────────────────────────────────────────────────────────────
-- E004 — Hourly performance  (deve somar ~51)  ATENÇÃO: TRAFFIC-TIME
-- Compare com E006/E009-traffic (mesma lente), NÃO com E001/E013.
-- ─────────────────────────────────────────────────────────────────────
SELECT traffic_event_date, traffic_event_hour, campaign_id, ad_product_type,
       SUM(total_purchases) AS orders, SUM(total_product_sales) AS sales
FROM amazon_attributed_events_by_traffic_time
WHERE traffic_event_date IS NOT NULL AND campaign_id IS NOT NULL
GROUP BY traffic_event_date, traffic_event_hour, campaign_id, ad_product_type;
-- COARSE traffic-time (só por dia) — teto do E004:
SELECT traffic_event_date, SUM(total_purchases) AS orders
FROM amazon_attributed_events_by_traffic_time
WHERE traffic_event_date IS NOT NULL AND campaign_id IS NOT NULL
GROUP BY traffic_event_date;


-- ─────────────────────────────────────────────────────────────────────
-- E005 — Product ASIN daily  (nosso bronze = 0 — investigar)
-- Escopo: exige tracked_asin IS NOT NULL. Rode a query 1 e a 2:
--   se query 2 (sem tracked_asin) >> query 1, o filtro tracked_asin
--   está zerando o extrato -> bug de escopo a corrigir.
-- ─────────────────────────────────────────────────────────────────────
-- (1) com o filtro atual do extrato:
SELECT conversion_event_date, campaign_id, ad_product_type, tracked_asin,
       SUM(total_purchases) AS orders
FROM amazon_attributed_events_by_conversion_time
WHERE conversion_event_date IS NOT NULL AND campaign_id IS NOT NULL
  AND ad_product_type IS NOT NULL AND tracked_asin IS NOT NULL
GROUP BY conversion_event_date, campaign_id, ad_product_type, tracked_asin;
-- (2) SEM o filtro tracked_asin (diagnóstico):
SELECT COUNT(*) AS linhas_com_asin_nulo, SUM(total_purchases) AS orders_com_asin_nulo
FROM amazon_attributed_events_by_conversion_time
WHERE conversion_event_date IS NOT NULL AND campaign_id IS NOT NULL
  AND tracked_asin IS NULL;


-- ─────────────────────────────────────────────────────────────────────
-- E008 — New-to-Brand / Halo  (deve somar ~60 em orders totais)
-- Métricas próprias: new_to_brand_purchases, brand_halo_purchases.
-- ─────────────────────────────────────────────────────────────────────
SELECT conversion_event_date, campaign_id, ad_product_type, tracked_asin,
       SUM(total_purchases)          AS orders,
       SUM(new_to_brand_purchases)   AS ntb_orders,
       SUM(brand_halo_purchases)     AS halo_orders
FROM amazon_attributed_events_by_conversion_time
WHERE conversion_event_date IS NOT NULL AND campaign_id IS NOT NULL
  AND tracked_asin IS NOT NULL
GROUP BY conversion_event_date, campaign_id, ad_product_type, tracked_asin;


-- ─────────────────────────────────────────────────────────────────────
-- E009 — Conversions unified  (conv-time ~60 ; traffic-time ~57)
-- Duas lentes; rode as duas.
-- ─────────────────────────────────────────────────────────────────────
-- conversion-time:
SELECT conversion_event_date, campaign_id, ad_product_type, targeting, match_type,
       customer_search_term, tracked_asin,
       SUM(total_purchases) AS orders
FROM amazon_attributed_events_by_conversion_time
WHERE conversion_event_date IS NOT NULL AND campaign_id IS NOT NULL AND ad_product_type IS NOT NULL
GROUP BY conversion_event_date, campaign_id, ad_product_type, targeting, match_type,
         customer_search_term, tracked_asin;
-- traffic-time:
SELECT traffic_event_date, campaign_id, ad_product_type,
       SUM(total_purchases) AS orders
FROM amazon_attributed_events_by_traffic_time
WHERE traffic_event_date IS NOT NULL AND campaign_id IS NOT NULL AND ad_product_type IS NOT NULL
GROUP BY traffic_event_date, campaign_id, ad_product_type;


-- ─────────────────────────────────────────────────────────────────────
-- E013 — Conversions daily total  (deve somar ~213/219 — JÁ VALIDADO)
-- ─────────────────────────────────────────────────────────────────────
SELECT conversion_event_date, SUM(total_purchases) AS orders, SUM(total_product_sales) AS sales
FROM amazon_attributed_events_by_conversion_time
WHERE conversion_event_date IS NOT NULL
GROUP BY conversion_event_date;
