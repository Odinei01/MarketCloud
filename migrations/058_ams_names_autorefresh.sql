-- =====================================================================
-- Torna o resolve de nomes (057) DURÁVEL e SEGURO:
--  1) refresh_swarm_campaign_names(): UPSERT em vez de TRUNCATE+INSERT — um
--     tropeço do fdw não apaga mais o mapa inteiro (antes: truncava e, se o
--     INSERT do fdw falhasse, ficava vazio -> unresolved explodia).
--  2) refresh_ams_to_hourly(): auto-refresh do mapa se estiver >1h stale
--     (cobre campanha nova tipo m19 autopilot sem precisar de deploy), dentro de
--     bloco EXCEPTION — fdw fora NÃO derruba a reconciliação. Como a
--     reconciliação roda de hora em hora (orchestrator) e a cada msg (consumidor),
--     o mapa se mantém fresco sozinho.
-- =====================================================================

CREATE OR REPLACE FUNCTION marketcloud_bronze.refresh_swarm_campaign_names()
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE n BIGINT;
BEGIN
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
    ) latest
    ON CONFLICT (campaign_id) DO UPDATE SET
        campaign_name = EXCLUDED.campaign_name,
        updated_at    = NOW();
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

CREATE OR REPLACE FUNCTION marketcloud_bronze.refresh_ams_to_hourly()
RETURNS TABLE(rows_upserted bigint, rows_unresolved bigint)
LANGUAGE plpgsql AS $$
DECLARE up BIGINT; un BIGINT;
BEGIN
    -- auto-refresh do mapa de nomes se >1h stale; fdw fora não derruba nada.
    IF NOT EXISTS (
        SELECT 1 FROM marketcloud_bronze.bronze_swarm_campaign_names
        WHERE updated_at > NOW() - INTERVAL '1 hour'
    ) THEN
        BEGIN
            PERFORM marketcloud_bronze.refresh_swarm_campaign_names();
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'refresh_swarm_campaign_names falhou (fdw?): %', SQLERRM;
        END;
    END IF;

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
