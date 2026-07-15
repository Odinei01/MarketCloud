package query

import (
	"context"
	"net/http"

	"github.com/jackc/pgx/v5"
)

const partnerCampaignsCTE = `
WITH watched(label, campaign_name, console_campaign_id, console_url) AS (
	VALUES
		('auto', 'SP -  - All products -  - auto - m19 autopilot - m9CiMFKmOjGF/1jM', 'A0932639GV0D8P0PYHSG', 'https://advertising.amazon.com.br/cm/sp/campaigns/A0932639GV0D8P0PYHSG?entityId=ENTITY1A6DL03BNNULZ'),
		('product', 'SP -  - All products -  - product - m19 autopilot - ITG1wbJ7wPUhSzGT', 'A09327071BYLJK06WKBKT', 'https://advertising.amazon.com.br/cm/sp/campaigns/A09327071BYLJK06WKBKT?entityId=ENTITY1A6DL03BNNULZ'),
		('exact', 'SP -  - All products -  - exact - m19 autopilot - vSjnFKqbm+IApSon', 'A09323953M5O5F9HAJ7IG', 'https://advertising.amazon.com.br/cm/sp/campaigns/A09323953M5O5F9HAJ7IG?entityId=ENTITY1A6DL03BNNULZ'),
		('phrase', 'SP -  - All products -  - phrase - m19 autopilot - 3oEr+QKQ/ZNIqsQs', 'A09325511H3FIAJFNMAA7', 'https://advertising.amazon.com.br/cm/sp/campaigns/A09325511H3FIAJFNMAA7?entityId=ENTITY1A6DL03BNNULZ')
)
`

