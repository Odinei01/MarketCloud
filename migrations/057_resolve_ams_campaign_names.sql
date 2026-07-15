-- =====================================================================
-- Resolve o rows_unresolved da reconciliação AMS: campanhas novas (ex.: m19
-- autopilot do parceiro) chegam no AMS mas não estão em bronze_swarm_campaign_
-- metrics/bid_schedule (não têm métrica diária consolidada nem agenda de bid),
-- então o campaign_id não mapeava pra nome e a linha caía como "unresolved".
--
-- Fix: materializar um MAPA AMPLO campaign_id->nome (TODAS as campanhas, sem
-- filtro de status) a partir do fdw swarm_src, numa bronze LOCAL (pra o Gold não
-- depender do fdw em runtime), e usá-lo como último fallback na v_ams_hourly_resolved.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_swarm_campaign_names (
    campaign_id   TEXT PRIMARY KEY,
    campaign_name TEXT NOT NULL,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Refresh repetível (chamável pelo orchestrator no ciclo de sync). Puxa de
-- campaigns_daily (histórico amplo) + targeting_inventory (cobre campanha nova
-- sem métrica diária ainda). Último nome não-vazio vence.
CREATE OR REPLACE FUNCTION marketcloud_bronze.refresh_swarm_campaign_names()
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE n BIGINT;
BEGIN
    TRUNCATE marketcloud_bronze.bronze_swarm_campaign_names;
    INSERT INTO marketcloud_bronze.bronze_swarm_campaign_names (campaign_id, campaign_name, updated_at)
    SELECT campaign_id, campaign_name, NOW()
    FROM (
        SELECT DISTINCT ON (CAST(campaign_id AS TEXT))
               CAST(campaign_id AS TEXT) AS campaign_id, campaign_name
        FROM (
            SELECT campaign_id, campaign_name, date::timestamp AS ts
            FROM swarm_src.amazon_ads_campaigns_daily
            WHERE campaign_id IS NOT NULL AND COALESCE(NULLIF(TRIM(campaign_name),''),'') <> ''
            UNION ALL
            SELECT campaign_id, campaign_name, updated_at AS ts
            FROM swarm_src.amazon_ads_targeting_inventory
            WHERE campaign_id IS NOT NULL AND COALESCE(NULLIF(TRIM(campaign_name),''),'') <> ''
        ) u
        ORDER BY CAST(campaign_id AS TEXT), ts DESC NULLS LAST
    ) latest;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

SELECT marketcloud_bronze.refresh_swarm_campaign_names();

-- View com o 3º fallback (mapa amplo de nomes). Colunas idênticas — só muda o
-- COALESCE e entra 1 LEFT JOIN.
CREATE OR REPLACE VIEW marketcloud_bronze.v_ams_hourly_resolved AS
SELECT
    a.data_date,
    a.event_hour,
    COALESCE(NULLIF(a.campaign_name, ''), m.campaign_name, s.campaign_name, n.campaign_name) AS campaign_name,
    a.campaign_id,
    a.impressions,
    a.clicks,
    a.spend,
    a.orders_7d,
    a.sales_7d,
    CASE WHEN a.clicks  > 0 THEN a.spend / a.clicks  END AS cpc,
    CASE WHEN a.spend   > 0 THEN a.sales_7d / a.spend END AS roas,
    CASE WHEN a.sales_7d> 0 THEN a.spend / a.sales_7d END AS acos
FROM marketcloud_bronze.bronze_ams_hourly a
LEFT JOIN LATERAL (
    SELECT m_1.campaign_name FROM marketcloud_bronze.bronze_swarm_campaign_metrics m_1
    WHERE m_1.campaign_id = a.campaign_id AND m_1.campaign_name IS NOT NULL
    ORDER BY m_1.data_date DESC LIMIT 1
) m ON TRUE
LEFT JOIN LATERAL (
    SELECT s_1.campaign_name FROM marketcloud_bronze.bronze_swarm_bid_schedule s_1
    WHERE s_1.campaign_id = a.campaign_id AND s_1.campaign_name IS NOT NULL LIMIT 1
) s ON TRUE
LEFT JOIN marketcloud_bronze.bronze_swarm_campaign_names n ON n.campaign_id = a.campaign_id;
