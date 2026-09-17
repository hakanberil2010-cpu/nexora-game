-- NEXORA 066 Final Water Cleanup
-- Apply only after the source cleanup commit is on GitHub main and Vercel is green.
-- Destructive legacy cleanup: removes the final water compatibility layer.
-- Production verification must remain read-only after apply.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $$
DECLARE
  v_count integer;
  v_names text[];
BEGIN
  SELECT count(*)
    INTO v_count
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND (
       (table_name = 'cities' AND column_name IN ('water', 'water_capacity'))
       OR
       (table_name = 'world_sites' AND column_name = 'reward_water')
     );

  IF v_count <> 3 THEN
    RAISE EXCEPTION
      '066 precondition failed: expected 3 legacy water columns, found %.',
      v_count;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.cities
     WHERE alloy IS DISTINCT FROM water
  ) THEN
    RAISE EXCEPTION
      '066 precondition failed: cities alloy/water balance parity mismatch.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.cities
     WHERE alloy_capacity IS DISTINCT FROM water_capacity
  ) THEN
    RAISE EXCEPTION
      '066 precondition failed: cities alloy/water capacity parity mismatch.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.world_sites
     WHERE reward_alloy IS DISTINCT FROM reward_water
  ) THEN
    RAISE EXCEPTION
      '066 precondition failed: world_sites reward parity mismatch.';
  END IF;

  SELECT array_agg(p.proname ORDER BY p.proname)
    INTO v_names
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.prokind = 'f'
     AND lower(pg_get_functiondef(p.oid)) LIKE '%water%';

  IF COALESCE(v_names, ARRAY[]::text[]) IS DISTINCT FROM ARRAY[
    'nexora_spend_city_resources',
    'nexora_sync_city_alloy_compat',
    'nexora_sync_world_site_alloy_compat'
  ]::text[] THEN
    RAISE EXCEPTION
      '066 precondition failed: unexpected public functions contain water: %',
      COALESCE(v_names, ARRAY[]::text[]);
  END IF;

  SELECT count(*)
    INTO v_count
    FROM pg_views
   WHERE schemaname = 'public'
     AND lower(definition) LIKE '%water%';

  IF v_count <> 0 THEN
    RAISE EXCEPTION
      '066 precondition failed: % public view(s) contain water.',
      v_count;
  END IF;

  SELECT count(*)
    INTO v_count
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND lower(pg_get_constraintdef(con.oid, true)) LIKE '%water%';

  IF v_count <> 0 THEN
    RAISE EXCEPTION
      '066 precondition failed: % public constraint(s) contain water.',
      v_count;
  END IF;

  IF EXISTS (SELECT 1 FROM public.battle_reports WHERE loot ? 'water')
     OR EXISTS (SELECT 1 FROM public.espionage_missions WHERE result ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_boss_reward_profiles WHERE first_kill_reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_boss_reward_profiles WHERE weekly_reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.military_missions WHERE result ? 'water')
     OR EXISTS (SELECT 1 FROM public.military_missions WHERE settled_loot ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_battle_reports WHERE report ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_battle_reports WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_camps WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_missions WHERE result ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_missions WHERE reward_snapshot ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_missions WHERE settled_reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.world_exploration_missions WHERE result ? 'water')
     OR EXISTS (SELECT 1 FROM public.world_sites WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_missions WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_daily_missions WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_weekly_missions WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_progression_missions WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_login_rewards WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_alliance_levels WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_mission_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_daily_mission_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_weekly_mission_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_progression_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_login_reward_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_alliance_mission_chest_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_alliance_level_reward_claims WHERE configured_reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_alliance_level_reward_claims WHERE reward ? 'water')
  THEN
    RAISE EXCEPTION
      '066 precondition failed: reward/history JSON still contains water.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.trade_offers
     WHERE give_resource = 'water' OR want_resource = 'water'
  )
  OR EXISTS (
    SELECT 1 FROM public.trade_transactions
     WHERE give_resource = 'water' OR want_resource = 'water'
  ) THEN
    RAISE EXCEPTION
      '066 precondition failed: legacy water trade rows exist.';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.buildings old_b
      JOIN public.buildings new_b
        ON new_b.city_id = old_b.city_id
       AND COALESCE(new_b.slot, 1) = COALESCE(old_b.slot, 1)
       AND new_b.building_type = 'Alaşım Rafinerisi'
     WHERE old_b.building_type = 'Su Arıtma'
  ) THEN
    RAISE EXCEPTION
      '066 precondition failed: building rename collision exists.';
  END IF;
END
$$;

DO $$
DECLARE
  v_unexpected integer;
