-- 232: corta do ML as duas features que o fan-out do Q005 envenenou.
--
-- CONTEXTO (ver docs/ACHADO-q005-amc-tabelas-fantasma.md): o Q005 grava em
-- bronze_amc_campaign_assist R$536.795,68 de venda direta sobre R$1.689,29 de gasto,
-- numa operacao que fatura ~R$28 mil/mes. O JOIN so por campaign_id cruza cada linha
-- de trafego com cada caminho de compra: SUM(spend) conta o gasto M vezes e
-- SUM(purchase_value) conta a venda N vezes.
--
-- O que sobrevive e o que nao:
--   assist_rate       OK  -- COUNT(DISTINCT user_id): o fan-out duplica linha, nao usuario
--   first_touch_rate  OK  -- idem
--   assisted_roas     NAO -- razao entre dois SUM() inflados por fatores DIFERENTES
--   decision          NAO -- deriva de direct_roas, inflado
--
-- Nao da para desinflar depois: o fator e M e N por campanha, e essa informacao nao
-- viaja no CSV. Numero que nao da para consertar tem que sair, nao ser estimado.
--
-- POR QUE ZERAR E NAO REMOVER A COLUNA: 4 views dependem desta (inclusive a
-- materialized gold_hourly_ml_target_mv). Remover coluna exigiria DROP CASCADE e
-- recriar as quatro. CREATE OR REPLACE preserva nome/tipo/ordem, entao nenhuma
-- dependente e tocada — e o dia em que o Q005 for reconstruido, volta trocando duas
-- linhas.
--
-- Alcance real: feature_full_control_campaign_hour_v1, que e o que o ML le, ja NAO
-- carregava essas duas. O veneno estava exposto aqui e podia ser consumido por quem
-- lesse a view direto. Agora nao pode mais.

CREATE OR REPLACE VIEW marketcloud_gold.gold_hourly_signal_amc AS
SELECT g.*,
       COALESCE(a.assist_rate, 0)       AS amc_assist_rate,
       COALESCE(a.first_touch_rate, 0)  AS amc_first_touch_rate,
       NULL::numeric                    AS amc_assisted_roas,   -- CORTADA: fan-out do Q005
       NULL::boolean                    AS amc_protect,         -- CORTADA: fan-out do Q005
       COALESCE(n.new_customer_rate, 0) AS amc_new_customer_rate,
       (n.decision = 'ACQUISITION')     AS amc_acquisition,
       COALESCE(mf.dpv, 0)              AS amc_dpv_count,
       COALESCE(mf.cart, 0)             AS amc_cart_adds,
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

-- Marca a origem, para ninguem reaproveitar o numero achando que e medicao.
COMMENT ON COLUMN marketcloud_bronze.bronze_amc_campaign_assist.spend IS
'INFLADO pelo produto cartesiano do Q005 (contado N vezes). Nao usar. Gasto autoritativo: amazon_ads_campaigns_daily.';
COMMENT ON COLUMN marketcloud_bronze.bronze_amc_campaign_assist.direct_sales IS
'INFLADO pelo produto cartesiano do Q005 (contado M vezes). Nao usar.';
COMMENT ON COLUMN marketcloud_bronze.bronze_amc_campaign_assist.assisted_sales IS
'INFLADO pelo produto cartesiano do Q005 (contado M vezes). Nao usar.';
COMMENT ON COLUMN marketcloud_bronze.bronze_amc_campaign_assist.direct_roas IS
'INVALIDO: razao entre dois SUM() inflados por fatores diferentes.';
COMMENT ON COLUMN marketcloud_bronze.bronze_amc_campaign_assist.assisted_roas IS
'INVALIDO: razao entre dois SUM() inflados por fatores diferentes. Cortada do ML na migration 232.';
COMMENT ON COLUMN marketcloud_bronze.bronze_amc_campaign_assist.decision IS
'INVALIDO: deriva de direct_roas, inflado. Cortada do ML na migration 232.';
COMMENT ON COLUMN marketcloud_bronze.bronze_amc_campaign_assist.assist_rate IS
'CONFIAVEL: COUNT(DISTINCT user_id) nao infla no fan-out.';
COMMENT ON COLUMN marketcloud_bronze.bronze_amc_campaign_assist.first_touch_rate IS
'CONFIAVEL: COUNT(DISTINCT user_id) nao infla no fan-out.';
