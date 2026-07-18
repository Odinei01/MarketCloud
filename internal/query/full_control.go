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
	MaxTopOfSearchPct       float64 `json:"max_top_of_search_pct"`
	MaxProductPagePct       float64 `json:"max_product_page_pct"`
	MaxRestOfSearchPct      float64 `json:"max_rest_of_search_pct"`
	StrategyConfig          any     `json:"strategy_config"`
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
		body.MinROAS < 0 || body.MaxACOS < 0 ||
		body.MaxTopOfSearchPct < 0 || body.MaxProductPagePct < 0 || body.MaxRestOfSearchPct < 0 {
		writeError(w, http.StatusBadRequest, "invalid_full_control_economic_value")
		return
	}
	if body.MaxTopOfSearchPct > 900 || body.MaxProductPagePct > 900 || body.MaxRestOfSearchPct > 900 {
		writeError(w, http.StatusBadRequest, "invalid_full_control_placement_limit")
		return
	}
	if body.MinROAS == 0 {
		body.MinROAS = 4
	}
	strategyJSON, err := json.Marshal(body.StrategyConfig)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_strategy_config")
		return
	}

	var saved map[string]any
	err = h.db.QueryRow(r.Context(), `
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
				$16::float8::numeric AS max_top_of_search_pct,
				$17::float8::numeric AS max_product_page_pct,
				$18::float8::numeric AS max_rest_of_search_pct,
				COALESCE(NULLIF($19::text,'')::jsonb, '{}'::jsonb) AS strategy_config,
				NULLIF($20::text,'') AS notes,
				NULLIF($21::text,'') AS user_id
		), upserted AS (
			INSERT INTO marketcloud_control.full_control_pilots (
				tenant_id, product_asin, seller_sku, product_title, campaign_id, campaign_name,
				mode, status, sale_price_brl, unit_cost_brl, stock_available,
				gross_margin_brl, gross_margin_pct,
				max_daily_budget_brl, max_spend_without_order_brl, min_roas, max_acos,
				max_top_of_search_pct, max_product_page_pct, max_rest_of_search_pct, strategy_config,
				notes, created_by, updated_by, updated_at
			)
			SELECT
				tenant_id, product_asin, seller_sku, product_title, campaign_id, campaign_name,
				mode, status, sale_price_brl, unit_cost_brl, stock_available,
				CASE WHEN sale_price_brl IS NOT NULL AND unit_cost_brl IS NOT NULL THEN sale_price_brl - unit_cost_brl END,
				CASE WHEN sale_price_brl > 0 AND unit_cost_brl IS NOT NULL THEN (sale_price_brl - unit_cost_brl) / sale_price_brl END,
				max_daily_budget_brl, max_spend_without_order_brl, min_roas, max_acos,
				max_top_of_search_pct, max_product_page_pct, max_rest_of_search_pct, strategy_config,
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
				max_top_of_search_pct=EXCLUDED.max_top_of_search_pct,
				max_product_page_pct=EXCLUDED.max_product_page_pct,
				max_rest_of_search_pct=EXCLUDED.max_rest_of_search_pct,
				strategy_config=EXCLUDED.strategy_config,
				notes=EXCLUDED.notes,
				updated_by=EXCLUDED.updated_by,
				updated_at=NOW()
			RETURNING *
		)
		SELECT to_jsonb(upserted.*)::jsonb FROM upserted`,
		tenantID, body.ProductASIN, body.SellerSKU, body.ProductTitle, body.CampaignID,
		body.CampaignName, body.Mode, body.Status, body.SalePriceBRL, body.UnitCostBRL,
		body.StockAvailable, body.MaxDailyBudgetBRL, body.MaxSpendWithoutOrderBRL,
		body.MinROAS, body.MaxACOS, body.MaxTopOfSearchPct, body.MaxProductPagePct,
		body.MaxRestOfSearchPct, string(strategyJSON), strings.TrimSpace(body.Notes), userID).Scan(&saved)
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
		       max_top_of_search_pct::float8 AS max_top_of_search_pct,
		       max_product_page_pct::float8 AS max_product_page_pct,
		       max_rest_of_search_pct::float8 AS max_rest_of_search_pct,
		       strategy_config,
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

