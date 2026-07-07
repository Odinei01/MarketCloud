-- =====================================================================
-- Validação: o que ingerimos bate com o AMC?
--
-- Contexto do problema:
--   Existem 3 medidas diferentes de "orders/sales", todas legítimas mas
--   NÃO intercambiáveis:
--     (A) conversion-time nível campanha  -> E001 (bronze_amc_campaign_daily)
--     (B) traffic-time                    -> E004 (bronze_amc_hourly_performance)
--                                            e E009 modo TRAFFIC_TIME
--     (C) conversion-time grão fino        -> E009 modo CONVERSION_TIME
--
--   - conversion-time  = conversão contada NO DIA EM QUE FECHOU.
--   - traffic-time     = conversão atribuída à DATA/HORA DO CLIQUE que a gerou
--                        (dias recentes ficam baixos: atribuição amadurece
--                         por até 14 dias).
--
--   O número "tenho muitas conversões em D-7" é a lente conversion-time
--   nível campanha (E001). O E004 (traffic-time, por hora) é naturalmente
--   menor nos dias recentes — E ADICIONALMENTE está perdendo conversões no
--   join por hora (ver Q3).
-- =====================================================================


-- ---------------------------------------------------------------------
-- Q1 — Reconciliação diária entre extratos (roda no Postgres marketcloud)
-- Compara as 3 lentes lado a lado por dia. Se E001 e E009_conv divergirem
-- muito num dia, é grão/filtro. Se E004 divergir de E009_traffic, é o
-- join do E004 perdendo conversão.
-- ---------------------------------------------------------------------
WITH e001 AS (
    SELECT data_date, SUM(orders) AS orders, SUM(sales) AS sales
    FROM marketcloud_bronze.bronze_amc_campaign_daily GROUP BY data_date
),
e004 AS (
    SELECT data_date, SUM(orders) AS orders, SUM(sales) AS sales
    FROM marketcloud_bronze.bronze_amc_hourly_performance GROUP BY data_date
),
e009c AS (
    SELECT attribution_date AS data_date, SUM(orders) AS orders, SUM(sales) AS sales
    FROM marketcloud_bronze.bronze_amc_conversions_unified_daily
    WHERE attribution_mode = 'CONVERSION_TIME' GROUP BY attribution_date
),
e009t AS (
    SELECT attribution_date AS data_date, SUM(orders) AS orders, SUM(sales) AS sales
    FROM marketcloud_bronze.bronze_amc_conversions_unified_daily
    WHERE attribution_mode = 'TRAFFIC_TIME' GROUP BY attribution_date
),
dates AS (
    SELECT data_date FROM e001
    UNION SELECT data_date FROM e004
    UNION SELECT data_date FROM e009c
    UNION SELECT data_date FROM e009t
)
SELECT
    d.data_date,
    COALESCE(e001.orders,  0) AS e001_conv_campanha,
    COALESCE(e009c.orders, 0) AS e009_conv_fino,
    COALESCE(e009t.orders, 0) AS e009_traffic,
    COALESCE(e004.orders,  0) AS e004_hourly_traffic,
    -- gap que denuncia o bug do E004 (mesma lente traffic-time):
    COALESCE(e009t.orders, 0) - COALESCE(e004.orders, 0) AS gap_e009t_menos_e004
FROM dates d
LEFT JOIN e001  ON e001.data_date  = d.data_date
LEFT JOIN e004  ON e004.data_date  = d.data_date
LEFT JOIN e009c ON e009c.data_date = d.data_date
LEFT JOIN e009t ON e009t.data_date = d.data_date
ORDER BY d.data_date DESC;


