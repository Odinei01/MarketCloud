"""
MarketCloud ML Worker - HOURLY REAL v2

Treina no dado real horario da conta ZANOM, sem supressao:
  marketcloud_features.feature_full_control_campaign_hour_v1

Diferente do V1, que aprendia sobre o AMC suprimido e recusava treinar por falta de
sinal na classe minoritaria. Aqui ha sinal real: celulas com pedido.

Modelos:
  ConversionModelReal   target: has_order  (binario)    -> conversion_probability
  ExpectedRoasReal      target: roas_capped (regressao)  -> expected_roas

HONESTIDADE:
  - grao: campanha x hora agregado na janela.
  - features SEM vazamento do alvo: hora, faixas do dia, campanha (one-hot),
    sinais de demanda, funil AMC, budget, stop-loss, produto e placement.
    Nao usa orders/sales/roas como X.
  - reporta comparacao contra baseline simples por hora-do-dia.
  - ADVISOR-ONLY: grava predicoes, nao executa nada.
"""

import json
import logging
import os
from datetime import date, datetime, timezone

import numpy as np
import pandas as pd
import psycopg2
import psycopg2.extras
from sklearn.ensemble import RandomForestClassifier, RandomForestRegressor
from sklearn.metrics import (
    balanced_accuracy_score,
    mean_absolute_error,
    r2_score,
    roc_auc_score,
)
from sklearn.model_selection import StratifiedKFold, cross_val_predict, KFold, GroupKFold

logging.basicConfig(level=logging.INFO, format="%(asctime)s [ML-HOURLY-REAL] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgres://mcadmin:mcsecret@postgres:5432/marketcloud")
ROAS_CAP = 20.0
GOOD_HOUR_PROB = 0.5
GOOD_HOUR_ROAS = 4.0


