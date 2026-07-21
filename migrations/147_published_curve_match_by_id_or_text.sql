-- 147_published_curve_match_by_id_or_text.sql
-- FIX: 6 keywords tinham curva PUBLICADA que so casava por TEXTO (entity_label),
-- nao por entity_id (o entity_id do profile != keyword_id do dado). Caiam no
-- hardcoded (fonte errada). A view agora chaveia pelo keyword_id REAL do dado,
-- casando o profile por entity_id OU entity_label=keyword_text. Assim todas as
-- keywords com schedule publicado usam a curva certa; a funcao de calibracao nao
-- muda (ja le esta view por keyword_id).

CREATE OR REPLACE VIEW marketcloud_gold.v_published_keyword_hour_mult_v1 AS
WITH kw AS (
    SELECT DISTINCT keyword_id, lower(trim(keyword_text)) AS txt
    FROM marketcloud_bronze.bronze_ams_hourly_target
    WHERE keyword_id IS NOT NULL
),
prof AS (
    SELECT id, entity_id, lower(trim(entity_label)) AS lbl
    FROM swarm_src.zanom_ads_bid_schedule_profiles
    WHERE status = 'PUBLISHED' AND scope = 'ENTITY'
)
SELECT kw.keyword_id,
       gs.h::smallint AS event_hour,
       round(avg(r.multiplier), 2) AS multiplier
FROM kw
JOIN prof ON (prof.entity_id = kw.keyword_id OR (prof.lbl <> '' AND prof.lbl = kw.txt))
JOIN swarm_src.zanom_ads_bid_schedule_rules r ON r.profile_id_ref = prof.id
CROSS JOIN generate_series(0, 23) gs(h)
WHERE gs.h >= r.hour_start AND gs.h < r.hour_end
GROUP BY 1, 2;
