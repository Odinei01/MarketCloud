"""
MarketCloud ML Worker V0
Treina modelos sobre a Feature Store e persiste predições em model_predictions.

Modelos:
  HourlyBidScheduleScorerML   — target: gold_action_type (feature_hourly_campaign_adgroup)
  SearchTermActionClassifierML — target: gold_action_type (feature_search_term_daily)

Regras soberanas:
  - Advisor, não executor.
  - Nenhuma predição chama Amazon Ads API para mutação.
  - Nenhuma alteração de bid, budget ou negativas é executada aqui.

Uso:
  python marketcloud_ml_worker_v0.py
  DATABASE_URL=postgres://... python marketcloud_ml_worker_v0.py
"""

import json
import logging
import os
import pickle
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

import numpy as np
import pandas as pd
import psycopg2
import psycopg2.extras
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, classification_report
from sklearn.model_selection import train_test_split

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [ML-WORKER] %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgres://mcadmin:mcsecret@localhost:5433/marketcloud",
)
MODELS_DIR = Path(__file__).parent / "models"
MODELS_DIR.mkdir(exist_ok=True)

MODEL_VERSION = f"v0.{date.today().strftime('%Y%m%d')}"

BID_MULTIPLIER_BY_ACTION = {
    "CUT_HOUR":             0.50,
    "BID_DOWN":             0.75,
    "HOLD":                 1.00,
    "WATCH":                1.00,
    "BID_UP":               1.20,
    "ADD_NEGATIVE_EXACT":   0.00,
    "ADD_NEGATIVE_PHRASE":  0.00,
    "HARVEST_SEARCH_TERM":  1.00,
    "MOVE_TO_EXACT":        1.00,
    "REDUCE_BID":           0.75,
    "PAUSE_TARGET":         0.50,
}

RISK_BY_ACTION = {
    "CUT_HOUR":             "HIGH",
    "BID_DOWN":             "HIGH",
    "PAUSE_TARGET":         "HIGH",
    "ADD_NEGATIVE_EXACT":   "HIGH",
    "ADD_NEGATIVE_PHRASE":  "HIGH",
    "BID_UP":               "LOW",
    "SCALE_CAMPAIGN":       "LOW",
    "HARVEST_SEARCH_TERM":  "LOW",
    "MOVE_TO_EXACT":        "LOW",
    "HOLD":                 "MEDIUM",
    "WATCH":                "MEDIUM",
}


# ─────────────────────────────────────────────────────────────────────────────
# DB helpers
# ─────────────────────────────────────────────────────────────────────────────

def get_conn():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def native(val):
    """Convert numpy/pandas/psycopg2 types to JSON-serialisable Python natives."""
    if isinstance(val, (np.integer,)):
        return int(val)
    if isinstance(val, (np.floating, Decimal)):
        return float(val)
    if isinstance(val, (np.bool_,)):
        return bool(val)
    if isinstance(val, float) and (np.isnan(val) or np.isinf(val)):
        return None
    if isinstance(val, pd.Timestamp):
        return val.isoformat()
    return val


def row_to_json(row: dict) -> dict:
    return {k: native(v) for k, v in row.items()}


# ─────────────────────────────────────────────────────────────────────────────
# Model persistence
# ─────────────────────────────────────────────────────────────────────────────

def save_model(model, name: str, version: str) -> str:
    path = MODELS_DIR / f"{name}_{version}.pkl"
    with open(path, "wb") as f:
        pickle.dump(model, f)
    return str(path)