def get_conn():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def load(conn):
    # Features Full Control (§2026-07-16): agrega a camada canonica de sinal
    # horario com budget, stop-loss, produto e placement traffic. Alvos
    # (orders/sales/roas) continuam vindo apenas de celulas maduras.
    sql = """
        WITH base AS (
            SELECT *
            FROM marketcloud_features.feature_full_control_campaign_hour_v1
        ), pilot AS (
            SELECT DISTINCT ON (campaign_id)
                campaign_id,
                tenant_id,
                product_asin,
                seller_sku
            FROM marketcloud_gold.full_control_effective_governance_v1
            WHERE COALESCE(campaign_id,'') <> ''
            ORDER BY campaign_id,
                CASE status WHEN 'active' THEN 0 WHEN 'draft' THEN 1 ELSE 2 END,
                updated_at DESC
        ), data_quality AS (
            SELECT
                campaign_id,
                AVG(data_quality_score)::float AS avg_data_quality_score_30d,
                COUNT(*) FILTER (WHERE data_quality_status = 'DIVERGENT')::float AS divergent_days_30d,
                COUNT(*) FILTER (WHERE data_quality_status = 'ADS_MISSING')::float AS ads_missing_days_30d,
                COUNT(*) FILTER (WHERE data_quality_status = 'ATTRIBUTING')::float AS attributing_days_30d,
                COUNT(*) FILTER (WHERE data_quality_status = 'FRESH')::float AS fresh_days_30d,
                COUNT(*) FILTER (WHERE data_quality_status = 'MATURE_RECONCILED')::float AS mature_reconciled_days_30d,
                COUNT(*) FILTER (WHERE traffic_usable_for_ml)::float AS traffic_usable_days_30d,
                COUNT(*) FILTER (WHERE conversion_usable_for_ml)::float AS conversion_usable_days_30d
            FROM marketcloud_gold.v_ams_data_quality_score_v1
            WHERE data_date >= CURRENT_DATE - INTERVAL '30 days'
            GROUP BY campaign_id
        )
        SELECT
            b.*,
            COALESCE(p.tenant_id::text, 'zanom') AS tenant_id,
            COALESCE(dq.avg_data_quality_score_30d,50) AS avg_data_quality_score_30d,
            COALESCE(dq.divergent_days_30d,0) AS divergent_days_30d,
            COALESCE(dq.ads_missing_days_30d,0) AS ads_missing_days_30d,
            COALESCE(dq.attributing_days_30d,0) AS attributing_days_30d,
            COALESCE(dq.fresh_days_30d,0) AS fresh_days_30d,
            COALESCE(dq.mature_reconciled_days_30d,0) AS mature_reconciled_days_30d,
            COALESCE(dq.traffic_usable_days_30d,0) AS traffic_usable_days_30d,
            COALESCE(dq.conversion_usable_days_30d,0) AS conversion_usable_days_30d,
            COALESCE(q.quality_orders_30d,0) AS quality_orders_30d,
            COALESCE(q.quality_units_sold_30d,0) AS quality_units_sold_30d,
            COALESCE(q.refund_total_30d,0) AS refund_total_30d,
            COALESCE(q.return_quantity_30d,0) AS return_quantity_30d,
            COALESCE(q.return_events_30d,0) AS return_events_30d,
            COALESCE(q.return_units_30d,0) AS return_units_30d,
            COALESCE(q.return_refund_amount_30d,0) AS return_refund_amount_30d,
            COALESCE(q.return_rate_30d,0) AS return_rate_30d,
            COALESCE(q.net_profit_after_quality_30d,0) AS net_profit_after_quality_30d,
            COALESCE(q.net_margin_after_quality_ratio_30d,0) AS net_margin_after_quality_ratio_30d,
            COALESCE(q.rating_latest,0) AS product_rating_latest,
            COALESCE(q.reviews_total_latest,0) AS product_reviews_total_latest,
            COALESCE(q.review_source_confidence,0) AS review_source_confidence,
            COALESCE(q.low_rating_flag,0) AS low_rating_flag,
            COALESCE(q.high_return_flag,0) AS high_return_flag,
            COALESCE(q.refund_flag,0) AS refund_flag,
            COALESCE(cc.avg_day_of_week,0) AS avg_day_of_week,
            COALESCE(cc.weekend_share,0) AS weekend_share,
            COALESCE(cc.avg_day_of_month,0) AS avg_day_of_month,
            COALESCE(cc.avg_week_of_month,0) AS avg_week_of_month,
            COALESCE(cc.avg_month_of_year,0) AS avg_month_of_year,
            COALESCE(cc.month_start_share,0) AS month_start_share,
            COALESCE(cc.month_middle_share,0) AS month_middle_share,
            COALESCE(cc.month_end_share,0) AS month_end_share,
            COALESCE(cc.paycheck_window_share,0) AS paycheck_window_share,
            COALESCE(cc.midmonth_window_share,0) AS midmonth_window_share,
            COALESCE(cc.holiday_share,0) AS holiday_share,
            COALESCE(cc.holiday_eve_share,0) AS holiday_eve_share,
            COALESCE(cc.post_holiday_share,0) AS post_holiday_share,
            COALESCE(cc.commercial_event_share,0) AS commercial_event_share,
            COALESCE(cc.mothers_day_share,0) AS mothers_day_share,
            COALESCE(cc.fathers_day_share,0) AS fathers_day_share,
            COALESCE(cc.black_friday_share,0) AS black_friday_share,
            COALESCE(cc.christmas_runup_share,0) AS christmas_runup_share,
            COALESCE(cc.avg_days_to_nearest_event,31) AS avg_days_to_nearest_event,
            COALESCE(cc.avg_abs_days_to_nearest_event,31) AS avg_abs_days_to_nearest_event,
            COALESCE(cc.pre_event_30d_share,0) AS pre_event_30d_share,
            COALESCE(cc.pre_event_14d_share,0) AS pre_event_14d_share,
            COALESCE(cc.pre_event_7d_share,0) AS pre_event_7d_share,
            COALESCE(cc.event_day_share,0) AS event_day_share,
            COALESCE(cc.post_event_7d_share,0) AS post_event_7d_share,
            COALESCE(cx.price_to_cost_ratio,0) AS price_to_cost_ratio,
            COALESCE(cx.stock_days_of_cover,0) AS stock_days_of_cover,
            COALESCE(cx.product_orders_30d,0) AS product_orders_30d,
            COALESCE(cx.product_sales_30d,0) AS product_sales_30d,
            COALESCE(cx.product_roas_30d,0) AS product_roas_30d,
            COALESCE(cx.has_competitor_price,0) AS has_competitor_price,
            COALESCE(cx.competitor_price_min_brl,0) AS competitor_price_min_brl,
            COALESCE(cx.competitor_price_gap_pct,0) AS competitor_price_gap_pct,
            COALESCE(cx.is_price_above_competitor,0) AS is_price_above_competitor,
            COALESCE(cx.has_bsr,0) AS has_bsr,
            COALESCE(cx.bsr_rank,0) AS bsr_rank,
            COALESCE(cx.bsr_delta_7d,0) AS bsr_delta_7d
        FROM base b
        LEFT JOIN pilot p ON p.campaign_id = b.campaign_id
        LEFT JOIN data_quality dq ON dq.campaign_id = b.campaign_id
        LEFT JOIN marketcloud_features.feature_product_quality_v1 q
          ON q.product_asin = COALESCE(NULLIF(p.product_asin,''), 'NO_ASIN')
         AND (
              COALESCE(q.seller_sku,'') = COALESCE(p.seller_sku,'')
              OR COALESCE(q.seller_sku,'') = ''
              OR COALESCE(p.seller_sku,'') = ''
         )
        LEFT JOIN marketcloud_features.feature_campaign_calendar_context_v1 cc
          ON cc.campaign_id = b.campaign_id
         AND cc.event_hour = b.event_hour
        LEFT JOIN marketcloud_features.feature_campaign_commercial_context_v1 cx
          ON cx.campaign_id = b.campaign_id
    """
    with conn.cursor() as cur:
        cur.execute(sql)
        df = pd.DataFrame([dict(r) for r in cur.fetchall()])
    if df.empty:
        return df
    numeric_cols = ["event_hour", "days_observed", "impressions", "clicks", "spend",
                    "orders", "sales", "spend_mature", "mature_days",
                    "amc_assist_rate", "amc_first_touch_rate", "amc_new_customer_rate",
                    "amc_dpv_count", "amc_cart_adds",
                    "learn_roas_delta_avg", "learn_win_rate",
                    "current_budget_brl", "spend_to_budget_ratio",
                    "top_of_search_bid_adjustment", "top_of_search_multiplier_delta",
                    "bidding_legacy_for_sales", "sale_price_brl", "unit_cost_brl",
                    "stock_available", "gross_margin_brl", "gross_margin_pct",
                    "max_daily_budget_brl", "max_spend_without_order_brl", "min_roas",
                    "max_top_of_search_pct", "max_product_page_pct", "max_rest_of_search_pct",
                    "spend_to_fc_daily_cap_ratio", "spend_to_stop_loss_ratio",
                    "is_full_control_pilot", "is_active_pilot", "can_control_flag",
                    "avg_data_quality_score_30d", "divergent_days_30d", "ads_missing_days_30d",
                    "attributing_days_30d", "fresh_days_30d", "mature_reconciled_days_30d",
                    "traffic_usable_days_30d", "conversion_usable_days_30d",
                    "placement_spend_45d", "placement_clicks_45d", "placement_impressions_45d",
                    "top_search_spend_45d", "product_page_spend_45d", "rest_search_spend_45d",
                    "top_search_spend_share_45d", "product_page_spend_share_45d", "rest_search_spend_share_45d",
                    "top_search_cpc_45d", "product_page_cpc_45d", "rest_search_cpc_45d",
                    "quality_orders_30d", "quality_units_sold_30d", "refund_total_30d",
                    "return_quantity_30d", "return_events_30d", "return_units_30d",
                    "return_refund_amount_30d", "return_rate_30d",
                    "net_profit_after_quality_30d", "net_margin_after_quality_ratio_30d",
                    "product_rating_latest", "product_reviews_total_latest",
                    "review_source_confidence", "low_rating_flag", "high_return_flag", "refund_flag",
                    "avg_day_of_week", "weekend_share", "avg_day_of_month",
                    "avg_week_of_month", "avg_month_of_year",
                    "month_start_share", "month_middle_share", "month_end_share",
                    "paycheck_window_share", "midmonth_window_share",
                    "holiday_share", "holiday_eve_share", "post_holiday_share",
                    "commercial_event_share", "mothers_day_share", "fathers_day_share",
                    "black_friday_share", "christmas_runup_share",
                    "avg_days_to_nearest_event", "avg_abs_days_to_nearest_event",
                    "pre_event_30d_share", "pre_event_14d_share", "pre_event_7d_share",
                    "event_day_share", "post_event_7d_share",
                    "price_to_cost_ratio", "stock_days_of_cover",
                    "product_orders_30d", "product_sales_30d", "product_roas_30d",
                    "has_competitor_price", "competitor_price_min_brl",
                    "competitor_price_gap_pct", "is_price_above_competitor",
                    "has_bsr", "bsr_rank", "bsr_delta_7d"]
    for col in numeric_cols:
        df[col] = pd.to_numeric(df[col], errors="coerce").replace([np.inf, -np.inf], np.nan).fillna(0.0)
    df["ctr"] = np.where(df["impressions"] > 0, df["clicks"] / df["impressions"], 0.0)
    df["cpc"] = np.where(df["clicks"] > 0, df["spend"] / df["clicks"], 0.0)
    df["impr_per_day"] = np.where(df["days_observed"] > 0, df["impressions"] / df["days_observed"], 0.0)
    # ROAS/has_order do alvo = só do maduro (sales/spend maduros)
    df["roas"] = np.where(df["spend_mature"] > 0, df["sales"] / df["spend_mature"], 0.0)
    df["has_order"] = (df["orders"] > 0).astype(int)
    df["is_madrugada"] = df["event_hour"].between(0, 5).astype(int)
    df["is_manha"] = df["event_hour"].between(6, 11).astype(int)
    df["is_tarde"] = df["event_hour"].between(12, 17).astype(int)
    df["is_noite"] = df["event_hour"].between(18, 23).astype(int)
    return df


