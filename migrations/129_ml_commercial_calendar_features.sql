-- =====================================================================
-- ML commercial context + calendar/seasonality features
--
-- Sem mock:
--   - usa economia real Zanom via Full Control/product candidates;
--   - usa qualidade real de produto;
--   - usa calendário derivado das datas reais AMS;
--   - expõe cobertura para concorrente/BSR, mas não inventa valores.
-- =====================================================================

CREATE OR REPLACE VIEW marketcloud_features.feature_calendar_day_v1 AS
WITH bounds AS (
    SELECT
        COALESCE(MIN(data_date), CURRENT_DATE - 60)::date AS min_date,
        (CURRENT_DATE + 90)::date AS max_date
    FROM (
        SELECT data_date FROM marketcloud_bronze.bronze_ams_hourly
        UNION ALL
        SELECT data_date FROM marketcloud_bronze.bronze_ams_hourly_target
    ) d
), days AS (
    SELECT gs::date AS data_date
    FROM bounds b
    CROSS JOIN generate_series(b.min_date, b.max_date, interval '1 day') gs
), easter AS (
    SELECT
        data_date,
        EXTRACT(YEAR FROM data_date)::int AS y
    FROM days
), easter_calc AS (
    SELECT
        data_date,
        y,
        y % 19 AS a,
        floor(y / 100.0)::int AS b,
        y % 100 AS c
    FROM easter
), easter_date AS (
    SELECT
        data_date,
        make_date(y, 3, 22)
        + (
            (
                (19 * a + b - floor(b / 4.0)::int - floor((b - floor((b + 8) / 25.0)::int + 1) / 3.0)::int + 15) % 30
            )
            + (
                32 + 2 * (b % 4) + 2 * floor(c / 4.0)::int
                - ((19 * a + b - floor(b / 4.0)::int - floor((b - floor((b + 8) / 25.0)::int + 1) / 3.0)::int + 15) % 30)
                - (c % 4)
            ) % 7
            - 7 * floor((
                a + 11 * ((19 * a + b - floor(b / 4.0)::int - floor((b - floor((b + 8) / 25.0)::int + 1) / 3.0)::int + 15) % 30)
                + 22 * ((32 + 2 * (b % 4) + 2 * floor(c / 4.0)::int
                - ((19 * a + b - floor(b / 4.0)::int - floor((b - floor((b + 8) / 25.0)::int + 1) / 3.0)::int + 15) % 30)
                - (c % 4)) % 7)
            ) / 451.0)::int
        )::int AS easter_day
    FROM easter_calc
), commercial_events AS (
    SELECT
        d.data_date,
        CASE
            WHEN to_char(d.data_date, 'MM-DD') IN ('01-01','04-21','05-01','09-07','10-12','11-02','11-15','12-25') THEN 1
            WHEN d.data_date IN (e.easter_day - 2, e.easter_day, e.easter_day + 60) THEN 1
            ELSE 0
        END::int AS is_br_holiday,
        CASE
            WHEN d.data_date = (
                SELECT dd::date
                FROM generate_series(make_date(EXTRACT(YEAR FROM d.data_date)::int, 5, 1), make_date(EXTRACT(YEAR FROM d.data_date)::int, 5, 14), interval '1 day') dd
                WHERE EXTRACT(DOW FROM dd) = 0
                ORDER BY dd
                OFFSET 1 LIMIT 1
            ) THEN 1 ELSE 0
        END::int AS is_mothers_day,
        CASE
            WHEN d.data_date = (
                SELECT dd::date
                FROM generate_series(make_date(EXTRACT(YEAR FROM d.data_date)::int, 8, 1), make_date(EXTRACT(YEAR FROM d.data_date)::int, 8, 14), interval '1 day') dd
                WHERE EXTRACT(DOW FROM dd) = 0
                ORDER BY dd
                OFFSET 1 LIMIT 1
            ) THEN 1 ELSE 0
        END::int AS is_fathers_day,
        CASE
            WHEN d.data_date = (
                SELECT dd::date
                FROM generate_series(make_date(EXTRACT(YEAR FROM d.data_date)::int, 11, 23), make_date(EXTRACT(YEAR FROM d.data_date)::int, 11, 30), interval '1 day') dd
                WHERE EXTRACT(DOW FROM dd) = 5
                ORDER BY dd DESC
                LIMIT 1
            ) THEN 1 ELSE 0
        END::int AS is_black_friday,
        CASE WHEN to_char(d.data_date, 'MM-DD') BETWEEN '12-15' AND '12-24' THEN 1 ELSE 0 END::int AS is_christmas_runup
    FROM days d
    LEFT JOIN easter_date e ON e.data_date = d.data_date
)
SELECT
    d.data_date,
    EXTRACT(DOW FROM d.data_date)::int AS day_of_week,
    CASE WHEN EXTRACT(DOW FROM d.data_date)::int IN (0,6) THEN 1 ELSE 0 END::int AS is_weekend,
    EXTRACT(DAY FROM d.data_date)::int AS day_of_month,
    CEIL(EXTRACT(DAY FROM d.data_date)::numeric / 7.0)::int AS week_of_month,
    EXTRACT(MONTH FROM d.data_date)::int AS month_of_year,
    EXTRACT(QUARTER FROM d.data_date)::int AS quarter_of_year,
    CASE WHEN EXTRACT(DAY FROM d.data_date)::int <= 7 THEN 1 ELSE 0 END::int AS is_month_start,
    CASE WHEN EXTRACT(DAY FROM d.data_date)::int BETWEEN 8 AND 20 THEN 1 ELSE 0 END::int AS is_month_middle,
    CASE WHEN d.data_date >= (date_trunc('month', d.data_date)::date + interval '1 month - 7 days')::date THEN 1 ELSE 0 END::int AS is_month_end,
    CASE WHEN EXTRACT(DAY FROM d.data_date)::int BETWEEN 1 AND 7 OR EXTRACT(DAY FROM d.data_date)::int BETWEEN 25 AND 31 THEN 1 ELSE 0 END::int AS is_paycheck_window,
    CASE WHEN EXTRACT(DAY FROM d.data_date)::int BETWEEN 13 AND 17 THEN 1 ELSE 0 END::int AS is_midmonth_window,
    e.is_br_holiday,
    CASE WHEN LEAD(e.is_br_holiday, 1, 0) OVER (ORDER BY d.data_date) = 1 THEN 1 ELSE 0 END::int AS is_holiday_eve,
    CASE WHEN LAG(e.is_br_holiday, 1, 0) OVER (ORDER BY d.data_date) = 1 THEN 1 ELSE 0 END::int AS is_post_holiday,
    e.is_mothers_day,
    e.is_fathers_day,
    e.is_black_friday,
    e.is_christmas_runup,
    CASE WHEN e.is_mothers_day = 1 OR e.is_fathers_day = 1 OR e.is_black_friday = 1 OR e.is_christmas_runup = 1 THEN 1 ELSE 0 END::int AS is_commercial_event
