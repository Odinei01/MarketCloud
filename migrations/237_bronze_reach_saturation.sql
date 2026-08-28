-- 237: destino do Q037 (saturacao de alcance). Snapshot via TRUNCATE + INSERT.
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_reach_saturation (
    campaign_id      TEXT,
    campaign_name    TEXT,
    users_reached    NUMERIC,
    impressions      NUMERIC,
    clicks           NUMERIC,
    spend            NUMERIC,
    frequency_avg    NUMERIC,
    fresh_reach_rate NUMERIC,
    saturation_rate  NUMERIC,
    cost_per_user    NUMERIC,
    decision         TEXT,
    updated_at       TIMESTAMPTZ DEFAULT NOW()
);
COMMENT ON COLUMN marketcloud_bronze.bronze_amc_reach_saturation.frequency_avg IS
'Impressoes por pessoa distinta. So o AMC responde: o relatorio de Ads conta impressao e nao sabe em quantas pessoas ela bateu.';
COMMENT ON COLUMN marketcloud_bronze.bronze_amc_reach_saturation.fresh_reach_rate IS
'Fracao de usuarios que viram o anuncio UMA vez — proxy de alcance ainda nao explorado.';
