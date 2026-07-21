-- 154_dayparting_windows_grouping.sql
-- FIX: o apply escrevia 24 regras de 1 hora (quebrava a estrutura de JANELAS do
-- dono). Agora agrupa horas consecutivas com o mesmo multiplicador numa janela
-- (gaps-and-islands). Valores identicos; so a estrutura volta a ser janela.
-- regroup_dayparting_windows(): conserta o estado JA aplicado (nao mexe no backup
-- pre_rules do audit, entao o revert-ao-original continua valendo).

-- (1) massive com AGRUPAMENTO (para runs futuros)
CREATE OR REPLACE FUNCTION marketcloud_gold.apply_dayparting_massive() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE r record; n int := 0; pre jsonb;
BEGIN
  FOR r IN
    SELECT DISTINCT c.keyword_id, c.keyword_text, p.id AS profile_id
    FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1 c
    JOIN swarm_src.zanom_ads_bid_schedule_profiles p
      ON p.status='PUBLISHED' AND p.scope='ENTITY'
     AND (p.entity_id=c.keyword_id OR (COALESCE(p.entity_label,'')<>'' AND lower(trim(p.entity_label))=lower(trim(c.keyword_text))))
    WHERE EXISTS (SELECT 1 FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1 x
                  WHERE x.keyword_id=c.keyword_id AND x.gate='OK' AND x.action<>'HOLD')
  LOOP
    SELECT COALESCE(jsonb_agg(jsonb_build_object('hour_start',hour_start,'hour_end',hour_end,
             'multiplier',multiplier,'day_of_week',day_of_week) ORDER BY hour_start),'[]'::jsonb)
      INTO pre FROM swarm_src.zanom_ads_bid_schedule_rules WHERE profile_id_ref=r.profile_id;
    INSERT INTO marketcloud_gold.dayparting_apply_audit
      (keyword_id,keyword_text,profile_id,dry_run,applied,hours_changed,plan_json,pre_rules_json,actor,result)
      VALUES (r.keyword_id,r.keyword_text,r.profile_id,false,true,
        (SELECT count(*) FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1
           WHERE keyword_id=r.keyword_id AND gate='OK' AND action<>'HOLD'),
        '[]'::jsonb, pre, 'MASSIVE', 'APPLIED');
    DELETE FROM swarm_src.zanom_ads_bid_schedule_rules WHERE profile_id_ref=r.profile_id;
    -- AGRUPA horas consecutivas de mesmo multiplicador em janelas
    INSERT INTO swarm_src.zanom_ads_bid_schedule_rules (id,profile_id_ref,hour_start,hour_end,multiplier,created_at,updated_at)
    SELECT gen_random_uuid()::text, r.profile_id, hs, he, mult, now(), now()
    FROM (
      WITH c AS (SELECT event_hour hr, recommended_multiplier mult
                 FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1 WHERE keyword_id=r.keyword_id),
      isl AS (SELECT hr, mult, hr - row_number() OVER (PARTITION BY mult ORDER BY hr) AS g FROM c)
      SELECT mult, min(hr) hs, max(hr)+1 he FROM isl GROUP BY mult, g
    ) w;
    UPDATE swarm_src.zanom_ads_bid_schedule_profiles
      SET status='PUBLISHED', is_active=true, version=COALESCE(version,0)+1, published_at=now(), updated_at=now()
      WHERE id=r.profile_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;$$;

-- (2) regroup do estado JA aplicado (estrutura -> janela; valores intactos; backup intacto)
CREATE OR REPLACE FUNCTION marketcloud_gold.regroup_dayparting_windows() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT DISTINCT profile_id FROM marketcloud_gold.dayparting_apply_audit
           WHERE actor='MASSIVE' AND applied AND profile_id IS NOT NULL
  LOOP
    -- so agrupa se estiver "quebrado" (mais de ~15 regras = provavelmente 1-por-hora)
    IF (SELECT count(*) FROM swarm_src.zanom_ads_bid_schedule_rules WHERE profile_id_ref=r.profile_id) < 15 THEN
      CONTINUE;
    END IF;
    CREATE TEMP TABLE _w ON COMMIT DROP AS
      WITH c AS (SELECT hour_start hr, multiplier mult FROM swarm_src.zanom_ads_bid_schedule_rules WHERE profile_id_ref=r.profile_id),
      isl AS (SELECT hr, mult, hr - row_number() OVER (PARTITION BY mult ORDER BY hr) AS g FROM c)
      SELECT mult, min(hr) hs, max(hr)+1 he FROM isl GROUP BY mult, g;
    DELETE FROM swarm_src.zanom_ads_bid_schedule_rules WHERE profile_id_ref=r.profile_id;
    INSERT INTO swarm_src.zanom_ads_bid_schedule_rules (id,profile_id_ref,hour_start,hour_end,multiplier,created_at,updated_at)
    SELECT gen_random_uuid()::text, r.profile_id, hs, he, mult, now(), now() FROM _w;
    DROP TABLE _w;
    UPDATE swarm_src.zanom_ads_bid_schedule_profiles SET version=COALESCE(version,0)+1, updated_at=now() WHERE id=r.profile_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;$$;