// GET /api/v1/gold/partner-campaign-monitor
// Monitor especial das campanhas m19 autopilot criadas por parceiro.
func (h *Handler) GoldPartnerCampaignMonitor(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	summary, err := h.collectRows(ctx, partnerCampaignsCTE+`
, daily AS (
	SELECT campaign_id, campaign_name,
	       MAX(date) AS last_daily_date,
	       MIN(date) AS first_daily_date,
	       COUNT(*) AS daily_rows,
	       SUM(impressions)::float8 AS daily_impressions,
	       SUM(clicks)::float8 AS daily_clicks,
	       SUM(cost)::float8 AS daily_spend,
	       SUM(purchases)::float8 AS daily_orders,
	       SUM(attributed_sales)::float8 AS daily_sales,
	       MAX(synced_at) AS last_daily_sync
	FROM swarm_src.amazon_ads_campaigns_daily
	WHERE campaign_name IN (SELECT campaign_name FROM watched)
	GROUP BY campaign_id, campaign_name
), latest_daily AS (
	SELECT DISTINCT ON (campaign_name)
	       campaign_name, campaign_id, campaign_status, targeting_type,
	       budget_amount::float8 AS budget_amount, budget_type, bidding_strategy,
	       top_of_search_bid_adjustment::float8 AS top_of_search_bid_adjustment,
	       structure_synced_at, synced_at, date
	FROM swarm_src.amazon_ads_campaigns_daily
	WHERE campaign_name IN (SELECT campaign_name FROM watched)
	ORDER BY campaign_name, date DESC, synced_at DESC NULLS LAST
), reporting AS (
	SELECT campaign_name,
	       COUNT(*) AS hourly_rows,
	       MIN(data_date) AS first_hourly_date,
	       MAX(data_date) AS last_hourly_date,
	       SUM(impressions)::float8 AS hourly_impressions,
	       SUM(clicks)::float8 AS hourly_clicks,
	       SUM(spend)::float8 AS hourly_spend,
	       SUM(COALESCE(orders_7d,0))::float8 AS hourly_orders,
	       SUM(COALESCE(sales_7d,0))::float8 AS hourly_sales,
	       MAX(ingested_at) AS last_hourly_ingest
	FROM marketcloud_bronze.bronze_amazon_ads_hourly
	WHERE campaign_name IN (SELECT campaign_name FROM watched)
	GROUP BY campaign_name
), ams AS (
	SELECT d.campaign_name,
	       COUNT(a.*) AS ams_rows,
	       MAX(a.data_date + make_interval(hours => a.event_hour)) AS last_ams_hour,
	       SUM(COALESCE(a.impressions,0))::float8 AS ams_impressions,
	       SUM(COALESCE(a.clicks,0))::float8 AS ams_clicks,
	       SUM(COALESCE(a.spend,0))::float8 AS ams_spend,
	       SUM(GREATEST(COALESCE(a.orders_14d,0), COALESCE(a.orders_7d,0), COALESCE(a.orders_1d,0)))::float8 AS ams_orders,
	       SUM(GREATEST(COALESCE(a.sales_14d,0), COALESCE(a.sales_7d,0), COALESCE(a.sales_1d,0)))::float8 AS ams_sales,
	       MAX(a.updated_at) AS last_ams_update
	FROM latest_daily d
	LEFT JOIN marketcloud_bronze.bronze_ams_hourly a ON a.campaign_id = d.campaign_id
	GROUP BY d.campaign_name
), ams_target AS (
	SELECT d.campaign_name,
	       COUNT(t.*) AS target_rows,
	       COUNT(DISTINCT COALESCE(NULLIF(t.keyword_id,''), NULLIF(t.target_id,''), NULLIF(t.keyword_text,''), NULLIF(t.targeting,''))) AS target_entities,
	       SUM(COALESCE(t.impressions,0))::float8 AS target_impressions,
	       SUM(COALESCE(t.clicks,0))::float8 AS target_clicks,
	       SUM(COALESCE(t.spend,0))::float8 AS target_spend,
	       MAX(t.updated_at) AS last_target_update
	FROM latest_daily d
	LEFT JOIN marketcloud_bronze.bronze_ams_hourly_target t ON t.campaign_id = d.campaign_id
	GROUP BY d.campaign_name
), inv AS (
	SELECT campaign_name,
	       COUNT(*) AS structure_rows,
	       COUNT(DISTINCT ad_group_id) AS ad_groups,
	       COUNT(*) FILTER (WHERE entity_type ILIKE '%keyword%') AS keywords,
	       COUNT(*) FILTER (WHERE entity_type ILIKE '%target%') AS targets,
	       COUNT(*) FILTER (WHERE COALESCE(is_negative,false)) AS negatives,
	       MIN(bid)::float8 AS min_bid,
	       MAX(bid)::float8 AS max_bid,
	       MAX(last_sync_at) AS last_structure_sync
	FROM swarm_src.amazon_ads_targeting_inventory
	WHERE campaign_name IN (SELECT campaign_name FROM watched)
	GROUP BY campaign_name
)
SELECT w.label, w.campaign_name, w.console_campaign_id, w.console_url,
       COALESCE(ld.campaign_id, d.campaign_id) AS campaign_id,
       ld.campaign_status, ld.targeting_type, ld.budget_amount, ld.budget_type,
       ld.bidding_strategy, ld.top_of_search_bid_adjustment,
       d.first_daily_date, d.last_daily_date, COALESCE(d.daily_rows,0) AS daily_rows,
       COALESCE(d.daily_impressions,0) AS daily_impressions,
       COALESCE(d.daily_clicks,0) AS daily_clicks,
       COALESCE(d.daily_spend,0) AS daily_spend,
       COALESCE(d.daily_orders,0) AS daily_orders,
       COALESCE(d.daily_sales,0) AS daily_sales,
       d.last_daily_sync, ld.structure_synced_at,
       COALESCE(r.hourly_rows,0) AS hourly_rows,
       r.first_hourly_date, r.last_hourly_date,
       COALESCE(r.hourly_impressions,0) AS hourly_impressions,
       COALESCE(r.hourly_clicks,0) AS hourly_clicks,
       COALESCE(r.hourly_spend,0) AS hourly_spend,
       COALESCE(r.hourly_orders,0) AS hourly_orders,
       COALESCE(r.hourly_sales,0) AS hourly_sales,
       r.last_hourly_ingest,
       COALESCE(a.ams_rows,0) AS ams_rows,
       a.last_ams_hour,
       COALESCE(a.ams_impressions,0) AS ams_impressions,
       COALESCE(a.ams_clicks,0) AS ams_clicks,
       COALESCE(a.ams_spend,0) AS ams_spend,
       COALESCE(a.ams_orders,0) AS ams_orders,
       COALESCE(a.ams_sales,0) AS ams_sales,
       a.last_ams_update,
       COALESCE(at.target_rows,0) AS target_rows,
       COALESCE(at.target_entities,0) AS target_entities,
       COALESCE(at.target_impressions,0) AS target_impressions,
       COALESCE(at.target_clicks,0) AS target_clicks,
       COALESCE(at.target_spend,0) AS target_spend,
       at.last_target_update,
       COALESCE(i.structure_rows,0) AS structure_rows,
       COALESCE(i.ad_groups,0) AS ad_groups,
       COALESCE(i.keywords,0) AS keywords,
       COALESCE(i.targets,0) AS targets,
       COALESCE(i.negatives,0) AS negatives,
       i.min_bid, i.max_bid, i.last_structure_sync
FROM watched w
LEFT JOIN daily d ON d.campaign_name = w.campaign_name
LEFT JOIN latest_daily ld ON ld.campaign_name = w.campaign_name
LEFT JOIN reporting r ON r.campaign_name = w.campaign_name
LEFT JOIN ams a ON a.campaign_name = w.campaign_name
LEFT JOIN ams_target at ON at.campaign_name = w.campaign_name
LEFT JOIN inv i ON i.campaign_name = w.campaign_name
ORDER BY w.label`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "partner_summary_failed: "+err.Error())
		return
	}

	hourly, err := h.collectRows(ctx, partnerCampaignsCTE+`
, ids AS (
	SELECT DISTINCT campaign_id, campaign_name
	FROM swarm_src.amazon_ads_campaigns_daily
	WHERE campaign_name IN (SELECT campaign_name FROM watched)
), reporting AS (
	SELECT 'reporting' AS source, NULL::text AS campaign_id, h.campaign_name,
	       h.data_date, h.event_hour,
	       h.impressions::float8 AS impressions, h.clicks::float8 AS clicks,
	       h.spend::float8 AS spend, COALESCE(h.orders_7d,0)::float8 AS orders,
	       COALESCE(h.sales_7d,0)::float8 AS sales, h.ingested_at AS updated_at
	FROM marketcloud_bronze.bronze_amazon_ads_hourly h
	WHERE h.campaign_name IN (SELECT campaign_name FROM watched)
), ams AS (
	SELECT 'ams' AS source, a.campaign_id, ids.campaign_name,
	       a.data_date, a.event_hour,
	       a.impressions::float8 AS impressions, a.clicks::float8 AS clicks,
	       a.spend::float8 AS spend,
	       GREATEST(COALESCE(a.orders_14d,0), COALESCE(a.orders_7d,0), COALESCE(a.orders_1d,0))::float8 AS orders,
	       GREATEST(COALESCE(a.sales_14d,0), COALESCE(a.sales_7d,0), COALESCE(a.sales_1d,0))::float8 AS sales,
	       a.updated_at
	FROM marketcloud_bronze.bronze_ams_hourly a
	JOIN ids ON ids.campaign_id = a.campaign_id
)
SELECT * FROM (
	SELECT * FROM reporting
	UNION ALL
	SELECT * FROM ams
) x
ORDER BY data_date DESC, event_hour DESC, campaign_name, source
LIMIT 96`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "partner_hourly_failed: "+err.Error())
		return
	}

	targets, err := h.collectRows(ctx, partnerCampaignsCTE+`
, ids AS (
	SELECT DISTINCT campaign_id, campaign_name
	FROM swarm_src.amazon_ads_campaigns_daily
	WHERE campaign_name IN (SELECT campaign_name FROM watched)
)
SELECT ids.campaign_name, t.campaign_id, t.ad_group_id, t.keyword_id, t.target_id,
       COALESCE(NULLIF(t.keyword_text,''), NULLIF(t.targeting,''), '<sem texto>') AS target_text,
       t.match_type, t.data_date, t.event_hour,
       t.impressions::float8 AS impressions, t.clicks::float8 AS clicks,
       t.spend::float8 AS spend,
       GREATEST(COALESCE(t.orders_14d,0), COALESCE(t.orders_7d,0), COALESCE(t.orders_1d,0))::float8 AS orders,
       GREATEST(COALESCE(t.sales_14d,0), COALESCE(t.sales_7d,0), COALESCE(t.sales_1d,0))::float8 AS sales,
       t.updated_at
FROM marketcloud_bronze.bronze_ams_hourly_target t
JOIN ids ON ids.campaign_id = t.campaign_id
ORDER BY t.data_date DESC, t.event_hour DESC, ids.campaign_name, target_text
LIMIT 120`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "partner_targets_failed: "+err.Error())
		return
	}

	structure, err := h.collectRows(ctx, partnerCampaignsCTE+`
SELECT campaign_name, campaign_id, campaign_status, ad_group_id, ad_group_name,
       ad_group_status, entity_type, entity_id, keyword_id, target_id,
       COALESCE(NULLIF(keyword_text,''), NULLIF(target_expression,''), NULLIF(resolved_expression,''), '<sem texto>') AS entity_text,
       match_type, bid::float8 AS bid, bid_source, state, serving_status,
       is_negative, source_api, last_sync_at, updated_at
FROM swarm_src.amazon_ads_targeting_inventory
WHERE campaign_name IN (SELECT campaign_name FROM watched)
ORDER BY campaign_name, ad_group_name, entity_type, entity_text
LIMIT 200`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "partner_structure_failed: "+err.Error())
		return
	}

	changes, err := h.collectRows(ctx, partnerCampaignsCTE+`
, ranked AS (
	SELECT campaign_name, campaign_id, date, campaign_status, targeting_type,
	       budget_amount::float8 AS budget_amount, budget_type, bidding_strategy,
	       top_of_search_bid_adjustment::float8 AS top_of_search_bid_adjustment,
	       structure_synced_at, synced_at,
	       LAG(campaign_status) OVER (PARTITION BY campaign_name ORDER BY date, synced_at) AS prev_campaign_status,
	       LAG(budget_amount::float8) OVER (PARTITION BY campaign_name ORDER BY date, synced_at) AS prev_budget_amount,
	       LAG(bidding_strategy) OVER (PARTITION BY campaign_name ORDER BY date, synced_at) AS prev_bidding_strategy,
	       LAG(top_of_search_bid_adjustment::float8) OVER (PARTITION BY campaign_name ORDER BY date, synced_at) AS prev_top_of_search_bid_adjustment
	FROM swarm_src.amazon_ads_campaigns_daily
	WHERE campaign_name IN (SELECT campaign_name FROM watched)
)
SELECT campaign_name, campaign_id, date, synced_at,
       campaign_status, prev_campaign_status,
       budget_amount, prev_budget_amount,
       bidding_strategy, prev_bidding_strategy,
       top_of_search_bid_adjustment, prev_top_of_search_bid_adjustment,
       CASE
         WHEN prev_campaign_status IS NULL THEN 'CREATED_OR_FIRST_SNAPSHOT'
         WHEN campaign_status IS DISTINCT FROM prev_campaign_status
           OR budget_amount IS DISTINCT FROM prev_budget_amount
           OR bidding_strategy IS DISTINCT FROM prev_bidding_strategy
           OR top_of_search_bid_adjustment IS DISTINCT FROM prev_top_of_search_bid_adjustment
         THEN 'CONFIG_CHANGED'
         ELSE 'NO_CONFIG_CHANGE'
       END AS change_type
FROM ranked
ORDER BY date DESC, synced_at DESC NULLS LAST, campaign_name
LIMIT 80`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "partner_changes_failed: "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"summary":   summary,
		"hourly":    hourly,
		"targets":   targets,
		"structure": structure,
		"changes":   changes,
	})
}

func (h *Handler) collectRows(ctx context.Context, sql string, args ...any) ([]map[string]any, error) {
	rows, err := h.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToMap)
}