def build_X(df):
    # features SEM vazamento do alvo (nada de orders/sales/roas)
    base = df[["event_hour", "is_madrugada", "is_manha", "is_tarde", "is_noite",
               "ctr", "cpc", "impr_per_day", "days_observed",
               "amc_assist_rate", "amc_first_touch_rate", "amc_new_customer_rate",
               "amc_dpv_count", "amc_cart_adds",
               "learn_roas_delta_avg", "learn_win_rate",
               "current_budget_brl", "spend_to_budget_ratio",
               "top_of_search_bid_adjustment", "top_of_search_multiplier_delta",
               "bidding_legacy_for_sales",
               "sale_price_brl", "unit_cost_brl", "stock_available",
               "gross_margin_brl", "gross_margin_pct",
               "max_daily_budget_brl", "max_spend_without_order_brl", "min_roas",
               "max_top_of_search_pct", "max_product_page_pct", "max_rest_of_search_pct",
               "spend_to_fc_daily_cap_ratio", "spend_to_stop_loss_ratio",
               "is_full_control_pilot", "is_active_pilot", "can_control_flag",
               "avg_data_quality_score_30d", "divergent_days_30d", "ads_missing_days_30d",
               "attributing_days_30d", "fresh_days_30d", "mature_reconciled_days_30d",
               "traffic_usable_days_30d", "conversion_usable_days_30d",
               "placement_spend_45d", "placement_clicks_45d", "placement_impressions_45d",
               "top_search_spend_share_45d", "product_page_spend_share_45d", "rest_search_spend_share_45d",
               "top_search_cpc_45d", "product_page_cpc_45d", "rest_search_cpc_45d",
               "quality_orders_30d", "quality_units_sold_30d", "refund_total_30d",
               "return_quantity_30d", "return_events_30d", "return_units_30d",
               "return_refund_amount_30d", "return_rate_30d",
               "net_profit_after_quality_30d", "net_margin_after_quality_ratio_30d",
               "product_rating_latest", "product_reviews_total_latest",
               "review_source_confidence", "low_rating_flag", "high_return_flag", "refund_flag",
               "avg_day_of_week", "weekend_share", "avg_day_of_month",
               "avg_week_of_month", "avg_month_of_year",
               "month_start_share", "month_middle_share", "month_end_share",
               "paycheck_window_share", "midmonth_window_share",
               "holiday_share", "holiday_eve_share", "post_holiday_share",
               "commercial_event_share", "mothers_day_share", "fathers_day_share",
               "black_friday_share", "christmas_runup_share",
               "avg_days_to_nearest_event", "avg_abs_days_to_nearest_event",
               "pre_event_30d_share", "pre_event_14d_share", "pre_event_7d_share",
               "event_day_share", "post_event_7d_share",
               "price_to_cost_ratio", "stock_days_of_cover",
               "product_orders_30d", "product_sales_30d", "product_roas_30d",
               "has_competitor_price", "competitor_price_min_brl",
               "competitor_price_gap_pct", "is_price_above_competitor",
               "has_bsr", "bsr_rank", "bsr_delta_7d"]].copy()
    camp = pd.get_dummies(df["campaign_norm"], prefix="c")
    X = pd.concat([base.reset_index(drop=True), camp.reset_index(drop=True)], axis=1)
    return X.astype(float), list(X.columns)


