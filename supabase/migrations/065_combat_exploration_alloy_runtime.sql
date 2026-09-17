-- NEXORA - Economy Rebalance V1 / Combat Exploration Alloy Runtime
-- Migration 065
--
-- Converts active combat, PvE, exploration, boss, espionage and region-bonus
-- runtime from legacy water to canonical alloy.
--
-- This migration intentionally keeps only three legacy compatibility functions:
--   nexora_spend_city_resources(...)
--   nexora_sync_city_alloy_compat()
--   nexora_sync_world_site_alloy_compat()
-- They are removed together with legacy columns in migration 066.

BEGIN;

-- Abort rather than guess if target history/config JSON already mixes
-- legacy water and canonical alloy keys in the same row.
DO $guard$
DECLARE
  v_conflicts bigint := 0;
BEGIN
  SELECT
    (SELECT COUNT(*) FROM public.battle_reports
      WHERE loot::text LIKE '%"water":%' AND loot::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.espionage_missions
      WHERE result::text LIKE '%"water":%' AND result::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.game_boss_reward_profiles
      WHERE first_kill_reward::text LIKE '%"water":%' AND first_kill_reward::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.game_boss_reward_profiles
      WHERE weekly_reward::text LIKE '%"water":%' AND weekly_reward::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.military_missions
      WHERE result::text LIKE '%"water":%' AND result::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.military_missions
      WHERE settled_loot::text LIKE '%"water":%' AND settled_loot::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.npc_battle_reports
      WHERE report::text LIKE '%"water":%' AND report::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.npc_battle_reports
      WHERE reward::text LIKE '%"water":%' AND reward::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.npc_camps
      WHERE reward::text LIKE '%"water":%' AND reward::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.npc_missions
      WHERE result::text LIKE '%"water":%' AND result::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.npc_missions
      WHERE reward_snapshot::text LIKE '%"water":%' AND reward_snapshot::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.npc_missions
      WHERE settled_reward::text LIKE '%"water":%' AND settled_reward::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.world_exploration_missions
      WHERE result::text LIKE '%"water":%' AND result::text LIKE '%"alloy":%') +
    (SELECT COUNT(*) FROM public.world_sites
      WHERE reward::text LIKE '%"water":%' AND reward::text LIKE '%"alloy":%')
  INTO v_conflicts;

  IF v_conflicts <> 0 THEN
    RAISE EXCEPTION
      'Combat/exploration alloy migration aborted: % mixed water/alloy JSON rows exist.',
      v_conflicts;
  END IF;
END;
$guard$;

-- JSON text replacement is key-specific: only the exact JSON object token
-- "water": is renamed, so nested reward/resources/loot objects are handled
-- without changing string values.
UPDATE public.battle_reports
SET loot = replace(loot::text, '"water":', '"alloy":')::jsonb
WHERE loot::text LIKE '%"water":%';

UPDATE public.espionage_missions
SET result = replace(result::text, '"water":', '"alloy":')::jsonb
WHERE result::text LIKE '%"water":%';

UPDATE public.game_boss_reward_profiles
SET first_kill_reward =
      replace(first_kill_reward::text, '"water":', '"alloy":')::jsonb
WHERE first_kill_reward::text LIKE '%"water":%';

UPDATE public.game_boss_reward_profiles
SET weekly_reward =
      replace(weekly_reward::text, '"water":', '"alloy":')::jsonb
WHERE weekly_reward::text LIKE '%"water":%';

UPDATE public.military_missions
SET result = replace(result::text, '"water":', '"alloy":')::jsonb
WHERE result::text LIKE '%"water":%';

UPDATE public.military_missions
SET settled_loot =
      replace(settled_loot::text, '"water":', '"alloy":')::jsonb
WHERE settled_loot::text LIKE '%"water":%';

UPDATE public.npc_battle_reports
SET report = replace(report::text, '"water":', '"alloy":')::jsonb
WHERE report::text LIKE '%"water":%';

UPDATE public.npc_battle_reports
SET reward = replace(reward::text, '"water":', '"alloy":')::jsonb
WHERE reward::text LIKE '%"water":%';

UPDATE public.npc_camps
SET reward = replace(reward::text, '"water":', '"alloy":')::jsonb
WHERE reward::text LIKE '%"water":%';

UPDATE public.npc_missions
SET result = replace(result::text, '"water":', '"alloy":')::jsonb
WHERE result::text LIKE '%"water":%';

UPDATE public.npc_missions
SET reward_snapshot =
      replace(reward_snapshot::text, '"water":', '"alloy":')::jsonb
WHERE reward_snapshot::text LIKE '%"water":%';

UPDATE public.npc_missions
SET settled_reward =
      replace(settled_reward::text, '"water":', '"alloy":')::jsonb
WHERE settled_reward::text LIKE '%"water":%';

UPDATE public.world_exploration_missions
SET result = replace(result::text, '"water":', '"alloy":')::jsonb
WHERE result::text LIKE '%"water":%';

UPDATE public.world_sites
SET reward = replace(reward::text, '"water":', '"alloy":')::jsonb
WHERE reward::text LIKE '%"water":%';

