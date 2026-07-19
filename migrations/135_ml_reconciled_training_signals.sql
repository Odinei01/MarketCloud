-- =====================================================================
-- ML reconciled training signals
--
-- Objetivo:
--   1. preservar Ads Reporting/API como historico maduro antes do AMS estar
--      estavel;
--   2. usar AMS como sinal horario real quando ja existe;
--   3. dar ao modelo target/keyword mais conversoes sem inventar pedido sem
--      proveniencia.
--
-- Regra:
--   - campanha/hora continua vindo de gold_hourly_signal_amc/unified, que ja
--     carrega o Ads hourly report reconciliado;
--   - target/hora usa AMS target a partir de 2026-07-13 quando existe;
--   - antes disso, usa Ads Reporting v3 target/keyword diario distribuido pelas
--     horas observadas da campanha no mesmo dia, proporcionalmente ao trafego.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.v_ml_target_hour_training_reconciled_v1 AS
WITH campaign_hour AS (
    SELECT
        h.data_date,
        h.event_hour,
        i.campaign_id,
        h.campaign_name,
        GREATEST(COALESCE(h.impressions,0),0)::numeric AS impressions,
        GREATEST(COALESCE(h.clicks,0),0)::numeric AS clicks,
        GREATEST(COALESCE(h.spend,0),0)::numeric AS spend,
        SUM(GREATEST(COALESCE(h.impressions,0),0)) OVER (PARTITION BY h.data_date, i.campaign_id) AS day_impressions,
        SUM(GREATEST(COALESCE(h.clicks,0),0)) OVER (PARTITION BY h.data_date, i.campaign_id) AS day_clicks,
        SUM(GREATEST(COALESCE(h.spend,0),0)) OVER (PARTITION BY h.data_date, i.campaign_id) AS day_spend,
        COUNT(*) OVER (PARTITION BY h.data_date, i.campaign_id) AS active_hours
    FROM marketcloud_gold.gold_hourly_signal_unified h
    JOIN marketcloud_gold.gold_campaign_identity i
      ON i.campaign_norm = lower(trim(h.campaign_name))
    WHERE COALESCE(i.campaign_id,'') <> ''
      AND (
          GREATEST(COALESCE(h.impressions,0),0) > 0
       OR GREATEST(COALESCE(h.clicks,0),0) > 0
       OR GREATEST(COALESCE(h.spend,0),0) > 0
       OR GREATEST(COALESCE(h.orders_7d,0),0) > 0
       OR GREATEST(COALESCE(h.sales_7d,0),0) > 0
      )
), ads_alloc AS (
    SELECT
        d.data_date,
        ch.event_hour,
        d.campaign_id,
        COALESCE(d.campaign_name, ch.campaign_name) AS campaign_name,
        d.ad_group_id,
        d.ad_group_name,
        d.keyword_id,
        d.target_id,
        d.target_entity_key,
        CASE WHEN d.report_grain = 'KEYWORD' THEN d.target_text END AS keyword_text,
        CASE WHEN d.report_grain = 'TARGET' THEN d.target_text END AS targeting,
        COALESCE(NULLIF(d.match_type,''), d.report_grain, 'UNKNOWN') AS match_type,
        (
            CASE
                WHEN d.impressions > 0 AND ch.day_impressions > 0 THEN d.impressions * ch.impressions / NULLIF(ch.day_impressions,0)
                WHEN d.impressions > 0 AND ch.active_hours > 0 THEN d.impressions / NULLIF(ch.active_hours,0)
                ELSE 0
            END
        )::numeric AS impressions,
        (
            CASE
                WHEN d.clicks > 0 AND ch.day_clicks > 0 THEN d.clicks * ch.clicks / NULLIF(ch.day_clicks,0)
                WHEN d.clicks > 0 AND ch.day_spend > 0 THEN d.clicks * ch.spend / NULLIF(ch.day_spend,0)
                WHEN d.clicks > 0 AND ch.active_hours > 0 THEN d.clicks / NULLIF(ch.active_hours,0)
                ELSE 0
            END
        )::numeric AS clicks,
        (
            CASE
                WHEN d.spend > 0 AND ch.day_spend > 0 THEN d.spend * ch.spend / NULLIF(ch.day_spend,0)
                WHEN d.spend > 0 AND ch.day_clicks > 0 THEN d.spend * ch.clicks / NULLIF(ch.day_clicks,0)
                WHEN d.spend > 0 AND ch.active_hours > 0 THEN d.spend / NULLIF(ch.active_hours,0)
                ELSE 0
            END
        )::numeric AS spend,
        (
            CASE
                WHEN d.orders > 0 AND ch.day_clicks > 0 THEN d.orders * ch.clicks / NULLIF(ch.day_clicks,0)
                WHEN d.orders > 0 AND ch.day_spend > 0 THEN d.orders * ch.spend / NULLIF(ch.day_spend,0)
                WHEN d.orders > 0 AND ch.active_hours > 0 THEN d.orders / NULLIF(ch.active_hours,0)
                ELSE 0
            END
        )::numeric AS orders,
        (
            CASE
                WHEN d.sales > 0 AND ch.day_clicks > 0 THEN d.sales * ch.clicks / NULLIF(ch.day_clicks,0)
                WHEN d.sales > 0 AND ch.day_spend > 0 THEN d.sales * ch.spend / NULLIF(ch.day_spend,0)
                WHEN d.sales > 0 AND ch.active_hours > 0 THEN d.sales / NULLIF(ch.active_hours,0)
                ELSE 0
            END
        )::numeric AS sales,
        'ADS_REPORTING_V3_DAILY_ALLOCATED'::text AS training_source,
        0.70::numeric AS source_confidence,
        d.last_sync AS source_updated_at
    FROM marketcloud_gold.v_ads_targeting_daily_effective_v1 d
    JOIN campaign_hour ch
      ON ch.data_date = d.data_date
     AND ch.campaign_id = d.campaign_id
    WHERE d.data_date < DATE '2026-07-13'
), ams AS (
    SELECT
        a.data_date,
        a.event_hour,
        a.campaign_id,
        COALESCE(NULLIF(a.campaign_name,''), i.campaign_name) AS campaign_name,
        COALESCE(a.ad_group_id,'') AS ad_group_id,
        a.ad_group_name,
        a.keyword_id,
        a.target_id,
        a.target_entity_key,
        a.keyword_text,
        a.targeting,
        COALESCE(NULLIF(a.match_type,''),'UNKNOWN') AS match_type,
        GREATEST(COALESCE(a.impressions,0),0)::numeric AS impressions,
        GREATEST(COALESCE(a.clicks,0),0)::numeric AS clicks,
        GREATEST(COALESCE(a.spend,0),0)::numeric AS spend,
        GREATEST(COALESCE(a.orders_14d,0), COALESCE(a.orders_7d,0), COALESCE(a.orders_1d,0), 0)::numeric AS orders,
        GREATEST(COALESCE(a.sales_14d,0), COALESCE(a.sales_7d,0), COALESCE(a.sales_1d,0), 0)::numeric AS sales,
        'AMS_STREAM_TARGET'::text AS training_source,
        1.00::numeric AS source_confidence,
        a.updated_at AS source_updated_at
    FROM marketcloud_bronze.bronze_ams_hourly_target a
    LEFT JOIN marketcloud_gold.gold_campaign_identity i
      ON i.campaign_id = a.campaign_id
    WHERE a.data_date >= DATE '2026-07-13'
      AND NULLIF(TRIM(COALESCE(a.target_entity_key,'')), '') IS NOT NULL
), unioned AS (
    SELECT * FROM ads_alloc
    UNION ALL
    SELECT * FROM ams
)
SELECT
    data_date,
    event_hour,
    campaign_id,
    campaign_name,
    ad_group_id,
    ad_group_name,
    keyword_id,
    target_id,
    target_entity_key,
    keyword_text,
    targeting,
    match_type,
    impressions,
    clicks,
    spend,
    orders,
    sales,
    training_source,
    source_confidence,
    source_updated_at
