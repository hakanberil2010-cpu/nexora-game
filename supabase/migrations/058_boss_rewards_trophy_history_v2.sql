-- NEXORA - Boss Rewards + Trophy History V2
-- Migration 058
--
-- Goals:
-- - Keep the existing PvE combat / mission / report flow unchanged.
-- - Track only victorious boss encounters as durable boss-kill history.
-- - Award deterministic non-spendable rare trophy drops without economy impact.
-- - Add one capacity-aware first-kill resource bonus per boss.
-- - Add one capacity-aware weekly boss chest per player/week after any boss win.
-- - Make every reward claim atomic and idempotent.
-- - Preserve all existing NPC/monster/elite/boss reports and world targets.
--
-- Apply after 057_alliance_missions_v1.sql.
-- Backend/frontend integration is intentionally NOT part of this migration.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) BOSS REWARD PROFILES
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.game_boss_reward_profiles (
  npc_camp_id bigint PRIMARY KEY
    REFERENCES public.npc_camps(id) ON DELETE CASCADE,
  first_kill_reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(first_kill_reward) = 'object'),
  weekly_reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(weekly_reward) = 'object'),
  rare_drop_key text NOT NULL,
  rare_drop_name text NOT NULL,
  rare_drop_icon text NOT NULL,
  rare_drop_chance_bps integer NOT NULL DEFAULT 0
    CHECK (rare_drop_chance_bps BETWEEN 0 AND 10000),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO public.game_boss_reward_profiles(
  npc_camp_id,
  first_kill_reward,
  weekly_reward,
  rare_drop_key,
  rare_drop_name,
  rare_drop_icon,
  rare_drop_chance_bps,
  active,
  updated_at
)
SELECT
  c.id,
  CASE s.name
    WHEN 'Kadim Titan' THEN
      '{"metal":1500,"energy":600,"water":700,"crystal":150}'::jsonb
    WHEN 'Boşluk Ejderi' THEN
      '{"metal":2500,"energy":1000,"water":1200,"crystal":250}'::jsonb
    ELSE '{}'::jsonb
  END,
  '{"metal":1200,"energy":600,"water":1200,"crystal":250}'::jsonb,
  CASE s.name
    WHEN 'Kadim Titan' THEN 'titan_core'
    WHEN 'Boşluk Ejderi' THEN 'void_scale'
    ELSE 'boss_trophy'
  END,
  CASE s.name
    WHEN 'Kadim Titan' THEN 'Titan Çekirdeği'
    WHEN 'Boşluk Ejderi' THEN 'Boşluk Pulu'
    ELSE 'Boss Hatırası'
  END,
  CASE s.name
    WHEN 'Kadim Titan' THEN '🔶'
    WHEN 'Boşluk Ejderi' THEN '💠'
    ELSE '🏆'
  END,
  CASE s.name
    WHEN 'Kadim Titan' THEN 2000
    WHEN 'Boşluk Ejderi' THEN 1500
    ELSE 0
  END,
  true,
  clock_timestamp()
FROM public.npc_camps c
JOIN public.world_sites s
  ON s.id = c.world_site_id
WHERE c.encounter_class = 'boss'
  AND s.name IN ('Kadim Titan','Boşluk Ejderi')
ON CONFLICT (npc_camp_id) DO UPDATE SET
  first_kill_reward = EXCLUDED.first_kill_reward,
  weekly_reward = EXCLUDED.weekly_reward,
  rare_drop_key = EXCLUDED.rare_drop_key,
  rare_drop_name = EXCLUDED.rare_drop_name,
  rare_drop_icon = EXCLUDED.rare_drop_icon,
  rare_drop_chance_bps = EXCLUDED.rare_drop_chance_bps,
  active = EXCLUDED.active,
  updated_at = clock_timestamp();

