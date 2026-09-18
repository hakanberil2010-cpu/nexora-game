-- TERYNDIS 083 Reward + Loot Overflow V1
-- Economy rule:
-- - Rewards and combat/exploration loot may exceed storage capacity.
-- - Trade delivery keeps its existing storage-capacity guard.
-- - Normal passive production never exceeds capacity.
-- - If a reward/loot balance is already at or above capacity, passive production
--   for that resource stops and the overflow balance is preserved until spent.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_claim_login_reward(p_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
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
  v_storage bigint := 10000;
  v_crystal_storage bigint := 10000;
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

  v_storage := 10000 + GREATEST(v_depo_level, 0) * 5000;
  v_crystal_storage := 10000 + GREATEST(v_crystal_depo_level, 0) * 5000;

  v_reward_metal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'metal', '')::bigint, 0));
  v_reward_energy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'energy', '')::bigint, 0));
  v_reward_alloy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'alloy', '')::bigint, 0));
  v_reward_crystal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'crystal', '')::bigint, 0));


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
$function$


CREATE OR REPLACE FUNCTION public.nexora_claim_mission(p_player_id bigint, p_mission_id text)
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
      SUM(CASE WHEN building_type = 'Depo' THEN level END),
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
    10000 + GREATEST(v_depo_level, 0) * 5000;

  v_crystal_storage :=
    10000 + GREATEST(v_crystal_depo_level, 0) * 5000;

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
$function$


