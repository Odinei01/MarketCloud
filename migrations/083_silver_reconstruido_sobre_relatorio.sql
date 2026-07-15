-- RECONSTRUCAO: o silver horario passa a nascer do RELATORIO, nao do AMC.
--
-- A 082 tentou reconciliar a venda que o AMC suprime, e recuperou so R$518 de
-- ~R$8,6k. O motivo apareceu na medicao: nao da pra reconciliar linha que nao
-- existe — o extract do AMC tem 6.897 linhas contra 10.210 do relatorio. Ele
-- nao suprime so a conversao: ele nem extrai ~3.3k campanha x hora x dia.
--
-- Inversao: bronze_amazon_ads_hourly (relatorio da conta) vira a BASE — ele tem
-- gasto E venda de tudo, sem clean room no meio. O AMC fica com o que so ele
-- sabe: como repartir entre ad groups (o relatorio e campanha x hora x dia).
--
-- Rateio do ad group, nesta ordem:
--   1. participacao de gasto naquela campanha x hora x dia (o AMC viu a hora);
--   2. participacao historica do ad group na campanha (o AMC nao viu a hora);
--   3. linha unica '(rateio indisponivel)' (o AMC nao conhece a campanha).
-- sales_source diz de onde veio cada numero, linha a linha.
CREATE OR REPLACE VIEW marketcloud_silver.silver_hourly_campaign_adgroup AS
WITH ctx AS (   -- identidade do tenant/instancia: o relatorio nao carrega
    SELECT tenant_id, amc_instance_id, ads_profile_id
    FROM marketcloud_control.amc_instances LIMIT 1
), camp AS (    -- campaign_id e ad_product_type por campanha, do que o AMC conhece
    SELECT lower(trim(campaign_name)) AS campaign_norm,
           max(campaign_id) AS campaign_id, max(ad_product_type) AS ad_product_type
    FROM marketcloud_bronze.bronze_amc_hourly_performance GROUP BY 1
), share_hora AS (  -- 1: o AMC viu esta campanha x hora x dia
    SELECT data_date, lower(trim(campaign_name)) AS campaign_norm, event_hour, ad_group_name,
           CASE WHEN sum(spend) OVER w > 0 THEN spend / sum(spend) OVER w
                ELSE 1.0 / GREATEST(count(*) OVER w, 1) END AS parte
    FROM marketcloud_bronze.bronze_amc_hourly_performance
    WINDOW w AS (PARTITION BY data_date, lower(trim(campaign_name)), event_hour)
), share_hist AS (  -- 2: participacao historica do ad group na campanha
    SELECT campaign_norm, ad_group_name,
           CASE WHEN sum(g) OVER (PARTITION BY campaign_norm) > 0
                THEN g / sum(g) OVER (PARTITION BY campaign_norm)
                ELSE 1.0 / GREATEST(count(*) OVER (PARTITION BY campaign_norm), 1) END AS parte
    FROM (SELECT lower(trim(campaign_name)) AS campaign_norm, ad_group_name, sum(spend) AS g
          FROM marketcloud_bronze.bronze_amc_hourly_performance GROUP BY 1,2) x
), rel AS (
    SELECT r.data_date, r.event_hour, r.campaign_name,
           lower(trim(r.campaign_name)) AS campaign_norm,
           r.impressions, r.clicks, r.spend, r.orders_7d, r.sales_7d, r.ingested_at
    FROM marketcloud_bronze.bronze_amazon_ads_hourly r
    WHERE r.campaign_name IS NOT NULL
), split AS (
    SELECT rel.*,
           COALESCE(sh.ad_group_name, hi.ad_group_name, '(rateio indisponivel)') AS ad_group_name,
           COALESCE(sh.parte, hi.parte, 1.0) AS parte,
           CASE WHEN sh.parte IS NOT NULL THEN 'RELATORIO+AMC_HORA'
                WHEN hi.parte IS NOT NULL THEN 'RELATORIO+AMC_HIST'
                ELSE 'RELATORIO_SEM_RATEIO' END AS origem
    FROM rel
    LEFT JOIN share_hora sh ON sh.data_date = rel.data_date
                           AND sh.campaign_norm = rel.campaign_norm
                           AND sh.event_hour = rel.event_hour
    LEFT JOIN share_hist hi ON hi.campaign_norm = rel.campaign_norm
                           AND sh.ad_group_name IS NULL
)
SELECT ctx.tenant_id, ctx.amc_instance_id, ctx.ads_profile_id,
    NULL::bigint AS workflow_run_id,
    s.data_date, s.event_hour::smallint AS event_hour,
    COALESCE(camp.campaign_id, '')::text AS campaign_id,
    s.campaign_name,
    COALESCE(camp.ad_product_type, 'SPONSORED_PRODUCTS')::text AS ad_product_type,
    s.ad_group_name,
    round((s.impressions * s.parte))::bigint AS impressions,
    round((s.clicks * s.parte))::bigint AS clicks,
    round((s.spend * s.parte)::numeric, 6)::numeric(18,6) AS spend,
    round((s.orders_7d * s.parte)::numeric, 4)::numeric(18,4) AS orders,
    round((s.sales_7d * s.parte)::numeric, 4)::numeric(18,4) AS sales,
    round((s.sales_7d * s.parte)::numeric, 4)::numeric(18,4) AS combined_sales,
    CASE WHEN s.impressions > 0 THEN (s.clicks::double precision / s.impressions) ELSE 0::double precision END AS ctr,
    CASE WHEN s.clicks > 0 THEN (s.spend / s.clicks)::double precision ELSE 0::double precision END AS cpc,
    CASE WHEN s.spend > 0 THEN (s.sales_7d / s.spend)::double precision ELSE 0::double precision END AS roas,
    CASE WHEN s.spend > 0 THEN (s.sales_7d / s.spend)::double precision ELSE 0::double precision END AS total_roas,
    CASE WHEN s.clicks > 0 THEN (s.orders_7d::double precision / s.clicks) ELSE 0::double precision END AS conversion_rate,
    CASE WHEN s.sales_7d > 0 THEN round((s.spend / s.sales_7d)::numeric, 4) ELSE 0::numeric END AS acos,
    CASE WHEN s.orders_7d > 0 THEN round((s.spend / s.orders_7d)::numeric, 4) ELSE 0::numeric END AS cpa,
    CASE WHEN s.orders_7d > 0 THEN round((s.sales_7d / s.orders_7d)::numeric, 4) ELSE 0::numeric END AS aov,
    CASE
        WHEN s.event_hour >= 0 AND s.event_hour <= 5 THEN 'MADRUGADA'::text
        WHEN s.event_hour >= 6 AND s.event_hour <= 11 THEN 'MANHA'::text
        WHEN s.event_hour >= 12 AND s.event_hour <= 17 THEN 'TARDE'::text
        ELSE 'NOITE'::text
    END AS day_part,
    CASE
        WHEN s.spend = 0::numeric THEN 'NO_SPEND'::text
        WHEN s.spend > 0::numeric AND s.clicks = 0 THEN 'SPEND_NO_CLICK'::text
        WHEN s.clicks > 0 AND s.sales_7d = 0::numeric THEN 'CLICK_NO_SALE'::text
        WHEN s.sales_7d > 0::numeric AND (s.sales_7d / NULLIF(s.spend,0)) < 3 THEN 'SALE_LOW_ROAS'::text
        WHEN (s.sales_7d / NULLIF(s.spend,0)) >= 3 AND (s.sales_7d / NULLIF(s.spend,0)) < 7 THEN 'SALE_GOOD_ROAS'::text
        ELSE 'SALE_STRONG_ROAS'::text
    END AS hour_efficiency_bucket,
    s.ingested_at AS loaded_at,
    s.origem AS sales_source
FROM split s
CROSS JOIN ctx
LEFT JOIN camp ON camp.campaign_norm = s.campaign_norm;

COMMENT ON VIEW marketcloud_silver.silver_hourly_campaign_adgroup IS
    'Horario campanha x ad group construido sobre o RELATORIO da conta (gasto E venda de tudo, sem clean room). O AMC entra so pra repartir entre ad groups. sales_source: RELATORIO+AMC_HORA | RELATORIO+AMC_HIST | RELATORIO_SEM_RATEIO.';
