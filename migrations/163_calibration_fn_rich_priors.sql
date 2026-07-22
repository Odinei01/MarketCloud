-- 163_calibration_fn_rich_priors.sql
-- ITEM 1: rebase da funcao semanal refresh_keyword_hourly_calibration.
-- Os PRIORS de pooling (campperf/globperf/globavg) passam a vir da fonte RICA
-- bronze_amazon_ads_hourly (campanha x hora, desde 31/05, ~3257 cliques, cobre auto),
-- em vez do stream esparso. kwperf continua no stream (unica fonte de keyword x hora).
-- Rich mapeia campaign_name->campaign_id via bronze_swarm_campaign_names. Sales dos
-- priors = venda-com-clique (FILTER clicks>0), coerente com a correcao de atribuicao.
-- So muda de ONDE vem o prior; toda a logica de shrinkage/bucket/gate fica igual.

CREATE OR REPLACE FUNCTION marketcloud_gold.refresh_keyword_hourly_calibration(
    p_window_days integer DEFAULT 28, p_pool_min_clicks integer DEFAULT 12,
    p_min_spend numeric DEFAULT 5.0, p_shrink_k numeric DEFAULT 15, p_target_roas numeric DEFAULT 3.0)
  RETURNS integer LANGUAGE plpgsql AS $function$
DECLARE
    v_run timestamptz := now();
    v_max date;
    v_max_rich date;
    v_rows int;
