-- Fase 6: recomendacoes advisor no grao keyword x hora.
-- Nao executa mutacao na Amazon. Enquanto o AMS nao provar payload com
-- keyword/target por hora, o Gold herda o multiplicador horario da campanha.

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_ams_hourly_target (
    data_date date NOT NULL,
    event_hour integer NOT NULL CHECK (event_hour BETWEEN 0 AND 23),
    campaign_id text NOT NULL,
    target_entity_key text NOT NULL,

    campaign_name text,
    ad_group_id text,
    ad_group_name text,
    keyword_id text,
    target_id text,
    keyword_text text,
    targeting text,
    match_type text,

    impressions numeric(18,4) DEFAULT 0,
    clicks numeric(18,4) DEFAULT 0,
    spend numeric(18,4) DEFAULT 0,
    orders_1d numeric(18,4) DEFAULT 0,
    sales_1d numeric(18,4) DEFAULT 0,
    orders_7d numeric(18,4) DEFAULT 0,
    sales_7d numeric(18,4) DEFAULT 0,
    orders_14d numeric(18,4) DEFAULT 0,
    sales_14d numeric(18,4) DEFAULT 0,

    last_traffic_at timestamptz,
    traffic_msg_time timestamptz,
    raw_traffic_payload jsonb,
    last_conversion_at timestamptz,
    conversion_msg_time timestamptz,
    raw_conversion_payload jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (data_date, event_hour, campaign_id, target_entity_key)
);

CREATE INDEX IF NOT EXISTS idx_ams_hourly_target_campaign_hour
    ON marketcloud_bronze.bronze_ams_hourly_target (campaign_id, event_hour, data_date);

CREATE INDEX IF NOT EXISTS idx_ams_hourly_target_keyword
    ON marketcloud_bronze.bronze_ams_hourly_target (campaign_id, lower(keyword_text), lower(match_type));

COMMENT ON TABLE marketcloud_bronze.bronze_ams_hourly_target IS
    'Landing AMS opcional no grao keyword/target x hora; populada apenas se o payload real trouxer esses identificadores.';

