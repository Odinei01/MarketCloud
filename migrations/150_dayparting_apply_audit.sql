-- 150_dayparting_apply_audit.sql
-- Auditoria do APPLY da calibracao de dayparting (escrita real do schedule).
-- Padrao dos outros executores: audit-antes-da-escrita, gated (kill-switch OFF),
-- allowlist (so os 3 pilotos de keyword). Cada tentativa (dry-run ou real) grava
-- aqui ANTES de tocar o schedule.
CREATE TABLE IF NOT EXISTS marketcloud_gold.dayparting_apply_audit (
    id            bigserial PRIMARY KEY,
    created_at    timestamptz NOT NULL DEFAULT now(),
    keyword_id    text NOT NULL,
    keyword_text  text,
    profile_id    text,
    dry_run       boolean NOT NULL,
    applied       boolean NOT NULL DEFAULT false,
    hours_changed int NOT NULL DEFAULT 0,
    plan_json     jsonb NOT NULL DEFAULT '[]',
    result        text,
    actor         text
);
CREATE INDEX IF NOT EXISTS idx_dayparting_apply_audit_kw ON marketcloud_gold.dayparting_apply_audit (keyword_id, created_at DESC);
