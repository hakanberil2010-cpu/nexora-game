-- NEXORA - Economy & Balance Audit / Mission Reward Capacity Guard
-- Migration 069
--
-- Extends the full-reward capacity guard to:
-- - daily mission claims
-- - weekly mission claims
-- - progression mission claims
--
-- If the configured reward does not fully fit:
-- - no resources are credited
-- - no claim row is inserted
-- - the player can free storage and retry
--
-- Existing reward values, mission progress and claim history are preserved.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_claim_daily_mission(
  p_player_id bigint,
  p_mission_id text
)
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

  v_storage := 5000 + GREATEST(v_depo_level, 0) * 2500;
  v_crystal_storage := 3000 + GREATEST(v_crystal_depo_level, 0) * 1500;
  v_reward := COALESCE(v_mission.reward, '{}'::jsonb);

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
      'rewardConfigured', v_reward,
      'snapshot', public.nexora_daily_missions_snapshot(p_player_id)
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
$function$;

CREATE OR REPLACE FUNCTION public.nexora_claim_weekly_mission(
  p_player_id bigint,
  p_mission_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
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

  v_storage := 5000 + GREATEST(v_depo_level, 0) * 2500;
  v_crystal_storage := 3000 + GREATEST(v_crystal_depo_level, 0) * 1500;
  v_reward := COALESCE(v_mission.reward, '{}'::jsonb);

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
      'rewardConfigured', v_reward,
      'snapshot', public.nexora_weekly_missions_snapshot(p_player_id)
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
$function$;

CREATE OR REPLACE FUNCTION public.nexora_claim_progression_mission(
  p_player_id bigint,
  p_mission_id text
)
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

  v_storage := 5000 + GREATEST(v_depo_level, 0) * 2500;
  v_crystal_storage := 3000 + GREATEST(v_crystal_depo_level, 0) * 1500;
  v_reward := COALESCE(v_mission.reward, '{}'::jsonb);

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
      'rewardConfigured', v_reward,
      'snapshot', public.nexora_progression_snapshot(p_player_id)
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
$function$;

COMMIT;
