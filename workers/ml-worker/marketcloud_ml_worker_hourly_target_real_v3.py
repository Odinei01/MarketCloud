"""
MarketCloud ML Worker — HOURLY TARGET REAL v3

Treina no dado reconciliado real em grao keyword/target x hora:
  marketcloud_gold.v_ml_target_hour_training_reconciled_v1

Modelos registrados:
  HourlyTargetClickRealV3       target: has_click
  HourlyTargetConversionRealV3  target: has_order
  HourlyTargetExpectedRoasRealV3 target: roas_capped

HONESTIDADE:
  - O dataset usa Ads Reporting v3 diario alocado por hora como backfill antes
    do AMS estabilizado, e AMS target horario como fonte principal a partir de
    2026-07-13. A feature source_confidence diferencia os dois sinais.
  - O dataset AMS target ainda pode conter restatements/deltas.
  - Se nao houver volume minimo, registra INSUFFICIENT_DATA e nao inventa score.
  - Usa tambem a faixa de BID recomendada pela Amazon (lower/median/upper) e
    o BID atual/proposto do Robo como contexto de treino, nao como label.
  - ADVISOR-ONLY: grava predicoes, nao executa nada na Amazon.

MODO SOMBRA (intencional, 2026-07-13):
  Escreve SOMENTE em tabelas observacionais (model_registry, ml_hourly_run_status,
  hourly_target_ml_predictions_v3). NENHUM auto-apply/bid-robot consome o V3 keyword.
  Motivo: densidade de conversao ainda baixa no grao keyword x hora
  (ex.: Conversao AUC 0.774 < baseline 0.926 com apenas ~6 positivos; ROAS nao
  treina com nonzero=3). NAO ligar o V3 a nenhum caminho de apply enquanto os
  positivos de conversao nao subirem (alvo pratico >~50) e o AUC nao superar o
  baseline de forma estavel. O auto-apply real hoje e SO no grao campanha x hora
  (marketcloud_ml_auto_apply_campaign_recommendations.py).
"""

import json
import logging
import os
from datetime import datetime, timezone

import numpy as np
import pandas as pd
import psycopg2
import psycopg2.extras
from sklearn.ensemble import RandomForestClassifier, RandomForestRegressor
from sklearn.metrics import balanced_accuracy_score, mean_absolute_error, r2_score, roc_auc_score
from sklearn.model_selection import StratifiedKFold, KFold, GroupKFold, cross_val_predict
try:
    from sklearn.model_selection import StratifiedGroupKFold
except ImportError:  # sklearn < 1.0
    StratifiedGroupKFold = None

logging.basicConfig(level=logging.INFO, format="%(asctime)s [ML-TARGET-REAL] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgres://mcadmin:mcsecret@postgres:5432/marketcloud")
ROAS_CAP = 20.0
MIN_POSITIVE_CLASS = 5
MIN_NEGATIVE_CLASS = 10
GOOD_TARGET_CLICK_PROB = 0.50
GOOD_TARGET_CONV_PROB = 0.35
GOOD_TARGET_ROAS = 4.0


