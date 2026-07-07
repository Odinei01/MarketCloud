-- =====================================================================
-- ZMC Feedback Loop V1 — decisão humana + outcome tracking + labels de ML
--
-- Por quê: hoje o ML aprende a REGRA Gold, não o RESULTADO. Sem registrar o
-- que aconteceu depois de uma recomendação, é impossível treinar "essa ação
-- melhorou o ROAS?". Este loop cria os LABELS que transformam o ML de
-- replicador de regra em preditor de resultado.
--
-- Regra soberana: NADA aqui executa na Amazon. As tabelas registram a decisão
-- humana e a execução MANUAL (o que a pessoa fez no console), e MEDEM o
-- resultado a partir do Silver. Zero mutação, zero chamada de API.
--
-- Fluxo:
--   G015 (fila) --> humano decide --> recommendation_decisions
--   humano aplica na Amazon (manual) --> execution_status=EXECUTED
--   após janela de avaliação --> recommendation_outcomes (label)
--   decisions + outcomes --> gold_training_labels_v1 (X,y do ML)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS marketcloud_recommendations;

-- ---------------------------------------------------------------------
-- 1) recommendation_decisions — decisão humana sobre uma recomendação G015
--    Escrita pela UI. Uma decisão corrente por recommendation_id (upsert).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marketcloud_recommendations.recommendation_decisions (
    decision_id      BIGSERIAL PRIMARY KEY,
    recommendation_id TEXT NOT NULL UNIQUE,

    tenant_id       TEXT NOT NULL,
    amc_instance_id TEXT NOT NULL,
    ads_profile_id  TEXT NOT NULL,

    -- snapshot da recomendação no momento da decisão (imutável p/ auditoria e ML)
    entity_type     TEXT NOT NULL,
    entity_key      TEXT NOT NULL,
    campaign_id     TEXT,
    campaign_name   TEXT,
    ad_product_type TEXT,
    ad_group_name   TEXT,
    event_hour      INTEGER,
    customer_search_term TEXT,

    recommended_action        TEXT,
    recommended_bid_multiplier NUMERIC(18,4),
    priority_score            NUMERIC(18,2),
    priority_bucket           TEXT,
    final_risk_level          TEXT,
    final_confidence_score    NUMERIC(18,8),
    gold_evidence_json        JSONB,
    prediction_evidence_json  JSONB,
    features_snapshot         JSONB,

    -- decisão humana
    decision        TEXT NOT NULL DEFAULT 'NOT_DECIDED',   -- NOT_DECIDED | APPROVED | REJECTED | SNOOZED | MODIFIED
    decided_action  TEXT,                                  -- = recommended_action, ou o override se MODIFIED
    decided_bid_multiplier NUMERIC(18,4),
    decided_by      TEXT,
    decision_notes  TEXT,
    decided_at      TIMESTAMPTZ,

    -- execução MANUAL na Amazon (registro, não ação)
    execution_status TEXT NOT NULL DEFAULT 'NOT_EXECUTED', -- NOT_EXECUTED | EXECUTED | SKIPPED | ROLLED_BACK
    executed_at      TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_decision CHECK (decision IN ('NOT_DECIDED','APPROVED','REJECTED','SNOOZED','MODIFIED')),
    CONSTRAINT chk_execution CHECK (execution_status IN ('NOT_EXECUTED','EXECUTED','SKIPPED','ROLLED_BACK'))
);

CREATE INDEX IF NOT EXISTS idx_rec_decisions_tenant   ON marketcloud_recommendations.recommendation_decisions (tenant_id, decision);
CREATE INDEX IF NOT EXISTS idx_rec_decisions_campaign ON marketcloud_recommendations.recommendation_decisions (tenant_id, campaign_id, ad_product_type);
CREATE INDEX IF NOT EXISTS idx_rec_decisions_exec     ON marketcloud_recommendations.recommendation_decisions (execution_status, executed_at);


