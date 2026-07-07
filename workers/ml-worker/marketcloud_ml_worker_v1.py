"""
MarketCloud ML Worker V1 — Robust ML
Sai de "replicador de regra Gold" para camada preditiva.

Modelos:
  HourlyBidActionClassifierV1        target: gold_action_type   (multi-class)
  HourlyConversionProbabilityModelV1 target: has_order_7d       (binário, prob calibrada)
  ExpectedRoasRegressorV1            target: roas_7d_capped      (regressão)

Fonte: marketcloud_features.feature_hourly_windows_v1

Regra soberana: advisor. Não executa bid, budget ou negativa.
Guardrails aplicados antes de persistir predições.
"""

import json
import logging
import os
import pickle
from datetime import date
from decimal import Decimal
from pathlib import Path

import numpy as np
import pandas as pd
import psycopg2
import psycopg2.extras
from sklearn.calibration import CalibratedClassifierCV
from sklearn.inspection import permutation_importance
from sklearn.ensemble import (
    ExtraTreesClassifier,
    HistGradientBoostingClassifier,
    HistGradientBoostingRegressor,
    RandomForestClassifier,
    RandomForestRegressor,
)
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    accuracy_score,
    balanced_accuracy_score,
    classification_report,
    confusion_matrix,
    f1_score,
    mean_absolute_error,
    mean_squared_error,
    precision_score,
    r2_score,
    recall_score,
)
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

logging.basicConfig(level=logging.INFO, format="%(asctime)s [ML-V1] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgres://mcadmin:mcsecret@localhost:5433/marketcloud")
MODELS_DIR = Path(__file__).parent / "models"
MODELS_DIR.mkdir(exist_ok=True)

MODEL_VERSION = "v1"
SOURCE_TABLE = "marketcloud_features.feature_hourly_windows_v1"
ENTITY_TYPE = "HOURLY_CAMPAIGN_ADGROUP"
ROAS_CAP = 20.0

BID_MULTIPLIER_BY_ACTION = {
    "CUT_HOUR": 0.50, "BID_DOWN": 0.75, "HOLD": 1.00, "WATCH": 1.00, "BID_UP": 1.20,
}
RISK_BY_ACTION = {
    "CUT_HOUR": "HIGH", "BID_DOWN": "HIGH", "BID_UP": "LOW", "HOLD": "MEDIUM", "WATCH": "MEDIUM",
}

FEATURES = [
    "event_hour",
    "sample_days_1d", "sample_days_3d", "sample_days_7d", "sample_days_14d", "sample_days_35d",
    "spend_1d", "spend_3d", "spend_7d", "spend_14d", "spend_35d",
    "clicks_1d", "clicks_3d", "clicks_7d", "clicks_14d", "clicks_35d",
    "impressions_1d", "impressions_3d", "impressions_7d", "impressions_14d", "impressions_35d",
    "orders_1d", "orders_3d", "orders_7d", "orders_14d", "orders_35d",
    "sales_1d", "sales_3d", "sales_7d", "sales_14d", "sales_35d",
    "ctr_7d", "cpc_7d", "roas_7d", "acos_7d", "conversion_rate_7d", "cpa_7d", "aov_7d",
    "ctr_35d", "cpc_35d", "roas_35d", "acos_35d", "conversion_rate_35d", "cpa_35d", "aov_35d",
    "spend_delta_7d_vs_35d", "clicks_delta_7d_vs_35d", "orders_delta_7d_vs_35d",
    "sales_delta_7d_vs_35d", "roas_delta_7d_vs_35d", "cpc_delta_7d_vs_35d",
    "ctr_delta_7d_vs_35d", "conversion_rate_delta_7d_vs_35d",
    "has_spend_7d", "has_click_7d", "has_order_7d", "has_sale_7d",
    "is_madrugada", "is_manha", "is_tarde", "is_noite",
]
BOOL_COLS = [
    "has_spend_7d", "has_click_7d", "has_order_7d", "has_sale_7d",
    "is_madrugada", "is_manha", "is_tarde", "is_noite",
]

MIN_ROWS = 50
MIN_CLASSES = 2
# Modelos de resultado real (conversão, ROAS) exigem sinal mínimo na classe/valor
# minoritário. Sem isso, o test split degenera (uma classe só) e as métricas
# viram artefato (bal_acc=1.0, rmse=0.0). Robustez = recusar treinar nesse caso.
MIN_POSITIVE = 10


