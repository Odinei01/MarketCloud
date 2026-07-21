-- 145_dayparting_calibration_ml_ledger.sql
-- Ledger de medicao para aprendizado (vira ML quando houver dado).
--
-- Filosofia do dono: "medir tudo para aprendizado". O gasto por hora ja e medido
-- imediatamente (bronze_ams_hourly_target.spend); a venda atribuida pousa depois
-- (Amazon atrasa). A calibracao ja HISTORIZA cada decisao (computed_at). Esta view
-- casa: (features no momento da decisao) + (resultado REALIZADO nos 7 dias
-- seguintes naquela keyword x hora) = linha de treino pronta para ML.
--
-- Nao aplica nada; so observa. Como roda semanal, o dataset cresce sozinho. Quando
-- houver volume, treina-se um modelo em cima desta view (snapshot congelado no
-- momento do treino para reprodutibilidade).

CREATE OR REPLACE VIEW marketcloud_gold.v_dayparting_calibration_ml_dataset_v1 AS
SELECT
    c.computed_at,
    c.keyword_id,
    c.keyword_text,
    c.campaign_id,
    c.event_hour,
    c.scope,
    -- features no momento da decisao
    c.published_multiplier,
    c.recommended_multiplier,
    c.target_multiplier,
    c.action,
    c.gate,
    c.hour_roas          AS roas_at_decision,
    c.scope_avg_roas     AS scope_avg_at_decision,
    c.signal,
    c.weeks_of_data,
    c.spend              AS spend_window_at_decision,
    -- resultado REALIZADO nos 7 dias apos a decisao (o "label")
    r.realized_spend,
    r.realized_sales,
    r.realized_days,
    CASE WHEN COALESCE(r.realized_spend,0) > 0
         THEN round(r.realized_sales / r.realized_spend, 2) END AS realized_roas,
    -- maturidade da atribuicao: quantos dias ja passaram desde a decisao
    (CURRENT_DATE - c.computed_at::date) AS days_since_decision,
    ((CURRENT_DATE - c.computed_at::date) >= 9) AS attribution_mature
FROM marketcloud_gold.gold_keyword_hourly_calibration_v1 c
LEFT JOIN LATERAL (
    SELECT sum(b.spend)                                  AS realized_spend,
           sum(b.sales_7d)                               AS realized_sales,
           count(DISTINCT b.data_date)                   AS realized_days
    FROM marketcloud_bronze.bronze_ams_hourly_target b
    WHERE b.keyword_id = c.keyword_id
      AND b.event_hour = c.event_hour
      AND b.data_date >  c.computed_at::date
      AND b.data_date <= c.computed_at::date + 7
) r ON true;

-- Resumo do ledger (para a tela de UX / acompanhamento).
CREATE OR REPLACE VIEW marketcloud_gold.v_dayparting_ledger_summary_v1 AS
SELECT
    computed_at::date                                        AS decision_date,
    count(*)                                                 AS decisoes,
    count(*) FILTER (WHERE gate='OK' AND action<>'HOLD')     AS recomendacoes,
    count(*) FILTER (WHERE attribution_mature)               AS ja_maduras,
    round(avg(realized_roas) FILTER (WHERE attribution_mature AND realized_roas IS NOT NULL), 2) AS roas_realizado_medio
FROM marketcloud_gold.v_dayparting_calibration_ml_dataset_v1
GROUP BY 1
ORDER BY 1 DESC;
