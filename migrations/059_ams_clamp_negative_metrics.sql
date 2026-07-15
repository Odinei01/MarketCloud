-- =====================================================================
-- Integridade: o AMS sp-traffic é DELTA-based (restatement manda correção),
-- mas o consumidor grava last-write-wins -> quando a última mensagem de uma
-- célula é uma correção NEGATIVA, o valor guardado fica negativo (ex.: -4 impr,
-- clicks=0/spend=0). Impressão/clique/gasto negativo é fisicamente impossível e
-- suja features do ML (ctr negativo etc.) — pior agora que o ML AUTO-APLICA bid.
--
-- INTERIM (band-aid seguro): clamp GREATEST(0, ...) na reconciliação, pra o
-- Gold/ML nunca receber negativo. O landing bronze_ams_hourly mantém o valor
-- bruto pra reprocessamento futuro.
--
-- FIX REAL (documentado no handoff, NÃO feito aqui p/ não arriscar double-count):
-- consumidor deve SOMAR deltas COM idempotência por AMS idempotencyId (SQS é
-- at-least-once). Isso recupera o total correto; o clamp é só ponte até lá.
-- =====================================================================

DROP VIEW IF EXISTS marketcloud_bronze.v_ams_hourly_resolved;
CREATE VIEW marketcloud_bronze.v_ams_hourly_resolved AS
SELECT
    a.data_date,
    a.event_hour,
    COALESCE(NULLIF(a.campaign_name, ''), m.campaign_name, s.campaign_name, n.campaign_name) AS campaign_name,
    a.campaign_id,
    GREATEST(0, a.impressions)                 AS impressions,
    GREATEST(0, a.clicks)                       AS clicks,
    GREATEST(0::numeric, a.spend)               AS spend,
    GREATEST(0::numeric, a.orders_7d)           AS orders_7d,
    GREATEST(0::numeric, a.sales_7d)            AS sales_7d,
    CASE WHEN a.clicks  > 0 THEN GREATEST(0::numeric, a.spend) / a.clicks END AS cpc,
    CASE WHEN a.spend   > 0 THEN GREATEST(0::numeric, a.sales_7d) / a.spend END AS roas,
    CASE WHEN a.sales_7d> 0 THEN GREATEST(0::numeric, a.spend) / a.sales_7d END AS acos
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
