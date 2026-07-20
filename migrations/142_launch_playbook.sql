-- 142 - Launch Playbook: modelo de dados p/ auto-criacao de campanhas de
-- descoberta de produto novo (ou que nao vende). Spec: docs/HANDOFF-launch-playbook.md.
-- Este migration cria SO o modelo de dados + template default. O executor de
-- criacao via SP-API e o proximo build (gated, kill-switch OFF).

CREATE TABLE IF NOT EXISTS marketcloud_control.launch_playbook_templates (
    template_name   TEXT PRIMARY KEY,
    description     TEXT,
    campaigns_json  JSONB NOT NULL,   -- [{type, match, budget_brl, default_bid, role}]
    guardrails_json JSONB NOT NULL,   -- {min_roas, max_daily_budget_brl, max_spend_without_order_brl, minimum_stock_cover_days}
    seed_strategy   TEXT DEFAULT 'from_title_and_category',
    launch_mode     TEXT DEFAULT 'advisor',  -- nasce em aprendizado; dono promove p/ full_auto
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS marketcloud_control.launch_playbook_runs (
    id              TEXT PRIMARY KEY,
    tenant_id       TEXT,
    product_asin    TEXT,
    product_sku     TEXT,
    product_title   TEXT,
    template_name   TEXT REFERENCES marketcloud_control.launch_playbook_templates(template_name),
    status          TEXT DEFAULT 'DRAFT',   -- DRAFT|APPROVED|CREATING|CREATED|FAILED
    seed_keywords_json    JSONB,
    created_campaign_ids  JSONB,
    guardrails_json       JSONB,
    blocked_reason  TEXT,
    requested_by    TEXT,
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    executed_at     TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS ix_launch_playbook_runs_status ON marketcloud_control.launch_playbook_runs (status);
CREATE INDEX IF NOT EXISTS ix_launch_playbook_runs_asin ON marketcloud_control.launch_playbook_runs (product_asin);

-- Template default DISCOVERY_V1 (validado no dossie das 4 campanhas m19 autopilot).
-- Regra de largada: comecar com AUTO + PHRASE; EXACT vazia (colheita); PRODUCT
-- pequeno. Nasce em advisor (nao mexe em dinheiro sozinha).
INSERT INTO marketcloud_control.launch_playbook_templates
    (template_name, description, campaigns_json, guardrails_json, seed_strategy, launch_mode)
VALUES (
    'DISCOVERY_V1',
    'Funil de descoberta->colheita para produto novo/que nao vende. Comeca AUTO+PHRASE; EXACT enche pela colheita; PRODUCT marginal.',
    '[
       {"type":"AUTO",    "match":"auto",   "role":"descoberta_pura",         "budget_brl":20, "default_bid":0.30, "launch_priority":1},
       {"type":"PHRASE",  "match":"phrase", "role":"descoberta_semicontrolada","budget_brl":20, "default_bid":0.30, "launch_priority":1},
       {"type":"EXACT",   "match":"exact",  "role":"colheita_comeca_vazia",    "budget_brl":10, "default_bid":0.40, "launch_priority":2},
       {"type":"PRODUCT", "match":"product","role":"asin_targeting_marginal",  "budget_brl":10, "default_bid":0.30, "launch_priority":2}
     ]'::jsonb,
    '{"min_roas":3.0, "max_daily_budget_brl":60, "max_spend_without_order_brl":20, "minimum_stock_cover_days":25}'::jsonb,
    'from_title_and_category',
    'advisor'
)
ON CONFLICT (template_name) DO UPDATE SET
    description=EXCLUDED.description, campaigns_json=EXCLUDED.campaigns_json,
    guardrails_json=EXCLUDED.guardrails_json, updated_at=NOW();
