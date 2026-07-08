-- =====================================================================
-- Lake — Relatório HORÁRIO real do Amazon Ads (Sponsored Products)
--
-- A verdade horária SEM supressão (diferente do AMC E004, que suprime ~74%
-- das conversões no grão hora×adgroup). Fonte: export "Sponsored Products
-- Campanha" por hora do console/Ads API. Grão: data × hora × campanha.
--
-- Comparação validada (22-24/jun): AMC E004 = 4 pedidos (2 células); este
-- relatório = 11 pedidos (10 células) com hora e ROAS reais.
--
-- Ingestão hoje: manual (CSV do console). Contínua: o SWARM deve pedir o
-- report horário (Ads API, mesmo caminho do amazon_ads_campaigns_daily) e o
-- lake ingere via fdw. Sem campaign_id na fonte -> mapear por campaign_name.
-- =====================================================================
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amazon_ads_hourly (
    data_date DATE, event_hour INT, campaign_name TEXT, campaign_status TEXT,
    portfolio TEXT, targeting_type TEXT, bid_strategy TEXT, budget NUMERIC(18,2),
    impressions BIGINT, clicks BIGINT, spend NUMERIC(18,4), cpc NUMERIC(18,4),
    orders_7d NUMERIC(18,4), acos NUMERIC(18,6), roas NUMERIC(18,4), sales_7d NUMERIC(18,4),
    ingested_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT pk_bronze_ads_hourly PRIMARY KEY (data_date, event_hour, campaign_name)
);
CREATE INDEX IF NOT EXISTS idx_ads_hourly_hour ON marketcloud_bronze.bronze_amazon_ads_hourly (event_hour);
CREATE INDEX IF NOT EXISTS idx_ads_hourly_campaign ON marketcloud_bronze.bronze_amazon_ads_hourly (campaign_name, data_date);
