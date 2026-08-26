package query

import (
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/zanom/marketcloud/internal/middleware"
)

// GET /api/v1/gold/ml-ams-status
// Status operacional: o que o AMS entregou por hora e o que os workers ML rodaram.
func (h *Handler) GoldMLAmsStatus(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	tenantID := middleware.TenantIDFromCtx(ctx).String()
	view := r.URL.Query().Get("view")
	if view == "" {
		view = "overview"
	}

	modelRows, err := h.db.Query(ctx, `
		SELECT model_name, model_version, model_type, target_name, status,
		       training_rows,
		       jsonb_build_object(
		       	'n', metrics_json->'n',
		       	'positives', metrics_json->'positives',
		       	'nonzero', metrics_json->'nonzero',
		       	'roc_auc', metrics_json->'roc_auc',
		       	'roc_auc_clicked_only', metrics_json->'roc_auc_clicked_only',
		       	'roc_auc_cross_campaign', metrics_json->'roc_auc_cross_campaign',
		       	'baseline_hourrate_auc', metrics_json->'baseline_hourrate_auc',
		       	'mae', metrics_json->'mae',
		       	'mae_clicked_only', metrics_json->'mae_clicked_only',
		       	'mae_cross_campaign', metrics_json->'mae_cross_campaign',
		       	'baseline_hourmean_mae', metrics_json->'baseline_hourmean_mae',
		       	'beats_baseline', metrics_json->'beats_baseline'
		       ) AS metrics_json,
		       created_at, last_trained_at
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
		       predictions_written,
		       NULL::jsonb AS metrics_json,
		       started_at, finished_at
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

	if view == "overview" {
		var ls struct {
			Measured, Improved, Worsened, Neutral, NoData int
			NetDeltaSales, NetDeltaSpend                  float64
		}
		_ = h.db.QueryRow(ctx, `
			SELECT
				count(*) FILTER (WHERE outcome_window='24h'),
				count(*) FILTER (WHERE outcome_window='24h' AND outcome_label='IMPROVED'),
				count(*) FILTER (WHERE outcome_window='24h' AND outcome_label='WORSENED'),
				count(*) FILTER (WHERE outcome_window='24h' AND outcome_label='NEUTRAL'),
				count(*) FILTER (WHERE outcome_window='24h' AND outcome_label='NO_DATA'),
				COALESCE(sum(delta_sales) FILTER (WHERE outcome_window='24h'),0),
				COALESCE(sum(delta_spend) FILTER (WHERE outcome_window='24h'),0)
			FROM marketcloud_recommendations.recommendation_hourly_outcomes`).
			Scan(&ls.Measured, &ls.Improved, &ls.Worsened, &ls.Neutral, &ls.NoData, &ls.NetDeltaSales, &ls.NetDeltaSpend)

		conclusive := ls.Improved + ls.Worsened
		sample := "OK"
		verdict := "NEUTRO"
		if conclusive < 20 {
			sample = "PEQUENA"
			verdict = "INCONCLUSIVO"
		} else if ls.Improved > ls.Worsened && ls.NetDeltaSales >= 0 {
			verdict = "POSITIVO"
		} else if ls.Worsened > ls.Improved && ls.NetDeltaSales < 0 {
			verdict = "NEGATIVO"
		}

		trainingVolumeLight := []map[string]any{
			{
				"source":    "campaign_hour_gold",
				"rows":      totals["campaign_rows"],
				"campaigns": nil,
				"targets":   nil,
				"clicks":    nil,
				"orders":    totals["ams_orders_7d"],
				"sales":     totals["ams_sales_7d"],
				"spend":     nil,
			},
			{
				"source":    "target_hour_reconciled",
				"rows":      totals["target_rows"],
				"campaigns": nil,
				"targets":   nil,
				"clicks":    nil,
				"orders":    totals["target_orders_7d"],
				"sales":     totals["target_sales_7d"],
				"spend":     nil,
			},
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"totals":                         totals,
			"models":                         models,
			"ml_runs":                        runs,
			"ams_hours":                      ams,
			"learning_outcomes":              []map[string]any{},
			"learning_summary":               map[string]any{"measured": ls.Measured, "improved": ls.Improved, "worsened": ls.Worsened, "neutral": ls.Neutral, "no_data": ls.NoData, "conclusive": conclusive, "net_delta_sales": ls.NetDeltaSales, "net_delta_spend": ls.NetDeltaSpend, "sample": sample, "verdict": verdict},
			"holdout":                        map[string]any{},
			"audit_360_summary":              map[string]any{},
			"audit_360":                      []map[string]any{},
			"full_control_360_summary":       map[string]any{},
			"full_control_360":               []map[string]any{},
			"ams_quality_summary":            []map[string]any{},
			"ams_quality_divergences":        []map[string]any{},
			"ads_reprocess_requests":         []map[string]any{},
			"ads_reprocess_health":           []map[string]any{},
			"ml_training_volume":             trainingVolumeLight,
			"operational_alerts":             []map[string]any{},
			"ams_target_quality_summary":     []map[string]any{},
			"ams_target_quality_divergences": []map[string]any{},
		})
		return
	}

	if view == "audit" {
		trainingVolumeLight := []map[string]any{
			{
				"source": "campaign_hour_gold",
				"rows":   totals["campaign_rows"],
				"orders": totals["ams_orders_7d"],
				"sales":  totals["ams_sales_7d"],
			},
			{
				"source": "target_hour_reconciled",
				"rows":   totals["target_rows"],
				"orders": totals["target_orders_7d"],
				"sales":  totals["target_sales_7d"],
			},
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"totals":                         totals,
			"models":                         models,
			"ml_runs":                        runs,
			"ams_hours":                      ams,
			"learning_outcomes":              []map[string]any{},
			"learning_summary":               map[string]any{},
			"holdout":                        map[string]any{},
			"audit_360_summary":              map[string]any{},
			"audit_360":                      []map[string]any{},
			"full_control_360_summary":       map[string]any{},
			"full_control_360":               []map[string]any{},
			"ams_quality_summary":            []map[string]any{},
			"ams_quality_divergences":        []map[string]any{},
			"ads_reprocess_requests":         []map[string]any{},
			"ads_reprocess_health":           []map[string]any{},
			"ml_training_volume":             trainingVolumeLight,
			"ams_target_quality_summary":     []map[string]any{},
			"ams_target_quality_divergences": []map[string]any{},
			"operational_alerts":             []map[string]any{},
		})
		return
	}

	if view == "ams" {
		qualityRows, err := h.db.Query(ctx, `
			SELECT data_quality_status, operator_action, rows,
			       min_date, max_date,
			       avg_quality_score::float8 AS avg_quality_score,
			       ams_spend::float8 AS ams_spend,
			       ads_spend::float8 AS ads_spend,
			       delta_ads_spend::float8 AS delta_ads_spend,
			       ams_orders_7d::float8 AS ams_orders_7d,
			       ads_orders::float8 AS ads_orders,
			       delta_ads_orders::float8 AS delta_ads_orders,
			       last_ams_update, last_ads_sync
			FROM marketcloud_gold.v_ams_quality_summary_v1
			ORDER BY
				CASE data_quality_status
					WHEN 'DIVERGENT' THEN 0
					WHEN 'ADS_MISSING' THEN 1
					WHEN 'ATTRIBUTING' THEN 2
					WHEN 'FRESH' THEN 3
					WHEN 'DELTA_ONLY' THEN 4
					WHEN 'MATURE_RECONCILED' THEN 5
					ELSE 6
				END,
				rows DESC`)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "ams_quality_summary_failed: "+err.Error())
			return
		}
		qualitySummary, err := pgx.CollectRows(qualityRows, pgx.RowToMap)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "ams_quality_summary_scan_failed: "+err.Error())
			return
		}

		divRows, err := h.db.Query(ctx, `
			SELECT data_date, maturity_bucket, campaign_id, campaign_name,
			       data_quality_status, data_quality_score, operator_action,
			       ams_spend_clamped::float8 AS ams_spend,
			       ads_spend::float8 AS ads_spend,
			       delta_ads_spend::float8 AS delta_ads_spend,
			       ams_orders_7d::float8 AS ams_orders_7d,
			       ads_orders::float8 AS ads_orders,
			       delta_ads_orders::float8 AS delta_ads_orders,
			       ams_sales_7d::float8 AS ams_sales_7d,
			       ads_sales::float8 AS ads_sales,
			       delta_ads_sales::float8 AS delta_ads_sales,
			       ams_last_update, ads_last_sync
			FROM marketcloud_gold.v_ams_data_quality_score_v1
			WHERE data_quality_status IN ('DIVERGENT','ADS_MISSING','LOW_CONFIDENCE')
			   OR operator_action IN ('REQUEST_ADS_REPORT_REPROCESS','INVESTIGATE_DELTA_AND_REPROCESS_ADS_REPORT')
			ORDER BY data_quality_score ASC, data_date DESC, ABS(delta_ads_spend) DESC NULLS LAST
			LIMIT 30`)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "ams_quality_divergences_failed: "+err.Error())
			return
		}
		qualityDivergences, err := pgx.CollectRows(divRows, pgx.RowToMap)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "ams_quality_divergences_scan_failed: "+err.Error())
			return
		}

		reprocessRows, err := h.db.Query(ctx, `
			SELECT id, source, data_date, window_label, status, reason,
			       requested_at, updated_at, completed_at, error_message
			FROM marketcloud_ops.ads_reporting_reprocess_requests
			ORDER BY data_date DESC, window_label
			LIMIT 30`)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "ads_reprocess_requests_failed: "+err.Error())
			return
		}
		reprocessRequests, err := pgx.CollectRows(reprocessRows, pgx.RowToMap)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "ads_reprocess_requests_scan_failed: "+err.Error())
			return
		}

		reprocessHealthRows, err := h.db.Query(ctx, `
			SELECT id, data_date, window_label, window_status, grain, report_id,
			       rows_ingested, grain_status, updated_at, completed_at, error_message
			FROM (
				WITH recent AS (
					SELECT id, data_date, window_label, status AS window_status,
					       metadata_json, updated_at, completed_at, error_message
					FROM marketcloud_ops.ads_reporting_reprocess_requests
					ORDER BY data_date DESC, window_label
					LIMIT 10
				), campaign AS (
					SELECT data_date, MAX(report_id) AS report_id, COUNT(*)::int AS rows_ingested
					FROM marketcloud_ops.ads_reporting_sp_campaign_daily_v3
					WHERE data_date IN (SELECT data_date FROM recent)
					GROUP BY data_date
				), adgroup AS (
					SELECT data_date, MAX(report_id) AS report_id, COUNT(*)::int AS rows_ingested
					FROM marketcloud_ops.ads_reporting_sp_adgroup_daily_v3
					WHERE data_date IN (SELECT data_date FROM recent)
					GROUP BY data_date
				), keyword AS (
					SELECT data_date, MAX(report_id) AS report_id, COUNT(*)::int AS rows_ingested
					FROM marketcloud_ops.ads_reporting_sp_targeting_daily_v3
					WHERE report_grain = 'KEYWORD'
					  AND data_date IN (SELECT data_date FROM recent)
					GROUP BY data_date
				), target AS (
					SELECT data_date, MAX(report_id) AS report_id, COUNT(*)::int AS rows_ingested
					FROM marketcloud_ops.ads_reporting_sp_targeting_daily_v3
					WHERE report_grain = 'TARGET'
					  AND data_date IN (SELECT data_date FROM recent)
					GROUP BY data_date
				)
				SELECT r.id, r.data_date, r.window_label, r.window_status,
				       r.updated_at, r.completed_at, r.error_message,
				       g.grain,
				       CASE g.grain
				       	WHEN 'CAMPAIGN' THEN COALESCE(r.metadata_json->>'sp_campaign_report_id', campaign.report_id)
				       	WHEN 'AD_GROUP' THEN COALESCE(r.metadata_json->>'sp_adgroup_report_id', adgroup.report_id)
				       	WHEN 'KEYWORD' THEN COALESCE(r.metadata_json->>'sp_keyword_report_id', keyword.report_id)
				       	WHEN 'TARGET' THEN COALESCE(r.metadata_json->>'sp_target_report_id', target.report_id)
				       END AS report_id,
				       CASE g.grain
				       	WHEN 'CAMPAIGN' THEN COALESCE(NULLIF(r.metadata_json->>'sp_campaign_rows_ingested','')::int, campaign.rows_ingested, 0)
				       	WHEN 'AD_GROUP' THEN COALESCE(NULLIF(r.metadata_json->>'sp_adgroup_rows_ingested','')::int, adgroup.rows_ingested, 0)
				       	WHEN 'KEYWORD' THEN COALESCE(NULLIF(r.metadata_json->>'sp_keyword_rows_ingested','')::int, keyword.rows_ingested, 0)
				       	WHEN 'TARGET' THEN COALESCE(NULLIF(r.metadata_json->>'sp_target_rows_ingested','')::int, target.rows_ingested, 0)
				       END AS rows_ingested,
				       CASE g.grain
				       	WHEN 'CAMPAIGN' THEN COALESCE(r.metadata_json->>'campaign_last_poll_status', CASE WHEN campaign.rows_ingested > 0 THEN 'COMPLETED' END, CASE WHEN r.metadata_json ? 'sp_campaign_rows_ingested' THEN 'COMPLETED' END)
				       	WHEN 'AD_GROUP' THEN COALESCE(r.metadata_json->>'adgroup_last_poll_status', CASE WHEN adgroup.rows_ingested > 0 THEN 'COMPLETED' END, CASE WHEN r.metadata_json ? 'sp_adgroup_rows_ingested' THEN 'COMPLETED' END)
				       	WHEN 'KEYWORD' THEN COALESCE(r.metadata_json->>'keyword_last_poll_status', CASE WHEN keyword.rows_ingested > 0 THEN 'COMPLETED' END, CASE WHEN r.metadata_json ? 'sp_keyword_rows_ingested' THEN 'COMPLETED' END)
				       	WHEN 'TARGET' THEN COALESCE(r.metadata_json->>'target_last_poll_status', CASE WHEN target.rows_ingested > 0 THEN 'COMPLETED' END, CASE WHEN r.metadata_json ? 'sp_target_rows_ingested' THEN 'COMPLETED' END)
				       END AS grain_status
				FROM recent r
				CROSS JOIN (VALUES ('CAMPAIGN'), ('AD_GROUP'), ('KEYWORD'), ('TARGET')) AS g(grain)
				LEFT JOIN campaign ON campaign.data_date = r.data_date
				LEFT JOIN adgroup ON adgroup.data_date = r.data_date
				LEFT JOIN keyword ON keyword.data_date = r.data_date
				LEFT JOIN target ON target.data_date = r.data_date
			) h
			ORDER BY data_date DESC,
				CASE grain WHEN 'CAMPAIGN' THEN 0 WHEN 'AD_GROUP' THEN 1 WHEN 'KEYWORD' THEN 2 WHEN 'TARGET' THEN 3 ELSE 4 END
			LIMIT 40`)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "ads_reprocess_health_failed: "+err.Error())
			return
		}
		reprocessHealth, err := pgx.CollectRows(reprocessHealthRows, pgx.RowToMap)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "ads_reprocess_health_scan_failed: "+err.Error())
			return
		}

		targetQualityRows, err := h.db.Query(ctx, `
			WITH ams AS (
				SELECT
					CASE
						WHEN NULLIF(keyword_id, '') IS NOT NULL
						  OR COALESCE(match_type, '') IN ('BROAD','PHRASE','EXACT')
						THEN 'KEYWORD'
						ELSE 'TARGET'
					END AS ads_report_grain,
					COUNT(*)::float8 AS rows,
					COALESCE(SUM(spend),0)::float8 AS ams_spend,
					COALESCE(SUM(GREATEST(COALESCE(orders_14d,0), COALESCE(orders_7d,0), COALESCE(orders_1d,0))),0)::float8 AS ams_orders,
					MAX(updated_at) AS last_ams_update
				FROM marketcloud_bronze.bronze_ams_hourly_target
				GROUP BY 1
			), ads AS (
				SELECT
					report_grain AS ads_report_grain,
					COUNT(*)::float8 AS ads_rows,
					COALESCE(SUM(cost),0)::float8 AS ads_spend,
					COALESCE(SUM(purchases),0)::float8 AS ads_orders,
					MAX(synced_at) AS last_ads_sync
				FROM marketcloud_ops.ads_reporting_sp_targeting_daily_v3
				GROUP BY report_grain
			)
			SELECT
				CASE
					WHEN COALESCE(ams.rows,0) > 0 AND COALESCE(ads.ads_rows,0) > 0 THEN 'FAST_COVERAGE'
					WHEN COALESCE(ams.rows,0) > 0 THEN 'ADS_TARGETING_MISSING'
					ELSE 'ADS_ONLY'
				END AS target_quality_status,
				COALESCE(ams.ads_report_grain, ads.ads_report_grain) AS ads_report_grain,
				COALESCE(ams.rows, ads.ads_rows, 0) AS rows,
				100::float8 AS avg_quality_score,
				COALESCE(ams.ams_spend,0)::float8 AS ams_spend,
				COALESCE(ads.ads_spend,0)::float8 AS ads_spend,
				(COALESCE(ads.ads_spend,0) - COALESCE(ams.ams_spend,0))::float8 AS delta_spend,
				COALESCE(ams.ams_orders,0)::float8 AS ams_orders,
				COALESCE(ads.ads_orders,0)::float8 AS ads_orders,
				(COALESCE(ads.ads_orders,0) - COALESCE(ams.ams_orders,0))::float8 AS delta_orders,
				ams.last_ams_update,
				ads.last_ads_sync
			FROM ams
			FULL OUTER JOIN ads USING (ads_report_grain)
			ORDER BY ads_report_grain`)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "ams_target_quality_summary_failed: "+err.Error())
			return
		}
		targetQualitySummary, err := pgx.CollectRows(targetQualityRows, pgx.RowToMap)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "ams_target_quality_summary_scan_failed: "+err.Error())
			return
		}

		targetQualityDivergences := []map[string]any{}

		writeJSON(w, http.StatusOK, map[string]any{
			"totals":                         totals,
			"models":                         models,
			"ml_runs":                        runs,
			"ams_hours":                      ams,
			"learning_outcomes":              []map[string]any{},
			"learning_summary":               map[string]any{},
			"holdout":                        map[string]any{},
			"audit_360_summary":              map[string]any{},
			"audit_360":                      []map[string]any{},
			"full_control_360_summary":       map[string]any{},
			"full_control_360":               []map[string]any{},
			"ams_quality_summary":            qualitySummary,
			"ams_quality_divergences":        qualityDivergences,
			"ads_reprocess_requests":         reprocessRequests,
			"ads_reprocess_health":           reprocessHealth,
			"ml_training_volume":             []map[string]any{},
			"ams_target_quality_summary":     targetQualitySummary,
			"ams_target_quality_divergences": targetQualityDivergences,
			"operational_alerts":             []map[string]any{},
		})
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

	// Veredito sintetico do aprendizado: conclui pelo operador de forma honesta.
	// Usa SO a janela 24h (senao 1h/3h/24h contam em triplo). Marca amostra
	// pequena para nao virar decisao de dinheiro em cima de ruido.
	var ls struct {
		Measured, Improved, Worsened, Neutral, NoData int
		NetDeltaSales, NetDeltaSpend                  float64
	}
	_ = h.db.QueryRow(ctx, `
		SELECT
			count(*) FILTER (WHERE outcome_window='24h'),
			count(*) FILTER (WHERE outcome_window='24h' AND outcome_label='IMPROVED'),
			count(*) FILTER (WHERE outcome_window='24h' AND outcome_label='WORSENED'),
			count(*) FILTER (WHERE outcome_window='24h' AND outcome_label='NEUTRAL'),
			count(*) FILTER (WHERE outcome_window='24h' AND outcome_label='NO_DATA'),
			COALESCE(sum(delta_sales) FILTER (WHERE outcome_window='24h'),0),
			COALESCE(sum(delta_spend) FILTER (WHERE outcome_window='24h'),0)
		FROM marketcloud_recommendations.recommendation_hourly_outcomes`).
		Scan(&ls.Measured, &ls.Improved, &ls.Worsened, &ls.Neutral, &ls.NoData, &ls.NetDeltaSales, &ls.NetDeltaSpend)

	conclusive := ls.Improved + ls.Worsened
	sample := "OK"
	verdict := "NEUTRO"
	if conclusive < 20 {
		sample = "PEQUENA"
		verdict = "INCONCLUSIVO"
	} else if ls.Improved > ls.Worsened && ls.NetDeltaSales >= 0 {
		verdict = "POSITIVO"
	} else if ls.Worsened > ls.Improved && ls.NetDeltaSales < 0 {
		verdict = "NEGATIVO"
	}
	learningSummary := map[string]any{
		"measured": ls.Measured, "improved": ls.Improved, "worsened": ls.Worsened,
		"neutral": ls.Neutral, "no_data": ls.NoData, "conclusive": conclusive,
		"net_delta_sales": ls.NetDeltaSales, "net_delta_spend": ls.NetDeltaSpend,
		"sample": sample, "verdict": verdict,
	}

	// Holdout: robo (TRATAMENTO) x deixar quieto (CONTROLE) no dado maduro.
	// Leitura DIRECIONAL (nivel de ROAS), nao diff-in-diff — ver migration 119.
	type hoRow struct {
		Grupo                       string
		Celulas                     int
		Gasto, Venda, Pedidos, Roas float64
	}
	var ctrl, trat hoRow
	if hoRows, hoErr := h.db.Query(ctx, `SELECT grupo, celulas, gasto::float8, venda::float8, pedidos::float8, roas::float8 FROM marketcloud_recommendations.v_holdout_analysis_v1`); hoErr == nil {
		defer hoRows.Close()
		for hoRows.Next() {
			var g hoRow
			if hoRows.Scan(&g.Grupo, &g.Celulas, &g.Gasto, &g.Venda, &g.Pedidos, &g.Roas) == nil {
				if g.Grupo == "CONTROLE" {
					ctrl = g
				} else if g.Grupo == "TRATAMENTO" {
					trat = g
				}
			}
		}
	}
	liftPct := 0.0
	if ctrl.Roas > 0 {
		liftPct = (trat.Roas - ctrl.Roas) / ctrl.Roas * 100
	}
	holdoutSummary := map[string]any{
		"control_roas": ctrl.Roas, "treatment_roas": trat.Roas, "lift_pct": liftPct,
		"control_cells": ctrl.Celulas, "treatment_cells": trat.Celulas,
		"control_spend": ctrl.Gasto, "treatment_spend": trat.Gasto,
		"control_sales": ctrl.Venda, "treatment_sales": trat.Venda,
		"reading": "DIRECIONAL",
	}

	if view == "ml" {
		trainingVolumeLight := []map[string]any{
			{
				"source":    "campaign_hour_gold",
				"rows":      totals["campaign_rows"],
				"campaigns": nil,
				"targets":   nil,
				"clicks":    nil,
				"orders":    totals["ams_orders_7d"],
				"sales":     totals["ams_sales_7d"],
				"spend":     nil,
			},
			{
				"source":    "target_hour_reconciled",
				"rows":      totals["target_rows"],
				"campaigns": nil,
				"targets":   nil,
				"clicks":    nil,
				"orders":    totals["target_orders_7d"],
				"sales":     totals["target_sales_7d"],
				"spend":     nil,
			},
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"totals":                         totals,
			"models":                         models,
			"ml_runs":                        runs,
			"ams_hours":                      ams,
			"learning_outcomes":              learning,
			"learning_summary":               learningSummary,
			"holdout":                        holdoutSummary,
			"audit_360_summary":              map[string]any{},
			"audit_360":                      []map[string]any{},
			"full_control_360_summary":       map[string]any{},
			"full_control_360":               []map[string]any{},
			"ams_quality_summary":            []map[string]any{},
			"ams_quality_divergences":        []map[string]any{},
			"ads_reprocess_requests":         []map[string]any{},
			"ads_reprocess_health":           []map[string]any{},
			"ml_training_volume":             trainingVolumeLight,
			"ams_target_quality_summary":     []map[string]any{},
			"ams_target_quality_divergences": []map[string]any{},
			"operational_alerts":             []map[string]any{},
		})
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
	if len(audit360) == 0 {
		err = h.db.QueryRow(ctx, `
			SELECT jsonb_build_object(
				'total', COUNT(*),
				'pending', COUNT(*) FILTER (WHERE execution_status = 'NOT_EXECUTED'),
				'winning', 0,
				'losing', 0,
				'neutral', COUNT(*) FILTER (WHERE execution_status IN ('EXECUTED','SHADOW','SKIPPED','ROLLED_BACK')),
				'model_right', 0,
				'model_wrong', 0,
				'last_executed_at', MAX(executed_at),
				'last_measured_at', (SELECT MAX(measured_at) FROM marketcloud_recommendations.recommendation_hourly_outcomes)
			)::jsonb
			FROM marketcloud_recommendations.recommendation_decisions
			WHERE tenant_id = $1 OR tenant_id = 'zanom'`, tenantID).Scan(&auditSummary)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "audit_360_fallback_summary_failed: "+err.Error())
			return
		}
		fallbackRows, err := h.db.Query(ctx, `
			SELECT recommendation_id, campaign_id, campaign_name, ad_group_name, event_hour,
			       recommended_action, recommended_bid_multiplier::float8 AS recommended_bid_multiplier,
			       decided_action, decided_bid_multiplier::float8 AS decided_bid_multiplier,
			       decided_by, decision_notes, executed_at,
			       priority_score::float8 AS priority_score,
			       priority_bucket, final_risk_level,
			       execution_status AS audit_result,
			       NULL::text AS model_result,
			       0::int AS measured_windows,
			       NULL::timestamptz AS action_start_at_1h,
			       NULL::timestamptz AS eval_window_end_1h,
			       NULL::float8 AS baseline_roas_1h,
			       NULL::float8 AS eval_roas_1h,
			       NULL::float8 AS delta_roas_1h,
			       NULL::text AS outcome_label_1h,
			       NULL::text AS model_verdict_1h,
			       NULL::timestamptz AS action_start_at_3h,
			       NULL::timestamptz AS eval_window_end_3h,
			       NULL::float8 AS baseline_roas_3h,
			       NULL::float8 AS eval_roas_3h,
			       NULL::float8 AS delta_roas_3h,
			       NULL::text AS outcome_label_3h,
			       NULL::text AS model_verdict_3h,
			       NULL::timestamptz AS action_start_at_24h,
			       NULL::timestamptz AS eval_window_end_24h,
			       NULL::float8 AS baseline_roas_24h,
			       NULL::float8 AS eval_roas_24h,
			       NULL::float8 AS delta_roas_24h,
			       NULL::text AS outcome_label_24h,
			       NULL::text AS model_verdict_24h,
			       updated_at AS last_measured_at
			FROM marketcloud_recommendations.recommendation_decisions
			WHERE tenant_id = $1 OR tenant_id = 'zanom'
			ORDER BY COALESCE(executed_at, updated_at, created_at) DESC
			LIMIT 40`, tenantID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "audit_360_fallback_failed: "+err.Error())
			return
		}
		audit360, err = pgx.CollectRows(fallbackRows, pgx.RowToMap)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "audit_360_fallback_scan_failed: "+err.Error())
			return
		}
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

	if view == "robot" {
		trainingVolumeLight := []map[string]any{
			{
				"source": "campaign_hour_gold",
				"rows":   totals["campaign_rows"],
				"orders": totals["ams_orders_7d"],
				"sales":  totals["ams_sales_7d"],
			},
			{
				"source": "target_hour_reconciled",
				"rows":   totals["target_rows"],
				"orders": totals["target_orders_7d"],
				"sales":  totals["target_sales_7d"],
			},
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"totals":                         totals,
			"models":                         models,
			"ml_runs":                        runs,
			"ams_hours":                      ams,
			"learning_outcomes":              learning,
			"learning_summary":               learningSummary,
			"holdout":                        holdoutSummary,
			"audit_360_summary":              auditSummary,
			"audit_360":                      audit360,
			"full_control_360_summary":       fc360Summary,
			"full_control_360":               fc360,
			"ams_quality_summary":            []map[string]any{},
			"ams_quality_divergences":        []map[string]any{},
			"ads_reprocess_requests":         []map[string]any{},
			"ads_reprocess_health":           []map[string]any{},
			"ml_training_volume":             trainingVolumeLight,
			"ams_target_quality_summary":     []map[string]any{},
			"ams_target_quality_divergences": []map[string]any{},
			"operational_alerts":             []map[string]any{},
		})
		return
	}

	qualityRows, err := h.db.Query(ctx, `
		SELECT data_quality_status, operator_action, rows,
		       min_date, max_date,
		       avg_quality_score::float8 AS avg_quality_score,
		       ams_spend::float8 AS ams_spend,
		       ads_spend::float8 AS ads_spend,
		       delta_ads_spend::float8 AS delta_ads_spend,
		       ams_orders_7d::float8 AS ams_orders_7d,
		       ads_orders::float8 AS ads_orders,
		       delta_ads_orders::float8 AS delta_ads_orders,
		       last_ams_update, last_ads_sync
		FROM marketcloud_gold.v_ams_quality_summary_v1
		ORDER BY
			CASE data_quality_status
				WHEN 'DIVERGENT' THEN 0
				WHEN 'ADS_MISSING' THEN 1
				WHEN 'ATTRIBUTING' THEN 2
				WHEN 'FRESH' THEN 3
				WHEN 'DELTA_ONLY' THEN 4
				WHEN 'MATURE_RECONCILED' THEN 5
				ELSE 6
			END,
			rows DESC`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ams_quality_summary_failed: "+err.Error())
		return
	}
	qualitySummary, err := pgx.CollectRows(qualityRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ams_quality_summary_scan_failed: "+err.Error())
		return
	}

	divRows, err := h.db.Query(ctx, `
		SELECT data_date, maturity_bucket, campaign_id, campaign_name,
		       data_quality_status, data_quality_score, operator_action,
		       ams_spend_clamped::float8 AS ams_spend,
		       ads_spend::float8 AS ads_spend,
		       delta_ads_spend::float8 AS delta_ads_spend,
		       ams_orders_7d::float8 AS ams_orders_7d,
		       ads_orders::float8 AS ads_orders,
		       delta_ads_orders::float8 AS delta_ads_orders,
		       ams_sales_7d::float8 AS ams_sales_7d,
		       ads_sales::float8 AS ads_sales,
		       delta_ads_sales::float8 AS delta_ads_sales,
		       ams_last_update, ads_last_sync
		FROM marketcloud_gold.v_ams_data_quality_score_v1
		WHERE data_quality_status IN ('DIVERGENT','ADS_MISSING','LOW_CONFIDENCE')
		   OR operator_action IN ('REQUEST_ADS_REPORT_REPROCESS','INVESTIGATE_DELTA_AND_REPROCESS_ADS_REPORT')
		ORDER BY data_quality_score ASC, data_date DESC, ABS(delta_ads_spend) DESC NULLS LAST
		LIMIT 30`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ams_quality_divergences_failed: "+err.Error())
		return
	}
	qualityDivergences, err := pgx.CollectRows(divRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ams_quality_divergences_scan_failed: "+err.Error())
		return
	}

	reprocessRows, err := h.db.Query(ctx, `
		SELECT id, source, data_date, window_label, status, reason,
		       requested_at, updated_at, completed_at, error_message
		FROM marketcloud_ops.ads_reporting_reprocess_requests
		ORDER BY data_date DESC, window_label
		LIMIT 30`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ads_reprocess_requests_failed: "+err.Error())
		return
	}
	reprocessRequests, err := pgx.CollectRows(reprocessRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ads_reprocess_requests_scan_failed: "+err.Error())
		return
	}

	reprocessHealthRows, err := h.db.Query(ctx, `
		SELECT id, data_date, window_label, window_status, grain, report_id,
		       rows_ingested, grain_status, updated_at, completed_at, error_message
		FROM marketcloud_gold.v_ads_reporting_reprocess_health_v1
		ORDER BY data_date DESC,
			CASE grain WHEN 'CAMPAIGN' THEN 0 WHEN 'AD_GROUP' THEN 1 WHEN 'KEYWORD' THEN 2 WHEN 'TARGET' THEN 3 ELSE 4 END
		LIMIT 40`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ads_reprocess_health_failed: "+err.Error())
		return
	}
	reprocessHealth, err := pgx.CollectRows(reprocessHealthRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ads_reprocess_health_scan_failed: "+err.Error())
		return
	}

	trainingVolumeRows, err := h.db.Query(ctx, `
		SELECT source, rows::float8 AS rows, min_date, max_date,
		       campaigns::float8 AS campaigns,
		       targets::float8 AS targets,
		       clicks::float8 AS clicks,
		       orders::float8 AS orders,
		       sales::float8 AS sales,
		       spend::float8 AS spend
		FROM marketcloud_gold.v_ml_training_volume_reconciliation_v1
		ORDER BY
			CASE source
				WHEN 'campaign_hour_gold' THEN 0
				WHEN 'target_hour_reconciled' THEN 1
				WHEN 'amc_daily_total_context' THEN 2
				ELSE 3
			END`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ml_training_volume_failed: "+err.Error())
		return
	}
	trainingVolume, err := pgx.CollectRows(trainingVolumeRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ml_training_volume_scan_failed: "+err.Error())
		return
	}

	targetQualityRows, err := h.db.Query(ctx, `
		SELECT target_quality_status, ads_report_grain,
		       COUNT(*) AS rows,
		       ROUND(AVG(target_quality_score)::numeric, 2)::float8 AS avg_quality_score,
		       SUM(ams_spend)::float8 AS ams_spend,
		       SUM(ads_spend)::float8 AS ads_spend,
		       SUM(delta_spend)::float8 AS delta_spend,
		       SUM(ams_orders)::float8 AS ams_orders,
		       SUM(ads_orders)::float8 AS ads_orders,
		       SUM(delta_orders)::float8 AS delta_orders,
		       MAX(ams_last_update) AS last_ams_update,
		       MAX(ads_last_sync) AS last_ads_sync
		FROM marketcloud_gold.v_ams_target_ads_reconciliation_daily_v1
		GROUP BY target_quality_status, ads_report_grain
		ORDER BY
			CASE target_quality_status
				WHEN 'DIVERGENT' THEN 0
				WHEN 'ADS_TARGETING_MISSING' THEN 1
				WHEN 'ATTRIBUTING' THEN 2
				WHEN 'FRESH' THEN 3
				WHEN 'MATCH' THEN 4
				ELSE 5
			END,
			rows DESC`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ams_target_quality_summary_failed: "+err.Error())
		return
	}
	targetQualitySummary, err := pgx.CollectRows(targetQualityRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ams_target_quality_summary_scan_failed: "+err.Error())
		return
	}

	targetDivRows, err := h.db.Query(ctx, `
		SELECT data_date, campaign_id, campaign_name, ad_group_id, ad_group_name,
		       target_entity_key, target_text, match_type, ads_report_grain,
		       target_quality_status, target_quality_score,
		       ams_spend::float8 AS ams_spend,
		       ads_spend::float8 AS ads_spend,
		       delta_spend::float8 AS delta_spend,
		       ams_orders::float8 AS ams_orders,
		       ads_orders::float8 AS ads_orders,
		       delta_orders::float8 AS delta_orders,
		       ams_last_update, ads_last_sync
		FROM marketcloud_gold.v_ams_target_ads_reconciliation_daily_v1
		WHERE target_quality_status IN ('DIVERGENT','ADS_TARGETING_MISSING')
		ORDER BY target_quality_score ASC, data_date DESC, ABS(delta_spend) DESC NULLS LAST
		LIMIT 40`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ams_target_quality_divergences_failed: "+err.Error())
		return
	}
	targetQualityDivergences, err := pgx.CollectRows(targetDivRows, pgx.RowToMap)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "ams_target_quality_divergences_scan_failed: "+err.Error())
		return
	}

	operationalAlerts := []map[string]any{}
	var lastTargetML time.Time
	err = h.db.QueryRow(ctx, `
		SELECT COALESCE(MAX(finished_at), TIMESTAMPTZ 'epoch')
		FROM marketcloud_gold.ml_hourly_run_status
		WHERE run_kind = 'hourly_target_real_v3'`).Scan(&lastTargetML)
	if err != nil {
		operationalAlerts = append(operationalAlerts, map[string]any{
			"severity":    "warning",
			"alert_key":   "ml_target_v3_freshness_check_failed",
			"title":       "ML target V3 freshness indisponivel",
			"detail":      err.Error(),
			"entity_type": "ML_RUN",
			"entity_id":   "hourly_target_real_v3",
			"observed_at": time.Now().UTC(),
		})
	} else if lastTargetML.Before(time.Now().UTC().Add(-2 * time.Hour)) {
		operationalAlerts = append(operationalAlerts, map[string]any{
			"severity":    "warning",
			"alert_key":   "ml_target_v3_freshness",
			"title":       "ML target V3 freshness",
			"detail":      "ultimo finished_at=" + lastTargetML.Format(time.RFC3339),
			"entity_type": "ML_RUN",
			"entity_id":   "hourly_target_real_v3",
			"observed_at": lastTargetML,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"totals":                         totals,
		"models":                         models,
		"ml_runs":                        runs,
		"ams_hours":                      ams,
		"learning_outcomes":              learning,
		"learning_summary":               learningSummary,
		"holdout":                        holdoutSummary,
		"audit_360_summary":              auditSummary,
		"audit_360":                      audit360,
		"full_control_360_summary":       fc360Summary,
		"full_control_360":               fc360,
		"ams_quality_summary":            qualitySummary,
		"ams_quality_divergences":        qualityDivergences,
		"ads_reprocess_requests":         reprocessRequests,
		"ads_reprocess_health":           reprocessHealth,
		"ml_training_volume":             trainingVolume,
		"ams_target_quality_summary":     targetQualitySummary,
		"ams_target_quality_divergences": targetQualityDivergences,
		"operational_alerts":             operationalAlerts,
	})
}