// GET /api/v1/settings/full-control-monitoring
func (h *Handler) FullControlMonitoring(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()

	pilotRows, err := h.db.Query(r.Context(), `
		SELECT pilot_id, product_asin, seller_sku, product_title,
		       campaign_id, campaign_name, mode, status,
		       sale_price_brl::float8 AS sale_price_brl,
		       unit_cost_brl::float8 AS unit_cost_brl,
		       stock_available::float8 AS stock_available,
		       max_daily_budget_brl::float8 AS max_daily_budget_brl,
		       max_spend_without_order_brl::float8 AS max_spend_without_order_brl,
		       min_roas::float8 AS min_roas,
		       max_top_of_search_pct::float8 AS max_top_of_search_pct,
		       max_product_page_pct::float8 AS max_product_page_pct,
		       max_rest_of_search_pct::float8 AS max_rest_of_search_pct,
		       spend_today::float8 AS spend_today,
		       orders_today::float8 AS orders_today,
		       sales_today::float8 AS sales_today,
		       roas_today::float8 AS roas_today,
		       current_budget_brl::float8 AS current_budget_brl,
		       can_control, gate_reason,
		       last_ams_update, updated_at
		FROM marketcloud_gold.full_control_effective_governance_v1
		WHERE tenant_id = $1
		  AND status IN ('active','paused','draft')
		ORDER BY
		  CASE status WHEN 'active' THEN 0 WHEN 'paused' THEN 1 ELSE 2 END,
		  updated_at DESC,
		  campaign_name`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_monitoring_pilots_failed: "+err.Error())
		return
	}
	pilots, err := pgx.CollectRows(pilotRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_monitoring_pilots_scan_failed: "+err.Error())
		return
	}

	actionRows, err := h.db.Query(r.Context(), `
		WITH pilots AS (
			SELECT DISTINCT campaign_id, lower(trim(campaign_name)) AS campaign_norm
			FROM marketcloud_gold.full_control_effective_governance_v1
			WHERE tenant_id = $1
			  AND status IN ('active','paused','draft')
		)
		SELECT a.recommendation_id,
		       a.campaign_id,
		       a.campaign_name,
		       a.ad_group_name,
		       a.event_hour,
		       a.recommended_action,
		       a.recommended_bid_multiplier::float8 AS recommended_bid_multiplier,
		       a.decided_action,
		       a.decided_bid_multiplier::float8 AS decided_bid_multiplier,
		       a.decided_by,
		       a.execution_status,
		       a.executed_at,
		       a.priority_score::float8 AS priority_score,
		       a.priority_bucket,
		       a.audit_result,
		       a.model_result,
		       a.measured_windows,
		       a.outcome_label_1h,
		       a.delta_roas_1h::float8 AS delta_roas_1h,
		       a.outcome_label_3h,
		       a.delta_roas_3h::float8 AS delta_roas_3h,
		       a.outcome_label_24h,
		       a.delta_roas_24h::float8 AS delta_roas_24h,
		       a.last_measured_at
		FROM marketcloud_recommendations.v_auto_apply_audit_360_v1 a
		JOIN pilots p
		  ON (a.campaign_id IS NOT NULL AND a.campaign_id = p.campaign_id)
		  OR (a.campaign_id IS NULL AND lower(trim(a.campaign_name)) = p.campaign_norm)
		WHERE a.tenant_id = $1
		ORDER BY a.executed_at DESC NULLS LAST, a.last_measured_at DESC NULLS LAST
		LIMIT 80`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_monitoring_actions_failed: "+err.Error())
		return
	}
	actions, err := pgx.CollectRows(actionRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_monitoring_actions_scan_failed: "+err.Error())
		return
	}

	proposalRows, err := h.db.Query(r.Context(), `
		WITH pilots AS (
			SELECT DISTINCT campaign_id, lower(trim(campaign_name)) AS campaign_norm
			FROM marketcloud_gold.full_control_effective_governance_v1
			WHERE tenant_id = $1
			  AND status IN ('active','paused','draft')
		)
		SELECT a.recommendation_id,
		       a.campaign_id,
		       a.campaign_name,
		       a.event_hour,
		       a.action_type,
		       a.current_value::float8 AS current_value,
		       a.recommended_value::float8 AS recommended_value,
		       a.expected_roas::float8 AS expected_roas,
		       a.conversion_probability::float8 AS conversion_probability,
		       a.expected_delta_spend::float8 AS expected_delta_spend,
		       a.expected_delta_sales::float8 AS expected_delta_sales,
		       a.expected_delta_roas::float8 AS expected_delta_roas,
		       a.confidence,
		       a.priority_score::float8 AS priority_score,
		       a.guardrail_status,
		       a.decision_class,
		       a.execution_strategy,
		       a.data_sufficiency,
		       a.operator_decision,
		       a.operator_reason,
		       a.audit_result,
		       a.execution_status,
		       a.computed_at
		FROM marketcloud_recommendations.v_ml_full_control_360_audit_v1 a
		JOIN pilots p
		  ON (a.campaign_id IS NOT NULL AND a.campaign_id = p.campaign_id)
		  OR (a.campaign_id IS NULL AND lower(trim(a.campaign_name)) = p.campaign_norm)
		ORDER BY a.priority_score DESC NULLS LAST, a.computed_at DESC
		LIMIT 80`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_monitoring_proposals_failed: "+err.Error())
		return
	}
	proposals, err := pgx.CollectRows(proposalRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_monitoring_proposals_scan_failed: "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"pilots":         pilots,
		"actions":        actions,
		"proposed_360":   proposals,
		"pilot_count":    len(pilots),
		"action_count":   len(actions),
		"proposal_count": len(proposals),
	})
}

