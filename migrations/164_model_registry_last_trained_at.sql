-- 164_model_registry_last_trained_at.sql
-- FIX do bug cosmetico que causou falso alarme "ML parou". O script de treino faz
-- INSERT ... ON CONFLICT DO UPDATE atualizando training_rows/metrics, mas NAO mexe em
-- created_at nem training_window_end -> esses campos ficam travados na 1a criacao
-- (07/09) e o painel parece que o modelo nao treina ha 13 dias, quando na verdade
-- retreina de hora em hora (ml_hourly_run_status prova: 259 rodadas COMPLETED).
--
-- Fix no NIVEL DO BANCO (duravel, independe do script que so existe no container):
-- coluna last_trained_at + trigger que carimba now() a cada INSERT/UPDATE (upsert).

ALTER TABLE marketcloud_features.model_registry
  ADD COLUMN IF NOT EXISTS last_trained_at timestamptz;

-- backfill: ultimo treino REAL por model_version (via run_status), senao created_at
UPDATE marketcloud_features.model_registry r
SET last_trained_at = COALESCE(
  (SELECT max(s.finished_at) FROM marketcloud_gold.ml_hourly_run_status s
   WHERE s.model_version = r.model_version AND s.status='COMPLETED'),
  r.created_at);

CREATE OR REPLACE FUNCTION marketcloud_features._stamp_last_trained_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.last_trained_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_stamp_last_trained_at ON marketcloud_features.model_registry;
CREATE TRIGGER trg_stamp_last_trained_at
  BEFORE INSERT OR UPDATE ON marketcloud_features.model_registry
  FOR EACH ROW EXECUTE FUNCTION marketcloud_features._stamp_last_trained_at();