-- Convert all remaining active gameplay functions that do not have "water"
-- in their SQL identity signature. CREATE OR REPLACE preserves the proven
-- signatures, grants and security mode of each function.
DO $functions$
DECLARE
  v_signature text;
  v_oid oid;
  v_definition text;
  v_migrated text;
  v_signatures constant text[] := ARRAY[
    'public.nexora_alliance_region_control(bigint)',
    'public.nexora_claim_boss_first_kill(bigint,bigint)',
    'public.nexora_claim_weekly_boss_reward(bigint)',
    'public.nexora_create_starting_city(bigint,text)',
    'public.nexora_player_alliance_region_bonus(bigint)',
    'public.nexora_pve_statistics_snapshot(bigint)',
    'public.nexora_resolve_espionage(bigint,bigint)',
    'public.nexora_resolve_military_mission(bigint,bigint,jsonb,jsonb,jsonb,integer,integer,numeric,integer,bigint,integer)',
    'public.nexora_resolve_npc_mission(bigint,bigint,jsonb,jsonb,integer,integer,integer)',
    'public.nexora_resolve_world_exploration(bigint,bigint)',
    'public.nexora_settle_mission_loot(bigint,bigint,numeric)',
    'public.nexora_start_building_upgrade(bigint,bigint,text,integer,jsonb,integer)',
    'public.nexora_start_building_upgrade_slot(bigint,bigint,text,integer,integer,jsonb,integer)',
    'public.nexora_start_npc_mission(bigint,bigint,bigint,jsonb,integer,integer,integer,integer,numeric,text)',
    'public.nexora_start_research_upgrade(bigint,bigint,text,integer,jsonb,integer)',
    'public.nexora_sync_city_production(bigint)'
  ];
BEGIN
  FOREACH v_signature IN ARRAY v_signatures LOOP
    v_oid := to_regprocedure(v_signature);

    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'Required gameplay function missing: %', v_signature;
    END IF;

    v_definition := pg_get_functiondef(v_oid);

    IF position('water' IN lower(v_definition)) = 0 THEN
      RAISE EXCEPTION
        'Expected legacy water token not found in gameplay function: %',
        v_signature;
    END IF;

    v_migrated := replace(v_definition, 'water', 'alloy');
    v_migrated := replace(v_migrated, 'Water', 'Alloy');
    v_migrated := replace(v_migrated, 'WATER', 'ALLOY');

    -- User-facing region bonus text is Turkish and therefore not covered
    -- by the English resource-token replacement above.
    v_migrated :=
      replace(v_migrated, 'Su üretimi +5%', 'Alaşım üretimi +5%');

    IF position('water' IN lower(v_migrated)) <> 0 THEN
      RAISE EXCEPTION
        'Legacy water token remains after gameplay function migration: %',
        v_signature;
    END IF;

    EXECUTE v_migrated;
  END LOOP;
END;
$functions$;

-- Hard postconditions.
DO $verify$
DECLARE
  v_json_water bigint := 0;
  v_selected_runtime_water bigint := 0;
  v_unexpected_runtime_water bigint := 0;
BEGIN
  SELECT
    (SELECT COUNT(*) FROM public.battle_reports WHERE loot::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.espionage_missions WHERE result::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.game_boss_reward_profiles WHERE first_kill_reward::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.game_boss_reward_profiles WHERE weekly_reward::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.military_missions WHERE result::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.military_missions WHERE settled_loot::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.npc_battle_reports WHERE report::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.npc_battle_reports WHERE reward::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.npc_camps WHERE reward::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.npc_missions WHERE result::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.npc_missions WHERE reward_snapshot::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.npc_missions WHERE settled_reward::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.world_exploration_missions WHERE result::text LIKE '%"water":%') +
    (SELECT COUNT(*) FROM public.world_sites WHERE reward::text LIKE '%"water":%')
  INTO v_json_water;

  IF v_json_water <> 0 THEN
    RAISE EXCEPTION
      'Combat/exploration history verification failed: % water JSON rows remain.',
      v_json_water;
  END IF;

  SELECT COUNT(*)
    INTO v_selected_runtime_water
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.prokind = 'f'
     AND p.proname IN (
       'nexora_alliance_region_control',
       'nexora_claim_boss_first_kill',
       'nexora_claim_weekly_boss_reward',
       'nexora_create_starting_city',
       'nexora_player_alliance_region_bonus',
       'nexora_pve_statistics_snapshot',
       'nexora_resolve_espionage',
       'nexora_resolve_military_mission',
       'nexora_resolve_npc_mission',
       'nexora_resolve_world_exploration',
       'nexora_settle_mission_loot',
       'nexora_start_building_upgrade',
       'nexora_start_building_upgrade_slot',
       'nexora_start_npc_mission',
       'nexora_start_research_upgrade',
       'nexora_sync_city_production'
     )
     AND lower(pg_get_functiondef(p.oid)) LIKE '%water%';

  IF v_selected_runtime_water <> 0 THEN
    RAISE EXCEPTION
      'Gameplay runtime verification failed: % migrated functions still contain water.',
      v_selected_runtime_water;
  END IF;

  SELECT COUNT(*)
    INTO v_unexpected_runtime_water
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.prokind = 'f'
     AND lower(pg_get_functiondef(p.oid)) LIKE '%water%'
     AND p.proname NOT IN (
       'nexora_spend_city_resources',
       'nexora_sync_city_alloy_compat',
       'nexora_sync_world_site_alloy_compat'
     );

  IF v_unexpected_runtime_water <> 0 THEN
    RAISE EXCEPTION
      'Unexpected water runtime functions remain after migration: %.',
      v_unexpected_runtime_water;
  END IF;
END;
$verify$;

COMMIT;
