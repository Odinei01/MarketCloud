"""
MarketCloud Modeling Worker
Polls for SUCCEEDED query_runs â†’ classifies campaigns â†’ writes insights + recommendations.
"""
import json
import os
import subprocess
import sys
import threading
import time
import logging
import psycopg2
import psycopg2.extras

from classifier import CampaignMetrics, classify
from insights import generate_campaign_insights
from recommendations import generate

logging.basicConfig(level=logging.INFO, format="%(asctime)s [WORKER] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgres://mcadmin:mcsecret@localhost:5433/marketcloud")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "15"))
HOURLY_REAL_ML_ENABLED = os.environ.get("HOURLY_REAL_ML_ENABLED", "false").lower() == "true"
HOURLY_REAL_ML_INTERVAL_SECONDS = int(os.environ.get("HOURLY_REAL_ML_INTERVAL_MINUTES", "60")) * 60
HOURLY_REAL_ML_RUN_IMMEDIATELY = os.environ.get("HOURLY_REAL_ML_RUN_IMMEDIATELY", "false").lower() == "true"
ML_AUTO_APPLY_CAMPAIGN_ENABLED = os.environ.get("ML_AUTO_APPLY_CAMPAIGN_ENABLED", "false").lower() == "true"


def get_conn():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def refresh_learning_outcomes():
    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT marketcloud_recommendations.refresh_recommendation_hourly_outcomes() AS refreshed")
                row = cur.fetchone()
                conn.commit()
                refreshed = row["refreshed"] if row else 0
                log.info("learning-outcomes refresh upserted %s rows", refreshed)
    except Exception as exc:
        log.exception("learning-outcomes refresh failed: %s", exc)


