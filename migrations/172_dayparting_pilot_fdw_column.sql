-- 172_dayparting_pilot_fdw_column.sql
-- A coluna dayparting_synced foi criada no pricing (mercado-data-app, via
-- ensureAmazonAdsBidScheduleAdmin). Pro marketcloud ler/gravar a flag pela foreign
-- table (FDW swarm_src -> pricing_db), a coluna precisa existir na definicao da
-- foreign table. Sem isso, a tela de aprovacao (DP Calibracao) nao enxerga a flag.
ALTER FOREIGN TABLE swarm_src.zanom_ads_bid_schedule_profiles ADD COLUMN IF NOT EXISTS dayparting_synced boolean;
