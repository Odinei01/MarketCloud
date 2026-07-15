-- =====================================================================
-- Gold — Camada HORÁRIA sobre o DADO REAL (não-suprimido) do Ads
--
-- Fonte: marketcloud_bronze.bronze_amazon_ads_hourly (relatório horário da
-- própria conta ZANOM via Amazon Advertising API — SEM supressão, diferente
-- do AMC E004 que anulava ~70% das conversões no grão horário).
--
-- Cruza o desempenho real por campanha×hora com a agenda de multiplicadores
-- do Robô (bronze_swarm_bid_schedule) para achar:
--   BID_UP    hora BOA sendo estrangulada  (ROAS alto, multiplicador < 1)
--   CUT_HOUR  hora que QUEIMA               (gasta com bid cheio, sem retorno)
--   BID_DOWN  hora fraca com bid cheio      (ROAS abaixo do alvo, amaciar)
--
-- RESSALVAS HONESTAS (gravadas no dataset, não escondidas):
--  1) OBSERVACIONAL: o ROAS foi obtido NAQUELE multiplicador. Subir o lance
--     muda o leilão — a recomendação é "testar", validada pelo loop de feedback.
--  2) VOLUME BAIXO: 1-2 pedidos/célula. Confiança escalada por volume; célula
--     rala vira LOW e nunca P0.
--  3) join campanha por NOME (o relatório horário não traz campaign_id).
--  4) ADVISOR-ONLY: nada executa na Amazon. O Robô/humano decide no cockpit.
-- =====================================================================

-- Parâmetros de decisão (calibrados no dado real: ROAS geral ~2.9, p75 ~3.0)
-- alvo_bom = 4.0 ; corte exige gasto >= 8 sem retorno ; amaciar < 2.0

-- ---------- 1) Performance real por campanha×hora ----------
DROP VIEW IF EXISTS marketcloud_gold.gold_hourly_recommendations_v1 CASCADE;
DROP VIEW IF EXISTS marketcloud_gold.gold_hourly_perf_v1 CASCADE;

