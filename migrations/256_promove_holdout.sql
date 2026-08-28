-- 256: promocao do holdout pareado. Exige confirmacao explicita e preserva o historico.
--
-- CONFIGURACAO ESCOLHIDA (corte de 7 cliques, 10 estratos):
--     CONTROLE    30 celulas, ROAS pre 4,35
--     TRATAMENTO  92 celulas, ROAS pre 4,42
--     desequilibrio 1,6% (era 19% no sorteio de 16/07)
--     122 celulas cobrindo 75,7% do gasto de 30 dias
--
-- 10 estratos e o ponto: com 5 o desequilibrio era 13%, com 15 sobe para 3,4%.
--
-- O QUE A PROMOCAO CUSTA: as celulas trocam de grupo, entao os 43 dias acumulados desde
-- 16/07 deixam de ser comparaveis e o relogio recomeca. Em troca, a proxima leitura mede
-- o robo em vez de medir o sorteio — a atual nao mede nem uma coisa nem outra.
--
-- O holdout antigo vai INTEIRO para holdout_cells_historico antes de qualquer escrita.
-- Reverter e um INSERT de volta.
--
-- p_confirmo existe para que promover seja um ato deliberado: chamar a funcao sem ele
-- nao muda nada. Isso mexe em dinheiro real — celula marcada CONTROLE deixa de ser
-- otimizada pelo robo.

CREATE TABLE IF NOT EXISTS marketcloud_control.holdout_cells_historico (
    campaign_name TEXT, event_hour SMALLINT, grupo TEXT,
    sorteado_em TIMESTAMPTZ, motivo TEXT,
    arquivado_em TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    arquivado_por TEXT
);

CREATE OR REPLACE FUNCTION marketcloud_control.promove_holdout(
    p_seed     text,
    p_confirmo boolean DEFAULT false,
    p_motivo   text    DEFAULT 'resorteio pareado por quintil de ROAS pre-tratamento'
) RETURNS TABLE(acao text, detalhe text) LANGUAGE plpgsql AS $function$
DECLARE
    n_prop bigint;
    n_ctrl bigint;
BEGIN
    SELECT COUNT(*), COUNT(*) FILTER (WHERE grupo='CONTROLE')
      INTO n_prop, n_ctrl
      FROM marketcloud_control.holdout_cells_proposta WHERE seed = p_seed;

    IF n_prop = 0 THEN
        RETURN QUERY SELECT 'ABORTADO', 'seed sem proposta: ' || p_seed; RETURN;
    END IF;

    IF NOT p_confirmo THEN
        RETURN QUERY SELECT 'SIMULACAO',
            format('promoveria %s celulas (%s CONTROLE) da seed %s. Chame com p_confirmo => true para aplicar.',
                   n_prop, n_ctrl, p_seed);
        RETURN;
    END IF;

    INSERT INTO marketcloud_control.holdout_cells_historico
        (campaign_name, event_hour, grupo, sorteado_em, motivo, arquivado_por)
    SELECT campaign_name, event_hour, grupo, sorteado_em, motivo, p_seed
    FROM marketcloud_control.holdout_cells;

    DELETE FROM marketcloud_control.holdout_cells;

    INSERT INTO marketcloud_control.holdout_cells (campaign_name, event_hour, grupo, sorteado_em, motivo)
    SELECT campaign_name, event_hour, grupo, NOW(), p_motivo
    FROM marketcloud_control.holdout_cells_proposta WHERE seed = p_seed;

    RETURN QUERY SELECT 'PROMOVIDO',
        format('%s celulas ativas (%s CONTROLE). Anterior arquivado em holdout_cells_historico.', n_prop, n_ctrl);
END; $function$;

COMMENT ON FUNCTION marketcloud_control.promove_holdout(text,boolean,text) IS
'Promove uma proposta de holdout para producao. Sem p_confirmo => true apenas simula. Arquiva o holdout anterior em holdout_cells_historico antes de escrever.';
