-- 159_global_overnight_cut.sql
-- CORTE DA MADRUGADA para TODAS as campanhas/keywords. Sobrepoe o piso nas horas
-- 22h-07h em CADA profile ativo (GLOBAL/CAMPAIGN/AD_GROUP/ENTITY), PRESERVANDO os
-- horarios diurnos. Justificativa: madrugada tem pouco trafego + zero venda-com-clique
-- (decisao por VOLUME, nao por ROAS — que sabemos ser frouxo por hora).
--
-- Merge deterministico: expande as janelas atuais p/ hora, mantem diurno como esta,
-- forca overnight = piso, reagrupa em janelas (gaps-and-islands). Backup + revert.
-- p_dry_run=true (default) so mostra o diff; false escreve de verdade.

CREATE TABLE IF NOT EXISTS marketcloud_gold.overnight_cut_audit (
  id           bigserial PRIMARY KEY,
  run_id       text NOT NULL,
  profile_id   text NOT NULL,
  profile_name text,
  scope        text,
  pre_rules_json  jsonb,
  post_rules_json jsonb,
  applied      boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- horas da madrugada (22h ate 07h inclusive)
CREATE OR REPLACE FUNCTION marketcloud_gold._overnight_hours() RETURNS int[]
LANGUAGE sql IMMUTABLE AS $$ SELECT ARRAY[22,23,0,1,2,3,4,5,6,7] $$;

CREATE OR REPLACE FUNCTION marketcloud_gold.apply_overnight_cut_all(
  p_floor   numeric DEFAULT 0.20,
  p_dry_run boolean DEFAULT true
) RETURNS TABLE(
  profile_id text, profile_name text, scope text,
  before_windows text, after_windows text, overnight_before text
) LANGUAGE plpgsql AS $$
DECLARE
  v_run text := 'oc_' || to_char(clock_timestamp(),'YYYYMMDD_HH24MISS_US');
BEGIN
  CREATE TEMP TABLE _oc_new ON COMMIT DROP AS
  WITH prof AS (
    SELECT pp.id, pp.name, pp.scope FROM swarm_src.zanom_ads_bid_schedule_profiles pp
    WHERE pp.status='PUBLISHED' AND pp.is_active
  ),
  exp AS (   -- janelas atuais expandidas por hora
    SELECT r.profile_id_ref AS pid, gs.hr, r.multiplier AS mult
    FROM swarm_src.zanom_ads_bid_schedule_rules r
    JOIN prof p ON p.id = r.profile_id_ref
    CROSS JOIN LATERAL generate_series(r.hour_start, r.hour_end - 1) AS gs(hr)
  ),
  day_hours AS (   -- diurno preservado exatamente
    SELECT pid, hr, mult FROM exp WHERE NOT (hr = ANY (marketcloud_gold._overnight_hours()))
  ),
  night_hours AS ( -- madrugada floored p/ TODO profile ativo
    SELECT p.id AS pid, hr, p_floor AS mult
    FROM prof p CROSS JOIN unnest(marketcloud_gold._overnight_hours()) AS hr
  ),
  final_hours AS (
    SELECT pid, hr, mult FROM day_hours
    UNION ALL
    SELECT pid, hr, mult FROM night_hours
  ),
  isl AS (
    SELECT pid, hr, mult,
           hr - row_number() OVER (PARTITION BY pid, mult ORDER BY hr) AS g
    FROM final_hours
  )
  SELECT pid, mult, min(hr) AS hs, max(hr) + 1 AS he
  FROM isl GROUP BY pid, mult, g;

  -- audita (backup do antes + preview do depois) p/ todo profile ativo
  INSERT INTO marketcloud_gold.overnight_cut_audit
    (run_id, profile_id, profile_name, scope, pre_rules_json, post_rules_json, applied)
  SELECT v_run, p.id, p.name, p.scope,
    COALESCE((SELECT jsonb_agg(jsonb_build_object('hs',hour_start,'he',hour_end,'mult',multiplier) ORDER BY hour_start)
              FROM swarm_src.zanom_ads_bid_schedule_rules WHERE profile_id_ref=p.id), '[]'::jsonb),
    COALESCE((SELECT jsonb_agg(jsonb_build_object('hs',hs,'he',he,'mult',mult) ORDER BY hs)
              FROM _oc_new WHERE pid=p.id), '[]'::jsonb),
    (NOT p_dry_run)
  FROM swarm_src.zanom_ads_bid_schedule_profiles p
  WHERE p.status='PUBLISHED' AND p.is_active;

  IF NOT p_dry_run THEN
    -- escreve de verdade: apaga regras dos profiles ativos e insere as novas janelas
    DELETE FROM swarm_src.zanom_ads_bid_schedule_rules
    WHERE profile_id_ref IN (SELECT id FROM swarm_src.zanom_ads_bid_schedule_profiles WHERE status='PUBLISHED' AND is_active);

    INSERT INTO swarm_src.zanom_ads_bid_schedule_rules
      (id, profile_id_ref, hour_start, hour_end, multiplier, created_at, updated_at)
    SELECT gen_random_uuid()::text, pid, hs, he, mult, now(), now() FROM _oc_new;

    UPDATE swarm_src.zanom_ads_bid_schedule_profiles
    SET version = COALESCE(version,0)+1, published_at = now(), updated_at = now()
    WHERE status='PUBLISHED' AND is_active;
  END IF;

  -- retorna o diff legivel
  RETURN QUERY
  SELECT p.id, p.name, p.scope,
    (SELECT string_agg(hour_start||'-'||hour_end||':'||multiplier, ', ' ORDER BY hour_start)
       FROM swarm_src.zanom_ads_bid_schedule_rules WHERE profile_id_ref=p.id),
    (SELECT string_agg(hs||'-'||he||':'||mult, ', ' ORDER BY hs) FROM _oc_new WHERE pid=p.id),
    (SELECT string_agg(hour_start||'-'||hour_end||':'||multiplier, ', ' ORDER BY hour_start)
       FROM swarm_src.zanom_ads_bid_schedule_rules
       WHERE profile_id_ref=p.id AND (hour_start < 8 OR hour_start >= 22))
  FROM swarm_src.zanom_ads_bid_schedule_profiles p
  WHERE p.status='PUBLISHED' AND p.is_active
  ORDER BY p.scope, p.name;
END;
$$;

-- REVERT do ultimo (ou de um run_id): restaura as regras do backup pre_rules_json.
CREATE OR REPLACE FUNCTION marketcloud_gold.revert_overnight_cut(p_run_id text DEFAULT NULL)
RETURNS TABLE(profile_id text, restored_rules int) LANGUAGE plpgsql AS $$
DECLARE
  v_run text;
BEGIN
  v_run := COALESCE(p_run_id, (SELECT run_id FROM marketcloud_gold.overnight_cut_audit
                               WHERE applied ORDER BY created_at DESC LIMIT 1));
  IF v_run IS NULL THEN RAISE EXCEPTION 'nenhum run aplicado p/ reverter'; END IF;

  DELETE FROM swarm_src.zanom_ads_bid_schedule_rules
  WHERE profile_id_ref IN (SELECT profile_id FROM marketcloud_gold.overnight_cut_audit WHERE run_id=v_run AND applied);

  INSERT INTO swarm_src.zanom_ads_bid_schedule_rules
    (id, profile_id_ref, hour_start, hour_end, multiplier, created_at, updated_at)
  SELECT gen_random_uuid()::text, a.profile_id,
         (e->>'hs')::int, (e->>'he')::int, (e->>'mult')::numeric, now(), now()
  FROM marketcloud_gold.overnight_cut_audit a
  CROSS JOIN LATERAL jsonb_array_elements(a.pre_rules_json) AS e
  WHERE a.run_id=v_run AND a.applied;

  UPDATE swarm_src.zanom_ads_bid_schedule_profiles
  SET version=COALESCE(version,0)+1, published_at=now(), updated_at=now()
  WHERE id IN (SELECT profile_id FROM marketcloud_gold.overnight_cut_audit WHERE run_id=v_run AND applied);

  RETURN QUERY
  SELECT a.profile_id, jsonb_array_length(a.pre_rules_json)
  FROM marketcloud_gold.overnight_cut_audit a WHERE a.run_id=v_run AND a.applied;
END;
$$;
