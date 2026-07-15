-- =====================================================================
-- Fix DEFINITIVO do dado AMS (payload cru capturado, §42):
--  - sp-traffic vem no grão KEYWORD×hora×placement (não campanha) e os valores
--    são DELTAS/restatement (ex.: impressions:-3), com idempotency_id.
--  - O consumidor fazia last-write-wins -> colapsava ~63 keywords em 1 e guardava
--    o último delta -> ~98% de perda (SUM impressions=506 absurdo).
--
-- Correção (mínima e correta):
--  1) DEDUP por idempotency_id (ams_seen_events): torna a SOMA segura apesar do
--     at-least-once do SQS.
--  2) Consumidor passa a ACUMULAR (+=) traffic em vez de overwrite (ver consumer.go):
--     campanha×hora = soma de todas as keywords; keyword×hora = soma dos deltas.
--  3) Base limpa: TRUNCATE dos landings (o histórico colapsado é lixo; restatements
--     dos últimos ~14d reentram e reacumulam; datas antigas do ML seguem no CSV).
--
-- Conversão fica como last-write-wins por ora (payload sp-conversion ainda não
-- capturado — está 0 por delay de atribuição; validar delta-vs-absoluto quando fluir).
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_bronze.ams_seen_events (
    idempotency_id TEXT PRIMARY KEY,
    seen_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ams_seen_events_seen_at ON marketcloud_bronze.ams_seen_events (seen_at);

-- base limpa p/ o modelo de acumulação (o dado atual é o colapso last-write-wins)
TRUNCATE marketcloud_bronze.bronze_ams_hourly;
TRUNCATE marketcloud_bronze.bronze_ams_hourly_target;

-- prune do dedup (>15d cobre a janela de reentrega/restatement) — chamável no ciclo
CREATE OR REPLACE FUNCTION marketcloud_bronze.prune_ams_seen_events()
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE n BIGINT;
BEGIN
    DELETE FROM marketcloud_bronze.ams_seen_events WHERE seen_at < NOW() - INTERVAL '15 days';
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;
