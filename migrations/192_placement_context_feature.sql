-- 192 — Fase A: contexto de placement (top/rest/product adjustment) como feature do ML.
-- O pricing passou a gravar os 3 ajustes em amazon_ads_campaigns_daily; aqui expomos
-- via FDW e criamos a feature view. Config (nao outcome) -> sem leakage. Deixa o ML
-- calcular o bid EFETIVO por placement (o buraco que fez o ML querer cortar o abridor).

ALTER FOREIGN TABLE swarm_src.amazon_ads_campaigns_daily ADD COLUMN IF NOT EXISTS rest_of_search_bid_adjustment numeric;
ALTER FOREIGN TABLE swarm_src.amazon_ads_campaigns_daily ADD COLUMN IF NOT EXISTS product_page_bid_adjustment numeric;

CREATE OR REPLACE VIEW marketcloud_features.feature_campaign_placement_context_v1 AS
SELECT DISTINCT ON (campaign_id) campaign_id,
  COALESCE(top_of_search_bid_adjustment,0)::float8  AS placement_top_adj,
  COALESCE(rest_of_search_bid_adjustment,0)::float8 AS placement_rest_adj,
  COALESCE(product_page_bid_adjustment,0)::float8   AS placement_product_adj
FROM swarm_src.amazon_ads_campaigns_daily
WHERE COALESCE(campaign_id,'') <> ''
ORDER BY campaign_id, date DESC, structure_synced_at DESC NULLS LAST;

COMMENT ON VIEW marketcloud_features.feature_campaign_placement_context_v1 IS
  'Fase A: os 3 ajustes de placement por campanha (estado atual, config nao outcome -> sem leak). HourlyTargetRealV3 joina por campaign_id.';
