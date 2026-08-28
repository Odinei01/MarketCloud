-- 242: o swarm-sync NUNCA completava — apontava para uma matview que nao existe mais.
--
-- SINTOMA: bronze_swarm_negatives, bid_schedule, current_bids e campaign_metrics todas
-- com 0 linhas, apesar do worker rodar a cada intervalo.
--
-- CAUSA: refresh_priority_mv() faz REFRESH de gold_recommendation_priority_mv, que foi
-- APAGADA no DROP CASCADE da migration 169 (remocao da cadeia de recomendacao ML V1).
-- O EXCEPTION da funcao tentava o refresh nao-concorrente — que falha pelo mesmo motivo,
-- relacao inexistente. O erro escapava e abortava a transacao INTEIRA de
-- refresh_swarm_state_and_target(), desfazendo tambem os DELETE+INSERT do swarm state
-- e o refresh do alvo do ML que ja tinham rodado antes.
--
-- Ou seja: o deadlock que aparecia no log era o sintoma barulhento; por baixo, o sync
-- falhava em TODA execucao, silenciosamente, desde a migration 169.
--
-- CORRECAO: checar a existencia da matview antes de mexer nela. Se um dia ela voltar,
-- volta a ser refrescada sozinha — sem precisar lembrar de editar esta funcao.

CREATE OR REPLACE FUNCTION marketcloud_bronze.refresh_priority_mv()
RETURNS void LANGUAGE plpgsql AS $function$
BEGIN
    IF to_regclass('marketcloud_gold.gold_recommendation_priority_mv') IS NULL THEN
        RETURN;  -- removida com a cadeia ML V1 (migration 169). Nada a refrescar.
    END IF;
    BEGIN
        REFRESH MATERIALIZED VIEW CONCURRENTLY marketcloud_gold.gold_recommendation_priority_mv;
    EXCEPTION WHEN OTHERS THEN
        REFRESH MATERIALIZED VIEW marketcloud_gold.gold_recommendation_priority_mv;
    END;
END; $function$;

-- O orquestrador tambem contava linhas da matview fantasma. So reporta o que existe.
CREATE OR REPLACE FUNCTION marketcloud_bronze.refresh_swarm_state_and_target()
RETURNS TABLE(source_table text, rows_inserted bigint) LANGUAGE plpgsql AS $function$
DECLARE
    n bigint;
BEGIN
    RETURN QUERY SELECT * FROM marketcloud_bronze.refresh_swarm_account_state();

    PERFORM marketcloud_bronze.refresh_ml_target_mv();
    source_table := 'gold_hourly_ml_target_mv';
    rows_inserted := (SELECT count(*) FROM marketcloud_gold.gold_hourly_ml_target_mv);
    RETURN NEXT;

    PERFORM marketcloud_bronze.refresh_priority_mv();
    IF to_regclass('marketcloud_gold.gold_recommendation_priority_mv') IS NOT NULL THEN
        EXECUTE 'SELECT count(*) FROM marketcloud_gold.gold_recommendation_priority_mv' INTO n;
        source_table := 'gold_recommendation_priority_mv';
        rows_inserted := n;
        RETURN NEXT;
    END IF;
END; $function$;