FROM days d
LEFT JOIN commercial_events e ON e.data_date = d.data_date;

COMMENT ON VIEW marketcloud_features.feature_calendar_day_v1 IS
    'Calendário diário para ML: dia da semana, fase do mês, feriados BR e datas comerciais calculadas.';

CREATE OR REPLACE VIEW marketcloud_features.feature_campaign_calendar_context_v1 AS
SELECT
    a.campaign_id,
    a.event_hour,
    AVG(c.day_of_week)::numeric AS avg_day_of_week,
    AVG(c.is_weekend)::numeric AS weekend_share,
    AVG(c.day_of_month)::numeric AS avg_day_of_month,
    AVG(c.week_of_month)::numeric AS avg_week_of_month,
    AVG(c.month_of_year)::numeric AS avg_month_of_year,
    AVG(c.is_month_start)::numeric AS month_start_share,
    AVG(c.is_month_middle)::numeric AS month_middle_share,
    AVG(c.is_month_end)::numeric AS month_end_share,
    AVG(c.is_paycheck_window)::numeric AS paycheck_window_share,
    AVG(c.is_midmonth_window)::numeric AS midmonth_window_share,
    AVG(c.is_br_holiday)::numeric AS holiday_share,
    AVG(c.is_holiday_eve)::numeric AS holiday_eve_share,
    AVG(c.is_post_holiday)::numeric AS post_holiday_share,
    AVG(c.is_commercial_event)::numeric AS commercial_event_share,
    AVG(c.is_mothers_day)::numeric AS mothers_day_share,
    AVG(c.is_fathers_day)::numeric AS fathers_day_share,
    AVG(c.is_black_friday)::numeric AS black_friday_share,
    AVG(c.is_christmas_runup)::numeric AS christmas_runup_share
FROM marketcloud_bronze.bronze_ams_hourly a
JOIN marketcloud_features.feature_calendar_day_v1 c ON c.data_date = a.data_date
WHERE COALESCE(a.campaign_id,'') <> ''
GROUP BY a.campaign_id, a.event_hour;

CREATE OR REPLACE VIEW marketcloud_features.feature_target_calendar_context_v1 AS
SELECT
    a.campaign_id,
    COALESCE(a.ad_group_id,'') AS ad_group_id,
    a.target_entity_key,
    a.event_hour,
    AVG(c.day_of_week)::numeric AS avg_day_of_week,
    AVG(c.is_weekend)::numeric AS weekend_share,
    AVG(c.day_of_month)::numeric AS avg_day_of_month,
    AVG(c.week_of_month)::numeric AS avg_week_of_month,
    AVG(c.month_of_year)::numeric AS avg_month_of_year,
    AVG(c.is_month_start)::numeric AS month_start_share,
    AVG(c.is_month_middle)::numeric AS month_middle_share,
    AVG(c.is_month_end)::numeric AS month_end_share,
    AVG(c.is_paycheck_window)::numeric AS paycheck_window_share,
    AVG(c.is_midmonth_window)::numeric AS midmonth_window_share,
    AVG(c.is_br_holiday)::numeric AS holiday_share,
    AVG(c.is_holiday_eve)::numeric AS holiday_eve_share,
    AVG(c.is_post_holiday)::numeric AS post_holiday_share,
    AVG(c.is_commercial_event)::numeric AS commercial_event_share,
    AVG(c.is_mothers_day)::numeric AS mothers_day_share,
    AVG(c.is_fathers_day)::numeric AS fathers_day_share,
    AVG(c.is_black_friday)::numeric AS black_friday_share,
    AVG(c.is_christmas_runup)::numeric AS christmas_runup_share
