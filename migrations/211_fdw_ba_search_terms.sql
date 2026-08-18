-- 211: expõe a tabela dedicada de Search Terms (E003) do mercado-data-app via FDW.
-- O Search Terms tinha shape long próprio (1 linha por termo×posição-no-top3) mas era
-- mal-alojado na tabela de Search Query Performance (E001). Agora tem casa própria
-- (amazon_brand_analytics_search_terms) com colunas limpas — click_share_rank deixa de
-- ser extração de raw_json e vira coluna. Esta FT deixa o gold pronto pra ser repontado
-- (mv_gold_market_search_weekly + mv_brand_analytics_market_query) numa migration seguinte.
CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_brand_analytics_search_terms (
  report_id text,
  period text,
  period_start date,
  period_end date,
  marketplace_id text,
  department_name text,
  search_term text,
  search_frequency_rank integer,
  click_share_rank integer,
  clicked_asin text,
  clicked_item_name text,
  click_share numeric,
  conversion_share numeric,
  raw_json_sanitized jsonb,
  synced_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_brand_analytics_search_terms');
