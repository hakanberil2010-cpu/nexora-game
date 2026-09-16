-- NEXORA - Weekly Missions + 7-Day Login Rewards V1
-- Migration 054
--
-- Goals:
-- - Add repeatable weekly missions with Monday 00:00 Europe/Istanbul reset.
-- - Add a 7-reward login cycle: one automatic-claimable reward per Istanbul calendar day.
-- - Missed login days do not reset the 7-reward cycle.
-- - Derive weekly progress only from authoritative server-side gameplay records.
-- - Keep weekly missions locked until the Beginner Guide is completed.
-- - Make all reward claims atomic, idempotent and storage-capacity aware.
-- - Preserve existing objectives payload and append "weekly" + "loginRewards".
--
-- Apply after 053_long_term_progression_v1.sql.
-- Backend/frontend integration is intentionally NOT part of this migration.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) WEEKLY MISSION DEFINITIONS + WEEK-SCOPED CLAIMS
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.game_weekly_missions (
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

CREATE TABLE IF NOT EXISTS public.player_weekly_mission_claims (
  player_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE CASCADE,
  week_start date NOT NULL,
  mission_id text NOT NULL
    REFERENCES public.game_weekly_missions(id) ON DELETE RESTRICT,
  claimed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(reward) = 'object'),
  PRIMARY KEY (player_id, week_start, mission_id)
);

CREATE INDEX IF NOT EXISTS idx_player_weekly_mission_claims_player_week
  ON public.player_weekly_mission_claims(
    player_id,
    week_start DESC,
    claimed_at DESC
  );

CREATE INDEX IF NOT EXISTS idx_battle_reports_winner_created
  ON public.battle_reports(winner_player_id, created_at DESC);

INSERT INTO public.game_weekly_missions
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
    'weekly_train_25',
    '🪖 Haftalık Seferberlik',
    'Bu hafta toplam 25 birlik eğitimine başla.',
    'units_training_started',
    25,
    '{"metal":500,"energy":250,"water":0,"crystal":0}'::jsonb,
    10,
    true
  ),
  (
    'weekly_explore_2',
    '🧭 Haftalık Kaşif',
    'Bu hafta 2 dünya keşfini tamamla.',
    'explorations_completed',
    2,
    '{"metal":0,"energy":0,"water":400,"crystal":100}'::jsonb,
    20,
    true
  ),
  (
    'weekly_battle_3',
    '⚔️ Haftalık Savaşçı',
    'Bu hafta NPC veya oyunculara karşı toplam 3 savaş zaferi kazan.',
    'battle_wins',
    3,
    '{"metal":600,"energy":250,"water":0,"crystal":100}'::jsonb,
    30,
    true
  ),
  (
    'weekly_active_3',
    '📅 Düzenli Komutan',
    'Bu hafta 3 farklı günde en az bir günlük görev ödülü al.',
    'daily_active_days',
    3,
    '{"metal":0,"energy":0,"water":500,"crystal":150}'::jsonb,
    40,
    true
  ),
  (
    'weekly_complete_all',
    '🎁 Haftalık Komutan Sandığı',
    'Dört ana haftalık hedefin tamamını bitir.',
    'weekly_core_completed',
    4,
    '{"metal":1000,"energy":500,"water":1000,"crystal":250}'::jsonb,
    50,
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
-- 2) 7-DAY LOGIN REWARD DEFINITIONS + DAILY CLAIM HISTORY
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.game_login_rewards (
  day_number smallint PRIMARY KEY
    CHECK (day_number BETWEEN 1 AND 7),
  title text NOT NULL,
  reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(reward) = 'object'),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS public.player_login_reward_claims (
  player_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE CASCADE,
  claim_date date NOT NULL,
  cycle_day smallint NOT NULL
    REFERENCES public.game_login_rewards(day_number) ON DELETE RESTRICT,
  claimed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(reward) = 'object'),
  PRIMARY KEY (player_id, claim_date)
);

