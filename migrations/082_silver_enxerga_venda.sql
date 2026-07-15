-- A RAIZ: o silver que gera TODAS as recomendacoes nao enxerga venda.
--
-- silver_hourly_campaign_adgroup e uma view fina sobre bronze_amc_hourly_performance
-- — o extract do AMC, que SUPRIME conversao de baixo volume. Medido em 15/07:
-- 6.897 linhas, 25 com venda, R$2.554 — contra 239 horas e R$11.147 no sinal do
-- relatorio horario da conta (bronze_amazon_ads_hourly: 10.210 linhas, 240 com
-- venda, R$11.193), que NAO passa pelo clean room e por isso nao e suprimido.
-- O cockpit via 10% das horas que vendem.
--
-- E nao e so a tela horaria: as QUATRO geradoras de recomendacao leem este silver
-- (gold_hourly_bid_schedule, gold_cut_candidates, gold_negative_keyword_candidates,
-- gold_scale_candidates). Cortar, negativar e escalar nasciam do dado cego.
-- Consertar view por view era enxugar gelo — conserta-se na origem.
--
-- Gasto/cliques/impressoes continuam do AMC (batem com o real). A VENDA vem do
-- relatorio quando o AMC esta zerado. O relatorio e campanha x hora x dia e o silver e
-- campanha x AD GROUP x hora x dia: rateia pela participacao de gasto do ad
-- group (mesmo criterio da 078, que reconciliou ao centavo). Nao sobrescreve
-- venda que o AMC ja traz — so preenche o que ele cegou.
CREATE OR REPLACE VIEW marketcloud_silver.silver_hourly_campaign_adgroup AS
WITH ams AS (
    SELECT a.data_date, lower(trim(a.campaign_name)) AS campaign_norm, a.event_hour,
           sum(a.sales_7d) AS venda, sum(a.orders_7d) AS pedidos
    FROM marketcloud_bronze.bronze_amazon_ads_hourly a
    WHERE a.campaign_name IS NOT NULL
    GROUP BY 1,2,3
    HAVING sum(a.sales_7d) > 0
), base AS (
    SELECT b.*,
           CASE WHEN sum(b.spend) OVER w > 0 THEN b.spend / sum(b.spend) OVER w
                ELSE 1.0 / GREATEST(count(*) OVER w, 1) END AS parte_do_grupo
    FROM marketcloud_bronze.bronze_amc_hourly_performance b
    WINDOW w AS (PARTITION BY b.data_date, lower(trim(b.campaign_name)), b.event_hour)
), rec AS (
    SELECT base.*,
           CASE WHEN COALESCE(base.sales,0) = 0 AND ams.venda IS NOT NULL
                THEN round((ams.venda * base.parte_do_grupo)::numeric, 4)
                ELSE base.sales END AS sales_rec,
           CASE WHEN COALESCE(base.sales,0) = 0 AND ams.venda IS NOT NULL
                THEN round((ams.pedidos * base.parte_do_grupo)::numeric, 4)
                ELSE base.orders END AS orders_rec,
           (COALESCE(base.sales,0) = 0 AND ams.venda IS NOT NULL) AS veio_do_ams
    FROM base
    LEFT JOIN ams ON ams.data_date = base.data_date
                 AND ams.campaign_norm = lower(trim(base.campaign_name))
                 AND ams.event_hour = base.event_hour
)
SELECT tenant_id, amc_instance_id, ads_profile_id, workflow_run_id, data_date, event_hour,
    campaign_id, campaign_name, ad_product_type, ad_group_name,
    impressions, clicks, spend,
    orders_rec::numeric(18,4) AS orders,
    sales_rec::numeric(18,4)  AS sales,
    (CASE WHEN veio_do_ams THEN sales_rec ELSE combined_sales END)::numeric(18,4) AS combined_sales,
    ctr, cpc,
    CASE WHEN spend > 0 THEN (sales_rec / spend)::double precision ELSE 0::double precision END AS roas,
    CASE WHEN spend > 0 THEN (sales_rec / spend)::double precision ELSE 0::double precision END AS total_roas,
    CASE WHEN clicks > 0 THEN (orders_rec / clicks)::double precision ELSE 0::double precision END AS conversion_rate,
    (CASE WHEN sales_rec > 0::numeric THEN spend / sales_rec ELSE 0::numeric END)::numeric AS acos,
    CASE WHEN orders_rec > 0::numeric THEN spend / orders_rec ELSE 0::numeric END AS cpa,
    CASE WHEN orders_rec > 0::numeric THEN sales_rec / orders_rec ELSE 0::numeric END AS aov,
    CASE
        WHEN event_hour >= 0 AND event_hour <= 5 THEN 'MADRUGADA'::text
        WHEN event_hour >= 6 AND event_hour <= 11 THEN 'MANHA'::text
        WHEN event_hour >= 12 AND event_hour <= 17 THEN 'TARDE'::text
        ELSE 'NOITE'::text
    END AS day_part,
    CASE
        WHEN spend = 0::numeric THEN 'NO_SPEND'::text
        WHEN spend > 0::numeric AND clicks = 0 THEN 'SPEND_NO_CLICK'::text
        WHEN clicks > 0 AND sales_rec = 0::numeric THEN 'CLICK_NO_SALE'::text
        WHEN sales_rec > 0::numeric AND (CASE WHEN spend > 0 THEN sales_rec/spend ELSE 0 END) < 3 THEN 'SALE_LOW_ROAS'::text
        WHEN (CASE WHEN spend > 0 THEN sales_rec/spend ELSE 0 END) >= 3
         AND (CASE WHEN spend > 0 THEN sales_rec/spend ELSE 0 END) < 7 THEN 'SALE_GOOD_ROAS'::text
        ELSE 'SALE_STRONG_ROAS'::text
    END AS hour_efficiency_bucket,
    loaded_at,
    CASE WHEN veio_do_ams THEN 'AMS_RECONCILED'::text ELSE 'AMC'::text END AS sales_source
FROM rec;

COMMENT ON VIEW marketcloud_silver.silver_hourly_campaign_adgroup IS
    'Horario campanha x ad group. Gasto/cliques do AMC; VENDA reconciliada do AMS onde o AMC suprimiu (rateada por gasto do ad group). sales_source diz a origem de cada linha.';
