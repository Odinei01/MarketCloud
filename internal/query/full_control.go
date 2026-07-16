package query

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/zanom/marketcloud/internal/middleware"
)

type fullControlPilotRequest struct {
	ProductASIN             string  `json:"product_asin"`
	SellerSKU               string  `json:"seller_sku"`
	ProductTitle            string  `json:"product_title"`
	CampaignID              string  `json:"campaign_id"`
	CampaignName            string  `json:"campaign_name"`
	Mode                    string  `json:"mode"`
	Status                  string  `json:"status"`
	SalePriceBRL            float64 `json:"sale_price_brl"`
	UnitCostBRL             float64 `json:"unit_cost_brl"`
	StockAvailable          float64 `json:"stock_available"`
	MaxDailyBudgetBRL       float64 `json:"max_daily_budget_brl"`
	MaxSpendWithoutOrderBRL float64 `json:"max_spend_without_order_brl"`
	MinROAS                 float64 `json:"min_roas"`
	MaxACOS                 float64 `json:"max_acos"`
	Notes                   string  `json:"notes"`
}

// GET /api/v1/settings/full-control-products
func (h *Handler) FullControlProducts(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	rows, err := h.db.Query(r.Context(), `
		SELECT product_asin, seller_sku, product_title, last_seen_date,
		       impressions_30d::float8 AS impressions_30d,
		       clicks_30d::float8 AS clicks_30d,
		       spend_30d::float8 AS spend_30d,
		       orders_30d::float8 AS orders_30d,
		       sales_30d::float8 AS sales_30d,
		       units_30d::float8 AS units_30d,
		       roas_30d::float8 AS roas_30d,
		       sale_price_brl::float8 AS sale_price_brl,
		       unit_cost_brl::float8 AS unit_cost_brl,
		       unit_cost_source,
		       stock_local_available::float8 AS stock_local_available,
		       stock_fba_available::float8 AS stock_fba_available,
		       stock_available::float8 AS stock_available,
		       stock_source,
		       stock_updated_at,
		       gross_margin_brl::float8 AS gross_margin_brl,
		       gross_margin_pct::float8 AS gross_margin_pct,
		       campaign_count,
		       campaigns,
		       has_unit_cost, has_stock, economics_ready
		FROM marketcloud_gold.full_control_product_candidates_v1
		WHERE tenant_id = $1
		ORDER BY spend_30d DESC NULLS LAST, product_asin
		LIMIT 200`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_products_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_products_scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

// PUT /api/v1/settings/full-control-pilot
func (h *Handler) SetFullControlPilot(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	userID := middleware.UserIDFromCtx(r.Context()).String()

	var body fullControlPilotRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	body.ProductASIN = strings.TrimSpace(body.ProductASIN)
	body.SellerSKU = strings.TrimSpace(body.SellerSKU)
	body.ProductTitle = strings.TrimSpace(body.ProductTitle)
	body.CampaignID = strings.TrimSpace(body.CampaignID)
	body.CampaignName = strings.TrimSpace(body.CampaignName)
	body.Mode = strings.TrimSpace(body.Mode)
	body.Status = strings.TrimSpace(body.Status)
	if body.Mode == "" {
		body.Mode = "monitor_only"
	}
	if body.Status == "" {
		body.Status = "draft"
	}
	if body.ProductASIN == "" || body.CampaignID == "" || body.CampaignName == "" {
		writeError(w, http.StatusBadRequest, "product_asin_campaign_required")
		return
	}
	if !validFullControlMode(body.Mode) || !validFullControlStatus(body.Status) {
		writeError(w, http.StatusBadRequest, "invalid_full_control_mode_or_status")
		return
	}
	if body.SalePriceBRL < 0 || body.UnitCostBRL < 0 || body.StockAvailable < 0 ||
		body.MaxDailyBudgetBRL < 0 || body.MaxSpendWithoutOrderBRL < 0 ||
		body.MinROAS < 0 || body.MaxACOS < 0 {
		writeError(w, http.StatusBadRequest, "invalid_full_control_economic_value")
		return
	}
	if body.MinROAS == 0 {
		body.MinROAS = 4
	}

	var saved map[string]any
	err := h.db.QueryRow(r.Context(), `
		WITH values_in AS (
			SELECT
				$1::text AS tenant_id,
				$2::text AS product_asin,
				NULLIF($3::text,'') AS seller_sku,
				NULLIF($4::text,'') AS product_title,
				$5::text AS campaign_id,
				$6::text AS campaign_name,
				$7::text AS mode,
				$8::text AS status,
				NULLIF($9::float8, 0)::numeric AS sale_price_brl,
				NULLIF($10::float8, 0)::numeric AS unit_cost_brl,
				NULLIF($11::float8, 0)::numeric AS stock_available,
				$12::float8::numeric AS max_daily_budget_brl,
				$13::float8::numeric AS max_spend_without_order_brl,
				$14::float8::numeric AS min_roas,
				NULLIF($15::float8, 0)::numeric AS max_acos,
				NULLIF($16::text,'') AS notes,
				NULLIF($17::text,'') AS user_id
		), upserted AS (
			INSERT INTO marketcloud_control.full_control_pilots (
				tenant_id, product_asin, seller_sku, product_title, campaign_id, campaign_name,
				mode, status, sale_price_brl, unit_cost_brl, stock_available,
				gross_margin_brl, gross_margin_pct,
				max_daily_budget_brl, max_spend_without_order_brl, min_roas, max_acos,
				notes, created_by, updated_by, updated_at
			)
			SELECT
				tenant_id, product_asin, seller_sku, product_title, campaign_id, campaign_name,
				mode, status, sale_price_brl, unit_cost_brl, stock_available,
				CASE WHEN sale_price_brl IS NOT NULL AND unit_cost_brl IS NOT NULL THEN sale_price_brl - unit_cost_brl END,
				CASE WHEN sale_price_brl > 0 AND unit_cost_brl IS NOT NULL THEN (sale_price_brl - unit_cost_brl) / sale_price_brl END,
				max_daily_budget_brl, max_spend_without_order_brl, min_roas, max_acos,
				notes, user_id, user_id, NOW()
			FROM values_in
			ON CONFLICT (tenant_id, product_asin, campaign_id) DO UPDATE SET
				seller_sku=EXCLUDED.seller_sku,
				product_title=EXCLUDED.product_title,
				campaign_name=EXCLUDED.campaign_name,
				mode=EXCLUDED.mode,
				status=EXCLUDED.status,
				sale_price_brl=EXCLUDED.sale_price_brl,
				unit_cost_brl=EXCLUDED.unit_cost_brl,
				stock_available=EXCLUDED.stock_available,
				gross_margin_brl=EXCLUDED.gross_margin_brl,
				gross_margin_pct=EXCLUDED.gross_margin_pct,
				max_daily_budget_brl=EXCLUDED.max_daily_budget_brl,
				max_spend_without_order_brl=EXCLUDED.max_spend_without_order_brl,
				min_roas=EXCLUDED.min_roas,
				max_acos=EXCLUDED.max_acos,
				notes=EXCLUDED.notes,
				updated_by=EXCLUDED.updated_by,
				updated_at=NOW()
			RETURNING *
		)
		SELECT to_jsonb(upserted.*)::jsonb FROM upserted`,
		tenantID, body.ProductASIN, body.SellerSKU, body.ProductTitle, body.CampaignID,
		body.CampaignName, body.Mode, body.Status, body.SalePriceBRL, body.UnitCostBRL,
		body.StockAvailable, body.MaxDailyBudgetBRL, body.MaxSpendWithoutOrderBRL,
		body.MinROAS, body.MaxACOS, strings.TrimSpace(body.Notes), userID).Scan(&saved)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_pilot_save_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, saved)
}

// GET /api/v1/settings/full-control-governance
func (h *Handler) FullControlGovernance(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	rows, err := h.db.Query(r.Context(), `
		SELECT pilot_id, product_asin, seller_sku, product_title,
		       campaign_id, campaign_name, mode, status,
		       sale_price_brl::float8 AS sale_price_brl,
		       unit_cost_brl::float8 AS unit_cost_brl,
		       stock_available::float8 AS stock_available,
		       gross_margin_brl::float8 AS gross_margin_brl,
		       gross_margin_pct::float8 AS gross_margin_pct,
		       stock_local_available::float8 AS stock_local_available,
		       stock_fba_available::float8 AS stock_fba_available,
		       stock_source,
		       stock_updated_at,
		       unit_cost_source,
		       max_daily_budget_brl::float8 AS max_daily_budget_brl,
		       max_spend_without_order_brl::float8 AS max_spend_without_order_brl,
		       min_roas::float8 AS min_roas,
		       max_acos::float8 AS max_acos,
		       spend_today::float8 AS spend_today,
		       orders_today::float8 AS orders_today,
		       sales_today::float8 AS sales_today,
		       roas_today::float8 AS roas_today,
		       current_budget_brl::float8 AS current_budget_brl,
		       budget_type, campaign_status,
		       economics_ready, can_control, gate_reason,
		       last_report_date, last_ams_update, updated_at
		FROM marketcloud_gold.full_control_effective_governance_v1
		WHERE tenant_id = $1
		ORDER BY can_control DESC, updated_at DESC, campaign_name`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_governance_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_governance_scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

func validFullControlMode(mode string) bool {
	return mode == "monitor_only" || mode == "semi_auto" || mode == "full_control"
}

func validFullControlStatus(status string) bool {
	return status == "draft" || status == "active" || status == "paused" || status == "completed" || status == "archived"
}
