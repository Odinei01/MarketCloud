-- #1 (corrigido): mid-funnel real via event_subtype (DPV/cart nas campanhas [SD] Retargeting).
CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_campaign_midfunnel (
    campaign_id       TEXT,
    campaign_name     TEXT,
    product_key       TEXT,   -- produto extraido de "[SD] - Retargeting - X" -> X
    detail_page_views NUMERIC,
    cart_adds         NUMERIC,
    updated_at        TIMESTAMPTZ DEFAULT NOW()
);

-- Refaz a feature view: assist + ntb + MID-FUNNEL (dpv/cart por produto, sem fan-out via LATERAL).
CREATE OR REPLACE VIEW marketcloud_gold.gold_hourly_signal_amc AS
SELECT g.*,
       COALESCE(a.assist_rate, 0)       AS amc_assist_rate,
       COALESCE(a.first_touch_rate, 0)  AS amc_first_touch_rate,
       a.assisted_roas                  AS amc_assisted_roas,
       (a.decision = 'PROTECT')         AS amc_protect,
       COALESCE(n.new_customer_rate, 0) AS amc_new_customer_rate,
       (n.decision = 'ACQUISITION')     AS amc_acquisition,
       COALESCE(mf.dpv, 0)              AS amc_dpv_count,
       COALESCE(mf.cart, 0)             AS amc_cart_adds
FROM marketcloud_gold.gold_hourly_signal_unified g
LEFT JOIN marketcloud_bronze.bronze_amc_campaign_assist a
       ON LOWER(TRIM(a.campaign_name)) = LOWER(TRIM(g.campaign_name))
LEFT JOIN marketcloud_bronze.bronze_amc_campaign_ntb n
       ON LOWER(TRIM(n.campaign_name)) = LOWER(TRIM(g.campaign_name))
LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(m.detail_page_views),0) AS dpv,
           COALESCE(SUM(m.cart_adds),0)         AS cart
    FROM marketcloud_bronze.bronze_amc_campaign_midfunnel m
    WHERE LENGTH(TRIM(COALESCE(m.product_key,''))) >= 4
      AND ( LOWER(TRIM(g.campaign_name)) LIKE '%'||LOWER(TRIM(m.product_key))||'%'
         OR LOWER(TRIM(m.product_key))   LIKE '%'||LOWER(TRIM(g.campaign_name))||'%' )
) mf ON TRUE;
