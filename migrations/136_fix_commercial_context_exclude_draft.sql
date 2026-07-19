-- 136 - Fix feature_campaign_commercial_context_v1: nao deixar pilot 'draft'
-- (ASIN nao confirmado / "nao enviado") alimentar a economia por campanha.
--
-- Bug (auditoria 2026-07-19): a CTE pilot ordenava
--   CASE status WHEN 'active' THEN 0 WHEN 'draft' THEN 1 ELSE 2 END
-- ou seja, 'draft' (1) vencia 'completed' (ELSE=2). Campanhas com uma linha
-- completed real + uma draft placeholder pegavam a DRAFT (ex.: Abridor de Vinho
-- pegou B0H887XGCJ draft em vez do B0H2TXK1YG completed).
--
-- Correcao: (1) excluir status='draft' do calculo (nao confirmado nao vira
-- economia); (2) ordenar active > completed > paused > resto, draft removido.
-- O executor Full Control ja e gated por status='active' AND mode='full_control',
-- entao esta mudanca so limpa features do ML / modal, sem afetar o dinheiro.

CREATE OR REPLACE VIEW marketcloud_features.feature_campaign_commercial_context_v1 AS
WITH pilot AS (
    SELECT DISTINCT ON (feg.campaign_id)
        feg.campaign_id,
        feg.product_asin,
        feg.seller_sku,
        feg.sale_price_brl,
        feg.unit_cost_brl,
        feg.stock_available,
        feg.gross_margin_brl,
        feg.gross_margin_pct,
        feg.max_daily_budget_brl,
        feg.max_spend_without_order_brl,
        feg.min_roas
    FROM marketcloud_gold.full_control_effective_governance_v1 feg
    WHERE COALESCE(feg.campaign_id, ''::text) <> ''::text
      AND COALESCE(feg.status, ''::text) <> 'draft'::text
    ORDER BY feg.campaign_id,
        (CASE feg.status
            WHEN 'active'::text THEN 0
            WHEN 'completed'::text THEN 1
            WHEN 'paused'::text THEN 2
            ELSE 3
        END),
        feg.updated_at DESC
), candidate AS (
    SELECT DISTINCT ON (fpc.product_asin, fpc.seller_sku)
        fpc.product_asin,
        fpc.seller_sku,
        fpc.sale_price_brl,
        fpc.unit_cost_brl,
        fpc.stock_available,
        fpc.gross_margin_brl,
        fpc.gross_margin_pct,
        fpc.orders_30d,
        fpc.sales_30d,
        fpc.roas_30d
    FROM marketcloud_gold.full_control_product_candidates_v1 fpc
    ORDER BY fpc.product_asin, fpc.seller_sku, fpc.last_seen_date DESC NULLS LAST
)
SELECT p.campaign_id,
    p.product_asin,
    p.seller_sku,
    COALESCE(p.sale_price_brl, c.sale_price_brl, 0::numeric) AS sale_price_brl,
    COALESCE(p.unit_cost_brl, c.unit_cost_brl, 0::numeric) AS unit_cost_brl,
    COALESCE(p.stock_available, c.stock_available, 0::numeric) AS stock_available,
    COALESCE(p.gross_margin_brl, c.gross_margin_brl, 0::numeric) AS gross_margin_brl,
    COALESCE(p.gross_margin_pct, c.gross_margin_pct, 0::numeric) AS gross_margin_pct,
    CASE
        WHEN COALESCE(p.unit_cost_brl, c.unit_cost_brl, 0::numeric) > 0::numeric
            THEN COALESCE(p.sale_price_brl, c.sale_price_brl, 0::numeric) / NULLIF(COALESCE(p.unit_cost_brl, c.unit_cost_brl, 0::numeric), 0::numeric)
        ELSE 0::numeric
    END AS price_to_cost_ratio,
    CASE
        WHEN COALESCE(c.orders_30d, 0::numeric) > 0::numeric
            THEN COALESCE(p.stock_available, c.stock_available, 0::numeric) / NULLIF(c.orders_30d / 30.0, 0::numeric)
        ELSE 0::numeric
    END AS stock_days_of_cover,
    COALESCE(c.orders_30d, 0::numeric) AS product_orders_30d,
    COALESCE(c.sales_30d, 0::numeric) AS product_sales_30d,
    COALESCE(c.roas_30d, 0::numeric) AS product_roas_30d,
    COALESCE(p.max_daily_budget_brl, 0::numeric) AS max_daily_budget_brl,
    COALESCE(p.max_spend_without_order_brl, 0::numeric) AS max_spend_without_order_brl,
    COALESCE(p.min_roas, 0::numeric) AS min_roas,
    0 AS has_competitor_price,
    0::numeric AS competitor_price_min_brl,
    0::numeric AS competitor_price_gap_pct,
    0 AS is_price_above_competitor,
    0 AS has_bsr,
    0::numeric AS bsr_rank,
    0::numeric AS bsr_delta_7d
FROM pilot p
    LEFT JOIN candidate c ON c.product_asin = p.product_asin
        AND (COALESCE(c.seller_sku, ''::text) = COALESCE(p.seller_sku, ''::text)
             OR COALESCE(c.seller_sku, ''::text) = ''::text
             OR COALESCE(p.seller_sku, ''::text) = ''::text);
