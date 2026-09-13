-- NEXORA Phase 14.3
-- Atomically starts a military mission so the same army cannot be spent twice
-- by concurrent requests.
-- Apply AFTER 022 and BEFORE deploying the matching api/auth.js change.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_start_military_mission(
  p_attacker_player_id bigint,
  p_defender_player_id bigint,
  p_attacker_city_id bigint,
  p_defender_city_id bigint,
  p_army jsonb,
  p_attack_power integer,
  p_depart_x integer,
  p_depart_y integer,
  p_target_x integer,
  p_target_y integer,
  p_travel_seconds integer,
  p_fleet_speed numeric
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  attacker public.cities%ROWTYPE;
  defender public.cities%ROWTYPE;
  unit_row public.units%ROWTYPE;
  mission public.military_missions%ROWTYPE;
  item jsonb;
  requested_type text;
  quantity_text text;
  level_text text;
  requested_quantity bigint;
  requested_level integer;
  item_count integer;
  distinct_type_count integer;
  unit_id bigint;
  affected integer;
  depart_time timestamptz;
  arrive_time timestamptz;
BEGIN
  IF p_attacker_player_id IS NULL OR p_defender_player_id IS NULL
     OR p_attacker_city_id IS NULL OR p_defender_city_id IS NULL
     OR p_attacker_player_id = p_defender_player_id
     OR p_attacker_city_id = p_defender_city_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_TARGET',
      'message', 'Geçersiz hedef oyuncu.'
    );
  END IF;

  IF p_travel_seconds IS NULL OR p_travel_seconds <= 0 OR p_travel_seconds > 86400
     OR p_fleet_speed IS NULL OR p_fleet_speed <= 0
     OR p_attack_power IS NULL OR p_attack_power <= 0
     OR p_depart_x IS NULL OR p_depart_y IS NULL
     OR p_target_x IS NULL OR p_target_y IS NULL
     OR p_depart_x NOT BETWEEN 0 AND 100
     OR p_depart_y NOT BETWEEN 0 AND 100
     OR p_target_x NOT BETWEEN 0 AND 100
     OR p_target_y NOT BETWEEN 0 AND 100 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_MISSION',
      'message', 'Geçersiz sefer bilgisi.'
    );
  END IF;

  -- Lock both cities in a deterministic order. The attacker-city lock is the
  -- serialization point for concurrent mission-start requests from one player.
  PERFORM id
  FROM public.cities
  WHERE id IN (p_attacker_city_id, p_defender_city_id)
  ORDER BY id
  FOR UPDATE;

  SELECT * INTO attacker
  FROM public.cities
  WHERE id = p_attacker_city_id
    AND player_id = p_attacker_player_id;

  IF attacker.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Saldıran koloni bulunamadı.'
    );
  END IF;

  SELECT * INTO defender
  FROM public.cities
  WHERE id = p_defender_city_id
    AND player_id = p_defender_player_id;

  IF defender.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_CITY_NOT_FOUND',
      'message', 'Hedef koloni bulunamadı.'
    );
  END IF;

  -- Do not start with stale coordinates if either colony moved between the
  -- backend read and this transaction.
  IF COALESCE(attacker.coordinate_x, 0) <> p_depart_x
     OR COALESCE(attacker.coordinate_y, 0) <> p_depart_y
     OR COALESCE(defender.coordinate_x, 0) <> p_target_x
     OR COALESCE(defender.coordinate_y, 0) <> p_target_y THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_CHANGED',
      'message', 'Koloni koordinatları değişti; haritayı yenileyip tekrar deneyin.'
    );
  END IF;

  -- This check is authoritative because it runs after the attacker-city lock.
  IF EXISTS (
    SELECT 1
    FROM public.military_missions
    WHERE attacker_player_id = p_attacker_player_id
      AND status IN ('traveling', 'resolving', 'returning')
    LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVE_MISSION',
      'message', 'Zaten aktif bir seferin bulunuyor.'
    );
  END IF;

  IF p_army IS NULL OR jsonb_typeof(p_army) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ARMY',
      'message', 'Geçersiz ordu bilgisi.'
    );
  END IF;

  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
  INTO item_count, distinct_type_count
  FROM jsonb_array_elements(p_army) AS army_item(value);

  IF item_count < 1 OR item_count > 6 OR distinct_type_count <> item_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ARMY',
      'message', 'Geçersiz veya tekrarlanan birlik seçimi.'
    );
  END IF;

  -- Validate every requested unit and lock the live unit rows before any write.
  FOR item IN
    SELECT value FROM jsonb_array_elements(p_army) AS army_item(value)
  LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz ordu bilgisi.'
      );
    END IF;

    requested_type := item->>'unit_type';
    quantity_text := item->>'quantity';
    level_text := item->>'level';

    IF requested_type IS NULL
       OR requested_type NOT IN ('piyade','savunma','saldiri','okcu','tank','hava') THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_UNIT',
        'message', 'Geçersiz birlik türü.'
      );
    END IF;

    IF quantity_text IS NULL
       OR quantity_text !~ '^[1-9][0-9]*$'
       OR char_length(quantity_text) > 10 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Birlik miktarı pozitif tam sayı olmalı.'
      );
    END IF;

    requested_quantity := quantity_text::bigint;
    IF requested_quantity <= 0 OR requested_quantity > 2147483647 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz birlik miktarı.'
      );
    END IF;

    IF level_text IS NULL
       OR level_text !~ '^[1-9][0-9]*$'
       OR char_length(level_text) > 2 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz birlik seviyesi.'
      );
    END IF;

    requested_level := level_text::integer;
    IF requested_level < 1 OR requested_level > 15 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz birlik seviyesi.'
      );
    END IF;

    SELECT * INTO unit_row
    FROM public.units
    WHERE city_id = attacker.id
      AND unit_type = requested_type
    ORDER BY id
    LIMIT 1
    FOR UPDATE;

    IF unit_row.id IS NULL OR COALESCE(unit_row.quantity, 0) < requested_quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INSUFFICIENT_UNITS',
        'message', requested_type || ' için yeterli birlik yok.'
      );
    END IF;

    IF GREATEST(1, COALESCE(unit_row.level, 1)) <> requested_level THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'UNIT_CHANGED',
        'message', 'Birlik seviyesi değişti; orduyu yenileyip tekrar deneyin.'
      );
    END IF;
  END LOOP;

  -- All checks passed. Spend each unit exactly once while the rows remain locked.
  FOR item IN
    SELECT value FROM jsonb_array_elements(p_army) AS army_item(value)
  LOOP
    requested_type := item->>'unit_type';
    requested_quantity := (item->>'quantity')::bigint;

    SELECT id INTO unit_id
    FROM public.units
    WHERE city_id = attacker.id
      AND unit_type = requested_type
    ORDER BY id
    LIMIT 1;

    UPDATE public.units
    SET quantity = quantity - requested_quantity
    WHERE id = unit_id
      AND quantity >= requested_quantity;

    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected <> 1 THEN
      -- Unexpected state after locked validation: raise so the entire function
      -- invocation rolls back instead of leaving a partial deduction.
      RAISE EXCEPTION 'Ordu miktarı işlem sırasında değişti.';
    END IF;
  END LOOP;

  depart_time := clock_timestamp();
  arrive_time := depart_time + make_interval(secs => p_travel_seconds);

  INSERT INTO public.military_missions(
    attacker_player_id,
    defender_player_id,
    attacker_city_id,
    defender_city_id,
    mission_type,
    status,
    depart_at,
    arrive_at,
    attack_power,
    army,
    depart_x,
    depart_y,
    target_x,
    target_y,
    travel_seconds,
    fleet_speed
  ) VALUES (
    p_attacker_player_id,
    p_defender_player_id,
    attacker.id,
    defender.id,
    'attack',
    'traveling',
    depart_time,
    arrive_time,
    p_attack_power,
    p_army,
    p_depart_x,
    p_depart_y,
    p_target_x,
    p_target_y,
    p_travel_seconds,
    p_fleet_speed
  )
  RETURNING * INTO mission;

  RETURN jsonb_build_object(
    'success', true,
    'mission', to_jsonb(mission)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_start_military_mission(
  bigint,bigint,bigint,bigint,jsonb,integer,integer,integer,integer,integer,integer,numeric
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_start_military_mission(
  bigint,bigint,bigint,bigint,jsonb,integer,integer,integer,integer,integer,integer,numeric
) TO service_role;

COMMIT;
