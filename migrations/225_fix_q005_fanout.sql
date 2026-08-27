-- 225: conserta a Q005 (assist por campanha). O AMC aceitava a query e devolvia
-- numero errado — o pior tipo de defeito, porque nada falha.
--
-- SINTOMA: bronze_amc_campaign_assist registrava R$536.795,68 de venda direta contra
-- R$1.689,29 de gasto. ROAS de ate 1.739. A operacao inteira fatura ~R$28 mil/mes:
-- o numero estava ~19x acima do universo possivel. E o funil vinha com 0 carrinhos e
-- 0 detail page views.
--
-- CAUSA: JOIN em produto cartesiano.
--
--     FROM sponsored_ads_traffic_report c
--     JOIN amc_path_to_purchase p ON c.campaign_id = p.campaign_id
--     GROUP BY c.campaign_id
--
-- O join casa APENAS por campaign_id. Cada linha de trafego (uma por campanha x dia x
-- posicao) cruza com CADA caminho de compra da mesma campanha. Com N linhas de trafego
-- e M caminhos, o resultado tem N x M linhas — e ai:
--
--     SUM(c.spend)          conta o gasto M vezes
--     SUM(p.purchase_value) conta a venda N vezes
--
-- Como N e M sao diferentes, a razao entre eles (o ROAS) vira um numero arbitrario.
-- Nao e "um pouco errado": e uma divisao entre dois numeros inflados por fatores
-- distintos. O AMC nao tem como reclamar — a query e valida, so nao mede o que diz.
--
-- CORRECAO: agregar cada lado ANTES de juntar. Uma linha por campanha de cada lado,
-- join 1:1, sem multiplicacao. LEFT JOIN porque campanha com gasto e sem caminho de
-- compra precisa aparecer com venda zero, nao sumir.
--
-- NAO mexi no SAFE_DIVIDE: minhas notas diziam que o AMC nao suporta, mas a Q005 tem
-- 56 execucoes concluidas, a ultima hoje. A nota estava errada, ou a plataforma mudou.
-- Nao se conserta o que esta funcionando.

UPDATE query_templates SET sql_template = $SQL$
WITH traffic AS (
    SELECT
        campaign_id,
        MAX(campaign_name) AS campaign_name,
        SUM(spend)         AS spend
    FROM sponsored_ads_traffic_report
    WHERE date BETWEEN {{period_start}} AND {{period_end}}
      {{campaign_filter}}
    GROUP BY campaign_id
),
paths AS (
    SELECT
        campaign_id,
        COUNT(DISTINCT user_id)                                                     AS users_total,
        COUNT(DISTINCT CASE WHEN touchpoint_position='LAST'   THEN user_id END)     AS direct_users,
        COUNT(DISTINCT CASE WHEN touchpoint_position='FIRST'  THEN user_id END)     AS first_users,
        COUNT(DISTINCT CASE WHEN touchpoint_position='MIDDLE' THEN user_id END)     AS middle_users,
        COUNT(DISTINCT CASE WHEN touchpoint_position!='LAST'
                             AND path_had_conversion=1        THEN user_id END)     AS assisted_users,
        SUM(CASE WHEN touchpoint_position='LAST' THEN purchase_value ELSE 0 END)    AS direct_sales,
        SUM(CASE WHEN touchpoint_position!='LAST'
                  AND path_had_conversion=1 THEN attributed_value ELSE 0 END)       AS assisted_sales
    FROM amc_path_to_purchase
    WHERE impression_date BETWEEN {{period_start}} AND {{period_end}}
    GROUP BY campaign_id
)
SELECT
    t.campaign_id,
    t.campaign_name,
    {{product_group_label}}                                        AS product_group,
    t.spend                                                        AS spend,
    COALESCE(p.direct_users,0)                                     AS direct_orders,
    COALESCE(p.direct_sales,0)                                     AS direct_sales,
    SAFE_DIVIDE(COALESCE(p.direct_sales,0), NULLIF(t.spend,0))     AS direct_roas,
    COALESCE(p.assisted_users,0)                                   AS assisted_orders,
    COALESCE(p.assisted_sales,0)                                   AS assisted_sales,
    SAFE_DIVIDE(COALESCE(p.assisted_sales,0), NULLIF(t.spend,0))   AS assisted_roas,
    SAFE_DIVIDE(COALESCE(p.assisted_users,0), NULLIF(p.users_total,0)) AS assist_rate,
    SAFE_DIVIDE(COALESCE(p.first_users,0),    NULLIF(p.users_total,0)) AS first_touch_rate,
    SAFE_DIVIDE(COALESCE(p.middle_users,0),   NULLIF(p.users_total,0)) AS middle_touch_rate,
    SAFE_DIVIDE(COALESCE(p.direct_users,0),   NULLIF(p.users_total,0)) AS last_touch_rate,
    CASE
        WHEN SAFE_DIVIDE(COALESCE(p.direct_sales,0), NULLIF(t.spend,0)) < {{target_roas}}
         AND SAFE_DIVIDE(COALESCE(p.assisted_users,0), NULLIF(p.users_total,0)) >= {{assist_rate_threshold}}
        THEN 'PROTECT'
        WHEN SAFE_DIVIDE(COALESCE(p.direct_sales,0), NULLIF(t.spend,0)) >= {{target_roas}}
        THEN 'OK_DIRECT_WINNER'
        ELSE 'REVIEW'
    END AS decision
FROM traffic t
LEFT JOIN paths p ON p.campaign_id = t.campaign_id
$SQL$,
version = COALESCE(version,1) + 1,
updated_at = NOW()
WHERE code = 'MC_ZANOM_Q005';
