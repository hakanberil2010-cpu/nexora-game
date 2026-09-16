-- NEXORA - Daily Missions V1
-- Migration 043
--
-- Goals:
-- - Add repeatable daily missions without changing existing one-time missions.
-- - Reset by server-side Europe/Istanbul calendar day; never trust client date/time.
-- - Derive progress only from authoritative gameplay event tables.
-- - Keep daily missions locked until the Beginner Guide is completed.
-- - Make reward claims atomic, idempotent per player/day/mission and capacity-aware.
-- - Preserve the existing missions/achievements/metrics/guide response and append
--   only a top-level "daily" object to nexora_refresh_achievements().
--
-- Apply after 042_first_day_economy_v1.sql.
-- Backend/frontend claim integration is intentionally NOT part of this migration.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) DAILY MISSION DEFINITIONS + DATE-SCOPED PLAYER CLAIMS
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.game_daily_missions (
  id text PRIMARY KEY,
  title text NOT NULL,
  description text NOT NULL,
  metric_key text NOT NULL,
  target_value bigint NOT NULL CHECK (target_value > 0),
  reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(reward) = 'object'),
  sort_order integer NOT NULL DEFAULT 0,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS public.player_daily_mission_claims (
  player_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE CASCADE,
  mission_date date NOT NULL,
  mission_id text NOT NULL
    REFERENCES public.game_daily_missions(id) ON DELETE RESTRICT,
  claimed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(reward) = 'object'),
  PRIMARY KEY (player_id, mission_date, mission_id)
);

CREATE INDEX IF NOT EXISTS idx_player_daily_mission_claims_player_date
  ON public.player_daily_mission_claims(
    player_id,
    mission_date DESC,
    claimed_at DESC
  );

