"""
MarketCloud — Executor Full Control 360.

Le as propostas 360 (budget/placement/stop-loss) dos pilotos que o dono liberou
como full_control + active + can_control, e manda pro executor do Robo (SWARM),
que de fato aplica na Amazon DENTRO DOS TETOS do piloto.

Fecha o loop: proposta -> executada -> gold/AMS mede -> ML aprende.

SEGURANCA (dupla trava, igual ao BID auto-apply):
  FULL_CONTROL_360_APPLY_ENABLED=false   -> worker dormente (default)
  FULL_CONTROL_360_APPLY_DRY_RUN=true    -> nao move dinheiro (default)
  E o proprio Robo tem FULL_CONTROL_360_EXECUTE_ENABLED (kill-switch) + allowlist.
So aplica de verdade quando as tres travas estao abertas.
"""

import json
import logging
import os
import urllib.request
import urllib.error
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras

logging.basicConfig(level=logging.INFO, format="%(asctime)s [FC360-EXEC] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgres://mcadmin:mcsecret@postgres:5432/marketcloud")
ROBOT_BASE = os.environ.get("BID_ROBOT_API_BASE", "http://host.docker.internal:8080").rstrip("/")
ENABLED = os.environ.get("FULL_CONTROL_360_APPLY_ENABLED", "false").lower() == "true"
DRY_RUN = os.environ.get("FULL_CONTROL_360_APPLY_DRY_RUN", "true").lower() != "false"
MAX_PER_RUN = int(os.environ.get("FULL_CONTROL_360_APPLY_MAX_PER_RUN", "10"))


def get_conn():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def load_actions(conn):
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT recommendation_id, campaign_id, campaign_name, action_type,
                   COALESCE(current_value,0)::float8 AS current_value,
                   COALESCE(recommended_value,0)::float8 AS recommended_value,
                   operator_decision, guardrail_status
            FROM marketcloud_gold.v_ml_full_control_360_decision_v1
            WHERE operator_decision IN ('APLICAR','APLICAR_SEGURANCA')
              AND can_control_now = true
              AND COALESCE(campaign_id,'') <> ''
            ORDER BY priority_score DESC NULLS LAST
            LIMIT %s
            """,
            (MAX_PER_RUN,),
        )
        return list(cur.fetchall())


def post_executor(action):
    raw = json.dumps(action).encode("utf-8")
    req = urllib.request.Request(
        ROBOT_BASE + "/api/amazon/ads/full-control/execute-action",
        data=raw, method="POST", headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        return {"status": "HTTP_ERROR", "safe_error": f"{exc.code}"}
    except Exception as exc:  # noqa
        return {"status": "UNREACHABLE", "safe_error": str(exc)[:120]}


def mark_executed(conn, recommendation_id, robot_status):
    # So marca EXECUTED no ledger do MarketCloud quando o Robo confirmou o write.
    if robot_status != "APPLIED_REAL_CONFIRMED":
        return
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE marketcloud_recommendations.recommendation_decisions
            SET decision='APPROVED', decided_by='FULL_CONTROL_360_EXECUTOR',
                execution_status='EXECUTED', executed_at=NOW(), updated_at=NOW()
            WHERE recommendation_id=%s
            """,
            (recommendation_id,),
        )
    conn.commit()


def main():
    started = datetime.now(timezone.utc)
    if not ENABLED:
        log.info("worker dormente (FULL_CONTROL_360_APPLY_ENABLED != true)")
        return
    if not ROBOT_BASE:
        log.warning("BID_ROBOT_API_BASE vazio; abortando")
        return
    with get_conn() as conn:
        actions = load_actions(conn)
        log.info("%s acoes 360 candidatas (dry_run=%s)", len(actions), DRY_RUN)
        applied = 0
        for a in actions:
            payload = {
                "action_type": a["action_type"],
                "campaign_id": a["campaign_id"],
                "campaign_name": a.get("campaign_name") or "",
                "current_value": float(a["current_value"]),
                "recommended_value": float(a["recommended_value"]),
                "dry_run": DRY_RUN,
                "recommendation_id": a["recommendation_id"],
            }
            resp = post_executor(payload)
            status = str(resp.get("status") or "")
            if DRY_RUN:
                log.info("[DRY] %s %s -> %s (real_write=%s)", a["action_type"], a["campaign_name"], status, resp.get("real_write"))
                continue
            if status == "APPLIED_REAL_CONFIRMED":
                mark_executed(conn, a["recommendation_id"], status)
                applied += 1
                log.info("APLICADO %s %s", a["action_type"], a["campaign_name"])
            else:
                log.info("nao aplicado %s %s -> %s %s", a["action_type"], a["campaign_name"], status, resp.get("blockers") or resp.get("safe_error") or "")
        log.info("fim: %s candidatas, %s aplicadas, dur=%ss", len(actions), applied, int((datetime.now(timezone.utc) - started).total_seconds()))


if __name__ == "__main__":
    main()