def register(conn, name, model_type, target, status, rows, metrics):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO marketcloud_features.model_registry
                (model_name, model_version, model_type, target_name,
                 training_rows, metrics_json, feature_columns_json, status)
            VALUES (%s,'v2',%s,%s,%s,%s,%s,%s)
            ON CONFLICT ON CONSTRAINT uq_model_registry DO UPDATE SET
                model_type=EXCLUDED.model_type, target_name=EXCLUDED.target_name,
                training_rows=EXCLUDED.training_rows, metrics_json=EXCLUDED.metrics_json,
                feature_columns_json=EXCLUDED.feature_columns_json, status=EXCLUDED.status
            """,
            (name, model_type, target, rows, json.dumps(metrics), json.dumps(metrics.get("features", [])), status),
        )
        conn.commit()


def record_run_status(conn, started_at, status, rows, positive_orders, predictions_written, metrics):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO marketcloud_gold.ml_hourly_run_status
                (run_kind, model_version, grain, status, training_rows,
                 positive_order_rows, predictions_written, metrics_json,
                 started_at, finished_at)
            VALUES ('hourly_real_v2', 'v2', 'campaign_hour', %s, %s, %s, %s, %s, %s, NOW())
            RETURNING id
            """,
            (status, rows, positive_orders, predictions_written, json.dumps(metrics), started_at),
        )
        run_id = cur.fetchone()["id"]
        conn.commit()
        return run_id


def confidence_for(cp, er, min_roas):
    cp = float(cp or 0)
    er = float(er or 0)
    min_roas = float(min_roas or GOOD_HOUR_ROAS)
    if cp >= 0.65 and er >= min_roas * 1.2:
        return "HIGH"
    if cp >= 0.45 and er >= min_roas:
        return "MEDIUM"
    return "LOW"


def rec_id(campaign_id, campaign_name, hour, action_type):
    raw = f"{campaign_id or campaign_name}:{hour}:{action_type}"
    safe = "".join(ch if ch.isalnum() else "_" for ch in raw.lower()).strip("_")
    return f"fc360_{safe[:180]}"


