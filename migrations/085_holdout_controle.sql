-- GRUPO DE CONTROLE (holdout) — a peca que faltava pra saber se o robo ajuda.
--
-- Por que: em 15/07 o placar de 24.200 mudancas medidas deu 18,4% de acerto e
-- delta de ROAS -3,01. Mas os rotulos denunciam REGRESSAO A MEDIA, nao efeito:
--   LOST_ROAS  2.088 linhas: ROAS 7,75 -> 2,12  (agiu numa hora de sorte, voltou)
--   WON_ROAS   5.020 linhas: ROAS 1,65 -> 4,83  (agiu numa hora de azar, voltou)
-- Sem contrafactual e impossivel separar o que o robo fez do que teria
-- acontecido sozinho. Nenhum volume de medida resolve isso — so um controle.
--
-- Desenho: 20% das celulas campanha x hora ficam CONGELADAS como controle. O
-- robo nunca as toca. A atribuicao e sorteada por hash (deterministica), mas
-- GRAVADA numa tabela — se ficasse sendo recalculada, mudaria junto com os
-- dados e a comparacao perderia sentido.
--
-- Estratificado POR CAMPANHA: ~5 das 24 horas de cada campanha. Assim a
-- comparacao e sempre dentro da mesma campanha, e nenhuma campanha fica
-- inteira de fora (o dono nao perde uma campanha pro experimento).
CREATE TABLE IF NOT EXISTS marketcloud_control.holdout_cells (
    campaign_name TEXT NOT NULL,
    event_hour    SMALLINT NOT NULL,
    grupo         TEXT NOT NULL CHECK (grupo IN ('CONTROLE','TRATAMENTO')),
    sorteado_em   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    motivo        TEXT,
    PRIMARY KEY (campaign_name, event_hour)
);

COMMENT ON TABLE marketcloud_control.holdout_cells IS
    'Grupo de controle do robo: celulas campanha x hora que NUNCA sao alteradas. Congelado no sorteio — nao recalcular.';

-- Sorteio unico. ON CONFLICT DO NOTHING: rodar de novo nao re-sorteia ninguem,
-- so inclui campanha/hora nova que passou a existir.
INSERT INTO marketcloud_control.holdout_cells (campaign_name, event_hour, grupo, motivo)
SELECT campaign_name, event_hour,
       CASE WHEN ordem <= 5 THEN 'CONTROLE' ELSE 'TRATAMENTO' END,
       'sorteio inicial 15/07: 5 das 24 horas por campanha'
FROM (
    SELECT campaign_name, event_hour,
           row_number() OVER (
               PARTITION BY campaign_name
               -- hash do par = sorteio deterministico e estavel
               ORDER BY md5(campaign_name || ':' || event_hour::text)
           ) AS ordem
    FROM (
        SELECT DISTINCT campaign_name, event_hour
        FROM marketcloud_gold.gold_hourly_signal_amc
        WHERE campaign_name IS NOT NULL
    ) celulas
) sorteio
ON CONFLICT (campaign_name, event_hour) DO NOTHING;

-- Leitura do experimento: controle vs tratamento, dentro de cada campanha.
-- So compara o que aconteceu DEPOIS do sorteio — antes disso os dois grupos
-- viveram a mesma vida e a diferenca nao significaria nada.
CREATE OR REPLACE VIEW marketcloud_gold.gold_holdout_leitura AS
WITH desde AS (SELECT min(sorteado_em)::date AS d0 FROM marketcloud_control.holdout_cells),
depois AS (
    SELECT g.campaign_name, g.event_hour,
           sum(g.spend) AS gasto, sum(g.sales_7d) AS venda, sum(g.clicks) AS cliques,
           count(DISTINCT g.data_date) AS dias
    FROM marketcloud_gold.gold_hourly_signal_amc g, desde
    WHERE g.data_date >= desde.d0
    GROUP BY 1,2
)
SELECT h.grupo,
       count(*)                                            AS celulas,
       sum(d.dias)                                         AS dias_observados,
       round(sum(d.gasto)::numeric,2)                      AS gasto,
       round(sum(d.venda)::numeric,2)                      AS venda,
       round((sum(d.venda)/NULLIF(sum(d.gasto),0))::numeric,2) AS roas,
       round((sum(d.cliques))::numeric,0)                  AS cliques
FROM marketcloud_control.holdout_cells h
JOIN depois d ON d.campaign_name = h.campaign_name AND d.event_hour = h.event_hour
GROUP BY 1;

COMMENT ON VIEW marketcloud_gold.gold_holdout_leitura IS
    'Placar do experimento: ROAS do grupo tratado vs controle, so no periodo APOS o sorteio. Precisa de semanas de acumulo — ler cedo demais e ler ruido.';
