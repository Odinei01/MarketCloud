"""
Apply ML-approved campaign/hour recommendations to the BID schedule.

This script does not write bids to Amazon. It updates the BID schedule in the
Zanom Ads Robot, so Cycle B applies the new multiplier in the next hourly run.
"""

import json
import logging
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras

logging.basicConfig(level=logging.INFO, format="%(asctime)s [ML-AUTO-APPLY] %(levelname)s %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgres://mcadmin:mcsecret@postgres:5432/marketcloud")
BID_ROBOT_API_BASE = os.environ.get("BID_ROBOT_API_BASE", "http://host.docker.internal:8080").rstrip("/")
AUTO_APPLY_ENABLED = os.environ.get("ML_AUTO_APPLY_CAMPAIGN_ENABLED", "false").lower() == "true"
AUTO_APPLY_DRY_RUN = os.environ.get("ML_AUTO_APPLY_DRY_RUN", "false").lower() == "true"
AUTO_APPLY_MAX = int(os.environ.get("ML_AUTO_APPLY_MAX_PER_RUN", "10"))
AUTO_APPLY_CONFIDENCE = tuple(x.strip().upper() for x in os.environ.get("ML_AUTO_APPLY_CONFIDENCE", "HIGH,MEDIUM").split(",") if x.strip())
FULL_AUTO_CAMPAIGN_IDS = {x.strip() for x in os.environ.get("ML_FULL_AUTO_CAMPAIGN_IDS", "").split(",") if x.strip()}
FULL_AUTO_CAMPAIGN_NAMES = {
    " ".join(x.strip().lower().split())
    for x in os.environ.get("ML_FULL_AUTO_CAMPAIGN_NAMES", "").split(",")
    if x.strip()
}
FULL_AUTO_REQUIRE_ALLOWLIST = os.environ.get("ML_FULL_AUTO_REQUIRE_ALLOWLIST", "true").lower() != "false"


def norm_campaign_name(value):
    return " ".join(str(value or "").strip().lower().split())


def campaign_allowed(row, db_campaign_ids=None, db_campaign_names=None):
    db_campaign_ids = db_campaign_ids or set()
    db_campaign_names = db_campaign_names or set()
    campaign_id = str(row.get("campaign_id") or "").strip()
    campaign_name = norm_campaign_name(row.get("campaign_name"))
    has_allowlist = bool(FULL_AUTO_CAMPAIGN_IDS or FULL_AUTO_CAMPAIGN_NAMES or db_campaign_ids or db_campaign_names)
    if not has_allowlist:
        return not FULL_AUTO_REQUIRE_ALLOWLIST
    # GOVERNANCA (P0 auditoria 16/07): full-auto casa SO por campaign_id.
    # Casar por nome deixava qualquer campanha nova batizada com um nome da
    # allowlist entrar em full-auto sozinha. Env por nome (_NAMES) so vale se
    # nao tiver id nenhum resolvivel — caminho de escape, nao regra.
    if not campaign_id:
        # sem id na linha: so o fallback por nome via ENV, nunca via banco
        return campaign_name in FULL_AUTO_CAMPAIGN_NAMES and not FULL_AUTO_CAMPAIGN_IDS and not db_campaign_ids
    return campaign_id in FULL_AUTO_CAMPAIGN_IDS or campaign_id in db_campaign_ids


def get_conn():
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def pending_profile_ids(details):
    out = []
    seen = set()
    if details is None:
        return out
    if isinstance(details, str):
        details = json.loads(details)
    for rule in details or []:
        if str(rule.get("status", "")).upper() != "PENDING":
            continue
        profile_id = str(rule.get("profile_id") or "").strip()
        if profile_id and profile_id not in seen:
            seen.add(profile_id)
            out.append(profile_id)
    return out


