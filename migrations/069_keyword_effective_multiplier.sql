-- A tela Keywords x hora mostrava "Atual" errado e recomendava subir/reduzir
-- lance que JA estava no valor sugerido (36 de 94 linhas aplicaveis em 15/07).
--
-- Causa: gold_hourly_recommendations_v1 casa a agenda por NOME DE CAMPANHA e
-- hora, e agrega min(multiplier) de TODOS os profiles daquela campanha juntos:
-- o da campanha, o do grupo e o de cada keyword. O bronze da agenda nem
-- carregava entity_id/scope, entao nao havia como saber de quem era a regra.
-- Resultado: a keyword "tag rastreador" ja tinha grade propria 13h-17h em 1.0,
-- a tela dizia "Atual 0.80 -> Subir pra 1.0", e o pin respondia ALREADY_ALIGNED.
--
-- Fix: o bronze passa a carregar scope/entity_id/entity_label (agenda) e
-- keyword_id (bids), e o gold resolve o multiplicador EFETIVO da keyword pela
-- hierarquia real do robo: KEYWORD (ENTITY) > AD_GROUP > CAMPAIGN > GLOBAL,
-- a mesma de amazonAdsBidScheduleResolveEffectiveMultiplier no SWARM.

ALTER TABLE marketcloud_bronze.bronze_swarm_bid_schedule
    ADD COLUMN IF NOT EXISTS scope TEXT,
    ADD COLUMN IF NOT EXISTS entity_id TEXT,
    ADD COLUMN IF NOT EXISTS entity_label TEXT;

CREATE INDEX IF NOT EXISTS idx_bronze_sched_scope_entity
    ON marketcloud_bronze.bronze_swarm_bid_schedule (scope, entity_id, hour_start, hour_end);

COMMENT ON COLUMN marketcloud_bronze.bronze_swarm_bid_schedule.scope IS
    'ENTITY|AD_GROUP|CAMPAIGN|GLOBAL: sem isso nao da pra saber de quem e a regra.';

ALTER TABLE marketcloud_bronze.bronze_swarm_current_bids
    ADD COLUMN IF NOT EXISTS keyword_id TEXT;

CREATE INDEX IF NOT EXISTS idx_bronze_bids_keyword_id
    ON marketcloud_bronze.bronze_swarm_current_bids (keyword_id);

-- Funcao de sync republicada com scope/entity_id/entity_label (agenda) e
-- keyword_id (bids). Corpo identico ao da migration 048 fora essas 4 adicoes.
CREATE OR REPLACE FUNCTION marketcloud_bronze.refresh_swarm_account_state()
 RETURNS TABLE(source_table text, rows_inserted bigint)
 LANGUAGE plpgsql
AS $function$
DECLARE
    n BIGINT;
