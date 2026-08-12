package query

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
)

// Fase 5 da spec ZANOM MARKETCLOUD: dashboard de produto da marca (§36-39). Le os gold
// novos (gold_brand_product_weekly = funil agregado + weighted shares; gold_brand_query_
// weekly = portfolio de query com share lift/price index/funnel_label/signal_strength).
// Read-only, sem inventar metrica (mostra so o que o E001 traz).

// GoldBrandOverview: lista os produtos de marca (1 por ASIN, periodo mais recente).
func (h *Handler) GoldBrandOverview(w http.ResponseWriter, r *http.Request) {
	rows, err := h.db.Query(r.Context(), `
		SELECT DISTINCT ON (asin)
		       asin, period_start, period_end,
		       queries_count::float8, active_queries::float8,
		       queries_with_purchase::float8,
		       search_impressions::float8, search_clicks::float8, search_cart_adds::float8, search_purchases::float8,
		       weighted_impression_share::float8, weighted_click_share::float8,
		       weighted_cart_share::float8, weighted_purchase_share::float8,
		       search_ctr::float8, search_conversion::float8,
		       top_query_by_volume, top_query_by_purchase
		FROM marketcloud_gold.gold_brand_product_weekly_v1
		ORDER BY asin, period_start DESC`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "brand_overview_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

// GoldBrandOverviewProduct: um ASIN — funil agregado + portfolio de query (labels/lift/idx).
func (h *Handler) GoldBrandOverviewProduct(w http.ResponseWriter, r *http.Request) {
	asin := chi.URLParam(r, "asin")
	if asin == "" {
		writeError(w, http.StatusBadRequest, "asin_required")
		return
	}
	var product map[string]any
	err := h.db.QueryRow(r.Context(), `
		SELECT to_jsonb(p) FROM (
			SELECT asin, period_start, period_end,
			       queries_count, active_queries, queries_with_click, queries_with_purchase,
			       search_impressions, search_clicks, search_cart_adds, search_purchases,
			       weighted_impression_share, weighted_click_share, weighted_cart_share, weighted_purchase_share,
			       search_ctr, search_conversion, top_query_by_volume, top_query_by_purchase
			FROM marketcloud_gold.gold_brand_product_weekly_v1
			WHERE upper(trim(asin)) = upper(trim($1))
			ORDER BY period_start DESC LIMIT 1
		) p`, asin).Scan(&product)
	if err != nil {
		product = map[string]any{}
	}
	rows, err := h.db.Query(r.Context(), `
		SELECT search_query,
		       search_query_volume::float8, search_query_score::float8,
		       brand_impressions::float8, brand_clicks::float8, brand_cart_adds::float8, brand_purchases::float8,
		       market_impressions::float8, market_purchases::float8,
		       brand_impression_share::float8, brand_click_share::float8, brand_purchase_share::float8,
		       click_share_lift::float8, purchase_share_lift::float8,
		       click_price_index::float8, purchase_price_index::float8,
		       brand_search_conversion::float8,
		       signal_strength, funnel_label
		FROM marketcloud_gold.gold_brand_query_weekly_v1
		WHERE upper(trim(asin)) = upper(trim($1))
		ORDER BY brand_purchases DESC NULLS LAST, brand_clicks DESC NULLS LAST, search_query_volume DESC NULLS LAST
		LIMIT 300`, asin)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "brand_overview_product_failed: "+err.Error())
		return
	}
	queries, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"asin": asin, "product": product, "queries": queries, "count": len(queries)})
}
