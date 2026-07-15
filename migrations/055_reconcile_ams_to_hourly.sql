-- =====================================================================
-- Reconciliação: bronze_ams_hourly (Stream, chave campaign_id) ->
-- bronze_amazon_ads_hourly (Gold, chave campaign_name).
--
-- O Gold horário (051/053) lê bronze_amazon_ads_hourly por NOME. O Stream grava
-- por ID (sem name garantido). Esta migração resolve id->name e faz o Gold
-- consumir o dado do Stream sem tocar nas views do Gold.
--
-- Fonte do nome (COALESCE, em ordem): o próprio payload -> métricas de campanha
-- do SWARM -> agenda de bid. Mapeia a janela de 7d do sp-conversion para
-- orders_7d/sales_7d (o grão que o Gold usa).
--
-- Estado hoje: bronze_ams_hourly ainda VAZIO (subscription bloqueada na policy
-- da fila). Isto roda com 0 linhas — fica pronto pro dado começar a fluir.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_bronze.v_ams_hourly_resolved AS
SELECT
    a.data_date,
    a.event_hour,
    COALESCE(NULLIF(a.campaign_name, ''), m.campaign_name, s.campaign_name) AS campaign_name,
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
    SELECT campaign_name FROM marketcloud_bronze.bronze_swarm_campaign_metrics m
    WHERE m.campaign_id = a.campaign_id AND m.campaign_name IS NOT NULL
    ORDER BY m.data_date DESC LIMIT 1
) m ON TRUE
LEFT JOIN LATERAL (
    SELECT campaign_name FROM marketcloud_bronze.bronze_swarm_bid_schedule s
    WHERE s.campaign_id = a.campaign_id AND s.campaign_name IS NOT NULL
    LIMIT 1
) s ON TRUE;

-- Upsert repetível: joga o Stream (com nome resolvido) no bronze que o Gold lê.
-- Só linhas com nome resolvido (senão o Gold não casaria com a agenda por nome).
-- Retorna (linhas_gravadas, linhas_sem_nome) p/ o worker logar cobertura.
CREATE OR REPLACE FUNCTION marketcloud_bronze.refresh_ams_to_hourly()
RETURNS TABLE(rows_upserted BIGINT, rows_unresolved BIGINT)
LANGUAGE plpgsql AS $$
DECLARE
    up BIGINT;
    un BIGINT;
BEGIN
    SELECT COUNT(*) INTO un FROM marketcloud_bronze.v_ams_hourly_resolved WHERE campaign_name IS NULL;

    INSERT INTO marketcloud_bronze.bronze_amazon_ads_hourly
        (data_date, event_hour, campaign_name, impressions, clicks, spend, cpc, orders_7d, acos, roas, sales_7d)
    SELECT data_date, event_hour, campaign_name,
           impressions, clicks, spend, cpc, orders_7d, acos, roas, sales_7d
    FROM marketcloud_bronze.v_ams_hourly_resolved
    WHERE campaign_name IS NOT NULL
    ON CONFLICT (data_date, event_hour, campaign_name) DO UPDATE SET
        impressions = EXCLUDED.impressions,
        clicks      = EXCLUDED.clicks,
        spend       = EXCLUDED.spend,
        cpc         = EXCLUDED.cpc,
        orders_7d   = EXCLUDED.orders_7d,
        acos        = EXCLUDED.acos,
        roas        = EXCLUDED.roas,
        sales_7d    = EXCLUDED.sales_7d;
    GET DIAGNOSTICS up = ROW_COUNT;

    rows_upserted := up;
    rows_unresolved := un;
    RETURN NEXT;
END;
$$;
