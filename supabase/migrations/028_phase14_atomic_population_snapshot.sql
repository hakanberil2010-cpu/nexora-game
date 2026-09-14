-- NEXORA Phase 14.6.1
-- Atomically snapshots effective military population for getCity().
-- Apply AFTER 027 and BEFORE deploying the matching api/auth.js.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_sync_city_population_snapshot(
  p_player_id bigint
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c public.cities%ROWTYPE;
  population_total numeric := 0;
  population_value bigint := 0;
  active_military bigint := 0;
  housing integer := 100;
  barracks integer := 0;
  army integer := 50;
  units_json jsonb := '[]'::jsonb;
  queue_json jsonb := '[]'::jsonb;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  -- The city row is the serialization point shared with training,
  -- military mission start and military return.
  SELECT *
  INTO c
  FROM public.cities
  WHERE player_id = p_player_id
  ORDER BY id
  LIMIT 1
  FOR UPDATE;

  IF c.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  SELECT
    100 + 50 * GREATEST(
      0,
      COALESCE((
        SELECT level
        FROM public.buildings
        WHERE city_id = c.id
          AND building_type = 'Konut'
        ORDER BY id
        LIMIT 1
      ), 0)
    )
  INTO housing;

  SELECT GREATEST(
    0,
    COALESCE((
      SELECT level
      FROM public.buildings
      WHERE city_id = c.id
        AND building_type = 'Kışla'
      ORDER BY id
      LIMIT 1
    ), 0)
  )
  INTO barracks;

  army := 50 + 50 * barracks;

  SELECT COALESCE(SUM(amount), 0)::numeric
  INTO population_total
  FROM (
    SELECT
      quantity::numeric *
      CASE unit_type
        WHEN 'tank' THEN 3
        WHEN 'hava' THEN 2
        WHEN 'piyade' THEN 1
        WHEN 'savunma' THEN 1
        WHEN 'saldiri' THEN 1
        WHEN 'okcu' THEN 1
        ELSE COALESCE(NULLIF(population_cost, 0), 1)
      END AS amount
    FROM public.units
    WHERE city_id = c.id

    UNION ALL

    SELECT
      quantity::numeric *
      CASE unit_type
        WHEN 'tank' THEN 3
        WHEN 'hava' THEN 2
        ELSE 1
      END AS amount
    FROM public.unit_production_queue
    WHERE city_id = c.id
      AND player_id = p_player_id
      AND status = 'training'
  ) pop;

  active_military := GREATEST(
    0,
    COALESCE(public.nexora_active_military_population(p_player_id), 0)
  );

  population_total := GREATEST(0::numeric, population_total)
    + active_military::numeric;

  population_value := LEAST(
    population_total,
    9223372036854775807::numeric
  )::bigint;

  UPDATE public.cities
  SET population = population_value,
      population_capacity = housing,
      army_capacity = army
  WHERE id = c.id
    AND (
      population IS DISTINCT FROM population_value
      OR population_capacity IS DISTINCT FROM housing
      OR army_capacity IS DISTINCT FROM army
    )
  RETURNING * INTO c;

  IF NOT FOUND THEN
    SELECT *
    INTO c
    FROM public.cities
    WHERE player_id = p_player_id
    ORDER BY id
    LIMIT 1;
  END IF;

  -- Return units and queue from the same transaction/snapshot that produced
  -- the effective population. Mutations sharing the city lock cannot interleave.
  SELECT COALESCE(
    jsonb_agg(to_jsonb(u) ORDER BY u.id),
    '[]'::jsonb
  )
  INTO units_json
  FROM public.units u
  WHERE u.city_id = c.id;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(q) ORDER BY q.finish_at, q.id),
    '[]'::jsonb
  )
  INTO queue_json
  FROM public.unit_production_queue q
  WHERE q.city_id = c.id
    AND q.player_id = p_player_id
    AND q.status = 'training';

  RETURN jsonb_build_object(
    'success', true,
    'city', to_jsonb(c),
    'units', units_json,
    'queue', queue_json,
    'activeMissionPopulation', active_military,
    'population', population_value,
    'population_capacity', housing,
    'army_capacity', army
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_sync_city_population_snapshot(bigint)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_sync_city_population_snapshot(bigint)
TO service_role;

COMMIT;
