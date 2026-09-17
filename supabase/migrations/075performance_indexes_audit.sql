-- NEXORA - Final Security/Performance Audit / Targeted Index Cleanup
-- SQL body for the next official Supabase migration generated in Work/Supabase.
-- Do not apply directly from this file without creating the official migration first.
--
-- Changes:
-- 1) Add covering index for cities.player_id.
-- 2) Add covering index for units.city_id.
-- 3) Remove the redundant standalone unit_levels(unit_type, level) unique index.
--    The UNIQUE constraint-backed index unit_levels_unit_type_level_key is preserved.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_cities_player_id
  ON public.cities USING btree (player_id);

CREATE INDEX IF NOT EXISTS idx_units_city_id
  ON public.units USING btree (city_id);

DO $guard$
DECLARE
  v_constraint_index regclass;
  v_duplicate_index regclass;
BEGIN
  SELECT c.conindid::regclass
  INTO v_constraint_index
  FROM pg_constraint c
  WHERE c.conrelid = 'public.unit_levels'::regclass
    AND c.contype = 'u'
    AND c.conname = 'unit_levels_unit_type_level_key';

  IF v_constraint_index IS NULL THEN
    RAISE EXCEPTION
      'Required UNIQUE constraint index missing: unit_levels_unit_type_level_key';
  END IF;

  v_duplicate_index := to_regclass('public.idx_unit_levels_type_level');

  IF v_duplicate_index IS NOT NULL THEN
    DROP INDEX public.idx_unit_levels_type_level;
  END IF;
END;
$guard$;

COMMIT;