def append_action(actions, row, action_type, current_value, recommended_value, cp, er, reason, priority_boost=0):
    min_roas = float(row.get("min_roas") or GOOD_HOUR_ROAS)
    spend = float(row.get("spend") or 0)
    baseline_roas = float(row.get("roas") or 0)
    expected_delta_roas = float(er or 0) - baseline_roas
    spend_delta_ratio = 0.0
    if action_type in ("INCREASE_DAILY_BUDGET", "INCREASE_TOP_OF_SEARCH", "TEST_PRODUCT_PAGE", "TEST_REST_OF_SEARCH"):
        spend_delta_ratio = min(0.35, max(0.05, (float(recommended_value or 0) - float(current_value or 0)) / max(abs(float(current_value or 0)), 1.0)))
    elif action_type in ("STOP_LOSS_PROTECT", "REDUCE_DAILY_BUDGET", "REDUCE_TOP_OF_SEARCH"):
        spend_delta_ratio = -min(0.35, max(0.05, (float(current_value or 0) - float(recommended_value or 0)) / max(abs(float(current_value or 0)), 1.0)))
    expected_delta_spend = round(spend * spend_delta_ratio, 4)
    expected_delta_sales = round((spend + expected_delta_spend) * max(float(er or 0), 0) - spend * max(baseline_roas, 0), 4)
    decision_class = classify_action(row, action_type, cp, er)
    data_sufficiency = data_sufficiency_for(row, cp, er)
    execution_strategy = "AUTO_EXECUTE_BID_ROBOT" if action_type.endswith("BID") else "REQUIRES_REAL_EXECUTOR"
    if action_type in ("STOP_LOSS_PROTECT", "REDUCE_DAILY_BUDGET", "REDUCE_TOP_OF_SEARCH"):
        execution_strategy = "SAFETY_RECOMMENDATION"
    priority = max(0.0, float(er or 0) - min_roas) * 10.0 + float(cp or 0) * 25.0 + priority_boost
    actions.append((
        rec_id(row.get("campaign_id"), row.get("campaign_name"), int(row.get("event_hour") or 0), action_type),
        str(row.get("tenant_id") or "zanom"),
        row.get("campaign_id"),
        row.get("campaign_name"),
        int(row.get("event_hour") or 0),
        action_type,
        "FULL_CONTROL_360",
        float(current_value or 0),
        float(recommended_value or 0),
        None if er is None or np.isnan(er) else round(float(er), 4),
        None if cp is None or np.isnan(cp) else round(float(cp), 4),
        confidence_for(cp, er, min_roas),
        round(priority, 4),
        "READY" if int(row.get("can_control_flag") or 0) == 1 else "BLOCKED_BY_GOVERNANCE",
        reason,
        json.dumps({
            "spend": float(row.get("spend") or 0),
            "spend_to_budget_ratio": float(row.get("spend_to_budget_ratio") or 0),
            "spend_to_fc_daily_cap_ratio": float(row.get("spend_to_fc_daily_cap_ratio") or 0),
            "spend_to_stop_loss_ratio": float(row.get("spend_to_stop_loss_ratio") or 0),
            "current_budget_brl": float(row.get("current_budget_brl") or 0),
            "max_daily_budget_brl": float(row.get("max_daily_budget_brl") or 0),
            "max_spend_without_order_brl": float(row.get("max_spend_without_order_brl") or 0),
            "top_search_spend_share_45d": float(row.get("top_search_spend_share_45d") or 0),
            "product_page_spend_share_45d": float(row.get("product_page_spend_share_45d") or 0),
            "rest_search_spend_share_45d": float(row.get("rest_search_spend_share_45d") or 0),
            "max_top_of_search_pct": float(row.get("max_top_of_search_pct") or 0),
            "max_product_page_pct": float(row.get("max_product_page_pct") or 0),
            "max_rest_of_search_pct": float(row.get("max_rest_of_search_pct") or 0),
            "stock_available": float(row.get("stock_available") or 0),
            "gross_margin_pct": float(row.get("gross_margin_pct") or 0),
        }),
        round(expected_delta_spend, 4),
        round(expected_delta_sales, 4),
        round(expected_delta_roas, 4),
        decision_class,
        execution_strategy,
        round(min_roas, 4),
        data_sufficiency,
        operator_note_for(decision_class, action_type),
    ))


def data_sufficiency_for(row, cp, er):
    days = float(row.get("days_observed") or 0)
    clicks = float(row.get("clicks") or 0)
    orders = float(row.get("orders") or 0)
    if days < 7 or clicks < 10:
        return "LOW_DATA"
    if orders <= 0 and (cp or 0) < 0.35:
        return "NO_CONVERSION_SIGNAL"
    if (er or 0) <= 0:
        return "ROAS_MODEL_CONFLICT"
    return "ENOUGH_DATA"


def classify_action(row, action_type, cp, er):
    if int(row.get("can_control_flag") or 0) != 1:
        return "BLOCKED"
    min_roas = float(row.get("min_roas") or GOOD_HOUR_ROAS)
    suff = data_sufficiency_for(row, cp, er)
    if action_type in ("STOP_LOSS_PROTECT", "REDUCE_DAILY_BUDGET", "REDUCE_TOP_OF_SEARCH") and float(er or 0) < min_roas:
        return "APPLY_SAFETY"
    if suff != "ENOUGH_DATA":
        return "WAIT_MORE_DATA"
    if float(cp or 0) >= 0.65 and float(er or 0) >= min_roas * 1.15:
        return "APPLY"
    if float(cp or 0) >= 0.45 and float(er or 0) >= min_roas:
        return "TEST_CONTROLLED"
    return "WAIT_MORE_DATA"


def operator_note_for(decision_class, action_type):
    if decision_class == "BLOCKED":
        return "Bloqueado por governanca atual do piloto."
    if decision_class == "APPLY_SAFETY":
        return "Acao defensiva: pode reduzir risco, mas ainda exige executor real para esta variavel."
    if decision_class == "APPLY":
        return "Sinal forte para aplicacao, sujeito ao executor real e limites do piloto."
    if decision_class == "TEST_CONTROLLED":
        return "Sinal positivo para teste pequeno/holdout antes de escalar."
    return "Aguardar mais dados antes de aplicar automaticamente."


