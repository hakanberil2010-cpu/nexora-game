-- NEXORA - Economy & Balance Audit / Boss + Alliance Reward Capacity Guard
-- Migration 070
--
-- Extends the full-reward capacity guard to:
-- - alliance weekly mission chest
-- - boss first-kill reward
-- - weekly boss reward
--
-- If the configured reward does not fully fit:
-- - no resources are credited
-- - no claim row is inserted
-- - the player can free storage and retry
--
-- Existing reward values, eligibility, idempotency and claim history are preserved.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_claim_alliance_mission_chest(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
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

  IF
    COALESCE(v_city.metal, 0) + 800
      > COALESCE(v_city.metal_capacity, 0)
    OR COALESCE(v_city.energy, 0) + 400
      > COALESCE(v_city.energy_capacity, 0)
    OR COALESCE(v_city.alloy, 0) + 800
      > COALESCE(v_city.alloy_capacity, 0)
    OR COALESCE(v_city.crystal, 0) + 200
      > COALESCE(v_city.crystal_capacity, 0)
  THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'REWARD_STORAGE_FULL',
      'message', 'Ödülün tamamını almak için depolarda yeterli boş alan yok.',
      'reward', v_reward,
      'snapshot', public.nexora_alliance_missions_snapshot(p_player_id)
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
$function$;

CREATE OR REPLACE FUNCTION public.nexora_claim_boss_first_kill(
  p_player_id bigint,
  p_camp_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
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
      'snapshot', public.nexora_boss_rewards_snapshot(p_player_id)
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
$function$;

CREATE OR REPLACE FUNCTION public.nexora_claim_weekly_boss_reward(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
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
      'snapshot', public.nexora_boss_rewards_snapshot(p_player_id)
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
$function$;

COMMIT;