BEGIN
    TRUNCATE marketcloud_bronze.bronze_swarm_negatives;
    INSERT INTO marketcloud_bronze.bronze_swarm_negatives (
        campaign_id, campaign_name, ad_group_id, ad_group_name,
        keyword_text, keyword_norm, match_type, state,
        campaign_status, ad_group_status, ingested_at
    )
    SELECT DISTINCT ON (CAST(campaign_id AS TEXT), LOWER(TRIM(keyword_text)), match_type)
        CAST(campaign_id AS TEXT),
        campaign_name,
        CAST(ad_group_id AS TEXT),
        ad_group_name,
        keyword_text,
        LOWER(TRIM(keyword_text)),
        match_type,
        state,
        campaign_status,
        ad_group_status,
        NOW()
    FROM swarm_src.amazon_ads_targeting_inventory
    WHERE is_negative = TRUE
      AND keyword_text IS NOT NULL
      AND campaign_id IS NOT NULL
    ORDER BY
        CAST(campaign_id AS TEXT),
        LOWER(TRIM(keyword_text)),
        match_type,
        CASE WHEN UPPER(COALESCE(state,'')) = 'ENABLED' THEN 0 ELSE 1 END,
        updated_at DESC NULLS LAST;
    GET DIAGNOSTICS n = ROW_COUNT;
    source_table := 'bronze_swarm_negatives';
    rows_inserted := n;
    RETURN NEXT;

    TRUNCATE marketcloud_bronze.bronze_swarm_bid_schedule;
    INSERT INTO marketcloud_bronze.bronze_swarm_bid_schedule (
        profile_id_ref, campaign_id, campaign_name, ad_group_id, ad_group_name,
        entity_type, day_of_week, hour_start, hour_end, multiplier, label, risk_flag,
        profile_status, profile_is_active, campaign_status, ad_group_status, ingested_at,
        scope, entity_id, entity_label
    )
    SELECT
        CAST(r.profile_id_ref AS TEXT),
        CAST(p.campaign_id AS TEXT),
        p.campaign_name,
        CAST(p.ad_group_id AS TEXT),
        p.ad_group_name,
        p.entity_type,
        r.day_of_week,
        r.hour_start,
        r.hour_end,
        r.multiplier,
        r.label,
        CAST(r.risk_flag AS TEXT),
        p.status,
        p.is_active,
        st.campaign_status,
        st.ad_group_status,
        NOW(),
        p.scope,
        CAST(p.entity_id AS TEXT),
        p.entity_label
    FROM swarm_src.zanom_ads_bid_schedule_rules r
    LEFT JOIN swarm_src.zanom_ads_bid_schedule_profiles p
        ON CAST(p.id AS TEXT) = CAST(r.profile_id_ref AS TEXT)
    LEFT JOIN LATERAL (
        SELECT t.campaign_status, t.ad_group_status
        FROM swarm_src.amazon_ads_targeting_inventory t
        WHERE CAST(t.campaign_id AS TEXT) = CAST(p.campaign_id AS TEXT)
          AND (
              p.ad_group_id IS NULL
              OR CAST(p.ad_group_id AS TEXT) = ''
              OR CAST(t.ad_group_id AS TEXT) = CAST(p.ad_group_id AS TEXT)
              OR LOWER(COALESCE(t.ad_group_name,'')) = LOWER(COALESCE(p.ad_group_name,''))
          )
        ORDER BY
            CASE WHEN UPPER(COALESCE(t.state,'')) = 'ENABLED' THEN 0 ELSE 1 END,
            t.updated_at DESC NULLS LAST
        LIMIT 1
    ) st ON TRUE
    WHERE COALESCE(p.is_active, TRUE) = TRUE
      AND UPPER(COALESCE(p.status, 'ACTIVE')) NOT IN ('ARCHIVED', 'PAUSED', 'DELETED');
    GET DIAGNOSTICS n = ROW_COUNT;
    source_table := 'bronze_swarm_bid_schedule';
    rows_inserted := n;
    RETURN NEXT;

    TRUNCATE marketcloud_bronze.bronze_swarm_current_bids;
    INSERT INTO marketcloud_bronze.bronze_swarm_current_bids (
        campaign_id, campaign_name, ad_group_id, ad_group_name,
        keyword_text, match_type, bid, state, serving_status,
        campaign_status, ad_group_status, ingested_at, keyword_id
    )
    SELECT
        CAST(campaign_id AS TEXT),
        campaign_name,
        CAST(ad_group_id AS TEXT),
        ad_group_name,
        keyword_text,
        match_type,
        bid,
        state,
        serving_status,
        campaign_status,
        ad_group_status,
        NOW(),
        CAST(keyword_id AS TEXT)
    FROM swarm_src.amazon_ads_targeting_inventory
    WHERE COALESCE(is_negative, FALSE) = FALSE
      AND campaign_id IS NOT NULL;
    GET DIAGNOSTICS n = ROW_COUNT;
    source_table := 'bronze_swarm_current_bids';
    rows_inserted := n;
    RETURN NEXT;

    TRUNCATE marketcloud_bronze.bronze_swarm_campaign_metrics;
    INSERT INTO marketcloud_bronze.bronze_swarm_campaign_metrics (
        data_date, campaign_id, campaign_name, campaign_status,
        cost, attributed_sales, purchases, roas, acos, ingested_at
    )
    SELECT
        date,
        CAST(campaign_id AS TEXT),
        MAX(campaign_name),
        MAX(campaign_status),
        SUM(cost),
        SUM(attributed_sales),
        SUM(purchases),
        CASE WHEN SUM(cost) > 0 THEN SUM(attributed_sales)/SUM(cost) ELSE 0 END,
        CASE WHEN SUM(attributed_sales) > 0 THEN SUM(cost)/SUM(attributed_sales) ELSE 0 END,
        NOW()
    FROM swarm_src.amazon_ads_campaigns_daily
    WHERE date IS NOT NULL
      AND campaign_id IS NOT NULL
      AND UPPER(COALESCE(campaign_status, 'ENABLED')) NOT IN ('ARCHIVED', 'PAUSED', 'DELETED')
    GROUP BY date, CAST(campaign_id AS TEXT);
    GET DIAGNOSTICS n = ROW_COUNT;
    source_table := 'bronze_swarm_campaign_metrics';
    rows_inserted := n;
    RETURN NEXT;