# ── infra ────────────────────────────────────────────────────────────────────

def get_conn():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def native(v):
    if isinstance(v, np.integer):
        return int(v)
    if isinstance(v, (np.floating, Decimal)):
        return float(v)
    if isinstance(v, np.bool_):
        return bool(v)
    if isinstance(v, float) and (np.isnan(v) or np.isinf(v)):
        return None
    return v


def load_features(conn) -> pd.DataFrame:
    with conn.cursor() as cur:
        cur.execute(f"SELECT * FROM {SOURCE_TABLE} WHERE feature_date = CURRENT_DATE")
        rows = cur.fetchall()
    df = pd.DataFrame([dict(r) for r in rows])
    if df.empty:
        return df
    for c in FEATURES:
        if c in BOOL_COLS:
            df[c] = df[c].astype(bool).astype(int)
        else:
            df[c] = pd.to_numeric(df[c], errors="coerce").fillna(0.0).astype(float)
    return df


def build_matrix(df: pd.DataFrame) -> pd.DataFrame:
    return df[FEATURES].fillna(0).astype(float)


def temporal_or_random_split(df, y):
    """Split temporal quando há múltiplas feature_date; senão train_test_split
    com stratify apenas se todas as classes tiverem >= 2 exemplos."""
    dates = sorted(pd.to_datetime(df["feature_date"]).dt.date.unique())
    if len(dates) >= 2:
        test_date = dates[-1]
        train_mask = pd.to_datetime(df["feature_date"]).dt.date < test_date
        if train_mask.sum() > 0 and (~train_mask).sum() > 0:
            return train_mask.values, (~train_mask).values, "temporal"
    # fallback aleatório
    n = len(df)
    idx = np.arange(n)
    stratify = None
    if y is not None:
        vc = pd.Series(y).value_counts()
        if len(vc) >= 2 and (vc >= 2).all():
            stratify = y
    tr, te = train_test_split(idx, test_size=0.20, random_state=42, stratify=stratify)
    train_mask = np.zeros(n, dtype=bool); train_mask[tr] = True
    test_mask = np.zeros(n, dtype=bool); test_mask[te] = True
    return train_mask, test_mask, "random"


def save_model(model, name):
    path = MODELS_DIR / f"{name}_{MODEL_VERSION}.pkl"
    with open(path, "wb") as f:
        pickle.dump(model, f)
    return str(path)


def register_model(conn, name, model_type, target, status, **kw):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO marketcloud_features.model_registry
                (model_name, model_version, model_type, target_name,
                 training_window_start, training_window_end, training_rows,
                 metrics_json, feature_columns_json, artifact_path, status)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            ON CONFLICT ON CONSTRAINT uq_model_registry DO UPDATE SET
                model_type=EXCLUDED.model_type, target_name=EXCLUDED.target_name,
                training_window_start=EXCLUDED.training_window_start,
                training_window_end=EXCLUDED.training_window_end,
                training_rows=EXCLUDED.training_rows, metrics_json=EXCLUDED.metrics_json,
                feature_columns_json=EXCLUDED.feature_columns_json,
                artifact_path=EXCLUDED.artifact_path, status=EXCLUDED.status
            """,
            (name, MODEL_VERSION, model_type, target,
             kw.get("window_start"), kw.get("window_end"), kw.get("training_rows", 0),
             json.dumps(kw.get("metrics", {})), json.dumps(kw.get("features", [])),
             kw.get("artifact_path"), status),
        )
        conn.commit()


def register_training_dataset(conn, name, target, row_count, class_dist, window):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO marketcloud_features.training_datasets
                (dataset_name, dataset_version, entity_type, target_name, source_table,
                 row_count, class_distribution_json, feature_columns_json,
                 train_start_date, train_end_date)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            ON CONFLICT ON CONSTRAINT uq_training_datasets DO UPDATE SET
                row_count=EXCLUDED.row_count,
                class_distribution_json=EXCLUDED.class_distribution_json,
                feature_columns_json=EXCLUDED.feature_columns_json,
                train_start_date=EXCLUDED.train_start_date,
                train_end_date=EXCLUDED.train_end_date
            """,
            (name, MODEL_VERSION, ENTITY_TYPE, target, SOURCE_TABLE,
             row_count, json.dumps(class_dist), json.dumps(FEATURES),
             window[0], window[1]),
        )
        conn.commit()


