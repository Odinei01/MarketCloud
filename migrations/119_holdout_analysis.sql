-- =====================================================================
-- 119: Analise de holdout (tratamento x controle) na tela.
--
-- As celulas ja existem (marketcloud_control.holdout_cells: CONTROLE nunca e
-- tocado pelo robo = contrafactual; TRATAMENTO e gerido). O que faltava era
-- LER: comparar a performance dos dois grupos pra responder "foi o robo ou o
-- mercado?" — o controle vive o MESMO mercado sem o robo.
--
-- HONESTIDADE: esta view compara o NIVEL de ROAS por grupo (leitura direcional).
-- Nao e diff-in-diff: os grupos podem nao ter partido equilibrados, e o robo so
-- comecou 16/07 — dado maduro (atribuicao 7d) do periodo pos-robo ainda nao
-- existe. Por isso a API marca isso e a tela mostra "direcional", nao "provado".
-- Quando houver antes/depois maduro, da pra evoluir pra diff-in-diff.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_recommendations.v_holdout_analysis_v1 AS
WITH cells AS (
    SELECT lower(trim(campaign_name)) AS campaign_norm, event_hour, grupo
    FROM marketcloud_control.holdout_cells
), sig AS (
    -- so dado maduro (conversao confiavel) pra o ROAS ser real, janela 14d.
    SELECT lower(trim(u.campaign_name)) AS campaign_norm, u.event_hour,
           COALESCE(u.spend, 0)::numeric   AS spend,
           COALESCE(u.sales_7d, 0)::numeric AS sales,
           COALESCE(u.orders_7d, 0)::numeric AS orders
    FROM marketcloud_gold.gold_hourly_signal_unified u
    WHERE u.conversion_trustworthy = true
      AND u.data_date >= CURRENT_DATE - 14
)
SELECT
    c.grupo,
    count(DISTINCT (c.campaign_norm, c.event_hour)) AS celulas,
    count(*)                                        AS linhas_hora,
    sum(s.spend)::numeric                           AS gasto,
    sum(s.sales)::numeric                           AS venda,
    sum(s.orders)::numeric                          AS pedidos,
    CASE WHEN sum(s.spend) > 0 THEN (sum(s.sales) / sum(s.spend)) ELSE 0 END::numeric AS roas
FROM cells c
JOIN sig s ON s.campaign_norm = c.campaign_norm AND s.event_hour = c.event_hour
GROUP BY c.grupo;

COMMENT ON VIEW marketcloud_recommendations.v_holdout_analysis_v1 IS
    'Holdout tratamento x controle: ROAS/gasto/venda por grupo em dado maduro (14d). Leitura DIRECIONAL (nivel), nao diff-in-diff. Controle = robo nao toca; contrafactual pra separar robo de mercado.';
