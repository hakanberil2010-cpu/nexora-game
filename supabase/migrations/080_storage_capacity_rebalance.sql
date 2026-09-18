-- TERYNDIS 080 Storage Capacity Rebalance
-- Canonical storage rules:
-- - Base capacity: 10,000 for Metal, Energy, Alloy and Crystal.
-- - Each Depo level adds 5,000 to Metal/Energy/Alloy capacity.
-- - Each Kristal Deposu level adds 5,000 to Crystal capacity.
-- - New starting cities begin with all four resources full at 10,000.
-- Existing resource balances are preserved; only capacity snapshots are refreshed.

BEGIN;

DO $patch$
DECLARE
  v_proc regprocedure;
  v_def text;
  v_patched text;
BEGIN
  FOREACH v_proc IN ARRAY ARRAY[
    'public.nexora_claim_daily_mission(bigint,text)'::regprocedure,
    'public.nexora_claim_login_reward(bigint)'::regprocedure,
    'public.nexora_claim_mission(bigint,text)'::regprocedure,
    'public.nexora_claim_progression_mission(bigint,text)'::regprocedure,
    'public.nexora_claim_weekly_mission(bigint,text)'::regprocedure,
    'public.nexora_resolve_world_exploration(bigint,bigint)'::regprocedure,
    'public.nexora_sync_city_production(bigint)'::regprocedure,
    'public.nexora_trade_storage_capacity(bigint,text)'::regprocedure
  ]
  LOOP
    v_def := pg_get_functiondef(v_proc);
    v_patched := v_def;

    v_patched := replace(
      v_patched,
      'v_storage bigint := 5000',
      'v_storage bigint := 10000'
    );
    v_patched := replace(
      v_patched,
      'v_crystal_storage bigint := 3000',
      'v_crystal_storage bigint := 10000'
    );

    v_patched := replace(
      v_patched,
      '5000 + GREATEST(v_depo_level, 0) * 2500',
      '10000 + GREATEST(v_depo_level, 0) * 5000'
    );
    v_patched := replace(
      v_patched,
      '5000 + GREATEST(0,v_depo_level) * 2500',
      '10000 + GREATEST(0,v_depo_level) * 5000'
    );
    v_patched := replace(
      v_patched,
      '5000 + GREATEST(0, v_depo_level) * 2500',
      '10000 + GREATEST(0, v_depo_level) * 5000'
    );
    v_patched := replace(
      v_patched,
      '5000 + GREATEST(0,v_depo) * 2500',
      '10000 + GREATEST(0,v_depo) * 5000'
    );

    v_patched := replace(
      v_patched,
      '3000 + GREATEST(v_crystal_depo_level, 0) * 1500',
      '10000 + GREATEST(v_crystal_depo_level, 0) * 5000'
    );
    v_patched := replace(
      v_patched,
      '3000 + GREATEST(0,v_crystal_depo_level) * 1500',
      '10000 + GREATEST(0,v_crystal_depo_level) * 5000'
    );
    v_patched := replace(
      v_patched,
      '3000 + GREATEST(0, v_crystal_depo_level) * 1500',
      '10000 + GREATEST(0, v_crystal_depo_level) * 5000'
    );
    v_patched := replace(
      v_patched,
      '3000 + GREATEST(0,v_crystal_depo) * 1500',
      '10000 + GREATEST(0,v_crystal_depo) * 5000'
    );

    IF v_patched = v_def THEN
      RAISE EXCEPTION
        '080 capacity patch found no target in %',
        v_proc::text;
    END IF;

    EXECUTE v_patched;
  END LOOP;
END;
$patch$;

DO $starting_city$
DECLARE
  v_proc regprocedure :=
    'public.nexora_create_starting_city(bigint,text)'::regprocedure;
  v_def text;
  v_patched text;
  v_anchor text := '    INTO created_city;';
  v_matches integer;
