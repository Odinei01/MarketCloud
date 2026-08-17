-- 202_dayparting_ml_outcome_ledger.sql
-- OUTCOME LOOP do blend ML x dayparting — gera a propria verdade.
--
-- Problema (medido na 200/201): o nudge do ML satura no clamp em ~62% das celulas
-- que opinam, e essas vivem em horas SEM dado proprio -> impossiveis de validar
-- hoje. Nao ha ground-truth pra calibrar o clamp no escuro.
--
-- Solucao: registrar a DECISAO do ML (ml_factor) por celula/dia e, semanas depois,
-- casar com o ROAS que aquela hora REALMENTE entregou. Em ~2 semanas isso vira dado
-- real das horas magras -> a proxima calibracao do clamp e data-driven, nao achismo.
--
-- Go-forward: ml_factor so existe desde a migration 200; o ledger comeca hoje.

-- 1) LEDGER append-only: 1 linha por (data do snapshot, keyword, hora).
CREATE TABLE IF NOT EXISTS marketcloud_gold.dayparting_ml_outcome_ledger (
    snapshot_date          date        NOT NULL,
    keyword_id             text        NOT NULL,
    event_hour             smallint    NOT NULL,
    keyword_text           text,
    campaign_id            text,
    ml_factor              numeric,          -- nudge do ML no dia da decisao
    ml_direction           text,             -- UP / DOWN / NEUTRO (derivado do ml_factor)
    blend_weight           numeric,          -- w = cliques/(cliques+k) no dia
    kw_roas_raw            numeric,          -- observacao propria conhecida no dia
    prior_roas             numeric,
    blended_roas           numeric,          -- hour_roas resultante
    recommended_multiplier numeric,
    action                 text,
    clicks_at_decision     numeric,          -- cliques acumulados que embasaram a decisao
    created_at             timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (snapshot_date, keyword_id, event_hour)
);

-- 2) SNAPSHOT idempotente: grava a decisao de HOJE a partir do latest da calibracao.
--    Re-rodar no mesmo dia sobrescreve (ON CONFLICT). So celulas com ml_factor.
CREATE OR REPLACE FUNCTION marketcloud_gold.snapshot_dayparting_ml_outcome(p_date date DEFAULT NULL)
  RETURNS integer LANGUAGE plpgsql AS $fn$
DECLARE v_date date := COALESCE(p_date, (now() AT TIME ZONE 'America/Sao_Paulo')::date); v_rows int;
BEGIN
    INSERT INTO marketcloud_gold.dayparting_ml_outcome_ledger AS l (
        snapshot_date, keyword_id, event_hour, keyword_text, campaign_id,
        ml_factor, ml_direction, blend_weight, kw_roas_raw, prior_roas,
        blended_roas, recommended_multiplier, action, clicks_at_decision)
    SELECT
        v_date, c.keyword_id, c.event_hour, NULLIF(c.keyword_text,''), c.campaign_id,
        c.ml_factor,
        CASE WHEN c.ml_factor > 1.02 THEN 'UP' WHEN c.ml_factor < 0.98 THEN 'DOWN' ELSE 'NEUTRO' END,
        c.blend_weight, c.kw_roas_raw, c.prior_roas,
        c.hour_roas, c.recommended_multiplier, c.action, c.clicks
    FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1 c
    WHERE c.ml_factor IS NOT NULL AND c.keyword_id IS NOT NULL
    ON CONFLICT (snapshot_date, keyword_id, event_hour) DO UPDATE SET
        ml_factor=EXCLUDED.ml_factor, ml_direction=EXCLUDED.ml_direction,
        blend_weight=EXCLUDED.blend_weight, kw_roas_raw=EXCLUDED.kw_roas_raw,
        prior_roas=EXCLUDED.prior_roas, blended_roas=EXCLUDED.blended_roas,
        recommended_multiplier=EXCLUDED.recommended_multiplier, action=EXCLUDED.action,
        clicks_at_decision=EXCLUDED.clicks_at_decision, keyword_text=EXCLUDED.keyword_text,
        campaign_id=EXCLUDED.campaign_id, created_at=now();
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$fn$;

