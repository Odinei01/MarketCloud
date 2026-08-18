-- 210: importa a Relevância V1 (termo↔ASIN) do cérebro ZM19 (mercado-data-app)
-- no FDW swarm_src, para o Radar de Search Term (:3001) pintar cada termo com o
-- veredito de aderência ao produto real (catalog attributes). Advisory, não recalcula.
CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.zm19_term_relevance (
  campaign_id text,
  campaign_name text,
  entity_label text,
  best_asin text,
  relevance numeric,
  n_meaningful integer,
  n_matched integer,
  contradiction boolean,
  verdict text,
  termos_ausentes text
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'v_zm19_term_relevance');
