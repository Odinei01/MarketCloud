-- 161_calibration_rich_rebuild.sql
-- CALIBRACAO CORRIGIDA na fonte RICA. Substitui a logica que lia do stream esparso.
-- Grao: campanha x hora (backbone solido, 3257 cliques desde 31/05). Keyword herda a
-- campanha (so ~3 keywords tem sinal horario proprio). Fallback: hora fina da campanha
-- cai na curva GLOBAL; global fina cai em 1.00 (neutro). Somente leitura — gera a
-- PROPOSTA; o write nos schedules e passo separado, so apos decisao do dono.
--
-- Multiplicador deterministico por ROAS vs meta 3.0 (buckets 0.30/0.50/0.80/1.00):
--   >=15 cliques na hora da campanha DECIDE; senao herda global; senao 1.00.

DROP VIEW IF EXISTS marketcloud_gold.v_daypart_calibration_campaign_rich;

CREATE VIEW marketcloud_gold.v_daypart_calibration_campaign_rich AS
WITH gl AS (
  SELECT event_hour, suggested_global_mult FROM marketcloud_gold.v_daypart_curve_global_rich
),
c AS (
  SELECT campaign_name, event_hour, clicks, roas
  FROM marketcloud_gold.v_daypart_curve_campaign_rich
),
scored AS (
  SELECT c.campaign_name, c.event_hour, c.clicks, c.roas, gl.suggested_global_mult,
    CASE
      WHEN c.clicks >= 15 AND c.roas >= 3 THEN 100
      WHEN c.clicks >= 15 AND c.roas >= 2 THEN 80
      WHEN c.clicks >= 15 AND c.roas >= 1 THEN 50
      WHEN c.clicks >= 15                  THEN 30
      ELSE NULL   -- hora fina da campanha: cai no fallback
    END AS own_mult
  FROM c LEFT JOIN gl USING (event_hour)
)
-- new_mult so onde HA SINAL (campanha >=15cl OU global >=15cl). Sem sinal = NULL
-- = "nao mexer, mantem o atual". Nunca aposta bid em hora sem dado.
SELECT campaign_name, event_hour, clicks, roas,
  (COALESCE(own_mult, suggested_global_mult) / 100.0)::numeric(8,4) AS new_mult,
  CASE
    WHEN own_mult IS NOT NULL THEN 'campanha ('||clicks||' cl, ROAS '||roas||')'
    WHEN suggested_global_mult IS NOT NULL THEN 'fallback global'
    ELSE 'sem sinal — manter atual'
  END AS fonte
FROM scored;
