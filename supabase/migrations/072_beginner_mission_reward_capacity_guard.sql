-- NEXORA - Economy & Balance Audit / Beginner Mission Reward Capacity Guard
-- Migration 072
--
-- Prevents beginner mission rewards from being silently truncated by storage.
--
-- If the full configured reward does not fit:
-- - no resources are credited
-- - no claim row is inserted
-- - the player can free storage and retry
--
-- Existing reward values, mission progress, achievement unlock behavior,
-- security mode and historical claim rows are preserved.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_claim_mission(
  p_player_id bigint,
  p_mission_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_mission public.game_missions%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_progress bigint;
  v_reward jsonb;

  v_depo_level integer := 0;
  v_crystal_depo_level integer := 0;
  v_storage bigint;
  v_crystal_storage bigint;

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
  IF p_player_id IS NULL OR p_player_id <= 0
     OR p_mission_id IS NULL OR btrim(p_mission_id) = '' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz görev isteği.'
    );
  END IF;

  -- Serialize all reward claims for this player.
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

  SELECT *
  INTO v_mission
  FROM public.game_missions
  WHERE id = p_mission_id
    AND active IS TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'Görev bulunamadı.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.player_mission_claims
    WHERE player_id = p_player_id
      AND mission_id = v_mission.id
  ) THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu görev ödülü daha önce alındı.',
      'snapshot', public.nexora_missions_snapshot(p_player_id)
    );
  END IF;

  v_progress :=
    public.nexora_progress_value(
      p_player_id,
      v_mission.metric_key
    );

  IF v_progress < v_mission.target_value THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_INCOMPLETE',
      'message', 'Görev henüz tamamlanmadı.',
      'progress', v_progress,
      'target', v_mission.target_value
    );
  END IF;

  SELECT *
  INTO v_city
  FROM public.cities
  WHERE player_id = p_player_id
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

  SELECT
    COALESCE(
      MAX(
        CASE
          WHEN building_type = 'Depo' THEN level
        END
      ),
      0
    ),
    COALESCE(
      MAX(
        CASE
          WHEN building_type = 'Kristal Deposu' THEN level
        END
      ),
      0
    )
  INTO v_depo_level, v_crystal_depo_level
  FROM public.buildings
  WHERE city_id = v_city.id;

  v_storage :=
    5000 + GREATEST(v_depo_level, 0) * 2500;

  v_crystal_storage :=
    3000 + GREATEST(v_crystal_depo_level, 0) * 1500;

  v_reward := COALESCE(v_mission.reward, '{}'::jsonb);

  v_reward_metal :=
    GREATEST(
      0,
      COALESCE((v_reward ->> 'metal')::bigint, 0)
    );

  v_reward_energy :=
    GREATEST(
      0,
      COALESCE((v_reward ->> 'energy')::bigint, 0)
    );

  v_reward_alloy :=
    GREATEST(
      0,
      COALESCE((v_reward ->> 'alloy')::bigint, 0)
    );

  v_reward_crystal :=
    GREATEST(
      0,
      COALESCE((v_reward ->> 'crystal')::bigint, 0)
    );

  IF
    GREATEST(COALESCE(v_city.metal, 0), 0) + v_reward_metal > v_storage
    OR GREATEST(COALESCE(v_city.energy, 0), 0) + v_reward_energy > v_storage
    OR GREATEST(COALESCE(v_city.alloy, 0), 0) + v_reward_alloy > v_storage
    OR GREATEST(COALESCE(v_city.crystal, 0), 0) + v_reward_crystal
      > v_crystal_storage
  THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'REWARD_STORAGE_FULL',
      'message', 'Ödülün tamamını almak için depolarda yeterli boş alan yok.',
      'rewardConfigured', v_reward,
      'snapshot', public.nexora_missions_snapshot(p_player_id)
    );
  END IF;

  v_credit_metal := v_reward_metal;
  v_credit_energy := v_reward_energy;
  v_credit_alloy := v_reward_alloy;
  v_credit_crystal := v_reward_crystal;

  UPDATE public.cities
  SET
    metal =
      GREATEST(COALESCE(metal, 0), 0) + v_credit_metal,
    energy =
      GREATEST(COALESCE(energy, 0), 0) + v_credit_energy,
    alloy =
      GREATEST(COALESCE(alloy, 0), 0) + v_credit_alloy,
    crystal =
      GREATEST(COALESCE(crystal, 0), 0) + v_credit_crystal,
    metal_capacity = v_storage,
    energy_capacity = v_storage,
    alloy_capacity = v_storage,
    crystal_capacity = v_crystal_storage,
    updated_at = now()
  WHERE id = v_city.id;

  v_credited := jsonb_build_object(
    'metal', v_credit_metal,
    'energy', v_credit_energy,
    'alloy', v_credit_alloy,
    'crystal', v_credit_crystal
  );

  INSERT INTO public.player_mission_claims(
    player_id,
    mission_id,
    claimed_at,
    reward
  )
  VALUES(
    p_player_id,
    v_mission.id,
    now(),
    v_credited
  );

  -- Unlock any achievements reached by the same canonical state.
  INSERT INTO public.player_achievements(
    player_id,
    achievement_id,
    unlocked_at
  )
  SELECT
    p_player_id,
    a.id,
    now()
  FROM public.game_achievements a
  WHERE a.active IS TRUE
    AND public.nexora_progress_value(
          p_player_id,
          a.metric_key
        ) >= a.target_value
  ON CONFLICT (player_id, achievement_id) DO NOTHING;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyClaimed', false,
    'message', 'Görev ödülü alındı.',
    'rewardConfigured', v_reward,
    'rewardCredited', v_credited,
    'snapshot', public.nexora_missions_snapshot(p_player_id)
  );
END;
$function$;

COMMIT;
