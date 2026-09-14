-- NEXORA - Multi-building slot infrastructure
-- Adds safe support for a second Metal/Energy/Water/Crystal producer and a second Depo.
-- Existing buildings remain slot 1. Merkez Bina, Sur and other buildings remain single-slot.
-- This migration intentionally does NOT rename Savunma Kulesi yet; that conversion is done
-- together with the matching backend change so live defense behavior is never temporarily lost.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) BUILDING INSTANCE SLOT
-- Existing rows become slot 1 without changing their levels or construction state.
-- -----------------------------------------------------------------------------

ALTER TABLE public.buildings
  ADD COLUMN IF NOT EXISTS slot integer NOT NULL DEFAULT 1;

UPDATE public.buildings
SET slot = 1
WHERE slot IS NULL;

-- Remove any legacy UNIQUE(city_id, building_type) constraint, if one exists.
-- It would otherwise prevent slot 2 rows.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname
    FROM pg_constraint c
    WHERE c.conrelid = 'public.buildings'::regclass
      AND c.contype = 'u'
      AND (
        SELECT array_agg(a.attname ORDER BY a.attname)
        FROM unnest(c.conkey) AS k(attnum)
        JOIN pg_attribute a
          ON a.attrelid = c.conrelid
         AND a.attnum = k.attnum
      ) = ARRAY['building_type','city_id']::name[]
  LOOP
    EXECUTE format(
      'ALTER TABLE public.buildings DROP CONSTRAINT %I',
      r.conname
    );
  END LOOP;
END $$;

-- Remove an equivalent standalone unique index, if the legacy schema used one
-- instead of a table constraint.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT
      n.nspname AS schema_name,
      ci.relname AS index_name
    FROM pg_index i
    JOIN pg_class t
      ON t.oid = i.indrelid
    JOIN pg_namespace tn
      ON tn.oid = t.relnamespace
    JOIN pg_class ci
      ON ci.oid = i.indexrelid
    JOIN pg_namespace n
      ON n.oid = ci.relnamespace
    WHERE tn.nspname = 'public'
      AND t.relname = 'buildings'
      AND i.indisunique
      AND NOT i.indisprimary
      AND i.indexprs IS NULL
      AND i.indpred IS NULL
      AND (
        SELECT array_agg(a.attname ORDER BY a.attname)
        FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a
          ON a.attrelid = i.indrelid
         AND a.attnum = k.attnum
        WHERE k.attnum > 0
      ) = ARRAY['building_type','city_id']::name[]
  LOOP
    EXECUTE format(
      'DROP INDEX IF EXISTS %I.%I',
      r.schema_name,
      r.index_name
    );
  END LOOP;
END $$;

ALTER TABLE public.buildings
  DROP CONSTRAINT IF EXISTS buildings_slot_check;

ALTER TABLE public.buildings
  ADD CONSTRAINT buildings_slot_check
  CHECK (
    slot = 1
    OR (
      slot = 2
      AND building_type IN (
        'Metal Madeni',
        'Enerji Santrali',
        'Su Arıtma',
        'Kristal Madeni',
        'Depo'
      )
    )
  );

CREATE UNIQUE INDEX IF NOT EXISTS idx_buildings_city_type_slot_unique
  ON public.buildings(city_id, building_type, slot);

CREATE INDEX IF NOT EXISTS idx_buildings_city_slot
  ON public.buildings(city_id, slot, building_type);


