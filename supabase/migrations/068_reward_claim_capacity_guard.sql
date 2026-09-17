-- NEXORA - Economy & Balance Audit / Reward Capacity Guard
-- Migration 068
--
-- First audit fix:
-- - Login rewards must never be silently truncated by storage capacity.
-- - If the full configured reward does not fit, the claim remains available.
-- - No reward amounts are changed in this migration.
-- - No existing claim history is rewritten.
--
-- Canonical resources: metal, energy, alloy, crystal.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_claim_login_reward(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_city public.cities%ROWTYPE;
  v_server_time timestamptz;
  v_claim_date date;
  v_prior_claims bigint := 0;
  v_cycle_day smallint := 1;
  v_reward jsonb;
  v_depo_level bigint := 0;
  v_crystal_depo_level bigint := 0;
  v_storage bigint := 5000;
  v_crystal_storage bigint := 3000;
  v_reward_metal bigint := 0;
  v_reward_energy bigint := 0;
  v_reward_alloy bigint := 0;
  v_reward_crystal bigint := 0;
  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_alloy bigint := 0;
  v_credit_crystal bigint := 0;
  v_credited jsonb;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz giriş ödülü isteği.'
    );
  END IF;

  PERFORM id
  FROM public.players
  WHERE id = p_player_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  v_server_time := clock_timestamp();
  v_claim_date := (v_server_time AT TIME ZONE 'Europe/Istanbul')::date;

  IF EXISTS (
    SELECT 1
    FROM public.player_login_reward_claims c
    WHERE c.player_id = p_player_id
      AND c.claim_date = v_claim_date
  ) THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bugünkü giriş ödülü zaten alındı.',
      'snapshot', public.nexora_login_rewards_snapshot(p_player_id)
    );
  END IF;

  SELECT COUNT(*)::bigint
  INTO v_prior_claims
  FROM public.player_login_reward_claims c
  WHERE c.player_id = p_player_id;

  v_cycle_day := ((GREATEST(v_prior_claims, 0) % 7) + 1)::smallint;

  SELECT COALESCE(r.reward, '{}'::jsonb)
  INTO v_reward
  FROM public.game_login_rewards r
  WHERE r.day_number = v_cycle_day
    AND r.active IS TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'LOGIN_REWARD_NOT_FOUND',
      'message', 'Giriş ödülü tanımı bulunamadı.'
    );
  END IF;

  SELECT *
  INTO v_city
  FROM public.cities c
  WHERE c.player_id = p_player_id
  ORDER BY c.id
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
    COALESCE(
      SUM(GREATEST(COALESCE(b.level, 0), 0))
      FILTER (WHERE b.building_type = 'Depo'),
      0
    )::bigint,
    COALESCE(
      SUM(GREATEST(COALESCE(b.level, 0), 0))
      FILTER (WHERE b.building_type = 'Kristal Deposu'),
      0
    )::bigint
  INTO v_depo_level, v_crystal_depo_level
  FROM public.buildings b
  WHERE b.city_id = v_city.id;

  v_storage := 5000 + GREATEST(v_depo_level, 0) * 2500;
  v_crystal_storage := 3000 + GREATEST(v_crystal_depo_level, 0) * 1500;

  v_reward_metal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'metal', '')::bigint, 0));
  v_reward_energy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'energy', '')::bigint, 0));
  v_reward_alloy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'alloy', '')::bigint, 0));
  v_reward_crystal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'crystal', '')::bigint, 0));

  IF
    GREATEST(COALESCE(v_city.metal, 0), 0) + v_reward_metal > v_storage
    OR GREATEST(COALESCE(v_city.energy, 0), 0) + v_reward_energy > v_storage
    OR GREATEST(COALESCE(v_city.alloy, 0), 0) + v_reward_alloy > v_storage
    OR GREATEST(COALESCE(v_city.crystal, 0), 0) + v_reward_crystal > v_crystal_storage
  THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'REWARD_STORAGE_FULL',
      'message', 'Ödülün tamamını almak için depolarda yeterli boş alan yok.',
      'day', v_cycle_day,
      'rewardConfigured', v_reward,
      'freeSpace', jsonb_build_object(
        'metal',
          GREATEST(v_storage - GREATEST(COALESCE(v_city.metal, 0), 0), 0),
        'energy',
          GREATEST(v_storage - GREATEST(COALESCE(v_city.energy, 0), 0), 0),
        'alloy',
          GREATEST(v_storage - GREATEST(COALESCE(v_city.alloy, 0), 0), 0),
        'crystal',
          GREATEST(
            v_crystal_storage - GREATEST(COALESCE(v_city.crystal, 0), 0),
            0
          )
      ),
      'capacities', jsonb_build_object(
        'metal', v_storage,
        'energy', v_storage,
        'alloy', v_storage,
        'crystal', v_crystal_storage
      ),
      'snapshot', public.nexora_login_rewards_snapshot(p_player_id)
    );
  END IF;

  v_credit_metal := v_reward_metal;
  v_credit_energy := v_reward_energy;
  v_credit_alloy := v_reward_alloy;
  v_credit_crystal := v_reward_crystal;

  UPDATE public.cities
  SET
    metal = GREATEST(COALESCE(metal, 0), 0) + v_credit_metal,
    energy = GREATEST(COALESCE(energy, 0), 0) + v_credit_energy,
    alloy = GREATEST(COALESCE(alloy, 0), 0) + v_credit_alloy,
    crystal = GREATEST(COALESCE(crystal, 0), 0) + v_credit_crystal,
    metal_capacity = v_storage,
    energy_capacity = v_storage,
    alloy_capacity = v_storage,
    crystal_capacity = v_crystal_storage,
    updated_at = clock_timestamp()
  WHERE id = v_city.id;

  v_credited := jsonb_build_object(
    'metal', v_credit_metal,
    'energy', v_credit_energy,
    'alloy', v_credit_alloy,
    'crystal', v_credit_crystal
  );

  INSERT INTO public.player_login_reward_claims(
    player_id,
    claim_date,
    cycle_day,
    claimed_at,
    reward
  )
  VALUES(
    p_player_id,
    v_claim_date,
    v_cycle_day,
    v_server_time,
    v_credited
  );

  RETURN jsonb_build_object(
    'success', true,
    'alreadyClaimed', false,
    'message', v_cycle_day::text || '. gün giriş ödülü alındı.',
    'day', v_cycle_day,
    'rewardConfigured', v_reward,
    'rewardCredited', v_credited,
    'snapshot', public.nexora_login_rewards_snapshot(p_player_id)
  );
END;
$function$;

COMMIT;
