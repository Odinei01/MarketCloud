-- =====================================================================
-- E013 — Conversions Daily Total (coarse, fonte da verdade financeira)
--
-- Motivo: extratos finos (E001 por campanha, E004 por hora×adgroup) perdem
-- conversão para o threshold de agregação/privacidade do AMC — o AMC anula
-- as dimensões de grupos pequenos. Validado em 07/07: AMC total = 221 orders,
-- mas só 150 têm campanha atribuída; 71 ficam com dimensão anulada.
--
-- E013 agrupa SÓ por conversion_event_date (+ moeda) — grupos grandes que o
-- AMC não suprime — capturando o total financeiro completo (221) que bate
-- com o console. NÃO filtra campaign_id (senão perderia os suprimidos).
--
-- Grão: data_date / purchase_currency
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_bronze.bronze_amc_conversions_daily_total (
    tenant_id       TEXT NOT NULL,
    amc_instance_id TEXT NOT NULL,
    ads_profile_id  TEXT NOT NULL,
    workflow_run_id BIGINT,

    data_date         DATE NOT NULL,
    purchase_currency TEXT NOT NULL DEFAULT 'UNKNOWN',

    conversion_rows     BIGINT        DEFAULT 0,
    orders              NUMERIC(18,4) DEFAULT 0,
    sales               NUMERIC(18,4) DEFAULT 0,
    units_sold          NUMERIC(18,4) DEFAULT 0,
    add_to_cart         NUMERIC(18,4) DEFAULT 0,
    detail_page_views   NUMERIC(18,4) DEFAULT 0,
    brand_halo_orders   NUMERIC(18,4) DEFAULT 0,
    brand_halo_sales    NUMERIC(18,4) DEFAULT 0,
    new_to_brand_orders NUMERIC(18,4) DEFAULT 0,
    new_to_brand_sales  NUMERIC(18,4) DEFAULT 0,
    off_amazon_sales    NUMERIC(18,4) DEFAULT 0,
    combined_sales      NUMERIC(18,4) DEFAULT 0,

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_bronze_amc_conversions_daily_total
        PRIMARY KEY (tenant_id, amc_instance_id, ads_profile_id, data_date, purchase_currency)
);

CREATE INDEX IF NOT EXISTS idx_bronze_conv_daily_total_date
    ON marketcloud_bronze.bronze_amc_conversions_daily_total (tenant_id, data_date);


-- =====================================================================
-- Template E013
-- =====================================================================
INSERT INTO query_templates (
    id, tenant_id, name, code, description, query_family, query_goal,
    sql_template, parameters_schema, min_lookback_days, max_lookback_days,
    supported_campaign_types, supported_marketplaces, version, status
) VALUES (
    gen_random_uuid(),
    'd7ec8c23-3f86-4cd1-b4cb-2a753a74c5f9',
    'Conversions Daily Total',
    'MC_ZANOM_E013',
    'Total diário de conversões (grão só por dia) — fonte da verdade financeira. Não sofre supressão do AMC; bate com o total do console. Marker E013_CONVERSIONS_DAILY_TOTAL_V1.',
    'MARGIN_ANALYSIS',
    'FINANCE_RECONCILIATION',
    $SQL$
WITH conv_raw AS (
    SELECT
        conversion_event_date AS data_date,
        purchase_currency,
        COUNT(1) AS conversion_rows,
        SUM(total_purchases) AS orders,
        SUM(total_product_sales) AS sales,
        SUM(total_units_sold) AS units_sold,
        SUM(total_add_to_cart) AS add_to_cart,
        SUM(total_detail_page_view) AS detail_page_views,
        SUM(brand_halo_purchases) AS brand_halo_orders,
        SUM(brand_halo_product_sales) AS brand_halo_sales,
        SUM(new_to_brand_purchases) AS new_to_brand_orders,
        SUM(new_to_brand_product_sales) AS new_to_brand_sales,
        SUM(off_amazon_product_sales) AS off_amazon_sales,
        SUM(combined_sales) AS combined_sales
    FROM amazon_attributed_events_by_conversion_time
    WHERE conversion_event_date IS NOT NULL
    GROUP BY
        conversion_event_date,
        purchase_currency
)
SELECT
    data_date,
    COALESCE(NULLIF(TRIM(CAST(purchase_currency AS VARCHAR)), ''), 'UNKNOWN') AS purchase_currency,
    conversion_rows,
    orders,
    sales,
    units_sold,
    add_to_cart,
    detail_page_views,
    brand_halo_orders,
    brand_halo_sales,
    new_to_brand_orders,
    new_to_brand_sales,
    off_amazon_sales,
    combined_sales
FROM conv_raw
WHERE data_date IS NOT NULL
$SQL$,
    '{"period_start":{"type":"string"},"period_end":{"type":"string"}}',
    1, 90,
    '{}', '{"AMAZON_BR"}',
    1, 'ACTIVE'
) ON CONFLICT (code, version) DO UPDATE SET
    sql_template = EXCLUDED.sql_template,
    description = EXCLUDED.description,
    updated_at = NOW();
