-- 139 - Materializa v_keyword_hourly_recommendation_explain_v1.
--
-- Problema (auditoria 2026-07-19): o modal de detalhe Keywords x hora mostrava
-- contexto comercial vazio porque o endpoint /explain estava STUBBADO retornando
-- '{}' hardcoded. O dado existe no explain view (commercial.sale_price_brl etc.,
-- 26/26 linhas), MAS a view custa ~15s por id: o filtro WHERE id=$1 nao e
-- empurrado pra dentro (merge joins com estimativa de ~1.8 bilhao de linhas),
-- entao 1 id custa igual a view inteira. Por isso foi stubbada.
--
-- Fix: materializa a view (26 linhas, ~15s uma vez) + indice unico p/ lookup por
-- id e REFRESH CONCURRENTLY. O endpoint passa a ler o matview (rapido). O refresh
-- periodico e pendurado no runAmsHourlyRefreshLoop do query-orchestrator.

CREATE MATERIALIZED VIEW IF NOT EXISTS marketcloud_gold.keyword_hourly_recommendation_explain_mv AS
SELECT keyword_hour_recommendation_id, explanation_json
FROM marketcloud_gold.v_keyword_hourly_recommendation_explain_v1;

CREATE UNIQUE INDEX IF NOT EXISTS ux_keyword_explain_mv_id
    ON marketcloud_gold.keyword_hourly_recommendation_explain_mv (keyword_hour_recommendation_id);
