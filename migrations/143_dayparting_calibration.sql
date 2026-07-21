-- 143_dayparting_calibration.sql  (v2 — GRAO KEYWORD)
-- Calibracao Semanal de Dayparting no MENOR GRAO (keyword x hora), mantendo o
-- mecanismo de buckets do grid atual {20,30,50,80,100}%.
--
-- Contexto (provado 21/07): a curva horaria de hoje (20/50/100/30) e HARDCODED
-- em amazon_ads_bid_schedule_no_pause.go — igual pra toda campanha/keyword, sem
-- recencia. Isto substitui essa constante por avaliacao KEYWORD A KEYWORD sobre
-- janela recente (trailing 28d), com pooling pela hierarquia que ja existe
-- (keyword -> campanha -> global) onde a keyword e magra (91% caem em GLOBAL hoje).
--
-- Fonte: marketcloud_bronze.bronze_ams_hourly_target (keyword x hora x dia com
-- spend/sales_7d). Saida: gold_keyword_hourly_calibration_v1 (o applier de bid le
-- daqui pra setar o multiplicador efetivo por keyword x hora). Travas: passo max
-- 1 bucket/semana, gate de amostra, snap nos buckets. Advisory; escrita real na
-- Amazon e gated (so pilotos) no worker/executor — nada aqui toca dinheiro.

-- limpa a v1 (grao campanha) — sem paralelo, o grao certo e keyword.
DROP VIEW     IF EXISTS marketcloud_gold.gold_dayparting_calibration_hour_v1;
DROP VIEW     IF EXISTS marketcloud_gold.gold_dayparting_calibration_latest_v1;
DROP FUNCTION IF EXISTS marketcloud_gold.refresh_dayparting_calibration(int,numeric,numeric,numeric,int,numeric);
DROP TABLE    IF EXISTS marketcloud_gold.gold_dayparting_calibration_v1;

-- ---- helpers de bucket (mecanismo do grid) ----

-- bucket alvo a partir do sinal (roas_hora / roas_medio do scope).
CREATE OR REPLACE FUNCTION marketcloud_gold._dp_bucket_from_signal(sig numeric)
RETURNS numeric IMMUTABLE LANGUAGE sql AS $$
  SELECT CASE
    WHEN sig IS NULL     THEN 1.00
    WHEN sig >= 1.00     THEN 1.00
    WHEN sig >= 0.75     THEN 0.80
    WHEN sig >= 0.50     THEN 0.50
    WHEN sig >= 0.30     THEN 0.30
    ELSE 0.20
  END;
$$;

-- move no MAXIMO 1 bucket em direcao ao alvo (trava de passo).
CREATE OR REPLACE FUNCTION marketcloud_gold._dp_bucket_step(cur numeric, tgt numeric)
RETURNS numeric IMMUTABLE LANGUAGE plpgsql AS $$
DECLARE
  b  numeric[] := ARRAY[0.20,0.30,0.50,0.80,1.00];
  ic int; it int;
BEGIN
  SELECT i INTO ic FROM generate_subscripts(b,1) i ORDER BY abs(b[i]-cur) LIMIT 1;
  SELECT i INTO it FROM generate_subscripts(b,1) i ORDER BY abs(b[i]-tgt) LIMIT 1;
  IF    it > ic THEN ic := ic + 1;
  ELSIF it < ic THEN ic := ic - 1;
  END IF;
  RETURN b[ic];
END;
$$;

-- curva hardcoded atual (ponto de partida na 1a rodada; espelha o Go).
CREATE OR REPLACE FUNCTION marketcloud_gold._dp_hardcoded_band(h int)
RETURNS numeric IMMUTABLE LANGUAGE sql AS $$
  SELECT CASE
    WHEN h BETWEEN 0 AND 5  THEN 0.20
    WHEN h BETWEEN 6 AND 8  THEN 1.00
    WHEN h BETWEEN 9 AND 10 THEN 0.50
    WHEN h BETWEEN 11 AND 13 THEN 1.00
    WHEN h BETWEEN 14 AND 17 THEN 0.50
    WHEN h BETWEEN 18 AND 20 THEN 1.00
    ELSE 0.30
  END;
$$;

