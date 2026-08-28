-- 257: pareia tambem por GASTO, nao so por ROAS.
--
-- O ERRO: estratifiquei por quintil de ROAS e conferi o equilibrio pela MEDIA SIMPLES das
-- celulas — 4,35 x 4,42, otimo. Mas a leitura do holdout usa ROAS AGREGADO, que e
-- ponderado por gasto. Nessa metrica os grupos saem 5,05 x 4,51: 12% de desequilibrio.
--
-- Equilibrei a metrica errada. Duas celulas com o mesmo ROAS pesam diferente se uma gasta
-- R$5 e a outra R$80, e o pareamento ignorava isso.
--
-- CORRECAO: estratificacao dupla. Dentro de cada bloco de ROAS, subdivide por gasto e
-- sorteia so entao. Assim controle e tratamento ficam parecidos nas duas dimensoes que
-- determinam o agregado.

CREATE OR REPLACE FUNCTION marketcloud_control.propoe_holdout_pareado(
    p_seed         text    DEFAULT 'resorteio-2026-08',
    p_pct_controle numeric DEFAULT 0.25,
    p_min_cliques  numeric DEFAULT 10,
    p_estratos     integer DEFAULT 10,
    p_estratos_gasto integer DEFAULT 3
) RETURNS TABLE(grupo text, celulas bigint, roas_simples numeric, roas_ponderado numeric) LANGUAGE plpgsql AS $function$
BEGIN
    DELETE FROM marketcloud_control.holdout_cells_proposta WHERE seed = p_seed;

    INSERT INTO marketcloud_control.holdout_cells_proposta
        (campaign_name, event_hour, grupo, estrato, roas_pre, cliques_pre, seed)
    WITH base AS (
        SELECT g.campaign_name, g.event_hour,
               SUM(g.spend) gasto, SUM(g.sales_7d) venda, SUM(g.clicks) cliques
        FROM marketcloud_gold.gold_hourly_signal_amc g
        WHERE g.data_date >= CURRENT_DATE - 30
        GROUP BY g.campaign_name, g.event_hour
        HAVING SUM(g.clicks) >= p_min_cliques AND SUM(g.spend) > 0
    ),
    e1 AS (
        SELECT b.*, (venda/NULLIF(gasto,0))::numeric roas_pre,
               ntile(p_estratos) OVER (ORDER BY venda/NULLIF(gasto,0)) bloco_roas
        FROM base b
    ),
    e2 AS (
        -- dentro do bloco de ROAS, subdivide por gasto: o agregado e ponderado por ele
        SELECT e1.*, ntile(p_estratos_gasto) OVER (PARTITION BY bloco_roas ORDER BY gasto) bloco_gasto
        FROM e1
    ),
    ordenado AS (
        SELECT e2.*,
               row_number() OVER (PARTITION BY bloco_roas, bloco_gasto
                                  ORDER BY md5(campaign_name||':'||event_hour||':'||p_seed)) rn,
               count(*)    OVER (PARTITION BY bloco_roas, bloco_gasto) n_bloco
        FROM e2
    )
    SELECT campaign_name, event_hour,
           CASE WHEN rn <= GREATEST(1, round(n_bloco * p_pct_controle)) THEN 'CONTROLE' ELSE 'TRATAMENTO' END,
           bloco_roas, ROUND(roas_pre,2), cliques, p_seed
    FROM ordenado;

    RETURN QUERY
    WITH b AS (
        SELECT p.grupo, p.roas_pre, g.gasto, g.venda
        FROM marketcloud_control.holdout_cells_proposta p
        JOIN LATERAL (
            SELECT SUM(spend) gasto, SUM(sales_7d) venda
            FROM marketcloud_gold.gold_hourly_signal_amc x
            WHERE x.campaign_name=p.campaign_name AND x.event_hour=p.event_hour
              AND x.data_date >= CURRENT_DATE - 30
        ) g ON TRUE
        WHERE p.seed = p_seed
    )
    SELECT b.grupo, COUNT(*)::bigint, ROUND(AVG(b.roas_pre),2),
           ROUND(SUM(b.venda)/NULLIF(SUM(b.gasto),0),2)
    FROM b GROUP BY b.grupo;
END; $function$;
