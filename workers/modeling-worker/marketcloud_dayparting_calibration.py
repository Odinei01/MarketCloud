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
                count(DISTINCT keyword_id)                                      AS keywords,
                count(DISTINCT keyword_id) FILTER (WHERE gate='OK' AND action<>'HOLD') AS kw_com_rec,
                count(*) FILTER (WHERE gate='OK' AND action='UP')               AS boosts,
                count(*) FILTER (WHERE gate='OK' AND action='DOWN')             AS cuts,
                count(*) FILTER (WHERE gate<>'OK' OR action='HOLD')             AS held
            FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
        """)
        summary = cur.fetchone()
        # Recomendacoes com PROVA FORTE (gate OK). Agrupa por hora+scope+direcao pois o
        # sinal (global/campanha) aplica a varias keywords contra o % publicado de cada.
        cur.execute("""
            SELECT event_hour, scope, action,
                   round(avg(hour_roas),1) roas, round(avg(scope_avg_roas),1) media,
                   max(weeks_of_data) sem, round(max(spend)) gasto,
                   count(DISTINCT keyword_id) kws
            FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
            WHERE gate='OK' AND action<>'HOLD'
            GROUP BY event_hour, scope, action
            ORDER BY event_hour
        """)
        global_changes = cur.fetchall()
        # Recomendacoes por keyword com CURVA PROPRIA (ENTITY) — mudanca individual.
        cur.execute("""
            SELECT keyword_text, event_hour,
                   (published_multiplier*100)::int de, (recommended_multiplier*100)::int para
            FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
            WHERE scope='ENTITY' AND gate='OK' AND action<>'HOLD'
            ORDER BY keyword_text, event_hour
        """)
        entity_changes = cur.fetchall()
    return summary, global_changes, entity_changes


def build_digest(summary, global_changes, entity_changes, applied):
    head = "🕐 <b>Calibracao Dayparting (keyword x hora)</b> — trailing %sd\n" % WINDOW_DAYS
    head += "%s keywords · <b>%s com recomendacao</b> (prova forte: ≥2 sem, ≥R$20) · ↑%s ↓%s\n" % (
        summary["keywords"], summary["kw_com_rec"], summary["boosts"], summary["cuts"])
    head += "Baseline = <b>sua curva publicada</b>. So mexe com prova; senao mantem seu %.\n"
    head += "Modo: <b>%s</b>\n" % ("APLICANDO (pilotos)" if applied else "ADVISORY — nao aplica")

    if global_changes:
        head += "\n📌 <b>Ajustes com prova</b> (hora: ROAS vs media da hora, em N semanas → direcao):\n"
        for g in global_changes:
            arrow = "🔺" if g["action"] == "UP" else "🔻"
            head += "%s %02dh [%s] ROAS %.1f vs media %.1f · %s sem → <b>%s</b> em %s kw\n" % (
                arrow, g["event_hour"], g["scope"], g["roas"] or 0, g["media"] or 0,
                g["sem"], "subir" if g["action"] == "UP" else "cortar", g["kws"])

    if entity_changes:
        head += "\n🎯 <b>Keywords com curva PROPRIA</b> (individual):\n"
        by_kw = {}
        for e in entity_changes:
            kw = e["keyword_text"] or "(sem texto)"
            by_kw.setdefault(kw, []).append("%02dh %s%%→%s%%" % (e["event_hour"], e["de"], e["para"]))
        for kw, chgs in list(by_kw.items())[:12]:
            head += "• <b>%s</b>: %s\n" % (kw[:28], ", ".join(chgs[:6]))

    if not global_changes and not entity_changes:
        head += "\nNenhuma recomendacao com prova forte ainda — mantem suas curvas. Medindo p/ aprender."
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
        log.info("calibracao keyword x hora: %s celulas | %s keywords | %s com recomendacao (prova forte) | up=%s down=%s held=%s",
                 n, summary["keywords"], summary["kw_com_rec"], summary["boosts"], summary["cuts"], summary["held"])
        log.info("DIGEST:\n%s", digest)
        send_telegram(digest)
    finally:
        conn.close()


if __name__ == "__main__":
    run_dayparting_calibration()
