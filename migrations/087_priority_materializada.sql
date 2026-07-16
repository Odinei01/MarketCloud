-- P0 da auditoria de 16/07: a tela travava. /gold/action-summary levava 23-48s,
-- /gold/review-queue 27-56s, e a agregacao direta na view passava de 2 minutos.
-- Medido aqui: count(*) na gold_recommendation_priority_v2 = 83,6 segundos.
--
-- Culpa minha (noite de 15/07): empilhei 077, 078, 079, 081 e 084 na mesma
-- view, cada uma com LATERAL/subquery correlacionada POR LINHA (alvo do ML,
-- multiplicador atual, metrica real, rateio, gap de atribuicao). Medi 8,9s
-- depois da 077 e nao voltei a medir depois das outras quatro.
--
-- Fix: o envelope vira MATERIALIZED VIEW e a view mantem o NOME — os quatro
-- consumidores (summary/cards, actionable/lista, review_queue,
-- campaign_action_plan) nao mudam. O custo sai do request e vai pro refresh,
-- que ja roda de hora em hora e sob demanda quando o dono aplica algo.
DROP MATERIALIZED VIEW IF EXISTS marketcloud_gold.gold_recommendation_priority_mv CASCADE;

CREATE MATERIALIZED VIEW marketcloud_gold.gold_recommendation_priority_mv AS
-- DISTINCT ON: a priority_v2 gera 2 recommendation_id duplicados (mesmo
-- search_term "seladora vacuo" em datas diferentes que colapsam no mesmo id
-- md5). Bug latente pequeno no silver de search term; aqui fica 1 por id, a
-- de maior prioridade. Sem isso o indice unico (que a tela precisa) nao cria.
SELECT DISTINCT ON (recommendation_id) *
FROM marketcloud_gold.gold_recommendation_priority_v2
ORDER BY recommendation_id, priority_score DESC NULLS LAST;

CREATE UNIQUE INDEX idx_prio_mv_pk
    ON marketcloud_gold.gold_recommendation_priority_mv (recommendation_id);
CREATE INDEX idx_prio_mv_tenant
    ON marketcloud_gold.gold_recommendation_priority_mv (tenant_id, priority_rank);
CREATE INDEX idx_prio_mv_acao
    ON marketcloud_gold.gold_recommendation_priority_mv (final_action_type);

COMMENT ON MATERIALIZED VIEW marketcloud_gold.gold_recommendation_priority_mv IS
    'Envelope operacional materializado (a view v2 calcula; esta guarda). Refresh no refresh_swarm_state_and_target(). Sem isso a tela levava 84s. DISTINCT ON dedup os 2 ids repetidos do silver de search term.';

-- refresh CONCURRENTLY (nao trava leitura da tela); exige o indice unico acima.
CREATE OR REPLACE FUNCTION marketcloud_bronze.refresh_priority_mv()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY marketcloud_gold.gold_recommendation_priority_mv;
EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW marketcloud_gold.gold_recommendation_priority_mv;
END; $$;