def get_conn():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def load(conn):
    sql = """
        WITH base AS (
            SELECT
                campaign_id,
                MAX(campaign_name) AS campaign_name,
                COALESCE(NULLIF(MAX(ad_group_id), ''), '') AS ad_group_id_norm,
                NULLIF(MAX(ad_group_id), '') AS ad_group_id,
                MAX(ad_group_name) AS ad_group_name,
                target_entity_key,
                MAX(keyword_id) AS keyword_id,
                MAX(target_id) AS target_id,
                MAX(keyword_text) AS keyword_text,
                MAX(targeting) AS targeting,
                COALESCE(NULLIF(MAX(match_type), ''), 'UNKNOWN') AS match_type,
                event_hour,
                COUNT(DISTINCT data_date)::int AS days_observed,
                SUM(COALESCE(impressions, 0))::float AS impressions,
                SUM(COALESCE(clicks, 0))::float AS clicks,
                SUM(COALESCE(spend, 0))::float AS spend,
                SUM(COALESCE(orders, 0))::float AS orders,
                SUM(COALESCE(sales, 0))::float AS sales,
                AVG(COALESCE(source_confidence, 1.0))::float AS source_confidence
            FROM marketcloud_gold.v_ml_target_hour_training_reconciled_v1
            WHERE NULLIF(TRIM(COALESCE(target_entity_key, '')), '') IS NOT NULL
            GROUP BY campaign_id, target_entity_key, event_hour
        ), pilot AS (
            SELECT DISTINCT ON (campaign_id)
                campaign_id,
                product_asin,
                seller_sku
            FROM marketcloud_gold.full_control_effective_governance_v1
            WHERE COALESCE(campaign_id,'') <> ''
            ORDER BY campaign_id,
                CASE status WHEN 'active' THEN 0 WHEN 'draft' THEN 1 ELSE 2 END,
                updated_at DESC
        )
        SELECT
            b.*,
            COALESCE(d.current_bid, 0)::float AS current_bid,
            COALESCE(NULLIF(r.recommended_bid_lower, 0), NULLIF(d.amazon_recommended_bid_lower, 0), 0)::float AS amazon_rec_bid_lower,
            COALESCE(NULLIF(r.recommended_bid_median, 0), NULLIF(d.amazon_recommended_bid_median, 0), 0)::float AS amazon_rec_bid_median,
            COALESCE(NULLIF(r.recommended_bid_upper, 0), NULLIF(d.amazon_recommended_bid_upper, 0), 0)::float AS amazon_rec_bid_upper,
            COALESCE(d.proposed_bid, 0)::float AS robot_proposed_bid,
            COALESCE(d.bid_delta_percent, 0)::float AS robot_bid_delta_percent,
            COALESCE(d.effective_min_bid, 0)::float AS effective_min_bid,
            COALESCE(d.effective_max_bid, 0)::float AS effective_max_bid,
            CASE
                WHEN COALESCE(d.current_bid,0) > 0 THEN COALESCE(NULLIF(r.recommended_bid_median, 0), NULLIF(d.amazon_recommended_bid_median, 0), 0) / NULLIF(d.current_bid,0)
                ELSE 0
            END::float AS amazon_rec_median_to_current_ratio,
            CASE
                WHEN COALESCE(NULLIF(r.recommended_bid_median, 0), NULLIF(d.amazon_recommended_bid_median, 0), 0) > 0 THEN COALESCE(d.proposed_bid,0) / NULLIF(COALESCE(NULLIF(r.recommended_bid_median, 0), NULLIF(d.amazon_recommended_bid_median, 0), 0),0)
                ELSE 0
            END::float AS robot_proposed_to_amazon_median_ratio,
            CASE WHEN COALESCE(NULLIF(r.recommended_bid_median, 0), NULLIF(d.amazon_recommended_bid_median, 0), 0) > 0 THEN 1 ELSE 0 END::float AS has_amazon_bid_recommendation
            , COALESCE(q.quality_orders_30d,0)::float AS quality_orders_30d
            , COALESCE(q.quality_units_sold_30d,0)::float AS quality_units_sold_30d
            , COALESCE(q.refund_total_30d,0)::float AS refund_total_30d
            , COALESCE(q.return_quantity_30d,0)::float AS return_quantity_30d
            , COALESCE(q.return_events_30d,0)::float AS return_events_30d
            , COALESCE(q.return_units_30d,0)::float AS return_units_30d
            , COALESCE(q.return_refund_amount_30d,0)::float AS return_refund_amount_30d
            , COALESCE(q.return_rate_30d,0)::float AS return_rate_30d
            , COALESCE(q.net_profit_after_quality_30d,0)::float AS net_profit_after_quality_30d
            , COALESCE(q.net_margin_after_quality_ratio_30d,0)::float AS net_margin_after_quality_ratio_30d
            , COALESCE(q.rating_latest,0)::float AS product_rating_latest
            , COALESCE(q.reviews_total_latest,0)::float AS product_reviews_total_latest
            , COALESCE(q.review_source_confidence,0)::float AS review_source_confidence
            , COALESCE(q.low_rating_flag,0)::float AS low_rating_flag
            , COALESCE(q.high_return_flag,0)::float AS high_return_flag
            , COALESCE(q.refund_flag,0)::float AS refund_flag
            , COALESCE(tq.avg_target_quality_score_30d,50)::float AS avg_target_quality_score_30d
            , COALESCE(tq.target_match_days_30d,0)::float AS target_match_days_30d
            , COALESCE(tq.target_divergent_days_30d,0)::float AS target_divergent_days_30d
            , COALESCE(tq.target_ads_missing_days_30d,0)::float AS target_ads_missing_days_30d
            , COALESCE(tq.target_attributing_days_30d,0)::float AS target_attributing_days_30d
            , COALESCE(tq.target_usable_days_30d,0)::float AS target_usable_days_30d
            , COALESCE(tc.avg_day_of_week,0)::float AS avg_day_of_week
            , COALESCE(tc.weekend_share,0)::float AS weekend_share
            , COALESCE(tc.avg_day_of_month,0)::float AS avg_day_of_month
            , COALESCE(tc.avg_week_of_month,0)::float AS avg_week_of_month
            , COALESCE(tc.avg_month_of_year,0)::float AS avg_month_of_year
            , COALESCE(tc.month_start_share,0)::float AS month_start_share
            , COALESCE(tc.month_middle_share,0)::float AS month_middle_share
            , COALESCE(tc.month_end_share,0)::float AS month_end_share
            , COALESCE(tc.paycheck_window_share,0)::float AS paycheck_window_share
            , COALESCE(tc.midmonth_window_share,0)::float AS midmonth_window_share
            , COALESCE(tc.holiday_share,0)::float AS holiday_share
            , COALESCE(tc.holiday_eve_share,0)::float AS holiday_eve_share
            , COALESCE(tc.post_holiday_share,0)::float AS post_holiday_share
            , COALESCE(tc.commercial_event_share,0)::float AS commercial_event_share
            , COALESCE(tc.mothers_day_share,0)::float AS mothers_day_share
            , COALESCE(tc.fathers_day_share,0)::float AS fathers_day_share
            , COALESCE(tc.black_friday_share,0)::float AS black_friday_share
            , COALESCE(tc.christmas_runup_share,0)::float AS christmas_runup_share
            , COALESCE(tc.avg_days_to_nearest_event,31)::float AS avg_days_to_nearest_event
            , COALESCE(tc.avg_abs_days_to_nearest_event,31)::float AS avg_abs_days_to_nearest_event
            , COALESCE(tc.pre_event_30d_share,0)::float AS pre_event_30d_share
            , COALESCE(tc.pre_event_14d_share,0)::float AS pre_event_14d_share
            , COALESCE(tc.pre_event_7d_share,0)::float AS pre_event_7d_share
            , COALESCE(tc.event_day_share,0)::float AS event_day_share
            , COALESCE(tc.post_event_7d_share,0)::float AS post_event_7d_share
            , COALESCE(hc.target_days_30d,0)::float AS target_days_30d
            , COALESCE(hc.target_impressions_30d,0)::float AS target_impressions_30d
            , COALESCE(hc.target_clicks_30d,0)::float AS target_clicks_30d
            , COALESCE(hc.target_spend_30d,0)::float AS target_spend_30d
            , COALESCE(hc.target_orders_30d,0)::float AS target_orders_30d
            , COALESCE(hc.target_sales_30d,0)::float AS target_sales_30d
            , COALESCE(hc.target_ctr_30d,0)::float AS target_ctr_30d
            , COALESCE(hc.target_cvr_30d,0)::float AS target_cvr_30d
            , COALESCE(hc.target_roas_30d,0)::float AS target_roas_30d
            , COALESCE(hc.campaign_days_30d,0)::float AS campaign_days_30d
            , COALESCE(hc.campaign_impressions_30d,0)::float AS campaign_impressions_30d
            , COALESCE(hc.campaign_clicks_30d,0)::float AS campaign_clicks_30d
            , COALESCE(hc.campaign_spend_30d,0)::float AS campaign_spend_30d
            , COALESCE(hc.campaign_orders_30d,0)::float AS campaign_orders_30d
            , COALESCE(hc.campaign_sales_30d,0)::float AS campaign_sales_30d
            , COALESCE(hc.campaign_ctr_30d,0)::float AS campaign_ctr_30d
            , COALESCE(hc.campaign_cvr_30d,0)::float AS campaign_cvr_30d
            , COALESCE(hc.campaign_roas_30d,0)::float AS campaign_roas_30d
            , COALESCE(hc.campaign_ml_conversion_probability,0)::float AS campaign_ml_conversion_probability
            , COALESCE(hc.campaign_ml_expected_roas,0)::float AS campaign_ml_expected_roas
            , COALESCE(hc.campaign_ml_good_hour,0)::float AS campaign_ml_good_hour
            , COALESCE(cx.sale_price_brl,0)::float AS sale_price_brl
            , COALESCE(cx.unit_cost_brl,0)::float AS unit_cost_brl
            , COALESCE(cx.stock_available,0)::float AS stock_available
            , COALESCE(cx.gross_margin_brl,0)::float AS gross_margin_brl
            , COALESCE(cx.gross_margin_pct,0)::float AS gross_margin_pct
            , COALESCE(cx.price_to_cost_ratio,0)::float AS price_to_cost_ratio
            , COALESCE(cx.stock_days_of_cover,0)::float AS stock_days_of_cover
            , COALESCE(cx.product_orders_30d,0)::float AS product_orders_30d
            , COALESCE(cx.product_sales_30d,0)::float AS product_sales_30d
            , COALESCE(cx.product_roas_30d,0)::float AS product_roas_30d
            , COALESCE(cx.max_daily_budget_brl,0)::float AS max_daily_budget_brl
            , COALESCE(cx.max_spend_without_order_brl,0)::float AS max_spend_without_order_brl
            , COALESCE(cx.min_roas,0)::float AS min_roas
            , COALESCE(cx.has_competitor_price,0)::float AS has_competitor_price
            , COALESCE(cx.competitor_price_min_brl,0)::float AS competitor_price_min_brl
            , COALESCE(cx.competitor_price_gap_pct,0)::float AS competitor_price_gap_pct
            , COALESCE(cx.is_price_above_competitor,0)::float AS is_price_above_competitor
            , COALESCE(cx.has_bsr,0)::float AS has_bsr
            , COALESCE(cx.bsr_rank,0)::float AS bsr_rank
            , COALESCE(cx.bsr_delta_7d,0)::float AS bsr_delta_7d
        FROM base b
        LEFT JOIN LATERAL (
            SELECT r.*
            FROM swarm_src.amazon_ads_bid_recommendations r
            WHERE r.campaign_id = b.campaign_id
              AND (COALESCE(r.ad_group_id,'') = b.ad_group_id_norm OR COALESCE(r.ad_group_id,'') = '')
              AND (
                    (NULLIF(b.keyword_id,'') IS NOT NULL AND r.keyword_id = b.keyword_id)
                 OR (NULLIF(b.target_id,'') IS NOT NULL AND r.target_id = b.target_id)
                 OR (NULLIF(b.target_entity_key,'') IS NOT NULL AND r.target_id = b.target_entity_key)
                 OR (
                        NULLIF(b.keyword_text,'') IS NOT NULL
                    AND lower(trim(COALESCE(
                        r.raw_payload_sanitized->>'keywordText',
                        r.raw_payload_sanitized->>'keyword',
                        r.raw_payload_sanitized #>> '{targetingExpression,value}',
                        ''
                    ))) = lower(trim(b.keyword_text))
                 )
                 OR (
                        NULLIF(b.targeting,'') IS NOT NULL
                    AND lower(trim(COALESCE(
                        r.raw_payload_sanitized->>'keywordText',
                        r.raw_payload_sanitized->>'keyword',
                        r.raw_payload_sanitized #>> '{targetingExpression,value}',
                        ''
                    ))) = lower(trim(b.targeting))
                 )
              )
            ORDER BY r.fetched_at DESC NULLS LAST
            LIMIT 1
        ) r ON TRUE
        LEFT JOIN LATERAL (
            SELECT d.*
            FROM swarm_src.amazon_ads_bid_decisions d
            WHERE d.campaign_id = b.campaign_id
              AND (COALESCE(d.ad_group_id,'') = b.ad_group_id_norm OR COALESCE(d.ad_group_id,'') = '')
              AND (
                    (NULLIF(b.keyword_id,'') IS NOT NULL AND d.keyword_id = b.keyword_id)
                 OR (NULLIF(b.target_id,'') IS NOT NULL AND d.target_id = b.target_id)
                 OR (NULLIF(b.keyword_text,'') IS NOT NULL AND lower(trim(d.target_text)) = lower(trim(b.keyword_text)))
                 OR (NULLIF(b.targeting,'') IS NOT NULL AND lower(trim(d.target_text)) = lower(trim(b.targeting)))
              )
            ORDER BY d.updated_at DESC NULLS LAST, d.created_at DESC NULLS LAST
            LIMIT 1
        ) d ON TRUE
        LEFT JOIN pilot p ON p.campaign_id = b.campaign_id
        LEFT JOIN marketcloud_features.feature_product_quality_v1 q
          ON q.product_asin = COALESCE(NULLIF(p.product_asin,''), 'NO_ASIN')
         AND (
              COALESCE(q.seller_sku,'') = COALESCE(p.seller_sku,'')
              OR COALESCE(q.seller_sku,'') = ''
              OR COALESCE(p.seller_sku,'') = ''
         )
        LEFT JOIN marketcloud_gold.v_ams_target_quality_features_v1 tq
          ON tq.campaign_id = b.campaign_id
         AND COALESCE(tq.ad_group_id,'') = b.ad_group_id_norm
         AND tq.target_entity_key = b.target_entity_key
        LEFT JOIN marketcloud_features.feature_target_calendar_context_v1 tc
          ON tc.campaign_id = b.campaign_id
         AND COALESCE(tc.ad_group_id,'') = b.ad_group_id_norm
         AND tc.target_entity_key = b.target_entity_key
         AND tc.event_hour = b.event_hour
        LEFT JOIN marketcloud_features.feature_target_hierarchical_context_v1 hc
          ON hc.campaign_id = b.campaign_id
         AND COALESCE(hc.ad_group_id,'') = b.ad_group_id_norm
         AND hc.target_entity_key = b.target_entity_key
         AND hc.event_hour = b.event_hour
        LEFT JOIN marketcloud_features.feature_campaign_commercial_context_v1 cx
          ON cx.campaign_id = b.campaign_id
    """
    with conn.cursor() as cur:
        cur.execute(sql)
        df = pd.DataFrame([dict(r) for r in cur.fetchall()])
    if df.empty:
        return df

    for col in [
        "impressions", "clicks", "spend", "orders", "sales",
        "source_confidence",
        "current_bid", "amazon_rec_bid_lower", "amazon_rec_bid_median",
        "amazon_rec_bid_upper", "robot_proposed_bid", "robot_bid_delta_percent",
        "effective_min_bid", "effective_max_bid",
        "amazon_rec_median_to_current_ratio", "robot_proposed_to_amazon_median_ratio",
        "has_amazon_bid_recommendation",
        "quality_orders_30d", "quality_units_sold_30d", "refund_total_30d",
        "return_quantity_30d", "return_events_30d", "return_units_30d",
        "return_refund_amount_30d", "return_rate_30d",
        "net_profit_after_quality_30d", "net_margin_after_quality_ratio_30d",
        "product_rating_latest", "product_reviews_total_latest",
        "review_source_confidence", "low_rating_flag", "high_return_flag", "refund_flag",
        "avg_target_quality_score_30d", "target_match_days_30d",
        "target_divergent_days_30d", "target_ads_missing_days_30d",
        "target_attributing_days_30d", "target_usable_days_30d",
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
        "target_days_30d", "target_impressions_30d", "target_clicks_30d",
        "target_spend_30d", "target_orders_30d", "target_sales_30d",
        "target_ctr_30d", "target_cvr_30d", "target_roas_30d",
        "campaign_days_30d", "campaign_impressions_30d", "campaign_clicks_30d",
        "campaign_spend_30d", "campaign_orders_30d", "campaign_sales_30d",
        "campaign_ctr_30d", "campaign_cvr_30d", "campaign_roas_30d",
        "campaign_ml_conversion_probability", "campaign_ml_expected_roas",
        "campaign_ml_good_hour",
        "sale_price_brl", "unit_cost_brl", "stock_available",
        "gross_margin_brl", "gross_margin_pct", "price_to_cost_ratio",
        "stock_days_of_cover", "product_orders_30d", "product_sales_30d",
        "product_roas_30d", "max_daily_budget_brl",
        "max_spend_without_order_brl", "min_roas",
        "has_competitor_price", "competitor_price_min_brl",
        "competitor_price_gap_pct", "is_price_above_competitor",
        "has_bsr", "bsr_rank", "bsr_delta_7d",
    ]:
        df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0.0)

    # AMS can send deltas/restatements. Keep the raw aggregate for audit, but use
    # non-negative signal features/labels for training stability.
    df["impressions_pos"] = df["impressions"].clip(lower=0)
    df["clicks_pos"] = df["clicks"].clip(lower=0)
    df["spend_pos"] = df["spend"].clip(lower=0)
    df["orders_pos"] = df["orders"].clip(lower=0)
    df["sales_pos"] = df["sales"].clip(lower=0)

    df["ctr"] = np.where(df["impressions_pos"] > 0, df["clicks_pos"] / df["impressions_pos"], 0.0)
    df["cpc"] = np.where(df["clicks_pos"] > 0, df["spend_pos"] / df["clicks_pos"], 0.0)
    df["impr_per_day"] = np.where(df["days_observed"] > 0, df["impressions_pos"] / df["days_observed"], 0.0)
    df["roas"] = np.where(df["spend_pos"] > 0, df["sales_pos"] / df["spend_pos"], 0.0)
    df["has_click"] = (df["clicks_pos"] > 0).astype(int)
    df["has_order"] = (df["orders_pos"] > 0).astype(int)
    df["is_madrugada"] = df["event_hour"].between(0, 5).astype(int)
    df["is_manha"] = df["event_hour"].between(6, 11).astype(int)
    df["is_tarde"] = df["event_hour"].between(12, 17).astype(int)
    df["is_noite"] = df["event_hour"].between(18, 23).astype(int)
    df["campaign_norm"] = df["campaign_name"].fillna("").str.strip().str.lower()
    df["match_type_norm"] = df["match_type"].fillna("UNKNOWN").str.strip().str.upper()
    return df


