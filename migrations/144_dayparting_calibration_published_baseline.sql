-- 144_dayparting_calibration_published_baseline.sql
-- Rework do baseline: a calibracao passa a comparar contra a CURVA PUBLICADA do
-- dono (zanom_ads_bid_schedule_profiles/rules, lidas via FDW swarm_src), nao mais
-- contra a curva hardcoded. Cada recomendacao carrega a PROVA (ROAS, gasto,
-- semanas com dado). Regra: mexe se o dado contraprovar; segura no valor publicado
-- onde nao ha dado suficiente (respeita intencao, ex.: madrugada baixa de proposito).
--
-- Join: profile.entity_id = bronze.keyword_id (ENTITY PUBLISHED). 41 profiles, 27
-- com dado recente. Keywords sem profile caem na curva hardcoded como fallback.

-- Curva publicada expandida por keyword x hora (janelas -> horas).
CREATE OR REPLACE VIEW marketcloud_gold.v_published_keyword_hour_mult_v1 AS
SELECT p.entity_id AS keyword_id,
       gs.h::smallint AS event_hour,
       round(avg(r.multiplier), 2) AS multiplier
FROM swarm_src.zanom_ads_bid_schedule_profiles p
JOIN swarm_src.zanom_ads_bid_schedule_rules r ON r.profile_id_ref = p.id
CROSS JOIN generate_series(0, 23) gs(h)
WHERE p.status = 'PUBLISHED' AND p.scope = 'ENTITY' AND p.entity_id IS NOT NULL
  AND gs.h >= r.hour_start AND gs.h < r.hour_end
GROUP BY 1, 2;