def write_full_control_360_actions(conn, df, proba_full, roas_full):
    actions = []
    for i in range(len(df)):
        row = df.iloc[i]
        if int(row.get("is_full_control_pilot") or 0) != 1:
            continue
        cp = None if np.isnan(proba_full[i]) else float(proba_full[i])
        er = None if np.isnan(roas_full[i]) else float(roas_full[i])
        if cp is None or er is None:
            continue
        min_roas = float(row.get("min_roas") or GOOD_HOUR_ROAS)
        current_budget = float(row.get("current_budget_brl") or 0)
        max_budget = float(row.get("max_daily_budget_brl") or 0)
        stop_loss = float(row.get("max_spend_without_order_brl") or 0)
        spend_to_budget = float(row.get("spend_to_budget_ratio") or 0)
        spend_to_stop = float(row.get("spend_to_stop_loss_ratio") or 0)
        top_limit = float(row.get("max_top_of_search_pct") or 0)
        product_limit = float(row.get("max_product_page_pct") or 0)
        rest_limit = float(row.get("max_rest_of_search_pct") or 0)
        top_current = float(row.get("top_of_search_bid_adjustment") or 0)

        if spend_to_stop >= 0.90 and er < min_roas:
            append_action(actions, row, "STOP_LOSS_PROTECT", stop_loss, 0, cp, er,
                          "Gasto sem pedido perto do limite e ROAS previsto abaixo do minimo.", 35)
        if cp >= GOOD_HOUR_PROB and er >= min_roas and spend_to_budget >= 0.85 and max_budget > current_budget > 0:
            recommended = min(max_budget, max(current_budget * 1.2, current_budget + 5))
            append_action(actions, row, "INCREASE_DAILY_BUDGET", current_budget, recommended, cp, er,
                          "Hora boa prevista e campanha perto do budget diario.", 30)
        if er < min_roas * 0.75 and current_budget > 0 and spend_to_budget > 0.50:
            recommended = max(5, current_budget * 0.8)
            append_action(actions, row, "REDUCE_DAILY_BUDGET", current_budget, recommended, cp, er,
                          "ROAS previsto fraco com consumo relevante de budget.", 20)
        if top_limit > 0 and cp >= GOOD_HOUR_PROB and er >= min_roas and top_current < top_limit:
            recommended = min(top_limit, max(top_current + 10, top_limit * 0.5))
            append_action(actions, row, "INCREASE_TOP_OF_SEARCH", top_current, recommended, cp, er,
                          "Hora forte; limite do piloto permite testar Top of Search.", 25)
        if top_current > 0 and er < min_roas:
            recommended = max(0, top_current - 10)
            append_action(actions, row, "REDUCE_TOP_OF_SEARCH", top_current, recommended, cp, er,
                          "Top of Search ativo com ROAS previsto abaixo do minimo.", 18)
        if product_limit > 0 and cp >= 0.45 and er >= min_roas and float(row.get("product_page_spend_share_45d") or 0) < 0.35:
            append_action(actions, row, "TEST_PRODUCT_PAGE", 0, product_limit, cp, er,
                          "Produto/campanha com sinal positivo; testar Product Page dentro do limite.", 12)
        if rest_limit > 0 and cp >= 0.45 and er >= min_roas and float(row.get("rest_search_spend_share_45d") or 0) < 0.35:
            append_action(actions, row, "TEST_REST_OF_SEARCH", 0, rest_limit, cp, er,
                          "Produto/campanha com sinal positivo; testar Rest of Search dentro do limite.", 8)

    with conn.cursor() as cur:
        cur.execute("TRUNCATE marketcloud_gold.ml_full_control_action_recommendations_v1")
        if actions:
            psycopg2.extras.execute_values(
                cur,
                """
                INSERT INTO marketcloud_gold.ml_full_control_action_recommendations_v1
                    (recommendation_id, tenant_id, campaign_id, campaign_name, event_hour,
                     action_type, action_scope, current_value, recommended_value,
                     expected_roas, conversion_probability, confidence, priority_score,
                     guardrail_status, reason, evidence_json,
                     expected_delta_spend, expected_delta_sales, expected_delta_roas,
                     decision_class, execution_strategy, min_roas_used, data_sufficiency, operator_note)
                VALUES %s
                ON CONFLICT (recommendation_id) DO UPDATE SET
                    tenant_id=EXCLUDED.tenant_id,
                    current_value=EXCLUDED.current_value,
                    recommended_value=EXCLUDED.recommended_value,
                    expected_roas=EXCLUDED.expected_roas,
                    conversion_probability=EXCLUDED.conversion_probability,
                    confidence=EXCLUDED.confidence,
                    priority_score=EXCLUDED.priority_score,
                    guardrail_status=EXCLUDED.guardrail_status,
                    reason=EXCLUDED.reason,
                    evidence_json=EXCLUDED.evidence_json,
                    expected_delta_spend=EXCLUDED.expected_delta_spend,
                    expected_delta_sales=EXCLUDED.expected_delta_sales,
                    expected_delta_roas=EXCLUDED.expected_delta_roas,
                    decision_class=EXCLUDED.decision_class,
                    execution_strategy=EXCLUDED.execution_strategy,
                    min_roas_used=EXCLUDED.min_roas_used,
                    data_sufficiency=EXCLUDED.data_sufficiency,
                    operator_note=EXCLUDED.operator_note,
                    computed_at=NOW()
                """,
                actions,
                page_size=200,
            )
        conn.commit()
        cur.execute("SELECT marketcloud_recommendations.sync_ml_full_control_360_proposals() AS synced")
        synced = cur.fetchone()
        conn.commit()
        if synced:
            log.info("%s propostas Full Control 360 sincronizadas no ledger", synced.get("synced"))
    return len(actions)


