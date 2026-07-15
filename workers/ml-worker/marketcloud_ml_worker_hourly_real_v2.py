"""
MarketCloud ML Worker - HOURLY REAL v2

Treina no dado real horario da conta ZANOM, sem supressao:
  marketcloud_bronze.bronze_amazon_ads_hourly

Diferente do V1, que aprendia sobre o AMC suprimido e recusava treinar por falta de
sinal na classe minoritaria. Aqui ha sinal real: celulas com pedido.

Modelos:
  ConversionModelReal   target: has_order  (binario)    -> conversion_probability
  ExpectedRoasReal      target: roas_capped (regressao)  -> expected_roas

HONESTIDADE:
  - grao: campanha x hora agregado na janela.
  - features SEM vazamento do alvo: hora, faixas do dia, campanha (one-hot),
    e sinais de demanda (ctr, cpc, impressoes/dia). Nao usa orders/sales/roas como X.
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
from sklearn.model_selection import StratifiedKFold, cross_val_predict, KFold

logging.basicConfig(level=logging.INFO, format="%(asctime)s [ML-HOURLY-REAL] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgres://mcadmin:mcsecret@postgres:5432/marketcloud")
ROAS_CAP = 20.0
GOOD_HOUR_PROB = 0.5
GOOD_HOUR_ROAS = 4.0


def get_conn():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def load(conn):
    # CAMADA CANÔNICA (§44): features de tráfego de TODAS as células; alvo de
    # conversão (orders/sales/roas) SÓ das células MADURAS (conversion_trustworthy).
    # Evita aprender "hora fresca = sem pedido" quando é só conversão imatura.
    sql = """
        SELECT LOWER(TRIM(campaign_name)) AS campaign_norm,
               MAX(campaign_name) AS campaign_name,
               event_hour,
               COUNT(DISTINCT data_date)                                         AS days_observed,
               SUM(impressions)::float                                           AS impressions,
               SUM(clicks)::float                                                AS clicks,
               SUM(spend)::float                                                 AS spend,
               COALESCE(SUM(orders_7d) FILTER (WHERE conversion_trustworthy),0)::float AS orders,
               COALESCE(SUM(sales_7d)  FILTER (WHERE conversion_trustworthy),0)::float AS sales,
               COALESCE(SUM(spend)     FILTER (WHERE conversion_trustworthy),0)::float AS spend_mature,
               COUNT(DISTINCT data_date) FILTER (WHERE conversion_trustworthy)   AS mature_days,
               COALESCE(MAX(amc_assist_rate),0)      AS amc_assist_rate,
               COALESCE(MAX(amc_first_touch_rate),0) AS amc_first_touch_rate,
               COALESCE(MAX(amc_new_customer_rate),0) AS amc_new_customer_rate,
               COALESCE(MAX(amc_dpv_count),0) AS amc_dpv_count,
               COALESCE(MAX(amc_cart_adds),0) AS amc_cart_adds,
               COALESCE(MAX(learn_roas_delta_avg),0) AS learn_roas_delta_avg,
               COALESCE(MAX(learn_win_rate),0.5)     AS learn_win_rate
        FROM marketcloud_gold.gold_hourly_signal_amc
        WHERE UPPER(COALESCE(campaign_status,'ENABLED')) NOT IN ('ARCHIVED','PAUSED','DELETED')
        GROUP BY LOWER(TRIM(campaign_name)), event_hour
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
                    "learn_roas_delta_avg", "learn_win_rate"]
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
               "learn_roas_delta_avg", "learn_win_rate"]].copy()
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
            """,
            (status, rows, positive_orders, predictions_written, json.dumps(metrics), started_at),
        )
        conn.commit()


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
            cls.fit(X, y_cls)
            proba_full = cls.predict_proba(X)[:, 1]
            imp = sorted(zip(feat_cols, cls.feature_importances_), key=lambda t: -t[1])[:8]
            cls_metrics["top_features"] = [{"f": f, "imp": float(i)} for f, i in imp]
            register(conn, "HourlyConversionRealV2", "classifier:rf", "has_order", "TRAINED", n, cls_metrics)
            log.info(f"Conversao: AUC={cls_metrics['roc_auc']:.3f} "
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
        run_status = "COMPLETED"
        if cls_metrics.get("positives", 0) < 10 or reg_metrics.get("n", 0) == 0:
            run_status = "PARTIAL"
        record_run_status(conn, started_at, run_status, n, pos, len(rows), {
            "conversion": cls_metrics,
            "expected_roas": reg_metrics,
        })
    except Exception:
        log.exception("erro no ML hourly-real v2")
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()



