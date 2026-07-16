package query

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/zanom/marketcloud/internal/middleware"
)

type tenantSettingsRequest struct {
	OperationalMode  string  `json:"operational_mode"`
	MinROAS          float64 `json:"min_roas"`
	MLAggressiveness float64 `json:"ml_aggressiveness"`
	RiskBudgetBRL    float64 `json:"risk_budget_brl"`
	ProtectedHours   []int   `json:"protected_hours"`
	TelegramChatID   string  `json:"telegram_chat_id"`
	Notes            string  `json:"notes"`
}

// GET /api/v1/settings/tenant
func (h *Handler) TenantSettings(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	settings, err := h.loadTenantSettings(r.Context(), tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "tenant_settings_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, settings)
}

// PUT /api/v1/settings/tenant
func (h *Handler) SetTenantSettings(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	userID := middleware.UserIDFromCtx(r.Context()).String()
	var body tenantSettingsRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	body.OperationalMode = strings.TrimSpace(body.OperationalMode)
	if body.OperationalMode == "" {
		body.OperationalMode = "advisor"
	}
	if !validAutomationMode(body.OperationalMode) {
		writeError(w, http.StatusBadRequest, "invalid_operational_mode")
		return
	}
	if body.MinROAS < 0 || body.MLAggressiveness < 0 || body.MLAggressiveness > 1 || body.RiskBudgetBRL < 0 {
		writeError(w, http.StatusBadRequest, "invalid_guardrail_value")
		return
	}
	for _, hour := range body.ProtectedHours {
		if hour < 0 || hour > 23 {
			writeError(w, http.StatusBadRequest, "invalid_protected_hour")
			return
		}
	}
	hoursCSV := joinInts(body.ProtectedHours)
	_, err := h.db.Exec(r.Context(), `
		INSERT INTO marketcloud_control.tenant_settings (
			tenant_id, operational_mode, min_roas, ml_aggressiveness,
			risk_budget_brl, protected_hours, telegram_chat_id, notes,
			updated_by, updated_at
		) VALUES (
			$1, $2, $3, $4, $5,
			CASE WHEN $6 = '' THEN '{}'::int[] ELSE string_to_array($6, ',')::int[] END,
			NULLIF($7,''), NULLIF($8,''), NULLIF($9,''), NOW()
		)
		ON CONFLICT (tenant_id) DO UPDATE SET
			operational_mode=EXCLUDED.operational_mode,
			min_roas=EXCLUDED.min_roas,
			ml_aggressiveness=EXCLUDED.ml_aggressiveness,
			risk_budget_brl=EXCLUDED.risk_budget_brl,
			protected_hours=EXCLUDED.protected_hours,
			telegram_chat_id=EXCLUDED.telegram_chat_id,
			notes=EXCLUDED.notes,
			updated_by=EXCLUDED.updated_by,
			updated_at=NOW()`,
		tenantID, body.OperationalMode, body.MinROAS, body.MLAggressiveness,
		body.RiskBudgetBRL, hoursCSV, strings.TrimSpace(body.TelegramChatID),
		strings.TrimSpace(body.Notes), userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "tenant_settings_save_failed: "+err.Error())
		return
	}
	settings, err := h.loadTenantSettings(r.Context(), tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "tenant_settings_reload_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, settings)
}

// GET /api/v1/settings/health
func (h *Handler) TenantHealth(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	tenantID := middleware.TenantIDFromCtx(ctx).String()

	type row struct {
		Key       string
		Label     string
		Status    string
		Detail    string
		UpdatedAt any
	}
	items := []map[string]any{}
	add := func(key, label, status, detail string, updated any) {
		items = append(items, map[string]any{
			"key":        key,
			"label":      label,
			"status":     status,
			"detail":     detail,
			"updated_at": updated,
		})
	}

	var adsProfiles int
	var lastProfile any
	_ = h.db.QueryRow(ctx, `
		SELECT COUNT(*), MAX(updated_at)
		FROM amazon_ads_profiles
		WHERE tenant_id = $1`, tenantID).Scan(&adsProfiles, &lastProfile)
	if adsProfiles > 0 {
		add("ads_profile", "Amazon Ads profile", "ok", strconv.Itoa(adsProfiles)+" profile(s) cadastrados", lastProfile)
	} else {
		add("ads_profile", "Amazon Ads profile", "error", "Nenhum profile Amazon Ads cadastrado", nil)
	}

	var currentBids, campaignIDs int
	var lastSwarm any
	_ = h.db.QueryRow(ctx, `
		SELECT COUNT(*), COUNT(*) FILTER (WHERE COALESCE(campaign_id,'') <> ''), MAX(ingested_at)
		FROM marketcloud_bronze.bronze_swarm_current_bids`).Scan(&currentBids, &campaignIDs, &lastSwarm)
	if currentBids > 0 && campaignIDs == currentBids {
		add("swarm_sync", "Sync campanhas/bids", "ok", strconv.Itoa(currentBids)+" entidades com ID", lastSwarm)
	} else if currentBids > 0 {
		add("swarm_sync", "Sync campanhas/bids", "warn", strconv.Itoa(campaignIDs)+"/"+strconv.Itoa(currentBids)+" entidades com ID", lastSwarm)
	} else {
		add("swarm_sync", "Sync campanhas/bids", "error", "Sem snapshot de bids/campanhas", nil)
	}

	var amsRows, amsTraffic, amsConversions int
	var lastAMS any
	_ = h.db.QueryRow(ctx, `
		SELECT COUNT(*),
		       COUNT(*) FILTER (WHERE COALESCE(impressions,0) > 0 OR COALESCE(clicks,0) > 0 OR COALESCE(spend,0) > 0),
		       COUNT(*) FILTER (WHERE COALESCE(orders_7d,0) > 0 OR COALESCE(sales_7d,0) > 0),
		       MAX(updated_at)
		FROM marketcloud_bronze.bronze_ams_hourly`).Scan(&amsRows, &amsTraffic, &amsConversions, &lastAMS)
	if amsTraffic > 0 {
		add("ams_traffic", "AMS trafego", "ok", strconv.Itoa(amsTraffic)+" linhas com trafego", lastAMS)
	} else if amsRows > 0 {
		add("ams_traffic", "AMS trafego", "warn", "AMS recebeu linhas, mas sem trafego positivo", lastAMS)
	} else {
		add("ams_traffic", "AMS trafego", "error", "Nenhuma linha AMS recebida", nil)
	}
	if amsConversions > 0 {
		add("ams_conversion", "AMS conversao", "ok", strconv.Itoa(amsConversions)+" linhas com venda/pedido", lastAMS)
	} else {
		add("ams_conversion", "AMS conversao", "warn", "Sem conversao atribuida no AMS campanha", lastAMS)
	}

	var latestMLStatus, latestMLKind string
	var latestML any
	_ = h.db.QueryRow(ctx, `
		SELECT COALESCE(run_kind,''), COALESCE(status,''), finished_at
		FROM marketcloud_gold.ml_hourly_run_status
		ORDER BY finished_at DESC
		LIMIT 1`).Scan(&latestMLKind, &latestMLStatus, &latestML)
	if latestMLStatus == "COMPLETED" {
		add("ml_run", "ML horario", "ok", latestMLKind+" COMPLETED", latestML)
	} else if latestMLStatus != "" {
		add("ml_run", "ML horario", "warn", latestMLKind+" "+latestMLStatus, latestML)
	} else {
		add("ml_run", "ML horario", "error", "Nenhuma execucao ML encontrada", nil)
	}

	var enabled, canApply, noHoldout int
	_ = h.db.QueryRow(ctx, `
		SELECT COUNT(*) FILTER (WHERE campaign_mode = 'full_auto'),
		       COUNT(*) FILTER (WHERE can_auto_apply),
		       COUNT(*) FILTER (WHERE campaign_mode = 'full_auto' AND NOT EXISTS (
		         SELECT 1 FROM marketcloud_control.holdout_cells h
		         WHERE h.campaign_name = g.campaign_name
		       ))
		FROM marketcloud_gold.gold_campaign_automation_governance g
		WHERE tenant_id = $1`, tenantID).Scan(&enabled, &canApply, &noHoldout)
	if enabled == 0 {
		add("auto_apply", "Robo pode aplicar", "warn", "Nenhuma campanha em full-auto", nil)
	} else if noHoldout > 0 {
		add("auto_apply", "Robo pode aplicar", "warn", strconv.Itoa(noHoldout)+" campanha(s) full-auto sem holdout", nil)
	} else if canApply > 0 {
		add("auto_apply", "Robo pode aplicar", "ok", strconv.Itoa(canApply)+" campanha(s) aptas por governanca", nil)
	} else {
		add("auto_apply", "Robo pode aplicar", "warn", "Full-auto ligado, mas teto do seller bloqueia", nil)
	}

	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

func (h *Handler) loadTenantSettings(ctx context.Context, tenantID string) (map[string]any, error) {
	var operationalMode, hoursJSON string
	var minROAS, aggressiveness, riskBudget float64
	var telegramChatID, notes *string
	var updatedAt any
	err := h.db.QueryRow(ctx, `
		WITH ensured AS (
			INSERT INTO marketcloud_control.tenant_settings (tenant_id)
			VALUES ($1)
			ON CONFLICT (tenant_id) DO NOTHING
			RETURNING tenant_id
		)
		SELECT operational_mode, min_roas::float8, ml_aggressiveness::float8,
		       risk_budget_brl::float8, COALESCE(array_to_json(protected_hours)::text,'[]'),
		       telegram_chat_id, notes, updated_at
		FROM marketcloud_control.tenant_settings
		WHERE tenant_id = $1`, tenantID).Scan(
		&operationalMode, &minROAS, &aggressiveness, &riskBudget,
		&hoursJSON, &telegramChatID, &notes, &updatedAt)
	if err != nil {
		return nil, err
	}
	var protectedHours []int
	_ = json.Unmarshal([]byte(hoursJSON), &protectedHours)
	return map[string]any{
		"tenant_id":         tenantID,
		"operational_mode":  operationalMode,
		"min_roas":          minROAS,
		"ml_aggressiveness": aggressiveness,
		"risk_budget_brl":   riskBudget,
		"protected_hours":   protectedHours,
		"telegram_chat_id":  valueOrEmpty(telegramChatID),
		"notes":             valueOrEmpty(notes),
		"updated_at":        updatedAt,
	}, nil
}

func validAutomationMode(mode string) bool {
	return mode == "advisor" || mode == "semi_auto" || mode == "full_auto"
}

func joinInts(values []int) string {
	if len(values) == 0 {
		return ""
	}
	parts := make([]string, 0, len(values))
	for _, value := range values {
		parts = append(parts, strconv.Itoa(value))
	}
	return strings.Join(parts, ",")
}

func valueOrEmpty(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