def clear_predictions(conn, model_name):
    with conn.cursor() as cur:
        cur.execute(
            "DELETE FROM marketcloud_features.model_predictions "
            "WHERE model_name=%s AND model_version=%s AND prediction_date=CURRENT_DATE",
            (model_name, MODEL_VERSION),
        )
        conn.commit()


def insert_predictions(conn, rows):
    if not rows:
        return
    with conn.cursor() as cur:
        psycopg2.extras.execute_values(
            cur,
            """
            INSERT INTO marketcloud_features.model_predictions (
                tenant_id, amc_instance_id, ads_profile_id,
                model_name, model_version, prediction_date,
                entity_type, entity_key,
                campaign_id, campaign_name, ad_product_type, ad_group_name, event_hour,
                gold_action_type, predicted_action_type, predicted_bid_multiplier,
                conversion_probability, expected_orders, expected_sales, expected_roas,
                confidence_score, prediction_risk_level,
                features_snapshot, prediction_evidence_json
            ) VALUES %s
            """,
            [(
                r["tenant_id"], r["amc_instance_id"], r["ads_profile_id"],
                r["model_name"], MODEL_VERSION, r["prediction_date"],
                ENTITY_TYPE, r["entity_key"],
                r.get("campaign_id"), r.get("campaign_name"), r.get("ad_product_type"),
                r.get("ad_group_name"), r.get("event_hour"),
                r.get("gold_action_type"), r.get("predicted_action_type"),
                r.get("predicted_bid_multiplier"),
                r.get("conversion_probability"), r.get("expected_orders"),
                r.get("expected_sales"), r.get("expected_roas"),
                r.get("confidence_score"), r.get("prediction_risk_level"),
                json.dumps(r.get("features_snapshot") or {}),
                json.dumps(r.get("prediction_evidence_json") or {}),
            ) for r in rows],
            page_size=200,
        )
        conn.commit()


# ── métricas ─────────────────────────────────────────────────────────────────

def classification_metrics(y_true, y_pred, classes):
    return {
        "accuracy": float(accuracy_score(y_true, y_pred)),
        "balanced_accuracy": float(balanced_accuracy_score(y_true, y_pred)),
        "macro_f1": float(f1_score(y_true, y_pred, average="macro", zero_division=0)),
        "weighted_f1": float(f1_score(y_true, y_pred, average="weighted", zero_division=0)),
        "precision_macro": float(precision_score(y_true, y_pred, average="macro", zero_division=0)),
        "recall_macro": float(recall_score(y_true, y_pred, average="macro", zero_division=0)),
        "class_distribution": {str(k): int(v) for k, v in pd.Series(y_true).value_counts().items()},
        "confusion_matrix": confusion_matrix(y_true, y_pred, labels=classes).tolist(),
        "classification_report": classification_report(y_true, y_pred, output_dict=True, zero_division=0),
    }


def regression_metrics(y_true, y_pred):
    return {
        "mae": float(mean_absolute_error(y_true, y_pred)),
        "rmse": float(np.sqrt(mean_squared_error(y_true, y_pred))),
        "r2": float(r2_score(y_true, y_pred)) if len(set(y_true)) > 1 else 0.0,
        "target_mean": float(np.mean(y_true)),
        "target_median": float(np.median(y_true)),
        "target_p95": float(np.percentile(y_true, 95)),
    }


def feature_importance(model, X=None, y=None):
    est = model
    if isinstance(model, Pipeline):
        est = model.steps[-1][1]
    # 1) importância nativa (tree-based clássico)
    if hasattr(est, "feature_importances_"):
        pairs = sorted(zip(FEATURES, est.feature_importances_), key=lambda x: -x[1])[:15]
        return [{"feature": f, "importance": float(i)} for f, i in pairs]
    # 2) fallback: permutation importance (ex.: HistGradientBoosting) — requer X,y
    if X is not None and y is not None:
        try:
            r = permutation_importance(model, X, y, n_repeats=5, random_state=42, n_jobs=-1)
            pairs = sorted(zip(FEATURES, r.importances_mean), key=lambda x: -x[1])[:15]
            return [{"feature": f, "importance": float(i), "method": "permutation"} for f, i in pairs]
        except Exception:
            pass
    return "feature_importance_unavailable"


