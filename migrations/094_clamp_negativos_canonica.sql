-- P1-2 da auditoria (16/07): 2 linhas negativas (impressions=-1) de reporting
-- chegavam a Gold (campanha autopilot exact, 09/07 16h e 20h). Delta de
-- transicao nao deveria virar metrica exposta. Clampa as 5 metricas cruas em
-- GREATEST(x,0) na camada canonica — protege TODOS os consumidores de Gold,
-- reporting e AMS, num lugar so.
CREATE OR REPLACE VIEW marketcloud_gold.gold_hourly_signal_unified AS
SELECT h.data_date,
    h.event_hour,
    h.campaign_name,
    h.campaign_status,
    GREATEST(h.impressions, 0)::bigint AS impressions,
    GREATEST(h.clicks, 0)::bigint AS clicks,
    GREATEST(h.spend, 0)::numeric(18,4) AS spend,
        CASE
            WHEN h.clicks > 0 THEN round(h.spend / h.clicks::numeric, 4)
            ELSE NULL::numeric
        END AS cpc,
    GREATEST(h.orders_7d, 0)::numeric(18,4) AS orders_7d,
    GREATEST(h.sales_7d, 0)::numeric(18,4) AS sales_7d,
    h.roas,
        CASE
            WHEN ams.campaign_id IS NOT NULL THEN 'AMS_STREAM'::text
            ELSE 'REPORTING'::text
        END AS traffic_source,
    ams.traffic_last_update,
        CASE
            WHEN ams.traffic_last_update IS NULL THEN 'REPORTING'::text
            WHEN ams.traffic_last_update > (now() - '03:00:00'::interval) THEN 'FRESH'::text
            WHEN ams.traffic_last_update > (now() - '24:00:00'::interval) THEN 'RECENT'::text
            ELSE 'STALE'::text
        END AS traffic_freshness,
        CASE
            WHEN COALESCE(h.orders_7d, 0::numeric) > 0::numeric OR COALESCE(h.sales_7d, 0::numeric) > 0::numeric THEN 'SETTLED'::text
            WHEN h.data_date <= (CURRENT_DATE - 7) THEN 'MATURE'::text
            WHEN h.data_date <= (CURRENT_DATE - 1) THEN 'MATURING'::text
            ELSE 'IMMATURE'::text
        END AS conversion_maturity,
    h.data_date <= (CURRENT_DATE - 7) OR COALESCE(h.orders_7d, 0::numeric) > 0::numeric OR COALESCE(h.sales_7d, 0::numeric) > 0::numeric AS conversion_trustworthy,
        CASE
            WHEN h.data_date > (CURRENT_DATE - 7) AND COALESCE(h.orders_7d, 0::numeric) = 0::numeric AND COALESCE(h.sales_7d, 0::numeric) = 0::numeric THEN 'CONVERSAO_IMATURA: roas/orders ainda em atribuicao; NAO ler 0 como ruim'::text
            WHEN COALESCE(h.orders_7d, 0::numeric) > 0::numeric OR COALESCE(h.sales_7d, 0::numeric) > 0::numeric THEN 'CONVERSAO_ATRIBUIDA: pedido/venda real'::text
            WHEN ams.campaign_id IS NULL THEN 'REPORTING/CSV: fonte madura de referencia'::text
            ELSE 'OK'::text
        END AS signal_note
   FROM marketcloud_bronze.bronze_amazon_ads_hourly h
     LEFT JOIN LATERAL ( SELECT a.campaign_id,
            max(a.last_traffic_at) AS traffic_last_update
           FROM marketcloud_bronze.bronze_ams_hourly a
             JOIN marketcloud_bronze.bronze_swarm_campaign_names n ON n.campaign_id = a.campaign_id
          WHERE lower(TRIM(BOTH FROM n.campaign_name)) = lower(TRIM(BOTH FROM h.campaign_name)) AND a.data_date = h.data_date AND a.event_hour = h.event_hour
          GROUP BY a.campaign_id
         LIMIT 1) ams ON true;;
