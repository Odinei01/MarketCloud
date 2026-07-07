-- =====================================================================
-- Desacopla a ingestão Bronze do ciclo de vida do run.
--
-- Problema: o modeling-worker consome runs em status SUCCEEDED/RESULT_DOWNLOADED
-- e os move para MODELING_COMPLETED. O loop de auto-ingest do orchestrator, que
-- procurava status='SUCCEEDED', perdia a corrida — nada era ingerido no Bronze.
--
-- Solução: rastrear a ingestão Bronze por coluna dedicada, independente de
-- status. O loop passa a buscar bronze_ingested_at IS NULL.
-- =====================================================================

ALTER TABLE query_runs
    ADD COLUMN IF NOT EXISTS bronze_ingested_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_query_runs_bronze_pending
    ON query_runs (created_at)
    WHERE bronze_ingested_at IS NULL;