def load_candidates(conn):
    with conn.cursor() as cur:
        cur.execute(
            """
            WITH campaign_ids AS (
                -- ID vem da FONTE UNICA gold_campaign_identity (migration 092),
                -- nao mais de bronze_ams_hourly. A AMS bronze so tem SP e nome
                -- vazio em varias linhas, entao um candidato podia ser ignorado
                -- por nao resolver o id pelo caminho antigo mesmo estando ligado
                -- (P1 da auditoria 16/07). O mapa canonico e 1:1 nome<->id.
                SELECT campaign_norm, campaign_id FROM marketcloud_gold.gold_campaign_identity
            )
            -- O ALVO VEM DO ML (migration 073), nao do "atual + 0.3" da v1.
            -- A v1 sugere LEAST(1.0, mult_min + 0.3): empurra toda hora que o ML
            -- aprova pra lance cheio, sem nuance, e o alvo se move a cada
            -- aplicacao (calculado sobre o multiplicador atual). O alvo do ML e
            -- absoluto e por hora: aplicou, alinhou, acabou.
            SELECT r.recommendation_id, r.campaign_name, r.event_hour, r.action_type,
                   r.current_multiplier, r.confidence, r.priority_score, r.roas, r.orders,
                   r.ml_good_hour, r.ml_agrees, r.ml_conversion_probability, r.ml_expected_roas,
                   t.ml_multiplier AS suggested_multiplier,
                   -- overlap_rule_details FALTAVA no SELECT: pending_profile_ids(row.get(...))
                   -- vinha None e o worker achava que nao havia perfil pendente, entao
                   -- NUNCA aplicava (bug do auto-apply, achado da auditoria 16/07).
                   -- Filtra PENDING contra o ALVO DO ML, nao a sugestao da v1: so
                   -- entra profile cujo multiplicador ainda esta abaixo do alvo do ML.
                   (SELECT jsonb_agg(e) FROM jsonb_array_elements(r.overlap_rule_details) e
                    WHERE e->>'status' = 'PENDING'
                      AND (e->>'multiplier')::float8 < t.ml_multiplier - 0.001) AS overlap_rule_details,
                   c.campaign_id,
                   COALESCE(i.tenant_id, 'zanom') AS tenant_id,
                   COALESCE(i.amc_instance_id, 'amcoo5vzswt') AS amc_instance_id,
                   COALESCE(i.ads_profile_id, '3084626225435227') AS ads_profile_id
            FROM marketcloud_gold.gold_hourly_recommendations_v1 r
            JOIN marketcloud_gold.gold_hourly_ml_target_multiplier t
              ON t.campaign_name = r.campaign_name AND t.event_hour = r.event_hour
            LEFT JOIN campaign_ids c ON c.campaign_norm = lower(trim(r.campaign_name))
            LEFT JOIN LATERAL (
                SELECT tenant_id, amc_instance_id, ads_profile_id
                FROM marketcloud_control.amc_instances
                LIMIT 1
            ) i ON TRUE
            WHERE r.action_type = 'BID_UP'
              AND r.confidence = ANY(%s)
              AND r.rules_still_need_change > 0
              AND r.ml_good_hour IS TRUE
              AND r.ml_agrees IS TRUE
              -- so SOBE, e so quando o alvo do ML de fato pede mais que o atual.
              -- A faixa morta de 0.05 evita aplicar micro-ajuste sozinho.
              AND t.ml_multiplier > r.current_multiplier + 0.05
              -- GRUPO DE CONTROLE: celula sorteada como CONTROLE nao e tocada.
              -- Sem isso o holdout e ficcao: o robo mexeria no controle e nao
              -- haveria contrafactual pra comparar com o tratamento.
              AND NOT EXISTS (
                  SELECT 1 FROM marketcloud_control.holdout_cells hc
                  WHERE hc.campaign_name = r.campaign_name
                    AND hc.event_hour = r.event_hour
                    AND hc.grupo = 'CONTROLE'
              )
            ORDER BY r.priority_score DESC NULLS LAST, r.computed_at DESC
            LIMIT %s
            """,
            (list(AUTO_APPLY_CONFIDENCE), AUTO_APPLY_MAX),
        )
        return [dict(row) for row in cur.fetchall()]