def main():
    started_at = datetime.now(timezone.utc)
    conn = get_conn()
    conn.autocommit = False
    try:
        df = load(conn)
        if df.empty:
            log.warning("sem dados horarios reais")
            return
        n = len(df)
        pos = int(df["has_order"].sum())
        log.info(f"{n} celulas campanha x hora | {pos} com pedido | {n-pos} sem")

        X, feat_cols = build_X(df)
        y_cls = df["has_order"].values
        y_roas = np.minimum(df["roas"].replace([np.inf, -np.inf], np.nan).fillna(0.0).values, ROAS_CAP)
        X = X.replace([np.inf, -np.inf], np.nan).fillna(0.0)

        # ---- Modelo 1: conversao (has_order) ----
        cls = RandomForestClassifier(n_estimators=400, class_weight="balanced",
                                     min_samples_leaf=2, random_state=42, n_jobs=-1)
        cls_metrics = {"features": feat_cols, "n": n, "positives": pos}
        if pos >= 10 and (n - pos) >= 10:
            cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
            proba = cross_val_predict(cls, X, y_cls, cv=cv, method="predict_proba", n_jobs=1)[:, 1]
            pred = (proba >= 0.5).astype(int)
            # baseline simples: taxa de pedido por hora-do-dia
            hour_rate = df.groupby("event_hour")["has_order"].transform("mean").values
            cls_metrics.update({
                "roc_auc": float(roc_auc_score(y_cls, proba)),
                "balanced_accuracy": float(balanced_accuracy_score(y_cls, pred)),
                "baseline_hourrate_auc": float(roc_auc_score(y_cls, hour_rate)),
                "beats_baseline": bool(roc_auc_score(y_cls, proba) > roc_auc_score(y_cls, hour_rate)),
                "cv": "stratified_5fold_oof",
            })
            # Metrica HONESTA de generalizacao cross-campanha (GroupKFold por
            # campaign_norm). Com os dummies de campanha, o CV aleatorio acima
            # mede "prever hora de campanha CONHECIDA" (uso operacional, legitimo);
            # este numero mede "prever campanha NOVA" (SaaS). Ambos divulgados
            # pra auditoria — o gap entre eles e o quanto o modelo depende da
            # identidade da campanha.
            try:
                groups = df["campaign_norm"].astype("category").cat.codes.values
                ng = int(df["campaign_norm"].nunique())
                if ng >= 3:
                    gcv = GroupKFold(n_splits=min(5, ng))
                    gproba = cross_val_predict(cls, X, y_cls, cv=gcv, groups=groups,
                                               method="predict_proba", n_jobs=1)[:, 1]
                    cls_metrics["roc_auc_cross_campaign"] = float(roc_auc_score(y_cls, gproba))
            except Exception as exc:
                cls_metrics["roc_auc_cross_campaign_error"] = str(exc)[:120]
            # AUC CONDICIONAL A CLIQUE (auditoria 19/07): so celulas com trafego
            # real (clicks>0), onde a decisao de bid importa. Remove o gate
            # trivial "sem clique => sem pedido" que infla o AUC global.
            try:
                clicked = df["clicks"].fillna(0).values > 0
                nclk = int(clicked.sum())
                cls_metrics["clicked_cells"] = nclk
                if nclk > 0 and len(np.unique(y_cls[clicked])) == 2:
                    cls_metrics["roc_auc_clicked_only"] = float(roc_auc_score(y_cls[clicked], proba[clicked]))
            except Exception as exc:
                cls_metrics["roc_auc_clicked_only_error"] = str(exc)[:120]
            cls.fit(X, y_cls)
            proba_full = cls.predict_proba(X)[:, 1]
            imp = sorted(zip(feat_cols, cls.feature_importances_), key=lambda t: -t[1])[:8]
            cls_metrics["top_features"] = [{"f": f, "imp": float(i)} for f, i in imp]
            register(conn, "HourlyConversionRealV2", "classifier:rf", "has_order", "TRAINED", n, cls_metrics)
            log.info(f"Conversao: AUC={cls_metrics['roc_auc']:.3f} "
                     f"AUC_xcamp={cls_metrics.get('roc_auc_cross_campaign')} "
                     f"AUC_clicked={cls_metrics.get('roc_auc_clicked_only')} "
                     f"baseline={cls_metrics['baseline_hourrate_auc']:.3f} "
                     f"beats={cls_metrics['beats_baseline']}")
        else:
            proba_full = np.full(n, np.nan)
            register(conn, "HourlyConversionRealV2", "classifier", "has_order", "INSUFFICIENT_DATA", n, cls_metrics)
            log.warning("conversao: sinal insuficiente")

        # ---- Modelo 2: ROAS esperado ----
        reg = RandomForestRegressor(n_estimators=400, min_samples_leaf=2, random_state=42, n_jobs=-1)
        reg_metrics = {"features": feat_cols, "n": n}
        finite_roas = np.isfinite(y_roas)
        if not np.all(finite_roas):
            log.warning("ROAS: %s labels invalidos tratados como zero", int((~finite_roas).sum()))
            y_roas = np.where(finite_roas, y_roas, 0.0)
        nonzero = int(np.sum(y_roas > 0))
        if nonzero >= 10:
            cv = KFold(n_splits=5, shuffle=True, random_state=42)
            oof = cross_val_predict(reg, X, y_roas, cv=cv, n_jobs=1)
            oof = np.clip(oof, 0, ROAS_CAP)
            baseline = df.groupby("event_hour")["roas"].transform("mean").clip(0, ROAS_CAP).values
            reg_metrics.update({
                "mae": float(mean_absolute_error(y_roas, oof)),
                "r2": float(r2_score(y_roas, oof)),
                "baseline_hourmean_mae": float(mean_absolute_error(y_roas, baseline)),
                "beats_baseline": bool(mean_absolute_error(y_roas, oof) < mean_absolute_error(y_roas, baseline)),
                "target_mean": float(np.mean(y_roas)),
                "cv": "kfold_5_oof",
            })
            # MAE honesto cross-campanha (GroupKFold) — ver nota no classificador.
            try:
                groups = df["campaign_norm"].astype("category").cat.codes.values
                ng = int(df["campaign_norm"].nunique())
                if ng >= 3:
                    gcv = GroupKFold(n_splits=min(5, ng))
                    goof = np.clip(cross_val_predict(reg, X, y_roas, cv=gcv, groups=groups, n_jobs=1), 0, ROAS_CAP)
                    reg_metrics["mae_cross_campaign"] = float(mean_absolute_error(y_roas, goof))
            except Exception as exc:
                reg_metrics["mae_cross_campaign_error"] = str(exc)[:120]
            # MAE condicional a clique: erro so nas celulas com trafego real.
            try:
                clicked = df["clicks"].fillna(0).values > 0
                nclk = int(clicked.sum())
                reg_metrics["clicked_cells"] = nclk
                if nclk > 0:
                    reg_metrics["mae_clicked_only"] = float(mean_absolute_error(y_roas[clicked], oof[clicked]))
            except Exception as exc:
                reg_metrics["mae_clicked_only_error"] = str(exc)[:120]
            reg.fit(X, y_roas)
            roas_full = np.clip(reg.predict(X), 0, ROAS_CAP)
            imp = sorted(zip(feat_cols, reg.feature_importances_), key=lambda t: -t[1])[:8]
            reg_metrics["top_features"] = [{"f": f, "imp": float(i)} for f, i in imp]
            register(conn, "HourlyExpectedRoasRealV2", "regressor:rf", "roas_capped", "TRAINED", n, reg_metrics)
            log.info(f"ROAS: MAE={reg_metrics['mae']:.3f} r2={reg_metrics['r2']:.3f} "
                     f"baseline_MAE={reg_metrics['baseline_hourmean_mae']:.3f} "
                     f"beats={reg_metrics['beats_baseline']}")
        else:
            roas_full = np.full(n, np.nan)
            register(conn, "HourlyExpectedRoasRealV2", "regressor", "roas_capped", "INSUFFICIENT_DATA", n, reg_metrics)
            log.warning("ROAS: variancia insuficiente")

        # ---- grava predicoes por campanha x hora ----
        rows = []
        for i in range(n):
            cp = None if np.isnan(proba_full[i]) else round(float(proba_full[i]), 4)
            er = None if np.isnan(roas_full[i]) else round(float(roas_full[i]), 4)
            good = None
            if cp is not None and er is not None:
                good = bool(cp >= GOOD_HOUR_PROB and er >= GOOD_HOUR_ROAS)
            rows.append((df.iloc[i]["campaign_name"], int(df.iloc[i]["event_hour"]), cp, er, good))
        with conn.cursor() as cur:
            cur.execute("TRUNCATE marketcloud_gold.hourly_ml_predictions_v2")
            psycopg2.extras.execute_values(
                cur,
                """INSERT INTO marketcloud_gold.hourly_ml_predictions_v2
                   (campaign_name, event_hour, conversion_probability, expected_roas, predicted_good_hour)
                   VALUES %s""",
                rows, page_size=200,
            )
            conn.commit()
        log.info(f"{len(rows)} predicoes gravadas em hourly_ml_predictions_v2")
        actions_written = write_full_control_360_actions(conn, df, proba_full, roas_full)
        log.info(f"{actions_written} recomendacoes Full Control 360 gravadas")
        run_status = "COMPLETED"
        if cls_metrics.get("positives", 0) < 10 or reg_metrics.get("n", 0) == 0:
            run_status = "PARTIAL"
        run_id = record_run_status(conn, started_at, run_status, n, pos, len(rows), {
            "conversion": cls_metrics,
            "expected_roas": reg_metrics,
            "full_control_360_actions_written": actions_written,
        })
        # P1-6: carimba predicoes/recs desta rodada com o run_id, ligando cada
        # uma ao modelo que a gerou (as tabelas sao truncadas por rodada, entao
        # tudo que esta la e desta rodada).
        if run_id:
            with conn.cursor() as cur:
                cur.execute("UPDATE marketcloud_gold.hourly_ml_predictions_v2 SET run_id=%s WHERE run_id IS NULL", (run_id,))
                cur.execute("UPDATE marketcloud_gold.ml_full_control_action_recommendations_v1 SET run_id=%s WHERE run_id IS NULL", (run_id,))
            conn.commit()
            log.info(f"predicoes/recs carimbadas com run_id={run_id}")
    except Exception:
        log.exception("erro no ML hourly-real v2")
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()



