-- PERFORMANCE: o alvo do ML custa ~1s pra recalcular (agrega gold_hourly_signal_amc
-- inteiro) e e lido pela tela de keywords, pelo cockpit e pelo auto-apply. Junto
-- com a fila do cockpit (que ja custa 8.6s por conta propria) virou 14s de tela.
--
-- Materializa o alvo e mantem o NOME da view apontando pra ele: todos os
-- consumidores (recs_v3, review_queue_v3, auto-apply) seguem iguais.
-- O refresh entra no refresh_swarm_account_state(), que ja roda de hora em hora
-- e sob demanda quando o dono aplica algo.
CREATE MATERIALIZED VIEW IF NOT EXISTS marketcloud_gold.gold_hourly_ml_target_mv AS
WITH camp AS (
    SELECT campaign_name, sum(sales_7d)/NULLIF(sum(spend),0) AS roas_campanha, sum(spend) AS gasto_total
    FROM marketcloud_gold.gold_hourly_signal_amc GROUP BY 1 HAVING sum(spend) > 0
), hora AS (
    SELECT campaign_name, event_hour, sum(sales_7d) AS venda, sum(spend) AS gasto, sum(clicks) AS cliques
    FROM marketcloud_gold.gold_hourly_signal_amc GROUP BY 1,2
)
SELECT h.campaign_name, h.event_hour,
       p.expected_roas::numeric AS prior_ml_roas,
       p.conversion_probability::numeric AS ml_conversion_probability,
       h.gasto::numeric AS gasto_observado,
       h.cliques AS cliques_observados,
       (h.venda/NULLIF(h.gasto,0))::numeric AS roas_observado,
       c.roas_campanha::numeric AS roas_ancora,
       ((h.venda + 20*p.expected_roas)/(h.gasto + 20))::numeric AS alvo_roas,
       GREATEST(0.30, LEAST(1.00, round((((h.venda + 20*p.expected_roas)/(h.gasto + 20))/c.roas_campanha*20)::numeric)/20)) AS ml_multiplier
FROM hora h
JOIN marketcloud_gold.hourly_ml_predictions_v2 p ON p.campaign_name=h.campaign_name AND p.event_hour=h.event_hour
JOIN camp c ON c.campaign_name=h.campaign_name
WHERE c.roas_campanha > 0;

CREATE UNIQUE INDEX IF NOT EXISTS idx_ml_target_mv_key
  ON marketcloud_gold.gold_hourly_ml_target_mv (campaign_name, event_hour);

CREATE OR REPLACE VIEW marketcloud_gold.gold_hourly_ml_target_multiplier AS
SELECT * FROM marketcloud_gold.gold_hourly_ml_target_mv;

COMMENT ON MATERIALIZED VIEW marketcloud_gold.gold_hourly_ml_target_mv IS
    'Alvo do ML materializado (a view de mesmo nome so aponta pra ca). Refresh no refresh_swarm_account_state().';

-- O refresh entra no fim do sync: assim o alvo acompanha o dado novo tanto no
-- loop de hora em hora quanto no refresh sob demanda (botao Aplicar da tela).
-- CONCURRENTLY pra nao travar leitura da tela; exige o indice unico acima.
CREATE OR REPLACE FUNCTION marketcloud_bronze.refresh_ml_target_mv()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY marketcloud_gold.gold_hourly_ml_target_mv;
EXCEPTION WHEN OTHERS THEN
    -- primeira carga (matview nunca populada) nao aceita CONCURRENTLY
    REFRESH MATERIALIZED VIEW marketcloud_gold.gold_hourly_ml_target_mv;
END; $$;