CREATE OR REPLACE FUNCTION public.nexora_claim_daily_mission(p_player_id bigint, p_mission_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_mission public.game_daily_missions%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_guide jsonb;
  v_progress bigint := 0;
  v_server_time timestamptz;
  v_mission_date date;
  v_reward jsonb;
  v_depo_level bigint := 0;
  v_crystal_depo_level bigint := 0;
  v_storage bigint := 10000;
  v_crystal_storage bigint := 10000;
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
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR p_mission_id IS NULL
     OR btrim(p_mission_id) = '' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz günlük görev isteği.'
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
  v_mission_date := (v_server_time AT TIME ZONE 'Europe/Istanbul')::date;

  SELECT *
  INTO v_mission
  FROM public.game_daily_missions m
  WHERE m.id = p_mission_id
    AND m.active IS TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'DAILY_MISSION_NOT_FOUND',
      'message', 'Günlük görev bulunamadı.'
    );
  END IF;

  v_guide := public.nexora_refresh_beginner_guide(p_player_id);

  IF COALESCE((v_guide ->> 'completed')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'DAILY_MISSIONS_LOCKED',
      'message', 'Günlük görevler Başlangıç Rehberi tamamlanınca açılır.',
      'snapshot', public.nexora_daily_missions_snapshot(p_player_id)
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.player_daily_mission_claims c
    WHERE c.player_id = p_player_id
      AND c.mission_date = v_mission_date
      AND c.mission_id = v_mission.id
  ) THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu günlük görev ödülü bugün zaten alındı.',
      'snapshot', public.nexora_daily_missions_snapshot(p_player_id)
    );
  END IF;

  v_progress := public.nexora_daily_progress_value(
    p_player_id,
    v_mission.metric_key,
    v_mission_date
  );

  IF v_progress < v_mission.target_value THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'DAILY_MISSION_INCOMPLETE',
      'message', 'Günlük görev henüz tamamlanmadı.',
      'progress', LEAST(v_progress, v_mission.target_value),
      'target', v_mission.target_value
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

  v_storage := 10000 + GREATEST(v_depo_level, 0) * 5000;
  v_crystal_storage := 10000 + GREATEST(v_crystal_depo_level, 0) * 5000;
  v_reward := COALESCE(v_mission.reward, '{}'::jsonb);

  v_reward_metal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'metal', '')::bigint, 0));
  v_reward_energy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'energy', '')::bigint, 0));
  v_reward_alloy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'alloy', '')::bigint, 0));
  v_reward_crystal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'crystal', '')::bigint, 0));


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

  INSERT INTO public.player_daily_mission_claims(
    player_id,
    mission_date,
    mission_id,
    claimed_at,
    reward
  )
  VALUES(
    p_player_id,
    v_mission_date,
    v_mission.id,
    v_server_time,
    v_credited
  );

  RETURN jsonb_build_object(
    'success', true,
    'alreadyClaimed', false,
    'message', 'Günlük görev ödülü alındı.',
    'dayKey', to_char(v_mission_date, 'YYYY-MM-DD'),
    'rewardConfigured', v_reward,
    'rewardCredited', v_credited,
    'snapshot', public.nexora_daily_missions_snapshot(p_player_id)
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.nexora_claim_progression_mission(p_player_id bigint, p_mission_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_mission public.game_progression_missions%ROWTYPE;
  v_current public.game_progression_missions%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_guide jsonb;
  v_progress bigint := 0;
  v_reward jsonb;
  v_depo_level bigint := 0;
  v_crystal_depo_level bigint := 0;
  v_storage bigint := 10000;
  v_crystal_storage bigint := 10000;
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
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR p_mission_id IS NULL
     OR btrim(p_mission_id) = '' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz ilerleme görevi isteği.'
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

  SELECT *
  INTO v_mission
  FROM public.game_progression_missions m
  WHERE m.id = p_mission_id
    AND m.active IS TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PROGRESSION_MISSION_NOT_FOUND',
      'message', 'İlerleme görevi bulunamadı.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.player_progression_claims c
    WHERE c.player_id = p_player_id
      AND c.mission_id = v_mission.id
  ) THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu ilerleme görevi ödülü zaten alındı.',
      'snapshot', public.nexora_progression_snapshot(p_player_id)
    );
  END IF;

  v_guide := public.nexora_refresh_beginner_guide(p_player_id);

  IF COALESCE((v_guide ->> 'completed')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PROGRESSION_LOCKED',
      'message', 'Uzun vadeli ilerleme yolu Başlangıç Rehberi tamamlanınca açılır.',
      'snapshot', public.nexora_progression_snapshot(p_player_id)
    );
  END IF;

  SELECT m.*
  INTO v_current
  FROM public.game_progression_missions m
  WHERE m.active IS TRUE
    AND NOT EXISTS (
      SELECT 1
      FROM public.player_progression_claims c
      WHERE c.player_id = p_player_id
        AND c.mission_id = m.id
    )
  ORDER BY m.stage_order, m.id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PROGRESSION_COMPLETE',
      'message', 'Uzun vadeli ilerleme yolunun tüm aşamaları tamamlandı.',
      'snapshot', public.nexora_progression_snapshot(p_player_id)
    );
  END IF;

  IF v_current.id <> v_mission.id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PROGRESSION_STAGE_LOCKED',
      'message', 'Önce mevcut ilerleme aşamasını tamamlamalısın.',
      'snapshot', public.nexora_progression_snapshot(p_player_id)
    );
  END IF;

  v_progress := public.nexora_progression_value(
    p_player_id,
    v_mission.metric_key
  );

  IF v_progress < v_mission.target_value THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PROGRESSION_MISSION_INCOMPLETE',
      'message', 'İlerleme görevi henüz tamamlanmadı.',
      'progress', LEAST(v_progress, v_mission.target_value),
      'target', v_mission.target_value
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

  v_storage := 10000 + GREATEST(v_depo_level, 0) * 5000;
  v_crystal_storage := 10000 + GREATEST(v_crystal_depo_level, 0) * 5000;
  v_reward := COALESCE(v_mission.reward, '{}'::jsonb);

  v_reward_metal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'metal', '')::bigint, 0));
  v_reward_energy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'energy', '')::bigint, 0));
  v_reward_alloy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'alloy', '')::bigint, 0));
  v_reward_crystal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'crystal', '')::bigint, 0));


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

  INSERT INTO public.player_progression_claims(
    player_id,
    mission_id,
    claimed_at,
    reward
  )
  VALUES(
    p_player_id,
    v_mission.id,
    clock_timestamp(),
    v_credited
  );

  RETURN jsonb_build_object(
    'success', true,
    'alreadyClaimed', false,
    'message', 'İlerleme görevi ödülü alındı.',
    'rewardConfigured', v_reward,
    'rewardCredited', v_credited,
    'snapshot', public.nexora_progression_snapshot(p_player_id)
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.nexora_claim_weekly_mission(p_player_id bigint, p_mission_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_mission public.game_weekly_missions%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_guide jsonb;
  v_progress bigint := 0;
  v_server_time timestamptz;
  v_week_start date;
  v_reward jsonb;
  v_depo_level bigint := 0;
  v_crystal_depo_level bigint := 0;
  v_storage bigint := 10000;
  v_crystal_storage bigint := 10000;
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
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR p_mission_id IS NULL
     OR btrim(p_mission_id) = '' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz haftalık görev isteği.'
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
  v_week_start :=
    date_trunc('week', v_server_time AT TIME ZONE 'Europe/Istanbul')::date;

  SELECT *
  INTO v_mission
  FROM public.game_weekly_missions m
  WHERE m.id = p_mission_id
    AND m.active IS TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WEEKLY_MISSION_NOT_FOUND',
      'message', 'Haftalık görev bulunamadı.'
    );
  END IF;

  v_guide := public.nexora_refresh_beginner_guide(p_player_id);

  IF COALESCE((v_guide ->> 'completed')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WEEKLY_MISSIONS_LOCKED',
      'message', 'Haftalık görevler Başlangıç Rehberi tamamlanınca açılır.',
      'snapshot', public.nexora_weekly_missions_snapshot(p_player_id)
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.player_weekly_mission_claims c
    WHERE c.player_id = p_player_id
      AND c.week_start = v_week_start
      AND c.mission_id = v_mission.id
  ) THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu haftalık görev ödülü bu hafta zaten alındı.',
      'snapshot', public.nexora_weekly_missions_snapshot(p_player_id)
    );
  END IF;

  v_progress := public.nexora_weekly_progress_value(
    p_player_id,
    v_mission.metric_key,
    v_week_start
  );

  IF v_progress < v_mission.target_value THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WEEKLY_MISSION_INCOMPLETE',
      'message', 'Haftalık görev henüz tamamlanmadı.',
      'progress', LEAST(v_progress, v_mission.target_value),
      'target', v_mission.target_value
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

  v_storage := 10000 + GREATEST(v_depo_level, 0) * 5000;
  v_crystal_storage := 10000 + GREATEST(v_crystal_depo_level, 0) * 5000;
  v_reward := COALESCE(v_mission.reward, '{}'::jsonb);

  v_reward_metal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'metal', '')::bigint, 0));
  v_reward_energy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'energy', '')::bigint, 0));
  v_reward_alloy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'alloy', '')::bigint, 0));
  v_reward_crystal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'crystal', '')::bigint, 0));


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

  INSERT INTO public.player_weekly_mission_claims(
    player_id,
    week_start,
    mission_id,
    claimed_at,
    reward
  )
  VALUES(
    p_player_id,
    v_week_start,
    v_mission.id,
    v_server_time,
    v_credited
  );

  RETURN jsonb_build_object(
    'success', true,
    'alreadyClaimed', false,
    'message', 'Haftalık görev ödülü alındı.',
    'weekKey', to_char(v_week_start, 'YYYY-MM-DD'),
    'rewardConfigured', v_reward,
    'rewardCredited', v_credited,
    'snapshot', public.nexora_weekly_missions_snapshot(p_player_id)
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.nexora_claim_alliance_mission_chest(p_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_server_time timestamptz := clock_timestamp();
  v_week_start date;
  v_alliance_id bigint;
  v_alliance_name text;
  v_core_count bigint := 0;
  v_completed_count bigint := 0;
  v_city public.cities%ROWTYPE;
  v_reward jsonb :=
    '{"metal":800,"energy":400,"alloy":800,"crystal":200}'::jsonb;
  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_alloy bigint := 0;
  v_credit_crystal bigint := 0;
  v_credited jsonb;
  v_existing jsonb;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz ittifak görevi ödül isteği.'
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

  v_week_start :=
    date_trunc(
      'week',
      v_server_time AT TIME ZONE 'Europe/Istanbul'
    )::date;

  SELECT a.id, a.name
  INTO v_alliance_id, v_alliance_name
  FROM public.alliance_members am
  JOIN public.alliances a
    ON a.id = am.alliance_id
  WHERE am.player_id = p_player_id
  LIMIT 1;

  IF v_alliance_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_IN_ALLIANCE',
      'message', 'Bir ittifakta olmalısın.'
    );
  END IF;

  PERFORM id
  FROM public.alliances
  WHERE id = v_alliance_id
  FOR UPDATE;

  SELECT c.reward
  INTO v_existing
  FROM public.player_alliance_mission_chest_claims c
  WHERE c.player_id = p_player_id
    AND c.alliance_id = v_alliance_id
    AND c.week_start = v_week_start
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu haftanın ittifak sandığını zaten aldın.',
      'weekKey', to_char(v_week_start, 'YYYY-MM-DD'),
      'allianceId', v_alliance_id,
      'reward', v_reward,
      'creditedReward', COALESCE(v_existing, '{}'::jsonb),
      'snapshot', public.nexora_alliance_missions_snapshot(p_player_id)
    );
  END IF;

  SELECT COUNT(*)::bigint
  INTO v_core_count
  FROM public.game_alliance_missions m
  WHERE m.active IS TRUE;

  SELECT COUNT(*)::bigint
  INTO v_completed_count
  FROM public.game_alliance_missions m
  WHERE m.active IS TRUE
    AND public.nexora_alliance_metric_value(
          v_alliance_id,
          m.metric_key,
          v_week_start
        ) >= m.target_value;

  IF v_core_count <= 0 OR v_completed_count < v_core_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ALLIANCE_MISSIONS_INCOMPLETE',
      'message', 'İttifak haftalık görevleri henüz tamamlanmadı.',
      'completedCount', v_completed_count,
      'totalCount', v_core_count,
      'snapshot', public.nexora_alliance_missions_snapshot(p_player_id)
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
      'message', 'Şehir bulunamadı.'
    );
  END IF;


  v_credit_metal := 800;
  v_credit_energy := 400;
  v_credit_alloy := 800;
  v_credit_crystal := 200;

  v_credited := jsonb_build_object(
    'metal', v_credit_metal,
    'energy', v_credit_energy,
    'alloy', v_credit_alloy,
    'crystal', v_credit_crystal
  );

  INSERT INTO public.player_alliance_mission_chest_claims(
    player_id,
    alliance_id,
    week_start,
    claimed_at,
    reward
  )
  VALUES(
    p_player_id,
    v_alliance_id,
    v_week_start,
    clock_timestamp(),
    v_credited
  )
  ON CONFLICT (player_id, alliance_id, week_start) DO NOTHING;

  IF NOT FOUND THEN
    SELECT c.reward
    INTO v_existing
    FROM public.player_alliance_mission_chest_claims c
    WHERE c.player_id = p_player_id
      AND c.alliance_id = v_alliance_id
      AND c.week_start = v_week_start
    LIMIT 1;

    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu haftanın ittifak sandığını zaten aldın.',
      'weekKey', to_char(v_week_start, 'YYYY-MM-DD'),
      'allianceId', v_alliance_id,
      'reward', v_reward,
      'creditedReward', COALESCE(v_existing, '{}'::jsonb),
      'snapshot', public.nexora_alliance_missions_snapshot(p_player_id)
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
    v_alliance_id,
    'alliance_mission_chest_claimed',
    p_player_id,
    jsonb_build_object(
      'weekKey', to_char(v_week_start, 'YYYY-MM-DD'),
      'allianceName', v_alliance_name
    ),
    clock_timestamp()
  );

  RETURN jsonb_build_object(
    'success', true,
    'alreadyClaimed', false,
    'message', 'İttifak haftalık sandığı alındı.',
    'weekKey', to_char(v_week_start, 'YYYY-MM-DD'),
    'allianceId', v_alliance_id,
    'reward', v_reward,
    'creditedReward', v_credited,
    'snapshot', public.nexora_alliance_missions_snapshot(p_player_id)
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.nexora_claim_boss_first_kill(p_player_id bigint, p_camp_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_profile public.game_boss_reward_profiles%ROWTYPE;
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
     OR p_camp_id IS NULL
     OR p_camp_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz boss ilk zafer ödülü isteği.'
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

  SELECT p.*
  INTO v_profile
  FROM public.game_boss_reward_profiles p
  JOIN public.npc_camps c
    ON c.id = p.npc_camp_id
  WHERE p.npc_camp_id = p_camp_id
    AND p.active IS TRUE
    AND c.active IS TRUE
    AND c.encounter_class = 'boss'
  LIMIT 1;

  IF v_profile.npc_camp_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'BOSS_NOT_FOUND',
      'message', 'Boss ödül profili bulunamadı.'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.player_boss_kills k
    WHERE k.player_id = p_player_id
      AND k.npc_camp_id = p_camp_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FIRST_KILL_REQUIRED',
      'message', 'Bu bossu henüz yenmedin.'
    );
  END IF;

  SELECT c.reward
  INTO v_existing
  FROM public.player_boss_reward_claims c
  WHERE c.player_id = p_player_id
    AND c.reward_kind = 'first_kill'
    AND c.reward_key = p_camp_id::text
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu bossun ilk zafer ödülünü zaten aldın.',
      'creditedReward', COALESCE(v_existing, '{}'::jsonb),
      'snapshot', public.nexora_boss_rewards_snapshot(p_player_id)
    );
  END IF;

  v_configured := v_profile.first_kill_reward;

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
      'code', 'BOSS_REWARD_INVALID',
      'message', 'Boss ilk zafer ödülü yapılandırması geçersiz.'
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

  INSERT INTO public.player_boss_reward_claims(
    player_id,
    reward_kind,
    reward_key,
    npc_camp_id,
    week_start,
    configured_reward,
    reward,
    claimed_at
  )
  VALUES(
    p_player_id,
    'first_kill',
    p_camp_id::text,
    p_camp_id,
    NULL,
    v_configured,
    v_credited,
    clock_timestamp()
  )
  ON CONFLICT (player_id, reward_kind, reward_key) DO NOTHING;

  IF NOT FOUND THEN
    SELECT c.reward
    INTO v_existing
    FROM public.player_boss_reward_claims c
    WHERE c.player_id = p_player_id
      AND c.reward_kind = 'first_kill'
      AND c.reward_key = p_camp_id::text
    LIMIT 1;

    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu bossun ilk zafer ödülünü zaten aldın.',
      'creditedReward', COALESCE(v_existing, '{}'::jsonb),
      'snapshot', public.nexora_boss_rewards_snapshot(p_player_id)
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

  RETURN jsonb_build_object(
    'success', true,
    'alreadyClaimed', false,
    'message', 'Boss ilk zafer ödülü alındı.',
    'configuredReward', v_configured,
    'creditedReward', v_credited,
    'snapshot', public.nexora_boss_rewards_snapshot(p_player_id)
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.nexora_claim_weekly_boss_reward(p_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_server_time timestamptz := clock_timestamp();
  v_week_start date;
  v_city public.cities%ROWTYPE;
  v_configured jsonb := '{}'::jsonb;
  v_existing jsonb;
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
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz haftalık boss ödülü isteği.'
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

  v_week_start :=
    date_trunc(
      'week',
      v_server_time AT TIME ZONE 'Europe/Istanbul'
    )::date;

  SELECT p.weekly_reward
  INTO v_configured
  FROM public.player_boss_kills k
  JOIN public.game_boss_reward_profiles p
    ON p.npc_camp_id = k.npc_camp_id
   AND p.active IS TRUE
  JOIN public.npc_camps c
    ON c.id = k.npc_camp_id
   AND c.encounter_class = 'boss'
  WHERE k.player_id = p_player_id
    AND k.killed_at >=
      v_week_start::timestamp AT TIME ZONE 'Europe/Istanbul'
    AND k.killed_at <
      (v_week_start + 7)::timestamp AT TIME ZONE 'Europe/Istanbul'
  ORDER BY c.tier DESC, k.killed_at DESC
  LIMIT 1;

  IF v_configured IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WEEKLY_BOSS_KILL_REQUIRED',
      'message', 'Bu hafta henüz bir boss yenmedin.'
    );
  END IF;

  SELECT c.reward
  INTO v_existing
  FROM public.player_boss_reward_claims c
  WHERE c.player_id = p_player_id
    AND c.reward_kind = 'weekly'
    AND c.reward_key = to_char(v_week_start, 'YYYY-MM-DD')
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu haftanın boss sandığını zaten aldın.',
      'weekKey', to_char(v_week_start, 'YYYY-MM-DD'),
      'creditedReward', COALESCE(v_existing, '{}'::jsonb),
      'snapshot', public.nexora_boss_rewards_snapshot(p_player_id)
    );
  END IF;

  IF jsonb_typeof(v_configured) IS DISTINCT FROM 'object'
     OR EXISTS (
       SELECT 1
       FROM jsonb_each_text(v_configured) r(key, value)
       WHERE key NOT IN ('metal', 'energy', 'alloy', 'crystal')
          OR value !~ '^[0-9]+$'
          OR char_length(value) > 12
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'BOSS_REWARD_INVALID',
      'message', 'Haftalık boss ödülü yapılandırması geçersiz.'
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

  INSERT INTO public.player_boss_reward_claims(
    player_id,
    reward_kind,
    reward_key,
    npc_camp_id,
    week_start,
    configured_reward,
    reward,
    claimed_at
  )
  VALUES(
    p_player_id,
    'weekly',
    to_char(v_week_start, 'YYYY-MM-DD'),
    NULL,
    v_week_start,
    v_configured,
    v_credited,
    clock_timestamp()
  )
  ON CONFLICT (player_id, reward_kind, reward_key) DO NOTHING;

  IF NOT FOUND THEN
    SELECT c.reward
    INTO v_existing
    FROM public.player_boss_reward_claims c
    WHERE c.player_id = p_player_id
      AND c.reward_kind = 'weekly'
      AND c.reward_key = to_char(v_week_start, 'YYYY-MM-DD')
    LIMIT 1;

    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu haftanın boss sandığını zaten aldın.',
      'weekKey', to_char(v_week_start, 'YYYY-MM-DD'),
      'creditedReward', COALESCE(v_existing, '{}'::jsonb),
      'snapshot', public.nexora_boss_rewards_snapshot(p_player_id)
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

  RETURN jsonb_build_object(
    'success', true,
    'alreadyClaimed', false,
    'message', 'Haftalık boss sandığı alındı.',
    'weekKey', to_char(v_week_start, 'YYYY-MM-DD'),
    'configuredReward', v_configured,
    'creditedReward', v_credited,
    'snapshot', public.nexora_boss_rewards_snapshot(p_player_id)
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.nexora_claim_alliance_level_reward(p_player_id bigint, p_level integer)
 RETURNS jsonb
 LANGUAGE plpgsql
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
$function$


CREATE OR REPLACE FUNCTION public.nexora_resolve_military_mission(p_player_id bigint, p_mission_id bigint, p_defender_snapshot jsonb, p_defender_losses jsonb, p_report_base jsonb, p_attack_power integer, p_defense_power integer, p_loot_rate numeric, p_battle_points integer, p_winner_player_id bigint, p_return_seconds integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  probe public.military_missions%ROWTYPE;
  mission public.military_missions%ROWTYPE;
  attacker public.cities%ROWTYPE;
  defender public.cities%ROWTYPE;
  unit_row public.units%ROWTYPE;
  snapshot_item jsonb;
  snapshot_id_text text;
  snapshot_type text;
  snapshot_quantity_text text;
  snapshot_level_text text;
  snapshot_id bigint;
  snapshot_quantity bigint;
  snapshot_level integer;
  snapshot_count integer;
  snapshot_distinct_types integer;
  live_positive_count integer;
  loss_key text;
  loss_text text;
  loss_quantity bigint;
  resource_name text;
  amount bigint;
  loot jsonb := '{"metal":0,"energy":0,"alloy":0,"crystal":0}'::jsonb;
  battle_result text;
  expected_winner bigint;
  battle_at timestamptz;
  return_at timestamptz;
  report jsonb;
  report_id bigint;
  report_result_udt text;
BEGIN
  IF p_player_id IS NULL OR p_mission_id IS NULL OR p_mission_id <= 0 THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_MISSION','message','Geçersiz sefer.');
  END IF;

  SELECT * INTO probe
  FROM public.military_missions
  WHERE id = p_mission_id;

  IF probe.id IS NULL THEN
    RETURN jsonb_build_object('success',false,'code','MISSION_NOT_FOUND','message','Sefer bulunamadı.');
  END IF;

  IF p_player_id IS DISTINCT FROM probe.attacker_player_id
     AND p_player_id IS DISTINCT FROM probe.defender_player_id THEN
    RETURN jsonb_build_object('success',false,'code','FORBIDDEN','message','Bu sefere erişemezsin.');
  END IF;

  PERFORM id
  FROM public.cities
  WHERE id IN (probe.attacker_city_id, probe.defender_city_id)
  ORDER BY id
  FOR UPDATE;

  SELECT * INTO mission
  FROM public.military_missions
  WHERE id = p_mission_id
  FOR UPDATE;

  IF mission.id IS NULL THEN
    RETURN jsonb_build_object('success',false,'code','MISSION_NOT_FOUND','message','Sefer bulunamadı.');
  END IF;

  IF p_player_id IS DISTINCT FROM mission.attacker_player_id
     AND p_player_id IS DISTINCT FROM mission.defender_player_id THEN
    RETURN jsonb_build_object('success',false,'code','FORBIDDEN','message','Bu sefere erişemezsin.');
  END IF;

  IF mission.status IN ('returning','completed') THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyResolved', true,
      'mission', to_jsonb(mission),
      'loot', COALESCE(mission.settled_loot, mission.result->'loot', loot)
    );
  END IF;

  IF mission.status IS DISTINCT FROM 'resolving' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_STATE',
      'message', 'Sefer çözüm aşamasında değil.'
    );
  END IF;

  SELECT * INTO attacker FROM public.cities WHERE id = mission.attacker_city_id;
  SELECT * INTO defender FROM public.cities WHERE id = mission.defender_city_id;
  IF attacker.id IS NULL OR defender.id IS NULL THEN
    RETURN jsonb_build_object('success',false,'code','CITY_NOT_FOUND','message','Savaş kolonilerinden biri bulunamadı.');
  END IF;

  IF p_attack_power IS NULL OR p_attack_power < 0
     OR p_defense_power IS NULL OR p_defense_power < 0
     OR p_battle_points IS NULL OR p_battle_points < 0
     OR p_return_seconds IS NULL OR p_return_seconds < 1 OR p_return_seconds > 86400
     OR p_loot_rate IS NULL OR p_loot_rate NOT IN (0::numeric,0.10::numeric) THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_RESULT','message','Geçersiz savaş sonucu.');
  END IF;

  IF p_report_base IS NULL OR jsonb_typeof(p_report_base) IS DISTINCT FROM 'object'
     OR jsonb_typeof(COALESCE(p_report_base->'attackerLosses','{}'::jsonb)) IS DISTINCT FROM 'object'
     OR jsonb_typeof(COALESCE(p_report_base->'survivorArmy','[]'::jsonb)) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_REPORT','message','Geçersiz savaş raporu.');
  END IF;

  battle_result := p_report_base->>'result';
  IF battle_result IS NULL OR battle_result NOT IN ('Zafer','Yenilgi','Beraberlik') THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_RESULT','message','Geçersiz savaş sonucu.');
  END IF;

  expected_winner := CASE
    WHEN battle_result = 'Zafer' THEN mission.attacker_player_id
    WHEN battle_result = 'Yenilgi' THEN mission.defender_player_id
    ELSE NULL
  END;

  IF p_winner_player_id IS DISTINCT FROM expected_winner THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_WINNER','message','Savaş kazananı doğrulanamadı.');
  END IF;

  IF (battle_result = 'Zafer' AND p_loot_rate <> 0.10::numeric)
     OR (battle_result <> 'Zafer' AND p_loot_rate <> 0::numeric) THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_LOOT','message','Yağma oranı savaş sonucuyla uyuşmuyor.');
  END IF;

  IF p_defender_snapshot IS NULL OR jsonb_typeof(p_defender_snapshot) IS DISTINCT FROM 'array'
     OR p_defender_losses IS NULL OR jsonb_typeof(p_defender_losses) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_DEFENSE','message','Geçersiz savunma verisi.');
  END IF;

  PERFORM id
  FROM public.units
  WHERE city_id = mission.defender_city_id
  ORDER BY id
  FOR UPDATE;

  SELECT COUNT(*) INTO live_positive_count
  FROM public.units
  WHERE city_id = mission.defender_city_id
    AND COALESCE(quantity,0) > 0;

  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
  INTO snapshot_count, snapshot_distinct_types
  FROM jsonb_array_elements(p_defender_snapshot) AS s(value);

  IF snapshot_count <> live_positive_count
     OR snapshot_distinct_types <> snapshot_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'DEFENDER_CHANGED',
      'message', 'Savunma ordusu değişti; savaş yeniden hesaplanmalı.'
    );
  END IF;

  FOR snapshot_item IN
    SELECT value FROM jsonb_array_elements(p_defender_snapshot) AS s(value)
  LOOP
    IF jsonb_typeof(snapshot_item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_DEFENSE','message','Geçersiz savunma verisi.');
    END IF;

    snapshot_id_text := snapshot_item->>'id';
    snapshot_type := snapshot_item->>'unit_type';
    snapshot_quantity_text := snapshot_item->>'quantity';
    snapshot_level_text := snapshot_item->>'level';

    IF snapshot_id_text IS NULL OR snapshot_id_text !~ '^[1-9][0-9]*$'
       OR char_length(snapshot_id_text) > 19
       OR snapshot_type IS NULL
       OR snapshot_type NOT IN ('piyade','savunma','saldiri','okcu','tank','hava')
       OR snapshot_quantity_text IS NULL OR snapshot_quantity_text !~ '^[1-9][0-9]*$'
       OR char_length(snapshot_quantity_text) > 10
       OR snapshot_level_text IS NULL OR snapshot_level_text !~ '^[1-9][0-9]*$'
       OR char_length(snapshot_level_text) > 2 THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_DEFENSE','message','Geçersiz savunma verisi.');
    END IF;

    snapshot_id := snapshot_id_text::bigint;
    snapshot_quantity := snapshot_quantity_text::bigint;
    snapshot_level := snapshot_level_text::integer;

    IF snapshot_quantity > 2147483647 OR snapshot_level < 1 OR snapshot_level > 15 THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_DEFENSE','message','Geçersiz savunma verisi.');
    END IF;

    SELECT * INTO unit_row
    FROM public.units
    WHERE id = snapshot_id
      AND city_id = mission.defender_city_id
      AND unit_type = snapshot_type
    LIMIT 1;

    IF unit_row.id IS NULL
       OR COALESCE(unit_row.quantity,0) <> snapshot_quantity
       OR GREATEST(1,COALESCE(unit_row.level,1)) <> snapshot_level THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'DEFENDER_CHANGED',
        'message', 'Savunma ordusu değişti; savaş yeniden hesaplanmalı.'
      );
    END IF;
  END LOOP;

  FOR loss_key, loss_text IN
    SELECT key, value FROM jsonb_each_text(p_defender_losses)
  LOOP
    IF loss_key NOT IN ('piyade','savunma','saldiri','okcu','tank','hava')
       OR loss_text IS NULL OR loss_text !~ '^[0-9]+$'
       OR char_length(loss_text) > 10 THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_LOSSES','message','Geçersiz savunma kaybı.');
    END IF;

    loss_quantity := loss_text::bigint;
    IF loss_quantity > 2147483647 THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_LOSSES','message','Geçersiz savunma kaybı.');
    END IF;

    IF loss_quantity > 0 AND NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_defender_snapshot) s(value)
      WHERE value->>'unit_type' = loss_key
        AND (value->>'quantity')::bigint >= loss_quantity
    ) THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_LOSSES','message','Savunma kaybı mevcut birlikten fazla.');
    END IF;
  END LOOP;

  FOR snapshot_item IN
    SELECT value FROM jsonb_array_elements(p_defender_snapshot) AS s(value)
  LOOP
    snapshot_id := (snapshot_item->>'id')::bigint;
    snapshot_type := snapshot_item->>'unit_type';
    snapshot_quantity := (snapshot_item->>'quantity')::bigint;
    loss_quantity := COALESCE((p_defender_losses->>snapshot_type)::bigint,0);

    IF loss_quantity < 0 OR loss_quantity > snapshot_quantity THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_LOSSES','message','Savunma kaybı mevcut birlikten fazla.');
    END IF;

    IF loss_quantity > 0 THEN
      UPDATE public.units
      SET quantity = quantity - loss_quantity
      WHERE id = snapshot_id;
    END IF;
  END LOOP;

  IF mission.settled_loot IS NOT NULL THEN
    loot := mission.settled_loot;
  ELSIF p_loot_rate > 0 THEN
    FOREACH resource_name IN ARRAY ARRAY['metal','energy','alloy','crystal'] LOOP
      amount := FLOOR(
          GREATEST(0,COALESCE((to_jsonb(defender)->>resource_name)::bigint,0))
          * p_loot_rate
        )::bigint;

      EXECUTE format(
        'UPDATE public.cities SET %1$I=COALESCE(%1$I,0)-$1 WHERE id=$2',
        resource_name
      ) USING amount, defender.id;

      EXECUTE format(
        'UPDATE public.cities SET %1$I=COALESCE(%1$I,0)+$1 WHERE id=$2',
        resource_name
      ) USING amount, attacker.id;

      loot := jsonb_set(loot,ARRAY[resource_name],to_jsonb(amount));
    END LOOP;
  END IF;

  battle_at := clock_timestamp();
  return_at := battle_at + make_interval(secs => p_return_seconds);

  report := p_report_base || jsonb_build_object(
    'result', battle_result,
    'attackPower', p_attack_power,
    'defensePower', p_defense_power,
    'defenderLosses', p_defender_losses,
    'loot', loot,
    'returnAt', return_at,
    'battleAt', battle_at,
    'battlePoints', p_battle_points,
    'winnerPlayerId', p_winner_player_id
  );

  SELECT c.udt_name
  INTO report_result_udt
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'battle_reports'
    AND c.column_name = 'result';

  IF report_result_udt IN ('json','jsonb') THEN
    INSERT INTO public.battle_reports(
      attacker_player_id, defender_player_id, result, attack_power, defense_power,
      attacker_losses, defender_losses, loot, battle_points, winner_player_id
    ) VALUES (
      mission.attacker_player_id, mission.defender_player_id, report,
      p_attack_power, p_defense_power,
      COALESCE(p_report_base->'attackerLosses','{}'::jsonb),
      p_defender_losses, loot, p_battle_points, p_winner_player_id
    )
    RETURNING id INTO report_id;
  ELSE
    INSERT INTO public.battle_reports(
      attacker_player_id, defender_player_id, result, attack_power, defense_power,
      attacker_losses, defender_losses, loot, battle_points, winner_player_id
    ) VALUES (
      mission.attacker_player_id, mission.defender_player_id, report::text,
      p_attack_power, p_defense_power,
      COALESCE(p_report_base->'attackerLosses','{}'::jsonb),
      p_defender_losses, loot, p_battle_points, p_winner_player_id
    )
    RETURNING id INTO report_id;
  END IF;

  UPDATE public.military_missions
  SET status = 'returning',
      arrive_at = return_at,
      attack_power = p_attack_power,
      result = report,
      settled_loot = loot
  WHERE id = mission.id
  RETURNING * INTO mission;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyResolved', false,
    'mission', to_jsonb(mission),
    'battleReportId', report_id,
    'loot', loot
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.nexora_settle_mission_loot(p_player_id bigint, p_mission_id bigint, p_loot_rate numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  probe public.military_missions%ROWTYPE;
  m public.military_missions%ROWTYPE;
  attacker public.cities%ROWTYPE;
  defender public.cities%ROWTYPE;
  loot jsonb := '{"metal":0,"energy":0,"alloy":0,"crystal":0}'::jsonb;
  resource text;
  amount bigint;
BEGIN
  IF p_loot_rate IS NULL OR p_loot_rate NOT IN (0,0.10) THEN RAISE EXCEPTION 'Geçersiz yağma oranı.'; END IF;
  SELECT * INTO probe FROM public.military_missions WHERE id=p_mission_id;
  IF probe.id IS NULL OR p_player_id IS NULL OR (p_player_id IS DISTINCT FROM probe.attacker_player_id AND p_player_id IS DISTINCT FROM probe.defender_player_id) THEN RAISE EXCEPTION 'Bu sefere erişemezsin.'; END IF;
  -- Same two-city order as Trade V2. Never acquire an offer or trade transaction.
  PERFORM id FROM public.cities WHERE id IN (probe.attacker_city_id,probe.defender_city_id) ORDER BY id FOR UPDATE;
  SELECT * INTO m FROM public.military_missions WHERE id=p_mission_id FOR UPDATE;
  IF m.settled_loot IS NOT NULL THEN RETURN jsonb_build_object('success',true,'loot',m.settled_loot); END IF;
  IF m.status IS DISTINCT FROM 'resolving' THEN RAISE EXCEPTION 'Sefer çözüm aşamasında değil.'; END IF;
  SELECT * INTO attacker FROM public.cities WHERE id=m.attacker_city_id;
  SELECT * INTO defender FROM public.cities WHERE id=m.defender_city_id;
  IF attacker.id IS NOT NULL AND defender.id IS NOT NULL AND attacker.id<>defender.id AND p_loot_rate>0 THEN
    FOREACH resource IN ARRAY ARRAY['metal','energy','alloy','crystal'] LOOP
      amount := FLOOR(GREATEST(0,COALESCE((to_jsonb(defender)->>resource)::bigint,0))*p_loot_rate)::bigint;
      -- Identifiers come only from the fixed array above.
      EXECUTE format('UPDATE public.cities SET %1$I=COALESCE(%1$I,0)-$1 WHERE id=$2',resource) USING amount,defender.id;
      EXECUTE format('UPDATE public.cities SET %1$I=COALESCE(%1$I,0)+$1 WHERE id=$2',resource) USING amount,attacker.id;
      loot := jsonb_set(loot,ARRAY[resource],to_jsonb(amount));
    END LOOP;
  END IF;
  UPDATE public.military_missions SET settled_loot=loot WHERE id=m.id;
  RETURN jsonb_build_object('success',true,'loot',loot);
END;
$function$


CREATE OR REPLACE FUNCTION public.nexora_resolve_npc_mission(p_player_id bigint, p_mission_id bigint, p_npc_losses jsonb, p_report_base jsonb, p_attack_power integer, p_defense_power integer, p_return_seconds integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  probe public.npc_missions%ROWTYPE;
  mission public.npc_missions%ROWTYPE;
  v_city public.cities%ROWTYPE;

  v_result text;
  v_expected_result text;

  survivor_item jsonb;
  original_item jsonb;
  survivor_count integer;
  survivor_distinct integer;
  survivor_type text;
  survivor_quantity_text text;
  survivor_level_text text;
  survivor_quantity bigint;
  survivor_level integer;

  original_type text;
  original_quantity bigint;
  original_level integer;

  loss_key text;
  loss_text text;
  loss_quantity bigint;

  npc_item jsonb;
  npc_type text;
  npc_quantity bigint;

  resource_name text;
  reward_text text;
  reward_amount bigint;
  current_amount bigint;
  capacity bigint;
  credit_amount bigint;
  credited_reward jsonb :=
    '{"metal":0,"energy":0,"alloy":0,"crystal":0}'::jsonb;

  v_battle_at timestamptz;
  v_return_at timestamptz;
  v_available_at timestamptz;

  v_report jsonb;
  v_report_id bigint;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR p_mission_id IS NULL OR p_mission_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_MISSION',
      'message', 'Geçersiz PvE seferi.'
    );
  END IF;

  IF p_attack_power IS NULL OR p_attack_power < 0
     OR p_defense_power IS NULL OR p_defense_power < 0
     OR p_return_seconds IS NULL
     OR p_return_seconds < 1
     OR p_return_seconds > 86400 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_RESULT',
      'message', 'Geçersiz PvE savaş sonucu.'
    );
  END IF;

  IF p_report_base IS NULL
     OR jsonb_typeof(p_report_base) IS DISTINCT FROM 'object'
     OR jsonb_typeof(
          COALESCE(p_report_base->'attackerLosses', '{}'::jsonb)
        ) IS DISTINCT FROM 'object'
     OR jsonb_typeof(
          COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
        ) IS DISTINCT FROM 'array'
     OR p_npc_losses IS NULL
     OR jsonb_typeof(p_npc_losses) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_REPORT',
      'message', 'Geçersiz PvE savaş raporu.'
    );
  END IF;

  SELECT *
    INTO probe
    FROM public.npc_missions
   WHERE id = p_mission_id;

  IF probe.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'PvE seferi bulunamadı.'
    );
  END IF;

  IF probe.player_id IS DISTINCT FROM p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu PvE seferine erişemezsin.'
    );
  END IF;

  SELECT *
    INTO v_city
    FROM public.cities
   WHERE id = probe.city_id
     AND player_id = p_player_id
   FOR UPDATE;

  IF v_city.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  SELECT *
    INTO mission
    FROM public.npc_missions
   WHERE id = p_mission_id
   FOR UPDATE;

  IF mission.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'PvE seferi bulunamadı.'
    );
  END IF;

  IF mission.player_id IS DISTINCT FROM p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu PvE seferine erişemezsin.'
    );
  END IF;

  IF mission.status IN ('returning','completed') THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyResolved', true,
      'mission', to_jsonb(mission),
      'reward',
        COALESCE(
          mission.settled_reward,
          mission.result->'reward',
          credited_reward
        )
    );
  END IF;

  IF mission.status IS DISTINCT FROM 'resolving' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_STATE',
      'message', 'PvE seferi çözüm aşamasında değil.'
    );
  END IF;

  IF mission.arrive_at > clock_timestamp() THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'BATTLE_NOT_READY',
      'message', 'PvE seferi henüz hedefe ulaşmadı.'
    );
  END IF;

  v_result := p_report_base->>'result';

  IF v_result IS NULL
     OR v_result NOT IN ('Zafer','Yenilgi','Beraberlik') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_RESULT',
      'message', 'Geçersiz PvE savaş sonucu.'
    );
  END IF;

  v_expected_result := CASE
    WHEN p_attack_power > p_defense_power THEN 'Zafer'
    WHEN p_attack_power < p_defense_power THEN 'Yenilgi'
    ELSE 'Beraberlik'
  END;

  IF v_result IS DISTINCT FROM v_expected_result THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_RESULT',
      'message', 'PvE savaş sonucu güç değerleriyle uyuşmuyor.'
    );
  END IF;

  -- Validate survivor array shape and duplicate types.
  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
    INTO survivor_count, survivor_distinct
    FROM jsonb_array_elements(
      COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
    ) AS survivor(value);

  IF survivor_distinct <> survivor_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_SURVIVORS',
      'message', 'Dönüş ordusunda tekrarlanan birlik türü var.'
    );
  END IF;

  FOR survivor_item IN
    SELECT value
      FROM jsonb_array_elements(
        COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
      ) AS survivor(value)
  LOOP
    IF jsonb_typeof(survivor_item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_SURVIVORS',
        'message', 'Geçersiz dönüş ordusu.'
      );
    END IF;

    survivor_type := survivor_item->>'unit_type';
    survivor_quantity_text := survivor_item->>'quantity';
    survivor_level_text := survivor_item->>'level';

    IF survivor_type IS NULL
       OR survivor_type NOT IN (
         'piyade','savunma','saldiri','okcu','tank','hava'
       )
       OR survivor_quantity_text IS NULL
       OR survivor_quantity_text !~ '^[0-9]+$'
       OR char_length(survivor_quantity_text) > 10
       OR survivor_level_text IS NULL
       OR survivor_level_text !~ '^[1-9][0-9]*$'
       OR char_length(survivor_level_text) > 2 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_SURVIVORS',
        'message', 'Geçersiz dönüş ordusu.'
      );
    END IF;

    survivor_quantity := survivor_quantity_text::bigint;
    survivor_level := survivor_level_text::integer;

    IF survivor_quantity > 2147483647
       OR survivor_level < 1
       OR survivor_level > 15
       OR NOT EXISTS (
         SELECT 1
           FROM jsonb_array_elements(mission.army) original(value)
          WHERE value->>'unit_type' = survivor_type
            AND (value->>'level')::integer = survivor_level
            AND (value->>'quantity')::bigint >= survivor_quantity
       ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_SURVIVORS',
        'message', 'Dönüş ordusu gönderilen ordudan büyük veya uyumsuz.'
      );
    END IF;
  END LOOP;

  -- Loss object may only contain valid unit types and non-negative integers.
  IF EXISTS (
    SELECT 1
      FROM jsonb_each_text(
        COALESCE(p_report_base->'attackerLosses', '{}'::jsonb)
      ) AS losses(key, value)
     WHERE key NOT IN (
       'piyade','savunma','saldiri','okcu','tank','hava'
     )
        OR value !~ '^[0-9]+$'
        OR char_length(value) > 10
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_LOSSES',
      'message', 'Geçersiz saldıran kaybı.'
    );
  END IF;

  -- Exact accounting: survivor + attacker loss must equal each sent quantity.
  FOR original_item IN
    SELECT value
      FROM jsonb_array_elements(mission.army) original(value)
  LOOP
    original_type := original_item->>'unit_type';
    original_quantity := (original_item->>'quantity')::bigint;
    original_level := (original_item->>'level')::integer;

    SELECT COALESCE(MAX((value->>'quantity')::bigint), 0)
      INTO survivor_quantity
      FROM jsonb_array_elements(
        COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
      ) survivor(value)
     WHERE value->>'unit_type' = original_type
       AND (value->>'level')::integer = original_level;

    loss_text :=
      COALESCE(
        p_report_base->'attackerLosses'->>original_type,
        '0'
      );

    IF loss_text !~ '^[0-9]+$'
       OR char_length(loss_text) > 10 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_LOSSES',
        'message', 'Geçersiz saldıran kaybı.'
      );
    END IF;

    loss_quantity := loss_text::bigint;

    IF loss_quantity > 2147483647
       OR survivor_quantity + loss_quantity <> original_quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ACCOUNTING',
        'message', 'Saldıran kayıp ve sağ kalan hesabı uyuşmuyor.'
      );
    END IF;
  END LOOP;

  -- No positive attacker-loss entry may reference a unit type that was not sent.
  IF EXISTS (
    SELECT 1
      FROM jsonb_each_text(
        COALESCE(p_report_base->'attackerLosses', '{}'::jsonb)
      ) losses(key, value)
     WHERE value::bigint > 0
       AND NOT EXISTS (
         SELECT 1
           FROM jsonb_array_elements(mission.army) original(item)
          WHERE item->>'unit_type' = key
       )
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_LOSSES',
      'message', 'Gönderilmeyen birlik türü için kayıp bildirildi.'
    );
  END IF;

  -- Validate NPC loss reporting against the immutable NPC snapshot.
  IF EXISTS (
    SELECT 1
      FROM jsonb_each_text(p_npc_losses) losses(key, value)
     WHERE key NOT IN (
       'piyade','savunma','saldiri','okcu','tank','hava'
     )
        OR value !~ '^[0-9]+$'
        OR char_length(value) > 10
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_NPC_LOSSES',
      'message', 'Geçersiz NPC kaybı.'
    );
  END IF;

  FOR loss_key, loss_text IN
    SELECT key, value
      FROM jsonb_each_text(p_npc_losses)
  LOOP
    loss_quantity := loss_text::bigint;

    IF loss_quantity > 2147483647 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_NPC_LOSSES',
        'message', 'Geçersiz NPC kaybı.'
      );
    END IF;

    SELECT value
      INTO npc_item
      FROM jsonb_array_elements(mission.npc_army) npc(value)
     WHERE value->>'unit_type' = loss_key
     LIMIT 1;

    IF npc_item IS NULL THEN
      IF loss_quantity > 0 THEN
        RETURN jsonb_build_object(
          'success', false,
          'code', 'INVALID_NPC_LOSSES',
          'message', 'NPC ordusunda olmayan birlik türü için kayıp bildirildi.'
        );
      END IF;
      CONTINUE;
    END IF;

    npc_type := npc_item->>'unit_type';
    npc_quantity := (npc_item->>'quantity')::bigint;

    IF npc_type IS DISTINCT FROM loss_key
       OR loss_quantity > npc_quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_NPC_LOSSES',
        'message', 'NPC kaybı mevcut birlikten fazla.'
      );
    END IF;
  END LOOP;

  -- Validate immutable reward snapshot before any credit.
  IF mission.reward_snapshot IS NULL
     OR jsonb_typeof(mission.reward_snapshot) IS DISTINCT FROM 'object'
     OR EXISTS (
       SELECT 1
         FROM jsonb_each_text(mission.reward_snapshot) r(key, value)
        WHERE key NOT IN ('metal','energy','alloy','crystal')
           OR value !~ '^[0-9]+$'
           OR char_length(value) > 12
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_REWARD_INVALID',
      'message', 'NPC ödül yapılandırması geçersiz.'
    );
  END IF;

  -- Only victories credit reward. Capacity overflow is not credited and is
  -- recorded as such in settled_reward.
  IF v_result = 'Zafer' THEN
    FOREACH resource_name IN ARRAY
      ARRAY['metal','energy','alloy','crystal']
    LOOP
      reward_text :=
        COALESCE(mission.reward_snapshot->>resource_name, '0');

      IF reward_text !~ '^[0-9]+$'
         OR char_length(reward_text) > 12 THEN
        RETURN jsonb_build_object(
          'success', false,
          'code', 'NPC_REWARD_INVALID',
          'message', 'NPC ödül yapılandırması geçersiz.'
        );
      END IF;

      reward_amount := reward_text::bigint;

      current_amount := CASE resource_name
        WHEN 'metal' THEN GREATEST(0, COALESCE(v_city.metal, 0))
        WHEN 'energy' THEN GREATEST(0, COALESCE(v_city.energy, 0))
        WHEN 'alloy' THEN GREATEST(0, COALESCE(v_city.alloy, 0))
        WHEN 'crystal' THEN GREATEST(0, COALESCE(v_city.crystal, 0))
        ELSE 0
      END;

      capacity :=
        public.nexora_trade_storage_capacity(
          v_city.id,
          resource_name
        );

      credit_amount := reward_amount;

      IF credit_amount > 0 THEN
        EXECUTE format(
          'UPDATE public.cities
              SET %1$I = COALESCE(%1$I,0) + $1,
                  updated_at = clock_timestamp()
            WHERE id = $2',
          resource_name
        )
        USING credit_amount, v_city.id;
      END IF;

      credited_reward :=
        jsonb_set(
          credited_reward,
          ARRAY[resource_name],
          to_jsonb(credit_amount),
          true
        );
    END LOOP;
  END IF;

  v_battle_at := clock_timestamp();
  v_return_at :=
    v_battle_at + make_interval(secs => p_return_seconds);
  v_available_at :=
    v_battle_at + make_interval(secs => mission.cooldown_seconds);

  v_report :=
    p_report_base
    ||
    jsonb_build_object(
      'result', v_expected_result,
      'attackPower', p_attack_power,
      'defensePower', p_defense_power,
      'npcLosses', p_npc_losses,
      'configuredReward', mission.reward_snapshot,
      'reward', credited_reward,
      'campId', mission.npc_camp_id,
      'campName', mission.camp_name,
      'campTier', mission.camp_tier,
      'battleTactic', mission.battle_tactic,
      'battleAt', v_battle_at,
      'returnAt', v_return_at,
      'campAvailableAt', v_available_at
    );

  INSERT INTO public.npc_battle_reports(
    npc_mission_id,
    player_id,
    npc_camp_id,
    camp_name,
    camp_tier,
    result,
    attack_power,
    defense_power,
    attacker_losses,
    npc_losses,
    reward,
    battle_tactic,
    report,
    created_at
  )
  VALUES(
    mission.id,
    p_player_id,
    mission.npc_camp_id,
    mission.camp_name,
    mission.camp_tier,
    v_expected_result,
    p_attack_power,
    p_defense_power,
    COALESCE(p_report_base->'attackerLosses', '{}'::jsonb),
    p_npc_losses,
    credited_reward,
    mission.battle_tactic,
    v_report,
    v_battle_at
  )
  RETURNING id INTO v_report_id;

  INSERT INTO public.player_npc_camp_state AS state(
    player_id,
    npc_camp_id,
    victories,
    defeats,
    draws,
    last_battle_at,
    available_at,
    updated_at
  )
  VALUES(
    p_player_id,
    mission.npc_camp_id,
    CASE WHEN v_expected_result = 'Zafer' THEN 1 ELSE 0 END,
    CASE WHEN v_expected_result = 'Yenilgi' THEN 1 ELSE 0 END,
    CASE WHEN v_expected_result = 'Beraberlik' THEN 1 ELSE 0 END,
    v_battle_at,
    v_available_at,
    v_battle_at
  )
  ON CONFLICT (player_id, npc_camp_id)
  DO UPDATE SET
    victories =
      state.victories
      + CASE WHEN v_expected_result = 'Zafer' THEN 1 ELSE 0 END,
    defeats =
      state.defeats
      + CASE WHEN v_expected_result = 'Yenilgi' THEN 1 ELSE 0 END,
    draws =
      state.draws
      + CASE WHEN v_expected_result = 'Beraberlik' THEN 1 ELSE 0 END,
    last_battle_at = v_battle_at,
    available_at = v_available_at,
    updated_at = v_battle_at;

  UPDATE public.npc_missions
     SET status = 'returning',
         arrive_at = v_return_at,
         attack_power = p_attack_power,
         defense_power = p_defense_power,
         result = v_report,
         settled_reward = credited_reward,
         updated_at = v_battle_at
   WHERE id = mission.id
   RETURNING * INTO mission;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyResolved', false,
    'mission', to_jsonb(mission),
    'npcBattleReportId', v_report_id,
    'reward', credited_reward,
    'campAvailableAt', v_available_at
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.nexora_resolve_world_exploration(p_player_id bigint, p_mission_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mission world_exploration_missions%ROWTYPE;
  v_city cities%ROWTYPE;
  v_site world_sites%ROWTYPE;
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
  v_result jsonb;
  v_remaining integer;
BEGIN
  SELECT *
    INTO v_mission
    FROM world_exploration_missions
   WHERE id = p_mission_id
     AND player_id = p_player_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'Keşif görevi bulunamadı.'
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

  UPDATE world_exploration_missions
     SET status = 'resolving'
   WHERE id = v_mission.id;

  SELECT *
    INTO v_site
    FROM world_sites
   WHERE id = v_mission.site_id
   LIMIT 1;

  IF NOT FOUND THEN
    UPDATE world_exploration_missions
       SET status = 'traveling'
     WHERE id = v_mission.id;

    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_NOT_FOUND',
      'message', 'Keşif noktası artık bulunamıyor.'
    );
  END IF;

  SELECT *
    INTO v_city
    FROM cities
   WHERE id = v_mission.city_id
     AND player_id = p_player_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    UPDATE world_exploration_missions
       SET status = 'traveling'
     WHERE id = v_mission.id;

    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Keşif görevine ait koloni bulunamadı.'
    );
  END IF;

  SELECT
    COALESCE(SUM(level) FILTER (WHERE building_type = 'Depo'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Kristal Deposu'), 0)
  INTO v_depo_level, v_crystal_depo_level
  FROM buildings
  WHERE city_id = v_city.id;

  v_storage := 10000 + GREATEST(0, v_depo_level) * 5000;
  v_crystal_storage := 10000 + GREATEST(0, v_crystal_depo_level) * 5000;

  -- Öncelik mevcut production reward JSON alanındadır.
  -- JSON anahtarı yoksa taslak/eski reward_* kolonlarına düşer.
  v_reward_metal := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'metal', '')::bigint, v_site.reward_metal, 0));
  v_reward_energy := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'energy', '')::bigint, v_site.reward_energy, 0));
  v_reward_alloy := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'alloy', '')::bigint, v_site.reward_alloy, 0));
  v_reward_crystal := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'crystal', '')::bigint, v_site.reward_crystal, 0));

  v_credit_metal := v_reward_metal;
  v_credit_energy := v_reward_energy;
  v_credit_alloy := v_reward_alloy;
  v_credit_crystal := v_reward_crystal;

  UPDATE cities
     SET metal = COALESCE(metal, 0) + v_credit_metal,
         energy = COALESCE(energy, 0) + v_credit_energy,
         alloy = COALESCE(alloy, 0) + v_credit_alloy,
         crystal = COALESCE(crystal, 0) + v_credit_crystal
   WHERE id = v_city.id;

  v_result := jsonb_build_object(
    'message', v_site.name || ' keşfi tamamlandı.',
    'siteId', v_site.id,
    'siteName', v_site.name,
    'siteType', v_site.site_type,
    'reward', jsonb_build_object(
      'metal', v_credit_metal,
      'energy', v_credit_energy,
      'alloy', v_credit_alloy,
      'crystal', v_credit_crystal
    ),
    'rewardRequested', jsonb_build_object(
      'metal', v_reward_metal,
      'energy', v_reward_energy,
      'alloy', v_reward_alloy,
      'crystal', v_reward_crystal
    )
  );

  UPDATE world_exploration_missions
     SET status = 'completed',
         completed_at = now(),
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
$function$