BEGIN
  WITH targets AS (
    SELECT
      c.oid AS relid,
      a.attnum,
      c.relname,
      a.attname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid
   WHERE n.nspname = 'public'
     AND a.attnum > 0
     AND NOT a.attisdropped
     AND (
       (c.relname = 'cities' AND a.attname IN ('water', 'water_capacity'))
       OR
       (c.relname = 'world_sites' AND a.attname = 'reward_water')
     )
  ),
  deps AS (
    SELECT
      t.relname || '.' || t.attname AS target,
      pg_describe_object(d.classid, d.objid, d.objsubid) AS dependent_object
    FROM targets t
    JOIN pg_depend d
      ON d.refobjid = t.relid
     AND d.refobjsubid = t.attnum
  )
  SELECT count(*)
    INTO v_unexpected
    FROM deps
   WHERE dependent_object NOT IN (
     'default value for column water of table cities',
     'default value for column water_capacity of table cities',
     'default value for column reward_water of table world_sites',
     'trigger trg_nexora_sync_city_alloy_compat on table cities',
     'trigger trg_nexora_sync_world_site_alloy_compat on table world_sites'
   );

  IF v_unexpected <> 0 THEN
    RAISE EXCEPTION
      '066 precondition failed: unexpected dependencies on legacy water columns.';
  END IF;
END
$$;

DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(
    'public.nexora_start_building_upgrade(bigint,bigint,text,integer,jsonb,integer)'::regprocedure
  )
  INTO v_def;

  IF position('public.nexora_spend_city_resources(' IN v_def) = 0 THEN
    RAISE EXCEPTION
      '066 precondition failed: legacy spender call missing in nexora_start_building_upgrade().';
  END IF;

  v_def := replace(
    v_def,
    'public.nexora_spend_city_resources(',
    'public.nexora_spend_city_resources_v2('
  );
  EXECUTE v_def;

  SELECT pg_get_functiondef(
    'public.nexora_start_unit_training(bigint,bigint,text)'::regprocedure
  )
  INTO v_def;

  IF position('public.nexora_spend_city_resources(' IN v_def) = 0 THEN
    RAISE EXCEPTION
      '066 precondition failed: legacy spender call missing in nexora_start_unit_training().';
  END IF;

  v_def := replace(
    v_def,
    'public.nexora_spend_city_resources(',
    'public.nexora_spend_city_resources_v2('
  );
  EXECUTE v_def;
END
$$;

DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(
    'public.nexora_beginner_guide_step_progress(bigint,integer)'::regprocedure
  )
  INTO v_def;
  IF position('Su Arıtma' IN v_def) = 0 THEN
    RAISE EXCEPTION
      '066 precondition failed: expected Su Arıtma in beginner guide function.';
  END IF;
  EXECUTE replace(v_def, 'Su Arıtma', 'Alaşım Rafinerisi');

  SELECT pg_get_functiondef(
    'public.nexora_create_starting_city(bigint,text)'::regprocedure
  )
  INTO v_def;
  IF position('Su Arıtma' IN v_def) = 0 THEN
    RAISE EXCEPTION
      '066 precondition failed: expected Su Arıtma in starting city function.';
  END IF;
  EXECUTE replace(v_def, 'Su Arıtma', 'Alaşım Rafinerisi');

  SELECT pg_get_functiondef(
    'public.nexora_start_building_upgrade_slot(bigint,bigint,text,integer,integer,jsonb,integer)'::regprocedure
  )
  INTO v_def;
  IF position('Su Arıtma' IN v_def) = 0 THEN
    RAISE EXCEPTION
      '066 precondition failed: expected Su Arıtma in slot upgrade function.';
  END IF;

  v_def := replace(v_def, 'Su Arıtma', 'Alaşım Rafinerisi');
  v_def := replace(
    v_def,
    'v_type:=CASE WHEN p_type=''Alaşım Rafinerisi'' THEN ''Alaşım Rafinerisi'' ELSE p_type END;',
    'v_type:=p_type;'
  );
  v_def := replace(
    v_def,
    'CASE WHEN active_building.building_type=''Alaşım Rafinerisi'' THEN ''Alaşım Rafinerisi'' ELSE active_building.building_type END',
    'active_building.building_type'
  );
  v_def := replace(
    v_def,
    'CASE WHEN v_type=''Alaşım Rafinerisi'' THEN ''Alaşım Rafinerisi'' ELSE v_type END',
    'v_type'
  );

  IF position(
    'THEN ''Alaşım Rafinerisi'' ELSE p_type'
    IN v_def
  ) > 0 THEN
    RAISE EXCEPTION
      '066 transform failed: identity building mapping remained in slot upgrade function.';
  END IF;
  EXECUTE v_def;

  SELECT pg_get_functiondef(
    'public.nexora_sync_city_production(bigint)'::regprocedure
  )
  INTO v_def;
  IF position('Su Arıtma' IN v_def) = 0 THEN
    RAISE EXCEPTION
      '066 precondition failed: expected Su Arıtma in production function.';
  END IF;

  v_def := replace(v_def, 'Su Arıtma', 'Alaşım Rafinerisi');
  v_def := replace(
    v_def,
    'building_type IN (''Alaşım Rafinerisi'', ''Alaşım Rafinerisi'')',
    'building_type = ''Alaşım Rafinerisi'''
  );
  EXECUTE v_def;
