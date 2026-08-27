-- 226: 'date' e palavra reservada no dialeto do AMC.
--
-- A correcao do produto cartesiano (migration 225) trocou o FROM direto por CTEs. No
-- caminho, o filtro perdeu o alias:
--
--     antes:  WHERE c.date BETWEEN ...   -> parseava
--     depois: WHERE date   BETWEEN ...   -> AMC_QUERY_REJECTED
--
-- "Encountered 'date BETWEEN' at line 7, column 11". Qualificado o parser resolve como
-- coluna; sozinho ele tenta ler como tipo e quebra. Erro meu na reescrita, nao da
-- correcao do join — que segue valendo.
--
-- Mesmo tratamento no impression_date por precaucao, e para a proxima pessoa nao
-- precisar descobrir de novo.

UPDATE query_templates SET sql_template = $SQL$
WITH traffic AS (
    SELECT
        t.campaign_id,
        MAX(t.campaign_name) AS campaign_name,
        SUM(t.spend)         AS spend
    FROM sponsored_ads_traffic_report t
    WHERE t.date BETWEEN {{period_start}} AND {{period_end}}
      {{campaign_filter}}
    GROUP BY t.campaign_id
),
paths AS (
    SELECT
        p.campaign_id,
        COUNT(DISTINCT p.user_id)                                                       AS users_total,
        COUNT(DISTINCT CASE WHEN p.touchpoint_position='LAST'   THEN p.user_id END)     AS direct_users,
        COUNT(DISTINCT CASE WHEN p.touchpoint_position='FIRST'  THEN p.user_id END)     AS first_users,
        COUNT(DISTINCT CASE WHEN p.touchpoint_position='MIDDLE' THEN p.user_id END)     AS middle_users,
        COUNT(DISTINCT CASE WHEN p.touchpoint_position!='LAST'
                             AND p.path_had_conversion=1        THEN p.user_id END)     AS assisted_users,
        SUM(CASE WHEN p.touchpoint_position='LAST' THEN p.purchase_value ELSE 0 END)    AS direct_sales,
        SUM(CASE WHEN p.touchpoint_position!='LAST'
                  AND p.path_had_conversion=1 THEN p.attributed_value ELSE 0 END)       AS assisted_sales
    FROM amc_path_to_purchase p
    WHERE p.impression_date BETWEEN {{period_start}} AND {{period_end}}
    GROUP BY p.campaign_id
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
version = COALESCE(version,1) + 1, updated_at = NOW()
WHERE code = 'MC_ZANOM_Q005';
