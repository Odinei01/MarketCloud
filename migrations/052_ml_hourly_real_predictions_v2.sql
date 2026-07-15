-- =====================================================================
-- Predições do ML V2 sobre o DADO REAL (relatório horário sem supressão).
--
-- Diferente do V1 (que aprendia sobre feature_hourly_windows_v1, alimentado
-- pelo AMC suprimido e por isso recusava treinar — classe minoritária < 10),
-- o V2 treina no bronze_amazon_ads_hourly: 90 células com pedido / 586 totais.
-- Alvo REAL: converte? (has_order) e ROAS esperado, por campanha×hora.
--
-- ADVISOR-ONLY. As predições enriquecem o cockpit horário; nada executa.
-- =====================================================================

CREATE TABLE IF NOT EXISTS marketcloud_gold.hourly_ml_predictions_v2 (
    campaign_name          TEXT    NOT NULL,
    event_hour             INTEGER NOT NULL,
    conversion_probability NUMERIC(6,4),   -- P(pedido) prevista
    expected_roas          NUMERIC(10,4),  -- ROAS esperado (capado)
    predicted_good_hour    BOOLEAN,        -- prob >= limiar E roas esperado >= alvo
    model_version          TEXT    NOT NULL DEFAULT 'v2',
    computed_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_hourly_ml_pred_v2 PRIMARY KEY (campaign_name, event_hour)
);
