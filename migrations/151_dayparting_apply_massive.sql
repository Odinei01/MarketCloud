-- 151_dayparting_apply_massive.sql
-- Apply MASSIVO da calibracao nos schedules ENTITY publicados (todas as keywords
-- parametrizadas), com guardrails: so celulas gate=OK mudam (HOLD escreve o publicado
-- = sem mudanca), passo ja travado em 1 bucket, backup do estado anterior em cada
-- profile (audit.pre_rules_json), e funcao de REVERT que desfaz tudo.
-- Roda numa transacao (all-or-nothing).

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
    INSERT INTO swarm_src.zanom_ads_bid_schedule_rules (id,profile_id_ref,hour_start,hour_end,multiplier,created_at,updated_at)
      SELECT gen_random_uuid()::text, r.profile_id, event_hour, event_hour+1, recommended_multiplier, now(), now()
      FROM marketcloud_gold.gold_keyword_hourly_calibration_latest_v1 WHERE keyword_id=r.keyword_id;
    UPDATE swarm_src.zanom_ads_bid_schedule_profiles
      SET status='PUBLISHED', is_active=true, version=COALESCE(version,0)+1, published_at=now(), updated_at=now()
      WHERE id=r.profile_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;$$;

-- KILL-SWITCH: desfaz o ultimo apply massivo de cada profile (restaura pre_rules).
CREATE OR REPLACE FUNCTION marketcloud_gold.revert_dayparting_massive() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT ON (profile_id) profile_id, pre_rules_json
    FROM marketcloud_gold.dayparting_apply_audit
    WHERE applied=true AND actor='MASSIVE' AND profile_id IS NOT NULL AND pre_rules_json IS NOT NULL
    ORDER BY profile_id, created_at DESC
  LOOP
    DELETE FROM swarm_src.zanom_ads_bid_schedule_rules WHERE profile_id_ref=r.profile_id;
    INSERT INTO swarm_src.zanom_ads_bid_schedule_rules (id,profile_id_ref,hour_start,hour_end,multiplier,day_of_week,created_at,updated_at)
      SELECT gen_random_uuid()::text, r.profile_id, (e->>'hour_start')::int, (e->>'hour_end')::int,
             (e->>'multiplier')::numeric, NULLIF(e->>'day_of_week',''), now(), now()
      FROM jsonb_array_elements(r.pre_rules_json) e;
    UPDATE swarm_src.zanom_ads_bid_schedule_profiles SET version=COALESCE(version,0)+1, updated_at=now() WHERE id=r.profile_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;$$;