END
$$;

DROP TRIGGER IF EXISTS trg_nexora_sync_city_alloy_compat
  ON public.cities;

DROP TRIGGER IF EXISTS trg_nexora_sync_world_site_alloy_compat
  ON public.world_sites;

ALTER TABLE public.buildings
  DROP CONSTRAINT IF EXISTS buildings_slot_check;

UPDATE public.buildings
   SET building_type = 'Alaşım Rafinerisi'
 WHERE building_type = 'Su Arıtma';

ALTER TABLE public.buildings
  ADD CONSTRAINT buildings_slot_check
  CHECK (
    slot = 1
    OR (
      slot = 2
      AND building_type = ANY (
        ARRAY[
          'Metal Madeni'::text,
          'Enerji Santrali'::text,
          'Alaşım Rafinerisi'::text,
          'Kristal Madeni'::text,
          'Depo'::text
        ]
      )
    )
  );

DROP FUNCTION IF EXISTS public.nexora_sync_city_alloy_compat();
DROP FUNCTION IF EXISTS public.nexora_sync_world_site_alloy_compat();

DROP FUNCTION IF EXISTS public.nexora_spend_city_resources(
  bigint,
  bigint,
  bigint,
  bigint,
  bigint
);

ALTER TABLE public.cities
  DROP COLUMN IF EXISTS water,
  DROP COLUMN IF EXISTS water_capacity;

ALTER TABLE public.world_sites
  DROP COLUMN IF EXISTS reward_water;

DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT count(*)
    INTO v_count
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND lower(column_name) LIKE '%water%';
  IF v_count <> 0 THEN
    RAISE EXCEPTION
      '066 postcondition failed: % public water-named column(s) remain.',
      v_count;
  END IF;

  SELECT count(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.prokind = 'f'
     AND lower(pg_get_functiondef(p.oid)) LIKE '%water%';
  IF v_count <> 0 THEN
    RAISE EXCEPTION
      '066 postcondition failed: % public function(s) still contain water.',
      v_count;
  END IF;

  SELECT count(*)
    INTO v_count
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE NOT t.tgisinternal
     AND n.nspname = 'public'
     AND lower(pg_get_triggerdef(t.oid)) LIKE '%water%';
  IF v_count <> 0 THEN
    RAISE EXCEPTION
      '066 postcondition failed: % public trigger(s) still contain water.',
      v_count;
  END IF;

  SELECT count(*)
    INTO v_count
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND (
       lower(pg_get_constraintdef(con.oid, true)) LIKE '%water%'
       OR pg_get_constraintdef(con.oid, true) LIKE '%Su Arıtma%'
     );
  IF v_count <> 0 THEN
    RAISE EXCEPTION
      '066 postcondition failed: % public legacy constraint(s) remain.',
      v_count;
  END IF;

  SELECT count(*)
    INTO v_count
    FROM public.buildings
   WHERE building_type = 'Su Arıtma';
  IF v_count <> 0 THEN
    RAISE EXCEPTION
      '066 postcondition failed: % Su Arıtma building row(s) remain.',
      v_count;
  END IF;

  SELECT count(*)
    INTO v_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.prokind = 'f'
     AND pg_get_functiondef(p.oid) LIKE '%Su Arıtma%';
  IF v_count <> 0 THEN
    RAISE EXCEPTION
      '066 postcondition failed: % public function(s) still contain Su Arıtma.',
      v_count;
  END IF;

  IF EXISTS (SELECT 1 FROM public.battle_reports WHERE loot ? 'water')
     OR EXISTS (SELECT 1 FROM public.espionage_missions WHERE result ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_boss_reward_profiles WHERE first_kill_reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_boss_reward_profiles WHERE weekly_reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.military_missions WHERE result ? 'water')
     OR EXISTS (SELECT 1 FROM public.military_missions WHERE settled_loot ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_battle_reports WHERE report ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_battle_reports WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_camps WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_missions WHERE result ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_missions WHERE reward_snapshot ? 'water')
     OR EXISTS (SELECT 1 FROM public.npc_missions WHERE settled_reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.world_exploration_missions WHERE result ? 'water')
     OR EXISTS (SELECT 1 FROM public.world_sites WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_missions WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_daily_missions WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_weekly_missions WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_progression_missions WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_login_rewards WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.game_alliance_levels WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_mission_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_daily_mission_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_weekly_mission_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_progression_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_login_reward_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_alliance_mission_chest_claims WHERE reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_alliance_level_reward_claims WHERE configured_reward ? 'water')
     OR EXISTS (SELECT 1 FROM public.player_alliance_level_reward_claims WHERE reward ? 'water')
  THEN
    RAISE EXCEPTION
      '066 postcondition failed: reward/history JSON still contains water.';
  END IF;
END
$$;

COMMIT;
