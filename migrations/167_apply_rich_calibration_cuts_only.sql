-- 167_apply_rich_calibration_cuts_only.sql
-- PASSO 2 (semi-auto): adiciona p_cuts_only a apply_rich_calibration. Quando true,
-- SO aplica reducoes (new_mult < atual) — protetivas, cobertas pelo risk guard (F1).
-- Aumentos (FEED) e neutros ficam intactos ate a impression share fluir + a medicao
-- madurar. Mantem backup/revert e dry_run.

DROP FUNCTION IF EXISTS marketcloud_gold.apply_rich_calibration(boolean);
DROP FUNCTION IF EXISTS marketcloud_gold.apply_rich_calibration(boolean, boolean);
DROP FUNCTION IF EXISTS marketcloud_gold.apply_rich_calibration(boolean, boolean, boolean);
CREATE FUNCTION marketcloud_gold.apply_rich_calibration(
  p_dry_run boolean DEFAULT true,
  p_signal_only boolean DEFAULT true,
  p_cuts_only boolean DEFAULT false)
RETURNS TABLE(profile_name text, hora int, atual numeric, novo numeric, direcao text)
LANGUAGE plpgsql AS $fn$
DECLARE
  v_run text := 'cal_' || to_char(clock_timestamp(),'YYYYMMDD_HH24MISS_US') || CASE WHEN p_cuts_only THEN '_cuts' ELSE '' END;
BEGIN
  CREATE TEMP TABLE _cal ON COMMIT DROP AS
  WITH prof AS (
    SELECT pp.id, pp.name FROM swarm_src.zanom_ads_bid_schedule_profiles pp
    WHERE pp.scope='CAMPAIGN' AND pp.status='PUBLISHED' AND pp.is_active
  ),
  cur AS (
    SELECT p.id AS pid, p.name, gs.hr, r.multiplier AS mult
    FROM prof p
    JOIN swarm_src.zanom_ads_bid_schedule_rules r ON r.profile_id_ref = p.id
    CROSS JOIN LATERAL generate_series(r.hour_start, r.hour_end-1) AS gs(hr)
  ),
  prop AS (
    SELECT campaign_name, event_hour AS hr, new_mult
    FROM marketcloud_gold.v_daypart_calibration_campaign_rich
    WHERE new_mult IS NOT NULL AND (NOT p_signal_only OR clicks >= 15)
  ),
  merged AS (
    -- cuts_only: so aceita a proposta se ela REDUZ o bid; senao mantem o atual
    SELECT c.pid, c.name, c.hr,
           c.mult AS cur_mult,
           CASE WHEN pr.new_mult IS NOT NULL AND (NOT p_cuts_only OR pr.new_mult < c.mult)
                THEN pr.new_mult ELSE c.mult END AS final_mult
    FROM cur c
    LEFT JOIN prop pr ON pr.campaign_name = c.name AND pr.hr = c.hr
  )
  SELECT * FROM merged;

  CREATE TEMP TABLE _cal_win ON COMMIT DROP AS
  WITH isl AS (
    SELECT pid, hr, final_mult,
           hr - row_number() OVER (PARTITION BY pid, final_mult ORDER BY hr) AS g
    FROM _cal
  )
  SELECT pid, final_mult AS mult, min(hr) AS hs, max(hr)+1 AS he
  FROM isl GROUP BY pid, final_mult, g;

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
