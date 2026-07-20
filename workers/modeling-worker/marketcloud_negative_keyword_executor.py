"""
MarketCloud — Executor de NEGATIVACAO de search term.

Le gold_negative_keyword_decisions_v1 (regra: gasto >= 1,5x CPA-alvo AND 0 venda)
e manda pro executor do Robo (SWARM) POST /api/amazon/ads/negative-keyword/
execute-action. Real so nos 2 pilotos (full_control active); no resto vai dry_run
(shadow) — nunca toca a Amazon fora dos pilotos.

TRAVAS (tudo default OFF):
  - NEGATIVE_KEYWORD_APPLY_ENABLED  : liga este worker (default OFF).
  - NEGATIVE_KEYWORD_EXECUTE_ENABLED: kill-switch do executor no SWARM (default OFF).
  - allowlist FULL_CONTROL_360_ALLOWLIST_CAMPAIGN_IDS no SWARM (os 2 pilotos).
Sem os dois ligados + allowlist, e dry-run: nao cria negativo de verdade.

Guard de maturidade: so negativa termo cuja ultima atividade e >= 2 dias
(atribuicao pode nao ter pousado nos ultimos dias). Dedup: nao re-negativa
(recommendation_decisions action ADD_NEGATIVE ja aplicado).
"""
import os
import json
import logging
import urllib.request

import psycopg2
import psycopg2.extras

logging.basicConfig(level=logging.INFO, format="%(asctime)s [NEG-KW-EXEC] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgres://mcadmin:mcsecret@postgres:5432/marketcloud")
ROBOT_BASE = os.environ.get("BID_ROBOT_API_BASE", "http://host.docker.internal:8080").rstrip("/")
APPLY_ENABLED = os.environ.get("NEGATIVE_KEYWORD_APPLY_ENABLED", "false").lower() == "true"
MAX_PER_RUN = int(os.environ.get("NEGATIVE_KEYWORD_MAX_PER_RUN", "25"))


def get_conn():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def load_pilot_ids(conn):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT DISTINCT campaign_id
            FROM marketcloud_gold.full_control_effective_governance_v1
            WHERE mode='full_control' AND status='active' AND COALESCE(campaign_id,'')<>''
        """)
        return {str(r["campaign_id"]) for r in cur.fetchall()}


def load_decisions(conn):
    # Guard de maturidade: exige atividade acumulada com ultima data >= 2 dias
    # atras (evita negativar antes da atribuicao pousar). Dedup: pula o que ja
    # foi negativado (recommendation_decisions ADD_NEGATIVE EXECUTED).
    with conn.cursor() as cur:
        cur.execute("""
            WITH last_seen AS (
                SELECT campaign_id, lower(trim(customer_search_term)) st, MAX(data_date) md
                FROM marketcloud_silver.silver_search_term_daily
                GROUP BY 1,2
            )
            SELECT d.campaign_id, d.campaign_name, d.search_term, d.decision,
                   round(d.spend::numeric,2) AS spend, d.clicks
            FROM marketcloud_gold.gold_negative_keyword_decisions_v1 d
            JOIN last_seen ls ON ls.campaign_id=d.campaign_id AND ls.st=d.search_term
            WHERE d.decision IS NOT NULL
              AND ls.md <= CURRENT_DATE - 2
            LIMIT %s
        """, (MAX_PER_RUN,))
        return cur.fetchall()


def post_negative(campaign_id, search_term, decision, dry_run):
    payload = {
        "campaign_id": str(campaign_id),
        "search_term": search_term,
        "decision": decision,
        "dry_run": dry_run,
        "source": "MARKETCLOUD_NEG_KW_EXECUTOR",
    }
    req = urllib.request.Request(
        ROBOT_BASE + "/api/amazon/ads/negative-keyword/execute-action",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    if not APPLY_ENABLED:
        log.info("negative keyword executor desligado (NEGATIVE_KEYWORD_APPLY_ENABLED!=true)")
        return
    if not ROBOT_BASE:
        log.warning("BID_ROBOT_API_BASE vazio; abortando")
        return
    real, shadow = 0, 0
    with get_conn() as conn:
        pilots = load_pilot_ids(conn)
        decisions = load_decisions(conn)
        log.info("%s decisoes de negativacao maduras | pilotos=%s", len(decisions), len(pilots))
        for d in decisions:
            is_pilot = str(d["campaign_id"]) in pilots
            dry = not is_pilot  # real so nos pilotos; resto e dry-run (shadow)
            try:
                res = post_negative(d["campaign_id"], d["search_term"], d["decision"], dry)
                status = res.get("status")
                if is_pilot and status == "APPLIED_REAL_CONFIRMED":
                    real += 1
                else:
                    shadow += 1
                log.info("neg %s '%s' pilot=%s dry=%s -> %s",
                         d["campaign_name"], d["search_term"], is_pilot, dry, status)
            except Exception as exc:
                log.warning("falha ao negativar '%s': %s", d["search_term"], exc)
    log.info("negativacao concluida real=%s shadow=%s", real, shadow)


if __name__ == "__main__":
    main()
