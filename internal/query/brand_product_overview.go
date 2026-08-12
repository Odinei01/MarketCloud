package query

import (
	"net/http"
	"strconv"

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

// GoldBrandMatrix (§90): matriz de produtos da marca — 1 linha por ASIN, pra comparar
// share/lift/CVR/queries de relance e achar melhor produto / maior oportunidade.
func (h *Handler) GoldBrandMatrix(w http.ResponseWriter, r *http.Request) {
	rows, err := h.db.Query(r.Context(), `
		SELECT DISTINCT ON (asin)
		       asin, period_start,
		       queries_count::float8, active_queries::float8, queries_with_purchase::float8,
		       search_impressions::float8, search_clicks::float8, search_purchases::float8,
		       weighted_impression_share::float8, weighted_click_share::float8,
		       weighted_cart_share::float8, weighted_purchase_share::float8,
		       search_ctr::float8, search_conversion::float8,
		       CASE WHEN weighted_impression_share > 0
		            THEN weighted_purchase_share / NULLIF(weighted_impression_share,0) END::float8 AS purchase_share_lift,
		       top_query_by_purchase
		FROM marketcloud_gold.gold_brand_product_weekly_v1
		ORDER BY asin, period_start DESC`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "brand_matrix_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

// GoldMarketSearch (§43): visao de mercado por termo — frequencia, top1/2/3, concentracao
// e classe. Independe de a ZANOM vender (fundacao do Product Discovery). Dedup: 1 linha
// por termo (periodo mais recente). Filtro opcional por classe de concentracao.
func (h *Handler) GoldMarketSearch(w http.ResponseWriter, r *http.Request) {
	limit := 200
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 1000 {
			limit = n
		}
	}
	cls := r.URL.Query().Get("class")
	rows, err := h.db.Query(r.Context(), `
		SELECT * FROM (
			SELECT DISTINCT ON (search_query)
			       search_query, period_start,
			       search_frequency_rank::float8 AS search_frequency_rank,
			       top1_asin, top1_click_share::float8 AS top1_click_share, top1_conversion_share::float8 AS top1_conversion_share,
			       top2_asin, top3_asin,
			       top3_click_concentration::float8 AS top3_click_concentration, top3_conversion_concentration::float8 AS top3_conversion_concentration,
			       market_concentration_class, rank_change_wow::float8 AS rank_change_wow
			FROM marketcloud_gold.gold_market_search_weekly_v1
			WHERE ($1 = '' OR market_concentration_class = $1)
			ORDER BY search_query, period_start DESC
		) x
		ORDER BY search_frequency_rank ASC NULLS LAST
		LIMIT `+strconv.Itoa(limit), cls)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "market_search_failed: "+err.Error())
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
