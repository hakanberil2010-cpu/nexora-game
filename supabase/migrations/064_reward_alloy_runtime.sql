-- NEXORA - Economy Rebalance V1 / Reward Alloy Runtime
-- Migration 064
--
-- Converts mission/login/alliance reward runtime from legacy water to alloy.
-- Scope is intentionally limited to reward claim/config flows.
-- PvP/PvE/exploration/boss resolution remains for the next migration.
--
-- Production audit before this migration:
--   reward config rows with water key: 60
--   reward config rows with alloy key: 0
--   reward config rows with both keys: 0

BEGIN;

DO $guard$
DECLARE
  v_conflicts bigint := 0;
BEGIN
  SELECT
    (SELECT COUNT(*) FROM public.game_missions WHERE reward ? 'water' AND reward ? 'alloy') +
    (SELECT COUNT(*) FROM public.game_daily_missions WHERE reward ? 'water' AND reward ? 'alloy') +
    (SELECT COUNT(*) FROM public.game_weekly_missions WHERE reward ? 'water' AND reward ? 'alloy') +
    (SELECT COUNT(*) FROM public.game_progression_missions WHERE reward ? 'water' AND reward ? 'alloy') +
    (SELECT COUNT(*) FROM public.game_login_rewards WHERE reward ? 'water' AND reward ? 'alloy') +
    (SELECT COUNT(*) FROM public.game_alliance_levels WHERE reward ? 'water' AND reward ? 'alloy')
  INTO v_conflicts;

  IF v_conflicts <> 0 THEN
    RAISE EXCEPTION
      'Reward migration aborted: rows containing both water and alloy keys exist.';
  END IF;
END;
$guard$;

-- Canonical reward configuration JSON.
UPDATE public.game_missions
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water';

UPDATE public.game_daily_missions
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water';

UPDATE public.game_weekly_missions
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water';

UPDATE public.game_progression_missions
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water';

UPDATE public.game_login_rewards
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water';

UPDATE public.game_alliance_levels
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water';

-- Historical reward JSON is metadata, not spendable state.
-- Migrate it so old records also stop exposing a water key.
UPDATE public.player_mission_claims
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water'
  AND NOT (reward ? 'alloy');

UPDATE public.player_daily_mission_claims
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water'
  AND NOT (reward ? 'alloy');

UPDATE public.player_weekly_mission_claims
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water'
  AND NOT (reward ? 'alloy');

UPDATE public.player_progression_claims
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water'
  AND NOT (reward ? 'alloy');

UPDATE public.player_login_reward_claims
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water'
  AND NOT (reward ? 'alloy');

UPDATE public.player_alliance_mission_chest_claims
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water'
  AND NOT (reward ? 'alloy');

UPDATE public.player_alliance_level_reward_claims
SET configured_reward =
  (configured_reward - 'water') ||
  jsonb_build_object(
    'alloy',
    COALESCE(NULLIF(configured_reward->>'water','')::bigint,0)
  )
WHERE configured_reward ? 'water'
  AND NOT (configured_reward ? 'alloy');

UPDATE public.player_alliance_level_reward_claims
SET reward =
  (reward - 'water') ||
  jsonb_build_object('alloy', COALESCE(NULLIF(reward->>'water','')::bigint,0))
WHERE reward ? 'water'
  AND NOT (reward ? 'alloy');

-- These functions are already production-proven.
-- The only resource-token migration is water -> alloy, which also maps
-- water_capacity -> alloy_capacity and JSON keys/variables consistently.
DO $functions$
DECLARE
  v_signature text;
  v_oid oid;
  v_definition text;
  v_migrated text;
  v_signatures constant text[] := ARRAY[
    'public.nexora_claim_mission(bigint,text)',
    'public.nexora_claim_daily_mission(bigint,text)',
    'public.nexora_claim_weekly_mission(bigint,text)',
    'public.nexora_claim_progression_mission(bigint,text)',
    'public.nexora_claim_login_reward(bigint)',
    'public.nexora_alliance_missions_snapshot(bigint)',
    'public.nexora_claim_alliance_mission_chest(bigint)',
    'public.nexora_claim_alliance_level_reward(bigint,integer)'
  ];
BEGIN
  FOREACH v_signature IN ARRAY v_signatures LOOP
    v_oid := to_regprocedure(v_signature);

    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'Required reward function missing: %', v_signature;
    END IF;

    v_definition := pg_get_functiondef(v_oid);

    IF position('water' IN lower(v_definition)) = 0 THEN
      RAISE EXCEPTION
        'Expected legacy water token not found in reward function: %',
        v_signature;
    END IF;

    v_migrated := replace(v_definition, 'water', 'alloy');
    v_migrated := replace(v_migrated, 'Water', 'Alloy');
    v_migrated := replace(v_migrated, 'WATER', 'ALLOY');

    IF position('water' IN lower(v_migrated)) <> 0 THEN
      RAISE EXCEPTION
        'Legacy water token remains after reward function migration: %',
        v_signature;
    END IF;

    EXECUTE v_migrated;
  END LOOP;
END;
$functions$;

-- Hard postconditions: config and migrated runtime functions must be alloy-only.
DO $verify$
DECLARE
  v_water_configs bigint := 0;
  v_runtime_water bigint := 0;
BEGIN
  SELECT
    (SELECT COUNT(*) FROM public.game_missions WHERE reward ? 'water') +
    (SELECT COUNT(*) FROM public.game_daily_missions WHERE reward ? 'water') +
    (SELECT COUNT(*) FROM public.game_weekly_missions WHERE reward ? 'water') +
    (SELECT COUNT(*) FROM public.game_progression_missions WHERE reward ? 'water') +
    (SELECT COUNT(*) FROM public.game_login_rewards WHERE reward ? 'water') +
    (SELECT COUNT(*) FROM public.game_alliance_levels WHERE reward ? 'water')
  INTO v_water_configs;

  IF v_water_configs <> 0 THEN
    RAISE EXCEPTION
      'Reward migration verification failed: % water config rows remain.',
      v_water_configs;
  END IF;

  SELECT COUNT(*)
    INTO v_runtime_water
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'nexora_claim_mission',
       'nexora_claim_daily_mission',
       'nexora_claim_weekly_mission',
       'nexora_claim_progression_mission',
       'nexora_claim_login_reward',
       'nexora_alliance_missions_snapshot',
       'nexora_claim_alliance_mission_chest',
       'nexora_claim_alliance_level_reward'
     )
     AND p.prokind = 'f'
     AND lower(pg_get_functiondef(p.oid)) LIKE '%water%';

  IF v_runtime_water <> 0 THEN
    RAISE EXCEPTION
      'Reward runtime migration verification failed: % functions still contain water.',
      v_runtime_water;
  END IF;
END;
$verify$;

COMMIT;
