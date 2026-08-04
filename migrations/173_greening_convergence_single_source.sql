-- 173_greening_convergence_single_source.sql
-- CONVERGENCIA: ML x Dayparting x Esverdeamento -> UMA publicacao so.
--
-- Antes: v_dayparting_greening_cells (155) tinha thresholds PROPRIOS (ROAS 3/6 hard,
-- teto FEED 150%) que DISCORDAVAM do que o robo aplica. O heatmap dizia "ALIMENTAR
-- 150%" e o robo aplicava <=100% -> "campenga" (indicadores brigando).
--
-- Agora: o heatmap LE a MESMA fonte publicada que o robo aplica:
--   gold_keyword_hourly_calibration_v1 (ultimo computed_at)
--   = Bayes-shrinkage sobre ROAS real  x  nudge do ML (conversion_probability)
--   = ja capado em 100% pelo _dp_bucket_from_signal (bucket ladder topo 1.00).
-- Uma fonte, uma verdade: o que voce ve verde e EXATAMENTE o que a Amazon recebe.
--
-- REGRA DURA (dono): NUNCA boost > 100%. A fonte ja garante (max recommended=1.00);
-- a acao FEED aqui e so um ROTULO ("hora vencedora, mantida CHEIA"), multiplicador=100.
-- Nunca acima da base.

DROP VIEW IF EXISTS marketcloud_gold.v_dayparting_greening_scoreboard;
DROP VIEW IF EXISTS marketcloud_gold.v_dayparting_greening_cells;

CREATE VIEW marketcloud_gold.v_dayparting_greening_cells AS
WITH latest AS (
  SELECT keyword_id, keyword_text, campaign_id, event_hour,
         clicks, spend, sales, hour_roas, recommended_multiplier, gate
  FROM marketcloud_gold.gold_keyword_hourly_calibration_v1
  WHERE computed_at = (SELECT max(computed_at)
                       FROM marketcloud_gold.gold_keyword_hourly_calibration_v1)
),
kw AS (   -- flag NIVEL KEYWORD: ROAS real agregado da keyword (todas as horas)
  SELECT keyword_id,
         CASE WHEN sum(spend) > 0 THEN sum(sales)/sum(spend) ELSE 0 END AS kw_roas,
         sum(clicks) AS kw_clicks
  FROM latest GROUP BY 1
)
SELECT
  COALESCE(NULLIF(l.keyword_text,''),'(sem texto)') AS keyword_text,
  l.keyword_id, l.campaign_id,
  COALESCE(cn.campaign_name, l.campaign_id) AS campaign_name,
  l.event_hour,
  round(l.spend,2) AS spend, round(l.sales,2) AS sales, l.clicks::int AS clicks,
  -- raw_roas = ROAS real da CELULA (pro placar de verde); shrunk = blend ML x dayparting
  CASE WHEN l.spend > 0 THEN round(l.sales/l.spend,2) ELSE 0 END AS raw_roas,
  round(l.hour_roas,2) AS shrunk_roas,
  round(k.kw_roas,2) AS kw_roas, k.kw_clicks::int AS kw_clicks,
  -- flag da keyword: MATAR so com evidencia forte (>=60 cl); VIGIAR 20-59; senao ok
  CASE WHEN k.kw_roas < 3.0 AND k.kw_clicks >= 60 THEN 'MATAR'
       WHEN k.kw_roas < 3.0 AND k.kw_clicks >= 20 THEN 'VIGIAR'
       ELSE 'ok' END AS kw_flag,
  -- ACAO da celula DERIVADA da fonte publicada (o que o robo aplica):
  CASE
    WHEN l.gate <> 'OK'                                    THEN 'HOLD'  -- sem dado: herda
    WHEN l.recommended_multiplier < 1.00                  THEN 'CUT'    -- bid abaixo da base
    WHEN l.hour_roas >= 6.0                               THEN 'FEED'   -- vencedora: CHEIA (100)
    ELSE                                                       'KEEP'   -- saudavel: base
  END AS action,
  -- multiplicador = EXATAMENTE o publicado (0..100), NUNCA > 100
  round(l.recommended_multiplier * 100)::int AS suggested_multiplier,
  CASE
    WHEN l.gate <> 'OK'                   THEN 'sem historico na hora: herda o vigente'
    WHEN l.recommended_multiplier < 1.00  THEN 'ROAS blend '||round(l.hour_roas,1)||' -> corta pra '||round(l.recommended_multiplier*100)||'% (economia)'
    WHEN l.hour_roas >= 6.0               THEN 'hora vencedora (ROAS '||round(l.hour_roas,1)||'): mantida CHEIA 100% (nunca acima da base)'
    ELSE                                       'hora saudavel (ROAS '||round(l.hour_roas,1)||'): mantem base 100%'
  END AS reason
FROM latest l
JOIN kw k USING (keyword_id)
LEFT JOIN marketcloud_bronze.bronze_swarm_campaign_names cn ON cn.campaign_id = l.campaign_id;

-- Placar: quanto do gasto ja e verde (celula ROAS real >=3) e o potencial pos-corte.
CREATE VIEW marketcloud_gold.v_dayparting_greening_scoreboard AS
WITH c AS (SELECT * FROM marketcloud_gold.v_dayparting_greening_cells)
SELECT
  round(sum(spend),2)                                              AS gasto_total,
  round(sum(spend) FILTER (WHERE raw_roas >= 3.0),2)              AS gasto_verde,
  round(100*sum(spend) FILTER (WHERE raw_roas >= 3.0)/NULLIF(sum(spend),0),1) AS pct_verde_hoje,
  round(sum(spend) FILTER (WHERE action='CUT' OR kw_flag='MATAR'),2)          AS gasto_a_cortar,
  round(sum(spend) FILTER (WHERE action='FEED'),2)               AS gasto_a_alimentar,
  round(100*sum(spend) FILTER (WHERE raw_roas >= 3.0)
        /NULLIF(sum(spend) FILTER (WHERE NOT (action='CUT' OR kw_flag='MATAR')),0),1) AS pct_verde_potencial,
  round(sum(sales),2)                                             AS vendas_total,
  count(*)                                                        AS celulas,
  count(*) FILTER (WHERE action='CUT')          AS n_cortar,
  count(*) FILTER (WHERE action='FEED')         AS n_alimentar,
  count(*) FILTER (WHERE action='KEEP')         AS n_manter,
  count(*) FILTER (WHERE action='HOLD')         AS n_aguardar,
  count(DISTINCT keyword_text) FILTER (WHERE kw_flag='MATAR')  AS n_keywords_matar,
  count(DISTINCT keyword_text) FILTER (WHERE kw_flag='VIGIAR') AS n_keywords_vigiar
FROM c;