END;
$function$

;

-- Multiplicador efetivo por keyword x hora, resolvendo a hierarquia.
-- day_of_week esta sempre vazio no robo hoje (601/601 regras), entao as regras
-- valem todo dia; se um dia passar a existir dia da semana, filtrar aqui tambem.
CREATE OR REPLACE VIEW marketcloud_gold.gold_keyword_effective_multiplier AS
WITH sched AS (
    SELECT s.scope, s.campaign_id, s.ad_group_id, s.entity_id,
           lower(trim(coalesce(s.entity_label,''))) AS entity_label_norm,
           s.hour_start, s.hour_end, s.multiplier
    FROM marketcloud_bronze.bronze_swarm_bid_schedule s
    WHERE coalesce(s.profile_is_active, true) = true
      AND upper(coalesce(s.profile_status,'')) = 'PUBLISHED'
      AND coalesce(s.day_of_week,'') = ''
      AND s.multiplier IS NOT NULL
), bids AS (
    SELECT DISTINCT ON (campaign_id, coalesce(ad_group_id,''), lower(trim(keyword_text)), lower(trim(coalesce(match_type,''))))
           campaign_id, ad_group_id, keyword_id,
           trim(keyword_text) AS keyword_text, match_type
    FROM marketcloud_bronze.bronze_swarm_current_bids
    WHERE coalesce(keyword_id,'') <> ''
      AND upper(coalesce(state,'')) = 'ENABLED'
    ORDER BY campaign_id, coalesce(ad_group_id,''), lower(trim(keyword_text)),
             lower(trim(coalesce(match_type,''))), ingested_at DESC
)
SELECT k.campaign_id,
       k.ad_group_id,
       k.keyword_text,
       k.match_type,
       k.keyword_id,
       h.hour AS event_hour,
       coalesce(eff.multiplier, 1.0) AS effective_multiplier,
       coalesce(eff.scope, 'DEFAULT')  AS effective_scope
FROM bids k
CROSS JOIN generate_series(0,23) AS h(hour)
LEFT JOIN LATERAL (
    SELECT s.multiplier, s.scope
    FROM sched s
    WHERE s.hour_start <= h.hour AND s.hour_end > h.hour
      AND (
            (s.scope = 'ENTITY'   AND s.campaign_id = k.campaign_id
                                  AND (s.entity_id = k.keyword_id
                                       OR (coalesce(s.entity_id,'') = ''
                                           AND s.entity_label_norm = lower(trim(k.keyword_text)))))
         OR (s.scope = 'AD_GROUP' AND s.campaign_id = k.campaign_id AND s.ad_group_id = k.ad_group_id)
         OR (s.scope = 'CAMPAIGN' AND s.campaign_id = k.campaign_id)
         OR (s.scope = 'GLOBAL')
      )
    -- mesma precedencia do robo: keyword sobrepoe grupo, que sobrepoe campanha
    ORDER BY CASE s.scope WHEN 'ENTITY' THEN 4 WHEN 'AD_GROUP' THEN 3
                          WHEN 'CAMPAIGN' THEN 2 WHEN 'GLOBAL' THEN 1 ELSE 0 END DESC
    LIMIT 1
) eff ON TRUE;

COMMENT ON VIEW marketcloud_gold.gold_keyword_effective_multiplier IS
    'Multiplicador que a keyword REALMENTE tem em cada hora (ENTITY>AD_GROUP>CAMPAIGN>GLOBAL). Sem agenda = 1.0 (DEFAULT).';
