-- 254: re-sorteio PAREADO do holdout. Proposta, nao promocao — nada muda sozinho.
--
-- POR QUE REFAZER: o sorteio de 16/07 nao equilibrou a linha de base. Medido agora,
-- 43 dias depois:
--     grupo        antes   depois   variacao
--     CONTROLE      2,68    4,97     +85%
--     TRATAMENTO    3,29    4,59     +40%
-- O controle partiu 19% ABAIXO do tratamento. Comparar os dois so no 'depois' dava
-- +56% a favor do robo; com a linha de base descontada, o diff-in-diff da -45pp CONTRA.
-- Nenhum dos dois numeros mede o robo: medem de onde cada grupo partiu.
--
-- Sem pareamento, cada leitura futura vai continuar dependendo do sorteio. E isso decide
-- se o robo continua mexendo em dinheiro real.
--
-- COMO PAREIA: estratifica as celulas por quintil de ROAS dos ultimos 30 dias e sorteia
-- DENTRO de cada quintil. Assim controle e tratamento nascem com a mesma distribuicao de
-- desempenho, e o 'antes' deixa de explicar o 'depois'.
--
-- SORTEIO DETERMINISTICO: a ordem vem de md5(celula || seed), nao de random(). Rodar duas
-- vezes com a mesma seed da o mesmo resultado — o sorteio fica auditavel, e ninguem pode
-- reexecutar ate sair um grupo conveniente.
--
-- Celula sem historico suficiente (menos de 10 cliques em 30 dias) fica FORA: sortear
-- ruido nao cria contrafactual, so dilui o experimento.

CREATE TABLE IF NOT EXISTS marketcloud_control.holdout_cells_proposta (
    campaign_name   TEXT        NOT NULL,
    event_hour      SMALLINT    NOT NULL,
    grupo           TEXT        NOT NULL,
    estrato         SMALLINT    NOT NULL,
    roas_pre        NUMERIC,
    cliques_pre     NUMERIC,
    seed            TEXT        NOT NULL,
    proposto_em     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (campaign_name, event_hour, seed)
);

CREATE OR REPLACE FUNCTION marketcloud_control.propoe_holdout_pareado(
    p_seed        text    DEFAULT 'resorteio-2026-08',
    p_pct_controle numeric DEFAULT 0.25,
    p_min_cliques numeric DEFAULT 10
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
               ntile(5) OVER (ORDER BY venda/NULLIF(gasto,0)) estrato
        FROM base b
    ),
    ordenado AS (
        SELECT e.*,
               -- ordem deterministica dentro do estrato
               row_number() OVER (PARTITION BY estrato
                                  ORDER BY md5(campaign_name||':'||event_hour||':'||p_seed)) rn,
               count(*)    OVER (PARTITION BY estrato) n_estrato
        FROM estratificado e
    )
    SELECT campaign_name, event_hour,
           CASE WHEN rn <= GREATEST(1, floor(n_estrato * p_pct_controle)) THEN 'CONTROLE' ELSE 'TRATAMENTO' END,
           estrato, ROUND(roas_pre,2), cliques, p_seed
    FROM ordenado;

    RETURN QUERY
    SELECT p.grupo, COUNT(*)::bigint, ROUND(AVG(p.roas_pre),2)
    FROM marketcloud_control.holdout_cells_proposta p
    WHERE p.seed = p_seed
    GROUP BY p.grupo;
END; $function$;

COMMENT ON FUNCTION marketcloud_control.propoe_holdout_pareado(text,numeric,numeric) IS
'Propoe re-sorteio do holdout pareado por quintil de ROAS pre-tratamento. Deterministico pela seed. NAO promove: escreve so em holdout_cells_proposta.';
