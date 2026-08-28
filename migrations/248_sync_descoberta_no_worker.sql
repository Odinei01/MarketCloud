-- 248: o sync da descoberta passa a rodar junto do swarm-sync.
--
-- refresh_swarm_state_and_target() ja e o worker que empurra estado do marketcloud para
-- o banco do robo, no intervalo do swarm-sync. A descoberta e a mesma classe de dado
-- (marketcloud calcula, robo consome), entao vai junto em vez de virar mais um worker.
--
-- Isolado em BEGIN/EXCEPTION de proposito: se a descoberta falhar, o swarm state NAO
-- pode cair junto. Foi exatamente esse acoplamento que quebrou o sync inteiro por meses
-- (migration 242) — uma matview inexistente abortava a transacao toda.

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

    -- descoberta -> robo. Falha aqui nao derruba o resto.
    BEGIN
        n := marketcloud_gold.sync_descoberta_zm19_para_robo();
        source_table := 'zm19_asin_discovery_priority';
        rows_inserted := n;
        RETURN NEXT;
    EXCEPTION WHEN OTHERS THEN
        source_table := 'zm19_asin_discovery_priority (FALHOU: ' || SQLERRM || ')';
        rows_inserted := 0;
        RETURN NEXT;
    END;
END; $function$;
