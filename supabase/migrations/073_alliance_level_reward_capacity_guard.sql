-- NEXORA - Economy & Balance Audit / Alliance Level Reward Capacity Guard
-- Migration 073
--
-- Prevents alliance level milestone rewards from being silently truncated.
--
-- If the full configured reward does not fit:
-- - no resources are credited
-- - no claim row is inserted
-- - the player can free storage and retry
--
-- Existing eligibility, idempotency, activity logging and reward values
-- are preserved.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_claim_alliance_level_reward(
  p_player_id bigint,
  p_level integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_member public.alliance_members%ROWTYPE;
  v_milestone public.alliance_level_milestones%ROWTYPE;
  v_level public.game_alliance_levels%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_existing jsonb;
  v_configured jsonb;
  v_credited jsonb;
  v_reward_metal bigint := 0;
  v_reward_energy bigint := 0;
  v_reward_alloy bigint := 0;
  v_reward_crystal bigint := 0;
  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_alloy bigint := 0;
  v_credit_crystal bigint := 0;
BEGIN
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR p_level IS NULL
     OR p_level < 2
     OR p_level > 10 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz ittifak seviye ödülü isteği.'
    );
  END IF;

  PERFORM p.id
  FROM public.players p
  WHERE p.id = p_player_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  SELECT am.*
  INTO v_member
  FROM public.alliance_members am
  WHERE am.player_id = p_player_id
  FOR UPDATE;

  IF v_member.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_IN_ALLIANCE',
      'message', 'Bir ittifaka üye değilsin.'
    );
  END IF;

  SELECT m.*
  INTO v_milestone
  FROM public.alliance_level_milestones m
  WHERE m.alliance_id = v_member.alliance_id
    AND m.level = p_level;

  IF v_milestone.alliance_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'LEVEL_NOT_REACHED',
      'message', 'İttifak bu seviyeye henüz ulaşmadı.'
    );
  END IF;

  IF v_member.joined_at > v_milestone.reached_at THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_ELIGIBLE',
      'message', 'Bu seviye kazanıldığında ittifak üyesi değildin.'
    );
  END IF;

  SELECT l.*
  INTO v_level
  FROM public.game_alliance_levels l
  WHERE l.level = p_level;

  IF v_level.level IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'LEVEL_NOT_FOUND',
      'message', 'İttifak seviyesi bulunamadı.'
    );
  END IF;

  SELECT c.reward
  INTO v_existing
  FROM public.player_alliance_level_reward_claims c
  WHERE c.player_id = p_player_id
    AND c.alliance_id = v_member.alliance_id
    AND c.level = p_level
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu ittifak seviye ödülünü zaten aldın.',
      'creditedReward', COALESCE(v_existing, '{}'::jsonb),
      'snapshot', public.nexora_alliance_progression_snapshot(p_player_id)
    );
  END IF;

  v_configured := v_level.reward;

  IF v_configured IS NULL
     OR jsonb_typeof(v_configured) IS DISTINCT FROM 'object'
     OR EXISTS (
       SELECT 1
       FROM jsonb_each_text(v_configured) r(key, value)
       WHERE key NOT IN ('metal', 'energy', 'alloy', 'crystal')
          OR value !~ '^[0-9]+$'
          OR char_length(value) > 12
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ALLIANCE_LEVEL_REWARD_INVALID',
      'message', 'İttifak seviye ödülü yapılandırması geçersiz.'
    );
  END IF;

  SELECT *
  INTO v_city
  FROM public.cities c
  WHERE c.player_id = p_player_id
  ORDER BY c.id
  LIMIT 1
  FOR UPDATE;

  IF v_city.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Şehir bulunamadı.'
    );
  END IF;

  v_reward_metal :=
    COALESCE((v_configured ->> 'metal')::bigint, 0);
  v_reward_energy :=
    COALESCE((v_configured ->> 'energy')::bigint, 0);
  v_reward_alloy :=
    COALESCE((v_configured ->> 'alloy')::bigint, 0);
  v_reward_crystal :=
    COALESCE((v_configured ->> 'crystal')::bigint, 0);

  IF
    COALESCE(v_city.metal, 0) + v_reward_metal
      > COALESCE(v_city.metal_capacity, 0)
    OR COALESCE(v_city.energy, 0) + v_reward_energy
      > COALESCE(v_city.energy_capacity, 0)
    OR COALESCE(v_city.alloy, 0) + v_reward_alloy
      > COALESCE(v_city.alloy_capacity, 0)
    OR COALESCE(v_city.crystal, 0) + v_reward_crystal
      > COALESCE(v_city.crystal_capacity, 0)
  THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'REWARD_STORAGE_FULL',
      'message', 'Ödülün tamamını almak için depolarda yeterli boş alan yok.',
      'configuredReward', v_configured,
      'snapshot', public.nexora_alliance_progression_snapshot(p_player_id)
    );
  END IF;

  v_credit_metal := v_reward_metal;
  v_credit_energy := v_reward_energy;
  v_credit_alloy := v_reward_alloy;
  v_credit_crystal := v_reward_crystal;

  v_credited := jsonb_build_object(
    'metal', v_credit_metal,
    'energy', v_credit_energy,
    'alloy', v_credit_alloy,
    'crystal', v_credit_crystal
  );

  INSERT INTO public.player_alliance_level_reward_claims(
    player_id,
    alliance_id,
    level,
    configured_reward,
    reward,
    claimed_at
  )
  VALUES(
    p_player_id,
    v_member.alliance_id,
    p_level,
    v_configured,
    v_credited,
    clock_timestamp()
  )
  ON CONFLICT (player_id, alliance_id, level) DO NOTHING;

  IF NOT FOUND THEN
    SELECT c.reward
    INTO v_existing
    FROM public.player_alliance_level_reward_claims c
    WHERE c.player_id = p_player_id
      AND c.alliance_id = v_member.alliance_id
      AND c.level = p_level
    LIMIT 1;

    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu ittifak seviye ödülünü zaten aldın.',
      'creditedReward', COALESCE(v_existing, '{}'::jsonb),
      'snapshot', public.nexora_alliance_progression_snapshot(p_player_id)
    );
  END IF;

  UPDATE public.cities
  SET
    metal = COALESCE(metal, 0) + v_credit_metal,
    energy = COALESCE(energy, 0) + v_credit_energy,
    alloy = COALESCE(alloy, 0) + v_credit_alloy,
    crystal = COALESCE(crystal, 0) + v_credit_crystal,
    updated_at = clock_timestamp()
  WHERE id = v_city.id;

  INSERT INTO public.alliance_activity(
    alliance_id,
    event_type,
    actor_player_id,
    metadata,
    created_at
  )
  VALUES(
    v_member.alliance_id,
    'alliance_level_reward_claimed',
    p_player_id,
    jsonb_build_object(
      'level', p_level,
      'reward', v_credited
    ),
    clock_timestamp()
  );

  RETURN jsonb_build_object(
    'success', true,
    'alreadyClaimed', false,
    'message', 'İttifak seviye ödülü alındı.',
    'configuredReward', v_configured,
    'creditedReward', v_credited,
    'snapshot', public.nexora_alliance_progression_snapshot(p_player_id)
  );
END;
$function$;

COMMIT;
