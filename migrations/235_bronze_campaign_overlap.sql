-- 235: destino do Q034 (canibalizacao entre campanhas).
-- Snapshot: o ingest faz TRUNCATE + INSERT, igual ao padrao do Q005.
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_campaign_overlap (
    campaign_a                TEXT,
    campaign_b                TEXT,
    overlap_users             NUMERIC,
    users_a                   NUMERIC,
    users_b                   NUMERIC,
    overlap_rate_a            NUMERIC,
    overlap_rate_b            NUMERIC,
    spend_a                   NUMERIC,
    spend_b                   NUMERIC,
    duplicated_spend_estimate NUMERIC,
    decision                  TEXT,
    updated_at                TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON COLUMN marketcloud_bronze.bronze_amc_campaign_overlap.duplicated_spend_estimate IS
'ESTIMATIVA, nao medicao: custo por usuario de cada campanha x usuarios alcancados pelas duas. A Amazon nao informa o custo de alcancar um usuario especifico.';
COMMENT ON COLUMN marketcloud_bronze.bronze_amc_campaign_overlap.overlap_users IS
'Usuarios expostos as DUAS campanhas. So o AMC responde isso — o relatorio de Ads conta por campanha e nunca cruza pessoa.';
