-- 166_impression_share_column.sql
-- PECA 2 do impression share: coluna aditiva (nullable) na tabela do relatorio diario
-- de campanha + view que expoe a IS por campanha x dia. NAO quebra nada: coluna nova
-- fica NULL ate o conector (peca 1) comecar a preencher. O ML (peca 3) junta por
-- campaign_id + data e transmite a IS do dia as horas daquele dia.
--
-- topOfSearchImpressionShare = parcela do topo de busca que voce ganhou (0-100).
-- Metrica DIARIA da Amazon (nao existe horaria).

ALTER TABLE marketcloud_ops.ads_reporting_sp_campaign_daily_v3
  ADD COLUMN IF NOT EXISTS top_of_search_is numeric;

CREATE OR REPLACE VIEW marketcloud_gold.v_campaign_impression_share_daily AS
SELECT profile_id, data_date, campaign_id, campaign_name,
       top_of_search_is
FROM marketcloud_ops.ads_reporting_sp_campaign_daily_v3
WHERE top_of_search_is IS NOT NULL;

COMMENT ON COLUMN marketcloud_ops.ads_reporting_sp_campaign_daily_v3.top_of_search_is
  IS 'Top-of-search impression share (0-100), diaria, do relatorio spCampaigns v3. Alimenta feature do ML.';
