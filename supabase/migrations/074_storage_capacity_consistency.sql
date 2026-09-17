-- NEXORA - Economy & Balance Audit / Storage Capacity Consistency
-- Migration 074
--
-- Canonical normal-resource storage counts BOTH Depo slots:
--   5000 + SUM(Depo levels) * 2500
--
-- Fixes two legacy runtime functions that still used MAX(Depo level):
-- - nexora_claim_mission
-- - nexora_resolve_world_exploration
--
-- Crystal Deposu remains single-slot and therefore keeps MAX(level).
-- Reward amounts, exploration loot amounts, security modes and grants
-- are otherwise preserved.

BEGIN;

DO $patch$
DECLARE
  v_oid oid;
  v_definition text;
  v_patched text;
  v_matches integer;
BEGIN
  v_oid := to_regprocedure(
    'public.nexora_claim_mission(bigint,text)'
  );

  IF v_oid IS NULL THEN
    RAISE EXCEPTION
      'Required function missing: public.nexora_claim_mission(bigint,text)';
  END IF;

  v_definition := pg_get_functiondef(v_oid);

  SELECT COUNT(*)
  INTO v_matches
  FROM regexp_matches(
    v_definition,
    'MAX\([[:space:]]*CASE[[:space:]]*WHEN building_type = ''Depo'' THEN level[[:space:]]*END[[:space:]]*\)',
    'g'
  );

  IF v_matches <> 1 THEN
    RAISE EXCEPTION
      'nexora_claim_mission Depo capacity target count expected 1, got %',
      v_matches;
  END IF;

  v_patched := regexp_replace(
    v_definition,
    'MAX\([[:space:]]*CASE[[:space:]]*WHEN building_type = ''Depo'' THEN level[[:space:]]*END[[:space:]]*\)',
    'SUM(CASE WHEN building_type = ''Depo'' THEN level END)',
    'g'
  );

  EXECUTE v_patched;

  v_oid := to_regprocedure(
    'public.nexora_resolve_world_exploration(bigint,bigint)'
  );

  IF v_oid IS NULL THEN
    RAISE EXCEPTION
      'Required function missing: public.nexora_resolve_world_exploration(bigint,bigint)';
  END IF;

  v_definition := pg_get_functiondef(v_oid);

  SELECT COUNT(*)
  INTO v_matches
  FROM regexp_matches(
    v_definition,
    'MAX\(level\) FILTER \(WHERE building_type = ''Depo''\)',
    'g'
  );

  IF v_matches <> 1 THEN
    RAISE EXCEPTION
      'nexora_resolve_world_exploration Depo capacity target count expected 1, got %',
      v_matches;
  END IF;

  v_patched := regexp_replace(
    v_definition,
    'MAX\(level\) FILTER \(WHERE building_type = ''Depo''\)',
    'SUM(level) FILTER (WHERE building_type = ''Depo'')',
    'g'
  );

  EXECUTE v_patched;
END;
$patch$;

DO $verify$
DECLARE
  v_claim text;
  v_exploration text;
BEGIN
  SELECT pg_get_functiondef(
    'public.nexora_claim_mission(bigint,text)'::regprocedure
  )
  INTO v_claim;

  SELECT pg_get_functiondef(
    'public.nexora_resolve_world_exploration(bigint,bigint)'::regprocedure
  )
  INTO v_exploration;

  IF v_claim !~ 'SUM\([[:space:]]*CASE[[:space:]]*WHEN building_type = ''Depo'' THEN level[[:space:]]*END[[:space:]]*\)' THEN
    RAISE EXCEPTION
      'nexora_claim_mission Depo SUM verification failed.';
  END IF;

  IF v_claim ~ 'MAX\([[:space:]]*CASE[[:space:]]*WHEN building_type = ''Depo'' THEN level[[:space:]]*END[[:space:]]*\)' THEN
    RAISE EXCEPTION
      'nexora_claim_mission still contains legacy Depo MAX.';
  END IF;

  IF position(
    'SUM(level) FILTER (WHERE building_type = ''Depo'')'
    IN v_exploration
  ) = 0 THEN
    RAISE EXCEPTION
      'nexora_resolve_world_exploration Depo SUM verification failed.';
  END IF;

  IF position(
    'MAX(level) FILTER (WHERE building_type = ''Depo'')'
    IN v_exploration
  ) <> 0 THEN
    RAISE EXCEPTION
      'nexora_resolve_world_exploration still contains legacy Depo MAX.';
  END IF;
END;
$verify$;

COMMIT;
