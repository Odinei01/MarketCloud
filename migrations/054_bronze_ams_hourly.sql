-- =====================================================================
-- Landing do Amazon Marketing Stream (push, hora-a-hora, SEM supressão).
--
-- Chaveado por campaign_id (o Stream manda campaignId — resolve o problema de
-- name->id que a ponte CSV tinha). Dois datasets aterrissam aqui:
--   sp-traffic     -> impressions, clicks, spend
--   sp-conversion  -> orders/sales por janela de atribuição (1d/7d/14d/30d)
--
-- RESTATEMENT: a conversão é REENVIADA conforme a atribuição amadurece. O
-- consumidor faz UPSERT com LAST-WRITE-WINS por (data, hora, campanha) — NUNCA
-- soma. Amazon manda o valor cumulativo atualizado da janela; sobrescrever é o
-- correto. Somar infla vendas.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_ams_hourly (
    data_date        DATE    NOT NULL,
    event_hour       INTEGER NOT NULL,
    campaign_id      TEXT    NOT NULL,
    campaign_name    TEXT,
    ad_group_id      TEXT,
    -- sp-traffic
    impressions      BIGINT,
    clicks           BIGINT,
    spend            NUMERIC(18,4),
    -- sp-conversion (por janela de atribuição)
    orders_1d        NUMERIC(18,4),
    sales_1d         NUMERIC(18,4),
    orders_7d        NUMERIC(18,4),
    sales_7d         NUMERIC(18,4),
    orders_14d       NUMERIC(18,4),
    sales_14d        NUMERIC(18,4),
    -- proveniência / restatement
    last_traffic_at     TIMESTAMPTZ,
    last_conversion_at  TIMESTAMPTZ,
    traffic_msg_time    TIMESTAMPTZ, -- time do evento no payload (idempotência)
    conversion_msg_time TIMESTAMPTZ,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_bronze_ams_hourly PRIMARY KEY (data_date, event_hour, campaign_id)
);
CREATE INDEX IF NOT EXISTS idx_bronze_ams_hourly_period
    ON marketcloud_bronze.bronze_ams_hourly (data_date, event_hour);

COMMENT ON TABLE marketcloud_bronze.bronze_ams_hourly IS
    'Amazon Marketing Stream landing (sp-traffic + sp-conversion). Last-write-wins por PK — trata restatement da conversão. Alimenta o Gold horário quando o Stream estiver ligado.';
