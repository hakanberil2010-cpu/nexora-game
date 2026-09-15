-- NEXORA - Alliance Region Bonuses V1 infrastructure
-- Additive / production-safe migration.
--
-- Region ownership rule:
--   * Every colony belongs to the nearest existing world-map region anchor.
--   * The alliance with the highest colony count in a region controls it.
--   * If the highest count is tied, the region is contested and has no controller.
--   * A region bonus is active for a player only when that player's alliance
--     controls the region containing that player's colony.
--
-- This migration only adds authoritative region/control helper RPCs.
-- Resource / defense / travel effects are wired into gameplay in the matching
-- backend / production changes after this migration is live.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) AUTHORITATIVE REGION CLASSIFIER
-- Keep the anchors and tie priority identical to regionForCoordinates() in
-- api/auth.js: Desert, Forest, Ice, Mountain, Volcanic, Ocean.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_region_key(
  p_x numeric,
  p_y numeric
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT r.region_key
  FROM (
    VALUES
      ('desert'::text,   1, 10::numeric, 18::numeric),
      ('forest'::text,   2, 42::numeric, 12::numeric),
      ('ice'::text,      3, 91::numeric, 17::numeric),
      ('mountain'::text, 4, 30::numeric, 83::numeric),
      ('volcanic'::text, 5, 72::numeric, 85::numeric),
      ('ocean'::text,    6, 95::numeric, 55::numeric)
  ) AS r(region_key, priority, anchor_x, anchor_y)
  ORDER BY
    (COALESCE(p_x,0) - r.anchor_x) * (COALESCE(p_x,0) - r.anchor_x)
    +
    (COALESCE(p_y,0) - r.anchor_y) * (COALESCE(p_y,0) - r.anchor_y),
    r.priority
  LIMIT 1;
$$;


-- -----------------------------------------------------------------------------
-- 2) REGION CONTROLLER
-- Only alliance-member colonies participate in alliance control.
-- A tie for first place means the region is contested and nobody receives the
-- controller bonus until one alliance has a unique lead.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_alliance_region_controller(
  p_region_key text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_region_key text := lower(btrim(COALESCE(p_region_key,'')));
  v_top_count integer := 0;
  v_top_alliance_id bigint;
  v_tie_count integer := 0;
  v_alliance_name text;
  v_alliance_tag text;
BEGIN
  IF v_region_key NOT IN (
    'desert','forest','ice','mountain','volcanic','ocean'
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_REGION',
      'message', 'Geçersiz bölge.'
    );
  END IF;

  WITH counts AS (
    SELECT
      am.alliance_id,
      COUNT(DISTINCT c.id)::integer AS colony_count
    FROM public.alliance_members am
    JOIN public.cities c
      ON c.player_id = am.player_id
    WHERE public.nexora_region_key(
      COALESCE(c.coordinate_x,0),
      COALESCE(c.coordinate_y,0)
    ) = v_region_key
    GROUP BY am.alliance_id
  )
  SELECT alliance_id, colony_count
  INTO v_top_alliance_id, v_top_count
  FROM counts
  ORDER BY colony_count DESC, alliance_id ASC
  LIMIT 1;

  IF v_top_alliance_id IS NULL OR COALESCE(v_top_count,0) <= 0 THEN
    RETURN jsonb_build_object(
      'success', true,
      'regionKey', v_region_key,
      'controllerAllianceId', NULL,
      'controllerAllianceName', NULL,
      'controllerAllianceTag', NULL,
      'controllerColonyCount', 0,
      'contested', false
    );
  END IF;

  WITH counts AS (
    SELECT
      am.alliance_id,
      COUNT(DISTINCT c.id)::integer AS colony_count
    FROM public.alliance_members am
    JOIN public.cities c
      ON c.player_id = am.player_id
    WHERE public.nexora_region_key(
      COALESCE(c.coordinate_x,0),
      COALESCE(c.coordinate_y,0)
    ) = v_region_key
    GROUP BY am.alliance_id
  )
  SELECT COUNT(*)::integer
  INTO v_tie_count
  FROM counts
  WHERE colony_count = v_top_count;

  IF v_tie_count > 1 THEN
    RETURN jsonb_build_object(
      'success', true,
      'regionKey', v_region_key,
      'controllerAllianceId', NULL,
      'controllerAllianceName', NULL,
      'controllerAllianceTag', NULL,
      'controllerColonyCount', v_top_count,
      'contested', true
    );
  END IF;

  SELECT a.name, a.tag
  INTO v_alliance_name, v_alliance_tag
  FROM public.alliances a
  WHERE a.id = v_top_alliance_id
  LIMIT 1;

  RETURN jsonb_build_object(
    'success', true,
    'regionKey', v_region_key,
    'controllerAllianceId', v_top_alliance_id,
    'controllerAllianceName', v_alliance_name,
    'controllerAllianceTag', v_alliance_tag,
    'controllerColonyCount', v_top_count,
    'contested', false
  );
END;
$$;


-- -----------------------------------------------------------------------------
-- 3) ONE PLAYER'S ACTIVE TERRITORY BONUS
-- This is the small authoritative helper that production, battle and travel
-- code can call. It does not trust any region/alliance value from the client.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_player_alliance_region_bonus(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_city public.cities%ROWTYPE;
  v_alliance_id bigint;
  v_region_key text;
  v_region_name text;
  v_bonus_key text;
  v_bonus_text text;
  v_controller jsonb;
  v_controller_id bigint;
  v_active boolean := false;
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
  LIMIT 1;

  IF v_city.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  SELECT am.alliance_id
  INTO v_alliance_id
  FROM public.alliance_members am
  WHERE am.player_id = p_player_id
  ORDER BY am.id
  LIMIT 1;

  v_region_key := public.nexora_region_key(
    COALESCE(v_city.coordinate_x,0),
    COALESCE(v_city.coordinate_y,0)
  );

  SELECT
    CASE v_region_key
      WHEN 'desert' THEN 'Çöl Bölgesi'
      WHEN 'forest' THEN 'Orman Bölgesi'
      WHEN 'ice' THEN 'Buz Bölgesi'
      WHEN 'mountain' THEN 'Dağ Bölgesi'
      WHEN 'volcanic' THEN 'Volkanik Bölge'
      WHEN 'ocean' THEN 'Okyanus'
    END,
    CASE v_region_key
      WHEN 'desert' THEN 'metal_production'
      WHEN 'forest' THEN 'water_production'
      WHEN 'ice' THEN 'energy_production'
      WHEN 'mountain' THEN 'defense'
      WHEN 'volcanic' THEN 'crystal_production'
      WHEN 'ocean' THEN 'travel_speed'
    END,
    CASE v_region_key
      WHEN 'desert' THEN 'Metal üretimi +5%'
      WHEN 'forest' THEN 'Su üretimi +5%'
      WHEN 'ice' THEN 'Enerji üretimi +5%'
      WHEN 'mountain' THEN 'Savunma +5%'
      WHEN 'volcanic' THEN 'Kristal üretimi +5%'
      WHEN 'ocean' THEN 'Seyahat süresi -5%'
    END
  INTO v_region_name, v_bonus_key, v_bonus_text;

  v_controller := public.nexora_alliance_region_controller(v_region_key);

  BEGIN
    v_controller_id := NULLIF(
      v_controller->>'controllerAllianceId',
      ''
    )::bigint;
  EXCEPTION WHEN OTHERS THEN
    v_controller_id := NULL;
  END;

  v_active :=
    v_alliance_id IS NOT NULL
    AND v_controller_id IS NOT NULL
    AND v_alliance_id = v_controller_id
    AND COALESCE((v_controller->>'contested')::boolean,false) = false;

  RETURN jsonb_build_object(
    'success', true,
    'playerId', p_player_id,
    'cityId', v_city.id,
    'regionKey', v_region_key,
    'regionName', v_region_name,
    'allianceId', v_alliance_id,
    'controllerAllianceId', v_controller_id,
    'controllerAllianceName', v_controller->>'controllerAllianceName',
    'controllerAllianceTag', v_controller->>'controllerAllianceTag',
    'controllerColonyCount', COALESCE((v_controller->>'controllerColonyCount')::integer,0),
    'contested', COALESCE((v_controller->>'contested')::boolean,false),
    'active', v_active,
    'bonusKey', v_bonus_key,
    'bonusPercent', 5,
    'bonusText', v_bonus_text
  );
END;
$$;


-- -----------------------------------------------------------------------------
-- 4) FULL REGION SNAPSHOT FOR WORLD / ALLIANCE UI
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_alliance_region_control(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_player_alliance_id bigint;
  v_regions jsonb := '[]'::jsonb;
  v_controller jsonb;
  v_key text;
  v_name text;
  v_bonus_key text;
  v_bonus_text text;
  v_controller_id bigint;
  v_mine boolean;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  SELECT am.alliance_id
  INTO v_player_alliance_id
  FROM public.alliance_members am
  WHERE am.player_id = p_player_id
  ORDER BY am.id
  LIMIT 1;

  FOR v_key, v_name, v_bonus_key, v_bonus_text IN
    SELECT *
    FROM (
      VALUES
        ('desert'::text,   'Çöl Bölgesi'::text,      'metal_production'::text,   'Metal üretimi +5%'::text, 1),
        ('forest'::text,   'Orman Bölgesi'::text,    'water_production'::text,   'Su üretimi +5%'::text, 2),
        ('ice'::text,      'Buz Bölgesi'::text,      'energy_production'::text,  'Enerji üretimi +5%'::text, 3),
        ('mountain'::text, 'Dağ Bölgesi'::text,      'defense'::text,            'Savunma +5%'::text, 4),
        ('volcanic'::text, 'Volkanik Bölge'::text,   'crystal_production'::text, 'Kristal üretimi +5%'::text, 5),
        ('ocean'::text,    'Okyanus'::text,          'travel_speed'::text,       'Seyahat süresi -5%'::text, 6)
    ) AS defs(region_key, region_name, bonus_key, bonus_text, priority)
    ORDER BY priority
  LOOP
    v_controller := public.nexora_alliance_region_controller(v_key);

    BEGIN
      v_controller_id := NULLIF(
        v_controller->>'controllerAllianceId',
        ''
      )::bigint;
    EXCEPTION WHEN OTHERS THEN
      v_controller_id := NULL;
    END;

    v_mine :=
      v_player_alliance_id IS NOT NULL
      AND v_controller_id IS NOT NULL
      AND v_player_alliance_id = v_controller_id
      AND COALESCE((v_controller->>'contested')::boolean,false) = false;

    v_regions := v_regions || jsonb_build_array(
      jsonb_build_object(
        'regionKey', v_key,
        'regionName', v_name,
        'bonusKey', v_bonus_key,
        'bonusPercent', 5,
        'bonusText', v_bonus_text,
        'controllerAllianceId', v_controller_id,
        'controllerAllianceName', v_controller->>'controllerAllianceName',
        'controllerAllianceTag', v_controller->>'controllerAllianceTag',
        'controllerColonyCount', COALESCE((v_controller->>'controllerColonyCount')::integer,0),
        'contested', COALESCE((v_controller->>'contested')::boolean,false),
        'controlledByPlayerAlliance', v_mine
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'playerAllianceId', v_player_alliance_id,
    'regions', v_regions
  );
END;
$$;


-- -----------------------------------------------------------------------------
-- 5) PERMISSIONS
-- -----------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.nexora_region_key(numeric,numeric)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.nexora_alliance_region_controller(text)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.nexora_player_alliance_region_bonus(bigint)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.nexora_alliance_region_control(bigint)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_region_key(numeric,numeric)
TO service_role;

GRANT EXECUTE ON FUNCTION public.nexora_alliance_region_controller(text)
TO service_role;

GRANT EXECUTE ON FUNCTION public.nexora_player_alliance_region_bonus(bigint)
TO service_role;

GRANT EXECUTE ON FUNCTION public.nexora_alliance_region_control(bigint)
TO service_role;

COMMIT;
