-- TERYNDIS 084 Research Auto Completion V1
-- Finalizes due research with database/server time and a row lock.
-- Completion is idempotent: a due pending research level can be applied only once.
-- City snapshots and objective refreshes synchronize research automatically.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_sync_research_upgrade(p_player_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r public.research%ROWTYPE;
  v_now timestamptz := clock_timestamp();
  v_completed boolean := false;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  SELECT *
    INTO r
    FROM public.research
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'completed', false,
      'research', NULL,
      'serverTime', v_now
    );
  END IF;

  IF r.upgrade_ready_at IS NULL
     OR r.pending_column IS NULL
     OR r.upgrade_ready_at > v_now THEN
    RETURN jsonb_build_object(
      'success', true,
      'completed', false,
      'research', to_jsonb(r),
      'serverTime', v_now
    );
  END IF;

  IF r.pending_column NOT IN (
    'production_level',
    'combat_level',
    'defense_level',
    'crystal_level',
    'general_power_level',
    'unit_attack_level',
    'unit_defense_level',
    'unit_hp_level',
    'travel_speed_level'
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_RESEARCH_STATE',
      'message', 'Araştırma durumu geçersiz.',
      'research', to_jsonb(r),
      'serverTime', v_now
    );
  END IF;

  UPDATE public.research
     SET production_level = COALESCE(production_level,0)
           + CASE WHEN r.pending_column='production_level' THEN 1 ELSE 0 END,
         combat_level = COALESCE(combat_level,0)
           + CASE WHEN r.pending_column='combat_level' THEN 1 ELSE 0 END,
         defense_level = COALESCE(defense_level,0)
           + CASE WHEN r.pending_column='defense_level' THEN 1 ELSE 0 END,
         crystal_level = COALESCE(crystal_level,0)
           + CASE WHEN r.pending_column='crystal_level' THEN 1 ELSE 0 END,
         general_power_level = COALESCE(general_power_level,0)
           + CASE WHEN r.pending_column='general_power_level' THEN 1 ELSE 0 END,
         unit_attack_level = COALESCE(unit_attack_level,0)
           + CASE WHEN r.pending_column='unit_attack_level' THEN 1 ELSE 0 END,
         unit_defense_level = COALESCE(unit_defense_level,0)
           + CASE WHEN r.pending_column='unit_defense_level' THEN 1 ELSE 0 END,
         unit_hp_level = COALESCE(unit_hp_level,0)
           + CASE WHEN r.pending_column='unit_hp_level' THEN 1 ELSE 0 END,
         travel_speed_level = COALESCE(travel_speed_level,0)
           + CASE WHEN r.pending_column='travel_speed_level' THEN 1 ELSE 0 END,
         upgrade_ready_at = NULL,
         pending_column = NULL
   WHERE id = r.id
     AND upgrade_ready_at = r.upgrade_ready_at
     AND pending_column = r.pending_column
  RETURNING * INTO r;

  IF FOUND THEN
    v_completed := true;
  ELSE
    SELECT *
      INTO r
      FROM public.research
     WHERE player_id = p_player_id
     ORDER BY id
     LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'completed', v_completed,
    'research', CASE WHEN r.id IS NULL THEN NULL ELSE to_jsonb(r) END,
    'serverTime', v_now
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_city_snapshot_v2(p_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_city_id bigint;
  v_research_sync jsonb;
  v_now timestamptz := statement_timestamp();
  v_training jsonb;
  v_production jsonb;
  v_population jsonb;
  v_buildings jsonb := '[]'::jsonb;
  v_research jsonb := jsonb_build_object(
    'production_level', 0,
    'crystal_level', 0
  );
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  -- The city row is the existing serialization point shared by training,
  -- production, military capacity and population snapshots.
  SELECT id
    INTO v_city_id
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  v_research_sync := public.nexora_sync_research_upgrade(p_player_id);

  IF COALESCE(v_research_sync->>'success', 'false') <> 'true' THEN
    RETURN v_research_sync;
  END IF;

  -- getCity() previously finalized each ready building from the API process.
  -- Do the same work once, atomically and with database/server time.
  UPDATE public.buildings
     SET level = level + 1,
         is_under_construction = false,
         upgrade_ready_at = NULL
   WHERE city_id = v_city_id
     AND is_under_construction = true
     AND upgrade_ready_at IS NOT NULL
     AND upgrade_ready_at <= v_now;

  v_training := public.nexora_complete_unit_training(
    p_player_id,
    v_city_id
  );

  IF COALESCE(v_training->>'success', 'false') <> 'true' THEN
    RETURN v_training;
  END IF;

  v_production := public.nexora_sync_city_production(p_player_id);

  IF COALESCE(v_production->>'success', 'false') <> 'true' THEN
    RETURN v_production;
  END IF;

  v_population := public.nexora_sync_city_population_snapshot(p_player_id);

  IF COALESCE(v_population->>'success', 'false') <> 'true' THEN
    RETURN v_population;
  END IF;

  SELECT COALESCE(
           jsonb_agg(to_jsonb(b) ORDER BY b.building_type, b.slot, b.id),
           '[]'::jsonb
         )
    INTO v_buildings
    FROM public.buildings b
   WHERE b.city_id = v_city_id;

  SELECT COALESCE(
           (
             SELECT jsonb_build_object(
               'production_level', COALESCE(r.production_level, 0),
               'crystal_level', COALESCE(r.crystal_level, 0)
             )
             FROM public.research r
             WHERE r.player_id = p_player_id
             ORDER BY r.id
             LIMIT 1
           ),
           jsonb_build_object(
             'production_level', 0,
             'crystal_level', 0
           )
         )
    INTO v_research;

  RETURN jsonb_build_object(
    'success', true,
    'city', v_population->'city',
    'buildings', v_buildings,
    'units', COALESCE(v_population->'units', '[]'::jsonb),
    'productionQueue', COALESCE(v_population->'queue', '[]'::jsonb),
    'population', v_population->'population',
    'population_capacity', v_population->'population_capacity',
    'army_capacity', v_population->'army_capacity',
    'research', v_research,
    'serverTime', COALESCE(v_production->'serverTime', to_jsonb(v_now))
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_refresh_achievements(p_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_guide jsonb; v_daily jsonb; v_progression jsonb; v_weekly jsonb; v_login_rewards jsonb; v_research_sync jsonb;
BEGIN
IF p_player_id IS NULL OR p_player_id<=0 OR NOT EXISTS(SELECT 1 FROM public.players p WHERE p.id=p_player_id) THEN RETURN jsonb_build_object('success',false,'code','PLAYER_NOT_FOUND','message','Oyuncu bulunamadı.'); END IF;
v_research_sync:=public.nexora_sync_research_upgrade(p_player_id);
IF COALESCE(v_research_sync->>'success','false')<>'true' THEN RETURN v_research_sync; END IF;
INSERT INTO public.player_achievements(player_id,achievement_id,unlocked_at)
SELECT p_player_id,a.id,now() FROM public.game_achievements a JOIN public.nexora_achievement_metrics_v2(p_player_id) m ON m.metric_key=a.metric_key LEFT JOIN public.player_achievements pa ON pa.player_id=p_player_id AND pa.achievement_id=a.id WHERE a.active IS TRUE AND pa.achievement_id IS NULL AND m.metric_value>=a.target_value ON CONFLICT (player_id,achievement_id) DO NOTHING;
v_guide:=public.nexora_refresh_beginner_guide(p_player_id);
v_daily:=public.nexora_daily_missions_snapshot(p_player_id);
v_progression:=public.nexora_progression_snapshot(p_player_id);
v_weekly:=public.nexora_weekly_missions_snapshot(p_player_id);
v_login_rewards:=public.nexora_login_rewards_snapshot(p_player_id);
RETURN public.nexora_missions_snapshot(p_player_id)||jsonb_build_object('guide',v_guide,'daily',v_daily,'progression',v_progression,'weekly',v_weekly,'loginRewards',v_login_rewards);
END;
$function$;

REVOKE ALL ON FUNCTION public.nexora_sync_research_upgrade(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_sync_research_upgrade(bigint)
  TO service_role;

COMMIT;