-- ---------------------------------------------------------------------
-- 2) recommendation_outcomes — medição antes/depois (o LABEL do ML)
--    Escrita pelo job de outcome (materializada, point-in-time).
--    Medida no grão CAMPANHA (silver_campaign_daily) — onde o AMC não
--    suprime, garantindo sinal financeiro confiável.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marketcloud_recommendations.recommendation_outcomes (
    outcome_id       BIGSERIAL PRIMARY KEY,
    recommendation_id TEXT NOT NULL,
    decision_id      BIGINT REFERENCES marketcloud_recommendations.recommendation_decisions(decision_id) ON DELETE CASCADE,

    tenant_id       TEXT NOT NULL,
    amc_instance_id TEXT NOT NULL,
    ads_profile_id  TEXT NOT NULL,

    entity_type     TEXT,
    entity_key      TEXT,
    campaign_id     TEXT,
    ad_product_type TEXT,
    decided_action  TEXT,

    baseline_window_start DATE,
    baseline_window_end   DATE,
    eval_window_start     DATE,
    eval_window_end       DATE,

    baseline_spend  NUMERIC(18,4), baseline_orders NUMERIC(18,4),
    baseline_sales  NUMERIC(18,4), baseline_roas   NUMERIC(18,4),
    eval_spend      NUMERIC(18,4), eval_orders     NUMERIC(18,4),
    eval_sales      NUMERIC(18,4), eval_roas       NUMERIC(18,4),

    delta_spend NUMERIC(18,4), delta_sales NUMERIC(18,4), delta_roas NUMERIC(18,4),

    outcome_label TEXT,   -- IMPROVED | NEUTRAL | WORSENED
    outcome_notes TEXT,

    measured_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_rec_outcome UNIQUE (recommendation_id, eval_window_end)
);

CREATE INDEX IF NOT EXISTS idx_rec_outcomes_label ON marketcloud_recommendations.recommendation_outcomes (tenant_id, outcome_label);
CREATE INDEX IF NOT EXISTS idx_rec_outcomes_rec   ON marketcloud_recommendations.recommendation_outcomes (recommendation_id);


-- ---------------------------------------------------------------------
-- 3) G015 v2 — fila de revisão com status REAL da decisão (join)
--    Substitui os hardcodes NOT_DECIDED/NOT_EXECUTED da migração 044.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS marketcloud_gold.gold_review_queue_v2 CASCADE;
CREATE VIEW marketcloud_gold.gold_review_queue_v2 AS
SELECT
    p.tenant_id, p.amc_instance_id, p.ads_profile_id,
    p.recommendation_id, p.priority_rank, p.priority_bucket, p.priority_score,
    p.entity_type, p.entity_key,
    p.campaign_id, p.campaign_name, p.ad_product_type, p.ad_group_name, p.event_hour, p.customer_search_term,
    p.final_action_type, p.final_bid_multiplier, p.final_confidence_score, p.final_risk_level,
    p.agreement, p.action_conflict, p.recommendation_status,
    p.spend, p.clicks, p.orders, p.sales, p.roas, p.cpc, p.conversion_rate,
    COALESCE(d.decision, 'NOT_DECIDED')          AS human_decision_status,
    COALESCE(d.execution_status, 'NOT_EXECUTED') AS execution_status,
    d.decided_by, d.decided_at, d.decision_notes,
    p.gold_evidence_json, p.prediction_evidence_json, p.features_snapshot,
    p.created_at
FROM marketcloud_gold.gold_recommendation_priority_v2 p
LEFT JOIN marketcloud_recommendations.recommendation_decisions d
    ON d.recommendation_id = p.recommendation_id;


-- ---------------------------------------------------------------------
-- 4) gold_training_labels_v1 — a fonte (X, y) do ML de outcome
--    features_snapshot (X) + decided_action + outcome_label (y).
--    É isto que o ML V2 vai treinar: "essa ação, nesse contexto, melhorou?"
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW marketcloud_recommendations.gold_training_labels_v1 AS
SELECT
    d.recommendation_id,
    d.tenant_id, d.amc_instance_id, d.ads_profile_id,
    d.entity_type, d.entity_key,
    d.campaign_id, d.campaign_name, d.ad_product_type,
    d.recommended_action,
    d.decision,
    d.decided_action,
    d.execution_status,
    d.final_risk_level, d.priority_score, d.final_confidence_score,
    d.features_snapshot,
    d.gold_evidence_json,
    o.baseline_roas, o.eval_roas, o.delta_roas,
    o.baseline_spend, o.eval_spend, o.delta_spend,
    o.outcome_label,
    o.eval_window_start, o.eval_window_end,
    o.measured_at
FROM marketcloud_recommendations.recommendation_decisions d
JOIN marketcloud_recommendations.recommendation_outcomes o
    ON o.recommendation_id = d.recommendation_id
WHERE d.decision IN ('APPROVED','MODIFIED','REJECTED')
  AND o.outcome_label IS NOT NULL;


