-- Camada de ALERTAS AMC: avalia o retargeting SD e cospe veredito automatico
-- (reativar / escalar / matar) — pro dono não precisar rodar query.
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_sd_retargeting_eval (
    sd_campaign      TEXT,
    product_key      TEXT,
    engaged_users    NUMERIC,
    buyers           NUMERIC,
    conversion_rate  NUMERIC,
    base_cvr         NUMERIC,
    lift_vs_baseline NUMERIC,
    product_orders   NUMERIC,
    product_revenue  NUMERIC,
    updated_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE VIEW marketcloud_gold.gold_amc_retargeting_alerts AS
SELECT
    sd_campaign,
    product_key,
    engaged_users,
    buyers,
    ROUND(conversion_rate::numeric, 4)  AS conversion_rate,
    ROUND(lift_vs_baseline::numeric, 1) AS lift_vs_baseline,
    ROUND(product_revenue::numeric, 2)  AS product_revenue,
    CASE
        WHEN engaged_users >= 15 AND COALESCE(buyers,0) = 0             THEN 'MATAR'
        WHEN COALESCE(buyers,0) >= 5 AND lift_vs_baseline >= 5          THEN 'ESCALAR'
        WHEN COALESCE(buyers,0) >= 1                                    THEN 'MONITORAR'
        ELSE 'BAIXO_SINAL'
    END AS verdict,
    CASE
        WHEN engaged_users >= 15 AND COALESCE(buyers,0) = 0 THEN
            '🔴 MATAR — ' || sd_campaign || ': ' || engaged_users || ' reimpactados, 0 compra. Só queima custo.'
        WHEN COALESCE(buyers,0) >= 5 AND lift_vs_baseline >= 5 THEN
            '🟢 ESCALAR — ' || sd_campaign || ': público converte ' || ROUND(lift_vs_baseline::numeric,0)
            || 'x o baseline, ' || buyers || ' compradores, R$ ' || ROUND(product_revenue::numeric,0) || ' atribuídos.'
        WHEN COALESCE(buyers,0) >= 1 THEN
            '🟡 MONITORAR — ' || sd_campaign || ': ' || buyers || ' compradores; sinal positivo, volume baixo.'
        ELSE
            '⚪ BAIXO SINAL — ' || sd_campaign || ': engajou mas ainda sem conversão relevante.'
    END AS alerta,
    CASE
        WHEN engaged_users >= 15 AND COALESCE(buyers,0) = 0            THEN 1  -- ação urgente (desperdício)
        WHEN COALESCE(buyers,0) >= 5 AND lift_vs_baseline >= 5         THEN 2  -- oportunidade
        WHEN COALESCE(buyers,0) >= 1                                   THEN 3
        ELSE 4
    END AS priority
FROM marketcloud_bronze.bronze_amc_sd_retargeting_eval;
