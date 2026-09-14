-- NEXORA Phase 14.4.4
-- Unique city spawn coordinates for new registrations.
-- Fixes existing duplicate/default coordinates and prevents future overlap.

BEGIN;

-- 1) Move only duplicate/invalid city coordinates.
DO $$
DECLARE
  rec record;
  new_x integer;
  new_y integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('nexora_city_spawn'));

  FOR rec IN
    WITH ranked AS (
      SELECT
        id,
        player_id,
        coordinate_x,
        coordinate_y,
        ROW_NUMBER() OVER (
          PARTITION BY coordinate_x, coordinate_y
          ORDER BY id
        ) AS rn
      FROM public.cities
    )
    SELECT id, player_id
    FROM ranked
    WHERE rn > 1
       OR coordinate_x IS NULL
       OR coordinate_y IS NULL
       OR coordinate_x NOT BETWEEN 1 AND 100
       OR coordinate_y NOT BETWEEN 1 AND 100
    ORDER BY id
  LOOP
    new_x := NULL;
    new_y := NULL;

    -- Prefer a spaced grid so colony icons do not sit on top of each other.
    SELECT gx, gy
    INTO new_x, new_y
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
    ORDER BY md5(rec.player_id::text || ':' || gx::text || ':' || gy::text)
    LIMIT 1;

    -- Fallback to the full map if the spaced grid is ever exhausted.
    IF new_x IS NULL OR new_y IS NULL THEN
      SELECT gx, gy
      INTO new_x, new_y
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
      ORDER BY md5(rec.player_id::text || ':' || gx::text || ':' || gy::text)
      LIMIT 1;
    END IF;

    IF new_x IS NULL OR new_y IS NULL THEN
      RAISE EXCEPTION 'Dünya haritasında boş koloni koordinatı kalmadı.';
    END IF;

    UPDATE public.cities
    SET coordinate_x = new_x,
        coordinate_y = new_y,
        updated_at = clock_timestamp()
    WHERE id = rec.id;
  END LOOP;
END;
$$;

-- 2) Enforce one colony per exact map coordinate.
CREATE UNIQUE INDEX IF NOT EXISTS idx_cities_unique_coordinate
  ON public.cities(coordinate_x, coordinate_y)
  WHERE coordinate_x IS NOT NULL
    AND coordinate_y IS NOT NULL;

-- 3) Authoritative, concurrency-safe starting-city creation.
CREATE OR REPLACE FUNCTION public.nexora_create_starting_city(
  p_player_id bigint,
  p_name text DEFAULT 'Yeni Koloni'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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

  -- Serialize spawn allocation so two registrations cannot receive one point.
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
  ORDER BY md5(p_player_id::text || ':' || gx::text || ':' || gy::text)
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
    ORDER BY md5(p_player_id::text || ':' || gx::text || ':' || gy::text)
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
  ) VALUES (
    p_player_id,
    COALESCE(NULLIF(BTRIM(p_name), ''), 'Yeni Koloni'),
    1,
    1000,
    500,
    500,
    250,
    spawn_x,
    spawn_y
  )
  RETURNING * INTO created_city;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyExists', false,
    'city', to_jsonb(created_city)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_create_starting_city(bigint,text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_create_starting_city(bigint,text)
TO service_role;

COMMIT;