-- -----------------------------------------------------------------------------
-- 2) SLOT-AWARE BUILDING UPGRADE RPC
-- The current six-argument nexora_start_building_upgrade remains untouched for
-- compatibility during rollout. The backend will switch to this new RPC next.
--
-- Unlock rules:
--   Slot 2 resource producers -> Merkez Bina level 5
--   Slot 2 Depo               -> Merkez Bina level 7
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_start_building_upgrade_slot(
  p_player_id bigint,
  p_city_id bigint,
  p_type text,
  p_slot integer,
  p_level integer,
  p_cost jsonb,
  p_duration integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c public.cities%ROWTYPE;
  b public.buildings%ROWTYPE;
  spent jsonb;
  ready timestamptz;
  center_level integer := 0;
BEGIN
  IF p_slot IS NULL OR p_slot NOT IN (1,2) THEN
    RAISE EXCEPTION 'Geçersiz bina yuvası.';
  END IF;

  IF p_slot = 2
     AND p_type NOT IN (
       'Metal Madeni',
       'Enerji Santrali',
       'Su Arıtma',
       'Kristal Madeni',
       'Depo'
     ) THEN
    RAISE EXCEPTION 'Bu bina türünün ikinci kopyası olamaz.';
  END IF;

  SELECT *
    INTO c
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF c.id IS NULL OR c.id <> p_city_id THEN
    RAISE EXCEPTION 'Koloni bulunamadı.';
  END IF;

  SELECT COALESCE(MAX(level),0)::integer
    INTO center_level
    FROM public.buildings
   WHERE city_id = c.id
     AND building_type = 'Merkez Bina'
     AND slot = 1;

  IF p_slot = 2 THEN
    IF p_type = 'Depo' AND center_level < 7 THEN
      RETURN jsonb_build_object(
        'success', false,
        'message', 'Depo II için Merkez Bina seviye 7 gerekli.',
        'required', jsonb_build_object(
          'building', 'Merkez Bina',
          'level', 7
        )
      );
    END IF;

    IF p_type IN (
         'Metal Madeni',
         'Enerji Santrali',
         'Su Arıtma',
         'Kristal Madeni'
       )
       AND center_level < 5 THEN
      RETURN jsonb_build_object(
        'success', false,
        'message', p_type || ' II için Merkez Bina seviye 5 gerekli.',
        'required', jsonb_build_object(
          'building', 'Merkez Bina',
          'level', 5
        )
      );
    END IF;
  END IF;

  SELECT *
    INTO b
    FROM public.buildings
   WHERE city_id = c.id
     AND building_type = p_type
     AND slot = p_slot
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF COALESCE(b.is_under_construction,false)
     OR COALESCE(b.level,0) IS DISTINCT FROM p_level THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Bina durumu değişti; tekrar yükle.'
    );
  END IF;

  IF p_level IS NULL
     OR p_level < 0
     OR p_duration IS NULL
     OR p_duration <= 0 THEN
    RAISE EXCEPTION 'Geçersiz inşaat.';
  END IF;

  spent := public.nexora_spend_city_resources(
    p_player_id,
    (p_cost->>'metal')::bigint,
    (p_cost->>'energy')::bigint,
    (p_cost->>'water')::bigint,
    (p_cost->>'crystal')::bigint
  );

  IF NOT (spent->>'success')::boolean THEN
    RETURN spent;
  END IF;

  ready := clock_timestamp() + make_interval(secs => p_duration);

  IF b.id IS NULL THEN
    INSERT INTO public.buildings(
      city_id,
      building_type,
      slot,
      level,
      is_under_construction,
      upgrade_ready_at
    )
    VALUES(
      c.id,
      p_type,
      p_slot,
      0,
      true,
      ready
    )
    RETURNING * INTO b;
  ELSE
    UPDATE public.buildings
       SET is_under_construction = true,
           upgrade_ready_at = ready
     WHERE id = b.id
     RETURNING * INTO b;
  END IF;

  RETURN spent || jsonb_build_object(
    'building', to_jsonb(b),
    'finishAt', ready
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_start_building_upgrade_slot(
  bigint,bigint,text,integer,integer,jsonb,integer
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_start_building_upgrade_slot(
  bigint,bigint,text,integer,integer,jsonb,integer
) TO service_role;


-- -----------------------------------------------------------------------------
-- 3) PRODUCTION / STORAGE NOW SUMS MULTIPLE BUILDING INSTANCES
-- Slot 1 behavior is unchanged. Slot 2 contributes immediately once its level
-- is completed, without requiring slot 1 to reach maximum level.
-- -----------------------------------------------------------------------------

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
    COALESCE(SUM(level) FILTER (
      WHERE building_type = 'Metal Madeni'
    ),0)::integer,
    COALESCE(SUM(level) FILTER (
      WHERE building_type = 'Enerji Santrali'
    ),0)::integer,
    COALESCE(SUM(level) FILTER (
      WHERE building_type = 'Su Arıtma'
    ),0)::integer,
    COALESCE(SUM(level) FILTER (
      WHERE building_type = 'Kristal Madeni'
    ),0)::integer,
    COALESCE(SUM(level) FILTER (
      WHERE building_type = 'Depo'
    ),0)::integer,
    COALESCE(MAX(level) FILTER (
      WHERE building_type = 'Kristal Deposu'
    ),0)::integer
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
    COALESCE(production_level,0),
    COALESCE(crystal_level,0)
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

  v_storage :=
    5000 + GREATEST(0,v_depo_level) * 2500;

  v_crystal_storage :=
    3000 + GREATEST(0,v_crystal_depo_level) * 1500;

  v_metal_rate :=
    GREATEST(0,v_metal_level) * 10
    * (1 + GREATEST(0,v_production_research) * 0.10);

  v_energy_rate :=
    GREATEST(0,v_energy_level) * 10
    * (1 + GREATEST(0,v_production_research) * 0.10);

  v_water_rate :=
    GREATEST(0,v_water_level) * 10
    * (1 + GREATEST(0,v_production_research) * 0.10);

  v_crystal_rate :=
    GREATEST(0,v_crystal_level) * 5
    * (1 + GREATEST(0,v_crystal_research) * 0.08);

  v_last := COALESCE(
    v_city.last_production_at,
    v_city.updated_at,
    v_now
  );

  v_elapsed_minutes := GREATEST(
    0,
    FLOOR(
      EXTRACT(EPOCH FROM (v_now - v_last)) / 60
    )::integer
  );

  IF v_elapsed_minutes > 0 THEN
    v_add_metal :=
      FLOOR(v_metal_rate * v_elapsed_minutes)::bigint;
    v_add_energy :=
      FLOOR(v_energy_rate * v_elapsed_minutes)::bigint;
    v_add_water :=
      FLOOR(v_water_rate * v_elapsed_minutes)::bigint;
    v_add_crystal :=
      FLOOR(v_crystal_rate * v_elapsed_minutes)::bigint;

    UPDATE public.cities
       SET metal = LEAST(
             v_storage,
             GREATEST(
               0,
               COALESCE(metal,0) + v_add_metal
             )
           ),
           energy = LEAST(
             v_storage,
             GREATEST(
               0,
               COALESCE(energy,0) + v_add_energy
             )
           ),
           water = LEAST(
             v_storage,
             GREATEST(
               0,
               COALESCE(water,0) + v_add_water
             )
           ),
           crystal = LEAST(
             v_crystal_storage,
             GREATEST(
               0,
               COALESCE(crystal,0) + v_add_crystal
             )
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


-- -----------------------------------------------------------------------------
-- 4) TRADE CAPACITY MUST USE THE SAME SUMMED DEPO LEVEL
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_trade_storage_capacity(
  p_city_id bigint,
  p_resource text
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_depo integer := 0;
  v_crystal_depo integer := 0;
BEGIN
  SELECT
    COALESCE(SUM(level) FILTER (
      WHERE building_type = 'Depo'
    ),0)::integer,
    COALESCE(MAX(level) FILTER (
      WHERE building_type = 'Kristal Deposu'
    ),0)::integer
  INTO
    v_depo,
    v_crystal_depo
  FROM public.buildings
  WHERE city_id = p_city_id;

  IF p_resource = 'crystal' THEN
    RETURN
      3000 + GREATEST(0,v_crystal_depo) * 1500;
  END IF;

  RETURN
    5000 + GREATEST(0,v_depo) * 2500;
END;
$$;


-- -----------------------------------------------------------------------------
-- 5) SANITY CHECKS
-- These raise only if the migration itself left invalid building rows.
-- -----------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.buildings
    WHERE slot NOT IN (1,2)
  ) THEN
    RAISE EXCEPTION 'Geçersiz bina slotu bulundu.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.buildings
    GROUP BY city_id, building_type, slot
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Aynı bina slotunda birden fazla kayıt bulundu.';
  END IF;
END $$;

COMMIT;
