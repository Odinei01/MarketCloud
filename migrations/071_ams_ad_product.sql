-- Marca de qual produto de anuncio veio cada linha horaria do AMS.
-- Motivo: em 15/07 a pergunta "o ML ja ve as campanhas SD?" so pode ser
-- respondida com um SELECT se a linha souber dizer o que ela e. Ate aqui a
-- bronze so tinha SP (o AMS estava inscrito apenas em sp-traffic/sp-conversion),
-- entao o default retroativo e SPONSORED_PRODUCTS e e verdadeiro.
ALTER TABLE marketcloud_bronze.bronze_ams_hourly
    ADD COLUMN IF NOT EXISTS ad_product TEXT NOT NULL DEFAULT 'SPONSORED_PRODUCTS';

CREATE INDEX IF NOT EXISTS idx_bronze_ams_hourly_ad_product
    ON marketcloud_bronze.bronze_ams_hourly (ad_product, data_date);

COMMENT ON COLUMN marketcloud_bronze.bronze_ams_hourly.ad_product IS
    'SPONSORED_PRODUCTS | SPONSORED_DISPLAY: de qual dataset AMS a linha veio.';
