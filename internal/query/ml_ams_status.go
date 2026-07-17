package query

import (
	"net/http"

	"github.com/jackc/pgx/v5"
	"github.com/zanom/marketcloud/internal/middleware"
)

// GET /api/v1/gold/ml-ams-status
// Status operacional: o que o AMS entregou por hora e o que os workers ML rodaram.
func (h *Handler) GoldMLAmsStatus(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	tenantID := middleware.TenantIDFromCtx(ctx).String()

	modelRows, err := h.db.Query(ctx, `
		SELECT model_name, model_version, model_type, target_name, status,
		       training_rows, metrics_json, created_at
		FROM marketcloud_features.model_registry
		WHERE model_name IN (
			'HourlyConversionRealV2', 'HourlyExpectedRoasRealV2',
			'HourlyTargetClickRealV3', 'HourlyTargetConversionRealV3', 'HourlyTargetExpectedRoasRealV3'
		)
		ORDER BY model_version, model_name`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "model_status_failed: "+err.Error())
		return
	}
	models, err := pgx.CollectRows(modelRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "model_status_scan_failed: "+err.Error())
		return
	}

	runRows, err := h.db.Query(ctx, `
		SELECT id, run_kind, model_version, grain, status,
		       training_rows, positive_click_rows, positive_order_rows,
		       predictions_written, metrics_json, started_at, finished_at
		FROM marketcloud_gold.ml_hourly_run_status
		ORDER BY finished_at DESC
		LIMIT 24`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ml_runs_failed: "+err.Error())
		return
	}
	runs, err := pgx.CollectRows(runRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ml_runs_scan_failed: "+err.Error())
		return
	}

	amsRows, err := h.db.Query(ctx, `
		SELECT data_date, event_hour,
		       campaign_rows, target_rows, target_entities,
		       campaign_impressions::float8 AS campaign_impressions,
		       campaign_clicks::float8 AS campaign_clicks,
		       campaign_spend::float8 AS campaign_spend,
		       campaign_orders::float8 AS campaign_orders,
		       campaign_sales::float8 AS campaign_sales,
		       target_impressions::float8 AS target_impressions,
		       target_clicks::float8 AS target_clicks,
		       target_spend::float8 AS target_spend,
		       target_orders::float8 AS target_orders,
		       target_sales::float8 AS target_sales,
		       last_update
		FROM marketcloud_gold.v_ams_hourly_status_v1
		ORDER BY data_date DESC, event_hour DESC
		LIMIT 36`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ams_status_failed: "+err.Error())
		return
	}
	ams, err := pgx.CollectRows(amsRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ams_status_scan_failed: "+err.Error())
		return
	}

	var totals map[string]any
	err = h.db.QueryRow(ctx, `
		WITH campaign AS (
			SELECT
				COUNT(*) AS rows,
				COUNT(*) FILTER (
					WHERE COALESCE(impressions,0) > 0
					   OR COALESCE(clicks,0) > 0
					   OR COALESCE(spend,0) > 0
				) AS traffic_rows,
				COUNT(*) FILTER (
					WHERE conversion_msg_time IS NOT NULL
					   OR last_conversion_at IS NOT NULL
					   OR COALESCE(orders_1d,0) > 0
					   OR COALESCE(orders_7d,0) > 0
					   OR COALESCE(orders_14d,0) > 0
					   OR COALESCE(sales_1d,0) > 0
					   OR COALESCE(sales_7d,0) > 0
					   OR COALESCE(sales_14d,0) > 0
				) AS conversion_rows,
				COALESCE(SUM(orders_1d),0)::float8 AS orders_1d,
				COALESCE(SUM(orders_7d),0)::float8 AS orders_7d,
				COALESCE(SUM(orders_14d),0)::float8 AS orders_14d,
				COALESCE(SUM(sales_1d),0)::float8 AS sales_1d,
				COALESCE(SUM(sales_7d),0)::float8 AS sales_7d,
				COALESCE(SUM(sales_14d),0)::float8 AS sales_14d,
				MAX(updated_at) AS last_update,
				MAX(traffic_msg_time) AS last_traffic_msg_time,
				MAX(conversion_msg_time) AS last_conversion_msg_time,
				MAX(last_conversion_at) AS last_conversion_at
			FROM marketcloud_bronze.bronze_ams_hourly
		), target AS (
			SELECT
				COUNT(*) AS rows,
				COUNT(*) FILTER (
					WHERE COALESCE(impressions,0) > 0
					   OR COALESCE(clicks,0) > 0
					   OR COALESCE(spend,0) > 0
				) AS traffic_rows,
				COUNT(*) FILTER (
					WHERE conversion_msg_time IS NOT NULL
					   OR last_conversion_at IS NOT NULL
					   OR COALESCE(orders_1d,0) > 0
					   OR COALESCE(orders_7d,0) > 0
					   OR COALESCE(orders_14d,0) > 0
					   OR COALESCE(sales_1d,0) > 0
					   OR COALESCE(sales_7d,0) > 0
					   OR COALESCE(sales_14d,0) > 0
				) AS conversion_rows,
				COALESCE(SUM(orders_1d),0)::float8 AS orders_1d,
				COALESCE(SUM(orders_7d),0)::float8 AS orders_7d,
				COALESCE(SUM(orders_14d),0)::float8 AS orders_14d,
				COALESCE(SUM(sales_1d),0)::float8 AS sales_1d,
				COALESCE(SUM(sales_7d),0)::float8 AS sales_7d,
				COALESCE(SUM(sales_14d),0)::float8 AS sales_14d,
				MAX(updated_at) AS last_update,
				MAX(traffic_msg_time) AS last_traffic_msg_time,
				MAX(conversion_msg_time) AS last_conversion_msg_time,
				MAX(last_conversion_at) AS last_conversion_at
			FROM marketcloud_bronze.bronze_ams_hourly_target
		), predictions AS (
			SELECT
				COUNT(*) AS target_predictions,
				COUNT(*) FILTER (WHERE click_probability IS NOT NULL) AS target_predictions_with_click_probability
			FROM marketcloud_gold.hourly_target_ml_predictions_v3
		), recs AS (
			SELECT COUNT(*) AS keyword_recommendations_with_target_ml
			FROM marketcloud_gold.gold_keyword_hourly_recommendations_v2
			WHERE target_ml_click_probability IS NOT NULL
		), latest_ml AS (
			SELECT
				MAX(finished_at) AS last_ml_run,
				MAX(finished_at) FILTER (WHERE run_kind = 'hourly_target_real_v3') AS last_target_ml_run,
				MAX(finished_at) FILTER (WHERE run_kind = 'hourly_real_v2') AS last_campaign_ml_run
			FROM marketcloud_gold.ml_hourly_run_status
		)
		SELECT jsonb_build_object(
			'campaign_rows', campaign.rows,
			'campaign_traffic_rows', campaign.traffic_rows,
			'campaign_conversion_rows', campaign.conversion_rows,
			'ams_orders_1d', campaign.orders_1d,
			'ams_orders_7d', campaign.orders_7d,
			'ams_orders_14d', campaign.orders_14d,
			'ams_sales_1d', campaign.sales_1d,
			'ams_sales_7d', campaign.sales_7d,
			'ams_sales_14d', campaign.sales_14d,
			'target_rows', target.rows,
			'target_traffic_rows', target.traffic_rows,
			'target_conversion_rows', target.conversion_rows,
			'target_orders_1d', target.orders_1d,
			'target_orders_7d', target.orders_7d,
			'target_orders_14d', target.orders_14d,
			'target_sales_1d', target.sales_1d,
			'target_sales_7d', target.sales_7d,
			'target_sales_14d', target.sales_14d,
			'target_predictions', predictions.target_predictions,
			'target_predictions_with_click_probability', predictions.target_predictions_with_click_probability,
			'keyword_recommendations_with_target_ml', recs.keyword_recommendations_with_target_ml,
			'last_ams_update', campaign.last_update,
			'last_target_update', target.last_update,
			'last_traffic_msg_time', GREATEST(campaign.last_traffic_msg_time, target.last_traffic_msg_time),
			'last_conversion_msg_time', GREATEST(campaign.last_conversion_msg_time, target.last_conversion_msg_time),
			'last_conversion_at', GREATEST(campaign.last_conversion_at, target.last_conversion_at),
			'last_ml_run', latest_ml.last_ml_run,
			'last_target_ml_run', latest_ml.last_target_ml_run,
			'last_campaign_ml_run', latest_ml.last_campaign_ml_run
		)::jsonb
		FROM campaign, target, predictions, recs, latest_ml`).Scan(&totals)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "status_totals_failed: "+err.Error())
		return
	}

	learningRows, err := h.db.Query(ctx, `
		SELECT recommendation_id, campaign_id, campaign_name, ad_group_name, event_hour,
		       recommended_action, recommended_bid_multiplier,
		       decided_action, decided_bid_multiplier, executed_at,
		       outcome_window, action_start_at, eval_window_end,
		       baseline_roas::float8 AS baseline_roas,
		       eval_roas::float8 AS eval_roas,
		       delta_roas::float8 AS delta_roas,
		       baseline_spend::float8 AS baseline_spend,
		       eval_spend::float8 AS eval_spend,
		       delta_spend::float8 AS delta_spend,
		       baseline_orders::float8 AS baseline_orders,
		       eval_orders::float8 AS eval_orders,
		       delta_orders::float8 AS delta_orders,
		       outcome_label, model_verdict, measured_at
		FROM marketcloud_recommendations.v_learning_loop_hourly_v1
		ORDER BY measured_at DESC, executed_at DESC, recommendation_id, outcome_window
		LIMIT 36`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "learning_outcomes_failed: "+err.Error())
		return
	}
	learning, err := pgx.CollectRows(learningRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "learning_outcomes_scan_failed: "+err.Error())
		return
	}

	var auditSummary map[string]any
	err = h.db.QueryRow(ctx, `
		SELECT jsonb_build_object(
			'total', COUNT(*),
			'pending', COUNT(*) FILTER (WHERE audit_result = 'PENDING_MEASUREMENT'),
			'winning', COUNT(*) FILTER (WHERE audit_result = 'WINNING'),
			'losing', COUNT(*) FILTER (WHERE audit_result = 'LOSING'),
			'neutral', COUNT(*) FILTER (WHERE audit_result = 'NEUTRAL'),
			'model_right', COUNT(*) FILTER (WHERE model_result = 'MODEL_RIGHT'),
			'model_wrong', COUNT(*) FILTER (WHERE model_result = 'MODEL_WRONG'),
			'last_executed_at', MAX(executed_at),
			'last_measured_at', MAX(last_measured_at)
		)::jsonb
		FROM marketcloud_recommendations.v_auto_apply_audit_360_v1
		WHERE tenant_id = $1`, tenantID).Scan(&auditSummary)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "audit_360_summary_failed: "+err.Error())
		return
	}

	auditRows, err := h.db.Query(ctx, `
		SELECT recommendation_id, campaign_id, campaign_name, ad_group_name, event_hour,
		       recommended_action, recommended_bid_multiplier::float8 AS recommended_bid_multiplier,
		       decided_action, decided_bid_multiplier::float8 AS decided_bid_multiplier,
		       decided_by, decision_notes, executed_at,
		       priority_score::float8 AS priority_score,
		       priority_bucket, final_risk_level,
		       audit_result, model_result, measured_windows,
		       action_start_at_1h, eval_window_end_1h,
		       baseline_roas_1h::float8 AS baseline_roas_1h,
		       eval_roas_1h::float8 AS eval_roas_1h,
		       delta_roas_1h::float8 AS delta_roas_1h,
		       outcome_label_1h, model_verdict_1h,
		       action_start_at_3h, eval_window_end_3h,
		       baseline_roas_3h::float8 AS baseline_roas_3h,
		       eval_roas_3h::float8 AS eval_roas_3h,
		       delta_roas_3h::float8 AS delta_roas_3h,
		       outcome_label_3h, model_verdict_3h,
		       action_start_at_24h, eval_window_end_24h,
		       baseline_roas_24h::float8 AS baseline_roas_24h,
		       eval_roas_24h::float8 AS eval_roas_24h,
		       delta_roas_24h::float8 AS delta_roas_24h,
		       outcome_label_24h, model_verdict_24h,
		       last_measured_at
		FROM marketcloud_recommendations.v_auto_apply_audit_360_v1
		WHERE tenant_id = $1
		ORDER BY executed_at DESC NULLS LAST, recommendation_id
		LIMIT 40`, tenantID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "audit_360_failed: "+err.Error())
		return
	}
	audit360, err := pgx.CollectRows(auditRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "audit_360_scan_failed: "+err.Error())
		return
	}

	var fc360Summary map[string]any
	err = h.db.QueryRow(ctx, `
		SELECT jsonb_build_object(
			'total', COUNT(*),
			'aplicar', COUNT(*) FILTER (WHERE operator_decision IN ('APLICAR','APLICAR_SEGURANCA')),
			'testar', COUNT(*) FILTER (WHERE operator_decision = 'TESTAR_CONTROLADO'),
			'aguardar', COUNT(*) FILTER (WHERE operator_decision = 'AGUARDAR_DADOS'),
			'bloquear', COUNT(*) FILTER (WHERE operator_decision = 'BLOQUEAR'),
			'pending_execution', COUNT(*) FILTER (WHERE audit_result = 'PENDING_EXECUTION'),
			'pending_measurement', COUNT(*) FILTER (WHERE audit_result = 'PENDING_MEASUREMENT'),
			'winning', COUNT(*) FILTER (WHERE audit_result = 'WINNING'),
			'losing', COUNT(*) FILTER (WHERE audit_result = 'LOSING'),
			'last_computed_at', MAX(computed_at),
			'last_measured_at', MAX(last_measured_at)
		)::jsonb
		FROM marketcloud_recommendations.v_ml_full_control_360_audit_v1`).Scan(&fc360Summary)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_360_summary_failed: "+err.Error())
		return
	}

	fc360Rows, err := h.db.Query(ctx, `
		SELECT recommendation_id, campaign_id, campaign_name, event_hour,
		       action_type, action_scope,
		       current_value::float8 AS current_value,
		       recommended_value::float8 AS recommended_value,
		       expected_roas::float8 AS expected_roas,
		       conversion_probability::float8 AS conversion_probability,
		       confidence, priority_score::float8 AS priority_score,
		       guardrail_status, reason, evidence_json,
		       expected_delta_spend::float8 AS expected_delta_spend,
		       expected_delta_sales::float8 AS expected_delta_sales,
		       expected_delta_roas::float8 AS expected_delta_roas,
		       decision_class, execution_strategy, min_roas_used::float8 AS min_roas_used,
		       data_sufficiency, operator_note, operator_decision, operator_reason,
		       decision, execution_status, executed_at, decided_at,
		       measured_windows,
		       outcome_label_1h, delta_roas_1h::float8 AS delta_roas_1h,
		       outcome_label_3h, delta_roas_3h::float8 AS delta_roas_3h,
		       outcome_label_24h, delta_roas_24h::float8 AS delta_roas_24h,
		       audit_result, last_measured_at, computed_at
		FROM marketcloud_recommendations.v_ml_full_control_360_audit_v1
		ORDER BY priority_score DESC NULLS LAST, computed_at DESC
		LIMIT 50`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_360_actions_failed: "+err.Error())
		return
	}
	fc360, err := pgx.CollectRows(fc360Rows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "full_control_360_actions_scan_failed: "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"totals":                   totals,
		"models":                   models,
		"ml_runs":                  runs,
		"ams_hours":                ams,
		"learning_outcomes":        learning,
		"audit_360_summary":        auditSummary,
		"audit_360":                audit360,
		"full_control_360_summary": fc360Summary,
		"full_control_360":         fc360,
	})
}
