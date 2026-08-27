-- 227: REVERTE a Q005 para a versao que roda.
--
-- Tentei consertar o produto cartesiano duas vezes (225 e 226) e as duas foram
-- rejeitadas pelo AMC no parse. A versao original tem 56 execucoes concluidas, a
-- ultima hoje. Ela devolve numero errado — mas devolve; as minhas nao devolvem nada.
--
-- Deixar o pipeline quebrado enquanto eu adivinho o dialeto e pior que o dado errado
-- que existia antes, e o dado errado ja estava documentado e marcado como nao-confiavel.
--
-- O diagnostico do fan-out continua correto: o JOIN so por campaign_id multiplica
-- gasto por M e venda por N, e o ROAS vira razao arbitraria. Isso explica R$536.795 de
-- venda numa operacao de R$28 mil/mes. O que falhou foi a EXECUCAO da correcao, nao o
-- diagnostico.
--
-- Para retomar: o AMC rejeita 'date' mesmo qualificado dentro de CTE, e o erro se
-- desloca de coluna 11 para 12 ao adicionar o alias — sinal de que o problema nao e o
-- alias. Proximo passo seria testar se o AMC aceita WITH nessa posicao, o que exige
-- submeter variantes e esperar cada uma. Nao da para adivinhar por leitura.

UPDATE query_templates SET sql_template = $SQL$
SELECT
    c.campaign_id,
    c.campaign_name,
    {{product_group_label}} AS product_group,
    SUM(c.spend)                                                               AS spend,
    COUNT(DISTINCT CASE WHEN p.touchpoint_position='LAST' THEN p.user_id END)  AS direct_orders,
    SUM(CASE WHEN p.touchpoint_position='LAST' THEN p.purchase_value ELSE 0 END) AS direct_sales,
    SAFE_DIVIDE(
        SUM(CASE WHEN p.touchpoint_position='LAST' THEN p.purchase_value ELSE 0 END),
        NULLIF(SUM(c.spend),0))                                                AS direct_roas,
    COUNT(DISTINCT CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.user_id END) AS assisted_orders,
    SUM(CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.attributed_value ELSE 0 END) AS assisted_sales,
    SAFE_DIVIDE(
        SUM(CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.attributed_value ELSE 0 END),
        NULLIF(SUM(c.spend),0))                                                AS assisted_roas,
    SAFE_DIVIDE(
        COUNT(DISTINCT CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.user_id END),
        NULLIF(COUNT(DISTINCT p.user_id),0))                                   AS assist_rate,
    SAFE_DIVIDE(
        COUNT(DISTINCT CASE WHEN p.touchpoint_position='FIRST' THEN p.user_id END),
        NULLIF(COUNT(DISTINCT p.user_id),0))                                   AS first_touch_rate,
    SAFE_DIVIDE(
        COUNT(DISTINCT CASE WHEN p.touchpoint_position='MIDDLE' THEN p.user_id END),
        NULLIF(COUNT(DISTINCT p.user_id),0))                                   AS middle_touch_rate,
    SAFE_DIVIDE(
        COUNT(DISTINCT CASE WHEN p.touchpoint_position='LAST' THEN p.user_id END),
        NULLIF(COUNT(DISTINCT p.user_id),0))                                   AS last_touch_rate,
    CASE
        WHEN SAFE_DIVIDE(
                SUM(CASE WHEN p.touchpoint_position='LAST' THEN p.purchase_value ELSE 0 END),
                NULLIF(SUM(c.spend),0)) < {{target_roas}}
         AND SAFE_DIVIDE(
                COUNT(DISTINCT CASE WHEN p.touchpoint_position!='LAST' AND p.path_had_conversion=1 THEN p.user_id END),
                NULLIF(COUNT(DISTINCT p.user_id),0)) >= {{assist_rate_threshold}}
        THEN 'PROTECT'
        WHEN SAFE_DIVIDE(
                SUM(CASE WHEN p.touchpoint_position='LAST' THEN p.purchase_value ELSE 0 END),
                NULLIF(SUM(c.spend),0)) >= {{target_roas}}
        THEN 'OK_DIRECT_WINNER'
        ELSE 'REVIEW'
    END AS decision
FROM sponsored_ads_traffic_report c
JOIN amc_path_to_purchase p ON c.campaign_id = p.campaign_id
    AND p.impression_date BETWEEN {{period_start}} AND {{period_end}}
WHERE c.date BETWEEN {{period_start}} AND {{period_end}}
  {{campaign_filter}}
GROUP BY c.campaign_id, c.campaign_name
ORDER BY assist_rate DESC
$SQL$,
version = COALESCE(version,1) + 1, updated_at = NOW()
WHERE code = 'MC_ZANOM_Q005';
