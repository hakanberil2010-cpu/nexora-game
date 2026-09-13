-- NEXORA Phase 10 audit fix 1
-- Atomic city production sync to prevent stale absolute resource PATCHes
-- from overwriting trade escrow / delivery resource changes.
-- Apply after 012_phase10_trade_v2.sql.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_sync_city_production(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_city public.cities%ROWTYPE;
  v_now timestamptz := now();
  v_last timestamptz;
  v_elapsed_minutes integer := 0;

  v_metal_level integer := 0;
  v_energy_level integer := 0;
  v_water_level integer := 0;
  v_crystal_level integer := 0;
  v_depo_level integer := 0;
  v_crystal_depo_level integer := 0;

  v_production_research integer := 0;
  v_crystal_research integer := 0;

  v_metal_rate numeric := 0;
  v_energy_rate numeric := 0;
  v_water_rate numeric := 0;
  v_crystal_rate numeric := 0;

  v_storage bigint := 5000;
  v_crystal_storage bigint := 3000;

  v_add_metal bigint := 0;
  v_add_energy bigint := 0;
  v_add_water bigint := 0;
  v_add_crystal bigint := 0;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  -- City is the shared resource row. Lock it before reading resource values so
  -- concurrent trade escrow/delivery cannot be overwritten by stale data.
  SELECT *
    INTO v_city
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

  SELECT
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Metal Madeni'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Enerji Santrali'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Su Arıtma'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Kristal Madeni'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Depo'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Kristal Deposu'), 0)
  INTO
    v_metal_level,
    v_energy_level,
    v_water_level,
    v_crystal_level,
    v_depo_level,
    v_crystal_depo_level
  FROM public.buildings
  WHERE city_id = v_city.id;

  SELECT
    COALESCE(production_level, 0),
    COALESCE(crystal_level, 0)
  INTO
    v_production_research,
    v_crystal_research
  FROM public.research
  WHERE player_id = p_player_id
  ORDER BY id
  LIMIT 1;

  IF NOT FOUND THEN
    v_production_research := 0;
    v_crystal_research := 0;
  END IF;

  v_storage := 5000 + GREATEST(0, v_depo_level) * 2500;
  v_crystal_storage := 3000 + GREATEST(0, v_crystal_depo_level) * 1500;

  v_metal_rate :=
    GREATEST(0, v_metal_level) * 10
    * (1 + GREATEST(0, v_production_research) * 0.10);

  v_energy_rate :=
    GREATEST(0, v_energy_level) * 10
    * (1 + GREATEST(0, v_production_research) * 0.10);

  v_water_rate :=
    GREATEST(0, v_water_level) * 10
    * (1 + GREATEST(0, v_production_research) * 0.10);

  v_crystal_rate :=
    GREATEST(0, v_crystal_level) * 5
    * (1 + GREATEST(0, v_crystal_research) * 0.08);

  v_last := COALESCE(v_city.last_production_at, v_city.updated_at, v_now);

  v_elapsed_minutes := GREATEST(
    0,
    FLOOR(EXTRACT(EPOCH FROM (v_now - v_last)) / 60)::integer
  );

  IF v_elapsed_minutes > 0 THEN
    -- Resources are integer game units. Accrue only complete units.
    v_add_metal := FLOOR(v_metal_rate * v_elapsed_minutes)::bigint;
    v_add_energy := FLOOR(v_energy_rate * v_elapsed_minutes)::bigint;
    v_add_water := FLOOR(v_water_rate * v_elapsed_minutes)::bigint;
    v_add_crystal := FLOOR(v_crystal_rate * v_elapsed_minutes)::bigint;

    UPDATE public.cities
       SET metal = LEAST(
             v_storage,
             GREATEST(0, COALESCE(metal, 0) + v_add_metal)
           ),
           energy = LEAST(
             v_storage,
             GREATEST(0, COALESCE(energy, 0) + v_add_energy)
           ),
           water = LEAST(
             v_storage,
             GREATEST(0, COALESCE(water, 0) + v_add_water)
           ),
           crystal = LEAST(
             v_crystal_storage,
             GREATEST(0, COALESCE(crystal, 0) + v_add_crystal)
           ),
           metal_capacity = v_storage,
           energy_capacity = v_storage,
           water_capacity = v_storage,
           crystal_capacity = v_crystal_storage,
           last_production_at = v_now,
           updated_at = v_now
     WHERE id = v_city.id
     RETURNING * INTO v_city;
  ELSE
    -- Keep derived storage capacities current without rewriting resources.
    UPDATE public.cities
       SET metal_capacity = v_storage,
           energy_capacity = v_storage,
           water_capacity = v_storage,
           crystal_capacity = v_crystal_storage
     WHERE id = v_city.id
       AND (
         metal_capacity IS DISTINCT FROM v_storage
         OR energy_capacity IS DISTINCT FROM v_storage
         OR water_capacity IS DISTINCT FROM v_storage
         OR crystal_capacity IS DISTINCT FROM v_crystal_storage
       )
     RETURNING * INTO v_city;

    IF NOT FOUND THEN
      SELECT *
        INTO v_city
        FROM public.cities
       WHERE player_id = p_player_id
       ORDER BY id
       LIMIT 1;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'city', to_jsonb(v_city),
    'serverTime', v_now,
    'elapsedMinutes', v_elapsed_minutes,
    'production', jsonb_build_object(
      'metalPerMinute', v_metal_rate,
      'energyPerMinute', v_energy_rate,
      'waterPerMinute', v_water_rate,
      'crystalPerMinute', v_crystal_rate
    ),
    'capacities', jsonb_build_object(
      'storage', v_storage,
      'crystalStorage', v_crystal_storage
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_sync_city_production(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_sync_city_production(bigint)
  TO service_role;

COMMIT;
