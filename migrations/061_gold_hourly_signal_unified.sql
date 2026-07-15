-- =====================================================================
-- CAMADA CANÔNICA de sinal horário (§30, tarefa #16).
--
-- Problema que resolve: bronze_amazon_ads_hourly mistura 4 semânticas —
--   reporting/CSV maduro (conversão 7d atribuída), AMS fresco (tráfego hora-a-hora
--   mas conversão=0 por delay de atribuição), etc. Sem declarar fonte/maturidade,
--   o ML/Gold leem roas=0 de célula FRESCA como "hora ruim" e recomendam CUT —
--   quando é só conversão IMATURA. E o D-14 sobrescreve cego o dado maduro.
--
-- Esta view declara, por célula (campanha×hora×dia): a FONTE do tráfego, a
-- FRESHNESS, a MATURIDADE da conversão e se dá pra CONFIAR no ROAS/pedido.
-- Não substitui o pipeline de uma vez (adoção documentada no handoff §44); é a
-- fonte de verdade única com proveniência visível.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.gold_hourly_signal_unified AS
SELECT
    h.data_date,
    h.event_hour,
    h.campaign_name,
    h.campaign_status,
    -- ---- métricas de tráfego ----
    h.impressions,
    h.clicks,
    h.spend,
    CASE WHEN h.clicks > 0 THEN ROUND((h.spend / h.clicks)::numeric, 4) END AS cpc,
    -- ---- métricas de conversão ----
    h.orders_7d,
    h.sales_7d,
    h.roas,
    -- ---- PROVENIÊNCIA ----
    -- tráfego veio do AMS se a célula existe no landing AMS; senão é reporting/CSV
    CASE WHEN ams.campaign_id IS NOT NULL THEN 'AMS_STREAM' ELSE 'REPORTING' END AS traffic_source,
    ams.traffic_last_update,
    -- freshness do tráfego
    CASE
        WHEN ams.traffic_last_update IS NULL                                    THEN 'REPORTING'
        WHEN ams.traffic_last_update > NOW() - INTERVAL '3 hours'               THEN 'FRESH'
        WHEN ams.traffic_last_update > NOW() - INTERVAL '24 hours'              THEN 'RECENT'
        ELSE 'STALE'
    END AS traffic_freshness,
    -- maturidade da conversão (janela de atribuição 7d)
    CASE
        WHEN h.data_date <= CURRENT_DATE - 7 THEN 'MATURE'
        WHEN h.data_date <= CURRENT_DATE - 1 THEN 'MATURING'
        ELSE 'IMMATURE'
    END AS conversion_maturity,
    -- CONFIANÇA: só confie em roas/orders quando a atribuição fechou (>=7d)
    (h.data_date <= CURRENT_DATE - 7) AS conversion_trustworthy,
    -- nota honesta pra UI/ML não interpretarem errado
    CASE
        WHEN h.data_date > CURRENT_DATE - 7 AND COALESCE(h.orders_7d,0) = 0
            THEN 'CONVERSAO_IMATURA: roas/orders ainda em atribuicao; NAO ler 0 como ruim'
        WHEN ams.campaign_id IS NOT NULL AND h.data_date <= CURRENT_DATE - 7
            THEN 'MADURO: trafego AMS + conversao atribuida'
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

-- Conveniência: só o sinal de conversão CONFIÁVEL (maduro) — alvo correto p/ o ML
-- treinar pedido/ROAS sem contaminar com células frescas imaturas (roas=0 falso).
CREATE OR REPLACE VIEW marketcloud_gold.gold_hourly_signal_mature AS
SELECT * FROM marketcloud_gold.gold_hourly_signal_unified
WHERE conversion_trustworthy = TRUE;

COMMENT ON VIEW marketcloud_gold.gold_hourly_signal_unified IS
    'Camada canonica horaria (§30): metricas + traffic_source/freshness + conversion_maturity/trustworthy + signal_note. Fonte de verdade com proveniencia. ML deve treinar conversao em gold_hourly_signal_mature; D-14 nao deve sobrescrever MATURE com IMMATURE.';
