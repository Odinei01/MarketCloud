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
        # ADVISORY: reportamos o ALVO (target_multiplier) — onde o dado diz que a hora
        # deve ficar — vs a curva hardcoded atual. (O passo de 1 bucket/semana e do
        # aplicador automatico; para revisao humana, o alvo e o que interessa.)
        cur.execute("""
            SELECT
                count(DISTINCT keyword_id)                               AS keywords,
                count(DISTINCT keyword_id) FILTER (WHERE scope='ENTITY') AS kw_entity,
                count(DISTINCT keyword_id) FILTER (
                    WHERE gate='OK' AND target_multiplier
                          <> marketcloud_gold._dp_hardcoded_band(event_hour::int)) AS kw_com_rec,
                count(*) FILTER (WHERE gate='OK' AND target_multiplier
                          > marketcloud_gold._dp_hardcoded_band(event_hour::int))  AS boosts,
                count(*) FILTER (WHERE gate='OK' AND target_multiplier
                          < marketcloud_gold._dp_hardcoded_band(event_hour::int))  AS cuts
            FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
        """)
        summary = cur.fetchone()
        # Curva GLOBAL (aplica as keywords sem dado proprio): horas cujo ALVO muda vs hardcoded.
        cur.execute("""
            SELECT event_hour,
                   round(avg(hour_roas),1)          AS roas,
                   round(avg(target_multiplier),2)  AS mult,
                   marketcloud_gold._dp_hardcoded_band(event_hour::int) AS hardcoded
            FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
            WHERE scope='GLOBAL' AND gate='OK'
            GROUP BY event_hour
            HAVING round(avg(target_multiplier),2)
                   <> marketcloud_gold._dp_hardcoded_band(event_hour::int)
            ORDER BY event_hour
        """)
        global_changes = cur.fetchall()
        # Keywords com CURVA PROPRIA (ENTITY): horas cujo ALVO muda vs hardcoded, por keyword.
        cur.execute("""
            SELECT keyword_text, event_hour, target_multiplier AS mult,
                   marketcloud_gold._dp_hardcoded_band(event_hour::int) AS hardcoded
            FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
            WHERE scope='ENTITY'
              AND target_multiplier <> marketcloud_gold._dp_hardcoded_band(event_hour::int)
            ORDER BY keyword_text, event_hour
        """)
        entity_changes = cur.fetchall()
    return summary, global_changes, entity_changes


def build_digest(summary, global_changes, entity_changes, applied):
    head = "🕐 <b>Calibracao Dayparting (keyword x hora)</b> — trailing %sd\n" % WINDOW_DAYS
    head += "%s keywords · %s com curva propria (ENTITY) · <b>%s com recomendacao</b> (↑%s ↓%s celulas)\n" % (
        summary["keywords"], summary["kw_entity"], summary["kw_com_rec"],
        summary["boosts"], summary["cuts"])
    head += "Modo: <b>%s</b>\n" % ("APLICANDO (pilotos)" if applied else "ADVISORY — nao aplica")

    if global_changes:
        head += "\n📌 <b>Curva GLOBAL</b> (aplica as keywords sem dado proprio) — horas que mudam:\n"
        for g in global_changes:
            arrow = "🔺" if g["mult"] > g["hardcoded"] else "🔻"
            head += "%s %02dh — ROAS %.1f → <b>%.2f</b> (era %.2f)\n" % (
                arrow, g["event_hour"], g["roas"] or 0, g["mult"], g["hardcoded"])

    if entity_changes:
        head += "\n🎯 <b>Keywords com curva PROPRIA</b> (recomendacao individual):\n"
        by_kw = {}
        for e in entity_changes:
            kw = e["keyword_text"] or "(sem texto)"
            by_kw.setdefault(kw, []).append(
                "%02dh→%.2f" % (e["event_hour"], e["mult"]))
        for kw, chgs in list(by_kw.items())[:15]:
            head += "• <b>%s</b>: %s\n" % (kw[:30], ", ".join(chgs[:8]))
    else:
        head += "\n(nenhuma keyword com dado proprio suficiente ainda — todas seguem a curva GLOBAL recalibrada)\n"

    if not global_changes and not entity_changes:
        head += "\nNenhuma recomendacao: as curvas ja batem com a atual."
    return head


def run_dayparting_calibration():
    conn = get_conn()
    try:
        n = run_calibration(conn)
        summary, global_changes, entity_changes = load_summary(conn)
        applied = False
        if APPLY_ENABLED:
            # Aplicacao real do bid (pilotos) e um passo separado e gated. Fase 1 entrega
            # o calculo + digest; o hook de escrita entra quando o dono ligar a trava.
            log.info("APPLY_ENABLED=true — aplicacao real ainda nao acoplada ao applier; mantendo advisory")
        digest = build_digest(summary, global_changes, entity_changes, applied)
        log.info("calibracao keyword x hora: %s celulas | %s keywords | %s com curva propria | %s com recomendacao",
                 n, summary["keywords"], summary["kw_entity"], summary["kw_com_rec"])
        log.info("DIGEST:\n%s", digest)
        send_telegram(digest)
    finally:
        conn.close()


if __name__ == "__main__":
    run_dayparting_calibration()
