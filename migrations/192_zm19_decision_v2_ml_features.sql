-- 192: ZM19 Decision Engine V2 entra no ML como feature, nao como decisor.
-- O SWARM calcula estado/gargalo/query/capital/outcome; o MarketCloud consome
-- sinais point-in-time/latest como contexto de treino e inferencia.

CREATE SCHEMA IF NOT EXISTS marketcloud_features;
CREATE SCHEMA IF NOT EXISTS swarm_src;

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.zm19_query_state_daily (
  as_of_date date,
  asin text,
  query_text text,
  query_key text,
  query_state text,
  confidence text,
  impressions_14d bigint,
  clicks_14d bigint,
  orders_14d bigint,
  spend_14d numeric(14,2),
  sales_14d numeric(14,2),
  brand_impression_share numeric(14,6),
  brand_click_share numeric(14,6),
  brand_cart_add_share numeric(14,6),
  brand_purchase_share numeric(14,6),
  purchase_share_lift numeric(14,6),
  evidence jsonb,
  computed_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'zm19_query_state_daily');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.zm19_capital_allocation_daily (
  as_of_date date,
  asin text,
  tier text,
  ppc_score numeric(8,2),
  learning_allowance_brl numeric(14,2),
  scale_budget_cap_brl numeric(14,2),
  hard_cpc_brl numeric(14,2),
  capital_policy text,
  evidence jsonb,
  computed_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'zm19_capital_allocation_daily');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.zm19_action_yield_daily (
  as_of_date date,
  action text,
  bottleneck text,
  samples integer,
  wins integer,
  losses integer,
  neutral integer,
  pending integer,
  win_rate numeric(8,4),
  avg_contribution_delta numeric(14,2),
  decision_note text,
  evidence jsonb,
  computed_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'zm19_action_yield_daily');

DROP VIEW IF EXISTS marketcloud_features.feature_zm19_decision_v2_context_v1;

CREATE OR REPLACE VIEW marketcloud_features.feature_zm19_decision_v2_context_v1 AS
WITH latest_q AS (
  SELECT DISTINCT ON (asin, query_key)
    asin,
    query_key,
    query_state,
    confidence AS query_confidence,
    impressions_14d,
    clicks_14d,
    orders_14d,
    spend_14d,
    sales_14d,
    brand_impression_share,
    brand_click_share,
    brand_cart_add_share,
    brand_purchase_share,
    purchase_share_lift,
    as_of_date,
    computed_at
  FROM swarm_src.zm19_query_state_daily
  ORDER BY asin, query_key, as_of_date DESC, computed_at DESC
),
latest_cap AS (
  SELECT DISTINCT ON (asin)
    asin,
    tier,
    ppc_score,
    learning_allowance_brl,
    scale_budget_cap_brl,
    hard_cpc_brl,
    capital_policy,
    as_of_date
  FROM swarm_src.zm19_capital_allocation_daily
  ORDER BY asin, as_of_date DESC, computed_at DESC
),
yield_summary AS (
  SELECT
    coalesce(sum(samples),0)::numeric AS zm19_action_samples,
    coalesce(sum(wins),0)::numeric AS zm19_action_wins,
    coalesce(sum(losses),0)::numeric AS zm19_action_losses,
    coalesce(avg(win_rate),0)::numeric AS zm19_action_avg_win_rate,
    coalesce(avg(avg_contribution_delta),0)::numeric AS zm19_action_avg_contribution_delta
  FROM swarm_src.zm19_action_yield_daily
  WHERE as_of_date = (SELECT max(as_of_date) FROM swarm_src.zm19_action_yield_daily)
)
SELECT
  q.asin,
  q.query_key,
  1::int AS has_zm19_v2_context,
  CASE q.query_state
    WHEN 'QUERY_CHAMPION' THEN 7
    WHEN 'PROVEN_CONVERTER' THEN 6
    WHEN 'PROMISING_LOW_SAMPLE' THEN 5
    WHEN 'CLICK_GAP' THEN 4
    WHEN 'CONVERSION_GAP' THEN 3
    WHEN 'UNPROVEN' THEN 2
    WHEN 'INSUFFICIENT_SAMPLE' THEN 1
    ELSE 0
  END::numeric AS zm19_query_state_score,
  CASE q.query_confidence
    WHEN 'VERY_HIGH' THEN 5
    WHEN 'HIGH' THEN 4
    WHEN 'MEDIUM' THEN 3
    WHEN 'LOW' THEN 2
    ELSE 1
  END::numeric AS zm19_query_confidence_score,
  coalesce(q.impressions_14d,0)::numeric AS zm19_query_impressions_14d,
  coalesce(q.clicks_14d,0)::numeric AS zm19_query_clicks_14d,
  coalesce(q.orders_14d,0)::numeric AS zm19_query_orders_14d,
  coalesce(q.spend_14d,0)::numeric AS zm19_query_spend_14d,
  coalesce(q.sales_14d,0)::numeric AS zm19_query_sales_14d,
  coalesce(q.brand_impression_share,0)::numeric AS zm19_brand_impression_share,
  coalesce(q.brand_click_share,0)::numeric AS zm19_brand_click_share,
  coalesce(q.brand_cart_add_share,0)::numeric AS zm19_brand_cart_add_share,
  coalesce(q.brand_purchase_share,0)::numeric AS zm19_brand_purchase_share,
  coalesce(q.purchase_share_lift,0)::numeric AS zm19_purchase_share_lift,
  CASE cap.tier
    WHEN 'TIER_1_SCALE' THEN 5
    WHEN 'TIER_2_EXPAND' THEN 4
    WHEN 'TIER_3_LEARN' THEN 3
    WHEN 'TIER_4_DIAGNOSTIC' THEN 2
    ELSE 1
  END::numeric AS zm19_capital_tier_score,
  coalesce(cap.ppc_score,0)::numeric AS zm19_ppc_score,
  coalesce(cap.learning_allowance_brl,0)::numeric AS zm19_learning_allowance_brl,
  coalesce(cap.scale_budget_cap_brl,0)::numeric AS zm19_scale_budget_cap_brl,
  coalesce(cap.hard_cpc_brl,0)::numeric AS zm19_hard_cpc_brl,
  CASE cap.capital_policy
    WHEN 'ALLOW_SCALE_WITH_ML_APPROVAL' THEN 3
    WHEN 'ALLOW_LEARNING_ONLY' THEN 2
    WHEN 'PROTECT_CAPITAL_WAIT_ML' THEN 1
    ELSE 0
  END::numeric AS zm19_capital_policy_score,
  ys.zm19_action_samples,
  ys.zm19_action_wins,
  ys.zm19_action_losses,
  ys.zm19_action_avg_win_rate,
  ys.zm19_action_avg_contribution_delta,
  q.as_of_date AS zm19_context_date
FROM latest_q q
LEFT JOIN latest_cap cap ON cap.asin = q.asin
CROSS JOIN yield_summary ys;

COMMENT ON VIEW marketcloud_features.feature_zm19_decision_v2_context_v1 IS
'Features ZM19 Decision Engine V2 para o ML. Estado/query/capital/yield viram numeros; nao ha recomendacao deterministica nesta view.';
