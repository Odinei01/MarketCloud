-- 175: renomeia a coluna do bridge de margem pra deixar a SEMANTICA honesta.
-- NAO e margem liquida/contribuicao (ignora fee real, ads, imposto, COPER, devolucao,
-- multiplos SKU/ASIN). E margem BRUTA DE CATALOGO = (preco - custo)/preco. Nome antigo
-- (gross_margin_pct) sugeria margem final; passa a gross_catalog_margin_pct.
DROP VIEW IF EXISTS marketcloud_features.feature_campaign_margin_bridge_v1;
CREATE VIEW marketcloud_features.feature_campaign_margin_bridge_v1 AS
WITH camp_asin AS (
  SELECT DISTINCT ti.campaign_id, split_part(ti.ad_group_name,'_',1) AS asin
  FROM swarm_src.amazon_ads_targeting_inventory ti
  WHERE COALESCE(ti.ad_group_name,'')<>'' AND split_part(ti.ad_group_name,'_',1) ~ '^B0'
),
asin_margin AS (
  SELECT al.asin, MAX(al.price) price, MAX(COALESCE(ll.product_cost,0)) cost
  FROM swarm_src.amazon_listings al
  LEFT JOIN swarm_src.amazon_listing_links ll ON ll.seller_sku=al.seller_sku
  WHERE COALESCE(al.asin,'')<>''
  GROUP BY al.asin
)
SELECT ca.campaign_id,
  round(avg(CASE WHEN am.price>0 AND am.cost>0 THEN 100.0*(am.price-am.cost)/am.price END)::numeric,2) gross_catalog_margin_pct,
  round(avg(CASE WHEN am.price>0 AND am.cost>0 THEN am.price-am.cost END)::numeric,2) gross_catalog_margin_brl,
  count(*) FILTER (WHERE am.cost>0) asins_com_custo
FROM camp_asin ca JOIN asin_margin am ON am.asin=ca.asin
GROUP BY ca.campaign_id;
