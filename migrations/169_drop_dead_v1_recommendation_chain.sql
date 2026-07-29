-- 169_drop_dead_v1_recommendation_chain.sql
--
-- Remove a cadeia MORTA de recomendacao V1 (grao ENTIDADE), superseded pelos
-- modelos hourly V2/V3 (grao HORA) desde 07/07/2026.
--
-- Motivacao (investigacao 29/07/2026):
--   * marketcloud_features.model_predictions estava congelada em 07/07 — escrita
--     apenas pelos workers ml_worker_v0/v1 (ja fora de qualquer deploy; modelos
--     V1 marcados INSUFFICIENT_DATA, substituidos por HourlyxRealV2/V3).
--   * Toda a arvore de views que a consumia alimentava so a tela ReviewQueue
--     ("Cockpit") + a pagina "Meu Robo Hoje" — ambas confirmadas SEM USO pelo dono.
--   * Handlers Go (GoldReviewQueue/ActionSummary/CampaignPlans/Decide/RobotToday),
--     rotas, paginas React e os 2 workers Python foram removidos no mesmo commit.
--
-- NAO tocado (compartilhado/vivo): bronze_amazon_ads_hourly, model_registry,
--   gold_hourly_recommendations_v1, gold_amc_retargeting_alerts, e a tabela
--   marketcloud_recommendations.recommendation_decisions (log historico de decisoes).

-- A arvore inteira e raizada na tabela model_predictions:
--   model_predictions -> unified_v2 -> priority_v2 -> priority_mv (matview)
--     -> {review_queue_v2, review_queue_actionable_v2, action_impact_summary_v2,
--         campaign_action_plan_v2}  (+ ml_disagreement_v2)
-- Auditada em 29/07: sao exatamente estes 8 objetos, todos mortos. Um unico
-- DROP CASCADE na raiz derruba a arvore toda de forma consistente.

BEGIN;

DROP TABLE IF EXISTS marketcloud_features.model_predictions CASCADE;

COMMIT;
