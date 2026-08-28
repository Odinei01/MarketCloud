-- 236: Q037 reduzido ao que SO o AMC responde — saturacao de alcance.
--
-- O ORIGINAL misturava 5 tabelas, 4 delas inexistentes (amc_attributed_purchases,
-- amc_path_to_purchase, amc_frequency, product_metrics), num score que somava ROAS,
-- conversao, assist, estoque e margem. Zero execucoes concluidas.
--
-- ROAS, conversao, estoque e margem NAO sao perguntas de AMC: esses dados estao no
-- Postgres, com custo real por SKU e estoque real, e ja alimentam o ML. Traze-los do
-- AMC seria trocar fonte boa por pior. O assist ja vem do Q005 reconstruido.
--
-- O que sobra, e que o relatorio de Ads NAO sabe responder: quantas PESSOAS distintas a
-- campanha alcancou, e quantas vezes bateu em cada uma. O Ads conta impressao; so o AMC
-- separa "5.000 impressoes em 5.000 pessoas" de "5.000 impressoes em 300 pessoas".
--
-- E isso que decide se cabe mais verba. Frequencia baixa com muito alcance fresco = ainda
-- ha gente nova para alcancar. Frequencia alta = a verba extra so repete anuncio para
-- quem ja viu e nao comprou.
--
-- SEM FAN-OUT: cada CTE ja devolve uma linha por campanha.
--
-- NOTA: impressions e coluna agregada por linha, nao uma impressao por linha — por isso
-- SUM(impressions) por usuario, nao COUNT(*).

UPDATE query_templates SET sql_template = $SQL$
WITH user_freq AS (
    SELECT campaign_id, user_id, SUM(impressions) AS imps
    FROM sponsored_ads_traffic
    WHERE user_id IS NOT NULL
      AND campaign_id IS NOT NULL
    GROUP BY campaign_id, user_id
),
camp AS (
    SELECT campaign_id,
           MAX(campaign)            AS campaign_name,
           COUNT(DISTINCT user_id)  AS users_reached,
           SUM(impressions)         AS impressions,
           SUM(clicks)              AS clicks,
           SUM(spend / 100000000.0) AS spend
    FROM sponsored_ads_traffic
    WHERE user_id IS NOT NULL
      AND campaign_id IS NOT NULL
    GROUP BY campaign_id
),
buckets AS (
    SELECT campaign_id,
           COUNT(user_id)                                AS users,
           COUNT(CASE WHEN imps  = 1 THEN user_id END)   AS users_1imp,
           COUNT(CASE WHEN imps >= 6 THEN user_id END)   AS users_6plus
    FROM user_freq
    GROUP BY campaign_id
)
SELECT
    c.campaign_id,
    c.campaign_name,
    c.users_reached,
    c.impressions,
    c.clicks,
    c.spend,
    (CAST(c.impressions AS DOUBLE)) / (CAST(NULLIF(c.users_reached, 0) AS DOUBLE)) AS frequency_avg,
    (CAST(b.users_1imp AS DOUBLE))  / (CAST(NULLIF(b.users, 0) AS DOUBLE))         AS fresh_reach_rate,
    (CAST(b.users_6plus AS DOUBLE)) / (CAST(NULLIF(b.users, 0) AS DOUBLE))         AS saturation_rate,
    (c.spend) / (CAST(NULLIF(c.users_reached, 0) AS DOUBLE))                       AS cost_per_user,
    CASE
        WHEN (CAST(c.impressions AS DOUBLE)) / (CAST(NULLIF(c.users_reached, 0) AS DOUBLE)) >= 6.0
          OR (CAST(b.users_6plus AS DOUBLE)) / (CAST(NULLIF(b.users, 0) AS DOUBLE)) >= 0.20
        THEN 'SATURADA'
        WHEN (CAST(b.users_1imp AS DOUBLE)) / (CAST(NULLIF(b.users, 0) AS DOUBLE)) >= 0.60
         AND (CAST(c.impressions AS DOUBLE)) / (CAST(NULLIF(c.users_reached, 0) AS DOUBLE)) < 3.0
        THEN 'CABE_VERBA'
        ELSE 'MONITOR'
    END AS decision
FROM camp c
JOIN buckets b ON b.campaign_id = c.campaign_id
WHERE c.users_reached >= 100
ORDER BY c.spend DESC
$SQL$,
status = 'ACTIVE',
version = COALESCE(version,1) + 1, updated_at = NOW()
WHERE code = 'MC_ZANOM_Q037';