CREATE TABLE IF NOT EXISTS marketcloud_gold.gold_keyword_hourly_calibration_v1 (
    computed_at             timestamptz NOT NULL DEFAULT now(),
    window_days             int         NOT NULL,
    campaign_id             text,
    ad_group_id             text,
    keyword_id              text        NOT NULL,
    keyword_text            text,
    match_type              text,
    event_hour              smallint    NOT NULL,
    scope                   text        NOT NULL,   -- ENTITY | CAMPAIGN | GLOBAL (de onde veio o sinal)
    clicks                  numeric     NOT NULL DEFAULT 0,
    spend                   numeric     NOT NULL DEFAULT 0,
    sales                   numeric     NOT NULL DEFAULT 0,
    hour_roas               numeric     NOT NULL DEFAULT 0,
    scope_avg_roas          numeric     NOT NULL DEFAULT 0,
    signal                  numeric     NOT NULL DEFAULT 1,
    target_multiplier       numeric     NOT NULL DEFAULT 1.0,   -- bucket alvo
    current_multiplier      numeric     NOT NULL DEFAULT 1.0,   -- bucket de partida
    recommended_multiplier  numeric     NOT NULL DEFAULT 1.0,   -- 1 passo em direcao ao alvo
    action                  text        NOT NULL DEFAULT 'HOLD',-- UP | DOWN | HOLD
    gate                    text        NOT NULL DEFAULT 'OK',  -- OK | INSUFFICIENT_DATA
    reason                  text        NOT NULL DEFAULT '',
    PRIMARY KEY (computed_at, keyword_id, event_hour)
);

CREATE INDEX IF NOT EXISTS idx_kw_hourly_calib_cell
    ON marketcloud_gold.gold_keyword_hourly_calibration_v1 (keyword_id, event_hour, computed_at DESC);

-- ultima calibracao por keyword x hora (o que o applier le).
CREATE OR REPLACE VIEW marketcloud_gold.gold_keyword_hourly_calibration_latest_v1 AS
SELECT DISTINCT ON (keyword_id, event_hour) *
FROM marketcloud_gold.gold_keyword_hourly_calibration_v1
ORDER BY keyword_id, event_hour, computed_at DESC;

