-- 201: latest_v1 carrega as entranhas do blend (colunas da 200).
CREATE OR REPLACE VIEW marketcloud_gold.gold_keyword_hourly_calibration_latest_v1 AS
 SELECT DISTINCT ON (keyword_id, event_hour) computed_at,
    window_days,
    campaign_id,
    ad_group_id,
    keyword_id,
    keyword_text,
    match_type,
    event_hour,
    scope,
    clicks,
    spend,
    sales,
    hour_roas,
    scope_avg_roas,
    signal,
    target_multiplier,
    current_multiplier,
    recommended_multiplier,
    action,
    gate,
    reason,
    published_multiplier,
    weeks_of_data,
    baseline_scope,
    kw_roas_raw,
    prior_roas,
    ml_factor,
    blend_weight
   FROM marketcloud_gold.gold_keyword_hourly_calibration_v1
  ORDER BY keyword_id, event_hour, computed_at DESC;
;
