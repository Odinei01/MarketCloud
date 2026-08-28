-- 247: empurra a prioridade de descoberta para o robo (pricing), onde o cerebro le.
--
-- O FDW entre os bancos e unidirecional: o marketcloud le o pricing (swarm_pg), nao o
-- contrario. Como a descoberta nasce aqui (ontologia de query) e e consumida la (cerebro
-- da ZM19), quem empurra e o marketcloud.
--
-- POR QUE ISSO IMPORTA: o cerebro escolhia alvo so pelo score do concorrente, sem saber
-- quanto do mercado de cada ASIN ainda estava por cobrir. Resultado medido em 28/08: os
-- dois maiores mercados da ZM19 (71.785 e 64.643 buscas, cobertura 4,5% e 1,0%) nao
-- receberam UM clique, enquanto o cozedor de ovos — ja com 59,5% coberto — levava o
-- segundo maior gasto.
--
-- FRESCOR: o cerebro so considera linhas com menos de 7 dias. Se este sync parar, ele
-- volta sozinho ao criterio antigo em vez de decidir por cobertura velha. Dado vencido
-- e pior que dado nenhum — uma cobertura de tres semanas atras manda expandir num
-- mercado que ja foi coberto.

IMPORT FOREIGN SCHEMA public LIMIT TO (zm19_asin_discovery_priority)
FROM SERVER swarm_pg INTO swarm_src;

CREATE OR REPLACE FUNCTION marketcloud_gold.sync_descoberta_zm19_para_robo()
RETURNS bigint LANGUAGE plpgsql AS $function$
DECLARE
    n bigint;
BEGIN
    -- DELETE + INSERT, nao TRUNCATE: TRUNCATE pega ACCESS EXCLUSIVE e ja causou deadlock
    -- contra REFRESH CONCURRENTLY (migration 241). A tabela tem dezenas de linhas.
    DELETE FROM swarm_src.zm19_asin_discovery_priority;

    INSERT INTO swarm_src.zm19_asin_discovery_priority
        (asin, decisao, volume_mercado, cobertura_pct, buscas_nao_alcancadas, compras, cvr_pct, atualizado_em)
    SELECT UPPER(asin), COALESCE(decisao,'SEM_SINAL'),
           volume_mercado, cobertura_pct, buscas_nao_alcancadas, compras, cvr_pct, NOW()
    FROM marketcloud_gold.v_descoberta_zm19_v1
    WHERE asin IS NOT NULL
      AND decisao IS NOT NULL;   -- ASIN sem dado de descoberta nao vira decisao

    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END; $function$;

COMMENT ON FUNCTION marketcloud_gold.sync_descoberta_zm19_para_robo() IS
'Empurra v_descoberta_zm19_v1 para zm19_asin_discovery_priority no banco do robo, onde o cerebro da ZM19 le. O cerebro so usa linhas com menos de 7 dias.';
