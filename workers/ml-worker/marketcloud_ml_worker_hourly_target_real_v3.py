"""
MarketCloud ML Worker — HOURLY TARGET REAL v3

Treina no dado AMS real em grao keyword/target x hora:
  marketcloud_bronze.bronze_ams_hourly_target

Modelos registrados:
  HourlyTargetClickRealV3       target: has_click
  HourlyTargetConversionRealV3  target: has_order
  HourlyTargetExpectedRoasRealV3 target: roas_capped

HONESTIDADE:
  - O dataset AMS target ainda pode ser pequeno e conter restatements/deltas.
  - Se nao houver volume minimo, registra INSUFFICIENT_DATA e nao inventa score.
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
from sklearn.model_selection import StratifiedKFold, KFold, cross_val_predict

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
        SELECT
            campaign_id,
            MAX(campaign_name) AS campaign_name,
            COALESCE(ad_group_id, '') AS ad_group_id_norm,
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
            SUM(GREATEST(COALESCE(orders_14d, 0), COALESCE(orders_7d, 0), COALESCE(orders_1d, 0)))::float AS orders,
            SUM(GREATEST(COALESCE(sales_14d, 0), COALESCE(sales_7d, 0), COALESCE(sales_1d, 0)))::float AS sales
        FROM marketcloud_bronze.bronze_ams_hourly_target
        WHERE NULLIF(TRIM(COALESCE(target_entity_key, '')), '') IS NOT NULL
        GROUP BY campaign_id, COALESCE(ad_group_id, ''), target_entity_key, event_hour
    """
    with conn.cursor() as cur:
        cur.execute(sql)
        df = pd.DataFrame([dict(r) for r in cur.fetchall()])
    if df.empty:
        return df

    for col in ["impressions", "clicks", "spend", "orders", "sales"]:
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
    cols = ["event_hour", "is_madrugada", "is_manha", "is_tarde", "is_noite", "impr_per_day", "days_observed"]
    # For conversion/ROAS after the hour closes, clicks/spend signals are allowed.
    # For click propensity, do not include click-derived features.
    if target != "has_click":
        cols.extend(["ctr", "cpc"])
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
            """,
            (status, rows, positive_clicks, positive_orders, predictions_written, json.dumps(metrics), started_at),
        )
        conn.commit()


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

    n_splits = max(2, min(5, pos, neg))
    clf = RandomForestClassifier(
        n_estimators=300,
        class_weight="balanced",
        min_samples_leaf=2,
        random_state=42,
        n_jobs=-1,
    )
    cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=42)
    proba = cross_val_predict(clf, X, y, cv=cv, method="predict_proba", n_jobs=-1)[:, 1]
    pred = (proba >= 0.5).astype(int)
    hour_rate = df.groupby("event_hour")[target_col].transform("mean").values
    auc = roc_auc_score(y, proba) if len(np.unique(y)) == 2 else np.nan
    base_auc = roc_auc_score(y, hour_rate) if len(np.unique(y)) == 2 else np.nan
    metrics.update({
        "roc_auc": None if np.isnan(auc) else float(auc),
        "balanced_accuracy": float(balanced_accuracy_score(y, pred)),
        "baseline_hourrate_auc": None if np.isnan(base_auc) else float(base_auc),
        "beats_baseline": bool((not np.isnan(auc)) and (not np.isnan(base_auc)) and auc > base_auc),
        "cv": f"stratified_{n_splits}fold_oof",
    })
    clf.fit(X, y)
    full = clf.predict_proba(X)[:, 1]
    imp = sorted(zip(feat_cols, clf.feature_importances_), key=lambda t: -t[1])[:8]
    metrics["top_features"] = [{"f": f, "imp": float(i)} for f, i in imp]
    register(conn, model_name, "classifier:rf", target_col, "TRAINED", len(df), metrics)
    log.info("%s: AUC=%s baseline=%s positives=%s", model_name, metrics["roc_auc"], metrics["baseline_hourrate_auc"], pos)
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

    n_splits = max(2, min(5, nonzero, len(df)))
    reg = RandomForestRegressor(n_estimators=300, min_samples_leaf=2, random_state=42, n_jobs=-1)
    cv = KFold(n_splits=n_splits, shuffle=True, random_state=42)
    oof = np.clip(cross_val_predict(reg, X, y, cv=cv, n_jobs=-1), 0, ROAS_CAP)
    baseline = df.groupby("event_hour")["roas"].transform("mean").clip(0, ROAS_CAP).values
    metrics.update({
        "mae": float(mean_absolute_error(y, oof)),
        "r2": float(r2_score(y, oof)),
        "baseline_hourmean_mae": float(mean_absolute_error(y, baseline)),
        "beats_baseline": bool(mean_absolute_error(y, oof) < mean_absolute_error(y, baseline)),
        "target_mean": float(np.mean(y)),
        "cv": f"kfold_{n_splits}_oof",
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
        record_run_status(conn, started_at, run_status, len(df), int(df["has_click"].sum()), int(df["has_order"].sum()), predictions_written, {
            "click_model_trained": bool(click_trained),
            "conversion_model_trained": bool(conv_trained),
            "roas_model_trained": bool(roas_trained),
            "targets": int(df["target_entity_key"].nunique()),
        })
    except Exception:
        log.exception("erro no ML target-real v3")
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