-- refresh_keyword_hourly_calibration: roda o controlador keyword x hora.
CREATE OR REPLACE FUNCTION marketcloud_gold.refresh_keyword_hourly_calibration(
    p_window_days int     DEFAULT 28,
    p_min_clicks  int     DEFAULT 15,   -- gate de amostra por celula (por scope)
    p_min_spend   numeric DEFAULT 8.0
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_run timestamptz := now();
    v_max date;
    v_rows int;
BEGIN
    SELECT max(data_date) INTO v_max FROM marketcloud_bronze.bronze_ams_hourly_target;
    IF v_max IS NULL THEN RETURN 0; END IF;

    WITH src AS (
        SELECT campaign_id, ad_group_id, keyword_id, keyword_text, match_type,
               event_hour::smallint AS hr, clicks, spend, sales_7d AS sales
        FROM marketcloud_bronze.bronze_ams_hourly_target
        WHERE data_date > v_max - p_window_days AND keyword_id IS NOT NULL
    ),
    kwdim AS (
        SELECT DISTINCT ON (keyword_id)
               keyword_id, campaign_id, ad_group_id, keyword_text, match_type
        FROM src ORDER BY keyword_id
    ),
    hours AS (SELECT generate_series(0,23)::smallint AS hr),
    grid AS (SELECT d.*, h.hr FROM kwdim d CROSS JOIN hours h),
    kwperf AS (
        SELECT keyword_id, hr, sum(clicks) c, sum(spend) s, sum(sales) v
        FROM src GROUP BY 1,2
    ),
    kwavg AS (
        SELECT keyword_id, sum(sales)/NULLIF(sum(spend),0) AS avg_roas
        FROM src GROUP BY 1
    ),
    campperf AS (
        SELECT campaign_id, hr, sum(clicks) c, sum(spend) s, sum(sales) v
        FROM src GROUP BY 1,2
    ),
    campavg AS (
        SELECT campaign_id, sum(sales)/NULLIF(sum(spend),0) AS avg_roas
        FROM src GROUP BY 1
    ),
    globperf AS (SELECT hr, sum(clicks) c, sum(spend) s, sum(sales) v FROM src GROUP BY 1),
    globavg  AS (SELECT sum(sales)/NULLIF(sum(spend),0) AS avg_roas FROM src),
    prior AS (
        SELECT keyword_id, event_hour, recommended_multiplier
        FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
    ),
    resolved AS (
        SELECT
            g.campaign_id, g.ad_group_id, g.keyword_id, g.keyword_text, g.match_type, g.hr,
            -- escolhe o scope mais fino que passa no gate de amostra
            CASE
                WHEN kp.c >= p_min_clicks AND kp.s >= p_min_spend THEN 'ENTITY'
                WHEN cp.c >= p_min_clicks AND cp.s >= p_min_spend THEN 'CAMPAIGN'
                WHEN gp.c >= p_min_clicks AND gp.s >= p_min_spend THEN 'GLOBAL'
                ELSE 'NONE'
            END AS scope,
            COALESCE(kp.c,0) kc, COALESCE(kp.s,0) ks, COALESCE(kp.v,0) kv,
            CASE
                WHEN kp.c >= p_min_clicks AND kp.s >= p_min_spend THEN COALESCE(kp.v/NULLIF(kp.s,0),0)
                WHEN cp.c >= p_min_clicks AND cp.s >= p_min_spend THEN COALESCE(cp.v/NULLIF(cp.s,0),0)
                WHEN gp.c >= p_min_clicks AND gp.s >= p_min_spend THEN COALESCE(gp.v/NULLIF(gp.s,0),0)
                ELSE 0
            END AS hour_roas,
            CASE
                WHEN kp.c >= p_min_clicks AND kp.s >= p_min_spend THEN COALESCE(ka.avg_roas,0)
                WHEN cp.c >= p_min_clicks AND cp.s >= p_min_spend THEN COALESCE(ca.avg_roas,0)
                ELSE COALESCE(ga.avg_roas,0)
            END AS scope_avg_roas,
            COALESCE(pr.recommended_multiplier, marketcloud_gold._dp_hardcoded_band(g.hr::int)) AS current_mult
        FROM grid g
        LEFT JOIN kwperf   kp ON kp.keyword_id=g.keyword_id AND kp.hr=g.hr
        LEFT JOIN kwavg    ka ON ka.keyword_id=g.keyword_id
        LEFT JOIN campperf cp ON cp.campaign_id=g.campaign_id AND cp.hr=g.hr
        LEFT JOIN campavg  ca ON ca.campaign_id=g.campaign_id
        LEFT JOIN globperf gp ON gp.hr=g.hr
        CROSS JOIN globavg ga
        LEFT JOIN prior    pr ON pr.keyword_id=g.keyword_id AND pr.event_hour=g.hr
    ),
    calc AS (
        SELECT *,
            CASE WHEN scope_avg_roas > 0 THEN round(hour_roas/scope_avg_roas,3) ELSE 1 END AS sig
        FROM resolved
    ),
    decided AS (
        SELECT *,
            marketcloud_gold._dp_bucket_from_signal(sig) AS tgt,
            CASE WHEN scope='NONE' THEN current_mult
                 ELSE marketcloud_gold._dp_bucket_step(current_mult, marketcloud_gold._dp_bucket_from_signal(sig))
            END AS rec
        FROM calc
    )
    INSERT INTO marketcloud_gold.gold_keyword_hourly_calibration_v1 (
        computed_at, window_days, campaign_id, ad_group_id, keyword_id, keyword_text,
        match_type, event_hour, scope, clicks, spend, sales, hour_roas, scope_avg_roas,
        signal, target_multiplier, current_multiplier, recommended_multiplier, action, gate, reason)
    SELECT
        v_run, p_window_days, campaign_id, ad_group_id, keyword_id, keyword_text,
        match_type, hr, scope, round(kc,0), round(ks,2), round(kv,2),
        round(hour_roas,2), round(scope_avg_roas,2), sig,
        tgt, round(current_mult,2), round(rec,2),
        CASE WHEN scope='NONE' THEN 'HOLD'
             WHEN rec > current_mult THEN 'UP'
             WHEN rec < current_mult THEN 'DOWN'
             ELSE 'HOLD' END,
        CASE WHEN scope='NONE' THEN 'INSUFFICIENT_DATA' ELSE 'OK' END,
        CASE
            WHEN scope='NONE' THEN format('sem amostra (kw/camp/global) — segura em %s', round(current_mult,2))
            WHEN sig < 0.5 THEN format('[%s] ROAS %s vs media %s — corta p/ %s', scope, round(hour_roas,2), round(scope_avg_roas,2), round(rec,2))
            WHEN sig > 1.0 THEN format('[%s] ROAS %s vs media %s — reforca p/ %s', scope, round(hour_roas,2), round(scope_avg_roas,2), round(rec,2))
            ELSE format('[%s] ROAS %s ~ media %s — %s', scope, round(hour_roas,2), round(scope_avg_roas,2), round(rec,2))
        END
    FROM decided;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;
