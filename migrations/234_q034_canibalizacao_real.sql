-- 234: Q034 (canibalizacao entre campanhas) reescrito sobre o schema real do AMC.
--
-- O ORIGINAL ERA FANTASIA: partia de amc_campaign_overlap, uma tabela que ja traria
-- campaign_a, campaign_b, user_id, search_term e ate duplicated_spend prontos. Ela nao
-- existe — como nao existem amc_campaign_users, amc_attributed_purchases nem
-- sponsored_ads_traffic_report. Por isso o Q034 tem 0 execucoes concluidas: nunca
-- funcionou, nao quebrou.
--
-- Alem disso o original juntava 5 tabelas so por campaign_id, o que multiplicaria gasto
-- e venda do mesmo jeito que estourou o Q005.
--
-- ESTA VERSAO calcula a sobreposicao de verdade, que e justamente o que SO o AMC
-- responde: o mesmo user_id exposto a duas campanhas. O relatorio de Ads nao sabe
-- disso — ele conta por campanha, nunca cruza pessoa.
--
-- SEM FAN-OUT: pairs ja e uma linha por par de campanhas e campaign_totals uma linha
-- por campanha. Os joins finais sao 1:1.
--
-- b.campaign_id > a.campaign_id: mata o auto-par e conta cada par uma vez so.
--
-- GASTO DUPLICADO e ESTIMATIVA declarada, nao medicao: custo por usuario de cada
-- campanha vezes os usuarios que as duas alcancaram. A Amazon nao diz quanto custou
-- alcancar um usuario especifico; esse rateio assume custo uniforme por pessoa.

UPDATE query_templates SET sql_template = $SQL$
WITH campaign_users AS (
    SELECT DISTINCT user_id, campaign_id
    FROM sponsored_ads_traffic
    WHERE user_id IS NOT NULL
      AND campaign_id IS NOT NULL
),
campaign_totals AS (
    SELECT campaign_id,
           MAX(campaign)            AS campaign_name,
           COUNT(DISTINCT user_id)  AS users,
           SUM(spend / 100000000.0) AS spend
    FROM sponsored_ads_traffic
    WHERE user_id IS NOT NULL
      AND campaign_id IS NOT NULL
    GROUP BY campaign_id
),
pairs AS (
    SELECT a.campaign_id AS campaign_a_id,
           b.campaign_id AS campaign_b_id,
           COUNT(DISTINCT a.user_id) AS overlap_users
    FROM campaign_users a
    JOIN campaign_users b
      ON  b.user_id     = a.user_id
      AND b.campaign_id > a.campaign_id
    GROUP BY a.campaign_id, b.campaign_id
)
SELECT
    ta.campaign_name AS campaign_a,
    tb.campaign_name AS campaign_b,
    p.overlap_users,
    ta.users AS users_a,
    tb.users AS users_b,
    (CAST(p.overlap_users AS DOUBLE)) / (CAST(NULLIF(ta.users, 0) AS DOUBLE)) AS overlap_rate_a,
    (CAST(p.overlap_users AS DOUBLE)) / (CAST(NULLIF(tb.users, 0) AS DOUBLE)) AS overlap_rate_b,
    ta.spend AS spend_a,
    tb.spend AS spend_b,
    ( (ta.spend / (CAST(NULLIF(ta.users, 0) AS DOUBLE)))
    + (tb.spend / (CAST(NULLIF(tb.users, 0) AS DOUBLE))) )
      * CAST(p.overlap_users AS DOUBLE) AS duplicated_spend_estimate,
    CASE
        WHEN (CAST(p.overlap_users AS DOUBLE)) / (CAST(NULLIF(ta.users, 0) AS DOUBLE)) >= 0.30
          OR (CAST(p.overlap_users AS DOUBLE)) / (CAST(NULLIF(tb.users, 0) AS DOUBLE)) >= 0.30
        THEN 'CONSOLIDATE'
        ELSE 'MONITOR'
    END AS decision
FROM pairs p
JOIN campaign_totals ta ON ta.campaign_id = p.campaign_a_id
JOIN campaign_totals tb ON tb.campaign_id = p.campaign_b_id
WHERE p.overlap_users >= 10
ORDER BY p.overlap_users DESC
$SQL$,
version = COALESCE(version,1) + 1, updated_at = NOW()
WHERE code = 'MC_ZANOM_Q034';
