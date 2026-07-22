-- 158_click_attributed_sales.sql
-- CORRECAO de atribuicao horaria. O stream AMS carimba a venda na hora da
-- CONVERSAO, nao na hora do CLIQUE: 37% da venda cai em linha com 0 clique/0 gasto
-- (venda orfa). Isso inflava o ROAS de horas mortas (ex. 11h/15h pareciam verdes
-- por venda orfa da campanha auto). Fix: para a decisao de bid POR HORA, o ROAS
-- usa so a venda atribuida a linha COM clique -> sum(sales_7d) FILTER (clicks>0).
-- A venda orfa continua real no P&L da conta, mas fora da decisao horaria.
-- Colunas de saida inalteradas: CREATE OR REPLACE nao mexe nos dependentes.

CREATE OR REPLACE VIEW marketcloud_gold.v_dayparting_greening_cells AS
WITH mature AS (
  SELECT COALESCE(NULLIF(keyword_text,''),'(sem texto)') AS keyword_text,
         max(keyword_id) AS keyword_id, max(campaign_id) AS campaign_id,
         max(campaign_name) AS campaign_name, event_hour,
         sum(spend)::numeric AS spend,
         COALESCE(sum(sales_7d) FILTER (WHERE clicks > 0), 0)::numeric AS sales,  -- so venda-com-clique
         sum(clicks)::numeric AS clicks
  FROM marketcloud_bronze.bronze_ams_hourly_target
  WHERE data_date BETWEEN CURRENT_DATE - 28 AND CURRENT_DATE - 7
  GROUP BY 1, 5 HAVING sum(spend) > 0
),
kw_prior AS (
  SELECT keyword_text,
         CASE WHEN sum(spend) > 0 THEN sum(sales)/sum(spend) ELSE 0 END AS kw_roas,
         sum(clicks) AS kw_clicks, sum(spend) AS kw_spend, sum(sales) AS kw_sales
  FROM mature GROUP BY 1
),
scored AS (
  SELECT m.*, k.kw_roas, k.kw_clicks, k.kw_spend, k.kw_sales,
         CASE WHEN m.spend > 0 THEN m.sales/m.spend ELSE 0 END AS raw_roas,
         (m.clicks/(m.clicks + 15.0)) AS w
  FROM mature m JOIN kw_prior k USING (keyword_text)
),
final AS (
  SELECT s.*,
         round(s.w * s.raw_roas + (1 - s.w) * s.kw_roas, 2) AS shrunk_roas,
         CASE WHEN s.kw_roas < 3.0 AND s.kw_clicks >= 60 THEN 'MATAR'
              WHEN s.kw_roas < 3.0 AND s.kw_clicks >= 20 THEN 'VIGIAR'
              ELSE 'ok' END AS kw_flag
  FROM scored s
)
SELECT keyword_text, keyword_id, campaign_id, campaign_name, event_hour,
  round(spend,2) AS spend, round(sales,2) AS sales, clicks,
  round(raw_roas,2) AS raw_roas, shrunk_roas,
  round(kw_roas,2) AS kw_roas, kw_clicks, kw_flag,
  CASE
    WHEN clicks < 5             THEN 'HOLD'
    WHEN shrunk_roas < 3.0      THEN 'CUT'
    WHEN shrunk_roas >= 6.0     THEN 'FEED'
    ELSE                             'KEEP'
  END AS action,
  CASE
    WHEN clicks < 5         THEN NULL
    WHEN shrunk_roas < 3.0  THEN 20
    WHEN shrunk_roas >= 6.0 THEN LEAST(150, GREATEST(100, (round(shrunk_roas/3.0*100/10.0)*10)::int))
    ELSE                         100
  END AS suggested_multiplier,
  CASE
    WHEN clicks < 5         THEN 'amostra fraca ('||clicks||' cliques): aguardar mais dado antes de agir'
    WHEN shrunk_roas < 3.0  THEN 'hora morta (venda-com-clique): ROAS '||shrunk_roas||' < meta 3.0 -> cortar bid pro piso'
    WHEN shrunk_roas >= 6.0 THEN 'hora vencedora: ROAS '||shrunk_roas||' >= 6.0 -> alimentar (bid acima da base)'
    ELSE                         'hora saudavel: ROAS '||shrunk_roas||' entre 3 e 6 -> manter base'
  END AS reason
FROM final;

CREATE OR REPLACE VIEW marketcloud_gold.v_dayparting_window_stability AS
WITH base AS (
  SELECT COALESCE(NULLIF(keyword_text,''),'(sem texto)') AS keyword_text,
         max(campaign_id) AS campaign_id,
         CASE WHEN event_hour < 6 THEN 'madrugada'
              WHEN event_hour < 12 THEN 'manha'
              WHEN event_hour < 18 THEN 'tarde'
              ELSE 'noite' END AS daypart,
         CASE WHEN EXTRACT(ISODOW FROM data_date) IN (6,7) THEN 'fim_semana' ELSE 'dia_util' END AS day_bucket,
         date_trunc('week', data_date)::date AS semana,
         sum(clicks) AS clicks, sum(spend) AS spend,
         COALESCE(sum(sales_7d) FILTER (WHERE clicks > 0), 0) AS sales   -- so venda-com-clique
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