def build_X(df, target):
    cols = [
        "event_hour", "is_madrugada", "is_manha", "is_tarde", "is_noite",
        "impr_per_day", "days_observed", "source_confidence",
        "current_bid", "amazon_rec_bid_lower", "amazon_rec_bid_median",
        "amazon_rec_bid_upper", "robot_proposed_bid", "robot_bid_delta_percent",
        "effective_min_bid", "effective_max_bid",
        "amazon_rec_median_to_current_ratio", "robot_proposed_to_amazon_median_ratio",
        "has_amazon_bid_recommendation",
        "quality_orders_30d", "quality_units_sold_30d", "refund_total_30d",
        "return_quantity_30d", "return_events_30d", "return_units_30d",
        "return_refund_amount_30d", "return_rate_30d",
        "net_profit_after_quality_30d", "net_margin_after_quality_ratio_30d",
        "product_rating_latest", "product_reviews_total_latest",
        "review_source_confidence", "low_rating_flag", "high_return_flag", "refund_flag",
        "avg_target_quality_score_30d", "target_match_days_30d",
        "target_divergent_days_30d", "target_ads_missing_days_30d",
        "target_attributing_days_30d", "target_usable_days_30d",
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
        "target_days_30d", "target_impressions_30d",
        "campaign_days_30d", "campaign_impressions_30d",
        "campaign_ml_conversion_probability", "campaign_ml_expected_roas",
        "campaign_ml_good_hour",
        "sale_price_brl", "unit_cost_brl", "stock_available",
        "gross_margin_brl", "gross_margin_pct", "price_to_cost_ratio",
        "stock_days_of_cover", "max_daily_budget_brl",
        "max_spend_without_order_brl", "min_roas",
        "has_competitor_price", "competitor_price_min_brl",
        "competitor_price_gap_pct", "is_price_above_competitor",
        "has_bsr", "bsr_rank", "bsr_delta_7d",
    ]
    # ANTI-LEAK (auditoria 18/07): os agregados 30d de pedido/venda/roas/cvr da
    # MESMA entidade (target_orders_30d etc.), da campanha-mae e do produto
    # continham o proprio label — a janela 30d cobre TODO o periodo de treino,
    # entao "target_orders_30d>0" ~= "has_order=1". Prova: AUC saltou p/ 1.000 e
    # top_features viraram exatamente essas colunas. Ficam FORA do X:
    #   - has_order/roas: *_orders_30d, *_sales_30d, *_cvr_30d, *_roas_30d
    #     (target, campaign e product) — derivados do label de pedido/venda.
    #   - has_click: alem dos acima, *_clicks_30d, *_ctr_30d, *_spend_30d
    #     (spend = cliques x cpc, deriva do label de clique).
    # Traffic pre-clique (impressions/days) e o prior do modelo de campanha
    # (campaign_ml_*) continuam — nao derivam do label.
    if target != "has_click":
        # Pos-clique: sinais de clique/custo da PROPRIA linha sao permitidos
        # (o funil clique->pedido e contexto legitimo), e trafego 30d tambem.
        cols.extend(["ctr", "cpc",
                     "target_clicks_30d", "target_spend_30d", "target_ctr_30d",
                     "campaign_clicks_30d", "campaign_spend_30d", "campaign_ctr_30d"])
    base = df[cols].copy()
    match = pd.get_dummies(df["match_type_norm"], prefix="m")
    camp = pd.get_dummies(df["campaign_norm"], prefix="c")
    X = pd.concat([base.reset_index(drop=True), match.reset_index(drop=True), camp.reset_index(drop=True)], axis=1)
    return X.astype(float), list(X.columns)


