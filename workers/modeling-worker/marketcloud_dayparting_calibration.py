"""
MarketCloud — Calibracao Semanal de Dayparting no GRAO KEYWORD (control loop).

Roda refresh_keyword_hourly_calibration() sobre os ultimos 28 dias (janela recente;
posicao-no-mes NAO e usada — provado nao-separavel em 21/07) e manda um digest no
Telegram com a curva calibrada vs a hardcoded.

Grao: keyword x hora (o menor). Substitui a curva hardcoded (20/50/100/30 igual pra
todos) por avaliacao keyword a keyword sobre dado recente, mantendo os buckets
{20,30,50,80,100}. Onde a keyword e magra, pool pela hierarquia keyword->campanha->
global (effective_scope). Travas no SQL: passo max 1 bucket/semana, gate de amostra.
Saida em gold_keyword_hourly_calibration_v1 (o applier de bid le daqui).

TRAVAS (default OFF):
  - DAYPARTING_CALIBRATION_APPLY_ENABLED : liga a APLICACAO real do bid (default OFF).
    Enquanto OFF, o worker so calcula e notifica (advisory). Aplicacao real (quando
    ligada) e restrita aos 2 pilotos (full_control active) — respeita a trava de dinheiro.
"""
import os
import json
import logging
import urllib.request

import psycopg2
import psycopg2.extras

logging.basicConfig(level=logging.INFO, format="%(asctime)s [DAYPART-CALIB] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgres://mcadmin:mcsecret@postgres:5432/marketcloud")
APPLY_ENABLED = os.environ.get("DAYPARTING_CALIBRATION_APPLY_ENABLED", "false").lower() == "true"
WINDOW_DAYS = int(os.environ.get("DAYPARTING_CALIBRATION_WINDOW_DAYS", "28"))

DOW = {1: "Seg", 2: "Ter", 3: "Qua", 4: "Qui", 5: "Sex", 6: "Sab", 7: "Dom"}


def get_conn():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def send_telegram(text):
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat:
        log.info("telegram nao configurado; pulando")
        return
    try:
        req = urllib.request.Request(
            "https://api.telegram.org/bot%s/sendMessage" % token,
            data=json.dumps({"chat_id": chat, "text": text, "parse_mode": "HTML"}).encode("utf-8"),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=15) as r:
            r.read()
    except Exception as exc:
        log.warning("falha ao enviar telegram: %s", exc)


def run_calibration(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT marketcloud_gold.refresh_keyword_hourly_calibration(%s)", (WINDOW_DAYS,))
        n = cur.fetchone()["refresh_keyword_hourly_calibration"]
    conn.commit()
    return n


def load_summary(conn):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT
                count(*)                                          AS total,
                count(*) FILTER (WHERE action='DOWN')             AS cuts,
                count(*) FILTER (WHERE action='UP')               AS boosts,
                count(*) FILTER (WHERE gate='INSUFFICIENT_DATA')  AS held,
                count(*) FILTER (WHERE scope='ENTITY')            AS s_entity,
                count(*) FILTER (WHERE scope='CAMPAIGN')          AS s_campaign,
                count(*) FILTER (WHERE scope='GLOBAL')            AS s_global,
                count(DISTINCT keyword_id)                        AS keywords
            FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
        """)
        summary = cur.fetchone()
        # maiores ajustes por hora (agregado — a curva que muda pra keyword tipica)
        cur.execute("""
            SELECT event_hour,
                   round(avg(hour_roas),2)              AS roas,
                   round(avg(scope_avg_roas),2)         AS media,
                   round(avg(recommended_multiplier),2) AS mult,
                   marketcloud_gold._dp_hardcoded_band(event_hour::int) AS hardcoded
            FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
            WHERE gate='OK'
            GROUP BY event_hour
            HAVING round(avg(recommended_multiplier),2)
                   <> marketcloud_gold._dp_hardcoded_band(event_hour::int)
            ORDER BY abs(round(avg(recommended_multiplier),2)
                         - marketcloud_gold._dp_hardcoded_band(event_hour::int)) DESC,
                     event_hour
            LIMIT 10
        """)
        moves = cur.fetchall()
    return summary, moves


def build_digest(summary, moves, applied):
    head = "🕐 <b>Calibracao Dayparting (keyword x hora)</b> — trailing %sd\n" % WINDOW_DAYS
    head += "%s keywords x 24h | ↑%s ↓%s · segurou(amostra): %s\n" % (
        summary["keywords"], summary["boosts"], summary["cuts"], summary["held"])
    head += "Scope do sinal: keyword=%s · campanha=%s · global=%s\n" % (
        summary["s_entity"], summary["s_campaign"], summary["s_global"])
    head += ("Modo: <b>%s</b>\n" % ("APLICANDO (pilotos)" if applied else "ADVISORY (nao aplica)"))
    if not moves:
        head += "\nNenhuma hora divergindo da curva atual ainda."
        return head
    head += "\n<b>Curva vs hardcoded</b> (hora: ROAS → calib | era):\n"
    for m in moves:
        arrow = "🔺" if m["mult"] > m["hardcoded"] else "🔻"
        head += "%s %02dh — ROAS %.1f → %.2f | era %.2f\n" % (
            arrow, m["event_hour"], m["roas"] or 0, m["mult"], m["hardcoded"])
    return head


def run_dayparting_calibration():
    conn = get_conn()
    try:
        n = run_calibration(conn)
        summary, moves = load_summary(conn)
        applied = False
        if APPLY_ENABLED:
            # Aplicacao real do bid (pilotos) e um passo separado e gated. Fase 1 entrega
            # o calculo + digest; o hook de escrita entra quando o dono ligar a trava.
            log.info("APPLY_ENABLED=true — aplicacao real ainda nao acoplada ao applier; mantendo advisory")
        digest = build_digest(summary, moves, applied)
        log.info("calibracao keyword x hora: %s celulas | %s keywords | scope kw=%s camp=%s global=%s | up=%s down=%s hold=%s",
                 n, summary["keywords"], summary["s_entity"], summary["s_campaign"], summary["s_global"],
                 summary["boosts"], summary["cuts"], summary["held"])
        send_telegram(digest)
    finally:
        conn.close()


if __name__ == "__main__":
    run_dayparting_calibration()
