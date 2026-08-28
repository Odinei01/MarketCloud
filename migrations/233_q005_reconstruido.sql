-- 233: reconstroi o Q005 sobre tabelas que EXISTEM no AMC.
--
-- POR QUE: as duas tabelas do Q005 antigo sao fantasmas (ver
-- docs/ACHADO-q005-amc-tabelas-fantasma.md). Ele so continuava rodando porque o AMC
-- reaproveitava um workflow validado quando elas ainda existiam; qualquer SQL novo era
-- recusado. E o JOIN so por campaign_id inflava gasto e venda (R$536.795 de venda
-- sobre R$1.689 de gasto).
--
-- A SUBSTITUTA nao precisou ser inventada: o Q007 ja reconstroi a jornada com 161
-- execucoes concluidas, usando duas tabelas vivas:
--   sponsored_ads_traffic       -> user_id, campaign_id, campaign, event_dt, spend
--   conversions_with_relevance  -> user_id, conversion_id, event_dt, total_product_sales
-- Aqui reaproveito esse miolo e troco a saida: em vez do caminho como texto, a posicao
-- do toque (FIRST/MIDDLE/LAST) agregada por campanha, que e o que o Q005 entrega.
--
-- COMO O FAN-OUT FICA IMPOSSIVEL: gasto e jornada sao agregados SEPARADAMENTE, cada um
-- ja com UMA linha por campanha, e so entao juntados. Nao ha como multiplicar. Nao e
-- cuidado de quem escreveu — e a forma da query.
--
-- JANELA: 28 dias entre o ultimo toque e a compra (2419200s), igual ao Q007.
--
-- HONESTIDADE DO NUMERO: numa conversao com toques em 3 campanhas, cada campanha soma
-- o valor INTEIRO da compra em assisted_sales. Isso e a natureza do assist, nao um bug:
-- assisted_sales NAO e somavel entre campanhas, serve para comparar campanhas entre si.
-- direct_sales (toque LAST) esse sim nao se sobrepoe.
--
-- Contrato de saida preservado: 15 colunas, mesma ordem, porque
-- ingest_bronze_q005.go le o CSV por posicao.

UPDATE query_templates SET sql_template = $SQL$
WITH sa_traffic AS (
    SELECT user_id, campaign_id,
           MAX(campaign)  AS campaign,
           MIN(event_dt)  AS first_touch_dt,
           MAX(event_dt)  AS last_touch_dt
    FROM sponsored_ads_traffic
    WHERE user_id IS NOT NULL
      AND campaign_id IS NOT NULL
    GROUP BY user_id, campaign_id
),
campaign_spend AS (
    SELECT campaign_id, SUM(spend / 100000000.0) AS spend
    FROM sponsored_ads_traffic
    WHERE campaign_id IS NOT NULL
    GROUP BY campaign_id
),
purchases AS (
    SELECT user_id, conversion_id,
           MAX(event_dt)            AS conversion_dt,
           MAX(total_product_sales) AS purchase_value
    FROM conversions_with_relevance
    WHERE event_category = 'purchase'
      AND user_id IS NOT NULL
    GROUP BY user_id, conversion_id
),
path_touches AS (
    SELECT p.user_id, p.conversion_id, p.purchase_value,
           t.campaign_id, t.campaign, t.first_touch_dt
    FROM purchases AS p
    JOIN sa_traffic AS t
      ON  t.user_id = p.user_id
      AND SECONDS_BETWEEN(t.last_touch_dt, p.conversion_dt) BETWEEN 0 AND 2419200
),
ranked_touches AS (
    SELECT user_id, conversion_id, purchase_value, campaign_id, campaign,
           ROW_NUMBER() OVER (PARTITION BY user_id, conversion_id
                              ORDER BY first_touch_dt ASC) AS touch_order,
           COUNT(campaign_id) OVER (PARTITION BY user_id, conversion_id) AS touch_total
    FROM path_touches
),
positioned AS (
    SELECT user_id, conversion_id, purchase_value, campaign_id, campaign,
           CASE WHEN touch_order = touch_total THEN 'LAST'
                WHEN touch_order = 1          THEN 'FIRST'
                ELSE 'MIDDLE' END AS touchpoint_position
    FROM ranked_touches
),
by_campaign AS (
    SELECT
        campaign_id,
        MAX(campaign) AS campaign_name,
        COUNT(DISTINCT conversion_id) AS users_total,
        COUNT(DISTINCT CASE WHEN touchpoint_position = 'LAST'   THEN conversion_id END) AS direct_users,
        COUNT(DISTINCT CASE WHEN touchpoint_position = 'FIRST'  THEN conversion_id END) AS first_users,
        COUNT(DISTINCT CASE WHEN touchpoint_position = 'MIDDLE' THEN conversion_id END) AS middle_users,
        COUNT(DISTINCT CASE WHEN touchpoint_position != 'LAST'  THEN conversion_id END) AS assisted_users,
        SUM(CASE WHEN touchpoint_position  = 'LAST' THEN purchase_value ELSE 0 END) AS direct_sales,
        SUM(CASE WHEN touchpoint_position != 'LAST' THEN purchase_value ELSE 0 END) AS assisted_sales
    FROM positioned
    GROUP BY campaign_id
)
SELECT
    b.campaign_id,
    b.campaign_name,
    {{product_group_label}} AS product_group,
    COALESCE(s.spend, 0)                                            AS spend,
    b.direct_users                                                  AS direct_orders,
    b.direct_sales                                                  AS direct_sales,
    (CAST(b.direct_sales AS DOUBLE)) / (CAST(NULLIF(s.spend, 0) AS DOUBLE))               AS direct_roas,
    b.assisted_users                                                AS assisted_orders,
    b.assisted_sales                                                AS assisted_sales,
    (CAST(b.assisted_sales AS DOUBLE)) / (CAST(NULLIF(s.spend, 0) AS DOUBLE))               AS assisted_roas,
    (CAST(b.assisted_users AS DOUBLE)) / (CAST(NULLIF(b.users_total, 0) AS DOUBLE))         AS assist_rate,
    (CAST(b.first_users AS DOUBLE)) / (CAST(NULLIF(b.users_total, 0) AS DOUBLE))         AS first_touch_rate,
    (CAST(b.middle_users AS DOUBLE)) / (CAST(NULLIF(b.users_total, 0) AS DOUBLE))         AS middle_touch_rate,
    (CAST(b.direct_users AS DOUBLE)) / (CAST(NULLIF(b.users_total, 0) AS DOUBLE))         AS last_touch_rate,
    CASE
        WHEN (CAST(b.direct_sales AS DOUBLE)) / (CAST(NULLIF(s.spend, 0) AS DOUBLE)) < {{target_roas}}
         AND (CAST(b.assisted_users AS DOUBLE)) / (CAST(NULLIF(b.users_total, 0) AS DOUBLE)) >= {{assist_rate_threshold}}
        THEN 'PROTECT'
        WHEN (CAST(b.direct_sales AS DOUBLE)) / (CAST(NULLIF(s.spend, 0) AS DOUBLE)) >= {{target_roas}}
        THEN 'OK_DIRECT_WINNER'
        ELSE 'REVIEW'
    END AS decision
FROM by_campaign b
LEFT JOIN campaign_spend s ON s.campaign_id = b.campaign_id
$SQL$,
version = COALESCE(version,1) + 1, updated_at = NOW()
WHERE code = 'MC_ZANOM_Q005';