def register(conn, name, model_type, target, status, rows, metrics):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO marketcloud_features.model_registry
                (model_name, model_version, model_type, target_name,
                 training_rows, metrics_json, feature_columns_json, status)
            VALUES (%s,'v3',%s,%s,%s,%s,%s,%s)
            ON CONFLICT ON CONSTRAINT uq_model_registry DO UPDATE SET
                model_type=EXCLUDED.model_type, target_name=EXCLUDED.target_name,
                training_rows=EXCLUDED.training_rows, metrics_json=EXCLUDED.metrics_json,
                feature_columns_json=EXCLUDED.feature_columns_json, status=EXCLUDED.status
            """,
            (name, model_type, target, rows, json.dumps(metrics), json.dumps(metrics.get("features", [])), status),
        )
        conn.commit()


def record_run_status(conn, started_at, status, rows, positive_clicks, positive_orders, predictions_written, metrics):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO marketcloud_gold.ml_hourly_run_status
                (run_kind, model_version, grain, status, training_rows,
                 positive_click_rows, positive_order_rows, predictions_written,
                 metrics_json, started_at, finished_at)
            VALUES ('hourly_target_real_v3', 'v3', 'keyword_target_hour', %s, %s, %s, %s, %s, %s, %s, NOW())
            RETURNING id
            """,
            (status, rows, positive_clicks, positive_orders, predictions_written, json.dumps(metrics), started_at),
        )
        run_id = cur.fetchone()["id"]
        conn.commit()
        return run_id


