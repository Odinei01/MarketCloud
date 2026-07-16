package query

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/zanom/marketcloud/internal/middleware"
)

// GET /api/v1/gold/ml-full-auto-campaigns
// Lists campaign candidates and whether each one is allowed to run the full
// recommend -> apply -> monitor -> learn loop.
func (h *Handler) GoldMLFullAutoCampaigns(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	rows, err := h.db.Query(r.Context(), `
		WITH recommendation_campaigns AS (
			SELECT
				lower(trim(campaign_name)) AS campaign_norm,
				MAX(campaign_name) AS campaign_name,
				COUNT(*) AS recommendation_rows,
				MAX(priority_score)::float8 AS max_priority_score,
				MAX(computed_at) AS last_recommendation_at
			FROM marketcloud_gold.gold_hourly_recommendations_v1
			WHERE campaign_name IS NOT NULL
			GROUP BY lower(trim(campaign_name))
		), campaign_ids AS (
			SELECT lower(trim(campaign_name)) AS campaign_norm, MAX(campaign_id) AS campaign_id, MAX(campaign_name) AS campaign_name
			FROM (
				SELECT campaign_id, campaign_name
				FROM marketcloud_bronze.v_ams_hourly_resolved
				WHERE campaign_name IS NOT NULL AND campaign_id IS NOT NULL
				UNION ALL
				SELECT campaign_id, campaign_name
				FROM marketcloud_bronze.bronze_swarm_current_bids
				WHERE campaign_name IS NOT NULL AND campaign_id IS NOT NULL
				  AND COALESCE(upper(campaign_status), '') NOT IN ('ARCHIVED', 'DELETED')
				UNION ALL
				SELECT campaign_id, campaign_name
				FROM marketcloud_bronze.bronze_swarm_bid_schedule
				WHERE campaign_name IS NOT NULL AND campaign_id IS NOT NULL
				  AND COALESCE(upper(campaign_status), '') NOT IN ('ARCHIVED', 'DELETED')
			) src
			GROUP BY lower(trim(campaign_name))
		), campaign_flags AS (
			SELECT lower(trim(campaign_name)) AS campaign_norm, MAX(campaign_id) AS campaign_id, MAX(campaign_name) AS campaign_name
			FROM marketcloud_control.ml_full_auto_campaign_flags
			WHERE tenant_id = $1
			GROUP BY lower(trim(campaign_name))
		), campaign_names AS (
			SELECT campaign_norm FROM recommendation_campaigns
			UNION
			SELECT campaign_norm FROM campaign_ids
			UNION
			SELECT campaign_norm FROM campaign_flags
		), campaigns AS (
			SELECT
				COALESCE(ids.campaign_id, flags.campaign_id, '') AS campaign_id,
				COALESCE(rc.campaign_name, ids.campaign_name, flags.campaign_name) AS campaign_name,
				COALESCE(rc.recommendation_rows, 0) AS recommendation_rows,
				COALESCE(rc.max_priority_score, 0)::float8 AS max_priority_score,
				rc.last_recommendation_at
			FROM campaign_names names
			LEFT JOIN recommendation_campaigns rc ON rc.campaign_norm = names.campaign_norm
			LEFT JOIN campaign_ids ids ON ids.campaign_norm = names.campaign_norm
			LEFT JOIN campaign_flags flags ON flags.campaign_norm = names.campaign_norm
		)
		SELECT
			NULLIF(c.campaign_id, '') AS campaign_id,
			c.campaign_name,
			c.recommendation_rows,
			c.max_priority_score,
			c.last_recommendation_at,
			COALESCE(f.enabled, FALSE) AS full_auto_enabled,
			COALESCE(f.automation_mode, CASE WHEN COALESCE(f.enabled, FALSE) THEN 'full_auto' ELSE 'advisor' END) AS automation_mode,
			COALESCE(g.can_auto_apply, FALSE) AS can_auto_apply,
			g.tenant_mode,
			f.notes,
			f.updated_at AS flag_updated_at
		FROM campaigns c
		LEFT JOIN marketcloud_control.ml_full_auto_campaign_flags f
		  ON f.tenant_id = $1
		 AND lower(trim(f.campaign_name)) = lower(trim(c.campaign_name))
		LEFT JOIN marketcloud_gold.gold_campaign_automation_governance g
		  ON g.tenant_id = $1
		 AND lower(trim(g.campaign_name)) = lower(trim(c.campaign_name))
		WHERE c.campaign_name IS NOT NULL
		ORDER BY COALESCE(f.enabled, FALSE) DESC, c.max_priority_score DESC NULLS LAST, c.campaign_name`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ml_full_auto_list_failed: "+err.Error())
		return
	}
	defer rows.Close()

	items := []map[string]any{}
	for rows.Next() {
		var campaignID *string
		var campaignName string
		var notes *string
		var recommendationRows int
		var maxPriority any
		var lastRecommendation any
		var enabled bool
		var automationMode string
		var canAutoApply bool
		var tenantMode *string
		var flagUpdated any
		if err := rows.Scan(&campaignID, &campaignName, &recommendationRows, &maxPriority, &lastRecommendation, &enabled, &automationMode, &canAutoApply, &tenantMode, &notes, &flagUpdated); err != nil {
			writeError(w, http.StatusInternalServerError, "ml_full_auto_scan_failed: "+err.Error())
			return
		}
		items = append(items, map[string]any{
			"campaign_id":            campaignID,
			"campaign_name":          campaignName,
			"recommendation_rows":    recommendationRows,
			"max_priority_score":     maxPriority,
			"last_recommendation_at": lastRecommendation,
			"full_auto_enabled":      enabled,
			"automation_mode":        automationMode,
			"can_auto_apply":         canAutoApply,
			"tenant_mode":            valueOrEmpty(tenantMode),
			"notes":                  notes,
			"flag_updated_at":        flagUpdated,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

// PUT /api/v1/gold/ml-full-auto-campaigns
// Body: { campaign_id?, campaign_name, enabled?, automation_mode?, notes? }
func (h *Handler) GoldSetMLFullAutoCampaign(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.TenantIDFromCtx(r.Context()).String()
	var body struct {
		CampaignID     string `json:"campaign_id"`
		CampaignName   string `json:"campaign_name"`
		Enabled        bool   `json:"enabled"`
		AutomationMode string `json:"automation_mode"`
		Notes          string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	body.CampaignID = strings.TrimSpace(body.CampaignID)
	body.CampaignName = strings.TrimSpace(body.CampaignName)
	if body.CampaignName == "" {
		writeError(w, http.StatusBadRequest, "campaign_name_required")
		return
	}
	body.AutomationMode = strings.TrimSpace(body.AutomationMode)
	if body.AutomationMode == "" {
		if body.Enabled {
			body.AutomationMode = "full_auto"
		} else {
			body.AutomationMode = "advisor"
		}
	}
	if !validAutomationMode(body.AutomationMode) {
		writeError(w, http.StatusBadRequest, "invalid_automation_mode")
		return
	}
	body.Enabled = body.AutomationMode == "full_auto"
	_, err := h.db.Exec(r.Context(), `
		INSERT INTO marketcloud_control.ml_full_auto_campaign_flags (
			tenant_id, campaign_id, campaign_name, enabled, automation_mode, notes, updated_at
		) VALUES ($1, NULLIF($2,''), $3, $4, $5, NULLIF($6,''), NOW())
		ON CONFLICT (tenant_id, campaign_name) DO UPDATE SET
			campaign_id = COALESCE(NULLIF(EXCLUDED.campaign_id,''), marketcloud_control.ml_full_auto_campaign_flags.campaign_id),
			enabled = EXCLUDED.enabled,
			automation_mode = EXCLUDED.automation_mode,
			notes = EXCLUDED.notes,
			updated_at = NOW()`,
		tenantID, body.CampaignID, body.CampaignName, body.Enabled, body.AutomationMode, body.Notes)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ml_full_auto_save_failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":          "ok",
		"campaign_id":     body.CampaignID,
		"campaign_name":   body.CampaignName,
		"enabled":         body.Enabled,
		"automation_mode": body.AutomationMode,
	})
}
