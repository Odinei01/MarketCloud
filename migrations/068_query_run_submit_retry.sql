-- Retry com backoff no submit ao AMC.
-- Motivo: em 2026-07-15 as 8 queries do lote diario morreram com HTTP 502
-- (rajada/hiccup da API do AMC) e ficaram FAILED em silencio ate o dia seguinte.
-- O submit agora re-tenta; erro permanente de SQL (AMC_QUERY_REJECTED) nao passa
-- por aqui — ele aparece depois, no poll de status.
ALTER TABLE query_runs ADD COLUMN IF NOT EXISTS submit_attempts INT NOT NULL DEFAULT 0;
ALTER TABLE query_runs ADD COLUMN IF NOT EXISTS next_retry_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_query_runs_queued_retry
    ON query_runs (status, next_retry_at) WHERE status = 'QUEUED';

COMMENT ON COLUMN query_runs.submit_attempts IS 'Tentativas de submit ao AMC (retry com backoff exponencial).';
COMMENT ON COLUMN query_runs.next_retry_at IS 'Quando o submit pode ser re-tentado; NULL = imediato.';