CREATE VIEW marketcloud_gold.gold_hourly_perf_v1 AS
WITH win AS (
    SELECT MAX(data_date) AS max_d, MIN(data_date) AS min_d
    FROM marketcloud_bronze.bronze_amazon_ads_hourly
),
cell AS (
    SELECT
        LOWER(TRIM(h.campaign_name))        AS campaign_norm,
        MAX(h.campaign_name)                AS campaign_name,
        h.event_hour,
        COUNT(DISTINCT h.data_date)         AS days_observed,
        SUM(h.impressions)                  AS impressions,
        SUM(h.clicks)                       AS clicks,
        SUM(h.spend)                        AS spend,
        SUM(h.orders_7d)                    AS orders,
        SUM(h.sales_7d)                     AS sales,
        CASE WHEN SUM(h.spend) > 0 THEN SUM(h.sales_7d)/SUM(h.spend) ELSE 0 END AS roas,
        CASE WHEN SUM(h.clicks) > 0 THEN SUM(h.orders_7d)/SUM(h.clicks) ELSE 0 END AS cvr
    FROM marketcloud_bronze.bronze_amazon_ads_hourly h
    WHERE UPPER(COALESCE(h.campaign_status,'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
    GROUP BY LOWER(TRIM(h.campaign_name)), h.event_hour
),
sched AS (
    -- multiplicador vigente na hora (pior caso p/ detectar estrangulamento):
    -- MIN = mais estrangulado; MAX = mais ampliado. Guardamos os dois.
    SELECT LOWER(TRIM(s.campaign_name)) AS campaign_norm, gs.hour AS event_hour,
        MIN(s.multiplier) AS mult_min, MAX(s.multiplier) AS mult_max,
        BOOL_OR(TRUE) AS has_schedule
    FROM marketcloud_bronze.bronze_swarm_bid_schedule s
    CROSS JOIN LATERAL generate_series(s.hour_start, s.hour_end - 1) AS gs(hour)
    WHERE UPPER(COALESCE(s.campaign_status,'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
      AND UPPER(COALESCE(s.ad_group_status,'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
    GROUP BY LOWER(TRIM(s.campaign_name)), gs.hour
)
SELECT
    c.campaign_norm, c.campaign_name, c.event_hour,
    c.days_observed, c.impressions, c.clicks,
    ROUND(c.spend::numeric,2)  AS spend,
    c.orders::int              AS orders,
    ROUND(c.sales::numeric,2)  AS sales,
    ROUND(c.roas::numeric,2)   AS roas,
    ROUND(c.cvr::numeric,4)    AS cvr,
    sc.mult_min, sc.mult_max,
    (sc.campaign_norm IS NOT NULL) AS has_schedule,
    w.min_d, w.max_d
FROM cell c
CROSS JOIN win w
LEFT JOIN sched sc ON sc.campaign_norm = c.campaign_norm AND sc.event_hour = c.event_hour;

-- ---------- 2) Recomendações horárias (decisão + confiança + evidência) ----------
CREATE VIEW marketcloud_gold.gold_hourly_recommendations_v1 AS
WITH scored AS (
    SELECT p.*,
        -- confiança escalada por volume real
        CASE
            WHEN p.orders >= 3 AND p.clicks >= 20 THEN 'HIGH'
            WHEN p.orders >= 1 AND p.spend    >= 5 THEN 'MEDIUM'
            ELSE 'LOW'
        END AS confidence,
        -- decisão
        CASE
            -- hora boa estrangulada -> subir lance
            WHEN p.roas >= 4.0 AND p.orders >= 1 AND p.spend >= 2
                 AND p.has_schedule AND p.mult_min < 1.0
                THEN 'BID_UP'
            -- gasta com bid cheio/ampliado e não retorna -> cortar a hora
            WHEN p.spend >= 8 AND (p.orders = 0 OR p.roas < 1.0)
                 AND p.has_schedule AND p.mult_max >= 1.0
                THEN 'CUT_HOUR'
            -- hora fraca com bid cheio -> amaciar
            WHEN p.spend >= 5 AND p.roas < 2.0 AND p.roas >= 1.0
                 AND p.has_schedule AND p.mult_max >= 1.0
                THEN 'BID_DOWN'
            -- hora boa já ampliada -> manter/observar
            WHEN p.roas >= 4.0 AND p.orders >= 1 AND p.has_schedule AND p.mult_min >= 1.0
                THEN 'KEEP_STRONG'
            ELSE 'WATCH'
        END AS action_type
    FROM marketcloud_gold.gold_hourly_perf_v1 p
)
SELECT
    md5(campaign_norm || '|' || event_hour || '|' || action_type) AS recommendation_id,
    campaign_name, event_hour, action_type, confidence,
    -- evidência
    spend, orders, sales, roas, cvr, clicks, impressions, days_observed,
    mult_min AS current_multiplier, mult_max, has_schedule,
    -- multiplicador sugerido (direcional; o Robô calcula o lance final)
    CASE action_type
        WHEN 'BID_UP'   THEN LEAST(1.0, ROUND((mult_min + 0.3)::numeric, 2))
        WHEN 'CUT_HOUR' THEN 0.3
        WHEN 'BID_DOWN' THEN GREATEST(0.5, ROUND((mult_max - 0.3)::numeric, 2))
        ELSE mult_min
    END AS suggested_multiplier,
    -- prioridade: valor em jogo × força do sinal, penalizado por confiança baixa
    ROUND((
        CASE action_type
            WHEN 'BID_UP'   THEN sales * LEAST(roas, 20) / 10.0   -- upside da hora boa
            WHEN 'CUT_HOUR' THEN spend * 2.0                       -- desperdício
            WHEN 'BID_DOWN' THEN spend * 1.0
            ELSE 0
        END
        * CASE confidence WHEN 'HIGH' THEN 1.0 WHEN 'MEDIUM' THEN 0.6 ELSE 0.3 END
    )::numeric, 2) AS priority_score,
    'REAL_HOURLY_OBSERVATIONAL'::text AS label_caveat,
    min_d AS window_from, max_d AS window_to,
    NOW() AS computed_at
FROM scored
WHERE action_type IN ('BID_UP','CUT_HOUR','BID_DOWN','KEEP_STRONG');
