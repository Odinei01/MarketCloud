-- 157_resolve_campaign_names.sql
-- Fix cosmetico: o stream horario (bronze_ams_hourly_target) nem sempre traz
-- campaign_name — campanhas de segmentacao AUTOMATICA (ex. "Hub USB") vem sem nome
-- e sem keyword_text. O nome real vive em bronze_swarm_campaign_names. Resolve o
-- nome por ali como fallback nas views que exibem campaign_name.

DROP VIEW IF EXISTS marketcloud_gold.v_pricing_window_candidates;
DROP VIEW IF EXISTS marketcloud_gold.v_placement_window_candidates;
DROP VIEW IF EXISTS marketcloud_gold.v_dayparting_window_stability;

CREATE VIEW marketcloud_gold.v_dayparting_window_stability AS
WITH base AS (
  SELECT COALESCE(NULLIF(keyword_text,''),'(sem texto)') AS keyword_text,
         max(campaign_id) AS campaign_id,
         CASE WHEN event_hour < 6 THEN 'madrugada'
              WHEN event_hour < 12 THEN 'manha'
              WHEN event_hour < 18 THEN 'tarde'
              ELSE 'noite' END AS daypart,
         CASE WHEN EXTRACT(ISODOW FROM data_date) IN (6,7) THEN 'fim_semana' ELSE 'dia_util' END AS day_bucket,
         date_trunc('week', data_date)::date AS semana,
         sum(clicks) AS clicks, sum(spend) AS spend, sum(sales_7d) AS sales
  FROM marketcloud_bronze.bronze_ams_hourly_target
  WHERE data_date > CURRENT_DATE - 42
  GROUP BY 1,3,4,5
),
per_week AS (
  SELECT keyword_text, campaign_id, daypart, day_bucket, semana,
         clicks, spend, sales,
         (spend > 0 AND clicks >= 3 AND sales/NULLIF(spend,0) >= 3.0) AS week_green
  FROM base
),
agg AS (
  SELECT keyword_text, max(campaign_id) AS campaign_id, daypart, day_bucket,
         count(*) FILTER (WHERE clicks > 0) AS weeks_active,
         count(*) FILTER (WHERE week_green) AS weeks_green,
         sum(clicks) AS clicks, sum(spend) AS spend, sum(sales) AS sales,
         CASE WHEN sum(spend) > 0 THEN round((sum(sales)/sum(spend))::numeric,2) ELSE 0 END AS roas
  FROM per_week GROUP BY 1,3,4
)
SELECT a.keyword_text, a.campaign_id,
       COALESCE(NULLIF(n.campaign_name,''), '(campanha '||a.campaign_id||')') AS campaign_name,
       a.daypart, a.day_bucket, a.weeks_active, a.weeks_green, a.clicks,
       round(a.spend::numeric,2) AS spend, round(a.sales::numeric,2) AS sales, a.roas,
       CASE
         WHEN a.weeks_green >= 3 AND a.clicks >= 15 THEN 'READY'
         WHEN a.weeks_green >= 2 AND a.clicks >= 8  THEN 'EMERGING'
         ELSE 'THIN'
       END AS readiness
FROM agg a
LEFT JOIN marketcloud_bronze.bronze_swarm_campaign_names n ON n.campaign_id = a.campaign_id
WHERE a.spend > 0;

CREATE VIEW marketcloud_gold.v_placement_window_candidates AS
WITH camp AS (
  SELECT campaign_id, max(campaign_name) AS campaign_name, daypart, day_bucket,
         sum(clicks) AS clicks, sum(spend) AS spend, sum(sales) AS sales,
         max(weeks_green) AS weeks_green,
         CASE WHEN sum(spend)>0 THEN round((sum(sales)/sum(spend))::numeric,2) ELSE 0 END AS roas
  FROM marketcloud_gold.v_dayparting_window_stability
  GROUP BY 1,3,4
),
scored AS (
  SELECT *, CASE
      WHEN weeks_green >= 3 AND clicks >= 15 THEN 'READY'
      WHEN weeks_green >= 2 AND clicks >= 8  THEN 'EMERGING'
      ELSE 'THIN' END AS readiness
  FROM camp
)
SELECT campaign_id, campaign_name, daypart, day_bucket, clicks,
       round(spend::numeric,2) AS spend, roas, weeks_green, readiness,
       CASE
         WHEN readiness='READY'    AND roas >= 6 THEN 100
         WHEN readiness='READY'    AND roas >= 3 THEN 50
         WHEN readiness='EMERGING' AND roas >= 6 THEN 25
         ELSE 0
       END AS suggested_tos_boost_pct,
       CASE
         WHEN readiness='THIN' THEN 'dado insuficiente/instavel: aguardar'
         WHEN roas < 3 THEN 'janela nao lucrativa: nao impulsionar primeira pagina'
         ELSE 'janela madura e lucrativa: impulsionar top-of-search '||
              (CASE WHEN readiness='READY' AND roas>=6 THEN '+100%'
                    WHEN readiness='READY' THEN '+50%' ELSE '+25% (sonda)' END)
       END AS reason
FROM scored;

CREATE VIEW marketcloud_gold.v_pricing_window_candidates AS
SELECT keyword_text, campaign_id, campaign_name, daypart, day_bucket,
       weeks_green, clicks, roas,
       'janela quente e estavel ('||weeks_green||' semanas verdes, ROAS '||roas||
       '): candidata a teste de premio de preco no daypart. Elasticidade a testar pelo robo de pricing.' AS hypothesis
FROM marketcloud_gold.v_dayparting_window_stability
WHERE readiness = 'READY' AND roas >= 6
ORDER BY roas DESC;