CREATE INDEX IF NOT EXISTS idx_player_login_reward_claims_player_claimed
  ON public.player_login_reward_claims(
    player_id,
    claimed_at DESC
  );

INSERT INTO public.game_login_rewards(day_number, title, reward, active)
VALUES
  (
    1,
    '1. Gün',
    '{"metal":300,"energy":0,"water":0,"crystal":0}'::jsonb,
    true
  ),
  (
    2,
    '2. Gün',
    '{"metal":0,"energy":200,"water":200,"crystal":0}'::jsonb,
    true
  ),
  (
    3,
    '3. Gün',
    '{"metal":400,"energy":0,"water":0,"crystal":100}'::jsonb,
    true
  ),
  (
    4,
    '4. Gün',
    '{"metal":0,"energy":300,"water":300,"crystal":0}'::jsonb,
    true
  ),
  (
    5,
    '5. Gün',
    '{"metal":500,"energy":200,"water":0,"crystal":0}'::jsonb,
    true
  ),
  (
    6,
    '6. Gün',
    '{"metal":0,"energy":0,"water":500,"crystal":150}'::jsonb,
    true
  ),
  (
    7,
    '7. Gün Büyük Ödül',
    '{"metal":750,"energy":400,"water":750,"crystal":250}'::jsonb,
    true
  )
ON CONFLICT (day_number) DO UPDATE SET
  title = EXCLUDED.title,
  reward = EXCLUDED.reward,
  active = EXCLUDED.active;