FROM marketcloud_bronze.bronze_ams_hourly_target a
JOIN marketcloud_features.feature_calendar_day_v1 c ON c.data_date = a.data_date
WHERE NULLIF(TRIM(COALESCE(a.target_entity_key,'')), '') IS NOT NULL
GROUP BY a.campaign_id, COALESCE(a.ad_group_id,''), a.target_entity_key, a.event_hour;

CREATE OR REPLACE VIEW marketcloud_features.feature_campaign_commercial_context_v1 AS
WITH pilot AS (
    SELECT DISTINCT ON (campaign_id)
        campaign_id,
        product_asin,
        seller_sku,
        sale_price_brl,
        unit_cost_brl,
        stock_available,
        gross_margin_brl,
        gross_margin_pct,
        max_daily_budget_brl,
        max_spend_without_order_brl,
        min_roas
    FROM marketcloud_gold.full_control_effective_governance_v1
    WHERE COALESCE(campaign_id,'') <> ''
    ORDER BY campaign_id, CASE status WHEN 'active' THEN 0 WHEN 'draft' THEN 1 ELSE 2 END, updated_at DESC
), candidate AS (
    SELECT DISTINCT ON (product_asin, seller_sku)
        product_asin,
        seller_sku,
        sale_price_brl,
        unit_cost_brl,
        stock_available,
        gross_margin_brl,
        gross_margin_pct,
        orders_30d,
        sales_30d,
        roas_30d
    FROM marketcloud_gold.full_control_product_candidates_v1
    ORDER BY product_asin, seller_sku, last_seen_date DESC NULLS LAST
)
SELECT
    p.campaign_id,
    p.product_asin,
    p.seller_sku,
    COALESCE(p.sale_price_brl, c.sale_price_brl, 0)::numeric AS sale_price_brl,
    COALESCE(p.unit_cost_brl, c.unit_cost_brl, 0)::numeric AS unit_cost_brl,
    COALESCE(p.stock_available, c.stock_available, 0)::numeric AS stock_available,
    COALESCE(p.gross_margin_brl, c.gross_margin_brl, 0)::numeric AS gross_margin_brl,
    COALESCE(p.gross_margin_pct, c.gross_margin_pct, 0)::numeric AS gross_margin_pct,
    CASE WHEN COALESCE(p.unit_cost_brl, c.unit_cost_brl, 0) > 0 THEN COALESCE(p.sale_price_brl, c.sale_price_brl, 0) / NULLIF(COALESCE(p.unit_cost_brl, c.unit_cost_brl, 0),0) ELSE 0 END::numeric AS price_to_cost_ratio,
    CASE WHEN COALESCE(c.orders_30d,0) > 0 THEN COALESCE(p.stock_available, c.stock_available, 0) / NULLIF(c.orders_30d / 30.0,0) ELSE 0 END::numeric AS stock_days_of_cover,
    COALESCE(c.orders_30d,0)::numeric AS product_orders_30d,
    COALESCE(c.sales_30d,0)::numeric AS product_sales_30d,
    COALESCE(c.roas_30d,0)::numeric AS product_roas_30d,
    COALESCE(p.max_daily_budget_brl,0)::numeric AS max_daily_budget_brl,
    COALESCE(p.max_spend_without_order_brl,0)::numeric AS max_spend_without_order_brl,
    COALESCE(p.min_roas,0)::numeric AS min_roas,
    0::int AS has_competitor_price,
    0::numeric AS competitor_price_min_brl,
    0::numeric AS competitor_price_gap_pct,
    0::int AS is_price_above_competitor,
    0::int AS has_bsr,
    0::numeric AS bsr_rank,
    0::numeric AS bsr_delta_7d
FROM pilot p
LEFT JOIN candidate c
  ON c.product_asin = p.product_asin
 AND (COALESCE(c.seller_sku,'') = COALESCE(p.seller_sku,'') OR COALESCE(c.seller_sku,'') = '' OR COALESCE(p.seller_sku,'') = '');

COMMENT ON VIEW marketcloud_features.feature_campaign_commercial_context_v1 IS
    'Contexto comercial real por campanha: preço/custo/estoque/margem Zanom. Campos concorrente/BSR ficam zerados porque não há fonte local validada ainda.';
