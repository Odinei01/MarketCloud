-- Auditoria final (16/07) #5: a campanha 275958980572653 esta em full-auto sem
-- holdout. Investigado: ela tem ZERO sinal (0 horas em gold_hourly_signal_amc,
-- 0 linhas/gasto/venda no relatorio). E campanha fantasma — nome generico
-- "Campanha - 24/06/2026 ...", criada e sem trafego desde entao. O holdout de
-- ontem partia do sinal, entao ela ficou de fora corretamente: nao ha o que
-- sortear nem o que medir. Full-auto nela nao aplica nada e nao aprende nada.
--
-- Das duas saidas da auditoria (criar holdout OU desligar), desligar e a certa:
-- criar holdout de campanha sem dado e teatro. Desligo a flag.
UPDATE marketcloud_control.ml_full_auto_campaign_flags
SET enabled = FALSE, updated_at = NOW(),
    notes = coalesce(notes,'') || ' [desligada 16/07: campanha sem sinal/holdout]'
WHERE enabled AND campaign_id = '275958980572653';

-- Sentinela: campanha full-auto ligada que nao tem holdout. Vazio = saudavel.
-- Full-auto sem holdout perde a leitura causal — se aparecer aqui, ou sorteia
-- controle ou desliga.
CREATE OR REPLACE VIEW marketcloud_gold.gold_full_auto_sem_holdout AS
SELECT f.campaign_name, f.campaign_id
FROM marketcloud_control.ml_full_auto_campaign_flags f
WHERE f.enabled
  AND NOT EXISTS (SELECT 1 FROM marketcloud_control.holdout_cells h
                  WHERE h.campaign_name = f.campaign_name);

COMMENT ON VIEW marketcloud_gold.gold_full_auto_sem_holdout IS
    'Campanha full-auto sem grupo de controle. Vazio = saudavel; nao-vazio = sortear holdout ou desligar a flag (full-auto sem holdout nao tem leitura causal).';
