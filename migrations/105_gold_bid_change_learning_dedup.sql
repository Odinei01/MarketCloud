-- =====================================================================
-- gold_bid_change_learning: dedupe do fan-out campanha-dia
--
-- A fonte swarm_src.amazon_ads_bid_learning_outcomes grava UMA linha por
-- execution_item (cada mudanca de BID), mas mede ROAS no grao CAMPANHA/DIA
-- (proxy DAILY_FALLBACK). Logo, N mudancas na mesma campanha no mesmo dia
-- geram N linhas identicas com a MESMA comparacao (baseline_date, measured_date,
-- roas_delta).
--
-- A versao anterior agregava count(*)/avg(roas_delta)/avg(roas_delta>0) por
-- campanha SEM dedupe: um dia com 300 mudancas de BID pesava 300x contra um dia
-- com 2 mudancas. Isso enviesava learn_roas_delta_avg e learn_win_rate (que o
-- ML consome via gold_hourly_signal_amc -> feature_full_control_campaign_hour_v1).
-- Medido: campanha 122134581461928 tinha 2119 linhas para 17 comparacoes reais.
--
-- Fix: colapsar cada comparacao campanha-dia a UM ponto antes de agregar. Assim
-- cada dia medido pesa igual, independNao de quantas keywords mudaram naquele dia.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_gold.gold_bid_change_learning AS
WITH per_campaign_day AS (
    -- uma linha por comparacao real (campanha x baseline x measured); o roas_delta
    -- e deterministico dentro do grupo, entao avg() apenas colapsa duplicatas.
    SELECT
        o.campaign_id,
        o.baseline_date,
        o.measured_date,
        avg(o.roas_delta) AS roas_delta
    FROM swarm_src.amazon_ads_bid_learning_outcomes o
    WHERE o.measured_date IS NOT NULL
      AND o.roas_delta IS NOT NULL
    GROUP BY o.campaign_id, o.baseline_date, o.measured_date
)
SELECT
    n.campaign_name,
    count(*) AS measured_changes,  -- agora: numero de dias-campanha medidos (pontos independentes), nao mudancas de BID
    avg(d.roas_delta)::double precision AS roas_delta_avg,
    avg(CASE WHEN d.roas_delta > 0::numeric THEN 1.0 ELSE 0.0 END)::double precision AS win_rate
FROM per_campaign_day d
JOIN marketcloud_bronze.bronze_swarm_campaign_names n ON n.campaign_id = d.campaign_id
GROUP BY n.campaign_name;

COMMENT ON VIEW marketcloud_gold.gold_bid_change_learning IS
    'Aprendizado de mudanca de BID por campanha (proxy diario). Deduplicado por campanha-dia: cada comparacao ROAS pesa uma vez, sem o fan-out de N mudancas por dia. Alimenta learn_roas_delta_avg/learn_win_rate do ML.';