-- -----------------------------------------------------------------------------
-- 3) SERVER-AUTHORITATIVE WEEKLY PROGRESS
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_weekly_progress_value(
  p_player_id bigint,
  p_metric_key text,
  p_week_start date
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_value bigint := 0;
  v_week_start timestamptz;
  v_week_end timestamptz;
BEGIN
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR p_metric_key IS NULL
     OR btrim(p_metric_key) = ''
     OR p_week_start IS NULL THEN
    RETURN 0;
  END IF;

  v_week_start :=
    p_week_start::timestamp AT TIME ZONE 'Europe/Istanbul';

  v_week_end :=
    (p_week_start + 7)::timestamp AT TIME ZONE 'Europe/Istanbul';

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
         AND q.created_at >= v_week_start
         AND q.created_at < v_week_end;

    WHEN 'explorations_completed' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.world_exploration_missions m
       WHERE m.player_id = p_player_id
         AND m.status = 'completed'
         AND m.completed_at IS NOT NULL
         AND m.completed_at >= v_week_start
         AND m.completed_at < v_week_end;

    WHEN 'battle_wins' THEN
      SELECT
        (
          SELECT COUNT(*)::bigint
            FROM public.battle_reports b
           WHERE b.winner_player_id = p_player_id
             AND b.created_at >= v_week_start
             AND b.created_at < v_week_end
        )
        +
        (
          SELECT COUNT(*)::bigint
            FROM public.npc_battle_reports r
           WHERE r.player_id = p_player_id
             AND r.result = 'Zafer'
             AND r.created_at >= v_week_start
             AND r.created_at < v_week_end
        )
        INTO v_value;

    WHEN 'daily_active_days' THEN
      SELECT COUNT(DISTINCT c.mission_date)::bigint
        INTO v_value
        FROM public.player_daily_mission_claims c
       WHERE c.player_id = p_player_id
         AND c.mission_date >= p_week_start
         AND c.mission_date < p_week_start + 7;

    WHEN 'weekly_core_completed' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.game_weekly_missions m
       WHERE m.active IS TRUE
         AND m.metric_key <> 'weekly_core_completed'
         AND public.nexora_weekly_progress_value(
               p_player_id,
               m.metric_key,
               p_week_start
             ) >= m.target_value;

    ELSE
      v_value := 0;
  END CASE;

  RETURN GREATEST(COALESCE(v_value, 0), 0);
END;
$function$;

-- -----------------------------------------------------------------------------
-- 4) READ-ONLY WEEKLY SNAPSHOT
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_weekly_missions_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_server_time timestamptz := clock_timestamp();
  v_week_start date;
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

  v_week_start :=
    date_trunc(
      'week',
      v_server_time AT TIME ZONE 'Europe/Istanbul'
    )::date;

  v_next_reset_at :=
    (v_week_start + 7)::timestamp AT TIME ZONE 'Europe/Istanbul';

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
    FROM public.game_weekly_missions m
    CROSS JOIN LATERAL (
      SELECT public.nexora_weekly_progress_value(
               p_player_id,
               m.metric_key,
               v_week_start
             ) AS progress
    ) p
    LEFT JOIN public.player_weekly_mission_claims c
      ON c.player_id = p_player_id
     AND c.week_start = v_week_start
     AND c.mission_id = m.id
   WHERE m.active IS TRUE;

  RETURN jsonb_build_object(
    'success', true,
    'weekKey', to_char(v_week_start, 'YYYY-MM-DD'),
    'serverTime', v_server_time,
    'nextResetAt', v_next_reset_at,
    'unlocked', v_unlocked,
    'missions', v_missions
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 5) ATOMIC WEEKLY MISSION REWARD CLAIM
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_claim_weekly_mission(
  p_player_id bigint,
  p_mission_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
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
    date_trunc(
      'week',
      v_server_time AT TIME ZONE 'Europe/Istanbul'
    )::date;

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
    GREATEST(0, v_storage - GREATEST(COALESCE(v_city.metal, 0), 0))
  );
  v_credit_energy := LEAST(
    v_reward_energy,
    GREATEST(0, v_storage - GREATEST(COALESCE(v_city.energy, 0), 0))
  );
  v_credit_water := LEAST(
    v_reward_water,
    GREATEST(0, v_storage - GREATEST(COALESCE(v_city.water, 0), 0))
  );
  v_credit_crystal := LEAST(
    v_reward_crystal,
    GREATEST(0, v_crystal_storage - GREATEST(COALESCE(v_city.crystal, 0), 0))
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

-- -----------------------------------------------------------------------------
-- 6) READ-ONLY 7-DAY LOGIN REWARD SNAPSHOT
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_login_rewards_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_server_time timestamptz := clock_timestamp();
  v_claim_date date;
  v_next_reset_at timestamptz;
  v_total_claims bigint := 0;
  v_claimed_today boolean := false;
  v_claimed_day smallint;
  v_claimed_at timestamptz;
  v_claimed_reward jsonb := '{}'::jsonb;
  v_next_day smallint := 1;
  v_rewards jsonb := '[]'::jsonb;
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

  v_claim_date :=
    (v_server_time AT TIME ZONE 'Europe/Istanbul')::date;

  v_next_reset_at :=
    (v_claim_date + 1)::timestamp AT TIME ZONE 'Europe/Istanbul';

  SELECT COUNT(*)::bigint
    INTO v_total_claims
    FROM public.player_login_reward_claims c
   WHERE c.player_id = p_player_id;

  SELECT c.cycle_day, c.claimed_at, c.reward
    INTO v_claimed_day, v_claimed_at, v_claimed_reward
    FROM public.player_login_reward_claims c
   WHERE c.player_id = p_player_id
     AND c.claim_date = v_claim_date
   LIMIT 1;

  v_claimed_today := FOUND;

  v_next_day :=
    ((GREATEST(v_total_claims, 0) % 7) + 1)::smallint;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'day', r.day_number,
               'title', r.title,
               'reward', r.reward
             )
             ORDER BY r.day_number
           ),
           '[]'::jsonb
         )
    INTO v_rewards
    FROM public.game_login_rewards r
   WHERE r.active IS TRUE;

  RETURN jsonb_build_object(
    'success', true,
    'dayKey', to_char(v_claim_date, 'YYYY-MM-DD'),
    'serverTime', v_server_time,
    'nextResetAt', v_next_reset_at,
    'totalClaims', v_total_claims,
    'claimedToday', v_claimed_today,
    'claimedDay', v_claimed_day,
    'claimedAt', v_claimed_at,
    'claimedReward', COALESCE(v_claimed_reward, '{}'::jsonb),
    'nextDay', v_next_day,
    'rewards', v_rewards
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 7) ATOMIC DAILY LOGIN REWARD CLAIM
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_claim_login_reward(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
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
  v_reward_water bigint := 0;
  v_reward_crystal bigint := 0;

  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_water bigint := 0;
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

  v_claim_date :=
    (v_server_time AT TIME ZONE 'Europe/Istanbul')::date;

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

  v_cycle_day :=
    ((GREATEST(v_prior_claims, 0) % 7) + 1)::smallint;

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

  v_storage :=
    5000 + GREATEST(v_depo_level, 0) * 2500;

  v_crystal_storage :=
    3000 + GREATEST(v_crystal_depo_level, 0) * 1500;

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
    GREATEST(0, v_storage - GREATEST(COALESCE(v_city.metal, 0), 0))
  );
  v_credit_energy := LEAST(
    v_reward_energy,
    GREATEST(0, v_storage - GREATEST(COALESCE(v_city.energy, 0), 0))
  );
  v_credit_water := LEAST(
    v_reward_water,
    GREATEST(0, v_storage - GREATEST(COALESCE(v_city.water, 0), 0))
  );
  v_credit_crystal := LEAST(
    v_reward_crystal,
    GREATEST(0, v_crystal_storage - GREATEST(COALESCE(v_city.crystal, 0), 0))
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

-- -----------------------------------------------------------------------------
-- 8) APPEND WEEKLY + LOGIN REWARDS TO EXISTING GAME-OBJECTIVES SNAPSHOT
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
  v_progression jsonb;
  v_weekly jsonb;
  v_login_rewards jsonb;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
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

  v_guide := public.nexora_refresh_beginner_guide(p_player_id);
  v_daily := public.nexora_daily_missions_snapshot(p_player_id);
  v_progression := public.nexora_progression_snapshot(p_player_id);
  v_weekly := public.nexora_weekly_missions_snapshot(p_player_id);
  v_login_rewards := public.nexora_login_rewards_snapshot(p_player_id);

  RETURN
    public.nexora_missions_snapshot(p_player_id)
    ||
    jsonb_build_object(
      'guide', v_guide,
      'daily', v_daily,
      'progression', v_progression,
      'weekly', v_weekly,
      'loginRewards', v_login_rewards
    );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 9) SECURITY
-- -----------------------------------------------------------------------------

ALTER TABLE public.game_weekly_missions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_weekly_mission_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_login_rewards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_login_reward_claims ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.game_weekly_missions
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.player_weekly_mission_claims
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.game_login_rewards
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.player_login_reward_claims
  FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.game_weekly_missions
  TO service_role;
GRANT ALL ON TABLE public.player_weekly_mission_claims
  TO service_role;
GRANT ALL ON TABLE public.game_login_rewards
  TO service_role;
GRANT ALL ON TABLE public.player_login_reward_claims
  TO service_role;

REVOKE ALL ON FUNCTION
  public.nexora_weekly_progress_value(bigint, text, date)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.nexora_weekly_missions_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.nexora_claim_weekly_mission(bigint, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.nexora_login_rewards_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.nexora_claim_login_reward(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.nexora_refresh_achievements(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.nexora_weekly_progress_value(bigint, text, date)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.nexora_weekly_missions_snapshot(bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.nexora_claim_weekly_mission(bigint, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.nexora_login_rewards_snapshot(bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.nexora_claim_login_reward(bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.nexora_refresh_achievements(bigint)
  TO service_role;

COMMIT;