# ── modelo 1: action classifier ──────────────────────────────────────────────

def run_action_classifier(conn, df):
    name = "HourlyBidActionClassifierV1"
    log.info(f"=== {name} ===")
    clear_predictions(conn, name)  # limpa predições antigas; só re-grava se treinar
    train_df = df[df["gold_action_type"].notna()].copy()
    n, classes = len(train_df), train_df["gold_action_type"].nunique()
    window = (df["feature_date"].min(), df["feature_date"].max())
    class_dist = {str(k): int(v) for k, v in train_df["gold_action_type"].value_counts().items()}
    register_training_dataset(conn, "hourly_action_v1", "gold_action_type", n, class_dist, window)

    if n < MIN_ROWS:
        register_model(conn, name, "classifier", "gold_action_type", "INSUFFICIENT_DATA", training_rows=n)
        return
    if classes < MIN_CLASSES:
        register_model(conn, name, "classifier", "gold_action_type", "SINGLE_CLASS_ONLY", training_rows=n)
        return

    X = build_matrix(train_df)
    y = train_df["gold_action_type"].values
    tr, te, split_mode = temporal_or_random_split(train_df, y)
    Xtr, Xte, ytr, yte = X[tr], X[te], y[tr], y[te]

    candidates = {
        "random_forest": RandomForestClassifier(n_estimators=200, class_weight="balanced", random_state=42, n_jobs=-1),
        "extra_trees": ExtraTreesClassifier(n_estimators=200, class_weight="balanced", random_state=42, n_jobs=-1),
        "hist_gradient_boosting": HistGradientBoostingClassifier(random_state=42),
        "logistic_regression": Pipeline([
            ("scale", StandardScaler()),
            ("clf", LogisticRegression(max_iter=2000, class_weight="balanced", multi_class="auto")),
        ]),
    }
    labels = sorted(set(y))
    best_name, best_model, best_metrics, best_score = None, None, None, (-1.0, -1.0)
    leaderboard = {}
    for cand_name, est in candidates.items():
        try:
            est.fit(Xtr, ytr)
            pred = est.predict(Xte)
            m = classification_metrics(yte, pred, labels)
            leaderboard[cand_name] = {"balanced_accuracy": m["balanced_accuracy"], "macro_f1": m["macro_f1"]}
            score = (m["balanced_accuracy"], m["macro_f1"])
            if score > best_score:
                best_score, best_name, best_model, best_metrics = score, cand_name, est, m
        except Exception as e:
            leaderboard[cand_name] = {"error": str(e)[:200]}
            log.warning(f"{name}: candidato {cand_name} falhou: {e}")

    if best_model is None:
        register_model(conn, name, "classifier", "gold_action_type", "FAILED", training_rows=n)
        return

    best_metrics["split_mode"] = split_mode
    best_metrics["chosen_model"] = best_name
    best_metrics["leaderboard"] = leaderboard
    best_metrics["top_features"] = feature_importance(best_model, Xte, yte)
    artifact = save_model(best_model, name)
    register_model(conn, name, f"classifier:{best_name}", "gold_action_type", "TRAINED",
                   training_rows=n, metrics=best_metrics, features=FEATURES,
                   artifact_path=artifact, window_start=window[0], window_end=window[1])
    log.info(f"{name}: melhor={best_name} bal_acc={best_metrics['balanced_accuracy']:.3f} macro_f1={best_metrics['macro_f1']:.3f}")

    # predições (todas as linhas)
    Xall = build_matrix(df)
    preds = best_model.predict(Xall)
    probas = best_model.predict_proba(Xall)
    model_classes = list(best_model.classes_)
    out = []
    for i, (_, row) in enumerate(df.iterrows()):
        pred = str(preds[i])
        conf = float(np.clip(np.max(probas[i]), 0.0, 1.0))
        # guardrail 3: sem BID_UP se sem spend/orders no 35d
        overridden = False
        if pred == "BID_UP" and float(row["spend_35d"]) == 0 and float(row["orders_35d"]) == 0:
            pred, overridden = "WATCH", True
        out.append({
            "tenant_id": row["tenant_id"], "amc_instance_id": row["amc_instance_id"],
            "ads_profile_id": row["ads_profile_id"], "model_name": name,
            "prediction_date": date.today(),
            "entity_key": f'{row["campaign_id"]}|{row["ad_product_type"]}|{row["ad_group_name"]}|{row["event_hour"]}',
            "campaign_id": row["campaign_id"], "campaign_name": row["campaign_name"],
            "ad_product_type": row["ad_product_type"], "ad_group_name": row["ad_group_name"],
            "event_hour": int(row["event_hour"]), "gold_action_type": row.get("gold_action_type"),
            "predicted_action_type": pred,
            "predicted_bid_multiplier": BID_MULTIPLIER_BY_ACTION.get(pred, 1.00),
            "confidence_score": conf, "prediction_risk_level": RISK_BY_ACTION.get(pred, "MEDIUM"),
            "features_snapshot": {c: native(row[c]) for c in FEATURES},
            "prediction_evidence_json": {
                "model_name": name, "model_version": MODEL_VERSION, "chosen_model": best_name,
                "gold_action_type": row.get("gold_action_type"),
                "predicted_action_type": pred,
                "agreement": pred == row.get("gold_action_type"),
                "guardrail_bid_up_override": overridden,
                "probabilities": {str(model_classes[j]): float(probas[i][j]) for j in range(len(model_classes))},
            },
        })
    insert_predictions(conn, out)
    log.info(f"{name}: {len(out)} predições gravadas")