def register_model(
    conn,
    model_name: str,
    model_version: str,
    model_type: str,
    target_name: str,
    status: str,
    training_rows: int = 0,
    metrics_json: dict = None,
    feature_columns: list = None,
    artifact_path: str = None,
    window_start: date = None,
    window_end: date = None,
) -> int:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO marketcloud_features.model_registry
                (model_name, model_version, model_type, target_name,
                 training_window_start, training_window_end,
                 training_rows, metrics_json, feature_columns_json,
                 artifact_path, status)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT ON CONSTRAINT uq_model_registry
            DO UPDATE SET
                status               = EXCLUDED.status,
                training_rows        = EXCLUDED.training_rows,
                metrics_json         = EXCLUDED.metrics_json,
                feature_columns_json = EXCLUDED.feature_columns_json,
                artifact_path        = EXCLUDED.artifact_path,
                training_window_start = EXCLUDED.training_window_start,
                training_window_end  = EXCLUDED.training_window_end
            RETURNING model_id
            """,
            (
                model_name, model_version, model_type, target_name,
                window_start, window_end,
                training_rows,
                json.dumps(metrics_json or {}),
                json.dumps(feature_columns or []),
                artifact_path,
                status,
            ),
        )
        row = cur.fetchone()
        conn.commit()
        return row["model_id"]


# ─────────────────────────────────────────────────────────────────────────────
# Prediction persistence
# ─────────────────────────────────────────────────────────────────────────────

def insert_predictions(conn, rows: list[dict]):
    if not rows:
        return
    with conn.cursor() as cur:
        psycopg2.extras.execute_values(
            cur,
            """
            INSERT INTO marketcloud_features.model_predictions (
                tenant_id, amc_instance_id, ads_profile_id,
                model_name, model_version,
                prediction_date,
                entity_type, entity_key,
                campaign_id, campaign_name, ad_product_type,
                ad_group_name, event_hour, customer_search_term,
                gold_action_type,
                predicted_action_type, predicted_bid_multiplier,
                conversion_probability,
                expected_orders, expected_sales, expected_roas,
                confidence_score, prediction_risk_level,
                features_snapshot, prediction_evidence_json
            ) VALUES %s
            """,
            [
                (
                    r["tenant_id"], r["amc_instance_id"], r["ads_profile_id"],
                    r["model_name"], r["model_version"],
                    r["prediction_date"],
                    r["entity_type"], r["entity_key"],
                    r.get("campaign_id"), r.get("campaign_name"), r.get("ad_product_type"),
                    r.get("ad_group_name"), r.get("event_hour"), r.get("customer_search_term"),
                    r.get("gold_action_type"),
                    r["predicted_action_type"], r["predicted_bid_multiplier"],
                    r.get("conversion_probability"),
                    r.get("expected_orders"), r.get("expected_sales"), r.get("expected_roas"),
                    r["confidence_score"], r["prediction_risk_level"],
                    json.dumps(r.get("features_snapshot") or {}),
                    json.dumps(r.get("prediction_evidence_json") or {}),
                )
                for r in rows
            ],
            page_size=200,
        )
        conn.commit()
    log.info(f"Inserted {len(rows)} predictions")


# ─────────────────────────────────────────────────────────────────────────────
# Modelo 1 — HourlyBidScheduleScorerML
# ─────────────────────────────────────────────────────────────────────────────

HOURLY_MODEL_NAME   = "HourlyBidScheduleScorerML"
HOURLY_MIN_ROWS     = 50
HOURLY_MIN_CLASSES  = 2

HOURLY_FEATURES = [
    "event_hour", "sample_days",
    "impressions_35d", "clicks_35d", "spend_35d", "orders_35d",
    "sales_35d", "combined_sales_35d",
    "ctr_35d", "cpc_35d", "roas_35d", "total_roas_35d",
    "acos_35d", "conversion_rate_35d", "cpa_35d", "aov_35d",
    "is_madrugada", "is_manha", "is_tarde", "is_noite",
    "has_spend", "has_click", "has_order", "has_sale",
]


def run_hourly_model(conn):
    log.info(f"=== {HOURLY_MODEL_NAME} ===")

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT
                tenant_id, amc_instance_id, ads_profile_id, feature_date,
                campaign_id, campaign_name, ad_product_type, ad_group_name,
                event_hour, day_part, sample_days,
                impressions_35d, clicks_35d, spend_35d, orders_35d,
                sales_35d, combined_sales_35d,
                ctr_35d, cpc_35d, roas_35d, total_roas_35d,
                acos_35d, conversion_rate_35d, cpa_35d, aov_35d,
                has_spend, has_click, has_order, has_sale,
                is_madrugada, is_manha, is_tarde, is_noite,
                gold_action_type, gold_bid_multiplier, gold_evidence_json
            FROM marketcloud_features.feature_hourly_campaign_adgroup
            WHERE feature_date = CURRENT_DATE
            """
        )
        rows = cur.fetchall()

    df = pd.DataFrame([dict(r) for r in rows])
    log.info(f"Loaded {len(df)} rows from feature_hourly_campaign_adgroup")

    if df.empty:
        log.warning("Feature table empty — skipping")
        register_model(
            conn, HOURLY_MODEL_NAME, MODEL_VERSION,
            "RandomForestClassifier", "gold_action_type",
            status="INSUFFICIENT_DATA",
        )
        return

    # Encode booleans as int
    bool_cols = ["is_madrugada", "is_manha", "is_tarde", "is_noite",
                 "has_spend", "has_click", "has_order", "has_sale"]
    for col in bool_cols:
        df[col] = df[col].astype(int)

    df_train = df[df["gold_action_type"].notna()].copy()
    n_rows = len(df_train)
    n_classes = df_train["gold_action_type"].nunique()

    log.info(f"Training rows={n_rows}, classes={n_classes}: {df_train['gold_action_type'].unique()}")

    if n_rows < HOURLY_MIN_ROWS:
        log.warning(f"Insufficient data ({n_rows} < {HOURLY_MIN_ROWS}) — not training")
        register_model(
            conn, HOURLY_MODEL_NAME, MODEL_VERSION,
            "RandomForestClassifier", "gold_action_type",
            status="INSUFFICIENT_DATA",
            training_rows=n_rows,
        )
        return

    if n_classes < HOURLY_MIN_CLASSES:
        log.warning(f"Single class only ({n_classes}) — not training")
        register_model(
            conn, HOURLY_MODEL_NAME, MODEL_VERSION,
            "RandomForestClassifier", "gold_action_type",
            status="SINGLE_CLASS_ONLY",
            training_rows=n_rows,
        )
        return

    X = df_train[HOURLY_FEATURES].fillna(0).astype(float)
    y = df_train["gold_action_type"]

    can_stratify = (y.value_counts() >= 2).all()
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.20, random_state=42,
        stratify=y if (n_classes > 1 and can_stratify) else None,
    )

    clf = RandomForestClassifier(
        n_estimators=100,
        class_weight="balanced",
        random_state=42,
        n_jobs=-1,
    )
    clf.fit(X_train, y_train)

    y_pred = clf.predict(X_test)
    accuracy = float(accuracy_score(y_test, y_pred))
    report = classification_report(y_test, y_pred, output_dict=True, zero_division=0)

    log.info(f"Test accuracy: {accuracy:.4f}")

    feature_importances = dict(
        sorted(zip(HOURLY_FEATURES, clf.feature_importances_), key=lambda x: -x[1])[:10]
    )
    metrics = {
        "accuracy": accuracy,
        "test_rows": len(X_test),
        "train_rows": len(X_train),
        "classes": list(clf.classes_),
        "top10_feature_importances": {k: float(v) for k, v in feature_importances.items()},
        "classification_report": report,
    }

    artifact_path = save_model(clf, HOURLY_MODEL_NAME, MODEL_VERSION)
    window_start_date = df_train["feature_date"].min()
    window_end_date   = df_train["feature_date"].max()

    model_id = register_model(
        conn, HOURLY_MODEL_NAME, MODEL_VERSION,
        "RandomForestClassifier", "gold_action_type",
        status="TRAINED",
        training_rows=n_rows,
        metrics_json=metrics,
        feature_columns=HOURLY_FEATURES,
        artifact_path=artifact_path,
        window_start=window_start_date,
        window_end=window_end_date,
    )
    log.info(f"Registered model_id={model_id} artifact={artifact_path}")

    # Predict on all feature rows (full df, not just train split)
    X_all = df[HOURLY_FEATURES].fillna(0).astype(float)
    predicted_classes = clf.predict(X_all)
    predicted_probas  = clf.predict_proba(X_all)
    class_labels      = list(clf.classes_)

    prediction_rows = []
    for i, (_, row) in enumerate(df.iterrows()):
        pred_class   = predicted_classes[i]
        proba_vector = predicted_probas[i]
        conf_score   = float(np.max(proba_vector))
        prob_by_class = {class_labels[j]: float(proba_vector[j]) for j in range(len(class_labels))}

        entity_key = "|".join([
            str(row["campaign_id"]),
            str(row["ad_product_type"]),
            str(row["ad_group_name"]),
            str(row["event_hour"]),
        ])

        features_snap = row_to_json(
            {col: row[col] for col in HOURLY_FEATURES}
        )

        evidence = {
            "model": HOURLY_MODEL_NAME,
            "version": MODEL_VERSION,
            "gold_action_type": row.get("gold_action_type"),
            "predicted_action_type": pred_class,
            "agreement": pred_class == row.get("gold_action_type"),
            "probabilities": prob_by_class,
            "top5_importances": dict(list(feature_importances.items())[:5]),
        }

        prediction_rows.append({
            "tenant_id":       row["tenant_id"],
            "amc_instance_id": row["amc_instance_id"],
            "ads_profile_id":  row["ads_profile_id"],
            "model_name":      HOURLY_MODEL_NAME,
            "model_version":   MODEL_VERSION,
            "prediction_date": date.today(),
            "entity_type":     "HOURLY_CAMPAIGN_ADGROUP",
            "entity_key":      entity_key,
            "campaign_id":     row.get("campaign_id"),
            "campaign_name":   row.get("campaign_name"),
            "ad_product_type": row.get("ad_product_type"),
            "ad_group_name":   row.get("ad_group_name"),
            "event_hour":      int(row["event_hour"]),
            "customer_search_term": None,
            "gold_action_type":     row.get("gold_action_type"),
            "predicted_action_type":    pred_class,
            "predicted_bid_multiplier": BID_MULTIPLIER_BY_ACTION.get(pred_class, 1.00),
            "conversion_probability":   prob_by_class.get("BID_UP", 0.0),
            "expected_orders":  native(row.get("orders_35d")),
            "expected_sales":   native(row.get("sales_35d")),
            "expected_roas":    native(row.get("roas_35d")),
            "confidence_score": conf_score,
            "prediction_risk_level": RISK_BY_ACTION.get(pred_class, "MEDIUM"),
            "features_snapshot":       features_snap,
            "prediction_evidence_json": evidence,
        })

    insert_predictions(conn, prediction_rows)
    log.info(f"{HOURLY_MODEL_NAME}: {len(prediction_rows)} predictions written")