-- 3) AVALIACAO forward: casa a decisao de D com o ROAS realizado em [D+1, D+7].
--    So snapshots maduros (D <= hoje-14) — a janela forward precisa de 7 dias +
--    7 dias de atribuicao (sales_7d) pra fechar. So celulas com dado forward real
--    (fwd_clicks >= 5) sao julgaveis. kw_fwd_avg = ROAS medio da keyword nas horas
--    da mesma janela, para direcao RELATIVA (a hora foi melhor/pior que a keyword?).
CREATE OR REPLACE VIEW marketcloud_gold.v_dayparting_ml_outcome_eval AS
WITH maxd AS (SELECT max(data_date) AS md FROM marketcloud_bronze.bronze_ams_hourly_target),
fwd AS (
    SELECT l.snapshot_date, l.keyword_id, l.event_hour,
           sum(t.clicks)  AS fwd_clicks,
           sum(t.spend)   AS fwd_spend,
           sum(t.sales_7d) FILTER (WHERE t.clicks>0) AS fwd_sales
    FROM marketcloud_gold.dayparting_ml_outcome_ledger l
    JOIN marketcloud_bronze.bronze_ams_hourly_target t
      ON t.keyword_id = l.keyword_id
     AND t.event_hour::smallint = l.event_hour
     AND t.data_date >  l.snapshot_date
     AND t.data_date <= l.snapshot_date + 7
    GROUP BY 1,2,3
),
scored AS (
    SELECT l.*,
           f.fwd_clicks, f.fwd_spend,
           COALESCE(f.fwd_sales/NULLIF(f.fwd_spend,0),0) AS fwd_roas
    FROM marketcloud_gold.dayparting_ml_outcome_ledger l
    LEFT JOIN fwd f USING (snapshot_date, keyword_id, event_hour)
),
kwavg AS (   -- ROAS forward medio da keyword no dia (so horas com dado)
    SELECT snapshot_date, keyword_id,
           avg(fwd_roas) FILTER (WHERE fwd_clicks >= 5) AS kw_fwd_avg_roas
    FROM scored GROUP BY 1,2
)
SELECT s.*,
       k.kw_fwd_avg_roas,
       (SELECT md FROM maxd) AS data_disponivel_ate,
       (s.snapshot_date <= (SELECT md FROM maxd) - 14) AS maduro,
       CASE
         WHEN s.fwd_clicks IS NULL OR s.fwd_clicks < 5 OR COALESCE(k.kw_fwd_avg_roas,0)=0 THEN 'SEM_DADO_FORWARD'
         WHEN s.fwd_roas > k.kw_fwd_avg_roas*1.05 THEN 'UP'
         WHEN s.fwd_roas < k.kw_fwd_avg_roas*0.95 THEN 'DOWN'
         ELSE 'FLAT' END AS realized_direction,
       CASE
         WHEN s.fwd_clicks IS NULL OR s.fwd_clicks < 5 OR COALESCE(k.kw_fwd_avg_roas,0)=0 THEN NULL
         WHEN s.ml_direction='NEUTRO' THEN NULL
         WHEN (s.ml_direction='UP'   AND s.fwd_roas > k.kw_fwd_avg_roas*1.05)
           OR (s.ml_direction='DOWN' AND s.fwd_roas < k.kw_fwd_avg_roas*0.95) THEN true
         WHEN s.fwd_roas BETWEEN k.kw_fwd_avg_roas*0.95 AND k.kw_fwd_avg_roas*1.05 THEN NULL  -- forward FLAT: inconclusivo
         ELSE false END AS ml_acertou
FROM scored s LEFT JOIN kwavg k USING (snapshot_date, keyword_id);

-- 4) SCOREBOARD: KPI ao longo do tempo — o ML ganha o pao? (so celulas julgaveis maduras)
CREATE OR REPLACE VIEW marketcloud_gold.v_dayparting_ml_outcome_scoreboard AS
SELECT
    ml_direction,
    count(*) FILTER (WHERE maduro) AS celulas_maduras,
    count(*) FILTER (WHERE maduro AND ml_acertou IS NOT NULL) AS julgaveis,
    count(*) FILTER (WHERE maduro AND ml_acertou) AS acertos,
    round(100.0 * count(*) FILTER (WHERE maduro AND ml_acertou)
          / NULLIF(count(*) FILTER (WHERE maduro AND ml_acertou IS NOT NULL),0), 1) AS pct_acerto,
    round(avg(fwd_roas) FILTER (WHERE maduro AND ml_acertou IS NOT NULL), 2) AS roas_forward_medio
FROM marketcloud_gold.v_dayparting_ml_outcome_eval
WHERE ml_direction IS NOT NULL
GROUP BY ml_direction ORDER BY ml_direction;