-- ---------------------------------------------------------------------
-- Q2 — Totais por extrato/lente (roda no Postgres marketcloud)
-- Visão macro. Espera-se: E001 >= E009_conv (grão) e E004 ~ E009_traffic.
-- ---------------------------------------------------------------------
SELECT 'E001 conv-time (campanha)'   AS fonte, SUM(orders) AS orders, ROUND(SUM(sales)::numeric,2) AS sales
FROM marketcloud_bronze.bronze_amc_campaign_daily
UNION ALL
SELECT 'E009 conv-time (fino)', SUM(orders), ROUND(SUM(sales)::numeric,2)
FROM marketcloud_bronze.bronze_amc_conversions_unified_daily WHERE attribution_mode='CONVERSION_TIME'
UNION ALL
SELECT 'E009 traffic-time', SUM(orders), ROUND(SUM(sales)::numeric,2)
FROM marketcloud_bronze.bronze_amc_conversions_unified_daily WHERE attribution_mode='TRAFFIC_TIME'
UNION ALL
SELECT 'E004 hourly (traffic-time)', SUM(orders), ROUND(SUM(sales)::numeric,2)
FROM marketcloud_bronze.bronze_amc_hourly_performance;


-- ---------------------------------------------------------------------
-- Q3 — Diagnóstico do join do E004 (roda no Postgres marketcloud)
-- E004 e E009_traffic usam A MESMA lente. Se divergem, o join por hora
-- do E004 está perdendo conversão. Linhas com gap > 0 = conversões que
-- o E004 deveria ter e não tem.
-- ---------------------------------------------------------------------
WITH e004 AS (
    SELECT data_date, SUM(orders) AS e004_orders
    FROM marketcloud_bronze.bronze_amc_hourly_performance GROUP BY data_date
),
e009t AS (
    SELECT attribution_date AS data_date, SUM(orders) AS e009t_orders
    FROM marketcloud_bronze.bronze_amc_conversions_unified_daily
    WHERE attribution_mode='TRAFFIC_TIME' GROUP BY attribution_date
)
SELECT
    COALESCE(e004.data_date, e009t.data_date) AS data_date,
    COALESCE(e009t_orders,0) AS e009_traffic,
    COALESCE(e004_orders,0)  AS e004_hourly,
    COALESCE(e009t_orders,0) - COALESCE(e004_orders,0) AS conversoes_perdidas_no_e004
FROM e009t
FULL OUTER JOIN e004 ON e004.data_date = e009t.data_date
WHERE COALESCE(e009t_orders,0) <> COALESCE(e004_orders,0)
ORDER BY data_date DESC;


-- =====================================================================
-- Q4 — VALIDAÇÃO CONTRA O AMC (roda NO CONSOLE DO AMC, não no Postgres)
--
-- Rode este SQL no AMC para a MESMA janela do backfill (ajuste as datas
-- no time window do workflow). O total de `orders`/`sales` que o AMC
-- devolver deve bater EXATAMENTE com a Q2 linha "E001 conv-time (campanha)"
-- da nossa bronze. Se bater, a ingestão do E001 está correta e o problema
-- é só de lente (E004). Se NÃO bater, a ingestão divergiu do AMC.
-- =====================================================================
-- SELECT
--     SUM(total_purchases)      AS orders,
--     SUM(total_product_sales)  AS sales
-- FROM amazon_attributed_events_by_conversion_time
-- WHERE conversion_event_date IS NOT NULL
--   AND campaign_id IS NOT NULL;
--
-- Versão por dia (para bater dia a dia com a Q1 coluna e001_conv_campanha):
-- SELECT
--     conversion_event_date     AS data_date,
--     SUM(total_purchases)      AS orders,
--     SUM(total_product_sales)  AS sales
-- FROM amazon_attributed_events_by_conversion_time
-- WHERE conversion_event_date IS NOT NULL
--   AND campaign_id IS NOT NULL
-- GROUP BY conversion_event_date
-- ORDER BY conversion_event_date DESC;
--
-- Validação da lente traffic-time (para bater com E004/E009_traffic):
-- SELECT
--     traffic_event_date        AS data_date,
--     SUM(total_purchases)      AS orders,
--     SUM(total_product_sales)  AS sales
-- FROM amazon_attributed_events_by_traffic_time
-- WHERE traffic_event_date IS NOT NULL
--   AND campaign_id IS NOT NULL
-- GROUP BY traffic_event_date
-- ORDER BY traffic_event_date DESC;
-- =====================================================================
