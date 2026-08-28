-- 255: numero de estratos vira parametro, e o default sobe de 5 para 10.
--
-- Com corte de 7 cliques o experimento ganha amostra (122 celulas, 75,7% do gasto contra
-- 61% no corte de 10), mas o pareamento piorou: controle 4,81 x tratamento 4,26, 13% de
-- desequilibrio — pior que os 3% do corte de 10.
--
-- A causa e variancia dentro do bloco: com 5 estratos e ~24 celulas cada, 6 vao para
-- controle e um outlier desloca a media do grupo. Mais estratos = blocos menores = menos
-- espaco para o acaso separar os grupos. E o mesmo principio do pareamento, aplicado com
-- granularidade maior.

CREATE OR REPLACE FUNCTION marketcloud_control.propoe_holdout_pareado(
    p_seed         text    DEFAULT 'resorteio-2026-08',
    p_pct_controle numeric DEFAULT 0.25,
    p_min_cliques  numeric DEFAULT 10,
    p_estratos     integer DEFAULT 10
) RETURNS TABLE(grupo text, celulas bigint, roas_pre_medio numeric) LANGUAGE plpgsql AS $function$
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
    estratificado AS (
        SELECT b.*, (venda/NULLIF(gasto,0))::numeric roas_pre,
               ntile(p_estratos) OVER (ORDER BY venda/NULLIF(gasto,0)) estrato
        FROM base b
    ),
    ordenado AS (
        SELECT e.*,
               row_number() OVER (PARTITION BY estrato
                                  ORDER BY md5(campaign_name||':'||event_hour||':'||p_seed)) rn,
               count(*)    OVER (PARTITION BY estrato) n_estrato
        FROM estratificado e
    )
    SELECT campaign_name, event_hour,
           CASE WHEN rn <= GREATEST(1, round(n_estrato * p_pct_controle)) THEN 'CONTROLE' ELSE 'TRATAMENTO' END,
           estrato, ROUND(roas_pre,2), cliques, p_seed
    FROM ordenado;

    RETURN QUERY
    SELECT p.grupo, COUNT(*)::bigint, ROUND(AVG(p.roas_pre),2)
    FROM marketcloud_control.holdout_cells_proposta p
    WHERE p.seed = p_seed GROUP BY p.grupo;
END; $function$;
