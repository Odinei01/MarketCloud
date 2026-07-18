-- =====================================================================
-- 121: Monitoramento das campanhas liberadas em Full Control.
--
-- Uma linha por piloto full_control ativo, consolidando: governanca (pode
-- controlar? por que nao?), gasto/pedidos do dia, escopo de keyword, e o
-- resumo das propostas 360 (quantas a aplicar / bloquear / ja executadas).
-- E a tela de "o robo esta cuidando dessas campanhas — e como".
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.v_full_control_monitoring_v1 AS
WITH prop AS (
    SELECT campaign_id,
           count(*) AS propostas_360,
           count(*) FILTER (WHERE operator_decision IN ('APLICAR','APLICAR_SEGURANCA')) AS a_aplicar,
           count(*) FILTER (WHERE operator_decision = 'BLOQUEAR') AS bloqueadas,
           count(*) FILTER (WHERE operator_decision = 'AGUARDAR_DADOS') AS aguardando
    FROM marketcloud_gold.v_ml_full_control_360_decision_v1
    GROUP BY campaign_id
), exec AS (
    SELECT campaign_id,
           count(*) FILTER (WHERE entity_type='FULL_CONTROL_360' AND execution_status='EXECUTED') AS executadas_360
    FROM marketcloud_recommendations.recommendation_decisions
    GROUP BY campaign_id
)
SELECT
    g.tenant_id,
    g.campaign_id,
    g.campaign_name,
    g.product_asin,
    g.mode,
    g.status,
    g.can_control,
    g.gate_reason,
    g.spend_today,
    g.orders_today,
    g.roas_today,
    g.stock_available,
    g.max_daily_budget_brl,
    g.max_spend_without_order_brl,
    g.min_roas,
    COALESCE(ks.escopo, 'CAMPANHA_INTEIRA') AS escopo_keyword,
    COALESCE(ks.keywords_selecionadas, 0)   AS keywords_selecionadas,
    COALESCE(p.propostas_360, 0)  AS propostas_360,
    COALESCE(p.a_aplicar, 0)      AS propostas_a_aplicar,
    COALESCE(p.bloqueadas, 0)     AS propostas_bloqueadas,
    COALESCE(p.aguardando, 0)     AS propostas_aguardando,
    COALESCE(e.executadas_360, 0) AS acoes_360_executadas
FROM marketcloud_gold.full_control_effective_governance_v1 g
LEFT JOIN prop p ON p.campaign_id = g.campaign_id
LEFT JOIN exec e ON e.campaign_id = g.campaign_id
LEFT JOIN marketcloud_gold.v_full_control_keyword_scope_v1 ks
       ON ks.tenant_id = g.tenant_id AND ks.campaign_id = g.campaign_id
WHERE g.mode = 'full_control' AND g.status = 'active';

COMMENT ON VIEW marketcloud_gold.v_full_control_monitoring_v1 IS
    'Monitor das campanhas liberadas em Full Control: governanca/tetos, gasto do dia, escopo de keyword e resumo das propostas 360 (a aplicar / bloqueadas / executadas).';