BEGIN
  v_def := pg_get_functiondef(v_proc);

  v_matches :=
    (length(v_def) - length(replace(v_def, v_anchor, '')))
    / length(v_anchor);

  IF v_matches <> 1 THEN
    RAISE EXCEPTION
      '080 starting-city anchor expected once, got %',
      v_matches;
  END IF;

  v_patched := replace(
    v_def,
    v_anchor,
    v_anchor || E'\n\n' ||
    '  UPDATE public.cities' || E'\n' ||
    '     SET metal = 10000,' || E'\n' ||
    '         energy = 10000,' || E'\n' ||
    '         alloy = 10000,' || E'\n' ||
    '         crystal = 10000,' || E'\n' ||
    '         metal_capacity = 10000,' || E'\n' ||
    '         energy_capacity = 10000,' || E'\n' ||
    '         alloy_capacity = 10000,' || E'\n' ||
    '         crystal_capacity = 10000,' || E'\n' ||
    '         updated_at = clock_timestamp()' || E'\n' ||
    '   WHERE id = created_city.id' || E'\n' ||
    '   RETURNING *' || E'\n' ||
    '    INTO created_city;'
  );

  EXECUTE v_patched;
END;
$starting_city$;

WITH levels AS (
  SELECT
    c.id AS city_id,
    COALESCE(
      SUM(GREATEST(COALESCE(b.level, 0), 0))
      FILTER (WHERE b.building_type = 'Depo'),
      0
    )::bigint AS depo_level,
    COALESCE(
      MAX(GREATEST(COALESCE(b.level, 0), 0))
      FILTER (WHERE b.building_type = 'Kristal Deposu'),
      0
    )::bigint AS crystal_depo_level
  FROM public.cities c
  LEFT JOIN public.buildings b
    ON b.city_id = c.id
  GROUP BY c.id
)
UPDATE public.cities c
SET
  metal_capacity =
    10000 + GREATEST(levels.depo_level, 0) * 5000,
  energy_capacity =
    10000 + GREATEST(levels.depo_level, 0) * 5000,
  alloy_capacity =
    10000 + GREATEST(levels.depo_level, 0) * 5000,
  crystal_capacity =
    10000 + GREATEST(levels.crystal_depo_level, 0) * 5000,
  updated_at = clock_timestamp()
FROM levels
WHERE c.id = levels.city_id;

DO $verify$
DECLARE
  v_old_count integer;
  v_def text;
BEGIN
  SELECT COUNT(*)
  INTO v_old_count
  FROM pg_proc p
  JOIN pg_namespace n
    ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind = 'f'
    AND (
      position('5000 + GREATEST(v_depo_level, 0) * 2500'
        IN pg_get_functiondef(p.oid)) > 0
      OR position('5000 + GREATEST(0,v_depo_level) * 2500'
        IN pg_get_functiondef(p.oid)) > 0
      OR position('5000 + GREATEST(0, v_depo_level) * 2500'
        IN pg_get_functiondef(p.oid)) > 0
      OR position('5000 + GREATEST(0,v_depo) * 2500'
        IN pg_get_functiondef(p.oid)) > 0
      OR position('3000 + GREATEST(v_crystal_depo_level, 0) * 1500'
        IN pg_get_functiondef(p.oid)) > 0
      OR position('3000 + GREATEST(0,v_crystal_depo_level) * 1500'
        IN pg_get_functiondef(p.oid)) > 0
      OR position('3000 + GREATEST(0, v_crystal_depo_level) * 1500'
        IN pg_get_functiondef(p.oid)) > 0
      OR position('3000 + GREATEST(0,v_crystal_depo) * 1500'
        IN pg_get_functiondef(p.oid)) > 0
    );

  IF v_old_count <> 0 THEN
    RAISE EXCEPTION
      '080 verification failed: % legacy capacity function(s) remain.',
      v_old_count;
  END IF;

  v_def := pg_get_functiondef(
    'public.nexora_create_starting_city(bigint,text)'::regprocedure
  );

  IF position('metal = 10000' IN v_def) = 0
     OR position('crystal_capacity = 10000' IN v_def) = 0 THEN
    RAISE EXCEPTION
      '080 starting-city full-resource verification failed.';
  END IF;
END;
$verify$;

COMMIT;
