-- =====================================================================
-- Histórico de decisões do Robô ZANOM + reconstrução de outcome (labels ML)
--
-- amazon_ads_bid_decisions tem, por decisão: contexto (roas_ref, tacos_ref,
-- cpc_ref, margin, break_even), a ação (current_bid -> proposed_bid,
-- bid_delta%, decision) e a entidade (campaign_id) + data. O roas_ref é o
-- "antes"; o "depois" vem das métricas diárias já no lake.
--
-- RESSALVA HONESTA (gravada aqui e no dataset): as decisões são majoritaria-
-- mente dry_run/diagnostic (eligible_to_apply=false). Então este é um dataset
-- OBSERVACIONAL — mede a TRAJETÓRIA de ROAS após uma recomendação, não o
-- efeito causal da ação aplicada. É o primeiro conjunto rotulado real, mas
-- causalidade limpa exige ação aplicada ou grupo de controle.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_swarm_bid_decisions (
    decision_id      TEXT PRIMARY KEY,
    created_at       TIMESTAMPTZ,
    decision_date    DATE,
    campaign_id      TEXT,
    campaign_name    TEXT,
    ad_group_id      TEXT,
    keyword_id       TEXT,
    entity_type      TEXT,
    match_type       TEXT,
    target_text      TEXT,
    -- ação
    decision         TEXT,
    reason_code      TEXT,
    risk_level       TEXT,
    current_bid      NUMERIC(18,4),
    proposed_bid     NUMERIC(18,4),
    bid_delta_percent NUMERIC(18,4),
    amazon_rec_bid_median NUMERIC(18,4),
    dry_run          BOOLEAN,
    eligible_to_apply BOOLEAN,
    -- contexto (features "antes")
    roas_ref         NUMERIC(18,4),
    acos_ref         NUMERIC(18,8),
    tacos_ref        NUMERIC(18,8),
    cpc_ref          NUMERIC(18,4),
    cost_ref         NUMERIC(18,4),
    orders_ref       NUMERIC(18,4),
    attributed_sales_ref NUMERIC(18,4),
    impressions_ref  NUMERIC(18,4),
    clicks_ref       NUMERIC(18,4),
    ctr_ref          NUMERIC(18,8),
    margin_percent   NUMERIC(18,4),
    break_even_acos_percent NUMERIC(18,4),
    ingested_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_swarm_biddec_campaign ON marketcloud_bronze.bronze_swarm_bid_decisions (campaign_id, decision_date);

-- ingestão (snapshot repetível)
TRUNCATE marketcloud_bronze.bronze_swarm_bid_decisions;
INSERT INTO marketcloud_bronze.bronze_swarm_bid_decisions
SELECT
    CAST(id AS TEXT), created_at, analysis_window_to::date,
    CAST(campaign_id AS TEXT), campaign_name, CAST(ad_group_id AS TEXT), CAST(keyword_id AS TEXT),
    entity_type, match_type, target_text,
    decision, reason_code, risk_level,
    current_bid, proposed_bid, bid_delta_percent, amazon_recommended_bid_median,
    dry_run, eligible_to_apply,
    roas_ref, acos_ref, tacos_ref, cpc_ref, cost_ref, orders_ref, attributed_sales_ref,
    impressions_ref, clicks_ref, ctr_ref, margin_percent, break_even_acos_percent, NOW()
FROM swarm_src.amazon_ads_bid_decisions
WHERE campaign_id IS NOT NULL;


-- =====================================================================
-- Base rotulada: contexto (X) + ação + outcome (y)
-- before = roas_ref; after = ROAS da campanha na janela [D+1, D+7].
-- =====================================================================
CREATE OR REPLACE VIEW marketcloud_recommendations.swarm_decision_outcomes_v1 AS
WITH after_roas AS (
    SELECT d.decision_id,
        SUM(m.attributed_sales) AS after_sales,
        SUM(m.cost)             AS after_cost,
        CASE WHEN SUM(m.cost) > 0 THEN SUM(m.attributed_sales)/SUM(m.cost) ELSE 0 END AS after_roas,
        COUNT(*) AS after_days
    FROM marketcloud_bronze.bronze_swarm_bid_decisions d
    JOIN marketcloud_bronze.bronze_swarm_campaign_metrics m
        ON m.campaign_id = d.campaign_id
       AND m.data_date >  d.decision_date
       AND m.data_date <= d.decision_date + INTERVAL '7 days'
    GROUP BY d.decision_id
)
SELECT
    d.decision_id, d.decision_date, d.campaign_id, d.campaign_name,
    d.entity_type, d.match_type,
    -- ação
    d.decision AS action, d.reason_code, d.risk_level, d.dry_run, d.eligible_to_apply,
    d.current_bid, d.proposed_bid, d.bid_delta_percent,
    -- features (contexto no momento da decisão)
    d.roas_ref, d.acos_ref, d.tacos_ref, d.cpc_ref, d.cost_ref, d.orders_ref,
    d.impressions_ref, d.clicks_ref, d.ctr_ref, d.margin_percent, d.break_even_acos_percent,
    -- outcome
    a.after_roas, a.after_days,
    ROUND((a.after_roas - d.roas_ref)::numeric, 4) AS delta_roas,
    CASE
        WHEN a.after_roas - d.roas_ref >  0.5 THEN 'IMPROVED'
        WHEN a.after_roas - d.roas_ref < -0.5 THEN 'WORSENED'
        ELSE 'NEUTRAL'
    END AS outcome_label,
    'OBSERVATIONAL_MOSTLY_DRYRUN'::text AS label_caveat
FROM marketcloud_bronze.bronze_swarm_bid_decisions d
JOIN after_roas a ON a.decision_id = d.decision_id
WHERE d.decision IN ('CUT','KEEP')          -- decisões com ação semântica
  AND d.roas_ref IS NOT NULL
  AND a.after_days >= 3;                     -- janela-depois com dados suficientes
