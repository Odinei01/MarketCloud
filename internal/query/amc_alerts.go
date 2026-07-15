package query

import (
	"net/http"

	"github.com/jackc/pgx/v5"
)

// GET /api/v1/gold/amc-alerts
// Alertas automáticos do retargeting SD (reativar/escalar/matar) — o sistema
// avisa sem o dono rodar query. Lê a view de regras gold_amc_retargeting_alerts.
func (h *Handler) GoldAMCAlerts(w http.ResponseWriter, r *http.Request) {
	sql := `
		SELECT sd_campaign, product_key,
		       engaged_users::int      AS engaged_users,
		       buyers::int             AS buyers,
		       conversion_rate::float8 AS conversion_rate,
		       lift_vs_baseline::float8 AS lift_vs_baseline,
		       product_revenue::float8 AS product_revenue,
		       verdict, alerta, priority::int AS priority
		FROM marketcloud_gold.gold_amc_retargeting_alerts
		ORDER BY priority, product_revenue DESC`
	rows, err := h.db.Query(r.Context(), sql)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}
