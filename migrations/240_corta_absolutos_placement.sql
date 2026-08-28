-- 240: corta do ML os ABSOLUTOS de placement (E007). Shares e CPC ficam.
--
-- MEDIDO (13-26/08) contra amazon_ads_campaigns_daily:
--   bronze_amc_placement_creative_daily  R$2.092,40  =  114,2% do que a Amazon cobrou
-- Gastar mais do que foi cobrado e impossivel. Nao e supressao — e erro.
--
-- NAO e duplicata de ingestao: com a chave completa (data, campanha, ad_group, targeting,
-- match_type, placement_type, creative, creative_type, creative_asin) ha ZERO grupos
-- repetidos. Cheguei a suspeitar de 27 mil linhas duplicadas usando uma chave incompleta;
-- inspecionar duas linhas do "grupo duplicado" mostrou impressoes 11 e 2 — dado legitimo.
-- Teria apagado dado real.
--
-- NAO e a query: o E007 e um GROUP BY simples sobre sponsored_ads_traffic, sem JOIN.
--
-- E o proprio AMC: no grao placement x creative ele devolve a mesma impressao em mais de
-- uma combinacao. O gasto NAO e somavel nesse grao. Prova, na campanha Localizador:
--   18/08  Ads R$16,69  |  E001 R$16,69  |  placement R$39,12 (64 linhas)
-- O E001 bate ao centavo; o placement infla 2,3x naquele dia.
--
-- O QUE SOBREVIVE: a inflacao e UNIFORME entre as metricas — gasto 1,142, cliques 1,139,
-- impressoes 1,147. A linha e replicada inteira, entao toda RAZAO se preserva:
--   *_share_45d  e  *_cpc_45d   -> confiaveis, ficam
--   *_spend_45d, *_clicks_45d, *_impressions_45d (absolutos) -> saem
--
-- Mesmo tratamento da migration 232: zera com CREATE OR REPLACE em vez de remover a
-- coluna, para nao tocar em dependentes e para voltar trocando seis linhas.

