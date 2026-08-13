package query

import (
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5"
)

// Radar de Entrega Horaria: responde "meu anuncio sumiu essa hora?" separando
// hora-morta-normal de queda-anormal. Nao inventa "impression share por hora" (Amazon
// nao da); usa a entrega real (impressoes/gasto/cliques por hora) vs o baseline da
// PROPRIA hora. Fonte: bronze_amazon_ads_hourly (horario, fresco).
//
// GET /api/v1/gold/hourly-delivery-radar?days=7&campaign=<opcional>
//   baseline: por hora 0-23, mediana/media de impressoes no trailing 28d (a "hora normal")
//   grid:     ultimos N dias x hora, impressoes/cliques/gasto reais (pra cruzar com baseline)
func (h *Handler) GoldHourlyDeliveryRadar(w http.ResponseWriter, r *http.Request) {
	days := 7
	if v := r.URL.Query().Get("days"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 && n <= 30 {
			days = n
		}
	}
	campaign := r.URL.Query().Get("campaign") // vazio = conta inteira

	// baseline por hora: mediana das impressoes/dia daquela hora no trailing 28d (so dias
	// que a hora entregou algo, p/ nao afundar a mediana com dias sem sync).
	baseRows, err := h.db.Query(r.Context(), `
		WITH per_day_hour AS (
			SELECT data_date, event_hour,
			       sum(impressions) AS impr, sum(clicks) AS clk, sum(spend) AS spend
			FROM marketcloud_bronze.bronze_amazon_ads_hourly
			WHERE data_date >= CURRENT_DATE - 28
			  AND ($1 = '' OR campaign_name = $1)
			GROUP BY data_date, event_hour
		)
		SELECT event_hour,
		       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY impr))::int AS baseline_impr,
		       round(avg(impr))::int                                        AS avg_impr,
		       round(avg(spend)::numeric,2)                                  AS avg_spend
		FROM per_day_hour
		WHERE impr > 0
		GROUP BY event_hour
		ORDER BY event_hour`, campaign)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "radar_baseline_failed: "+err.Error())
		return
	}
	baseline, err := pgx.CollectRows(baseRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	gridRows, err := h.db.Query(r.Context(), `
		SELECT data_date::text AS data_date, event_hour,
		       sum(impressions)::int AS impressions,
		       sum(clicks)::int      AS clicks,
		       round(sum(spend)::numeric,2) AS spend
		FROM marketcloud_bronze.bronze_amazon_ads_hourly
		WHERE data_date >= CURRENT_DATE - $1::int
		  AND ($2 = '' OR campaign_name = $2)
		GROUP BY data_date, event_hour
		ORDER BY data_date, event_hour`, days, campaign)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "radar_grid_failed: "+err.Error())
		return
	}
	grid, err := pgx.CollectRows(gridRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}

	// lista de campanhas ativas (ENABLED) p/ o filtro do radar
	campRows, err := h.db.Query(r.Context(), `
		WITH latest_status AS (
			SELECT DISTINCT ON (campaign_name) campaign_name, UPPER(TRIM(campaign_status)) AS st
			FROM swarm_src.amazon_ads_campaigns_daily
			WHERE COALESCE(campaign_name,'') <> ''
			ORDER BY campaign_name, date DESC
		)
		SELECT h.campaign_name, sum(h.impressions)::int AS impressions
		FROM marketcloud_bronze.bronze_amazon_ads_hourly h
		JOIN latest_status ls ON ls.campaign_name = h.campaign_name AND ls.st = 'ENABLED'
		WHERE h.data_date >= CURRENT_DATE - 14 AND COALESCE(h.campaign_name,'') <> ''
		GROUP BY h.campaign_name
		HAVING sum(h.impressions) > 0
		ORDER BY impressions DESC`)
	campaigns := []map[string]any{}
	if err == nil {
		campaigns, _ = pgx.CollectRows(campRows, pgx.RowToMap)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"days": days, "campaign": campaign,
		"baseline": baseline, "grid": grid, "campaigns": campaigns,
	})
}