CREATE INDEX IF NOT EXISTS idx_unit_production_queue_player_created
  ON public.unit_production_queue(player_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_world_explore_player_completed_at
  ON public.world_exploration_missions(
    player_id,
    completed_at DESC,
    id DESC
  )
  WHERE status = 'completed';

INSERT INTO public.game_daily_missions
  (
    id,
    title,
    description,
    metric_key,
    target_value,
    reward,
    sort_order,
    active
  )
VALUES
  (
    'daily_train_5',
    '🪖 Günlük Eğitim',
    'Bugün toplam 5 birlik eğitimine başla.',
    'units_training_started',
    5,
    '{"metal":250,"energy":100,"water":0,"crystal":0}'::jsonb,
    10,
    true
  ),
  (
    'daily_explore_1',
    '🧭 Günlük Keşif',
    'Bugün 1 dünya keşfini tamamla.',
    'explorations_completed',
    1,
    '{"metal":0,"energy":0,"water":150,"crystal":50}'::jsonb,
    20,
    true
  ),
  (
    'daily_npc_victory_1',
    '🏕️ Kamp Avcısı',
    'Bugün 1 NPC kampını yen.',
    'npc_camps_won',
    1,
    '{"metal":300,"energy":100,"water":0,"crystal":25}'::jsonb,
    30,
    true
  )
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  metric_key = EXCLUDED.metric_key,
  target_value = EXCLUDED.target_value,
  reward = EXCLUDED.reward,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active;

-- -----------------------------------------------------------------------------
-- 2) SERVER-AUTHORITATIVE DAILY PROGRESS
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_daily_progress_value(
  p_player_id bigint,
  p_metric_key text,
  p_mission_date date
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_value bigint := 0;
  v_day_start timestamptz;
  v_day_end timestamptz;
BEGIN
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR p_metric_key IS NULL
     OR btrim(p_metric_key) = ''
     OR p_mission_date IS NULL THEN
    RETURN 0;
  END IF;

  v_day_start :=
    p_mission_date::timestamp AT TIME ZONE 'Europe/Istanbul';

  v_day_end :=
    (p_mission_date + 1)::timestamp AT TIME ZONE 'Europe/Istanbul';

  CASE p_metric_key
    WHEN 'units_training_started' THEN
      SELECT COALESCE(
               SUM(
                 GREATEST(
                   COALESCE(q.quantity, 0),
                   0
                 )
               ),
               0
             )::bigint
        INTO v_value
        FROM public.unit_production_queue q
       WHERE q.player_id = p_player_id
         AND q.created_at >= v_day_start
         AND q.created_at < v_day_end;

    WHEN 'explorations_completed' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.world_exploration_missions m
       WHERE m.player_id = p_player_id
         AND m.status = 'completed'
         AND m.completed_at IS NOT NULL
         AND m.completed_at >= v_day_start
         AND m.completed_at < v_day_end;

    WHEN 'npc_camps_won' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.npc_battle_reports r
       WHERE r.player_id = p_player_id
         AND r.result = 'Zafer'
         AND r.created_at >= v_day_start
         AND r.created_at < v_day_end;

    ELSE
      v_value := 0;
  END CASE;

  RETURN GREATEST(COALESCE(v_value, 0), 0);
END;
$function$;

-- -----------------------------------------------------------------------------
-- 3) READ-ONLY DAILY SNAPSHOT
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_daily_missions_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_server_time timestamptz := clock_timestamp();
  v_mission_date date;
  v_next_reset_at timestamptz;
  v_unlocked boolean := false;
  v_missions jsonb := '[]'::jsonb;
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

  v_mission_date :=
    (v_server_time AT TIME ZONE 'Europe/Istanbul')::date;

  v_next_reset_at :=
    (v_mission_date + 1)::timestamp AT TIME ZONE 'Europe/Istanbul';

  SELECT EXISTS (
    SELECT 1
      FROM public.player_beginner_guide_state s
     WHERE s.player_id = p_player_id
       AND s.completed_step >= 6
  )
    INTO v_unlocked;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', m.id,
               'title', m.title,
               'description', m.description,
               'metricKey', m.metric_key,
               'progress', LEAST(p.progress, m.target_value),
               'target', m.target_value,
               'completed', p.progress >= m.target_value,
               'claimed', c.mission_id IS NOT NULL,
               'claimedAt', c.claimed_at,
               'reward', m.reward,
               'creditedReward', COALESCE(c.reward, '{}'::jsonb),
               'claimable',
                 v_unlocked
                 AND p.progress >= m.target_value
                 AND c.mission_id IS NULL
             )
             ORDER BY m.sort_order, m.id
           ),
           '[]'::jsonb
         )
    INTO v_missions
    FROM public.game_daily_missions m
    CROSS JOIN LATERAL (
      SELECT public.nexora_daily_progress_value(
               p_player_id,
               m.metric_key,
               v_mission_date
             ) AS progress
    ) p
    LEFT JOIN public.player_daily_mission_claims c
      ON c.player_id = p_player_id
     AND c.mission_date = v_mission_date
     AND c.mission_id = m.id
   WHERE m.active IS TRUE;

  RETURN jsonb_build_object(
    'success', true,
    'dayKey', to_char(v_mission_date, 'YYYY-MM-DD'),
    'serverTime', v_server_time,
    'nextResetAt', v_next_reset_at,
    'unlocked', v_unlocked,
    'missions', v_missions
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 4) ATOMIC DAILY REWARD CLAIM
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_claim_daily_mission(
  p_player_id bigint,
  p_mission_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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
  v_reward_water bigint := 0;
  v_reward_crystal bigint := 0;

  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_water bigint := 0;
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
  v_mission_date :=
    (v_server_time AT TIME ZONE 'Europe/Istanbul')::date;

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

  v_storage :=
    5000 + GREATEST(v_depo_level, 0) * 2500;

  v_crystal_storage :=
    3000 + GREATEST(v_crystal_depo_level, 0) * 1500;

  v_reward := COALESCE(v_mission.reward, '{}'::jsonb);

  v_reward_metal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'metal', '')::bigint, 0));
  v_reward_energy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'energy', '')::bigint, 0));
  v_reward_water :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'water', '')::bigint, 0));
  v_reward_crystal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'crystal', '')::bigint, 0));

  v_credit_metal := LEAST(
    v_reward_metal,
    GREATEST(
      0,
      v_storage - GREATEST(COALESCE(v_city.metal, 0), 0)
    )
  );

  v_credit_energy := LEAST(
    v_reward_energy,
    GREATEST(
      0,
      v_storage - GREATEST(COALESCE(v_city.energy, 0), 0)
    )
  );

  v_credit_water := LEAST(
    v_reward_water,
    GREATEST(
      0,
      v_storage - GREATEST(COALESCE(v_city.water, 0), 0)
    )
  );

  v_credit_crystal := LEAST(
    v_reward_crystal,
    GREATEST(
      0,
      v_crystal_storage - GREATEST(COALESCE(v_city.crystal, 0), 0)
    )
  );

  UPDATE public.cities
     SET metal = GREATEST(COALESCE(metal, 0), 0) + v_credit_metal,
         energy = GREATEST(COALESCE(energy, 0), 0) + v_credit_energy,
         water = GREATEST(COALESCE(water, 0), 0) + v_credit_water,
         crystal = GREATEST(COALESCE(crystal, 0), 0) + v_credit_crystal,
         metal_capacity = v_storage,
         energy_capacity = v_storage,
         water_capacity = v_storage,
         crystal_capacity = v_crystal_storage,
         updated_at = clock_timestamp()
   WHERE id = v_city.id;

  v_credited := jsonb_build_object(
    'metal', v_credit_metal,
    'energy', v_credit_energy,
    'water', v_credit_water,
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

-- -----------------------------------------------------------------------------
-- 5) APPEND DAILY TO THE EXISTING GAME-OBJECTIVES SNAPSHOT
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_refresh_achievements(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_guide jsonb;
  v_daily jsonb;
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

  v_guide :=
    public.nexora_refresh_beginner_guide(p_player_id);

  v_daily :=
    public.nexora_daily_missions_snapshot(p_player_id);

  RETURN
    public.nexora_missions_snapshot(p_player_id)
    ||
    jsonb_build_object(
      'guide', v_guide,
      'daily', v_daily
    );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 6) SECURITY
-- -----------------------------------------------------------------------------

ALTER TABLE public.game_daily_missions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_daily_mission_claims ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.game_daily_missions
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.player_daily_mission_claims
  FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.game_daily_missions
  TO service_role;
GRANT ALL ON TABLE public.player_daily_mission_claims
  TO service_role;

REVOKE ALL ON FUNCTION
  public.nexora_daily_progress_value(bigint, text, date)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  public.nexora_daily_missions_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  public.nexora_claim_daily_mission(bigint, text)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  public.nexora_refresh_achievements(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.nexora_daily_progress_value(bigint, text, date)
  TO service_role;

GRANT EXECUTE ON FUNCTION
  public.nexora_daily_missions_snapshot(bigint)
  TO service_role;

GRANT EXECUTE ON FUNCTION
  public.nexora_claim_daily_mission(bigint, text)
  TO service_role;

GRANT EXECUTE ON FUNCTION
  public.nexora_refresh_achievements(bigint)
  TO service_role;

COMMIT;
