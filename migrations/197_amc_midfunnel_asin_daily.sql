-- 197 — meio-funil (DPV/ATC) por ASIN x DIA. O Q041 traz DPV/ATC mas so por campanha e
-- sem data (snapshot). Aqui: MC_ZANOM_Q043 le conversions_with_relevance no grao
-- conversion_event_date x tracked_asin -> serie diaria por ASIN, pra completar o funil
-- por produto (Impr->Click->DPV->ATC->compra). Fonte certa: conversions_with_relevance
-- (o attributed_events dos Sponsored Ads volta 0 de DPV/ATC nessa conta).

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_midfunnel_asin_daily (
	data_date          date NOT NULL,
	asin               text NOT NULL,
	detail_page_views  numeric NOT NULL DEFAULT 0,
	cart_adds          numeric NOT NULL DEFAULT 0,
	updated_at         timestamptz NOT NULL DEFAULT now(),
	PRIMARY KEY (data_date, asin)
);

-- template Q043: copia tenant_id/parameters_schema do Q041 e sobrescreve o essencial.
INSERT INTO query_templates
	(tenant_id, name, code, description, query_family, query_goal, sql_template,
	 parameters_schema, min_lookback_days, max_lookback_days, supported_campaign_types,
	 supported_marketplaces, version, status)
SELECT
	tenant_id,
	'MC_ZANOM_Q043 — Meio-funil ASIN diario (DPV/ATC)',
	'MC_ZANOM_Q043',
	'DPV/ATC por ASIN x dia via conversions_with_relevance — completa o funil por produto.',
	query_family,
	'dpv/atc por ASIN x dia para o funil por produto (diario).',
	$SQL$
-- NB: no conversions_with_relevance o ASIN relevante e `tracked_item` (o `tracked_asin`
-- existe mas vem NULL nesses eventos de meio-funil vindos do DSP retargeting). Data =
-- `event_date` (o `conversion_event_date` e do attributed_events, outra tabela).
SELECT
    event_date   AS data_date,
    tracked_item AS asin,
    COUNT(DISTINCT CASE WHEN event_subtype = 'detailPageView' THEN conversion_id END) AS detail_page_views,
    COUNT(DISTINCT CASE WHEN event_subtype = 'shoppingCart'   THEN conversion_id END) AS cart_adds
FROM conversions_with_relevance
WHERE user_id IS NOT NULL
  AND event_subtype IN ('detailPageView','shoppingCart')
  AND tracked_item IS NOT NULL
  AND event_date IS NOT NULL
GROUP BY event_date, tracked_item
$SQL$,
	parameters_schema, min_lookback_days, max_lookback_days, supported_campaign_types,
	supported_marketplaces, 1, 'ACTIVE'
FROM query_templates
WHERE code = 'MC_ZANOM_Q041'
  AND NOT EXISTS (SELECT 1 FROM query_templates WHERE code = 'MC_ZANOM_Q043');
