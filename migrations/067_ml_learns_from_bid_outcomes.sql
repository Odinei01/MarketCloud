-- PASSO 4: fecha o loop — o ML passa a APRENDER com o resultado medido das
-- mudancas de lance (inclusive os pins de keyword feitos pelo dono).
-- Ate aqui o outcome era medido no robo, mas o ML nao consumia.

-- 1) Expoe os outcomes do robo (SWARM) no marketcloud via fdw.
IMPORT FOREIGN SCHEMA public LIMIT TO (amazon_ads_bid_learning_outcomes)
FROM SERVER swarm_pg INTO swarm_src;

-- 2) Agrega por campanha o que ja foi MEDIDO: a mudanca de lance ajudou?
CREATE OR REPLACE VIEW marketcloud_gold.gold_bid_change_learning AS
SELECT
    n.campaign_name,
    COUNT(*)                                                  AS measured_changes,
    AVG(o.roas_delta)::float8                                 AS roas_delta_avg,
    AVG(CASE WHEN o.roas_delta > 0 THEN 1.0 ELSE 0.0 END)::float8 AS win_rate
FROM swarm_src.amazon_ads_bid_learning_outcomes o
JOIN marketcloud_bronze.bronze_swarm_campaign_names n
     ON n.campaign_id = o.campaign_id
WHERE o.measured_date IS NOT NULL   -- so o que ja tem resultado real
  AND o.roas_delta IS NOT NULL
GROUP BY n.campaign_name;

COMMENT ON VIEW marketcloud_gold.gold_bid_change_learning IS
'O que as mudancas de lance ja medidas ensinaram, por campanha (delta de ROAS e taxa de acerto). Alimenta o ML horario.';

-- 3) Liga como feature na camada que o ML le.
DROP VIEW IF EXISTS marketcloud_gold.gold_hourly_signal_amc;
CREATE VIEW marketcloud_gold.gold_hourly_signal_amc AS
SELECT g.*,
       COALESCE(a.assist_rate, 0)       AS amc_assist_rate,
       COALESCE(a.first_touch_rate, 0)  AS amc_first_touch_rate,
       a.assisted_roas                  AS amc_assisted_roas,
       (a.decision = 'PROTECT')         AS amc_protect,
       COALESCE(n.new_customer_rate, 0) AS amc_new_customer_rate,
       (n.decision = 'ACQUISITION')     AS amc_acquisition,
       COALESCE(mf.dpv, 0)              AS amc_dpv_count,
       COALESCE(mf.cart, 0)             AS amc_cart_adds,
       -- APRENDIZADO: resultado real das mudancas de lance nessa campanha
       COALESCE(l.roas_delta_avg, 0)    AS learn_roas_delta_avg,
       COALESCE(l.win_rate, 0.5)        AS learn_win_rate,
       COALESCE(l.measured_changes, 0)  AS learn_measured_changes
FROM marketcloud_gold.gold_hourly_signal_unified g
LEFT JOIN marketcloud_bronze.bronze_amc_campaign_assist a
       ON LOWER(TRIM(a.campaign_name)) = LOWER(TRIM(g.campaign_name))
LEFT JOIN marketcloud_bronze.bronze_amc_campaign_ntb n
       ON LOWER(TRIM(n.campaign_name)) = LOWER(TRIM(g.campaign_name))
LEFT JOIN marketcloud_gold.gold_bid_change_learning l
       ON LOWER(TRIM(l.campaign_name)) = LOWER(TRIM(g.campaign_name))
LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(m.detail_page_views),0) AS dpv,
           COALESCE(SUM(m.cart_adds),0)         AS cart
    FROM marketcloud_bronze.bronze_amc_campaign_midfunnel m
    WHERE LENGTH(TRIM(COALESCE(m.product_key,''))) >= 4
      AND ( LOWER(TRIM(g.campaign_name)) LIKE '%'||LOWER(TRIM(m.product_key))||'%'
         OR LOWER(TRIM(m.product_key))   LIKE '%'||LOWER(TRIM(g.campaign_name))||'%' )
) mf ON TRUE;
