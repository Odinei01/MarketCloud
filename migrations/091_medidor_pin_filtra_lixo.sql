-- P1-4 da auditoria (16/07): measure_keyword_pin_outcomes le bronze_ams_hourly_target
-- CRU, que tem negativos de transicao do stream (217 linhas com impressao
-- negativa, 3 com clique/gasto/venda negativos) — o medidor somava isso no
-- WIN/LOSS. A auditoria sugeriu ler a camada canonica; nao da: a canonica e
-- grao campanha x hora e o pin mede keyword x hora (keyword_id nao existe la).
--
-- Fix no grao certo: aplicar no bronze de keyword a MESMA protecao que a
-- canonica da — descartar linha com metrica negativa (delta de transicao) antes
-- de somar. So muda o FROM ... WHERE; resto da funcao identico a 074.
CREATE OR REPLACE FUNCTION marketcloud_gold.measure_keyword_pin_outcomes(min_dias integer DEFAULT 3, min_cliques integer DEFAULT 5, neutro_pct numeric DEFAULT 0.10)
 RETURNS TABLE(medidos bigint, sem_dado_ainda bigint)
 LANGUAGE plpgsql
AS $function$
DECLARE n_med BIGINT := 0;
BEGIN
    WITH pend AS (
        SELECT o.id, o.entity_id, o.target_hour, o.applied_at, o.baseline_roas, o.baseline_orders, o.baseline_cost
        FROM swarm_src.amazon_ads_bid_learning_outcomes o
        WHERE o.action_type='KEYWORD_HOUR_PIN' AND o.measured_date IS NULL
          AND o.target_hour IS NOT NULL AND o.entity_id IS NOT NULL
    ), depois AS (
        SELECT p.id, count(DISTINCT t.data_date) dias, sum(t.impressions) impressions,
               sum(t.clicks) clicks, sum(t.spend) cost, sum(t.orders_7d) orders, sum(t.sales_7d) sales
        FROM pend p JOIN marketcloud_bronze.bronze_ams_hourly_target t
          ON t.keyword_id=p.entity_id AND t.event_hour=p.target_hour AND t.data_date > p.applied_at::date
          -- protecao (P1-4): descarta delta de transicao negativo, igual a canonica
          AND coalesce(t.impressions,0) >= 0 AND coalesce(t.clicks,0) >= 0
          AND coalesce(t.spend,0) >= 0 AND coalesce(t.sales_7d,0) >= 0
          AND coalesce(t.orders_7d,0) >= 0
        GROUP BY p.id
    ), calc AS (
        SELECT p.id, d.dias, d.impressions, d.clicks, d.cost, d.orders, d.sales,
               CASE WHEN d.cost>0 THEN d.sales/d.cost ELSE 0 END roas_depois,
               p.baseline_roas, p.baseline_orders, p.baseline_cost
        FROM pend p JOIN depois d ON d.id=p.id)
    UPDATE swarm_src.amazon_ads_bid_learning_outcomes o
    SET measured_date=CURRENT_DATE, measured_impressions=c.impressions, measured_clicks=c.clicks,
        measured_cost=c.cost, measured_orders=c.orders, measured_sales=c.sales, measured_roas=c.roas_depois,
        roas_delta=c.roas_depois-coalesce(c.baseline_roas,0), orders_delta=c.orders-coalesce(c.baseline_orders,0),
        cost_delta=c.cost-coalesce(c.baseline_cost,0),
        outcome_label=CASE WHEN abs(c.roas_depois-coalesce(c.baseline_roas,0)) < neutro_pct*GREATEST(coalesce(c.baseline_roas,0),0.01) THEN 'NEUTRAL'
                           WHEN c.roas_depois > coalesce(c.baseline_roas,0) THEN 'WIN' ELSE 'LOSS' END,
        outcome_reason=format('keyword x hora: %s dias, %s cliques, ROAS %s -> %s', c.dias, c.clicks,
                              round(coalesce(c.baseline_roas,0)::numeric,2), round(c.roas_depois::numeric,2)),
        updated_at=NOW()
    FROM calc c WHERE o.id=c.id AND c.dias>=min_dias AND c.clicks>=min_cliques;
    GET DIAGNOSTICS n_med = ROW_COUNT;

    UPDATE swarm_src.amazon_ads_bid_learning_outcomes o
    SET outcome_label='PENDING_DATA',
        outcome_reason='aguardando volume na hora alvo (min '||min_dias||' dias e '||min_cliques||' cliques)',
        updated_at=NOW()
    WHERE o.action_type='KEYWORD_HOUR_PIN' AND o.measured_date IS NULL AND o.outcome_label <> 'PENDING_DATA';

    medidos := n_med;
    SELECT count(*) INTO sem_dado_ainda FROM swarm_src.amazon_ads_bid_learning_outcomes
    WHERE action_type='KEYWORD_HOUR_PIN' AND measured_date IS NULL;
    RETURN NEXT;
END; $function$;