def fit_classifier(conn, df, model_name, target_col, feature_target):
    y = df[target_col].values
    pos = int(y.sum())
    neg = int(len(y) - pos)
    X, feat_cols = build_X(df, feature_target)
    metrics = {"features": feat_cols, "n": int(len(df)), "positives": pos, "negatives": neg}
    if pos < MIN_POSITIVE_CLASS or neg < MIN_NEGATIVE_CLASS:
        register(conn, model_name, "classifier:rf", target_col, "INSUFFICIENT_DATA", len(df), metrics)
        log.warning("%s: sinal insuficiente positives=%s negatives=%s", model_name, pos, neg)
        return np.full(len(df), np.nan)

    groups = df["target_entity_key"].astype(str).values
    n_groups = int(len(np.unique(groups)))
    n_splits = max(2, min(5, pos, neg, n_groups))
    clf = RandomForestClassifier(
        n_estimators=300,
        class_weight="balanced",
        min_samples_leaf=2,
        random_state=42,
        n_jobs=-1,
    )
    # HONESTIDADE DO CV (auditoria 19/07): split por GRUPO (target_entity_key).
    # O StratifiedKFold aleatorio antigo deixava linhas do MESMO target em treino
    # e teste, entao o OOF media memorizacao de propensao por entidade e inflava
    # o AUC. Group split mede generalizacao para targets nao vistos.
    if StratifiedGroupKFold is not None:
        cv = StratifiedGroupKFold(n_splits=n_splits, shuffle=True, random_state=42)
        cv_name = f"stratified_group_{n_splits}fold_oof"
    else:
        cv = GroupKFold(n_splits=n_splits)
        cv_name = f"group_{n_splits}fold_oof"
    proba = cross_val_predict(clf, X, y, cv=cv, groups=groups, method="predict_proba", n_jobs=-1)[:, 1]
    pred = (proba >= 0.5).astype(int)
    hour_rate = df.groupby("event_hour")[target_col].transform("mean").values
    auc = roc_auc_score(y, proba) if len(np.unique(y)) == 2 else np.nan
    base_auc = roc_auc_score(y, hour_rate) if len(np.unique(y)) == 2 else np.nan
    # AUC CONDICIONAL A CLIQUE: mede so as celulas com trafego real (clicks>0),
    # onde a decisao de bid importa. Remove o gate trivial "sem clique => sem
    # pedido" que dominava o AUC global. Nao se aplica ao modelo de clique.
    auc_clicked = np.nan
    n_clicked = 0
    if target_col != "has_click":
        clicked = df["clicks_pos"].values > 0
        n_clicked = int(clicked.sum())
        if n_clicked > 0 and len(np.unique(y[clicked])) == 2:
            auc_clicked = roc_auc_score(y[clicked], proba[clicked])
    metrics.update({
        "roc_auc": None if np.isnan(auc) else float(auc),
        "roc_auc_clicked_only": None if np.isnan(auc_clicked) else float(auc_clicked),
        "clicked_cells": n_clicked,
        "balanced_accuracy": float(balanced_accuracy_score(y, pred)),
        "baseline_hourrate_auc": None if np.isnan(base_auc) else float(base_auc),
        "beats_baseline": bool((not np.isnan(auc)) and (not np.isnan(base_auc)) and auc > base_auc),
        "cv": cv_name,
    })
    clf.fit(X, y)
    full = clf.predict_proba(X)[:, 1]
    imp = sorted(zip(feat_cols, clf.feature_importances_), key=lambda t: -t[1])[:8]
    metrics["top_features"] = [{"f": f, "imp": float(i)} for f, i in imp]
    register(conn, model_name, "classifier:rf", target_col, "TRAINED", len(df), metrics)
    log.info("%s: AUC=%s AUC_clicked=%s baseline=%s positives=%s cv=%s", model_name, metrics["roc_auc"], metrics.get("roc_auc_clicked_only"), metrics["baseline_hourrate_auc"], pos, cv_name)
    return full


