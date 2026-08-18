-- 209: importa as recomendacoes do cerebro ZM19 (mercado-data-app) no FDW swarm_src,
-- para o MarketCloud EXIBIR o radar de search term na tela de dayparting (:3001) sem
-- recalcular (um cerebro so: o ZM19 gera, o MarketCloud so espelha).
CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.m19_clone_recommendations (
  id bigint,
  created_at timestamptz,
  action text,
  campaign_name text,
  ad_group_id text,
  entity_type text,
  entity_label text,
  match_type text,
  to_value text,
  reason_code text,
  evidence jsonb,
  status text
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'm19_clone_recommendations');
