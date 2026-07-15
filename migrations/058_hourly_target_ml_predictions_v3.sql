-- =====================================================================
-- HourlyTargetRealV3 — ML no grao keyword/target x hora com dado AMS real.
--
-- ADVISOR-ONLY. Nada executa na Amazon.
-- O V3 nasce separado do V2 campanha x hora para nao misturar graos.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_gold.hourly_target_ml_predictions_v3 (
    campaign_id              TEXT    NOT NULL,
    campaign_name            TEXT,
    ad_group_id              TEXT,
    ad_group_name            TEXT,
    target_entity_key        TEXT    NOT NULL,
    keyword_id               TEXT,
    target_id                TEXT,
    keyword_text             TEXT,
    targeting                TEXT,
    match_type               TEXT,
    event_hour               INTEGER NOT NULL CHECK (event_hour BETWEEN 0 AND 23),
    days_observed            INTEGER NOT NULL DEFAULT 0,
    impressions              NUMERIC(18,4),
    clicks                   NUMERIC(18,4),
    spend                    NUMERIC(18,4),
    orders                   NUMERIC(18,4),
    sales                    NUMERIC(18,4),
    click_probability        NUMERIC(6,4),
    conversion_probability   NUMERIC(6,4),
    expected_roas            NUMERIC(10,4),
    predicted_good_target_hour BOOLEAN,
    model_version            TEXT    NOT NULL DEFAULT 'v3',
    label_caveat             TEXT    NOT NULL DEFAULT 'AMS_TARGET_HOURLY_ADVISOR_ONLY',
    computed_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_hourly_target_ml_pred_v3 PRIMARY KEY (campaign_id, target_entity_key, event_hour)
);

CREATE INDEX IF NOT EXISTS idx_hourly_target_ml_pred_v3_campaign_hour
    ON marketcloud_gold.hourly_target_ml_predictions_v3 (campaign_id, event_hour);

CREATE INDEX IF NOT EXISTS idx_hourly_target_ml_pred_v3_text_match
    ON marketcloud_gold.hourly_target_ml_predictions_v3 (lower(COALESCE(keyword_text, targeting, '')), lower(COALESCE(match_type, '')));

COMMENT ON TABLE marketcloud_gold.hourly_target_ml_predictions_v3 IS
'Predicoes ML no grao keyword/target x hora usando bronze_ams_hourly_target. Advisor-only; conversao/ROAS ficam nulos ate haver volume suficiente.';

CREATE OR REPLACE VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v2 AS
SELECT
    k.*,
    p.click_probability::float8 AS target_ml_click_probability,
    p.conversion_probability::float8 AS target_ml_conversion_probability,
    p.expected_roas::float8 AS target_ml_expected_roas,
    p.predicted_good_target_hour AS target_ml_good_hour,
    p.label_caveat AS target_ml_label_caveat,
    p.computed_at AS target_ml_computed_at
FROM marketcloud_gold.gold_keyword_hourly_recommendations_v1 k
LEFT JOIN marketcloud_gold.hourly_target_ml_predictions_v3 p
  ON p.campaign_id = k.campaign_id
 AND p.event_hour = k.event_hour
 AND (
    p.target_entity_key = 'adg:' || COALESCE(k.ad_group_id, '') || '|kw:' || lower(trim(COALESCE(k.keyword_text, ''))) || '|match:' || lower(trim(COALESCE(k.match_type, '')))
    OR (
      lower(trim(COALESCE(p.keyword_text, p.targeting, ''))) = lower(trim(COALESCE(k.keyword_text, '')))
      AND lower(trim(COALESCE(p.match_type, ''))) = lower(trim(COALESCE(k.match_type, '')))
      AND COALESCE(p.ad_group_id, '') = COALESCE(k.ad_group_id, '')
    )
 );

COMMENT ON VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v2 IS
'Keyword x hora V2 enriquecida com HourlyTargetRealV3 quando houver predicao AMS target x hora.';

