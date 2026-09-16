-- NEXORA - New Player PvP Protection V1
-- Migration 041
--
-- Goals:
-- - Give only players created after this migration 72 hours of PvP protection.
-- - Do not backfill protection for existing production players.
-- - Enforce protection inside the authoritative atomic PvP mission-start RPC.
-- - A protected attacker gives up protection only when a valid PvP mission
--   actually passes every validation and is about to spend the selected army.
-- - PvE, espionage, trade, exploration and other systems remain unchanged.
-- - Existing 13-argument battle-tactic wrapper remains unchanged; it continues
--   to call this 12-argument core function inside the same transaction.
--
-- Apply after 040_beginner_guide_v1.sql.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) NEW-PLAYER PROTECTION STATE
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.player_pvp_protection (
  player_id bigint PRIMARY KEY
    REFERENCES public.players(id) ON DELETE CASCADE,
  started_at timestamptz NOT NULL,
  protected_until timestamptz NOT NULL,
  ended_at timestamptz,
  ended_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT player_pvp_protection_time_check
    CHECK (protected_until > started_at),
  CONSTRAINT player_pvp_protection_end_check
    CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE INDEX IF NOT EXISTS idx_player_pvp_protection_active_until
  ON public.player_pvp_protection(protected_until)
  WHERE ended_at IS NULL;

ALTER TABLE public.player_pvp_protection ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.player_pvp_protection
  FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.player_pvp_protection
  TO service_role;

-- Intentionally no INSERT ... SELECT backfill here. Players that already exist
-- when this migration is applied remain unprotected.

-- -----------------------------------------------------------------------------
-- 2) AUTOMATIC 72-HOUR PROTECTION FOR FUTURE PLAYERS
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_create_new_player_pvp_protection()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
BEGIN
  INSERT INTO public.player_pvp_protection(
    player_id,
    started_at,
    protected_until,
    ended_at,
    ended_reason,
    created_at,
    updated_at
  )
  VALUES(
    NEW.id,
    v_now,
    v_now + interval '72 hours',
    NULL,
    NULL,
    v_now,
    v_now
  )
  ON CONFLICT (player_id) DO NOTHING;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_nexora_new_player_pvp_protection
  ON public.players;

CREATE TRIGGER trg_nexora_new_player_pvp_protection
AFTER INSERT ON public.players
FOR EACH ROW
EXECUTE FUNCTION public.nexora_create_new_player_pvp_protection();

-- -----------------------------------------------------------------------------
-- 3) BACKEND-ONLY PROTECTION SNAPSHOT
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_pvp_protection_state(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_state public.player_pvp_protection%ROWTYPE;
  v_now timestamptz := now();
  v_active boolean := false;
  v_remaining integer := 0;
BEGIN
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR NOT EXISTS (
       SELECT 1
         FROM public.players p
        WHERE p.id = p_player_id
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  SELECT *
    INTO v_state
    FROM public.player_pvp_protection s
   WHERE s.player_id = p_player_id;

  IF v_state.player_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'protected', false,
      'hasProtectionRecord', false,
      'startedAt', NULL,
      'protectedUntil', NULL,
      'remainingSeconds', 0,
      'endedAt', NULL,
      'endedReason', NULL
    );
  END IF;

  v_active :=
    v_state.ended_at IS NULL
    AND v_state.protected_until > v_now;

  IF v_active THEN
    v_remaining := GREATEST(
      0,
      CEIL(
        EXTRACT(
          EPOCH FROM (v_state.protected_until - v_now)
        )
      )::integer
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'protected', v_active,
    'hasProtectionRecord', true,
    'startedAt', v_state.started_at,
    'protectedUntil', v_state.protected_until,
    'remainingSeconds', v_remaining,
    'endedAt', v_state.ended_at,
    'endedReason',
      CASE
        WHEN v_state.ended_at IS NOT NULL
          THEN v_state.ended_reason
        WHEN v_state.protected_until <= v_now
          THEN 'expired'
        ELSE NULL
      END
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 4) AUTHORITATIVE PvP MISSION START
--
-- This replaces only the current 12-argument core from migration 023.
-- The 13-argument battle-tactic wrapper from migration 035 is left untouched.
-- It still calls this core function, so the protection check cannot be bypassed
-- by the current backend attack endpoint.
-- -----------------------------------------------------------------------------

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
AS $function$
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
  v_now timestamptz;
  v_target_protected_until timestamptz;
  v_target_remaining_seconds integer := 0;
  v_attacker_protection_ended integer := 0;
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

  -- Lock both cities in deterministic order. The attacker-city lock remains the
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

  -- Protection rows are locked after the existing deterministic city locks.
  -- Missing rows mean legacy/pre-migration players and therefore no protection.
  PERFORM player_id
  FROM public.player_pvp_protection
  WHERE player_id IN (p_attacker_player_id, p_defender_player_id)
  ORDER BY player_id
  FOR UPDATE;

  v_now := clock_timestamp();

  SELECT s.protected_until
    INTO v_target_protected_until
    FROM public.player_pvp_protection s
   WHERE s.player_id = p_defender_player_id
     AND s.ended_at IS NULL;

  IF v_target_protected_until IS NOT NULL
     AND v_target_protected_until > v_now THEN
    v_target_remaining_seconds := GREATEST(
      0,
      CEIL(
        EXTRACT(
          EPOCH FROM (v_target_protected_until - v_now)
        )
      )::integer
    );

    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_PVP_PROTECTED',
      'message', 'Bu oyuncu yeni oyuncu PvP koruması altında.',
      'protectedUntil', v_target_protected_until,
      'remainingSeconds', v_target_remaining_seconds
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

  -- Every failure-return above has passed. If the attacker is still protected,
  -- voluntarily starting this valid real-player attack ends that protection.
  -- This update and the army deduction / mission insert are in one transaction;
  -- any unexpected exception later rolls all of them back together.
  v_now := clock_timestamp();

  UPDATE public.player_pvp_protection
     SET ended_at = v_now,
         ended_reason = 'pvp_attack',
         updated_at = v_now
   WHERE player_id = p_attacker_player_id
     AND ended_at IS NULL
     AND protected_until > v_now;

  GET DIAGNOSTICS v_attacker_protection_ended = ROW_COUNT;

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
    'mission', to_jsonb(mission),
    'attackerProtectionEnded', v_attacker_protection_ended = 1
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 5) FUNCTION / TRIGGER PERMISSIONS
-- -----------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.nexora_create_new_player_pvp_protection()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.nexora_pvp_protection_state(bigint)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.nexora_start_military_mission(
  bigint,bigint,bigint,bigint,jsonb,integer,integer,integer,integer,integer,integer,numeric
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_create_new_player_pvp_protection()
  TO service_role;

GRANT EXECUTE ON FUNCTION public.nexora_pvp_protection_state(bigint)
  TO service_role;

GRANT EXECUTE ON FUNCTION public.nexora_start_military_mission(
  bigint,bigint,bigint,bigint,jsonb,integer,integer,integer,integer,integer,integer,numeric
) TO service_role;

COMMIT;
