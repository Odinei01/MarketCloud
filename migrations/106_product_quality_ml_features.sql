-- =====================================================================
-- Product quality features for Full Control ML
--
-- Exposes review/rating/return/refund quality signals from the operational
-- app so campaign-hour models can learn product-page risk, not only media
-- performance.
-- =====================================================================

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_product_quality_snapshot (
    id bigint,
    snapshot_date date,
    sku text,
    asin text,
    product_name text,
    orders_count integer,
    units_sold integer,
    gross_sales numeric,
    discount_total numeric,
    refund_total numeric,
    return_quantity integer,
    reimbursement_total numeric,
    amazon_fee_total numeric,
    fba_fee_total numeric,
    ads_cost numeric,
    cmv numeric,
    net_profit_after_quality numeric,
    net_margin_after_quality numeric,
    rating numeric,
    reviews_total integer,
    main_negative_topic text,
    main_return_reason text,
    review_source text,
    quality_status text,
    source_status text,
    created_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_product_quality_snapshot');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_product_quality_reviews (
    id bigint,
    asin text,
    sku text,
    product_name text,
    rating numeric,
    ratings_total integer,
    review_count integer,
    positive_topics_json jsonb,
    negative_topics_json jsonb,
    main_negative_topic text,
    source text,
    source_confidence numeric,
    captured_at timestamptz,
    created_at timestamptz
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_product_quality_reviews');

CREATE FOREIGN TABLE IF NOT EXISTS swarm_src.amazon_product_returns (
    id bigint,
    amazon_order_id text,
    sku text,
    asin text,
    fnsku text,
    product_name text,
    return_date timestamptz,
    return_quantity integer,
    return_reason text,
    return_status text,
    detailed_disposition text,
    customer_comments text,
    refund_amount numeric,
    label_cost numeric,
    source text,
    created_at timestamptz,
    stock_movement_status text,
    classification text,
    zanom_product_id text,
    zanom_sku text
) SERVER swarm_pg OPTIONS (schema_name 'public', table_name 'amazon_product_returns');

CREATE OR REPLACE VIEW marketcloud_features.feature_product_quality_v1 AS
WITH snapshot AS (
    SELECT
        COALESCE(NULLIF(asin,''), 'NO_ASIN') AS product_asin,
        NULLIF(sku,'') AS seller_sku,
        MAX(product_name) AS product_title,
        MAX(snapshot_date) AS latest_snapshot_date,
        SUM(COALESCE(orders_count,0))::numeric AS quality_orders_30d,
        SUM(COALESCE(units_sold,0))::numeric AS quality_units_sold_30d,
        SUM(COALESCE(refund_total,0))::numeric AS refund_total_30d,
        SUM(COALESCE(return_quantity,0))::numeric AS return_quantity_30d,
        SUM(COALESCE(net_profit_after_quality,0))::numeric AS net_profit_after_quality_30d,
        CASE WHEN SUM(COALESCE(gross_sales,0)) > 0
             THEN SUM(COALESCE(net_profit_after_quality,0)) / NULLIF(SUM(COALESCE(gross_sales,0)),0)
             ELSE 0 END AS net_margin_after_quality_ratio_30d,
        MAX(COALESCE(rating,0))::numeric AS latest_rating,
        MAX(COALESCE(reviews_total,0))::numeric AS latest_reviews_total,
        MAX(main_negative_topic) FILTER (WHERE COALESCE(main_negative_topic,'') <> '') AS main_negative_topic,
        MAX(main_return_reason) FILTER (WHERE COALESCE(main_return_reason,'') <> '') AS main_return_reason,
        MAX(review_source) AS review_source,
        MAX(quality_status) AS quality_status,
        MAX(source_status) AS source_status
    FROM swarm_src.amazon_product_quality_snapshot
    WHERE snapshot_date >= CURRENT_DATE - INTERVAL '30 days'
      AND COALESCE(NULLIF(asin,''), NULLIF(sku,'')) IS NOT NULL
    GROUP BY COALESCE(NULLIF(asin,''), 'NO_ASIN'), NULLIF(sku,'')
), latest_review AS (
    SELECT DISTINCT ON (COALESCE(NULLIF(asin,''), 'NO_ASIN'), NULLIF(sku,''))
        COALESCE(NULLIF(asin,''), 'NO_ASIN') AS product_asin,
        NULLIF(sku,'') AS seller_sku,
        COALESCE(rating,0)::numeric AS review_rating_latest,
        COALESCE(review_count, ratings_total, 0)::numeric AS review_count_latest,
        COALESCE(source_confidence,0)::numeric AS review_source_confidence,
        captured_at AS review_captured_at
    FROM swarm_src.amazon_product_quality_reviews
    WHERE COALESCE(NULLIF(asin,''), NULLIF(sku,'')) IS NOT NULL
    ORDER BY COALESCE(NULLIF(asin,''), 'NO_ASIN'), NULLIF(sku,''), captured_at DESC NULLS LAST
), returns AS (
    SELECT
        COALESCE(NULLIF(asin,''), 'NO_ASIN') AS product_asin,
        NULLIF(sku,'') AS seller_sku,
        COUNT(*)::numeric AS return_events_30d,
        SUM(COALESCE(return_quantity,0))::numeric AS return_units_30d,
        SUM(COALESCE(refund_amount,0))::numeric AS return_refund_amount_30d
    FROM swarm_src.amazon_product_returns
    WHERE return_date::date >= CURRENT_DATE - INTERVAL '30 days'
      AND COALESCE(NULLIF(asin,''), NULLIF(sku,'')) IS NOT NULL
    GROUP BY COALESCE(NULLIF(asin,''), 'NO_ASIN'), NULLIF(sku,'')
)
SELECT
    s.product_asin,
    s.seller_sku,
    s.product_title,
    s.latest_snapshot_date,
    s.quality_orders_30d,
    s.quality_units_sold_30d,
    s.refund_total_30d,
    s.return_quantity_30d,
    COALESCE(r.return_events_30d,0) AS return_events_30d,
    COALESCE(r.return_units_30d,0) AS return_units_30d,
    COALESCE(r.return_refund_amount_30d,0) AS return_refund_amount_30d,
    CASE WHEN COALESCE(s.quality_units_sold_30d,0) > 0
         THEN COALESCE(s.return_quantity_30d,0) / NULLIF(s.quality_units_sold_30d,0)
         ELSE 0 END AS return_rate_30d,
    s.net_profit_after_quality_30d,
    s.net_margin_after_quality_ratio_30d,
    COALESCE(NULLIF(lr.review_rating_latest,0), s.latest_rating, 0) AS rating_latest,
    COALESCE(NULLIF(lr.review_count_latest,0), s.latest_reviews_total, 0) AS reviews_total_latest,
    COALESCE(lr.review_source_confidence,0) AS review_source_confidence,
    s.main_negative_topic,
    s.main_return_reason,
    s.review_source,
    s.quality_status,
    s.source_status,
    CASE
      WHEN COALESCE(NULLIF(lr.review_rating_latest,0), s.latest_rating, 0) > 0
       AND COALESCE(NULLIF(lr.review_rating_latest,0), s.latest_rating, 0) < 3.8 THEN 1
      ELSE 0
    END AS low_rating_flag,
    CASE WHEN COALESCE(s.quality_units_sold_30d,0) > 0
       AND COALESCE(s.return_quantity_30d,0) / NULLIF(s.quality_units_sold_30d,0) >= 0.08 THEN 1
      ELSE 0
    END AS high_return_flag,
    CASE WHEN COALESCE(s.refund_total_30d,0) > 0 THEN 1 ELSE 0 END AS refund_flag
FROM snapshot s
LEFT JOIN latest_review lr
  ON lr.product_asin = s.product_asin
 AND COALESCE(lr.seller_sku,'') = COALESCE(s.seller_sku,'')
LEFT JOIN returns r
  ON r.product_asin = s.product_asin
 AND COALESCE(r.seller_sku,'') = COALESCE(s.seller_sku,'');

COMMENT ON VIEW marketcloud_features.feature_product_quality_v1 IS
'Product review/rating/return/refund features from SWARM, used by Full Control campaign-hour ML as non-leaking product-page quality context.';