BEGIN
    SELECT max(data_date) INTO v_max FROM marketcloud_bronze.bronze_ams_hourly_target;
    IF v_max IS NULL THEN RETURN 0; END IF;
    SELECT max(data_date) INTO v_max_rich FROM marketcloud_bronze.bronze_amazon_ads_hourly;

    WITH src AS (   -- stream esparso: unica fonte de keyword x hora (kwperf/kwdim)
        SELECT campaign_id, ad_group_id, keyword_id, keyword_text, match_type,
               event_hour::smallint AS hr, clicks, spend, sales_7d AS sales, data_date
        FROM marketcloud_bronze.bronze_ams_hourly_target
        WHERE data_date > v_max - p_window_days AND keyword_id IS NOT NULL
    ),
    rich AS (   -- fonte RICA: priors de campanha/global (campaign_name->id)
        SELECT n.campaign_id, r.event_hour::smallint AS hr,
               r.clicks, r.spend, r.sales_7d AS sales, r.data_date
        FROM marketcloud_bronze.bronze_amazon_ads_hourly r
        LEFT JOIN marketcloud_bronze.bronze_swarm_campaign_names n ON n.campaign_name = r.campaign_name
        WHERE r.data_date > v_max_rich - p_window_days
    ),
    kwdim AS (SELECT DISTINCT ON (keyword_id) keyword_id, campaign_id, ad_group_id, keyword_text, match_type FROM src ORDER BY keyword_id),
    hours AS (SELECT generate_series(0,23)::smallint AS hr),
    grid AS (SELECT d.*, h.hr FROM kwdim d CROSS JOIN hours h),
    kwperf AS (SELECT keyword_id, hr, sum(clicks) c, sum(spend) s,
                      sum(sales) FILTER (WHERE clicks>0) v,
                      count(DISTINCT to_char(data_date,'IW')) FILTER (WHERE spend>0) weeks FROM src GROUP BY 1,2),
    campperf AS (SELECT campaign_id, hr, sum(clicks) c, sum(spend) s,
                        sum(sales) FILTER (WHERE clicks>0) v,
                        count(DISTINCT to_char(data_date,'IW')) FILTER (WHERE spend>0) weeks
                 FROM rich WHERE campaign_id IS NOT NULL GROUP BY 1,2),
    globperf AS (SELECT hr, sum(clicks) c, sum(spend) s,
                        sum(sales) FILTER (WHERE clicks>0) v,
                        count(DISTINCT to_char(data_date,'IW')) FILTER (WHERE spend>0) weeks
                 FROM rich GROUP BY 1),
    globavg  AS (SELECT sum(sales) FILTER (WHERE clicks>0)/NULLIF(sum(spend),0) AS avg_roas FROM rich),
    prior AS (SELECT keyword_id, event_hour, recommended_multiplier FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1),
    base AS (
        SELECT
            g.campaign_id, g.ad_group_id, g.keyword_id, g.keyword_text, g.match_type, g.hr,
            COALESCE(kp.c,0) kc, COALESCE(kp.s,0) ks, COALESCE(kp.v,0) kv, COALESCE(kp.weeks,0) kw_weeks,
            COALESCE(kp.v/NULLIF(kp.s,0),0) AS kw_roas,
            CASE WHEN cp.c >= p_pool_min_clicks AND cp.s >= p_min_spend THEN COALESCE(cp.v/NULLIF(cp.s,0),0)
                 ELSE COALESCE(gp.v/NULLIF(gp.s,0),0) END AS prior_roas,
            CASE WHEN cp.c >= p_pool_min_clicks AND cp.s >= p_min_spend THEN 'CAMPANHA' ELSE 'GLOBAL' END AS prior_scope,
            CASE WHEN cp.c >= p_pool_min_clicks AND cp.s >= p_min_spend THEN COALESCE(cp.weeks,0) ELSE COALESCE(gp.weeks,0) END AS prior_weeks,
            COALESCE(gp.s,0) AS glob_spend,
            p_target_roas AS ref_roas,
            COALESCE(pub.multiplier, marketcloud_gold._dp_hardcoded_band(g.hr::int)) AS published_mult,
            COALESCE(pub.baseline_scope, 'HARDCODED') AS baseline_scope,
            COALESCE(pr.recommended_multiplier, pub.multiplier, marketcloud_gold._dp_hardcoded_band(g.hr::int)) AS current_mult
        FROM grid g
        LEFT JOIN kwperf   kp ON kp.keyword_id=g.keyword_id AND kp.hr=g.hr
        LEFT JOIN campperf cp ON cp.campaign_id=g.campaign_id AND cp.hr=g.hr
        LEFT JOIN globperf gp ON gp.hr=g.hr
        LEFT JOIN prior    pr ON pr.keyword_id=g.keyword_id AND pr.event_hour=g.hr
        LEFT JOIN marketcloud_gold.v_effective_published_curve_v1 pub ON pub.keyword_id=g.keyword_id AND pub.event_hour=g.hr
    ),
    calc AS (
        SELECT *,
            round(kc::numeric / (kc + p_shrink_k), 3) AS w,
            round(kc::numeric/(kc+p_shrink_k) * kw_roas
                  + (1 - kc::numeric/(kc+p_shrink_k)) * prior_roas, 3) AS blended_roas,
            CASE WHEN kc::numeric/(kc+p_shrink_k) >= 0.5 THEN 'KEYWORD'
                 WHEN kc > 0 THEN 'KEYWORD+'||prior_scope
                 ELSE prior_scope END AS scope_label
        FROM base
    ),
    sig AS (
        SELECT *, CASE WHEN ref_roas > 0 THEN round(blended_roas/ref_roas,3) ELSE 1 END AS signal_v FROM calc
    ),
    decided AS (
        SELECT *, marketcloud_gold._dp_bucket_from_signal(signal_v) AS tgt,
            (prior_weeks >= 2 OR kw_weeks >= 2) AS confident FROM sig
    )
    INSERT INTO marketcloud_gold.gold_keyword_hourly_calibration_v1 (
        computed_at, window_days, campaign_id, ad_group_id, keyword_id, keyword_text,
        match_type, event_hour, scope, clicks, spend, sales, hour_roas, scope_avg_roas,
        signal, target_multiplier, current_multiplier, published_multiplier, weeks_of_data,
        recommended_multiplier, action, gate, reason, baseline_scope)
    SELECT
        v_run, p_window_days, campaign_id, ad_group_id, keyword_id, keyword_text,
        match_type, hr, scope_label, round(kc,0), round(ks,2), round(kv,2),
        round(blended_roas,2), round(ref_roas,2), signal_v, tgt,
        CASE WHEN confident THEN round(marketcloud_gold._dp_bucket_step(current_mult, tgt),2) ELSE round(published_mult,2) END,
        round(published_mult,2), GREATEST(kw_weeks, prior_weeks),
        CASE WHEN confident THEN round(marketcloud_gold._dp_bucket_step(current_mult, tgt),2) ELSE round(published_mult,2) END,
        CASE WHEN NOT confident THEN 'HOLD'
             WHEN tgt > published_mult + 0.001 THEN 'UP'
             WHEN tgt < published_mult - 0.001 THEN 'DOWN'
             ELSE 'HOLD' END,
        CASE WHEN NOT confident THEN 'INSUFFICIENT_DATA' ELSE 'OK' END,
        CASE
            WHEN NOT confident THEN format('sem historico na hora — mantem %s%% (herda de %s)', round(published_mult*100), baseline_scope)
            WHEN kc > 0 THEN format('[%s] %s clk proprios (peso %s) + prior %s(rico): ROAS %s vs meta %s — %s%%->%s%% (base: %s)',
                                    scope_label, round(kc), round(w,2), prior_scope, round(blended_roas,1), round(ref_roas,1), round(published_mult*100), round(tgt*100), baseline_scope)
            ELSE format('[%s] sem clique proprio, usa %s(rico): ROAS %s vs meta %s — %s%%->%s%% (base: %s)',
                        scope_label, prior_scope, round(blended_roas,1), round(ref_roas,1), round(published_mult*100), round(tgt*100), baseline_scope)
        END,
        baseline_scope
    FROM decided;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$function$;
