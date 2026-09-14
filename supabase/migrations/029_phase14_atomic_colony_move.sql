-- NEXORA Phase 14.7
-- Atomic colony movement.
-- Apply AFTER 028 and BEFORE deploying the matching api/auth.js.
--
-- Goals:
-- - Serialize colony movement with registration spawn allocation.
-- - Serialize movement with military mission start/return through the city row lock.
-- - Prevent moves onto another colony or an active world site.
-- - Preserve the existing rule: a player cannot move while their own military
--   mission is traveling/resolving/returning.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_move_colony_atomic(
  p_player_id bigint,
  p_x integer,
  p_y integer
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_city public.cities%ROWTYPE;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  IF p_x IS NULL OR p_y IS NULL
     OR p_x NOT BETWEEN 1 AND 100
     OR p_y NOT BETWEEN 1 AND 100 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_COORDINATE',
      'message', 'X ve Y koordinatları 1-100 arasında tam sayı olmalı.'
    );
  END IF;

  -- Use the same allocator lock as Phase 14.4.4 city spawn.
  -- This prevents a registration spawn and a colony move from selecting
  -- the same free coordinate at the same time.
  PERFORM pg_advisory_xact_lock(hashtext('nexora_city_spawn'));

  -- The city row is also the serialization point used by military mission
  -- start/return flows. Once this lock is held, the active-mission check below
  -- cannot race with a new mission start for the same player.
  SELECT *
  INTO v_city
  FROM public.cities
  WHERE player_id = p_player_id
  ORDER BY id
  LIMIT 1
  FOR UPDATE;

  IF v_city.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  IF COALESCE(v_city.coordinate_x, 0) = p_x
     AND COALESCE(v_city.coordinate_y, 0) = p_y THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SAME_COORDINATE',
      'message', 'Zaten bu koordinattasın.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.military_missions
    WHERE attacker_player_id = p_player_id
      AND status IN ('traveling', 'resolving', 'returning')
    LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVE_MISSION',
      'message', 'Aktif askeri sefer varken koloni koordinatı değiştirilemez.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.world_sites
    WHERE active = true
      AND coordinate_x = p_x
      AND coordinate_y = p_y
    LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WORLD_SITE_OCCUPIED',
      'message', 'Bu koordinatta aktif bir dünya noktası bulunuyor.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.cities
    WHERE id <> v_city.id
      AND coordinate_x = p_x
      AND coordinate_y = p_y
    LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'COORDINATE_OCCUPIED',
      'message', 'Bu koordinat dolu.'
    );
  END IF;

  UPDATE public.cities
  SET coordinate_x = p_x,
      coordinate_y = p_y,
      updated_at = clock_timestamp()
  WHERE id = v_city.id
  RETURNING * INTO v_city;

  RETURN jsonb_build_object(
    'success', true,
    'code', 'MOVED',
    'message', 'Koloni taşındı.',
    'city', to_jsonb(v_city)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_move_colony_atomic(bigint,integer,integer)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_move_colony_atomic(bigint,integer,integer)
TO service_role;

COMMIT;
