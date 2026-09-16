-- NEXORA - City Snapshot Performance V2. Apply after 048_header_badges_v2.sql.
-- Consolidates the normal city-screen refresh into one PostgREST RPC/transaction.
-- Existing authoritative production, training and population functions are reused.
-- No tables or existing RPC contracts are replaced.
BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_city_snapshot_v2(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_city_id bigint;
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

REVOKE ALL ON FUNCTION public.nexora_city_snapshot_v2(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_city_snapshot_v2(bigint)
  TO service_role;

COMMIT;