-- -----------------------------------------------------------------------------
-- 2) DURABLE BOSS KILL / TROPHY HISTORY
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.player_boss_kills (
  npc_battle_report_id bigint PRIMARY KEY
    REFERENCES public.npc_battle_reports(id) ON DELETE CASCADE,
  player_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE CASCADE,
  npc_camp_id bigint NOT NULL
    REFERENCES public.npc_camps(id) ON DELETE CASCADE,
  killed_at timestamptz NOT NULL,
  rare_drop_roll integer NOT NULL
    CHECK (rare_drop_roll BETWEEN 0 AND 9999),
  rare_drop_key text,
  rare_drop_name text,
  rare_drop_icon text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS idx_player_boss_kills_player_time
  ON public.player_boss_kills(
    player_id,
    killed_at DESC,
    npc_battle_report_id DESC
  );

CREATE INDEX IF NOT EXISTS idx_player_boss_kills_player_camp
  ON public.player_boss_kills(
    player_id,
    npc_camp_id,
    killed_at DESC
  );

-- -----------------------------------------------------------------------------
-- 3) IDEMPOTENT RESOURCE REWARD CLAIM HISTORY
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.player_boss_reward_claims (
  player_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE CASCADE,
  reward_kind text NOT NULL
    CHECK (reward_kind IN ('first_kill','weekly')),
  reward_key text NOT NULL,
  npc_camp_id bigint
    REFERENCES public.npc_camps(id) ON DELETE CASCADE,
  week_start date,
  configured_reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(configured_reward) = 'object'),
  reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(reward) = 'object'),
  claimed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (player_id, reward_kind, reward_key),
  CHECK (
    (
      reward_kind = 'first_kill'
      AND npc_camp_id IS NOT NULL
      AND week_start IS NULL
    )
    OR
    (
      reward_kind = 'weekly'
      AND npc_camp_id IS NULL
      AND week_start IS NOT NULL
    )
  )
);

CREATE INDEX IF NOT EXISTS idx_player_boss_reward_claims_player_time
  ON public.player_boss_reward_claims(
    player_id,
    claimed_at DESC
  );

ALTER TABLE public.game_boss_reward_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_boss_kills ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_boss_reward_claims ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- 4) AUTOMATIC BOSS-KILL TRACKING
--
-- No extra resources are credited here. The trigger only records a boss victory
-- and its deterministic rare-trophy roll. The roll cannot be rerolled by retrying
-- a request because npc_battle_report_id is unique and part of the deterministic
-- seed.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_track_boss_kill()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_profile public.game_boss_reward_profiles%ROWTYPE;
  v_roll integer;
BEGIN
  IF NEW.result IS DISTINCT FROM 'Zafer' THEN
    RETURN NEW;
  END IF;

  SELECT p.*
    INTO v_profile
    FROM public.game_boss_reward_profiles p
    JOIN public.npc_camps c
      ON c.id = p.npc_camp_id
   WHERE p.npc_camp_id = NEW.npc_camp_id
     AND p.active IS TRUE
     AND c.encounter_class = 'boss'
   LIMIT 1;

  IF v_profile.npc_camp_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_roll :=
    (
      (
        'x'
        || substr(
             md5(
               NEW.id::text
               || ':'
               || NEW.player_id::text
               || ':'
               || NEW.npc_camp_id::text
               || ':nexora-boss-v2'
             ),
             1,
             8
           )
      )::bit(32)::bigint
      % 10000
    )::integer;

  INSERT INTO public.player_boss_kills(
    npc_battle_report_id,
    player_id,
    npc_camp_id,
    killed_at,
    rare_drop_roll,
    rare_drop_key,
    rare_drop_name,
    rare_drop_icon,
    created_at
  )
  VALUES(
    NEW.id,
    NEW.player_id,
    NEW.npc_camp_id,
    NEW.created_at,
    v_roll,
    CASE
      WHEN v_roll < v_profile.rare_drop_chance_bps
        THEN v_profile.rare_drop_key
      ELSE NULL
    END,
    CASE
      WHEN v_roll < v_profile.rare_drop_chance_bps
        THEN v_profile.rare_drop_name
      ELSE NULL
    END,
    CASE
      WHEN v_roll < v_profile.rare_drop_chance_bps
        THEN v_profile.rare_drop_icon
      ELSE NULL
    END,
    clock_timestamp()
  )
  ON CONFLICT (npc_battle_report_id) DO NOTHING;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_nexora_track_boss_kill
  ON public.npc_battle_reports;

CREATE TRIGGER trg_nexora_track_boss_kill
AFTER INSERT ON public.npc_battle_reports
FOR EACH ROW
EXECUTE FUNCTION public.nexora_track_boss_kill();