-- ---------------------------------------------------------------------
-- 5) v_outcome_candidates — decisões prontas para medição de outcome
--    (executadas e com janela de avaliação já decorrida no Silver).
--    O job de outcome consome esta view.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW marketcloud_recommendations.v_outcome_candidates AS
WITH silver_max AS (
    SELECT MAX(data_date) AS max_date FROM marketcloud_silver.silver_campaign_daily
)
SELECT
    d.decision_id, d.recommendation_id,
    d.tenant_id, d.amc_instance_id, d.ads_profile_id,
    d.entity_type, d.entity_key, d.campaign_id, d.ad_product_type, d.decided_action,
    d.decided_at::date               AS decision_date,
    (d.decided_at::date - INTERVAL '7 days')::date AS baseline_window_start,
    d.decided_at::date               AS baseline_window_end,
    d.decided_at::date               AS eval_window_start,
    (d.decided_at::date + INTERVAL '7 days')::date AS eval_window_end,
    s.max_date
FROM marketcloud_recommendations.recommendation_decisions d
CROSS JOIN silver_max s
LEFT JOIN marketcloud_recommendations.recommendation_outcomes o
    ON o.recommendation_id = d.recommendation_id
    AND o.eval_window_end = (d.decided_at::date + INTERVAL '7 days')::date
WHERE d.decision IN ('APPROVED','MODIFIED','REJECTED')
  AND d.campaign_id IS NOT NULL
  AND s.max_date >= (d.decided_at::date + INTERVAL '7 days')::date  -- janela de avaliação decorrida
  AND o.outcome_id IS NULL;                                          -- ainda não medida


-- =====================================================================
-- JOB DE OUTCOME (documentado) — roda periodicamente; mede campanha
-- antes/depois no Silver e materializa o label. NÃO executa nada na Amazon.
--
-- INSERT INTO marketcloud_recommendations.recommendation_outcomes (
--     recommendation_id, decision_id, tenant_id, amc_instance_id, ads_profile_id,
--     entity_type, entity_key, campaign_id, ad_product_type, decided_action,
--     baseline_window_start, baseline_window_end, eval_window_start, eval_window_end,
--     baseline_spend, baseline_orders, baseline_sales, baseline_roas,
--     eval_spend, eval_orders, eval_sales, eval_roas,
--     delta_spend, delta_sales, delta_roas, outcome_label)
-- SELECT
--     c.recommendation_id, c.decision_id, c.tenant_id, c.amc_instance_id, c.ads_profile_id,
--     c.entity_type, c.entity_key, c.campaign_id, c.ad_product_type, c.decided_action,
--     c.baseline_window_start, c.baseline_window_end, c.eval_window_start, c.eval_window_end,
--     b.spend, b.orders, b.sales, CASE WHEN b.spend>0 THEN b.sales/b.spend ELSE 0 END,
--     e.spend, e.orders, e.sales, CASE WHEN e.spend>0 THEN e.sales/e.spend ELSE 0 END,
--     (e.spend-b.spend), (e.sales-b.sales),
--     (CASE WHEN e.spend>0 THEN e.sales/e.spend ELSE 0 END) - (CASE WHEN b.spend>0 THEN b.sales/b.spend ELSE 0 END),
--     CASE
--       WHEN (CASE WHEN e.spend>0 THEN e.sales/e.spend ELSE 0 END) - (CASE WHEN b.spend>0 THEN b.sales/b.spend ELSE 0 END) >  0.5 THEN 'IMPROVED'
--       WHEN (CASE WHEN e.spend>0 THEN e.sales/e.spend ELSE 0 END) - (CASE WHEN b.spend>0 THEN b.sales/b.spend ELSE 0 END) < -0.5 THEN 'WORSENED'
--       ELSE 'NEUTRAL' END
-- FROM marketcloud_recommendations.v_outcome_candidates c
-- LEFT JOIN LATERAL (SELECT SUM(spend) spend, SUM(orders) orders, SUM(sales) sales
--     FROM marketcloud_silver.silver_campaign_daily s
--     WHERE s.campaign_id=c.campaign_id AND s.ad_product_type=c.ad_product_type
--       AND s.data_date >= c.baseline_window_start AND s.data_date < c.baseline_window_end) b ON TRUE
-- LEFT JOIN LATERAL (SELECT SUM(spend) spend, SUM(orders) orders, SUM(sales) sales
--     FROM marketcloud_silver.silver_campaign_daily s
--     WHERE s.campaign_id=c.campaign_id AND s.ad_product_type=c.ad_product_type
--       AND s.data_date >= c.eval_window_start AND s.data_date < c.eval_window_end) e ON TRUE
-- ON CONFLICT (recommendation_id, eval_window_end) DO NOTHING;
-- =====================================================================