def auto_apply_ml_campaign_recommendations():
    if not ML_AUTO_APPLY_CAMPAIGN_ENABLED:
        log.info("ML campaign auto-apply disabled")
        return
    script = os.path.join(os.path.dirname(__file__), "marketcloud_ml_auto_apply_campaign_recommendations.py")
    if not os.path.exists(script):
        log.error("ML campaign auto-apply script not found: %s", script)
        return
    try:
        started = time.time()
        result = subprocess.run(
            [sys.executable, script],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        if result.stdout:
            log.info("[ml-auto-apply-campaign]\n%s", result.stdout.strip())
        if result.returncode == 0:
            log.info("ml-auto-apply-campaign finished in %.1fs", time.time() - started)
        else:
            log.error("ml-auto-apply-campaign failed rc=%s in %.1fs", result.returncode, time.time() - started)
    except Exception as exc:
        log.exception("ml-auto-apply-campaign scheduler error: %s", exc)


def apply_full_control_360():
    # Executor Full Control 360 (budget/placement/stop-loss). Roda todo ciclo,
    # mas so age se FULL_CONTROL_360_APPLY_ENABLED=true (default OFF) — agendar
    # aqui e seguro: dorme ate o dono armar as travas.
    script = os.path.join(os.path.dirname(__file__), "marketcloud_full_control_360_executor.py")
    if not os.path.exists(script):
        return
    try:
        started = time.time()
        result = subprocess.run([sys.executable, script], check=False, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.stdout:
            log.info("[fc360-executor]\n%s", result.stdout.strip())
        if result.returncode != 0:
            log.error("fc360-executor failed rc=%s in %.1fs", result.returncode, time.time() - started)
    except Exception as exc:
        log.exception("fc360-executor scheduler error: %s", exc)


def hourly_real_ml_loop():
    if not HOURLY_REAL_ML_ENABLED:
        log.info("Hourly real ML scheduler disabled")
        return
    scripts = [
        ("hourly-real-ml", os.path.join(os.path.dirname(__file__), "marketcloud_ml_worker_hourly_real_v2.py")),
        ("hourly-target-real-ml", os.path.join(os.path.dirname(__file__), "marketcloud_ml_worker_hourly_target_real_v3.py")),
    ]
    missing = [script for _, script in scripts if not os.path.exists(script)]
    if missing:
        log.error("Hourly real ML script(s) not found: %s", ", ".join(missing))
        return
    wait = 0 if HOURLY_REAL_ML_RUN_IMMEDIATELY else HOURLY_REAL_ML_INTERVAL_SECONDS
    log.info("Hourly real ML scheduler enabled interval=%ss run_immediately=%s scripts=%s",
             HOURLY_REAL_ML_INTERVAL_SECONDS, HOURLY_REAL_ML_RUN_IMMEDIATELY,
             ",".join(name for name, _ in scripts))
    while True:
        if wait > 0:
            time.sleep(wait)
        wait = HOURLY_REAL_ML_INTERVAL_SECONDS
        for name, script in scripts:
            try:
                started = time.time()
                result = subprocess.run(
                    [sys.executable, script],
                    check=False,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )
                if result.stdout:
                    log.info("[%s]\n%s", name, result.stdout.strip())
                if result.returncode == 0:
                    log.info("%s finished in %.1fs", name, time.time() - started)
                else:
                    log.error("%s failed rc=%s in %.1fs", name, result.returncode, time.time() - started)
            except Exception as exc:
                log.exception("%s scheduler error: %s", name, exc)
        auto_apply_ml_campaign_recommendations()
        apply_full_control_360()
        refresh_learning_outcomes()


def pick_pending_runs(cur) -> list[dict]:
    cur.execute("""
        SELECT qr.id, qr.tenant_id, qr.store_id, qr.parameters_json,
               qt.code AS template_code, qt.query_family
        FROM query_runs qr
        JOIN query_templates qt ON qt.id = qr.query_template_id
        WHERE qr.status IN ('SUCCEEDED', 'RESULT_DOWNLOADED')
        ORDER BY qr.finished_at ASC
        LIMIT 5
        FOR UPDATE SKIP LOCKED
    """)
    return cur.fetchall()


def mock_campaigns_from_params(params: dict, store_id: str, cur) -> list[CampaignMetrics]:
    """
    Build CampaignMetrics from real campaigns in DB + parameters.
    When no real AMC result file exists, synthesize metrics from DB campaigns.
    In production, this would parse the Parquet/CSV from object storage.
    """
    target_roas = float(params.get("target_roas", 4.0))
    cur.execute("""
        SELECT campaign_id, campaign_name, campaign_type, daily_budget, status
        FROM campaigns WHERE store_id = %s AND status IN ('ENABLED','PAUSED')
        LIMIT 50
    """, (store_id,))
    db_campaigns = cur.fetchall()

    if not db_campaigns:
        return []

    import hashlib
    metrics = []
    for c in db_campaigns:
        seed = int(hashlib.md5(c["campaign_id"].encode()).hexdigest()[:8], 16)
        rng = (seed % 100) / 100.0

        # Deterministic synthetic signals based on campaign name heuristics
        name = (c["campaign_name"] or "").lower()
        if any(w in name for w in ["exata", "exact", "branded", "conversÃ£o"]):
            roas = 5.0 + rng * 4
            assist = rng * 0.2
            first = 0.1 + rng * 0.2
            last = 0.5 + rng * 0.4
        elif any(w in name for w in ["ampla", "broad", "descoberta", "discovery", "rastreador"]):
            roas = 1.2 + rng * 2.5
            assist = 0.25 + rng * 0.35
            first = 0.3 + rng * 0.4
            last = 0.1 + rng * 0.25
        elif any(w in name for w in ["concorrente", "competitor", "asin"]):
            roas = 0.2 + rng * 1.2
            assist = rng * 0.08
            first = 0.05 + rng * 0.1
            last = 0.05 + rng * 0.15
        elif any(w in name for w in ["remarketing", "retarget", "visitou", "sd"]):
            roas = 3.5 + rng * 3
            assist = 0.15 + rng * 0.25
            first = 0.05
            last = 0.3 + rng * 0.4
        else:
            roas = 2.0 + rng * 3
            assist = 0.1 + rng * 0.3
            first = 0.2 + rng * 0.3
            last = 0.2 + rng * 0.4

        spend = 100 + rng * 900
        direct_sales = spend * roas
        assisted_sales = direct_sales * assist * 1.5
        direct_conv = max(0, int(rng * 15))
        assisted_conv = max(0, int(rng * 8))
        path_presence = 0.05 + assist * 0.8

        metrics.append(CampaignMetrics(
            campaign_id=c["campaign_id"],
            campaign_name=c["campaign_name"],
            spend=round(spend, 2),
            direct_conversions=direct_conv,
            assisted_conversions=assisted_conv,
            direct_sales=round(direct_sales, 2),
            assisted_sales=round(assisted_sales, 2),
            assist_rate=round(assist, 3),
            first_touch_rate=round(first, 3),
            last_touch_rate=round(last, 3),
            path_presence_rate=round(path_presence, 3),
        ))

    return metrics


def process_run(run: dict, conn):
    run_id = str(run["id"])
    tenant_id = str(run["tenant_id"])
    store_id = str(run["store_id"])
    params = run["parameters_json"] if isinstance(run["parameters_json"], dict) else json.loads(run["parameters_json"] or "{}")

    log.info(f"Processing run {run_id} [{run['template_code']}] store={store_id}")

    with conn.cursor() as cur:
        # Mark MODELING_STARTED
        cur.execute("""
            UPDATE query_runs SET status='MODELING_STARTED', updated_at=NOW() WHERE id=%s
        """, (run_id,))
        cur.execute("INSERT INTO query_run_events (query_run_id, status) VALUES (%s,'MODELING_STARTED')", (run_id,))
        conn.commit()

        # Build campaign metrics
        campaign_metrics = mock_campaigns_from_params(params, store_id, cur)
        if not campaign_metrics:
            log.warning(f"No campaigns for run {run_id}, skipping")
            cur.execute("UPDATE query_runs SET status='MODELING_COMPLETED', updated_at=NOW() WHERE id=%s", (run_id,))
            conn.commit()
            return

        # Classify
        results = [classify(m) for m in campaign_metrics]

        # Write insights
        period_start = params.get("period_start", "")
        period_end = params.get("period_end", "")
        raw_insights = generate_campaign_insights(results, period_start, period_end)
        insight_ids = []

        for ins in raw_insights:
            cur.execute("""
                INSERT INTO insights
                    (tenant_id, store_id, query_run_id, insight_type, entity_type, entity_id, entity_name,
                     severity, confidence, score, title, summary, evidence_json, recommended_action,
                     period_start, period_end)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                RETURNING id
            """, (
                tenant_id, store_id, run_id,
                ins.insight_type, ins.entity_type, ins.entity_id, ins.entity_name,
                ins.severity, ins.confidence, ins.score,
                ins.title, ins.summary, ins.evidence_json, ins.recommended_action,
                period_start or None, period_end or None,
            ))
            row = cur.fetchone()
            if row:
                insight_ids.append(str(row["id"]))

        # Write recommendations
        recs = generate(results)
        for i, rec in enumerate(recs):
            source_id = insight_ids[i] if i < len(insight_ids) else None
            cur.execute("""
                INSERT INTO recommendations
                    (tenant_id, store_id, source_insight_id, target_type, target_id, target_name,
                     action_type, current_value, recommended_value, impact_estimate, reason, confidence)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            """, (
                tenant_id, store_id, source_id,
                rec.target_type, rec.target_id, rec.target_name,
                rec.action_type,
                json.dumps(rec.current_value), json.dumps(rec.recommended_value),
                json.dumps(rec.impact_estimate),
                rec.reason, rec.confidence,
            ))

        # Usage record
        month = time.strftime("%Y-%m")
        cur.execute("""
            INSERT INTO usage_records (tenant_id, store_id, metric, value, period_month)
            VALUES (%s,%s,'insights_generated',%s,%s)
        """, (tenant_id, store_id, len(raw_insights), month))
        cur.execute("""
            INSERT INTO usage_records (tenant_id, store_id, metric, value, period_month)
            VALUES (%s,%s,'recommendations_generated',%s,%s)
        """, (tenant_id, store_id, len(recs), month))

        # Mark INSIGHTS_GENERATED
        cur.execute("""
            UPDATE query_runs SET status='INSIGHTS_GENERATED', updated_at=NOW() WHERE id=%s
        """, (run_id,))
        cur.execute("INSERT INTO query_run_events (query_run_id, status) VALUES (%s,'INSIGHTS_GENERATED')", (run_id,))
        conn.commit()

        log.info(f"Run {run_id} done: {len(raw_insights)} insights, {len(recs)} recommendations")


def main():
    log.info("MarketCloud Modeling Worker starting...")
    threading.Thread(target=hourly_real_ml_loop, name="hourly-real-ml", daemon=True).start()
    while True:
        try:
            conn = get_conn()
            conn.autocommit = False
            with conn.cursor() as cur:
                runs = pick_pending_runs(cur)
                conn.commit()

            for run in runs:
                try:
                    process_run(run, conn)
                except Exception as e:
                    log.error(f"Error processing run {run['id']}: {e}")
                    conn.rollback()
                    with conn.cursor() as cur:
                        cur.execute("""
                            UPDATE query_runs SET status='FAILED', error_code='MODELING_FAILED',
                            error_message=%s, updated_at=NOW() WHERE id=%s
                        """, (str(e), str(run["id"])))
                        conn.commit()

            conn.close()

        except Exception as e:
            log.error(f"Worker loop error: {e}")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()



