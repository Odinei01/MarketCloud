-- =====================================================================
-- Lake — Ingestão do ESTADO DA CONTA a partir do Robô ZANOM (SWARM)
--
-- Por quê: o cockpit ZMC (AMC) recomendava no vácuo — ex.: ADD_NEGATIVE de
-- "fone de ouvido bluetooth" que JÁ é negativa há semanas; CUT_HOUR de horas
-- que o Robô JÁ reduziu. Sem cruzar com o estado real da conta, vira ruído.
--
-- Padrão: mesmo do bronze AMC. O SWARM (pricing_intelligence) é a FONTE; aqui
-- materializamos o estado no lake para o cockpit cruzar LOCALMENTE (o ZMC não
-- depende do SWARM estar de pé em runtime).
--
-- Pré-requisito (setup fora deste migration, pois carrega credencial):
--   CREATE EXTENSION postgres_fdw;
--   CREATE SERVER swarm_pg FOREIGN DATA WRAPPER postgres_fdw
--     OPTIONS (host 'pricing_db', port '5432', dbname 'pricing_intelligence');
--   CREATE USER MAPPING FOR mcadmin SERVER swarm_pg OPTIONS (user '...', password '...');
--   IMPORT FOREIGN SCHEMA public LIMIT TO (
--     amazon_ads_targeting_inventory, zanom_ads_bid_schedule_rules,
--     zanom_ads_bid_schedule_profiles, amazon_ads_campaigns_daily)
--   FROM SERVER swarm_pg INTO swarm_src;
-- =====================================================================

-- ---------- 1) Negativas ativas ----------
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_swarm_negatives (
    campaign_id   TEXT NOT NULL,
    campaign_name TEXT,
    ad_group_id   TEXT,
    keyword_text  TEXT NOT NULL,
    keyword_norm  TEXT NOT NULL,
    match_type    TEXT NOT NULL,
    state         TEXT,
    ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_bronze_swarm_negatives PRIMARY KEY (campaign_id, keyword_norm, match_type)
);
CREATE INDEX IF NOT EXISTS idx_swarm_neg_norm ON marketcloud_bronze.bronze_swarm_negatives (keyword_norm);

-- ---------- 2) Agenda horária de bid (multiplicadores) ----------
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_swarm_bid_schedule (
    profile_id_ref TEXT,
    campaign_id    TEXT,
    campaign_name  TEXT,
    ad_group_id    TEXT,
    entity_type    TEXT,
    day_of_week    TEXT,
    hour_start     INTEGER,
    hour_end       INTEGER,
    multiplier     NUMERIC(10,4),
    label          TEXT,
    risk_flag      TEXT,
    ingested_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_swarm_sched_campaign ON marketcloud_bronze.bronze_swarm_bid_schedule (campaign_id, hour_start);

-- ---------- 3) Bids atuais (não-negativos) ----------
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_swarm_current_bids (
    campaign_id   TEXT NOT NULL,
    campaign_name TEXT,
    ad_group_id   TEXT,
    keyword_text  TEXT,
    match_type    TEXT,
    bid           NUMERIC(18,4),
    state         TEXT,
    serving_status TEXT,
    ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_swarm_bids_campaign ON marketcloud_bronze.bronze_swarm_current_bids (campaign_id);

-- ---------- 4) Métricas de campanha (ROAS/ACOS reais do SWARM) ----------
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_swarm_campaign_metrics (
    data_date        DATE NOT NULL,
    campaign_id      TEXT NOT NULL,
    campaign_name    TEXT,
    cost             NUMERIC(18,4),
    attributed_sales NUMERIC(18,4),
    purchases        NUMERIC(18,4),
    roas             NUMERIC(18,4),
    acos             NUMERIC(18,8),
    ingested_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_bronze_swarm_metrics PRIMARY KEY (data_date, campaign_id)
);


-- =====================================================================
-- Ingestão (snapshot: TRUNCATE + INSERT). Repetível pelo worker de sync.
-- =====================================================================

TRUNCATE marketcloud_bronze.bronze_swarm_negatives;
INSERT INTO marketcloud_bronze.bronze_swarm_negatives (campaign_id, campaign_name, ad_group_id, keyword_text, keyword_norm, match_type, state)
SELECT DISTINCT ON (CAST(campaign_id AS TEXT), LOWER(TRIM(keyword_text)), match_type)
    CAST(campaign_id AS TEXT), campaign_name, CAST(ad_group_id AS TEXT),
    keyword_text, LOWER(TRIM(keyword_text)), match_type, state
FROM swarm_src.amazon_ads_targeting_inventory
WHERE is_negative = TRUE AND keyword_text IS NOT NULL AND campaign_id IS NOT NULL
ORDER BY CAST(campaign_id AS TEXT), LOWER(TRIM(keyword_text)), match_type, state;

TRUNCATE marketcloud_bronze.bronze_swarm_bid_schedule;
INSERT INTO marketcloud_bronze.bronze_swarm_bid_schedule (profile_id_ref, campaign_id, campaign_name, ad_group_id, entity_type, day_of_week, hour_start, hour_end, multiplier, label, risk_flag)
SELECT CAST(r.profile_id_ref AS TEXT), CAST(p.campaign_id AS TEXT), p.campaign_name, CAST(p.ad_group_id AS TEXT),
    p.entity_type, r.day_of_week, r.hour_start, r.hour_end, r.multiplier, r.label, CAST(r.risk_flag AS TEXT)
FROM swarm_src.zanom_ads_bid_schedule_rules r
LEFT JOIN swarm_src.zanom_ads_bid_schedule_profiles p ON CAST(p.id AS TEXT) = CAST(r.profile_id_ref AS TEXT);

TRUNCATE marketcloud_bronze.bronze_swarm_current_bids;
INSERT INTO marketcloud_bronze.bronze_swarm_current_bids (campaign_id, campaign_name, ad_group_id, keyword_text, match_type, bid, state, serving_status)
SELECT CAST(campaign_id AS TEXT), campaign_name, CAST(ad_group_id AS TEXT), keyword_text, match_type,
    bid, state, serving_status
FROM swarm_src.amazon_ads_targeting_inventory
WHERE COALESCE(is_negative, FALSE) = FALSE AND campaign_id IS NOT NULL;

TRUNCATE marketcloud_bronze.bronze_swarm_campaign_metrics;
INSERT INTO marketcloud_bronze.bronze_swarm_campaign_metrics (data_date, campaign_id, campaign_name, cost, attributed_sales, purchases, roas, acos)
SELECT date, CAST(campaign_id AS TEXT), MAX(campaign_name),
    SUM(cost), SUM(attributed_sales), SUM(purchases),
    CASE WHEN SUM(cost) > 0 THEN SUM(attributed_sales)/SUM(cost) ELSE 0 END,
    CASE WHEN SUM(attributed_sales) > 0 THEN SUM(cost)/SUM(attributed_sales) ELSE 0 END
FROM swarm_src.amazon_ads_campaigns_daily
WHERE date IS NOT NULL AND campaign_id IS NOT NULL
GROUP BY date, CAST(campaign_id AS TEXT);