-- Backfill any boss victories that may already exist by migration time.
WITH eligible AS (
  SELECT
    r.id AS npc_battle_report_id,
    r.player_id,
    r.npc_camp_id,
    r.created_at AS killed_at,
    p.rare_drop_key,
    p.rare_drop_name,
    p.rare_drop_icon,
    p.rare_drop_chance_bps,
    (
      (
        'x'
        || substr(
             md5(
               r.id::text
               || ':'
               || r.player_id::text
               || ':'
               || r.npc_camp_id::text
               || ':nexora-boss-v2'
             ),
             1,
             8
           )
      )::bit(32)::bigint
      % 10000
    )::integer AS rare_drop_roll
  FROM public.npc_battle_reports r
  JOIN public.npc_camps c
    ON c.id = r.npc_camp_id
  JOIN public.game_boss_reward_profiles p
    ON p.npc_camp_id = c.id
   AND p.active IS TRUE
  WHERE r.result = 'Zafer'
    AND c.encounter_class = 'boss'
)
INSERT INTO public.player_boss_kills(
  npc_battle_report_id,
  player_id,
  npc_camp_id,
  killed_at,
  rare_drop_roll,
  rare_drop_key,
  rare_drop_name,
  rare_drop_icon,
  created_at
)
SELECT
  e.npc_battle_report_id,
  e.player_id,
  e.npc_camp_id,
  e.killed_at,
  e.rare_drop_roll,
  CASE
    WHEN e.rare_drop_roll < e.rare_drop_chance_bps
      THEN e.rare_drop_key
    ELSE NULL
  END,
  CASE
    WHEN e.rare_drop_roll < e.rare_drop_chance_bps
      THEN e.rare_drop_name
    ELSE NULL
  END,
  CASE
    WHEN e.rare_drop_roll < e.rare_drop_chance_bps
      THEN e.rare_drop_icon
    ELSE NULL
  END,
  clock_timestamp()
