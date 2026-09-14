-- NEXORA - Espionage V1 infrastructure
-- Additive / production-safe migration. No DROP/TRUNCATE.
-- Run after 033_watchtower_rename.sql.

BEGIN;

CREATE TABLE IF NOT EXISTS public.espionage_missions (
  id bigserial PRIMARY KEY,
  attacker_player_id bigint NOT NULL,
  defender_player_id bigint NOT NULL,
  attacker_city_id bigint NOT NULL,
  defender_city_id bigint NOT NULL,
  status text NOT NULL DEFAULT 'traveling',
  depart_at timestamptz NOT NULL DEFAULT now(),
  arrive_at timestamptz NOT NULL,
  completed_at timestamptz,
  distance numeric NOT NULL DEFAULT 0,
  travel_seconds integer NOT NULL DEFAULT 0,
  attacker_watchtower_level integer NOT NULL DEFAULT 0,
  defender_watchtower_level integer NOT NULL DEFAULT 0,
  detected boolean,
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- If a draft table existed before this migration, complete it safely.
ALTER TABLE public.espionage_missions
  ADD COLUMN IF NOT EXISTS attacker_player_id bigint,
  ADD COLUMN IF NOT EXISTS defender_player_id bigint,
  ADD COLUMN IF NOT EXISTS attacker_city_id bigint,
  ADD COLUMN IF NOT EXISTS defender_city_id bigint,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'traveling',
  ADD COLUMN IF NOT EXISTS depart_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS arrive_at timestamptz,
  ADD COLUMN IF NOT EXISTS completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS distance numeric DEFAULT 0,
  ADD COLUMN IF NOT EXISTS travel_seconds integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS attacker_watchtower_level integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS defender_watchtower_level integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS detected boolean,
  ADD COLUMN IF NOT EXISTS result jsonb,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_espionage_attacker_status
  ON public.espionage_missions(attacker_player_id, status, arrive_at DESC);

CREATE INDEX IF NOT EXISTS idx_espionage_defender_status
  ON public.espionage_missions(defender_player_id, status, arrive_at DESC);

CREATE INDEX IF NOT EXISTS idx_espionage_arrive_at
  ON public.espionage_missions(arrive_at);

-- Espionage data is server-side only. The backend uses the service role.
ALTER TABLE public.espionage_missions ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- Start an espionage mission.
-- One active espionage mission per attacker is allowed.
-- The attacker's watchtower level is frozen at departure time.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.nexora_start_espionage(
  p_attacker_player_id bigint,
  p_defender_player_id bigint,
  p_travel_seconds integer,
  p_distance numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_attacker_city public.cities%ROWTYPE;
  v_defender_city public.cities%ROWTYPE;
  v_existing public.espionage_missions%ROWTYPE;
  v_mission public.espionage_missions%ROWTYPE;
  v_attacker_watchtower integer := 0;
  v_defender_watchtower integer := 0;
  v_seconds integer;
  v_distance numeric;
BEGIN
  IF p_attacker_player_id IS NULL OR p_attacker_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ATTACKER',
      'message', 'Geçersiz casusluk gönderen oyuncu.'
    );
  END IF;

  IF p_defender_player_id IS NULL OR p_defender_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_TARGET',
      'message', 'Geçersiz casusluk hedefi.'
    );
  END IF;

  IF p_attacker_player_id = p_defender_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SELF_TARGET',
      'message', 'Kendi kolonine casus gönderemezsin.'
    );
  END IF;

  -- Lock the attacker's city so simultaneous start requests serialize.
  SELECT *
    INTO v_attacker_city
    FROM public.cities
   WHERE player_id = p_attacker_player_id
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

  SELECT *
    INTO v_defender_city
    FROM public.cities
   WHERE player_id = p_defender_player_id
   ORDER BY id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_CITY_NOT_FOUND',
      'message', 'Hedef koloni bulunamadı.'
    );
  END IF;

  SELECT COALESCE(
    MAX(
      GREATEST(0, COALESCE(level, 0)) +
      CASE
        WHEN COALESCE(is_under_construction, false) = true
         AND upgrade_ready_at IS NOT NULL
         AND upgrade_ready_at <= now()
        THEN 1
        ELSE 0
      END
    ),
    0
  )
  INTO v_attacker_watchtower
  FROM public.buildings
  WHERE city_id = v_attacker_city.id
    AND building_type = 'Gözcü Kulesi';

  IF v_attacker_watchtower < 1 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WATCHTOWER_REQUIRED',
      'message', 'Casus göndermek için Gözcü Kulesi seviye 1 gerekli.'
    );
  END IF;

  SELECT *
    INTO v_existing
    FROM public.espionage_missions
   WHERE attacker_player_id = p_attacker_player_id
     AND status IN ('traveling', 'resolving')
   ORDER BY id DESC
   LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVE_ESPIONAGE',
      'message', 'Zaten aktif bir casusluk görevin var.',
      'missionId', v_existing.id
    );
  END IF;

  SELECT COALESCE(
    MAX(
      GREATEST(0, COALESCE(level, 0)) +
      CASE
        WHEN COALESCE(is_under_construction, false) = true
         AND upgrade_ready_at IS NOT NULL
         AND upgrade_ready_at <= now()
        THEN 1
        ELSE 0
      END
    ),
    0
  )
  INTO v_defender_watchtower
  FROM public.buildings
  WHERE city_id = v_defender_city.id
    AND building_type = 'Gözcü Kulesi';

  v_seconds := GREATEST(5, LEAST(COALESCE(p_travel_seconds, 5), 1800));
  v_distance := GREATEST(0, COALESCE(p_distance, 0));

  INSERT INTO public.espionage_missions(
    attacker_player_id,
    defender_player_id,
    attacker_city_id,
    defender_city_id,
    status,
    depart_at,
    arrive_at,
    distance,
    travel_seconds,
    attacker_watchtower_level,
    defender_watchtower_level
  )
  VALUES(
    p_attacker_player_id,
    p_defender_player_id,
    v_attacker_city.id,
    v_defender_city.id,
    'traveling',
    now(),
    now() + make_interval(secs => v_seconds),
    v_distance,
    v_seconds,
    v_attacker_watchtower,
    v_defender_watchtower
  )
  RETURNING * INTO v_mission;

  RETURN jsonb_build_object(
    'success', true,
    'message', '🕵️ Casus hedef koloniye gönderildi.',
    'mission', jsonb_build_object(
      'id', v_mission.id,
      'status', v_mission.status,
      'arriveAt', v_mission.arrive_at,
      'travelSeconds', v_mission.travel_seconds,
      'distance', v_mission.distance,
      'targetPlayerId', v_mission.defender_player_id
    )
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- Resolve an espionage mission.
-- Result is a snapshot and therefore does not change on later status requests.
-- Successful intel tiers:
--   1 = resources
--   2 = resources + buildings
--   3 = resources + buildings + army
--   4 = resources + buildings + army + research
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.nexora_resolve_espionage(
  p_player_id bigint,
  p_mission_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_mission public.espionage_missions%ROWTYPE;
  v_defender_city public.cities%ROWTYPE;
  v_sync jsonb;
  v_defender_watchtower integer := 0;
  v_attack_level integer := 0;
  v_advantage integer := 0;
  v_detection_chance integer := 30;
  v_roll integer := 1;
  v_detected boolean := false;
  v_intel_level integer := 0;
  v_remaining integer := 0;
  v_resources jsonb := '{}'::jsonb;
  v_buildings jsonb := '[]'::jsonb;
  v_army jsonb := '[]'::jsonb;
  v_research jsonb := '{}'::jsonb;
  v_result jsonb;
BEGIN
  SELECT *
    INTO v_mission
    FROM public.espionage_missions
   WHERE id = p_mission_id
     AND attacker_player_id = p_player_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'Casusluk görevi bulunamadı.'
    );
  END IF;

  IF v_mission.status = 'completed' THEN
    RETURN jsonb_build_object(
      'success', true,
      'mission', jsonb_build_object(
        'id', v_mission.id,
        'status', 'completed',
        'arriveAt', v_mission.arrive_at,
        'remainingSeconds', 0,
        'result', COALESCE(v_mission.result, '{}'::jsonb)
      )
    );
  END IF;

  IF v_mission.arrive_at > now() THEN
    v_remaining := GREATEST(
      0,
      CEIL(EXTRACT(EPOCH FROM (v_mission.arrive_at - now())))::integer
    );

    RETURN jsonb_build_object(
      'success', true,
      'mission', jsonb_build_object(
        'id', v_mission.id,
        'status', 'traveling',
        'arriveAt', v_mission.arrive_at,
        'remainingSeconds', v_remaining,
        'result', COALESCE(v_mission.result, '{}'::jsonb)
      )
    );
  END IF;

  IF v_mission.status NOT IN ('traveling', 'resolving') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_STATUS',
      'message', 'Casusluk görevi sonuçlandırılamıyor.'
    );
  END IF;

  UPDATE public.espionage_missions
     SET status = 'resolving'
   WHERE id = v_mission.id;

  -- Synchronize passive production before taking the resource snapshot.
  SELECT public.nexora_sync_city_production(v_mission.defender_player_id)
    INTO v_sync;

  SELECT *
    INTO v_defender_city
    FROM public.cities
   WHERE id = v_mission.defender_city_id
     AND player_id = v_mission.defender_player_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    v_result := jsonb_build_object(
      'outcome', 'target_missing',
      'detected', false,
      'intelLevel', 0,
      'message', 'Hedef koloni artık bulunamıyor.'
    );

    UPDATE public.espionage_missions
       SET status = 'completed',
           completed_at = now(),
           detected = false,
           result = v_result
     WHERE id = v_mission.id;

    RETURN jsonb_build_object(
      'success', true,
      'mission', jsonb_build_object(
        'id', v_mission.id,
        'status', 'completed',
        'arriveAt', v_mission.arrive_at,
        'remainingSeconds', 0,
        'result', v_result
      )
    );
  END IF;

  SELECT COALESCE(
    MAX(
      GREATEST(0, COALESCE(level, 0)) +
      CASE
        WHEN COALESCE(is_under_construction, false) = true
         AND upgrade_ready_at IS NOT NULL
         AND upgrade_ready_at <= now()
        THEN 1
        ELSE 0
      END
    ),
    0
  )
  INTO v_defender_watchtower
  FROM public.buildings
  WHERE city_id = v_defender_city.id
    AND building_type = 'Gözcü Kulesi';

  v_attack_level := GREATEST(1, COALESCE(v_mission.attacker_watchtower_level, 1));
  v_advantage := v_attack_level - v_defender_watchtower;

  -- Equal towers = 30% detection.
  -- Better defender tower raises detection; better attacker tower lowers it.
  v_detection_chance := GREATEST(
    10,
    LEAST(80, 30 + ((v_defender_watchtower - v_attack_level) * 8))
  );

  v_roll := FLOOR(random() * 100)::integer + 1;
  v_detected := v_roll <= v_detection_chance;

  IF v_detected THEN
    v_result := jsonb_build_object(
      'outcome', 'detected',
      'detected', true,
      'intelLevel', 0,
      'message', '🚨 Casusun hedef kolonide yakalandı. İstihbarat alınamadı.'
    );
  ELSE
    v_intel_level := CASE
      WHEN v_advantage >= 4 THEN 4
      WHEN v_advantage >= 2 THEN 3
      WHEN v_advantage >= 0 THEN 2
      ELSE 1
    END;

    v_resources := jsonb_build_object(
      'metal', GREATEST(0, COALESCE(v_defender_city.metal, 0)),
      'energy', GREATEST(0, COALESCE(v_defender_city.energy, 0)),
      'water', GREATEST(0, COALESCE(v_defender_city.water, 0)),
      'crystal', GREATEST(0, COALESCE(v_defender_city.crystal, 0))
    );

    IF v_intel_level >= 2 THEN
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'building', x.building_type,
            'slot', x.slot,
            'level', x.effective_level
          )
          ORDER BY x.building_type, x.slot
        ),
        '[]'::jsonb
      )
      INTO v_buildings
      FROM (
        SELECT
          building_type,
          COALESCE(slot, 1) AS slot,
          GREATEST(0, COALESCE(level, 0)) +
          CASE
            WHEN COALESCE(is_under_construction, false) = true
             AND upgrade_ready_at IS NOT NULL
             AND upgrade_ready_at <= now()
            THEN 1
            ELSE 0
          END AS effective_level
        FROM public.buildings
        WHERE city_id = v_defender_city.id
        ORDER BY building_type, COALESCE(slot, 1)
      ) AS x;
    END IF;

    IF v_intel_level >= 3 THEN
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'unitType', u.unit_type,
            'quantity', GREATEST(0, COALESCE(u.quantity, 0)),
            'level', GREATEST(1, COALESCE(u.level, 1))
          )
          ORDER BY u.unit_type
        ),
        '[]'::jsonb
      )
      INTO v_army
      FROM public.units AS u
      WHERE u.city_id = v_defender_city.id
        AND COALESCE(u.quantity, 0) > 0;
    END IF;

    IF v_intel_level >= 4 THEN
      SELECT jsonb_build_object(
        'production', COALESCE(r.production_level, 0),
        'combat', COALESCE(r.combat_level, 0),
        'defense', COALESCE(r.defense_level, 0),
        'crystal', COALESCE(r.crystal_level, 0),
        'generalPower', COALESCE(r.general_power_level, 0),
        'unitAttack', COALESCE(r.unit_attack_level, 0),
        'unitDefense', COALESCE(r.unit_defense_level, 0),
        'unitHp', COALESCE(r.unit_hp_level, 0),
        'travelSpeed', COALESCE(r.travel_speed_level, 0)
      )
      INTO v_research
      FROM public.research AS r
      WHERE r.player_id = v_mission.defender_player_id
      LIMIT 1;

      v_research := COALESCE(v_research, '{}'::jsonb);
    END IF;

    v_result := jsonb_build_object(
      'outcome', 'success',
      'detected', false,
      'intelLevel', v_intel_level,
      'message', '🕵️ Casusluk başarılı. Hedef koloni hakkında istihbarat toplandı.',
      'targetPlayerId', v_mission.defender_player_id,
      'targetCityId', v_mission.defender_city_id,
      'resources', v_resources,
      'buildings', CASE WHEN v_intel_level >= 2 THEN v_buildings ELSE NULL END,
      'army', CASE WHEN v_intel_level >= 3 THEN v_army ELSE NULL END,
      'research', CASE WHEN v_intel_level >= 4 THEN v_research ELSE NULL END
    );
  END IF;

  UPDATE public.espionage_missions
     SET status = 'completed',
         completed_at = now(),
         defender_watchtower_level = v_defender_watchtower,
         detected = v_detected,
         result = v_result
   WHERE id = v_mission.id;

  RETURN jsonb_build_object(
    'success', true,
    'mission', jsonb_build_object(
      'id', v_mission.id,
      'status', 'completed',
      'arriveAt', v_mission.arrive_at,
      'remainingSeconds', 0,
      'result', v_result
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_start_espionage(bigint, bigint, integer, numeric)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_resolve_espionage(bigint, bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_start_espionage(bigint, bigint, integer, numeric)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_resolve_espionage(bigint, bigint)
  TO service_role;

COMMIT;
