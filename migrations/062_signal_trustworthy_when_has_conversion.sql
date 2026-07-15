-- =====================================================================
-- Refina a camada canônica (§44): a maturidade por data (<= hoje-7) é um PROXY
-- para "atribuição fechou" — correto pro AMS (que leva 7d). MAS quando o dado
-- vem de um relatório de console (CSV) com "pedidos de 7 dias" JÁ atribuídos, a
-- conversão é usável na hora, mesmo em data recente.
--
-- Fix: conversion_trustworthy = data madura OU já tem conversão real (>0). Assim
-- as conversões recentes carregadas por CSV (ex.: 08-13) entram no ML; e células
-- frescas com 0 (AMS ainda em atribuição) seguem não-confiáveis.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.gold_hourly_signal_unified AS
SELECT
    h.data_date,
    h.event_hour,
    h.campaign_name,
    h.campaign_status,
    h.impressions,
    h.clicks,
    h.spend,
    CASE WHEN h.clicks > 0 THEN ROUND((h.spend / h.clicks)::numeric, 4) END AS cpc,
    h.orders_7d,
    h.sales_7d,
    h.roas,
    CASE WHEN ams.campaign_id IS NOT NULL THEN 'AMS_STREAM' ELSE 'REPORTING' END AS traffic_source,
    ams.traffic_last_update,
    CASE
        WHEN ams.traffic_last_update IS NULL                       THEN 'REPORTING'
        WHEN ams.traffic_last_update > NOW() - INTERVAL '3 hours'  THEN 'FRESH'
        WHEN ams.traffic_last_update > NOW() - INTERVAL '24 hours' THEN 'RECENT'
        ELSE 'STALE'
    END AS traffic_freshness,
    CASE
        WHEN COALESCE(h.orders_7d,0) > 0 OR COALESCE(h.sales_7d,0) > 0 THEN 'SETTLED'
        WHEN h.data_date <= CURRENT_DATE - 7 THEN 'MATURE'
        WHEN h.data_date <= CURRENT_DATE - 1 THEN 'MATURING'
        ELSE 'IMMATURE'
    END AS conversion_maturity,
    -- CONFIÁVEL: já atribuiu (>=7d) OU já tem conversão real (CSV/reporting atribuído)
    (h.data_date <= CURRENT_DATE - 7 OR COALESCE(h.orders_7d,0) > 0 OR COALESCE(h.sales_7d,0) > 0) AS conversion_trustworthy,
    CASE
        WHEN h.data_date > CURRENT_DATE - 7 AND COALESCE(h.orders_7d,0) = 0 AND COALESCE(h.sales_7d,0) = 0
            THEN 'CONVERSAO_IMATURA: roas/orders ainda em atribuicao; NAO ler 0 como ruim'
        WHEN COALESCE(h.orders_7d,0) > 0 OR COALESCE(h.sales_7d,0) > 0
            THEN 'CONVERSAO_ATRIBUIDA: pedido/venda real'
        WHEN ams.campaign_id IS NULL
            THEN 'REPORTING/CSV: fonte madura de referencia'
        ELSE 'OK'
    END AS signal_note
FROM marketcloud_bronze.bronze_amazon_ads_hourly h
LEFT JOIN LATERAL (
    SELECT a.campaign_id, MAX(a.last_traffic_at) AS traffic_last_update
    FROM marketcloud_bronze.bronze_ams_hourly a
    JOIN marketcloud_bronze.bronze_swarm_campaign_names n ON n.campaign_id = a.campaign_id
    WHERE LOWER(TRIM(n.campaign_name)) = LOWER(TRIM(h.campaign_name))
      AND a.data_date  = h.data_date
      AND a.event_hour = h.event_hour
    GROUP BY a.campaign_id
    LIMIT 1
) ams ON TRUE;