func validFullControlMode(mode string) bool {
	return mode == "monitor_only" || mode == "semi_auto" || mode == "full_control"
}

func validFullControlStatus(status string) bool {
	return status == "draft" || status == "active" || status == "paused" || status == "completed" || status == "archived"
}

// GET /api/v1/settings/full-control-keywords?campaign_id=
// Keywords selecionadas para Full Control (escopo por keyword).
func (h *Handler) FullControlKeywords(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	campaignID := strings.TrimSpace(r.URL.Query().Get("campaign_id"))
	if campaignID == "" {
		writeError(w, http.StatusBadRequest, "campaign_id_required")
		return
	}
	rows, err := h.db.Query(r.Context(), `
		SELECT id, campaign_id, COALESCE(ad_group_id,'') AS ad_group_id, COALESCE(keyword_id,'') AS keyword_id,
		       keyword_text, COALESCE(match_type,'') AS match_type, enabled, updated_at
		FROM marketcloud_control.full_control_keywords
		WHERE tenant_id=$1 AND campaign_id=$2
		ORDER BY enabled DESC, keyword_text`, tenantID, campaignID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "fc_keywords_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "fc_keywords_scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

// PUT /api/v1/settings/full-control-keyword — adiciona/atualiza uma keyword no escopo.
func (h *Handler) SetFullControlKeyword(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	userID := middleware.UserIDFromCtx(r.Context()).String()
	var b struct {
		CampaignID  string `json:"campaign_id"`
		AdGroupID   string `json:"ad_group_id"`
		KeywordID   string `json:"keyword_id"`
		KeywordText string `json:"keyword_text"`
		MatchType   string `json:"match_type"`
		Enabled     *bool  `json:"enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if strings.TrimSpace(b.CampaignID) == "" || strings.TrimSpace(b.KeywordText) == "" {
		writeError(w, http.StatusBadRequest, "campaign_id_keyword_required")
		return
	}
	enabled := true
	if b.Enabled != nil {
		enabled = *b.Enabled
	}
	_, err := h.db.Exec(r.Context(), `
		INSERT INTO marketcloud_control.full_control_keywords
			(tenant_id, campaign_id, ad_group_id, keyword_id, keyword_text, match_type, enabled, created_by)
		VALUES ($1,$2,NULLIF($3,''),NULLIF($4,''),$5,NULLIF($6,''),$7,$8)
		ON CONFLICT (tenant_id, campaign_id, lower(trim(keyword_text)), lower(trim(COALESCE(match_type,''))))
		DO UPDATE SET enabled=EXCLUDED.enabled, ad_group_id=EXCLUDED.ad_group_id,
			keyword_id=EXCLUDED.keyword_id, updated_at=NOW()`,
		tenantID, b.CampaignID, b.AdGroupID, b.KeywordID, b.KeywordText, b.MatchType, enabled, userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "fc_keyword_save_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "campaign_id": b.CampaignID, "keyword_text": b.KeywordText, "enabled": enabled})
}

// GET /api/v1/settings/full-control-monitor — monitor das campanhas liberadas.
func (h *Handler) FullControlMonitor(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	rows, err := h.db.Query(r.Context(), `
		SELECT campaign_id, campaign_name, product_asin, can_control, gate_reason,
		       spend_today::float8 AS spend_today, orders_today::float8 AS orders_today, roas_today::float8 AS roas_today,
		       stock_available::float8 AS stock_available, max_daily_budget_brl::float8 AS max_daily_budget_brl,
		       max_spend_without_order_brl::float8 AS max_spend_without_order_brl, min_roas::float8 AS min_roas,
		       escopo_keyword, keywords_selecionadas, propostas_360, propostas_a_aplicar,
		       propostas_bloqueadas, propostas_aguardando, acoes_360_executadas
		FROM marketcloud_gold.v_full_control_monitoring_v1
		WHERE tenant_id=$1
		ORDER BY propostas_a_aplicar DESC, campaign_name`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "fc_monitor_failed: "+err.Error())
		return
	}
	items, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "fc_monitor_scan_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}