-- Colunas de baseline publicado + prova.
ALTER TABLE marketcloud_gold.gold_keyword_hourly_calibration_v1
    ADD COLUMN IF NOT EXISTS published_multiplier numeric,
    ADD COLUMN IF NOT EXISTS weeks_of_data int NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION marketcloud_gold.refresh_keyword_hourly_calibration(
    p_window_days      int     DEFAULT 28,
    p_kw_min_clicks    int     DEFAULT 25,
    p_cell_min_clicks  int     DEFAULT 1,
    p_pool_min_clicks  int     DEFAULT 12,
    p_min_spend        numeric DEFAULT 5.0
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
               event_hour::smallint AS hr, clicks, spend, sales_7d AS sales, data_date
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
        SELECT keyword_id, hr, sum(clicks) c, sum(spend) s, sum(sales) v,
               count(DISTINCT to_char(data_date,'IW')) FILTER (WHERE spend>0) weeks
        FROM src GROUP BY 1,2
    ),
    kwavg AS (SELECT keyword_id, sum(sales)/NULLIF(sum(spend),0) AS avg_roas FROM src GROUP BY 1),
    kwtot AS (SELECT keyword_id, sum(clicks) c, sum(spend) s FROM src GROUP BY 1),
    campperf AS (SELECT campaign_id, hr, sum(clicks) c, sum(spend) s, sum(sales) v,
                        count(DISTINCT to_char(data_date,'IW')) FILTER (WHERE spend>0) weeks FROM src GROUP BY 1,2),
    campavg AS (SELECT campaign_id, sum(sales)/NULLIF(sum(spend),0) AS avg_roas FROM src GROUP BY 1),
    globperf AS (SELECT hr, sum(clicks) c, sum(spend) s, sum(sales) v,
                        count(DISTINCT to_char(data_date,'IW')) FILTER (WHERE spend>0) weeks FROM src GROUP BY 1),
    globavg  AS (SELECT sum(sales)/NULLIF(sum(spend),0) AS avg_roas FROM src),
    prior AS (
        SELECT keyword_id, event_hour, recommended_multiplier
        FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
    ),
    resolved AS (
        SELECT
            g.campaign_id, g.ad_group_id, g.keyword_id, g.keyword_text, g.match_type, g.hr,
            CASE
                WHEN kt.c >= p_kw_min_clicks AND kt.s >= p_min_spend AND COALESCE(kp.c,0) >= p_cell_min_clicks THEN 'ENTITY'
                WHEN cp.c >= p_pool_min_clicks AND cp.s >= p_min_spend THEN 'CAMPAIGN'
                WHEN gp.c >= p_pool_min_clicks AND gp.s >= p_min_spend THEN 'GLOBAL'
                ELSE 'NONE'
            END AS scope,
            COALESCE(kp.c,0) kc, COALESCE(kp.s,0) ks, COALESCE(kp.v,0) kv,
            -- gasto e semanas do SCOPE que deu o sinal (nao da keyword, senao o global forte nunca passa)
            CASE
                WHEN kt.c >= p_kw_min_clicks AND kt.s >= p_min_spend AND COALESCE(kp.c,0) >= p_cell_min_clicks THEN COALESCE(kp.s,0)
                WHEN cp.c >= p_pool_min_clicks AND cp.s >= p_min_spend THEN COALESCE(cp.s,0)
                ELSE COALESCE(gp.s,0)
            END AS scope_spend,
            CASE
                WHEN kt.c >= p_kw_min_clicks AND kt.s >= p_min_spend AND COALESCE(kp.c,0) >= p_cell_min_clicks THEN COALESCE(kp.weeks,0)
                WHEN cp.c >= p_pool_min_clicks AND cp.s >= p_min_spend THEN COALESCE(cp.weeks,0)
                ELSE COALESCE(gp.weeks,0)
            END AS weeks,
            CASE
                WHEN kt.c >= p_kw_min_clicks AND kt.s >= p_min_spend AND COALESCE(kp.c,0) >= p_cell_min_clicks THEN COALESCE(kp.v/NULLIF(kp.s,0),0)
                WHEN cp.c >= p_pool_min_clicks AND cp.s >= p_min_spend THEN COALESCE(cp.v/NULLIF(cp.s,0),0)
                WHEN gp.c >= p_pool_min_clicks AND gp.s >= p_min_spend THEN COALESCE(gp.v/NULLIF(gp.s,0),0)
                ELSE 0
            END AS hour_roas,
            CASE
                WHEN kt.c >= p_kw_min_clicks AND kt.s >= p_min_spend AND COALESCE(kp.c,0) >= p_cell_min_clicks THEN COALESCE(ka.avg_roas,0)
                WHEN cp.c >= p_pool_min_clicks AND cp.s >= p_min_spend THEN COALESCE(ca.avg_roas,0)
                ELSE COALESCE(ga.avg_roas,0)
            END AS scope_avg_roas,
            -- BASELINE = curva publicada do dono (fallback hardcoded onde nao ha profile)
            COALESCE(pub.multiplier, marketcloud_gold._dp_hardcoded_band(g.hr::int)) AS published_mult,
            COALESCE(pr.recommended_multiplier, pub.multiplier, marketcloud_gold._dp_hardcoded_band(g.hr::int)) AS current_mult
        FROM grid g
        LEFT JOIN kwtot    kt ON kt.keyword_id=g.keyword_id
        LEFT JOIN kwperf   kp ON kp.keyword_id=g.keyword_id AND kp.hr=g.hr
        LEFT JOIN kwavg    ka ON ka.keyword_id=g.keyword_id
        LEFT JOIN campperf cp ON cp.campaign_id=g.campaign_id AND cp.hr=g.hr
        LEFT JOIN campavg  ca ON ca.campaign_id=g.campaign_id
        LEFT JOIN globperf gp ON gp.hr=g.hr
        CROSS JOIN globavg ga
        LEFT JOIN prior    pr ON pr.keyword_id=g.keyword_id AND pr.event_hour=g.hr
        LEFT JOIN marketcloud_gold.v_published_keyword_hour_mult_v1 pub
               ON pub.keyword_id=g.keyword_id AND pub.event_hour=g.hr
    ),
    calc AS (
        SELECT *, CASE WHEN scope_avg_roas > 0 THEN round(hour_roas/scope_avg_roas,3) ELSE 1 END AS sig
        FROM resolved
    ),
    decided AS (
        SELECT *,
            marketcloud_gold._dp_bucket_from_signal(sig) AS tgt,
            -- PROVA FORTE p/ recomendar mudanca: visto em >=2 semanas E gasto >= R$20
            -- na janela naquela hora. Atribuicao atrasa (ROAS 0 recente pode ser venda
            -- nao-pousada), entao exigimos recorrencia + dinheiro real. Senao: mantem.
            (scope <> 'NONE' AND weeks >= 2 AND scope_spend >= 20) AS confident
        FROM calc
    )
    INSERT INTO marketcloud_gold.gold_keyword_hourly_calibration_v1 (
        computed_at, window_days, campaign_id, ad_group_id, keyword_id, keyword_text,
        match_type, event_hour, scope, clicks, spend, sales, hour_roas, scope_avg_roas,
        signal, target_multiplier, current_multiplier, published_multiplier, weeks_of_data,
        recommended_multiplier, action, gate, reason)
    SELECT
        v_run, p_window_days, campaign_id, ad_group_id, keyword_id, keyword_text,
        match_type, hr, scope, round(kc,0), round(ks,2), round(kv,2),
        round(hour_roas,2), round(scope_avg_roas,2), sig,
        tgt,
        -- so move o multiplicador quando ha prova forte; senao mantem o publicado
        CASE WHEN confident THEN round(marketcloud_gold._dp_bucket_step(current_mult, tgt),2) ELSE round(published_mult,2) END,
        round(published_mult,2), weeks,
        CASE WHEN confident THEN round(marketcloud_gold._dp_bucket_step(current_mult, tgt),2) ELSE round(published_mult,2) END,
        CASE
            WHEN NOT confident THEN 'HOLD'
            WHEN tgt > published_mult + 0.001 THEN 'UP'
            WHEN tgt < published_mult - 0.001 THEN 'DOWN'
            ELSE 'HOLD' END,
        CASE WHEN scope='NONE' THEN 'INSUFFICIENT_DATA'
             WHEN NOT confident THEN 'EVIDENCIA_FRACA'
             ELSE 'OK' END,
        CASE
            WHEN scope='NONE' THEN format('sem dado — mantem seu %s%%', round(published_mult*100))
            WHEN NOT confident THEN format('evidencia fraca (%s sem, R$%s) — mantem seu %s%%', weeks, round(scope_spend), round(published_mult*100))
            WHEN sig < 0.5 THEN format('[%s] ROAS %s < media %s em %s sem, R$%s — corta de %s%% p/ %s%%', scope, round(hour_roas,1), round(scope_avg_roas,1), weeks, round(scope_spend), round(published_mult*100), round(tgt*100))
            WHEN sig > 1.0 THEN format('[%s] ROAS %s > media %s em %s sem, R$%s — sobe de %s%% p/ %s%%', scope, round(hour_roas,1), round(scope_avg_roas,1), weeks, round(scope_spend), round(published_mult*100), round(tgt*100))
            ELSE format('[%s] ROAS %s ~ media %s (%s sem) — mantem %s%%', scope, round(hour_roas,1), round(scope_avg_roas,1), weeks, round(published_mult*100))
        END
    FROM decided;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;
