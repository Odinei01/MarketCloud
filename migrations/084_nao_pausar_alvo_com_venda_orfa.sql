-- 084: nao pausar alvo quando a venda da campanha nao fecha com as keywords.
-- (substitui 077 e 078 — a definicao final da priority_v2 vive aqui)
--
-- Contexto: 075 levou o alvo do ML pra LISTA do cockpit (actionable_v3), mas os
-- CARDS do topo leem gold_action_impact_summary_v2 -> gold_recommendation_priority_v2.
-- Duas fontes, um conserto so: a lista mudava (CUT_HOUR 81->32) e os cards nao.
-- O dono viu na hora: "as recomendacoes continuam as mesmas".
--
-- gold_recommendation_priority_v2 e um envelope simples sobre a unified_v2, e as
-- QUATRO views penduram nela (summary, actionable, review_queue,
-- campaign_action_plan). Trocando a FONTE aqui dentro, todas herdam de uma vez —
-- e o proprio corpo da view (action_weight, que faz CASE final_action_type) passa
-- a usar a acao corrigida sozinho.
--
-- As constantes chapadas nascem na unified_v2 (CUT_HOUR 0.50 / BID_DOWN 0.75 /
-- BID_UP 1.20), sem olhar ROAS nenhum. Nao mexo la: 17k chars decidindo TODAS as
-- acoes da conta (negativar, pausar, budget), e o alvo horario nao diz nada sobre
-- elas. O override fica no envelope, so nas acoes horarias.
CREATE OR REPLACE VIEW marketcloud_gold.gold_recommendation_priority_v2 AS
 SELECT recommendation_id,
    tenant_id,
    amc_instance_id,
    ads_profile_id,
    source_gold_view,
    entity_type,
    entity_key,
    campaign_id,
    campaign_name,
    ad_product_type,
    ad_group_name,
    event_hour,
    customer_search_term,
    gold_action_type,
    gold_bid_multiplier,
    gold_reason_code,
    gold_risk_level,
    gold_confidence_score,
    gold_evidence_json,
    model_name,
    model_version,
    predicted_action_type,
    predicted_bid_multiplier,
    ml_confidence_score,
    prediction_risk_level,
    prediction_evidence_json,
    features_snapshot,
    agreement,
    action_conflict,
    spend,
    clicks,
    orders,
    sales,
    roas,
    cpc,
    conversion_rate,
    financial_impact_score,
    priority_score,
    final_action_type,
    final_bid_multiplier,
    final_confidence_score,
    final_risk_level,
    recommendation_status,
    created_at,
        CASE final_risk_level
            WHEN 'HIGH'::text THEN 100
            WHEN 'MEDIUM'::text THEN 60
            WHEN 'LOW'::text THEN 30
            WHEN 'WATCH'::text THEN 20
            ELSE 10
        END AS risk_score,
    round(final_confidence_score * 100::numeric, 2) AS confidence_weight,
    financial_impact_score AS impact_weight,
        CASE final_action_type
            WHEN 'CUT_HOUR'::text THEN 100
            WHEN 'ADD_NEGATIVE_EXACT'::text THEN 95
            WHEN 'ADD_NEGATIVE_PHRASE'::text THEN 95
            WHEN 'PAUSE_TARGET'::text THEN 90
            WHEN 'CUT_CAMPAIGN_BUDGET'::text THEN 85
            WHEN 'BID_DOWN'::text THEN 80
            WHEN 'REDUCE_BID'::text THEN 75
            WHEN 'BID_UP'::text THEN 65
            WHEN 'HARVEST_SEARCH_TERM'::text THEN 60
            WHEN 'MOVE_TO_EXACT'::text THEN 58
            WHEN 'SCALE_CAMPAIGN'::text THEN 55
            WHEN 'INCREASE_BID'::text THEN 55
            WHEN 'WATCH'::text THEN 20
            WHEN 'HOLD'::text THEN 10
            ELSE 15
        END AS action_weight,
    row_number() OVER (PARTITION BY tenant_id ORDER BY priority_score DESC, spend DESC NULLS LAST) AS priority_rank,
        CASE
            WHEN priority_score >= 85::numeric THEN 'P0_CRITICAL'::text
            WHEN priority_score >= 70::numeric THEN 'P1_HIGH'::text
            WHEN priority_score >= 50::numeric THEN 'P2_MEDIUM'::text
            ELSE 'P3_LOW'::text
        END AS priority_bucket
   FROM (
     SELECT
          m.recommendation_id,
          m.tenant_id,
          m.amc_instance_id,
          m.ads_profile_id,
          m.source_gold_view,
          m.entity_type,
          m.entity_key,
          m.campaign_id,
          m.campaign_name,
          m.ad_product_type,
          m.ad_group_name,
          m.event_hour,
          m.customer_search_term,
          m.gold_action_type,
          m.gold_bid_multiplier,
          m.gold_reason_code,
          m.gold_risk_level,
          m.gold_confidence_score,
          m.gold_evidence_json,
          m.model_name,
          m.model_version,
          m.predicted_action_type,
          m.predicted_bid_multiplier,
          m.ml_confidence_score,
          m.prediction_risk_level,
          m.prediction_evidence_json,
          m.features_snapshot,
          m.agreement,
          m.action_conflict,
          m.spend,
          m.clicks,
          m.orders,
          m.sales,
          m.roas,
          m.cpc,
          m.conversion_rate,
          m.final_action_type,
          m.final_bid_multiplier,
          m.final_confidence_score,
          m.final_risk_level,
          m.recommendation_status,
          m.created_at
,
          -- Impacto e prioridade RECALCULADOS sobre a acao e o gasto ja
          -- corrigidos. Mesmos pesos da unified_v2 — nao inventei formula,
          -- so troquei as entradas que estavam erradas: a acao (corte que o ML
          -- derrubou pesava 100, agora WATCH pesa 20) e o gasto (que vinha do
          -- silver cego). Sem isso a linha virava WATCH e continuava P0 CRITICAL.
          CASE
              WHEN m.spend >= 100::numeric THEN 100
              WHEN m.spend >= 50::numeric THEN 75
              WHEN m.spend >= 20::numeric THEN 50
              WHEN m.spend > 0::numeric THEN 25
              ELSE 10
          END AS financial_impact_score,
          round(
              CASE m.final_action_type
                  WHEN 'CUT_HOUR'::text THEN 100
                  WHEN 'ADD_NEGATIVE_EXACT'::text THEN 95
                  WHEN 'ADD_NEGATIVE_PHRASE'::text THEN 95
                  WHEN 'PAUSE_TARGET'::text THEN 90
                  WHEN 'CUT_CAMPAIGN_BUDGET'::text THEN 85
                  WHEN 'BID_DOWN'::text THEN 80
                  WHEN 'REDUCE_BID'::text THEN 75
                  WHEN 'BID_UP'::text THEN 65
                  WHEN 'HARVEST_SEARCH_TERM'::text THEN 60
                  WHEN 'MOVE_TO_EXACT'::text THEN 58
                  WHEN 'SCALE_CAMPAIGN'::text THEN 55
                  WHEN 'INCREASE_BID'::text THEN 55
                  WHEN 'WATCH'::text THEN 20
                  WHEN 'HOLD'::text THEN 10
                  ELSE 15
              END::numeric * 0.35 +
              CASE m.final_risk_level
                  WHEN 'HIGH'::text THEN 100
                  WHEN 'MEDIUM'::text THEN 60
                  WHEN 'LOW'::text THEN 30
                  WHEN 'WATCH'::text THEN 20
                  ELSE 10
              END::numeric * 0.25 +
              CASE
                  WHEN m.spend >= 100::numeric THEN 100
                  WHEN m.spend >= 50::numeric THEN 75
                  WHEN m.spend >= 20::numeric THEN 50
                  WHEN m.spend > 0::numeric THEN 25
                  ELSE 10
              END::numeric * 0.25 +
              m.final_confidence_score * 100::numeric * 0.15
          , 2) AS priority_score
     FROM (
     SELECT
        x.recommendation_id,
        x.tenant_id,
        x.amc_instance_id,
        x.ads_profile_id,
        x.source_gold_view,
        x.entity_type,
        x.entity_key,
        x.campaign_id,
        x.campaign_name,
        x.ad_product_type,
        x.ad_group_name,
        x.event_hour,
        x.customer_search_term,
        x.gold_action_type,
        x.gold_bid_multiplier,
        x.gold_reason_code,
        x.gold_risk_level,
        x.gold_confidence_score,
        x.gold_evidence_json,
        x.model_name,
        x.model_version,
        x.predicted_action_type,
        x.predicted_bid_multiplier,
        x.ml_confidence_score,
        x.prediction_risk_level,
        x.prediction_evidence_json,
        x.features_snapshot,
        x.agreement,
        x.action_conflict,
        -- METRICA REAL nas linhas horarias: o silver que alimenta a
        -- gold_hourly_bid_schedule vem do AMC e SUPRIME conversao de baixo
        -- volume — enxerga 25 de 239 horas que vendem (R$2.5k de R$11.1k).
        -- Por isso quase toda hora aparecia com ROAS 0 e virava corte P0.
        -- gold_hourly_signal_amc vem do AMS, que nao suprime.
        -- RATEIO: a metrica real e por campanha x hora, mas a linha e por
        -- campanha x ad group x hora (87 pares duplicados). Jogar o valor cheio
        -- em cada linha dobraria o 'gasto em risco'. O gasto do silver e
        -- confiavel (bate com o real); so a VENDA e cega. Entao rateia pela
        -- participacao de gasto de cada ad group naquela campanha x hora.
        CASE WHEN h.horaria_metrica THEN round((sig.gasto * rateio.parte)::numeric, 4) ELSE x.spend END AS spend,
        CASE WHEN h.horaria_metrica THEN round((sig.cliques * rateio.parte)::numeric, 4) ELSE x.clicks END AS clicks,
        CASE WHEN h.horaria_metrica THEN round((sig.pedidos * rateio.parte)::numeric, 4) ELSE x.orders END AS orders,
        CASE WHEN h.horaria_metrica THEN round((sig.venda * rateio.parte)::numeric, 4) ELSE x.sales END AS sales,
        CASE WHEN h.horaria_metrica THEN sig.roas ELSE x.roas END AS roas,
        x.cpc,
        x.conversion_rate,
        x.financial_impact_score,
        x.priority_score,
        x.final_confidence_score,
        x.final_risk_level,
        x.recommendation_status,
        x.created_at
,
        -- acao horaria que o ML NAO sustenta vira WATCH: sem isso a tela diria
        -- "cortar" e o valor aplicado SUBIRIA o lance.
        -- NAO DESTRUIR O QUE NAO SE CONSEGUE MEDIR.
        -- Campanha sem NENHUM sinal do AMS (ex.: as [SD] - Retargeting, cuja
        -- assinatura sd-traffic/sd-conversion so subiu em 15/07 a noite) cai no
        -- silver alimentado pelo AMC, que suprime conversao -> aparece ROAS 0,00
        -- e vira "cortar/pausar P0 CRITICO". Eram as MESMAS campanhas que o AMC
        -- mostra com lift 26-50x e compradores reais. Ausencia de dado nao e
        -- prova de fracasso: vira WATCH ate o AMS trazer o dado.
        CASE WHEN x.final_action_type IN ('CUT_HOUR','BID_DOWN','PAUSE_TARGET','CUT_CAMPAIGN_BUDGET')
                  AND NOT EXISTS (SELECT 1 FROM marketcloud_gold.gold_hourly_signal_amc g
                                  WHERE g.campaign_name = x.campaign_name)
             THEN 'WATCH'::text
             -- PAUSE_TARGET nasce do bronze_amc_target_daily, que atribui venda a
             -- keyword — e o AMC suprime justo a keyword de baixo volume, que e a
             -- que aparece com "0 vendas". Se a campanha tem venda que NAO fecha com
             -- a soma das keywords, esse zero pode ser supressao. Ex. Seladora:
             -- keywords somam R$1.790 de R$2.201 reais — faltam 19%. Nao se pausa
             -- alvo com base num zero que pode nao existir.
             WHEN x.final_action_type = 'PAUSE_TARGET' AND gap.suspeito THEN 'WATCH'::text
             WHEN h.horaria AND t.ml_multiplier >= COALESCE(cur.multiplier, 1.0) - 0.05
             THEN 'WATCH'::text ELSE x.final_action_type END AS final_action_type,
        -- WATCH nao pode propor lance novo: fica no multiplicador ATUAL. O dono
        -- clicava OK numa linha "nao faca nada" e o lance mudava.
        -- WATCH NUNCA propoe lance novo: fica no multiplicador ATUAL da campanha.
        -- Vale pro WATCH que eu converto (corte que o ML nao sustenta) E pro
        -- WATCH que ja vinha do sistema, que carregava a constante 1.00 — clicar
        -- OK nele subia o lance de quem estava em 0.7. "Observar" nao mexe em nada.
        -- sem sinal: nao propoe lance nenhum (1.00 = convencao de WATCH do sistema)
        CASE WHEN x.final_action_type IN ('CUT_HOUR','BID_DOWN','PAUSE_TARGET','CUT_CAMPAIGN_BUDGET')
                  AND NOT EXISTS (SELECT 1 FROM marketcloud_gold.gold_hourly_signal_amc g
                                  WHERE g.campaign_name = x.campaign_name)
                  THEN COALESCE(cur.multiplier, 1.0)
             WHEN x.event_hour IS NOT NULL
                  AND (x.final_action_type = 'WATCH'
                       OR (h.horaria AND t.ml_multiplier >= COALESCE(cur.multiplier, 1.0) - 0.05))
                  THEN COALESCE(cur.multiplier, 1.0)
             WHEN h.horaria THEN t.ml_multiplier
             ELSE x.final_bid_multiplier END AS final_bid_multiplier
     FROM marketcloud_gold.gold_recommendation_unified_v2 x
     LEFT JOIN marketcloud_gold.gold_hourly_ml_target_mv t
       ON t.campaign_name = x.campaign_name AND t.event_hour = x.event_hour
     LEFT JOIN LATERAL (
        -- multiplicador que a campanha tem hoje naquela hora (escopo CAMPAIGN)
        SELECT s.multiplier FROM marketcloud_bronze.bronze_swarm_bid_schedule s
        WHERE lower(trim(s.campaign_name)) = lower(trim(x.campaign_name))
          AND s.hour_start <= x.event_hour AND s.hour_end > x.event_hour
          AND COALESCE(s.day_of_week,'') = ''
          AND COALESCE(s.profile_is_active, true) = true
          AND upper(COALESCE(s.profile_status,'')) = 'PUBLISHED'
          AND s.scope = 'CAMPAIGN'
        LIMIT 1
     ) cur ON TRUE
     LEFT JOIN LATERAL (
        -- metrica real da campanha x hora (AMS, sem supressao)
        SELECT sum(g.spend) AS gasto, sum(g.clicks) AS cliques, sum(g.orders_7d) AS pedidos,
               sum(g.sales_7d) AS venda,
               CASE WHEN sum(g.spend) > 0 THEN sum(g.sales_7d)/sum(g.spend) ELSE 0 END AS roas
        FROM marketcloud_gold.gold_hourly_signal_amc g
        WHERE g.campaign_name = x.campaign_name AND g.event_hour = x.event_hour
     ) sig ON TRUE
     LEFT JOIN LATERAL (
        -- parte deste ad group no gasto da campanha x hora (do silver, que
        -- acerta gasto). Sem outra linha na mesma hora, parte = 1.
        SELECT CASE WHEN sum(o.spend) > 0 THEN x.spend / sum(o.spend)
                    -- ninguem gastou no silver: divide igual entre as linhas da hora,
                    -- senao cada uma leva 100% e o gasto em risco dobra.
                    ELSE 1.0 / GREATEST(count(*), 1) END AS parte
        FROM marketcloud_gold.gold_recommendation_unified_v2 o
        WHERE o.campaign_name = x.campaign_name AND o.event_hour = x.event_hour
          AND o.source_gold_view = 'gold_hourly_bid_schedule'
     ) rateio ON TRUE
     LEFT JOIN LATERAL (
        -- a venda da campanha fecha com a soma das keywords? >5% de gap = o AMC
        -- suprimiu algo, entao "0 vendas" na keyword nao e prova.
        SELECT (COALESCE(kw.venda,0) < 0.95 * COALESCE(rel.venda,0)) AS suspeito
        FROM (SELECT sum(sales) AS venda FROM marketcloud_bronze.bronze_amc_target_daily d
              WHERE d.campaign_name = x.campaign_name) kw,
             (SELECT sum(sales_7d) AS venda FROM marketcloud_bronze.bronze_amazon_ads_hourly r
              WHERE r.campaign_name = x.campaign_name) rel
     ) gap ON TRUE
     CROSS JOIN LATERAL (
        SELECT (x.final_action_type IN ('CUT_HOUR','BID_DOWN')
                AND x.event_hour IS NOT NULL
                AND t.ml_multiplier IS NOT NULL) AS horaria,
               -- so troca a metrica onde ela vem do silver cego (linhas horarias)
               (x.event_hour IS NOT NULL
                AND x.source_gold_view = 'gold_hourly_bid_schedule'
                AND sig.gasto IS NOT NULL) AS horaria_metrica
     ) h
   ) m
   ) u;