# ─────────────────────────────────────────────────────────────────────────────
# Modelo 2 — SearchTermActionClassifierML
# ─────────────────────────────────────────────────────────────────────────────

ST_MODEL_NAME   = "SearchTermActionClassifierML"
ST_MIN_ROWS     = 30
ST_MIN_CLASSES  = 2

ST_FEATURES = [
    "term_length", "term_word_count",
    "impressions_35d", "clicks_35d", "spend_35d", "orders_35d",
    "sales_35d", "combined_sales_35d",
    "ctr_35d", "cpc_35d", "roas_35d", "total_roas_35d",
    "acos_35d", "conversion_rate_35d", "cpa_35d", "aov_35d",
    "is_branded_zanom",
]


def run_search_term_model(conn):
    log.info(f"=== {ST_MODEL_NAME} ===")

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT
                tenant_id, amc_instance_id, ads_profile_id, feature_date,
                campaign_id, campaign_name, ad_product_type,
                ad_group_name, targeting, match_type,
                customer_search_term, search_term_normalized,
                term_length, term_word_count, is_branded_zanom,
                impressions_35d, clicks_35d, spend_35d, orders_35d,
                sales_35d, combined_sales_35d,
                ctr_35d, cpc_35d, roas_35d, total_roas_35d,
                acos_35d, conversion_rate_35d, cpa_35d, aov_35d,
                gold_action_type, gold_risk_level, gold_evidence_json
            FROM marketcloud_features.feature_search_term_daily
            WHERE feature_date = CURRENT_DATE
            """
        )
        rows = cur.fetchall()

    df = pd.DataFrame([dict(r) for r in rows])
    log.info(f"Loaded {len(df)} rows from feature_search_term_daily")

    if df.empty:
        log.warning("Feature table empty — skipping")
        register_model(
            conn, ST_MODEL_NAME, MODEL_VERSION,
            "RandomForestClassifier", "gold_action_type",
            status="INSUFFICIENT_DATA",
        )
        return

    # Encode boolean
    df["is_branded_zanom"] = df["is_branded_zanom"].astype(int)

    df_train = df[df["gold_action_type"].notna()].copy()
    n_rows   = len(df_train)
    n_classes = df_train["gold_action_type"].nunique()

    log.info(f"Training rows={n_rows}, classes={n_classes}: {df_train['gold_action_type'].unique()}")

    if n_rows < ST_MIN_ROWS:
        log.warning(f"Insufficient data ({n_rows} < {ST_MIN_ROWS}) — not training")
        register_model(
            conn, ST_MODEL_NAME, MODEL_VERSION,
            "RandomForestClassifier", "gold_action_type",
            status="INSUFFICIENT_DATA",
            training_rows=n_rows,
        )
        return

    if n_classes < ST_MIN_CLASSES:
        log.warning(f"Single class only ({n_classes}) — not training")
        register_model(
            conn, ST_MODEL_NAME, MODEL_VERSION,
            "RandomForestClassifier", "gold_action_type",
            status="SINGLE_CLASS_ONLY",
            training_rows=n_rows,
        )
        return

    X = df_train[ST_FEATURES].fillna(0).astype(float)
    y = df_train["gold_action_type"]

    can_stratify = (y.value_counts() >= 2).all()
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.20, random_state=42,
        stratify=y if (n_classes > 1 and can_stratify) else None,
    )

    clf = RandomForestClassifier(
        n_estimators=100,
        class_weight="balanced",
        random_state=42,
        n_jobs=-1,
    )
    clf.fit(X_train, y_train)

    y_pred   = clf.predict(X_test)
    accuracy = float(accuracy_score(y_test, y_pred))
    report   = classification_report(y_test, y_pred, output_dict=True, zero_division=0)

    log.info(f"Test accuracy: {accuracy:.4f}")

    feature_importances = dict(
        sorted(zip(ST_FEATURES, clf.feature_importances_), key=lambda x: -x[1])[:10]
    )
    metrics = {
        "accuracy": accuracy,
        "test_rows": len(X_test),
        "train_rows": len(X_train),
        "classes": list(clf.classes_),
        "top10_feature_importances": {k: float(v) for k, v in feature_importances.items()},
        "classification_report": report,
    }

    artifact_path = save_model(clf, ST_MODEL_NAME, MODEL_VERSION)

    model_id = register_model(
        conn, ST_MODEL_NAME, MODEL_VERSION,
        "RandomForestClassifier", "gold_action_type",
        status="TRAINED",
        training_rows=n_rows,
        metrics_json=metrics,
        feature_columns=ST_FEATURES,
        artifact_path=artifact_path,
        window_start=df_train["feature_date"].min(),
        window_end=df_train["feature_date"].max(),
    )
    log.info(f"Registered model_id={model_id} artifact={artifact_path}")

    X_all = df[ST_FEATURES].fillna(0).astype(float)
    predicted_classes = clf.predict(X_all)
    predicted_probas  = clf.predict_proba(X_all)
    class_labels      = list(clf.classes_)

    prediction_rows = []
    for i, (_, row) in enumerate(df.iterrows()):
        pred_class   = predicted_classes[i]
        proba_vector = predicted_probas[i]
        conf_score   = float(np.max(proba_vector))
        prob_by_class = {class_labels[j]: float(proba_vector[j]) for j in range(len(class_labels))}

        entity_key = "|".join([
            str(row["campaign_id"]),
            str(row["ad_product_type"]),
            str(row["search_term_normalized"]),
        ])

        features_snap = row_to_json({col: row[col] for col in ST_FEATURES})

        evidence = {
            "model": ST_MODEL_NAME,
            "version": MODEL_VERSION,
            "gold_action_type": row.get("gold_action_type"),
            "predicted_action_type": pred_class,
            "agreement": pred_class == row.get("gold_action_type"),
            "probabilities": prob_by_class,
            "top5_importances": dict(list(feature_importances.items())[:5]),
        }

        prediction_rows.append({
            "tenant_id":       row["tenant_id"],
            "amc_instance_id": row["amc_instance_id"],
            "ads_profile_id":  row["ads_profile_id"],
            "model_name":      ST_MODEL_NAME,
            "model_version":   MODEL_VERSION,
            "prediction_date": date.today(),
            "entity_type":     "SEARCH_TERM",
            "entity_key":      entity_key,
            "campaign_id":     row.get("campaign_id"),
            "campaign_name":   row.get("campaign_name"),
            "ad_product_type": row.get("ad_product_type"),
            "ad_group_name":   row.get("ad_group_name"),
            "event_hour":      None,
            "customer_search_term": row.get("customer_search_term"),
            "gold_action_type":     row.get("gold_action_type"),
            "predicted_action_type":    pred_class,
            "predicted_bid_multiplier": BID_MULTIPLIER_BY_ACTION.get(pred_class, 1.00),
            "conversion_probability":   prob_by_class.get("HARVEST_SEARCH_TERM", 0.0),
            "expected_orders":  native(row.get("orders_35d")),
            "expected_sales":   native(row.get("sales_35d")),
            "expected_roas":    native(row.get("roas_35d")),
            "confidence_score": conf_score,
            "prediction_risk_level": RISK_BY_ACTION.get(pred_class, "MEDIUM"),
            "features_snapshot":       features_snap,
            "prediction_evidence_json": evidence,
        })

    insert_predictions(conn, prediction_rows)
    log.info(f"{ST_MODEL_NAME}: {len(prediction_rows)} predictions written")


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main():
    log.info("MarketCloud ML Worker V0 starting")
    log.info(f"  MODEL_VERSION : {MODEL_VERSION}")
    log.info(f"  DATABASE_URL  : {DATABASE_URL.split('@')[-1]}")
    log.info(f"  MODELS_DIR    : {MODELS_DIR}")

    conn = get_conn()
    conn.autocommit = False

    try:
        run_hourly_model(conn)
        run_search_term_model(conn)
    except Exception:
        log.exception("Unhandled error in ML worker")
        conn.rollback()
        raise
    finally:
        conn.close()

    log.info("ML Worker V0 finished")


if __name__ == "__main__":
    main()
