-- NEXORA - First Day Economy V1
-- Migration 042
--
-- Goals:
-- - Give only newly created starting cities a playable first-hour economy.
-- - Seed non-transferable starter infrastructure instead of over-inflating liquid resources.
-- - Require Barracks level 1 before new unit training can start.
-- - Preserve all existing players, cities, resources, buildings, queues and missions.
-- - Keep registration spawn allocation concurrency-safe.
--
-- Apply after 041_new_player_pvp_protection_v1.sql.
-- No existing player/city rows are backfilled or rewritten.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) NEW STARTING CITY PACKAGE
--
-- Existing city rows are returned unchanged.
-- Only a player who has no city and reaches this RPC after this migration gets:
--   Resources: 2250 metal / 800 energy / 800 water / 300 crystal
--   Buildings: Merkez Bina 1, Metal Madeni 1, Enerji Santrali 1, Su Arıtma 1
--
-- Kristal Madeni intentionally remains locked behind the existing Merkez Bina 2
-- prerequisite so the normal progression tree is preserved.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_create_starting_city(
  p_player_id bigint,
  p_name text DEFAULT 'Yeni Koloni'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  existing_city public.cities%ROWTYPE;
  created_city public.cities%ROWTYPE;
  spawn_x integer;
  spawn_y integer;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  -- Preserve the existing registration spawn serialization.
  PERFORM pg_advisory_xact_lock(hashtext('nexora_city_spawn'));

  SELECT *
    INTO existing_city
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF existing_city.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyExists', true,
      'city', to_jsonb(existing_city)
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.players
     WHERE id = p_player_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  SELECT gx, gy
    INTO spawn_x, spawn_y
    FROM generate_series(3, 97, 3) AS gx
    CROSS JOIN generate_series(3, 97, 3) AS gy
   WHERE NOT EXISTS (
           SELECT 1
             FROM public.cities c
            WHERE c.coordinate_x = gx
              AND c.coordinate_y = gy
         )
     AND NOT EXISTS (
           SELECT 1
             FROM public.world_sites ws
            WHERE ws.active = true
              AND ws.coordinate_x = gx
              AND ws.coordinate_y = gy
         )
   ORDER BY md5(
     p_player_id::text || ':' || gx::text || ':' || gy::text
   )
   LIMIT 1;

  IF spawn_x IS NULL OR spawn_y IS NULL THEN
    SELECT gx, gy
      INTO spawn_x, spawn_y
      FROM generate_series(1, 100) AS gx
      CROSS JOIN generate_series(1, 100) AS gy
     WHERE NOT EXISTS (
             SELECT 1
               FROM public.cities c
              WHERE c.coordinate_x = gx
                AND c.coordinate_y = gy
           )
       AND NOT EXISTS (
             SELECT 1
               FROM public.world_sites ws
              WHERE ws.active = true
                AND ws.coordinate_x = gx
                AND ws.coordinate_y = gy
           )
     ORDER BY md5(
       p_player_id::text || ':' || gx::text || ':' || gy::text
     )
     LIMIT 1;
  END IF;

  IF spawn_x IS NULL OR spawn_y IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WORLD_FULL',
      'message', 'Dünya haritasında boş koloni koordinatı kalmadı.'
    );
  END IF;

  INSERT INTO public.cities(
    player_id,
    name,
    level,
    metal,
    energy,
    water,
    crystal,
    coordinate_x,
    coordinate_y
  )
  VALUES (
    p_player_id,
    COALESCE(NULLIF(BTRIM(p_name), ''), 'Yeni Koloni'),
    1,
    2250,
    800,
    800,
    300,
    spawn_x,
    spawn_y
  )
  RETURNING *
    INTO created_city;

  -- Starter infrastructure is created inside the same DB transaction as the
  -- city. Any unexpected failure here rolls the entire city creation back.
  INSERT INTO public.buildings(
    city_id,
    building_type,
    slot,
    level,
    is_under_construction,
    upgrade_ready_at
  )
  VALUES
    (created_city.id, 'Merkez Bina',       1, 1, false, NULL),
    (created_city.id, 'Metal Madeni',      1, 1, false, NULL),
    (created_city.id, 'Enerji Santrali',   1, 1, false, NULL),
    (created_city.id, 'Su Arıtma',         1, 1, false, NULL)
  ON CONFLICT (city_id, building_type, slot) DO NOTHING;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyExists', false,
    'city', to_jsonb(created_city)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.nexora_create_starting_city(
  bigint,
  text
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_create_starting_city(
  bigint,
  text
)
TO service_role;


-- -----------------------------------------------------------------------------
-- 2) BARRACKS REQUIREMENT FOR NEW UNIT TRAINING
--
-- Existing units, active missions and existing training queue rows are untouched.
-- Only starting a NEW unit-training request now requires Kışla level >= 1.
--
-- The remainder of the authoritative bulk-training function is preserved:
-- resource cost, MAX mode, population/army capacity, active-mission reservation,
-- training duration, queue insertion and atomic resource deduction.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_start_unit_training_bulk(
  p_player_id bigint,
  p_city_id bigint,
  p_type text,
  p_requested_quantity bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  c public.cities%ROWTYPE;
  q public.unit_production_queue%ROWTYPE;
  cfg record;

  spent jsonb;

  population bigint := 0;
  active_military bigint := 0;

  housing integer := 100;
  barracks integer := 0;
  army integer := 50;

  available_capacity bigint := 0;
  max_by_capacity bigint := 0;
  max_by_metal bigint := 0;
  max_by_energy bigint := 0;
  max_allowed bigint := 0;

  requested_quantity bigint := 0;
  actual_quantity bigint := 0;

  unit_duration integer := 0;
  total_duration bigint := 0;

  total_metal bigint := 0;
  total_energy bigint := 0;

  finish_time timestamptz;
BEGIN

  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  IF p_city_id IS NULL OR p_city_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_CITY',
      'message', 'Geçersiz koloni.'
    );
  END IF;

  IF p_requested_quantity IS NOT NULL
     AND (
       p_requested_quantity <= 0
       OR p_requested_quantity > 1000000
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_QUANTITY',
      'message', 'Geçersiz üretim adedi.'
    );
  END IF;


  -- City row is the serialization point shared with
  -- resource spending, military missions and population snapshots.
  SELECT *
    INTO c
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF c.id IS NULL OR c.id <> p_city_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;


  SELECT *
    INTO cfg
    FROM (
      VALUES
        ('piyade',  100,  20, 1, 20),
        ('savunma', 150,  40, 1, 24),
        ('saldiri',  200,  75, 1, 28),
        ('okcu',     220,  90, 1, 30),
        ('tank',     700, 220, 3, 55),
        ('hava',     650, 260, 2, 50)
    ) AS config(
      kind,
      metal,
      energy,
      pop,
      train
    )
   WHERE kind = p_type;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_UNIT',
      'message', 'Geçersiz birlik türü.'
    );
  END IF;


  housing := (
    SELECT
      100 +
      50 * GREATEST(
        0,
        COALESCE(
          (
            SELECT level
              FROM public.buildings
             WHERE city_id = c.id
               AND building_type = 'Konut'
             ORDER BY id
             LIMIT 1
          ),
          0
        )
      )
  );


  barracks := (
    SELECT GREATEST(
      0,
      COALESCE(
        (
          SELECT level
            FROM public.buildings
           WHERE city_id = c.id
             AND building_type = 'Kışla'
           ORDER BY id
           LIMIT 1
        ),
        0
      )
    )
  );


  IF barracks < 1 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'BARRACKS_REQUIRED',
      'message', 'Birlik üretmek için Kışla seviye 1 gerekli.',
      'required', jsonb_build_object(
        'building', 'Kışla',
        'level', 1
      ),
      'maxQuantity', 0
    );
  END IF;


  army := 50 + 50 * barracks;


  -- Current army + current training queue.
  population := (
    SELECT COALESCE(SUM(amount), 0)::bigint
      FROM (

        SELECT
          quantity::bigint *
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
          quantity::bigint *
          CASE unit_type
            WHEN 'tank' THEN 3
            WHEN 'hava' THEN 2
            ELSE 1
          END AS amount
          FROM public.unit_production_queue
         WHERE city_id = c.id
           AND player_id = p_player_id
           AND status = 'training'

      ) pop
  );


  -- This helper was extended by PvE V1, so both PvP and active NPC armies
  -- continue to reserve capacity exactly as before.
  active_military := GREATEST(
    0,
    COALESCE(
      public.nexora_active_military_population(
        p_player_id
      ),
      0
    )
  );


  population :=
    GREATEST(0, population)
    + active_military;


  available_capacity := GREATEST(
    0,
    LEAST(
      housing::bigint - population,
      army::bigint - population
    )
  );


  max_by_capacity :=
    FLOOR(
      available_capacity::numeric /
      cfg.pop::numeric
    )::bigint;


  max_by_metal :=
    FLOOR(
      GREATEST(
        0,
        COALESCE(c.metal, 0)
      )::numeric /
      cfg.metal::numeric
    )::bigint;


  max_by_energy :=
    FLOOR(
      GREATEST(
        0,
        COALESCE(c.energy, 0)
      )::numeric /
      cfg.energy::numeric
    )::bigint;


  max_allowed := GREATEST(
    0,
    LEAST(
      max_by_capacity,
      max_by_metal,
      max_by_energy,
      1000000::bigint
    )
  );


  IF max_allowed <= 0 THEN

    IF max_by_capacity <= 0 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'CAPACITY_FULL',
        'message',
          CASE
            WHEN population >= housing
              THEN 'Konut kapasitesi yetersiz.'
            ELSE 'Kışla/ordu kapasitesi yetersiz.'
          END,
        'population', population,
        'population_capacity', housing,
        'army_capacity', army,
        'maxQuantity', 0
      );
    END IF;

    RETURN jsonb_build_object(
      'success', false,
      'code', 'INSUFFICIENT_RESOURCES',
      'message', 'Bu birlik için yeterli kaynak yok.',
      'maxQuantity', 0,
      'available', jsonb_build_object(
        'metal', GREATEST(0, COALESCE(c.metal, 0)),
        'energy', GREATEST(0, COALESCE(c.energy, 0))
      )
    );

  END IF;


  -- NULL means MAX mode.
  requested_quantity :=
    COALESCE(
      p_requested_quantity,
      max_allowed
    );


  -- Requested amount can be higher than current resources/capacity.
  -- In that case admit the maximum safe amount.
  actual_quantity :=
    LEAST(
      requested_quantity,
      max_allowed
    );


  IF actual_quantity <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOTHING_TO_TRAIN',
      'message', 'Üretilebilecek birlik bulunamadı.'
    );
  END IF;


  total_metal :=
    actual_quantity *
    cfg.metal::bigint;

  total_energy :=
    actual_quantity *
    cfg.energy::bigint;


  -- Atomic resource deduction.
  spent :=
    public.nexora_spend_city_resources(
      p_player_id,
      total_metal,
      total_energy,
      0,
      0
    );


  IF NOT COALESCE(
    (spent->>'success')::boolean,
    false
  ) THEN
    RETURN spent;
  END IF;


  -- Preserve existing Barracks training-speed formula.
  unit_duration :=
    GREATEST(
      10,
      ROUND(
        cfg.train *
        GREATEST(
          0.35,
          1 - GREATEST(1, barracks) * 0.04
        )
      )::integer
    );


  total_duration :=
    unit_duration::bigint *
    actual_quantity;


  finish_time :=
    clock_timestamp() +
    make_interval(
      secs => total_duration::double precision
    );


  INSERT INTO public.unit_production_queue(
    player_id,
    city_id,
    unit_type,
    quantity,
    finish_at
  )
  VALUES(
    p_player_id,
    c.id,
    p_type,
    actual_quantity::integer,
    finish_time
  )
  RETURNING *
    INTO q;


  RETURN spent ||
    jsonb_build_object(
      'success', true,

      'production',
        to_jsonb(q),

      'requestedQuantity',
        p_requested_quantity,

      'acceptedQuantity',
        actual_quantity,

      'maxQuantity',
        max_allowed,

      'unitDurationSeconds',
        unit_duration,

      'totalDurationSeconds',
        total_duration,

      'finishAt',
        finish_time,

      'population',
        population,

      'populationAfter',
        population +
        actual_quantity * cfg.pop::bigint,

      'population_capacity',
        housing,

      'army_capacity',
        army,

      'cost',
        jsonb_build_object(
          'metal', total_metal,
          'energy', total_energy,
          'water', 0,
          'crystal', 0
        )
    );

END;
$function$;


REVOKE ALL ON FUNCTION public.nexora_start_unit_training_bulk(
  bigint,
  bigint,
  text,
  bigint
)
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE ON FUNCTION public.nexora_start_unit_training_bulk(
  bigint,
  bigint,
  text,
  bigint
)
TO service_role;


COMMIT;