def fit_roas(conn, df):
    y = np.minimum(df["roas"].values, ROAS_CAP)
    nonzero = int(np.sum(y > 0))
    X, feat_cols = build_X(df, "roas")
    metrics = {"features": feat_cols, "n": int(len(df)), "nonzero": nonzero}
    if nonzero < MIN_POSITIVE_CLASS:
        register(conn, "HourlyTargetExpectedRoasRealV3", "regressor:rf", "roas_capped", "INSUFFICIENT_DATA", len(df), metrics)
        log.warning("HourlyTargetExpectedRoasRealV3: variancia insuficiente nonzero=%s", nonzero)
        return np.full(len(df), np.nan)

    groups = df["target_entity_key"].astype(str).values
    n_groups = int(len(np.unique(groups)))
    n_splits = max(2, min(5, nonzero, len(df), n_groups))
    reg = RandomForestRegressor(n_estimators=300, min_samples_leaf=2, random_state=42, n_jobs=-1)
    # HONESTIDADE DO CV (auditoria 19/07): group split por target_entity_key,
    # como nos classificadores, para o MAE OOF nao memorizar entidade.
    cv = GroupKFold(n_splits=n_splits)
    oof = np.clip(cross_val_predict(reg, X, y, cv=cv, groups=groups, n_jobs=-1), 0, ROAS_CAP)
    baseline = df.groupby("event_hour")["roas"].transform("mean").clip(0, ROAS_CAP).values
    # MAE condicional a clique: erro so onde houve trafego real (decisao importa).
    clicked = df["clicks_pos"].values > 0
    n_clicked = int(clicked.sum())
    mae_clicked = float(mean_absolute_error(y[clicked], oof[clicked])) if n_clicked > 0 else None
    metrics.update({
        "mae": float(mean_absolute_error(y, oof)),
        "mae_clicked_only": mae_clicked,
        "clicked_cells": n_clicked,
        "r2": float(r2_score(y, oof)),
        "baseline_hourmean_mae": float(mean_absolute_error(y, baseline)),
        "beats_baseline": bool(mean_absolute_error(y, oof) < mean_absolute_error(y, baseline)),
        "target_mean": float(np.mean(y)),
        "cv": f"group_{n_splits}fold_oof",
    })
    reg.fit(X, y)
    full = np.clip(reg.predict(X), 0, ROAS_CAP)
    imp = sorted(zip(feat_cols, reg.feature_importances_), key=lambda t: -t[1])[:8]
    metrics["top_features"] = [{"f": f, "imp": float(i)} for f, i in imp]
    register(conn, "HourlyTargetExpectedRoasRealV3", "regressor:rf", "roas_capped", "TRAINED", len(df), metrics)
    log.info("HourlyTargetExpectedRoasRealV3: MAE=%.3f nonzero=%s", metrics["mae"], nonzero)
    return full