FROM unioned
WHERE COALESCE(campaign_id,'') <> ''
  AND NULLIF(TRIM(COALESCE(target_entity_key,'')), '') IS NOT NULL;

COMMENT ON VIEW marketcloud_gold.v_ml_target_hour_training_reconciled_v1 IS
    'Fonte reconciliada para ML target/keyword x hora: Ads Reporting v3 diario alocado por hora antes de 2026-07-13 e AMS target horario a partir de 2026-07-13. training_source/source_confidence deixam a proveniencia explicita.';

CREATE OR REPLACE VIEW marketcloud_gold.v_ml_training_volume_reconciliation_v1 AS
SELECT
    'campaign_hour_gold'::text AS source,
    COUNT(*)::numeric AS rows,
    MIN(data_date) AS min_date,
    MAX(data_date) AS max_date,
    COUNT(DISTINCT campaign_name)::numeric AS campaigns,
    NULL::numeric AS targets,
    SUM(GREATEST(COALESCE(clicks,0),0))::numeric AS clicks,
    SUM(GREATEST(COALESCE(orders_7d,0),0))::numeric AS orders,
    SUM(GREATEST(COALESCE(sales_7d,0),0))::numeric AS sales,
    SUM(GREATEST(COALESCE(spend,0),0))::numeric AS spend
FROM marketcloud_gold.gold_hourly_signal_unified
UNION ALL
SELECT
    'target_hour_reconciled'::text AS source,
    COUNT(*)::numeric AS rows,
    MIN(data_date) AS min_date,
    MAX(data_date) AS max_date,
    COUNT(DISTINCT campaign_id)::numeric AS campaigns,
    COUNT(DISTINCT target_entity_key)::numeric AS targets,
    SUM(GREATEST(COALESCE(clicks,0),0))::numeric AS clicks,
    SUM(GREATEST(COALESCE(orders,0),0))::numeric AS orders,
    SUM(GREATEST(COALESCE(sales,0),0))::numeric AS sales,
    SUM(GREATEST(COALESCE(spend,0),0))::numeric AS spend
FROM marketcloud_gold.v_ml_target_hour_training_reconciled_v1
UNION ALL
SELECT
    'amc_daily_total_context'::text AS source,
    COUNT(*)::numeric AS rows,
    MIN(data_date) AS min_date,
    MAX(data_date) AS max_date,
    NULL::numeric AS campaigns,
    NULL::numeric AS targets,
    NULL::numeric AS clicks,
    SUM(COALESCE(orders,0))::numeric AS orders,
    SUM(COALESCE(sales,0))::numeric AS sales,
    NULL::numeric AS spend
FROM marketcloud_bronze.bronze_amc_conversions_daily_total;

COMMENT ON VIEW marketcloud_gold.v_ml_training_volume_reconciliation_v1 IS
    'Resumo de volume que separa labels treinaveis por campanha/target dos pedidos AMC diarios totais usados apenas como contexto/calibracao.';