# ── modelo 2: conversion probability ─────────────────────────────────────────

def run_conversion_probability(conn, df):
    name = "HourlyConversionProbabilityModelV1"
    log.info(f"=== {name} ===")
    clear_predictions(conn, name)  # limpa predições antigas; só re-grava se treinar
    df = df.copy()
    y = (pd.to_numeric(df["orders_7d"], errors="coerce").fillna(0) > 0).astype(int).values
    n = len(df)
    classes = len(set(y))
    window = (df["feature_date"].min(), df["feature_date"].max())
    class_dist = {str(k): int(v) for k, v in pd.Series(y).value_counts().items()}
    register_training_dataset(conn, "hourly_conversion_v1", "has_order_7d", n, class_dist, window)

    if n < MIN_ROWS:
        register_model(conn, name, "classifier", "has_order_7d", "INSUFFICIENT_DATA", training_rows=n)
        return
    if classes < MIN_CLASSES:
        register_model(conn, name, "classifier", "has_order_7d", "SINGLE_CLASS_ONLY", training_rows=n)
        return
    minority = int(pd.Series(y).value_counts().min())
    if minority < MIN_POSITIVE:
        log.warning(f"{name}: classe minoritária={minority} < {MIN_POSITIVE} — sinal insuficiente")
        register_model(conn, name, "classifier", "has_order_7d", "INSUFFICIENT_DATA",
                       training_rows=n, metrics={"reason": "minority_class_too_small",
                                                 "minority_count": minority, "min_required": MIN_POSITIVE,
                                                 "class_distribution": class_dist})
        return

    X = build_matrix(df)
    tr, te, split_mode = temporal_or_random_split(df, y)
    Xtr, Xte, ytr, yte = X[tr], X[te], y[tr], y[te]

    base = RandomForestClassifier(n_estimators=300, class_weight="balanced", random_state=42, n_jobs=-1)
    # calibração de probabilidade (fallback para raw se dados insuficientes)
    model, calibrated = base, False
    min_class_tr = int(pd.Series(ytr).value_counts().min())
    if min_class_tr >= 3 and len(set(ytr)) >= 2:
        try:
            cv = min(3, min_class_tr)
            model = CalibratedClassifierCV(base, method="sigmoid", cv=cv)
            model.fit(Xtr, ytr)
            calibrated = True
        except Exception as e:
            log.warning(f"{name}: calibração falhou, usando raw: {e}")
            model, calibrated = base, False
    if not calibrated:
        model = base
        model.fit(Xtr, ytr)

    pred = model.predict(Xte)
    m = classification_metrics(yte, pred, sorted(set(y)))
    m["split_mode"] = split_mode
    m["calibrated"] = calibrated
    # importância do estimador-base (refit garante que está treinado, mesmo calibrado)
    base.fit(Xtr, ytr)
    m["top_features"] = feature_importance(base, Xtr, ytr)
    artifact = save_model(model, name)
    register_model(conn, name, "classifier:calibrated_rf" if calibrated else "classifier:rf",
                   "has_order_7d", "TRAINED", training_rows=n, metrics=m, features=FEATURES,
                   artifact_path=artifact, window_start=window[0], window_end=window[1])
    log.info(f"{name}: bal_acc={m['balanced_accuracy']:.3f} calibrated={calibrated}")

    Xall = build_matrix(df)
    proba = model.predict_proba(Xall)
    pos_idx = list(model.classes_).index(1) if 1 in list(model.classes_) else 1
    out = []
    for i, (_, row) in enumerate(df.iterrows()):
        cp = float(np.clip(proba[i][pos_idx], 0.0, 1.0))
        conf = float(np.clip(np.max(proba[i]), 0.0, 1.0))
        interp = ("probability model suggests potential conversion despite weak current Gold rule"
                  if cp >= 0.5 and row.get("gold_action_type") in ("WATCH", "CUT_HOUR", "BID_DOWN")
                  else "aligned with Gold signal")
        out.append({
            "tenant_id": row["tenant_id"], "amc_instance_id": row["amc_instance_id"],
            "ads_profile_id": row["ads_profile_id"], "model_name": name,
            "prediction_date": date.today(),
            "entity_key": f'{row["campaign_id"]}|{row["ad_product_type"]}|{row["ad_group_name"]}|{row["event_hour"]}',
            "campaign_id": row["campaign_id"], "campaign_name": row["campaign_name"],
            "ad_product_type": row["ad_product_type"], "ad_group_name": row["ad_group_name"],
            "event_hour": int(row["event_hour"]), "gold_action_type": row.get("gold_action_type"),
            "conversion_probability": cp, "confidence_score": conf,
            "prediction_risk_level": "LOW" if cp >= 0.5 else "MEDIUM",
            "features_snapshot": {c: native(row[c]) for c in FEATURES},
            "prediction_evidence_json": {
                "model_name": name, "model_version": MODEL_VERSION,
                "conversion_probability": cp,
                "gold_action_type": row.get("gold_action_type"),
                "calibrated": calibrated, "interpretation": interp,
            },
        })
    insert_predictions(conn, out)
    log.info(f"{name}: {len(out)} predições gravadas")