def load_db_allowlist(conn):
    ids = set()
    names = set()
    with conn.cursor() as cur:
        try:
            cur.execute(
                """
                SELECT campaign_id, campaign_name
                FROM marketcloud_control.ml_full_auto_campaign_flags
                WHERE enabled IS TRUE
                """
            )
            for row in cur.fetchall():
                campaign_id = str(row.get("campaign_id") or "").strip()
                campaign_name = norm_campaign_name(row.get("campaign_name"))
                if campaign_id:
                    ids.add(campaign_id)
                if campaign_name:
                    names.add(campaign_name)
        except Exception as exc:
            log.warning("full-auto DB allowlist indisponivel: %s", exc)
            conn.rollback()
    return ids, names


def post_apply(payload):
    raw = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        BID_ROBOT_API_BASE + "/api/amazon/ads/bid-robot/schedules/apply-suggestion",
        data=raw,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body or "{}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"bid robot HTTP {exc.code}: {body[:300]}") from exc


def record_decision(conn, row, response):
    if int(response.get("updated_count") or 0) <= 0:
        return
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO marketcloud_recommendations.recommendation_decisions (
                recommendation_id, tenant_id, amc_instance_id, ads_profile_id,
                entity_type, entity_key, campaign_id, campaign_name, ad_product_type,
                event_hour, recommended_action, recommended_bid_multiplier,
                priority_score, priority_bucket, final_risk_level, final_confidence_score,
                gold_evidence_json, prediction_evidence_json, features_snapshot,
                decision, decided_action, decided_bid_multiplier, decided_by, decision_notes,
                decided_at, execution_status, executed_at
            ) VALUES (
                %s, %s, %s, %s,
                'CAMPAIGN_HOUR', %s, NULLIF(%s,''), %s, 'SPONSORED_PRODUCTS',
                %s, %s, %s,
                %s, %s, %s, %s,
                %s::jsonb, %s::jsonb, %s::jsonb,
                'APPROVED', %s, %s, 'ML_AUTO_APPLY', %s,
                NOW(), 'EXECUTED', NOW()
            )
            ON CONFLICT (recommendation_id) DO UPDATE SET
                recommended_bid_multiplier=EXCLUDED.recommended_bid_multiplier,
                priority_score=EXCLUDED.priority_score,
                final_risk_level=EXCLUDED.final_risk_level,
                final_confidence_score=EXCLUDED.final_confidence_score,
                prediction_evidence_json=EXCLUDED.prediction_evidence_json,
                features_snapshot=EXCLUDED.features_snapshot,
                decision='APPROVED',
                decided_action=EXCLUDED.decided_action,
                decided_bid_multiplier=EXCLUDED.decided_bid_multiplier,
                decided_by='ML_AUTO_APPLY',
                decision_notes=EXCLUDED.decision_notes,
                decided_at=NOW(),
                execution_status='EXECUTED',
                executed_at=NOW(),
                updated_at=NOW()
            """,
            (
                row["recommendation_id"], row["tenant_id"], row["amc_instance_id"], row["ads_profile_id"],
                f"{row.get('campaign_name','')}:{row.get('event_hour')}", row.get("campaign_id") or "", row.get("campaign_name"),
                int(row["event_hour"]), row["action_type"], float(row["suggested_multiplier"]),
                float(row.get("priority_score") or 0), row.get("confidence"), row.get("confidence"), float(row.get("ml_conversion_probability") or 0),
                json.dumps({"source": "gold_hourly_ml_target_multiplier(prior=ML)+gold_hourly_recommendations_v1(gatilho)", "roas": float(row.get("roas") or 0), "orders": int(row.get("orders") or 0)}),
                json.dumps({"ml_good_hour": row.get("ml_good_hour"), "ml_agrees": row.get("ml_agrees"), "ml_conversion_probability": float(row.get("ml_conversion_probability") or 0), "ml_expected_roas": float(row.get("ml_expected_roas") or 0)}),
                json.dumps({"bid_robot_response": response, "current_multiplier": float(row.get("current_multiplier") or 0), "suggested_multiplier": float(row.get("suggested_multiplier") or 0)}),
                row["action_type"], float(row["suggested_multiplier"]), "Aplicado automaticamente pelo ML apos concordancia do modelo com a recomendacao.",
            ),
        )
    conn.commit()


def main():
    if not AUTO_APPLY_ENABLED:
        log.info("auto apply disabled")
        return
    if not BID_ROBOT_API_BASE:
        log.warning("BID_ROBOT_API_BASE vazio; auto apply bloqueado")
        return
    applied = 0
    considered = 0
    with get_conn() as conn:
        db_campaign_ids, db_campaign_names = load_db_allowlist(conn)
        total_ids = len(FULL_AUTO_CAMPAIGN_IDS | db_campaign_ids)
        total_names = len(FULL_AUTO_CAMPAIGN_NAMES | db_campaign_names)
        if FULL_AUTO_REQUIRE_ALLOWLIST and total_ids == 0 and total_names == 0:
            log.warning("auto apply bloqueado: full-auto allowlist vazia")
            return
        log.info(
            "full auto allowlist ids=%s names=%s require_allowlist=%s dry_run=%s",
            total_ids,
            total_names,
            FULL_AUTO_REQUIRE_ALLOWLIST,
            AUTO_APPLY_DRY_RUN,
        )
        candidates = load_candidates(conn)
        log.info("%s candidatos ML para auto-apply", len(candidates))
        for row in candidates:
            if not campaign_allowed(row, db_campaign_ids, db_campaign_names):
                log.info("skip %s campanha fora do full-auto: %s", row.get("recommendation_id"), row.get("campaign_name"))
                continue
            profile_ids = pending_profile_ids(row.get("overlap_rule_details"))
            if not profile_ids:
                log.info("skip %s sem profile pendente", row.get("recommendation_id"))
                continue
            considered += 1
            payload = {
                "recommendation_id": row["recommendation_id"],
                "campaign_name": row.get("campaign_name"),
                "hour": int(row["event_hour"]),
                "suggested_multiplier": float(row["suggested_multiplier"]),
                "profile_ids": profile_ids,
                "dry_run": AUTO_APPLY_DRY_RUN,
                "send_telegram": True,
                "source": "MARKETCLOUD_ML_AUTO_APPLY",
            }
            # Dry-run NAO faz POST. Antes o flag so viajava no payload e o POST
            # acontecia igual — dependia do robo respeitar. Um "dry-run" que
            # chama a API real e uma armadilha: se o outro lado ignora a flag,
            # aplica lance de verdade.
            if AUTO_APPLY_DRY_RUN:
                log.info("[DRY-RUN] aplicaria %s %s %02dh -> %s em %s profile(s)",
                         row.get("campaign_name"), row.get("recommendation_id"),
                         int(row["event_hour"]), float(row["suggested_multiplier"]), len(profile_ids))
                continue
            response = post_apply(payload)
            updated_count = int(response.get("updated_count") or 0)
            log.info("%s %s %02dh updated=%s aligned=%s failed=%s telegram=%s",
                     row.get("campaign_name"), row.get("recommendation_id"), int(row["event_hour"]),
                     updated_count, response.get("already_aligned_count"), response.get("failed_count"), response.get("telegram_status"))
            record_decision(conn, row, response)
            applied += updated_count
    log.info("auto apply concluido considered=%s applied_profiles=%s at=%s", considered, applied, datetime.now(timezone.utc).isoformat())


if __name__ == "__main__":
    main()
