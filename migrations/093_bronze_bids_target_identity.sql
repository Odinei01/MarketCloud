-- P0 da 3a rodada da auditoria (16/07): bronze_swarm_current_bids "duplicada"
-- (3.842 linhas / 1.585 chaves distintas / 2.344 sem identidade).
--
-- Causa raiz (a auditoria parou em "duplicata + perda de identidade"; e SO
-- perda de identidade): as campanhas product-autopilot da Amazon fazem
-- targeting por PRODUTO (ASIN), nao por keyword. A fonte
-- amazon_ads_targeting_inventory guarda target_id + resolved_expression
-- (ex.: ASIN_SAME_AS B01HZMPH08) distintos por linha, e ZERO linhas sem
-- identidade. O sync (refresh_swarm_account_state) so copiava keyword_text/
-- match_type — vazios pra product target — e DESCARTAVA target_id/expressao.
-- Resultado: 133 produtos distintos viram 133 linhas identicas e sem id.
--
-- Nao ha duplicata real: sao 133 alvos diferentes que o sync tornou
-- indistinguiveis. Fix: bronze ganha target_id + resolved_expression e o sync
-- os carrega. So o bloco current_bids muda; resto da funcao identico a 069.
ALTER TABLE marketcloud_bronze.bronze_swarm_current_bids
    ADD COLUMN IF NOT EXISTS target_id TEXT,
    ADD COLUMN IF NOT EXISTS resolved_expression TEXT;

CREATE INDEX IF NOT EXISTS idx_bronze_bids_target_id
    ON marketcloud_bronze.bronze_swarm_current_bids (target_id) WHERE target_id IS NOT NULL;

-- funcao republicada: so o bloco current_bids ganhou target_id/resolved_expression
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
        campaign_status, ad_group_status, ingested_at, keyword_id,
        target_id, resolved_expression
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
        CAST(keyword_id AS TEXT),
        CAST(target_id AS TEXT),
        CAST(resolved_expression AS TEXT)
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