def write_predictions(conn, df, click_proba, conv_proba, roas_pred):
    rows = []
    for i, r in df.reset_index(drop=True).iterrows():
        cp = None if np.isnan(click_proba[i]) else round(float(click_proba[i]), 4)
        vp = None if np.isnan(conv_proba[i]) else round(float(conv_proba[i]), 4)
        er = None if np.isnan(roas_pred[i]) else round(float(roas_pred[i]), 4)
        good = None
        if vp is not None and er is not None:
            good = bool(vp >= GOOD_TARGET_CONV_PROB and er >= GOOD_TARGET_ROAS)
        elif cp is not None:
            good = bool(cp >= GOOD_TARGET_CLICK_PROB)
        rows.append((
            r["campaign_id"], r.get("campaign_name"), r.get("ad_group_id"), r.get("ad_group_name"),
            r["target_entity_key"], r.get("keyword_id"), r.get("target_id"), r.get("keyword_text"),
            r.get("targeting"), r.get("match_type"), int(r["event_hour"]), int(r["days_observed"]),
            float(r["impressions"]), float(r["clicks"]), float(r["spend"]), float(r["orders"]), float(r["sales"]),
            cp, vp, er, good,
        ))
    with conn.cursor() as cur:
        cur.execute("TRUNCATE marketcloud_gold.hourly_target_ml_predictions_v3")
        psycopg2.extras.execute_values(
            cur,
            """
            INSERT INTO marketcloud_gold.hourly_target_ml_predictions_v3
                (campaign_id, campaign_name, ad_group_id, ad_group_name, target_entity_key,
                 keyword_id, target_id, keyword_text, targeting, match_type, event_hour,
                 days_observed, impressions, clicks, spend, orders, sales,
                 click_probability, conversion_probability, expected_roas, predicted_good_target_hour)
            VALUES %s
            """,
            rows,
            page_size=300,
        )
        conn.commit()
    log.info("%s predicoes gravadas em hourly_target_ml_predictions_v3", len(rows))
    return len(rows)


