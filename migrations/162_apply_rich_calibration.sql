-- 162_apply_rich_calibration.sql
-- Aplica a PROPOSTA da calibracao corrigida (v_daypart_calibration_campaign_rich) nos
-- profiles CAMPAIGN, SO nas horas com sinal (new_mult IS NOT NULL) que diferem do atual.
-- Demais horas: preservadas. Merge via gaps-and-islands. Backup + revert. dry_run default.
-- Mesma disciplina do corte de madrugada: nunca escreve hora sem sinal.

CREATE TABLE IF NOT EXISTS marketcloud_gold.calibration_apply_audit (
  id bigserial PRIMARY KEY,
  run_id text NOT NULL,
  profile_id text NOT NULL,
  profile_name text,
  pre_rules_json jsonb,
  post_rules_json jsonb,
  hours_changed int,
  applied boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

DROP FUNCTION IF EXISTS marketcloud_gold.apply_rich_calibration(boolean);
DROP FUNCTION IF EXISTS marketcloud_gold.apply_rich_calibration(boolean, boolean);
-- p_signal_only=true (default): so muda hora com sinal DA CAMPANHA (>=15cl) -> conservador (~30).
-- p_signal_only=false: tambem aplica o fallback global nas horas finas -> reformula tudo (~172).
CREATE FUNCTION marketcloud_gold.apply_rich_calibration(p_dry_run boolean DEFAULT true, p_signal_only boolean DEFAULT true)
RETURNS TABLE(profile_name text, hora int, atual numeric, novo numeric, direcao text)
LANGUAGE plpgsql AS $fn$
DECLARE
  v_run text := 'cal_' || to_char(clock_timestamp(),'YYYYMMDD_HH24MISS_US');
BEGIN
  -- por hora: valor atual + proposta (so profiles CAMPAIGN cujo nome casa a proposta)
  CREATE TEMP TABLE _cal ON COMMIT DROP AS
  WITH prof AS (
    SELECT pp.id, pp.name FROM swarm_src.zanom_ads_bid_schedule_profiles pp
    WHERE pp.scope='CAMPAIGN' AND pp.status='PUBLISHED' AND pp.is_active
  ),
  cur AS (   -- atual expandido por hora
    SELECT p.id AS pid, p.name, gs.hr, r.multiplier AS mult
    FROM prof p
    JOIN swarm_src.zanom_ads_bid_schedule_rules r ON r.profile_id_ref = p.id
    CROSS JOIN LATERAL generate_series(r.hour_start, r.hour_end-1) AS gs(hr)
  ),
  prop AS (   -- proposta: signal_only limita ao sinal da propria campanha (>=15cl)
    SELECT campaign_name, event_hour AS hr, new_mult
    FROM marketcloud_gold.v_daypart_calibration_campaign_rich
    WHERE new_mult IS NOT NULL AND (NOT p_signal_only OR clicks >= 15)
  ),
  merged AS (   -- hora recebe a proposta se houver; senao mantem atual
    SELECT c.pid, c.name, c.hr,
           c.mult AS cur_mult,
           COALESCE(pr.new_mult, c.mult) AS final_mult
    FROM cur c
    LEFT JOIN prop pr ON pr.campaign_name = c.name AND pr.hr = c.hr
  )
  SELECT * FROM merged;

  -- regrupa em janelas (gaps-and-islands) por profile+multiplicador final
  CREATE TEMP TABLE _cal_win ON COMMIT DROP AS
  WITH isl AS (
    SELECT pid, hr, final_mult,
           hr - row_number() OVER (PARTITION BY pid, final_mult ORDER BY hr) AS g
    FROM _cal
  )
  SELECT pid, final_mult AS mult, min(hr) AS hs, max(hr)+1 AS he
  FROM isl GROUP BY pid, final_mult, g;

  -- audita (backup + preview) so dos profiles que REALMENTE mudam
  INSERT INTO marketcloud_gold.calibration_apply_audit
    (run_id, profile_id, profile_name, pre_rules_json, post_rules_json, hours_changed, applied)
  SELECT v_run, p.id, p.name,
    COALESCE((SELECT jsonb_agg(jsonb_build_object('hs',hour_start,'he',hour_end,'mult',multiplier) ORDER BY hour_start)
              FROM swarm_src.zanom_ads_bid_schedule_rules WHERE profile_id_ref=p.id),'[]'::jsonb),
    COALESCE((SELECT jsonb_agg(jsonb_build_object('hs',hs,'he',he,'mult',mult) ORDER BY hs)
              FROM _cal_win WHERE pid=p.id),'[]'::jsonb),
    (SELECT count(*) FROM _cal WHERE pid=p.id AND cur_mult<>final_mult),
    (NOT p_dry_run)
  FROM swarm_src.zanom_ads_bid_schedule_profiles p
  WHERE p.scope='CAMPAIGN' AND p.status='PUBLISHED' AND p.is_active
    AND EXISTS (SELECT 1 FROM _cal WHERE pid=p.id AND cur_mult<>final_mult);

  IF NOT p_dry_run THEN
    DELETE FROM swarm_src.zanom_ads_bid_schedule_rules
    WHERE profile_id_ref IN (SELECT DISTINCT pid FROM _cal WHERE cur_mult<>final_mult);
    INSERT INTO swarm_src.zanom_ads_bid_schedule_rules
      (id, profile_id_ref, hour_start, hour_end, multiplier, created_at, updated_at)
    SELECT gen_random_uuid()::text, w.pid, w.hs, w.he, w.mult, now(), now()
    FROM _cal_win w WHERE w.pid IN (SELECT DISTINCT pid FROM _cal WHERE cur_mult<>final_mult);
    UPDATE swarm_src.zanom_ads_bid_schedule_profiles
    SET version=COALESCE(version,0)+1, published_at=now(), updated_at=now()
    WHERE id IN (SELECT DISTINCT pid FROM _cal WHERE cur_mult<>final_mult);
  END IF;

  RETURN QUERY
  SELECT c.name, c.hr, c.cur_mult, c.final_mult,
         CASE WHEN c.final_mult>c.cur_mult THEN 'SOBE' ELSE 'DESCE' END
  FROM _cal c WHERE c.cur_mult<>c.final_mult ORDER BY c.name, c.hr;
END;
$fn$;

-- revert do ultimo (ou de um run_id) da calibracao
DROP FUNCTION IF EXISTS marketcloud_gold.revert_rich_calibration(text);
CREATE FUNCTION marketcloud_gold.revert_rich_calibration(p_run_id text DEFAULT NULL)
RETURNS TABLE(out_profile_id text, restored int) LANGUAGE plpgsql AS $fn$
DECLARE v_run text;
BEGIN
  v_run := COALESCE(p_run_id, (SELECT a.run_id FROM marketcloud_gold.calibration_apply_audit a
                               WHERE a.applied ORDER BY a.created_at DESC LIMIT 1));
  IF v_run IS NULL THEN RAISE EXCEPTION 'nenhum run aplicado'; END IF;
  DELETE FROM swarm_src.zanom_ads_bid_schedule_rules
  WHERE profile_id_ref IN (SELECT a.profile_id FROM marketcloud_gold.calibration_apply_audit a WHERE a.run_id=v_run AND a.applied);
  INSERT INTO swarm_src.zanom_ads_bid_schedule_rules (id, profile_id_ref, hour_start, hour_end, multiplier, created_at, updated_at)
  SELECT gen_random_uuid()::text, a.profile_id, (e->>'hs')::int, (e->>'he')::int, (e->>'mult')::numeric, now(), now()
  FROM marketcloud_gold.calibration_apply_audit a CROSS JOIN LATERAL jsonb_array_elements(a.pre_rules_json) e
  WHERE a.run_id=v_run AND a.applied;
  UPDATE swarm_src.zanom_ads_bid_schedule_profiles SET version=COALESCE(version,0)+1, published_at=now(), updated_at=now()
  WHERE id IN (SELECT a.profile_id FROM marketcloud_gold.calibration_apply_audit a WHERE a.run_id=v_run AND a.applied);
  RETURN QUERY SELECT a.profile_id, jsonb_array_length(a.pre_rules_json) FROM marketcloud_gold.calibration_apply_audit a WHERE a.run_id=v_run AND a.applied;
END;
$fn$;