# ── modelo 3: expected ROAS regressor ────────────────────────────────────────

def run_expected_roas(conn, df):
    name = "ExpectedRoasRegressorV1"
    log.info(f"=== {name} ===")
    clear_predictions(conn, name)  # limpa predições antigas; só re-grava se treinar
    df = df.copy()
    y = np.minimum(pd.to_numeric(df["roas_7d"], errors="coerce").fillna(0).values, ROAS_CAP)
    n = len(df)
    window = (df["feature_date"].min(), df["feature_date"].max())
    register_training_dataset(conn, "hourly_roas_v1", "roas_7d_capped", n,
                              {"target_mean": float(np.mean(y)), "target_p95": float(np.percentile(y, 95))}, window)

    if n < MIN_ROWS:
        register_model(conn, name, "regressor", "roas_7d_capped", "INSUFFICIENT_DATA", training_rows=n)
        return
    nonzero = int(np.sum(y > 0))
    if nonzero < MIN_POSITIVE:
        log.warning(f"{name}: alvos não-zero={nonzero} < {MIN_POSITIVE} — variância insuficiente")
        register_model(conn, name, "regressor", "roas_7d_capped", "INSUFFICIENT_DATA",
                       training_rows=n, metrics={"reason": "target_variance_too_low",
                                                 "nonzero_targets": nonzero, "min_required": MIN_POSITIVE,
                                                 "target_mean": float(np.mean(y))})
        return

    X = build_matrix(df)
    tr, te, split_mode = temporal_or_random_split(df, None)
    Xtr, Xte, ytr, yte = X[tr], X[te], y[tr], y[te]

    candidates = {
        "random_forest": RandomForestRegressor(n_estimators=300, random_state=42, n_jobs=-1),
        "hist_gradient_boosting": HistGradientBoostingRegressor(random_state=42),
    }
    best_name, best_model, best_metrics, best_rmse = None, None, None, float("inf")
    leaderboard = {}
    for cand_name, est in candidates.items():
        try:
            est.fit(Xtr, ytr)
            m = regression_metrics(yte, est.predict(Xte))
            leaderboard[cand_name] = {"rmse": m["rmse"], "mae": m["mae"], "r2": m["r2"]}
            if m["rmse"] < best_rmse:
                best_rmse, best_name, best_model, best_metrics = m["rmse"], cand_name, est, m
        except Exception as e:
            leaderboard[cand_name] = {"error": str(e)[:200]}
            log.warning(f"{name}: candidato {cand_name} falhou: {e}")

    if best_model is None:
        register_model(conn, name, "regressor", "roas_7d_capped", "FAILED", training_rows=n)
        return

    best_metrics["split_mode"] = split_mode
    best_metrics["chosen_model"] = best_name
    best_metrics["leaderboard"] = leaderboard
    best_metrics["top_features"] = feature_importance(best_model, Xte, yte)
    artifact = save_model(best_model, name)
    register_model(conn, name, f"regressor:{best_name}", "roas_7d_capped", "TRAINED",
                   training_rows=n, metrics=best_metrics, features=FEATURES,
                   artifact_path=artifact, window_start=window[0], window_end=window[1])
    log.info(f"{name}: melhor={best_name} rmse={best_metrics['rmse']:.3f} r2={best_metrics['r2']:.3f}")

    Xall = build_matrix(df)
    yhat = best_model.predict(Xall)
    out = []
    for i, (_, row) in enumerate(df.iterrows()):
        exp_roas = float(max(0.0, yhat[i]))
        out.append({
            "tenant_id": row["tenant_id"], "amc_instance_id": row["amc_instance_id"],
            "ads_profile_id": row["ads_profile_id"], "model_name": name,
            "prediction_date": date.today(),
            "entity_key": f'{row["campaign_id"]}|{row["ad_product_type"]}|{row["ad_group_name"]}|{row["event_hour"]}',
            "campaign_id": row["campaign_id"], "campaign_name": row["campaign_name"],
            "ad_product_type": row["ad_product_type"], "ad_group_name": row["ad_group_name"],
            "event_hour": int(row["event_hour"]), "gold_action_type": row.get("gold_action_type"),
            "expected_roas": exp_roas,
            "expected_sales": native(row["sales_7d"]),
            "expected_orders": native(row["orders_7d"]),
            "confidence_score": None,
            "prediction_risk_level": "LOW" if exp_roas >= 5 else "MEDIUM",
            "features_snapshot": {c: native(row[c]) for c in FEATURES},
            "prediction_evidence_json": {
                "model_name": name, "model_version": MODEL_VERSION, "chosen_model": best_name,
                "expected_roas": exp_roas, "roas_cap": ROAS_CAP,
                "gold_action_type": row.get("gold_action_type"),
                "interpretation": "expected 7d ROAS given multi-window features",
            },
        })
    insert_predictions(conn, out)
    log.info(f"{name}: {len(out)} predições gravadas")


def main():
    log.info(f"ML Worker V1 starting (version={MODEL_VERSION})")
    conn = get_conn()
    conn.autocommit = False
    try:
        df = load_features(conn)
        log.info(f"Loaded {len(df)} rows from {SOURCE_TABLE}")
        if df.empty:
            for nm, mt, tg in [("HourlyBidActionClassifierV1", "classifier", "gold_action_type"),
                               ("HourlyConversionProbabilityModelV1", "classifier", "has_order_7d"),
                               ("ExpectedRoasRegressorV1", "regressor", "roas_7d_capped")]:
                register_model(conn, nm, mt, tg, "INSUFFICIENT_DATA", training_rows=0)
            return
        run_action_classifier(conn, df)
        run_conversion_probability(conn, df)
        run_expected_roas(conn, df)
    except Exception:
        log.exception("Erro no ML Worker V1")
        conn.rollback()
        raise
    finally:
        conn.close()
    log.info("ML Worker V1 finished")


if __name__ == "__main__":
    main()