CREATE OR REPLACE FUNCTION public.nexora_sync_city_production(p_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_city public.cities%ROWTYPE;
  v_now timestamptz := now();
  v_last timestamptz;
  v_elapsed_minutes integer := 0;
  v_metal_level integer := 0;
  v_energy_level integer := 0;
  v_alloy_level integer := 0;
  v_crystal_level integer := 0;
  v_depo_level integer := 0;
  v_crystal_depo_level integer := 0;
  v_production_research integer := 0;
  v_crystal_research integer := 0;
  v_region_bonus jsonb := '{}'::jsonb;
  v_region_bonus_active boolean := false;
  v_region_bonus_key text;
  v_metal_rate numeric := 0;
  v_energy_rate numeric := 0;
  v_alloy_rate numeric := 0;
  v_crystal_rate numeric := 0;
  v_storage bigint := 10000;
  v_crystal_storage bigint := 10000;
  v_add_metal bigint := 0;
  v_add_energy bigint := 0;
  v_add_alloy bigint := 0;
  v_add_crystal bigint := 0;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object('success', false, 'code', 'INVALID_PLAYER', 'message', 'Geçersiz oyuncu.');
  END IF;
  SELECT * INTO v_city FROM public.cities WHERE player_id = p_player_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'code', 'CITY_NOT_FOUND', 'message', 'Koloni bulunamadı.');
  END IF;
  SELECT
    COALESCE(SUM(level) FILTER (WHERE building_type = 'Metal Madeni'),0)::integer,
    COALESCE(SUM(level) FILTER (WHERE building_type = 'Enerji Santrali'),0)::integer,
    COALESCE(SUM(level) FILTER (WHERE building_type = 'Alaşım Rafinerisi'),0)::integer,
    COALESCE(SUM(level) FILTER (WHERE building_type = 'Kristal Madeni'),0)::integer,
    COALESCE(SUM(level) FILTER (WHERE building_type = 'Depo'),0)::integer,
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Kristal Deposu'),0)::integer
  INTO v_metal_level,v_energy_level,v_alloy_level,v_crystal_level,v_depo_level,v_crystal_depo_level
  FROM public.buildings WHERE city_id = v_city.id;
  SELECT COALESCE(production_level,0),COALESCE(crystal_level,0)
    INTO v_production_research,v_crystal_research
    FROM public.research WHERE player_id = p_player_id ORDER BY id LIMIT 1;
  IF NOT FOUND THEN v_production_research := 0; v_crystal_research := 0; END IF;
  v_region_bonus := public.nexora_player_alliance_region_bonus(p_player_id);
  IF COALESCE(v_region_bonus->>'success','false') = 'true' THEN
    v_region_bonus_active := COALESCE((v_region_bonus->>'active')::boolean,false);
    v_region_bonus_key := v_region_bonus->>'bonusKey';
  END IF;
  v_storage := 10000 + GREATEST(0,v_depo_level) * 5000;
  v_crystal_storage := 10000 + GREATEST(0,v_crystal_depo_level) * 5000;
  v_metal_rate := GREATEST(0,v_metal_level) * 12 * (1 + GREATEST(0,v_production_research) * 0.10);
  v_energy_rate := GREATEST(0,v_energy_level) * 6 * (1 + GREATEST(0,v_production_research) * 0.10);
  v_alloy_rate := GREATEST(0,v_alloy_level) * 10 * (1 + GREATEST(0,v_production_research) * 0.10);
  v_crystal_rate := GREATEST(0,v_crystal_level) * 5 * (1 + GREATEST(0,v_crystal_research) * 0.08);
  IF v_region_bonus_active THEN
    CASE v_region_bonus_key
      WHEN 'metal_production' THEN v_metal_rate := v_metal_rate * 1.05;
      WHEN 'energy_production' THEN v_energy_rate := v_energy_rate * 1.05;
      WHEN 'alloy_production' THEN v_alloy_rate := v_alloy_rate * 1.05;
      WHEN 'alloy_production' THEN v_alloy_rate := v_alloy_rate * 1.05;
      WHEN 'crystal_production' THEN v_crystal_rate := v_crystal_rate * 1.05;
      ELSE NULL;
    END CASE;
  END IF;
  v_last := COALESCE(v_city.last_production_at,v_city.updated_at,v_now);
  v_elapsed_minutes := GREATEST(0,FLOOR(EXTRACT(EPOCH FROM (v_now - v_last)) / 60)::integer);
  IF v_elapsed_minutes > 0 THEN
    v_add_metal := FLOOR(v_metal_rate * v_elapsed_minutes)::bigint;
    v_add_energy := FLOOR(v_energy_rate * v_elapsed_minutes)::bigint;
    v_add_alloy := FLOOR(v_alloy_rate * v_elapsed_minutes)::bigint;
    v_add_crystal := FLOOR(v_crystal_rate * v_elapsed_minutes)::bigint;
    UPDATE public.cities
       SET metal = CASE
             WHEN GREATEST(0,COALESCE(metal,0)) >= v_storage
               THEN GREATEST(0,COALESCE(metal,0))
             ELSE LEAST(v_storage,GREATEST(0,COALESCE(metal,0) + v_add_metal))
           END,
           energy = CASE
             WHEN GREATEST(0,COALESCE(energy,0)) >= v_storage
               THEN GREATEST(0,COALESCE(energy,0))
             ELSE LEAST(v_storage,GREATEST(0,COALESCE(energy,0) + v_add_energy))
           END,
           alloy = CASE
             WHEN GREATEST(0,COALESCE(alloy,0)) >= v_storage
               THEN GREATEST(0,COALESCE(alloy,0))
             ELSE LEAST(v_storage,GREATEST(0,COALESCE(alloy,0) + v_add_alloy))
           END,
           crystal = CASE
             WHEN GREATEST(0,COALESCE(crystal,0)) >= v_crystal_storage
               THEN GREATEST(0,COALESCE(crystal,0))
             ELSE LEAST(v_crystal_storage,GREATEST(0,COALESCE(crystal,0) + v_add_crystal))
           END,
           metal_capacity = v_storage,
           energy_capacity = v_storage,
           alloy_capacity = v_storage,
           crystal_capacity = v_crystal_storage,
           last_production_at = v_now,
           updated_at = v_now
     WHERE id = v_city.id RETURNING * INTO v_city;
  ELSE
    UPDATE public.cities
       SET metal_capacity = v_storage,energy_capacity = v_storage,alloy_capacity = v_storage,crystal_capacity = v_crystal_storage
     WHERE id = v_city.id
       AND (metal_capacity IS DISTINCT FROM v_storage OR energy_capacity IS DISTINCT FROM v_storage OR alloy_capacity IS DISTINCT FROM v_storage OR crystal_capacity IS DISTINCT FROM v_crystal_storage)
     RETURNING * INTO v_city;
    IF NOT FOUND THEN SELECT * INTO v_city FROM public.cities WHERE player_id = p_player_id ORDER BY id LIMIT 1; END IF;
  END IF;
  RETURN jsonb_build_object(
    'success', true,
    'city', to_jsonb(v_city),
    'serverTime', v_now,
    'elapsedMinutes', v_elapsed_minutes,
    'production', jsonb_build_object('metalPerMinute', v_metal_rate,'energyPerMinute', v_energy_rate,'alloyPerMinute', v_alloy_rate,'alloyPerMinute', v_alloy_rate,'crystalPerMinute', v_crystal_rate),
    'capacities', jsonb_build_object('storage', v_storage,'alloyStorage', v_storage,'alloyStorage', v_storage,'crystalStorage', v_crystal_storage),
    'allianceRegionBonus', v_region_bonus
  );
END;
$function$


COMMIT;
