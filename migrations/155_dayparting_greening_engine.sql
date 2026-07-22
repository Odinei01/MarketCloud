-- 155_dayparting_greening_engine.sql
-- Motor DETERMINISTICO de "esverdear" o heatmap. Sem LLM, sem aleatoriedade:
-- cada celula keyword x hora recebe uma acao por REGRA FIXA sobre o dado maduro
-- + shrinkage. Mesma entrada -> mesma saida. Somente LEITURA (recomenda; nao gasta).
-- Aplicar dinheiro continua atras do executor gated (pilotos).
--
-- Constantes (todas explicitas, auditaveis):
--   MATURA        = data entre CURRENT_DATE-28 e CURRENT_DATE-7 (atribuicao 7d fechada)
--   TARGET_ROAS   = 3.0  (break-even)
--   FEED_ROAS     = 6.0  (2x break-even p/ merecer bid acima da base)
--   K_SHRINK      = 15   (forca do prior; w = clicks/(clicks+K))
--   MIN_CLICKS    = 5    (abaixo disso: amostra fraca -> AGUARDAR)
--   MIN_CLICKS_KW = 20   (amostra p/ condenar a keyword inteira)
--   FLOOR_MULT    = 20%  (corte: leva a hora pro piso)
--   MAX_UPLIFT    = 150% (teto do "alimentar", nunca corre solto)

DROP VIEW IF EXISTS marketcloud_gold.v_dayparting_greening_scoreboard;
DROP VIEW IF EXISTS marketcloud_gold.v_dayparting_greening_cells;

CREATE VIEW marketcloud_gold.v_dayparting_greening_cells AS
WITH mature AS (
  SELECT COALESCE(NULLIF(keyword_text,''),'(sem texto)') AS keyword_text,
         max(keyword_id)   AS keyword_id,
         max(campaign_id)  AS campaign_id,
         max(campaign_name) AS campaign_name,
         event_hour,
         sum(spend)::numeric   AS spend,
         sum(sales_7d)::numeric AS sales,
         sum(clicks)::numeric   AS clicks
  FROM marketcloud_bronze.bronze_ams_hourly_target
  WHERE data_date BETWEEN CURRENT_DATE - 28 AND CURRENT_DATE - 7
  GROUP BY 1, 5
  HAVING sum(spend) > 0
),
kw_prior AS (   -- prior = ROAS da keyword inteira (todas as horas maduras)
  SELECT keyword_text,
         CASE WHEN sum(spend) > 0 THEN sum(sales)/sum(spend) ELSE 0 END AS kw_roas,
         sum(clicks) AS kw_clicks,
         sum(spend)  AS kw_spend,
         sum(sales)  AS kw_sales
  FROM mature GROUP BY 1
),
scored AS (
  SELECT m.*,
         k.kw_roas, k.kw_clicks, k.kw_spend, k.kw_sales,
         CASE WHEN m.spend > 0 THEN m.sales/m.spend ELSE 0 END AS raw_roas,
         (m.clicks/(m.clicks + 15.0)) AS w
  FROM mature m JOIN kw_prior k USING (keyword_text)
),
final AS (
  SELECT s.*,
         -- ROAS encolhido: mistura a celula com o prior da keyword (robusto a amostra fina)
         round(s.w * s.raw_roas + (1 - s.w) * s.kw_roas, 2) AS shrunk_roas,
         -- flag da KEYWORD (nivel keyword, separado da acao da celula):
         --   MATAR so com evidencia forte (>=60 cliques); VIGIAR 20-59; senao ok.
         --   nunca se mata keyword no ruido de 20 cliques.
         CASE WHEN s.kw_roas < 3.0 AND s.kw_clicks >= 60 THEN 'MATAR'
              WHEN s.kw_roas < 3.0 AND s.kw_clicks >= 20 THEN 'VIGIAR'
              ELSE 'ok' END AS kw_flag
  FROM scored s
)
SELECT
  keyword_text, keyword_id, campaign_id, campaign_name, event_hour,
  round(spend,2) AS spend, round(sales,2) AS sales, clicks,
  round(raw_roas,2) AS raw_roas, shrunk_roas,
  round(kw_roas,2) AS kw_roas, kw_clicks, kw_flag,
  -- ACAO da celula (nivel hora), independente da flag da keyword:
  CASE
    WHEN clicks < 5             THEN 'HOLD'   -- amostra fraca: nao age no ruido
    WHEN shrunk_roas < 3.0      THEN 'CUT'    -- hora morta com amostra: corta pro piso
    WHEN shrunk_roas >= 6.0     THEN 'FEED'   -- hora vencedora: alimenta acima da base
    ELSE                             'KEEP'   -- saudavel: mantem base
  END AS action,
  CASE
    WHEN clicks < 5         THEN NULL                                  -- herda o vigente
    WHEN shrunk_roas < 3.0  THEN 20                                    -- piso
    WHEN shrunk_roas >= 6.0 THEN LEAST(150, GREATEST(100, (round(shrunk_roas/3.0*100/10.0)*10)::int))
    ELSE                         100
  END AS suggested_multiplier,
  CASE
    WHEN clicks < 5         THEN 'amostra fraca ('||clicks||' cliques): aguardar mais dado antes de agir'
    WHEN shrunk_roas < 3.0  THEN 'hora morta: ROAS '||shrunk_roas||' < meta 3.0 -> cortar bid pro piso'
    WHEN shrunk_roas >= 6.0 THEN 'hora vencedora: ROAS '||shrunk_roas||' >= 6.0 -> alimentar (bid acima da base)'
    ELSE                         'hora saudavel: ROAS '||shrunk_roas||' entre 3 e 6 -> manter base'
  END AS reason
FROM final;

-- Placar: quanto do gasto MADURO ja e verde, e quanto pode ficar depois de cortar o morto.
CREATE VIEW marketcloud_gold.v_dayparting_greening_scoreboard AS
WITH c AS (SELECT * FROM marketcloud_gold.v_dayparting_greening_cells)
SELECT
  round(sum(spend),2)                                              AS gasto_total,
  round(sum(spend) FILTER (WHERE raw_roas >= 3.0),2)               AS gasto_verde,
  round(100*sum(spend) FILTER (WHERE raw_roas >= 3.0)/NULLIF(sum(spend),0),1) AS pct_verde_hoje,
  round(sum(spend) FILTER (WHERE action='CUT' OR kw_flag='MATAR'),2)          AS gasto_a_cortar,
  round(sum(spend) FILTER (WHERE action = 'FEED'),2)              AS gasto_a_alimentar,
  -- potencial: se cortar todo o morto (celula CUT + keyword MATAR), que % do gasto restante e verde
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
