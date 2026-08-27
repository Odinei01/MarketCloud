-- 219: o ML passa a alimentar a calibração de campanha × hora.
--
-- SITUAÇÃO ANTERIOR: a ponte dayparting→bid-robot já estava ligada para 14 das 18
-- campanhas, mas o que ela empurrava era quase sempre cego. Das 1.151 linhas de
-- v_daypart_calibration_campaign_rich, 1.098 (95%) vinham de "fallback global" — o
-- mesmo 0,80 para toda campanha naquela hora — e apenas 5 tinham sinal próprio
-- (exige 15 cliques na campanha×hora, o que quase nenhuma atinge).
--
-- Enquanto isso o ML tinha opinião por campanha × hora parada em
-- gold_hourly_ml_target_multiplier (479 linhas, 22 campanhas, 24 horas) e NADA a lia.
-- Modelo treinado, previsão gerada, decisão tomada por um número fixo.
--
-- ORDEM DE PRECEDÊNCIA — medido vence previsto, previsto vence cego:
--
--   1. sinal próprio da campanha (>=15 cliques): venda medida naquela hora
--   2. ML (novo): previsão do modelo para aquela campanha × hora
--   3. fallback global: a curva média da conta
--   4. sem sinal: mantém o multiplicador atual
--
-- O ML NÃO sobrepõe o nível 1 de propósito. É a mesma regra que aplicamos na
-- negativação hoje: quando existe venda medida, ela decide; previsão entra onde não
-- há medição, não por cima dela.
--
-- CLAMP: o multiplicador do ML é limitado a [0,30 .. 1,20]. O piso evita que uma
-- previsão pessimista zere a campanha numa hora — apagar presença é caro e demora a
-- voltar. O teto evita que o modelo suba lance além do que a agenda foi desenhada
-- para permitir. Previsão erra; a trava define quanto pode custar o erro.

CREATE OR REPLACE VIEW marketcloud_gold.v_daypart_calibration_campaign_rich AS
WITH gl AS (
  SELECT event_hour, suggested_global_mult
  FROM marketcloud_gold.v_daypart_curve_global_rich
), c AS (
  SELECT campaign_name, event_hour, clicks, roas
  FROM marketcloud_gold.v_daypart_curve_campaign_rich
), ml AS (
  -- previsão do modelo por campanha × hora, já limitada
  SELECT campaign_name, event_hour,
         LEAST(1.20, GREATEST(0.30, ml_multiplier))::numeric AS ml_mult,
         roas_observado, gasto_observado
  FROM marketcloud_gold.gold_hourly_ml_target_multiplier
  WHERE ml_multiplier IS NOT NULL
), scored AS (
  SELECT c.campaign_name, c.event_hour, c.clicks, c.roas,
         gl.suggested_global_mult,
         ml.ml_mult, ml.roas_observado AS ml_roas, ml.gasto_observado AS ml_gasto,
         CASE
           WHEN c.clicks >= 15 AND c.roas >= 3::numeric THEN 100
           WHEN c.clicks >= 15 AND c.roas >= 2::numeric THEN 80
           WHEN c.clicks >= 15 AND c.roas >= 1::numeric THEN 50
           WHEN c.clicks >= 15 THEN 30
           ELSE NULL::integer
         END AS own_mult
  FROM c
  LEFT JOIN gl USING (event_hour)
  LEFT JOIN ml ON ml.campaign_name = c.campaign_name AND ml.event_hour = c.event_hour
)
SELECT campaign_name, event_hour, clicks, roas,
  CASE
    WHEN own_mult IS NOT NULL THEN (own_mult::numeric / 100.0)
    WHEN ml_mult  IS NOT NULL THEN ml_mult
    WHEN suggested_global_mult IS NOT NULL THEN (suggested_global_mult::numeric / 100.0)
  END::numeric(8,4) AS new_mult,
  CASE
    WHEN own_mult IS NOT NULL
      THEN 'campanha (' || clicks || ' cl, ROAS ' || roas || ')'
    -- a fonte declara o gasto observado: quem ler a agenda sabe se o ML opinou
    -- sobre uma hora com movimento ou sobre uma hora vazia
    WHEN ml_mult IS NOT NULL
      THEN 'ML (gasto ' || COALESCE(ROUND(ml_gasto::numeric,2),0) || ', ROAS ' || COALESCE(ROUND(ml_roas::numeric,2),0) || ')'
    WHEN suggested_global_mult IS NOT NULL THEN 'fallback global'
    ELSE 'sem sinal — manter atual'
  END AS fonte
FROM scored;
