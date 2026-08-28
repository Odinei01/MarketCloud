-- 253: atualiza o sync para o novo contrato da descoberta (share em vez de cobertura).
--
-- A 251/252 trocaram cobertura_pct por share_pct e removeram buscas_nao_alcancadas, mas
-- a funcao de sync continuava lendo os nomes antigos: quebrou, e o cerebro ficou lendo
-- a versao anterior — ainda dentro dos 7 dias de frescor, portanto SEM alarme. Foi a
-- pior forma de falhar: silenciosa e com o dado velho parecendo valido.
--
-- Mapeamento para o contrato que o cerebro ja consome:
--   cobertura_pct         <- share_pct (impression share real, mesma semantica: presenca)
--   buscas_nao_alcancadas <- impressoes de mercado que NAO foram nossas
-- Assim o cerebro nao muda: continua priorizando quem tem menos presenca e mais espaco.

CREATE OR REPLACE FUNCTION marketcloud_gold.sync_descoberta_zm19_para_robo()
RETURNS bigint LANGUAGE plpgsql AS $function$
DECLARE
    n bigint;
BEGIN
    DELETE FROM swarm_src.zm19_asin_discovery_priority;

    INSERT INTO swarm_src.zm19_asin_discovery_priority
        (asin, decisao, volume_mercado, cobertura_pct, buscas_nao_alcancadas, compras, cvr_pct, atualizado_em)
    SELECT UPPER(d.asin), COALESCE(d.decisao,'SEM_SINAL'),
           d.volume_mercado,
           d.share_pct,
           GREATEST(COALESCE(d.impressoes_mercado,0) - COALESCE(d.impressoes,0), 0),
           d.compras, d.cvr_pct, NOW()
    FROM marketcloud_gold.v_descoberta_asin_v1 d
    WHERE d.asin IS NOT NULL AND d.decisao IS NOT NULL;

    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END; $function$;