CREATE OR REPLACE VIEW marketcloud_features.feature_full_control_campaign_hour_v1 AS
 WITH hourly AS (
         SELECT lower(TRIM(BOTH FROM g.campaign_name)) AS campaign_norm,
            max(g.campaign_name) AS campaign_name,
            max(i.campaign_id) AS campaign_id,
            g.event_hour,
            count(DISTINCT g.data_date) AS days_observed,
            sum(g.impressions) AS impressions,
            sum(g.clicks) AS clicks,
            sum(g.spend) AS spend,
            COALESCE(sum(g.orders_7d) FILTER (WHERE g.conversion_trustworthy), 0::numeric) AS orders,
            COALESCE(sum(g.sales_7d) FILTER (WHERE g.conversion_trustworthy), 0::numeric) AS sales,
            COALESCE(sum(g.spend) FILTER (WHERE g.conversion_trustworthy), 0::numeric) AS spend_mature,
            count(DISTINCT g.data_date) FILTER (WHERE g.conversion_trustworthy) AS mature_days,
            COALESCE(max(g.amc_assist_rate), 0::numeric) AS amc_assist_rate,
            COALESCE(max(g.amc_first_touch_rate), 0::numeric) AS amc_first_touch_rate,
            COALESCE(max(g.amc_new_customer_rate), 0::numeric) AS amc_new_customer_rate,
            COALESCE(max(g.amc_dpv_count), 0::numeric) AS amc_dpv_count,
            COALESCE(max(g.amc_cart_adds), 0::numeric) AS amc_cart_adds,
            COALESCE(max(g.learn_roas_delta_avg), 0::double precision)::numeric AS learn_roas_delta_avg,
            COALESCE(max(g.learn_win_rate), 0.5::double precision)::numeric AS learn_win_rate,
            max(g.campaign_status) AS campaign_status
           FROM marketcloud_gold.gold_hourly_signal_amc g
             LEFT JOIN marketcloud_gold.gold_campaign_identity i ON i.campaign_norm = lower(TRIM(BOTH FROM g.campaign_name))
          WHERE upper(COALESCE(g.campaign_status, 'ENABLED'::text)) <> ALL (ARRAY['ARCHIVED'::text, 'PAUSED'::text, 'DELETED'::text])
          GROUP BY (lower(TRIM(BOTH FROM g.campaign_name))), g.event_hour
        ), latest_structure AS (
         SELECT DISTINCT ON (amazon_ads_campaigns_daily.campaign_id) amazon_ads_campaigns_daily.campaign_id,
            amazon_ads_campaigns_daily.budget_amount::numeric AS current_budget_brl,
            amazon_ads_campaigns_daily.budget_type,
            amazon_ads_campaigns_daily.bidding_strategy,
            COALESCE(amazon_ads_campaigns_daily.top_of_search_bid_adjustment, 0::numeric) AS top_of_search_bid_adjustment,
            amazon_ads_campaigns_daily.campaign_status AS structure_campaign_status,
            amazon_ads_campaigns_daily.synced_at AS structure_synced_at
           FROM swarm_src.amazon_ads_campaigns_daily
          WHERE COALESCE(amazon_ads_campaigns_daily.campaign_id, ''::text) <> ''::text
          ORDER BY amazon_ads_campaigns_daily.campaign_id, amazon_ads_campaigns_daily.date DESC NULLS LAST, amazon_ads_campaigns_daily.synced_at DESC NULLS LAST
        ), placement AS (
         SELECT silver_placement_creative_daily.campaign_id,
            sum(silver_placement_creative_daily.spend) AS placement_spend,
            sum(silver_placement_creative_daily.clicks) AS placement_clicks,
            sum(silver_placement_creative_daily.impressions) AS placement_impressions,
            sum(silver_placement_creative_daily.spend) FILTER (WHERE silver_placement_creative_daily.placement_type = 'Top of Search on-Amazon'::text) AS top_search_spend,
            sum(silver_placement_creative_daily.clicks) FILTER (WHERE silver_placement_creative_daily.placement_type = 'Top of Search on-Amazon'::text) AS top_search_clicks,
            sum(silver_placement_creative_daily.impressions) FILTER (WHERE silver_placement_creative_daily.placement_type = 'Top of Search on-Amazon'::text) AS top_search_impressions,
            sum(silver_placement_creative_daily.spend) FILTER (WHERE silver_placement_creative_daily.placement_type = 'Detail Page on-Amazon'::text) AS product_page_spend,
            sum(silver_placement_creative_daily.clicks) FILTER (WHERE silver_placement_creative_daily.placement_type = 'Detail Page on-Amazon'::text) AS product_page_clicks,
            sum(silver_placement_creative_daily.impressions) FILTER (WHERE silver_placement_creative_daily.placement_type = 'Detail Page on-Amazon'::text) AS product_page_impressions,
            sum(silver_placement_creative_daily.spend) FILTER (WHERE silver_placement_creative_daily.placement_type = 'Other on-Amazon'::text) AS rest_search_spend,
            sum(silver_placement_creative_daily.clicks) FILTER (WHERE silver_placement_creative_daily.placement_type = 'Other on-Amazon'::text) AS rest_search_clicks,
            sum(silver_placement_creative_daily.impressions) FILTER (WHERE silver_placement_creative_daily.placement_type = 'Other on-Amazon'::text) AS rest_search_impressions
           FROM marketcloud_silver.silver_placement_creative_daily
          WHERE COALESCE(silver_placement_creative_daily.campaign_id, ''::text) <> ''::text AND silver_placement_creative_daily.data_date >= (CURRENT_DATE - 45)
          GROUP BY silver_placement_creative_daily.campaign_id
        ), pilot AS (
         SELECT DISTINCT ON (full_control_effective_governance_v1.campaign_id) full_control_effective_governance_v1.campaign_id,
            full_control_effective_governance_v1.mode,
            full_control_effective_governance_v1.status,
            COALESCE(full_control_effective_governance_v1.sale_price_brl, 0::numeric) AS sale_price_brl,
            COALESCE(full_control_effective_governance_v1.unit_cost_brl, 0::numeric) AS unit_cost_brl,
            COALESCE(full_control_effective_governance_v1.stock_available, 0::numeric) AS stock_available,
            COALESCE(full_control_effective_governance_v1.gross_margin_brl, 0::numeric) AS gross_margin_brl,
            COALESCE(full_control_effective_governance_v1.gross_margin_pct, 0::numeric) AS gross_margin_pct,
            COALESCE(full_control_effective_governance_v1.max_daily_budget_brl, 0::numeric) AS max_daily_budget_brl,
            COALESCE(full_control_effective_governance_v1.max_spend_without_order_brl, 0::numeric) AS max_spend_without_order_brl,
            COALESCE(full_control_effective_governance_v1.min_roas, 0::numeric) AS min_roas,
            COALESCE(full_control_effective_governance_v1.max_top_of_search_pct, 0::numeric) AS max_top_of_search_pct,
            COALESCE(full_control_effective_governance_v1.max_product_page_pct, 0::numeric) AS max_product_page_pct,
            COALESCE(full_control_effective_governance_v1.max_rest_of_search_pct, 0::numeric) AS max_rest_of_search_pct,
            COALESCE(full_control_effective_governance_v1.current_budget_brl, 0::numeric) AS governance_current_budget_brl,
            COALESCE(full_control_effective_governance_v1.can_control, false) AS can_control,
            full_control_effective_governance_v1.gate_reason
           FROM marketcloud_gold.full_control_effective_governance_v1
          WHERE COALESCE(full_control_effective_governance_v1.campaign_id, ''::text) <> ''::text
          ORDER BY full_control_effective_governance_v1.campaign_id, (
                CASE full_control_effective_governance_v1.status
                    WHEN 'active'::text THEN 0
                    WHEN 'draft'::text THEN 1
                    ELSE 2
                END), full_control_effective_governance_v1.updated_at DESC
        )
 SELECT h.campaign_norm,
    h.campaign_name,
    h.campaign_id,
    h.event_hour,
    h.days_observed,
    h.impressions,
    h.clicks,
    h.spend,
    h.orders,
    h.sales,
    h.spend_mature,
    h.mature_days,
    h.amc_assist_rate,
    h.amc_first_touch_rate,
    h.amc_new_customer_rate,
    h.amc_dpv_count,
    h.amc_cart_adds,
    h.learn_roas_delta_avg,
    h.learn_win_rate,
    COALESCE(ls.current_budget_brl, 0::numeric) AS current_budget_brl,
        CASE
            WHEN COALESCE(ls.current_budget_brl, 0::numeric) > 0::numeric THEN h.spend / NULLIF(ls.current_budget_brl, 0::numeric)
            ELSE 0::numeric
        END AS spend_to_budget_ratio,
    COALESCE(ls.top_of_search_bid_adjustment, 0::numeric) AS top_of_search_bid_adjustment,
    COALESCE(ls.top_of_search_bid_adjustment, 0::numeric) / 100.0 AS top_of_search_multiplier_delta,
        CASE
            WHEN ls.bidding_strategy ~~* '%LEGACY%'::text THEN 1
            ELSE 0
        END AS bidding_legacy_for_sales,
    COALESCE(p.sale_price_brl, 0::numeric) AS sale_price_brl,
    COALESCE(p.unit_cost_brl, 0::numeric) AS unit_cost_brl,
    COALESCE(p.stock_available, 0::numeric) AS stock_available,
    COALESCE(p.gross_margin_brl, 0::numeric) AS gross_margin_brl,
    COALESCE(p.gross_margin_pct, 0::numeric) AS gross_margin_pct,
    COALESCE(p.max_daily_budget_brl, 0::numeric) AS max_daily_budget_brl,
    COALESCE(p.max_spend_without_order_brl, 0::numeric) AS max_spend_without_order_brl,
    COALESCE(p.min_roas, 0::numeric) AS min_roas,
        CASE
            WHEN COALESCE(p.max_daily_budget_brl, 0::numeric) > 0::numeric THEN h.spend / NULLIF(p.max_daily_budget_brl, 0::numeric)
            ELSE 0::numeric
        END AS spend_to_fc_daily_cap_ratio,
        CASE
            WHEN COALESCE(p.max_spend_without_order_brl, 0::numeric) > 0::numeric THEN h.spend / NULLIF(p.max_spend_without_order_brl, 0::numeric)
            ELSE 0::numeric
        END AS spend_to_stop_loss_ratio,
        CASE
            WHEN p.mode = 'full_control'::text THEN 1
            ELSE 0
        END AS is_full_control_pilot,
        CASE
            WHEN p.status = 'active'::text THEN 1
            ELSE 0
        END AS is_active_pilot,
        CASE
            WHEN COALESCE(p.can_control, false) THEN 1
            ELSE 0
        END AS can_control_flag,
    NULL::numeric AS placement_spend_45d,
    NULL::numeric AS placement_clicks_45d,
    NULL::numeric AS placement_impressions_45d,
    NULL::numeric AS top_search_spend_45d,
    NULL::numeric AS product_page_spend_45d,
    NULL::numeric AS rest_search_spend_45d,
        CASE
            WHEN COALESCE(pl.placement_spend, 0::numeric) > 0::numeric THEN COALESCE(pl.top_search_spend, 0::numeric) / NULLIF(pl.placement_spend, 0::numeric)
            ELSE 0::numeric
        END AS top_search_spend_share_45d,
        CASE
            WHEN COALESCE(pl.placement_spend, 0::numeric) > 0::numeric THEN COALESCE(pl.product_page_spend, 0::numeric) / NULLIF(pl.placement_spend, 0::numeric)
            ELSE 0::numeric
        END AS product_page_spend_share_45d,
        CASE
            WHEN COALESCE(pl.placement_spend, 0::numeric) > 0::numeric THEN COALESCE(pl.rest_search_spend, 0::numeric) / NULLIF(pl.placement_spend, 0::numeric)
            ELSE 0::numeric
        END AS rest_search_spend_share_45d,
        CASE
            WHEN COALESCE(pl.top_search_clicks, 0::numeric) > 0::numeric THEN COALESCE(pl.top_search_spend, 0::numeric) / NULLIF(pl.top_search_clicks, 0::numeric)
            ELSE 0::numeric
        END AS top_search_cpc_45d,
        CASE
            WHEN COALESCE(pl.product_page_clicks, 0::numeric) > 0::numeric THEN COALESCE(pl.product_page_spend, 0::numeric) / NULLIF(pl.product_page_clicks, 0::numeric)
            ELSE 0::numeric
        END AS product_page_cpc_45d,
        CASE
            WHEN COALESCE(pl.rest_search_clicks, 0::numeric) > 0::numeric THEN COALESCE(pl.rest_search_spend, 0::numeric) / NULLIF(pl.rest_search_clicks, 0::numeric)
            ELSE 0::numeric
        END AS rest_search_cpc_45d,
    COALESCE(p.max_top_of_search_pct, 0::numeric) AS max_top_of_search_pct,
    COALESCE(p.max_product_page_pct, 0::numeric) AS max_product_page_pct,
    COALESCE(p.max_rest_of_search_pct, 0::numeric) AS max_rest_of_search_pct
   FROM hourly h
     LEFT JOIN latest_structure ls ON ls.campaign_id = h.campaign_id
     LEFT JOIN placement pl ON pl.campaign_id = h.campaign_id
     LEFT JOIN pilot p ON p.campaign_id = h.campaign_id;
;