def main():
    started_at = datetime.now(timezone.utc)
    conn = get_conn()
    conn.autocommit = False
    try:
        df = load(conn)
        if df.empty:
            log.warning("sem dados AMS target horarios")
            return
        log.info(
            "%s celulas target×hora | %s com clique | %s com pedido | %s targets",
            len(df), int(df["has_click"].sum()), int(df["has_order"].sum()), df["target_entity_key"].nunique(),
        )
        click_proba = fit_classifier(conn, df, "HourlyTargetClickRealV3", "has_click", "has_click")
        conv_proba = fit_classifier(conn, df, "HourlyTargetConversionRealV3", "has_order", "has_order")
        roas_pred = fit_roas(conn, df)
        predictions_written = write_predictions(conn, df, click_proba, conv_proba, roas_pred)
        click_trained = not np.isnan(click_proba).all()
        conv_trained = not np.isnan(conv_proba).all()
        roas_trained = not np.isnan(roas_pred).all()
        run_status = "COMPLETED" if click_trained and conv_trained and roas_trained else ("PARTIAL" if click_trained else "INSUFFICIENT_DATA")
        run_id = record_run_status(conn, started_at, run_status, len(df), int(df["has_click"].sum()), int(df["has_order"].sum()), predictions_written, {
            "click_model_trained": bool(click_trained),
            "conversion_model_trained": bool(conv_trained),
            "roas_model_trained": bool(roas_trained),
            "targets": int(df["target_entity_key"].nunique()),
        })
        # P1-6: carimba as predicoes target desta rodada com o run_id.
        if run_id:
            with conn.cursor() as cur:
                cur.execute("UPDATE marketcloud_gold.hourly_target_ml_predictions_v3 SET run_id=%s WHERE run_id IS NULL", (run_id,))
            conn.commit()
            log.info("predicoes target carimbadas com run_id=%s", run_id)
    except Exception:
        log.exception("erro no ML target-real v3")
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