CREATE OR REPLACE VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v1 AS
WITH hourly AS (
    SELECT *
    FROM marketcloud_gold.gold_hourly_recommendations_v1
    WHERE action_type IN ('BID_UP', 'CUT_HOUR', 'BID_DOWN', 'KEEP_STRONG')
),
current_keywords AS (
    SELECT DISTINCT ON (
        campaign_id,
        COALESCE(ad_group_id, ''),
        lower(trim(COALESCE(keyword_text, ''))),
        lower(trim(COALESCE(match_type, '')))
    )
        campaign_id,
        campaign_name,
        ad_group_id,
        ad_group_name,
        trim(keyword_text) AS keyword_text,
        match_type,
        bid::numeric AS base_bid,
        state,
        serving_status,
        campaign_status,
        ad_group_status,
        ingested_at
    FROM marketcloud_bronze.bronze_swarm_current_bids
    WHERE NULLIF(trim(COALESCE(keyword_text, '')), '') IS NOT NULL
      AND bid IS NOT NULL
      AND bid > 0
      AND COALESCE(upper(campaign_status), '') NOT IN ('ARCHIVED', 'PAUSED', 'DELETED')
      AND COALESCE(upper(ad_group_status), '') NOT IN ('ARCHIVED', 'PAUSED', 'DELETED')
      AND COALESCE(upper(state), '') NOT IN ('ARCHIVED', 'PAUSED', 'DELETED')
    ORDER BY
        campaign_id,
        COALESCE(ad_group_id, ''),
        lower(trim(COALESCE(keyword_text, ''))),
        lower(trim(COALESCE(match_type, ''))),
        ingested_at DESC
),
target_hour AS (
    SELECT
        t.campaign_id,
        t.event_hour,
        lower(trim(COALESCE(t.keyword_text, t.targeting, ''))) AS target_text_norm,
        lower(trim(COALESCE(t.match_type, ''))) AS match_type_norm,
        sum(COALESCE(t.impressions, 0)) AS target_impressions,
        sum(COALESCE(t.clicks, 0)) AS target_clicks,
        sum(COALESCE(t.spend, 0)) AS target_spend,
        sum(GREATEST(COALESCE(t.orders_14d, 0), COALESCE(t.orders_7d, 0), COALESCE(t.orders_1d, 0))) AS target_orders,
        sum(GREATEST(COALESCE(t.sales_14d, 0), COALESCE(t.sales_7d, 0), COALESCE(t.sales_1d, 0))) AS target_sales
    FROM marketcloud_bronze.bronze_ams_hourly_target t
    WHERE NULLIF(trim(COALESCE(t.keyword_text, t.targeting, '')), '') IS NOT NULL
    GROUP BY 1, 2, 3, 4
)
SELECT
    md5(
        h.recommendation_id || '|' ||
        k.campaign_id || '|' ||
        COALESCE(k.ad_group_id, '') || '|' ||
        lower(k.keyword_text) || '|' ||
        COALESCE(k.match_type, '')
    ) AS keyword_hour_recommendation_id,
    k.campaign_id,
    k.campaign_name,
    k.ad_group_id,
    k.ad_group_name,
    k.keyword_text,
    k.match_type,
    h.event_hour,
    h.action_type AS campaign_action_type,
    CASE h.action_type
        WHEN 'BID_UP' THEN 'INCREASE_EFFECTIVE_BID'
        WHEN 'CUT_HOUR' THEN 'DECREASE_EFFECTIVE_BID'
        WHEN 'BID_DOWN' THEN 'DECREASE_EFFECTIVE_BID'
        WHEN 'KEEP_STRONG' THEN 'KEEP_EFFECTIVE_BID'
        ELSE 'WATCH'
    END AS advisor_action,
    h.confidence,
    CASE
        WHEN COALESCE(th.target_clicks, 0) >= 20 OR COALESCE(th.target_orders, 0) >= 3 THEN 'TARGET_HOUR_OBSERVED'
        ELSE 'CAMPAIGN_HOUR_INHERITED'
    END AS source_grain,
    CASE
        WHEN COALESCE(th.target_clicks, 0) >= 20 OR COALESCE(th.target_orders, 0) >= 3 THEN 'TARGET_VOLUME_OK'
        WHEN h.confidence = 'LOW' THEN 'LOW_VOLUME_INHERITED'
        ELSE 'INHERITED_CAMPAIGN_HOUR'
    END AS sample_guard,
    'ADVISOR_ONLY_USE_SWARM_DRY_RUN'::text AS execution_hint,

    round(k.base_bid, 2) AS base_bid,
    COALESCE(h.current_multiplier, 1)::numeric AS current_hour_multiplier,
    COALESCE(h.suggested_multiplier, h.current_multiplier, 1)::numeric AS suggested_hour_multiplier,
    round(k.base_bid * COALESCE(h.current_multiplier, 1), 2) AS current_effective_bid,
    round(k.base_bid * COALESCE(h.suggested_multiplier, h.current_multiplier, 1), 2) AS suggested_effective_bid,
    round(k.base_bid * (COALESCE(h.suggested_multiplier, h.current_multiplier, 1) - COALESCE(h.current_multiplier, 1)), 2) AS effective_bid_delta,
    round(
        CASE WHEN COALESCE(h.current_multiplier, 1) = 0 THEN 0
             ELSE ((COALESCE(h.suggested_multiplier, h.current_multiplier, 1) - COALESCE(h.current_multiplier, 1)) / COALESCE(h.current_multiplier, 1)) * 100
        END,
        2
    ) AS effective_bid_delta_percent,

    h.spend,
    h.orders,
    h.sales,
    h.roas,
    h.clicks,
    h.impressions,
    h.days_observed,
    h.window_from,
    h.window_to,
    h.ml_conversion_probability,
    h.ml_expected_roas,
    h.ml_good_hour,
    h.ml_agrees,
    round(h.priority_score * CASE h.confidence WHEN 'HIGH' THEN 1.0 WHEN 'MEDIUM' THEN 0.7 ELSE 0.35 END, 2) AS priority_score,

    (th.campaign_id IS NOT NULL) AS target_hour_has_data,
    th.target_impressions,
    th.target_clicks,
    th.target_spend,
    th.target_orders,
    th.target_sales,
    now() AS computed_at
FROM hourly h
JOIN current_keywords k
  ON lower(trim(k.campaign_name)) = lower(trim(h.campaign_name))
LEFT JOIN target_hour th
  ON th.campaign_id = k.campaign_id
 AND th.event_hour = h.event_hour
 AND th.target_text_norm = lower(trim(k.keyword_text))
 AND th.match_type_norm = lower(trim(COALESCE(k.match_type, '')))
WHERE h.action_type <> 'KEEP_STRONG'
   OR h.confidence IN ('HIGH', 'MEDIUM');

COMMENT ON VIEW marketcloud_gold.gold_keyword_hourly_recommendations_v1 IS
    'Advisor keyword x hora: base bid por keyword do SWARM vezes multiplicador horario real da campanha; troca para source TARGET_HOUR_OBSERVED quando AMS trouxer volume keyword/target suficiente.';
