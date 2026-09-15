-- NEXORA - Battle Tactics V1
-- Additive / production-safe migration.
-- Stores the server-authoritative tactic selected when a military mission starts.
-- Existing missions default to balanced.

BEGIN;

ALTER TABLE public.military_missions
  ADD COLUMN IF NOT EXISTS battle_tactic text;

UPDATE public.military_missions
SET battle_tactic = 'balanced'
WHERE battle_tactic IS NULL
   OR battle_tactic NOT IN ('assault', 'balanced', 'cautious');

ALTER TABLE public.military_missions
  ALTER COLUMN battle_tactic SET DEFAULT 'balanced',
  ALTER COLUMN battle_tactic SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'military_missions_battle_tactic_check'
      AND conrelid = 'public.military_missions'::regclass
  ) THEN
    ALTER TABLE public.military_missions
      ADD CONSTRAINT military_missions_battle_tactic_check
      CHECK (battle_tactic IN ('assault', 'balanced', 'cautious'));
  END IF;
END;
$$;

-- Keep the existing 12-argument mission-start function untouched.
-- This 13-argument wrapper calls it inside the same transaction, then stores
-- the validated tactic on the mission row. If the tactic update unexpectedly
-- fails, RAISE rolls the whole RPC back, including the unit deduction.
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
  p_fleet_speed numeric,
  p_battle_tactic text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result jsonb;
  v_mission_id bigint;
  v_mission public.military_missions%ROWTYPE;
  v_tactic text;
BEGIN
  v_tactic := lower(trim(COALESCE(p_battle_tactic, '')));

  IF v_tactic NOT IN ('assault', 'balanced', 'cautious') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_TACTIC',
      'message', 'Geçersiz savaş taktiği.'
    );
  END IF;

  SELECT public.nexora_start_military_mission(
    p_attacker_player_id,
    p_defender_player_id,
    p_attacker_city_id,
    p_defender_city_id,
    p_army,
    p_attack_power,
    p_depart_x,
    p_depart_y,
    p_target_x,
    p_target_y,
    p_travel_seconds,
    p_fleet_speed
  )
  INTO v_result;

  IF v_result IS NULL OR v_result->>'success' IS DISTINCT FROM 'true' THEN
    RETURN v_result;
  END IF;

  BEGIN
    v_mission_id := NULLIF(v_result->'mission'->>'id', '')::bigint;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Sefer kimliği doğrulanamadı.';
  END;

  IF v_mission_id IS NULL OR v_mission_id <= 0 THEN
    RAISE EXCEPTION 'Sefer kimliği doğrulanamadı.';
  END IF;

  UPDATE public.military_missions
  SET battle_tactic = v_tactic
  WHERE id = v_mission_id
    AND attacker_player_id = p_attacker_player_id
  RETURNING * INTO v_mission;

  IF v_mission.id IS NULL THEN
    RAISE EXCEPTION 'Savaş taktiği sefere kaydedilemedi.';
  END IF;

  RETURN v_result || jsonb_build_object(
    'mission', to_jsonb(v_mission)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_start_military_mission(
  bigint,bigint,bigint,bigint,jsonb,integer,integer,integer,integer,integer,integer,numeric,text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_start_military_mission(
  bigint,bigint,bigint,bigint,jsonb,integer,integer,integer,integer,integer,integer,numeric,text
) TO service_role;

COMMIT;