FROM eligible e
ON CONFLICT (npc_battle_report_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 5) READ-ONLY BOSS REWARDS / HISTORY SNAPSHOT
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_boss_rewards_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_server_time timestamptz := clock_timestamp();
  v_week_start date;
  v_next_reset_at timestamptz;
  v_bosses jsonb := '[]'::jsonb;
  v_recent_kills jsonb := '[]'::jsonb;
  v_total_kills bigint := 0;
  v_unique_bosses bigint := 0;
  v_rare_drops bigint := 0;
  v_unclaimed_first_kills bigint := 0;
  v_weekly_kills bigint := 0;
  v_weekly_claimed boolean := false;
  v_weekly_claimed_at timestamptz;
  v_weekly_reward jsonb := '{}'::jsonb;
  v_weekly_credited jsonb := '{}'::jsonb;
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

  SELECT
    COUNT(*)::bigint,
    COUNT(DISTINCT k.npc_camp_id)::bigint,
    COUNT(*) FILTER (WHERE k.rare_drop_key IS NOT NULL)::bigint
    INTO
      v_total_kills,
      v_unique_bosses,
      v_rare_drops
    FROM public.player_boss_kills k
   WHERE k.player_id = p_player_id;

  SELECT COUNT(*)::bigint
    INTO v_weekly_kills
    FROM public.player_boss_kills k
   WHERE k.player_id = p_player_id
     AND k.killed_at >=
           v_week_start::timestamp AT TIME ZONE 'Europe/Istanbul'
     AND k.killed_at <
           (v_week_start + 7)::timestamp AT TIME ZONE 'Europe/Istanbul';

  -- Weekly reward is intentionally the same for every active boss profile in V2.
  -- Selecting one active profile keeps the value data-driven for future tuning.
  SELECT COALESCE(p.weekly_reward, '{}'::jsonb)
    INTO v_weekly_reward
    FROM public.game_boss_reward_profiles p
    JOIN public.npc_camps c
      ON c.id = p.npc_camp_id
   WHERE p.active IS TRUE
     AND c.encounter_class = 'boss'
   ORDER BY c.tier DESC, c.id DESC
   LIMIT 1;

  v_weekly_reward := COALESCE(v_weekly_reward, '{}'::jsonb);

  SELECT
    true,
    c.claimed_at,
    c.reward
    INTO
      v_weekly_claimed,
      v_weekly_claimed_at,
      v_weekly_credited
    FROM public.player_boss_reward_claims c
   WHERE c.player_id = p_player_id
     AND c.reward_kind = 'weekly'
     AND c.reward_key = to_char(v_week_start, 'YYYY-MM-DD')
   LIMIT 1;

  v_weekly_claimed := COALESCE(v_weekly_claimed, false);
  v_weekly_credited := COALESCE(v_weekly_credited, '{}'::jsonb);

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'campId', c.id,
               'name', s.name,
               'level', c.tier,
               'icon', c.icon,
               'firstKillReward', p.first_kill_reward,
               'weeklyReward', p.weekly_reward,
               'rareDrop', jsonb_build_object(
                 'key', p.rare_drop_key,
                 'name', p.rare_drop_name,
                 'icon', p.rare_drop_icon,
                 'chanceBps', p.rare_drop_chance_bps
               ),
               'kills', stats.kills,
               'firstKilledAt', stats.first_killed_at,
               'lastKilledAt', stats.last_killed_at,
               'rareDropCount', stats.rare_drop_count,
               'firstKillClaimed', claim.reward_key IS NOT NULL,
               'firstKillClaimedAt', claim.claimed_at,
               'firstKillCreditedReward',
                 COALESCE(claim.reward, '{}'::jsonb),
               'firstKillClaimable',
                 stats.kills > 0
                 AND claim.reward_key IS NULL
             )
             ORDER BY c.tier, c.id
           ),
           '[]'::jsonb
         )
    INTO v_bosses
    FROM public.game_boss_reward_profiles p
    JOIN public.npc_camps c
      ON c.id = p.npc_camp_id
    JOIN public.world_sites s
      ON s.id = c.world_site_id
    LEFT JOIN LATERAL (
      SELECT
        COUNT(k.npc_battle_report_id)::bigint AS kills,
        MIN(k.killed_at) AS first_killed_at,
        MAX(k.killed_at) AS last_killed_at,
        COUNT(k.npc_battle_report_id)
          FILTER (WHERE k.rare_drop_key IS NOT NULL)::bigint
          AS rare_drop_count
      FROM public.player_boss_kills k
      WHERE k.player_id = p_player_id
        AND k.npc_camp_id = c.id
    ) stats
      ON true
    LEFT JOIN public.player_boss_reward_claims claim
      ON claim.player_id = p_player_id
     AND claim.reward_kind = 'first_kill'
     AND claim.reward_key = c.id::text
   WHERE p.active IS TRUE
     AND c.active IS TRUE
     AND c.encounter_class = 'boss'
     AND s.active IS TRUE;

  SELECT COUNT(*)::bigint
    INTO v_unclaimed_first_kills
    FROM public.game_boss_reward_profiles p
    JOIN public.npc_camps c
      ON c.id = p.npc_camp_id
   WHERE p.active IS TRUE
     AND c.encounter_class = 'boss'
     AND EXISTS (
       SELECT 1
         FROM public.player_boss_kills k
        WHERE k.player_id = p_player_id
          AND k.npc_camp_id = c.id
     )
     AND NOT EXISTS (
       SELECT 1
         FROM public.player_boss_reward_claims claim
        WHERE claim.player_id = p_player_id
          AND claim.reward_kind = 'first_kill'
          AND claim.reward_key = c.id::text
     );

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'reportId', x.npc_battle_report_id,
               'campId', x.npc_camp_id,
               'name', x.boss_name,
               'level', x.boss_tier,
               'icon', x.boss_icon,
               'killedAt', x.killed_at,
               'rareDrop',
                 CASE
                   WHEN x.rare_drop_key IS NULL THEN NULL
                   ELSE jsonb_build_object(
                     'key', x.rare_drop_key,
                     'name', x.rare_drop_name,
                     'icon', x.rare_drop_icon
                   )
                 END
             )
             ORDER BY x.killed_at DESC, x.npc_battle_report_id DESC
           ),
           '[]'::jsonb
         )
    INTO v_recent_kills
    FROM (
      SELECT
        k.npc_battle_report_id,
        k.npc_camp_id,
        s.name AS boss_name,
        c.tier AS boss_tier,
        c.icon AS boss_icon,
        k.killed_at,
        k.rare_drop_key,
        k.rare_drop_name,
        k.rare_drop_icon
      FROM public.player_boss_kills k
      JOIN public.npc_camps c
        ON c.id = k.npc_camp_id
      JOIN public.world_sites s
        ON s.id = c.world_site_id
      WHERE k.player_id = p_player_id
      ORDER BY k.killed_at DESC, k.npc_battle_report_id DESC
      LIMIT 10
    ) x;

  RETURN jsonb_build_object(
    'success', true,
    'weekKey', to_char(v_week_start, 'YYYY-MM-DD'),
    'serverTime', v_server_time,
    'nextResetAt', v_next_reset_at,
    'summary', jsonb_build_object(
      'totalBossKills', v_total_kills,
      'uniqueBossesDefeated', v_unique_bosses,
      'rareDropsTotal', v_rare_drops,
      'unclaimedFirstKills', v_unclaimed_first_kills
    ),
    'weekly', jsonb_build_object(
      'bossKills', v_weekly_kills,
      'unlocked', v_weekly_kills > 0,
      'claimed', v_weekly_claimed,
      'claimedAt', v_weekly_claimed_at,
      'claimable', v_weekly_kills > 0 AND NOT v_weekly_claimed,
      'reward', v_weekly_reward,
      'creditedReward', v_weekly_credited
    ),
    'bosses', v_bosses,
    'recentKills', v_recent_kills
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 6) FIRST-KILL BONUS CLAIM
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_claim_boss_first_kill(
  p_player_id bigint,
  p_camp_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_profile public.game_boss_reward_profiles%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_existing jsonb;
  v_configured jsonb;
  v_credited jsonb;
  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_water bigint := 0;
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
        WHERE key NOT IN ('metal','energy','water','crystal')
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

  v_credit_metal :=
    LEAST(
      COALESCE((v_configured->>'metal')::bigint, 0),
      GREATEST(
        COALESCE(v_city.metal_capacity, 0) - COALESCE(v_city.metal, 0),
        0
      )
    );

  v_credit_energy :=
    LEAST(
      COALESCE((v_configured->>'energy')::bigint, 0),
      GREATEST(
        COALESCE(v_city.energy_capacity, 0) - COALESCE(v_city.energy, 0),
        0
      )
    );

  v_credit_water :=
    LEAST(
      COALESCE((v_configured->>'water')::bigint, 0),
      GREATEST(
        COALESCE(v_city.water_capacity, 0) - COALESCE(v_city.water, 0),
        0
      )
    );

  v_credit_crystal :=
    LEAST(
      COALESCE((v_configured->>'crystal')::bigint, 0),
      GREATEST(
        COALESCE(v_city.crystal_capacity, 0) - COALESCE(v_city.crystal, 0),
        0
      )
    );

  v_credited := jsonb_build_object(
    'metal', v_credit_metal,
    'energy', v_credit_energy,
    'water', v_credit_water,
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
     SET metal = COALESCE(metal, 0) + v_credit_metal,
         energy = COALESCE(energy, 0) + v_credit_energy,
         water = COALESCE(water, 0) + v_credit_water,
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

-- -----------------------------------------------------------------------------
-- 7) WEEKLY BOSS CHEST CLAIM
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_claim_weekly_boss_reward(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_server_time timestamptz := clock_timestamp();
  v_week_start date;
  v_city public.cities%ROWTYPE;
  v_configured jsonb := '{}'::jsonb;
  v_existing jsonb;
  v_credited jsonb;
  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_water bigint := 0;
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
        WHERE key NOT IN ('metal','energy','water','crystal')
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

  v_credit_metal :=
    LEAST(
      COALESCE((v_configured->>'metal')::bigint, 0),
      GREATEST(
        COALESCE(v_city.metal_capacity, 0) - COALESCE(v_city.metal, 0),
        0
      )
    );

  v_credit_energy :=
    LEAST(
      COALESCE((v_configured->>'energy')::bigint, 0),
      GREATEST(
        COALESCE(v_city.energy_capacity, 0) - COALESCE(v_city.energy, 0),
        0
      )
    );

  v_credit_water :=
    LEAST(
      COALESCE((v_configured->>'water')::bigint, 0),
      GREATEST(
        COALESCE(v_city.water_capacity, 0) - COALESCE(v_city.water, 0),
        0
      )
    );

  v_credit_crystal :=
    LEAST(
      COALESCE((v_configured->>'crystal')::bigint, 0),
      GREATEST(
        COALESCE(v_city.crystal_capacity, 0) - COALESCE(v_city.crystal, 0),
        0
      )
    );

  v_credited := jsonb_build_object(
    'metal', v_credit_metal,
    'energy', v_credit_energy,
    'water', v_credit_water,
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
     SET metal = COALESCE(metal, 0) + v_credit_metal,
         energy = COALESCE(energy, 0) + v_credit_energy,
         water = COALESCE(water, 0) + v_credit_water,
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

-- -----------------------------------------------------------------------------
-- 8) SECURITY
-- -----------------------------------------------------------------------------

REVOKE ALL ON TABLE public.game_boss_reward_profiles
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON TABLE public.player_boss_kills
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON TABLE public.player_boss_reward_claims
  FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.game_boss_reward_profiles
  TO service_role;

GRANT SELECT ON TABLE public.player_boss_kills
  TO service_role;

GRANT SELECT, INSERT ON TABLE public.player_boss_reward_claims
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_track_boss_kill()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.nexora_boss_rewards_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.nexora_claim_boss_first_kill(bigint, bigint)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.nexora_claim_weekly_boss_reward(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_track_boss_kill()
  TO service_role;

GRANT EXECUTE ON FUNCTION public.nexora_boss_rewards_snapshot(bigint)
  TO service_role;

GRANT EXECUTE ON FUNCTION public.nexora_claim_boss_first_kill(bigint, bigint)
  TO service_role;

GRANT EXECUTE ON FUNCTION public.nexora_claim_weekly_boss_reward(bigint)
  TO service_role;

COMMIT;
