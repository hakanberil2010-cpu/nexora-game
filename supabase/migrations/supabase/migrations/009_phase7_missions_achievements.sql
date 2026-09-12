-- NEXORA Phase 7 – Görevler & Başarımlar V1
-- Apply after 008_phase6_owned_site_exploration_lock.sql.
-- Additive, production-safe, rerunnable. Existing gameplay tables/rows are preserved.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) DEFINITIONS + PLAYER STATE
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.game_missions (
  id text PRIMARY KEY,
  title text NOT NULL,
  description text NOT NULL,
  metric_key text NOT NULL,
  target_value bigint NOT NULL CHECK (target_value > 0),
  reward jsonb NOT NULL DEFAULT '{}'::jsonb,
  sort_order integer NOT NULL DEFAULT 0,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.player_mission_claims (
  player_id bigint NOT NULL,
  mission_id text NOT NULL REFERENCES public.game_missions(id) ON DELETE RESTRICT,
  claimed_at timestamptz NOT NULL DEFAULT now(),
  reward jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (player_id, mission_id)
);

CREATE TABLE IF NOT EXISTS public.game_achievements (
  id text PRIMARY KEY,
  title text NOT NULL,
  description text NOT NULL,
  metric_key text NOT NULL,
  target_value bigint NOT NULL CHECK (target_value > 0),
  icon text NOT NULL DEFAULT '🏆',
  sort_order integer NOT NULL DEFAULT 0,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.player_achievements (
  player_id bigint NOT NULL,
  achievement_id text NOT NULL REFERENCES public.game_achievements(id) ON DELETE RESTRICT,
  unlocked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (player_id, achievement_id)
);

CREATE INDEX IF NOT EXISTS idx_player_mission_claims_player
  ON public.player_mission_claims(player_id, claimed_at DESC);

CREATE INDEX IF NOT EXISTS idx_player_achievements_player
  ON public.player_achievements(player_id, unlocked_at DESC);

-- V1 one-time missions. Existing players can complete these from their current
-- canonical game state; no client-side progress counter is trusted.
INSERT INTO public.game_missions
  (id, title, description, metric_key, target_value, reward, sort_order, active)
VALUES
  (
    'hq_level_2',
    'Koloniyi Güçlendir',
    'Merkez Bina seviyesini 2 yap.',
    'hq_level',
    2,
    '{"metal":500,"energy":250,"water":0,"crystal":0}'::jsonb,
    10,
    true
  ),
  (
    'army_10',
    'İlk Ordu',
    'Toplam 10 birlik sahibi ol.',
    'unit_count',
    10,
    '{"metal":300,"energy":150,"water":0,"crystal":0}'::jsonb,
    20,
    true
  ),
  (
    'research_1',
    'Bilime İlk Adım',
    'En az 1 araştırma seviyesi tamamla.',
    'research_levels',
    1,
    '{"metal":0,"energy":250,"water":0,"crystal":75}'::jsonb,
    30,
    true
  ),
  (
    'exploration_1',
    'Ufkun Ötesi',
    '1 dünya keşfini başarıyla tamamla.',
    'explorations_completed',
    1,
    '{"metal":0,"energy":0,"water":250,"crystal":75}'::jsonb,
    40,
    true
  ),
  (
    'victory_1',
    'İlk Zafer',
    '1 savaşı kazan.',
    'battles_won',
    1,
    '{"metal":400,"energy":0,"water":0,"crystal":100}'::jsonb,
    50,
    true
  ),
  (
    'strategic_site_1',
    'Stratejik Hakimiyet',
    '1 stratejik dünya noktasını kontrol altına al.',
    'strategic_sites',
    1,
    '{"metal":300,"energy":0,"water":0,"crystal":150}'::jsonb,
    60,
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

INSERT INTO public.game_achievements
  (id, title, description, metric_key, target_value, icon, sort_order, active)
VALUES
  (
    'builder_20',
    'Yapı Ustası',
    'Toplam bina seviyelerinde 20 seviyeye ulaş.',
    'building_levels',
    20,
    '🏗️',
    10,
    true
  ),
  (
    'army_50',
    'Ordu Komutanı',
    'Toplam 50 birlik sahibi ol.',
    'unit_count',
    50,
    '⚔️',
    20,
    true
  ),
  (
    'scientist_5',
    'Bilim İnsanı',
    'Toplam 5 araştırma seviyesi tamamla.',
    'research_levels',
    5,
    '🔬',
    30,
    true
  ),
  (
    'explorer_5',
    'Kaşif',
    '5 dünya keşfini başarıyla tamamla.',
    'explorations_completed',
    5,
    '🧭',
    40,
    true
  ),
  (
    'victor_5',
    'Fatih',
    '5 savaş kazan.',
    'battles_won',
    5,
    '🏅',
    50,
    true
  ),
  (
    'controller_2',
    'Stratejist',
    'Aynı anda 2 stratejik dünya noktasını kontrol et.',
    'strategic_sites',
    2,
    '🏳️',
    60,
    true
  )
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  metric_key = EXCLUDED.metric_key,
  target_value = EXCLUDED.target_value,
  icon = EXCLUDED.icon,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active;

-- -----------------------------------------------------------------------------
-- 2) SERVER-SIDE CANONICAL PROGRESS
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_progress_value(
  p_player_id bigint,
  p_metric_key text
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_value bigint := 0;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN 0;
  END IF;

  CASE p_metric_key
    WHEN 'hq_level' THEN
      SELECT COALESCE(MAX(b.level), 0)::bigint
        INTO v_value
        FROM public.buildings b
        JOIN public.cities c ON c.id = b.city_id
       WHERE c.player_id = p_player_id
         AND b.building_type = 'Merkez Bina';

    WHEN 'building_levels' THEN
      SELECT COALESCE(SUM(GREATEST(COALESCE(b.level, 0), 0)), 0)::bigint
        INTO v_value
        FROM public.buildings b
        JOIN public.cities c ON c.id = b.city_id
       WHERE c.player_id = p_player_id;

    WHEN 'unit_count' THEN
      SELECT COALESCE(SUM(GREATEST(COALESCE(u.quantity, 0), 0)), 0)::bigint
        INTO v_value
        FROM public.units u
        JOIN public.cities c ON c.id = u.city_id
       WHERE c.player_id = p_player_id;

    WHEN 'research_levels' THEN
      SELECT COALESCE(SUM(
        GREATEST(COALESCE(r.general_power_level, 0), 0) +
        GREATEST(COALESCE(r.unit_attack_level, 0), 0) +
        GREATEST(COALESCE(r.unit_defense_level, 0), 0) +
        GREATEST(COALESCE(r.unit_hp_level, 0), 0) +
        GREATEST(COALESCE(r.travel_speed_level, 0), 0) +
        GREATEST(COALESCE(r.combat_level, 0), 0) +
        GREATEST(COALESCE(r.defense_level, 0), 0) +
        GREATEST(COALESCE(r.production_level, 0), 0) +
        GREATEST(COALESCE(r.crystal_level, 0), 0)
      ), 0)::bigint
        INTO v_value
        FROM public.research r
       WHERE r.player_id = p_player_id;

    WHEN 'explorations_completed' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.world_exploration_missions m
       WHERE m.player_id = p_player_id
         AND m.status = 'completed';

    WHEN 'battles_won' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.battle_reports b
       WHERE b.winner_player_id = p_player_id;

    WHEN 'strategic_sites' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.world_sites s
       WHERE s.owner_player_id = p_player_id
         AND s.active IS TRUE;

    ELSE
      v_value := 0;
  END CASE;

  RETURN GREATEST(COALESCE(v_value, 0), 0);
END;
$$;

-- -----------------------------------------------------------------------------
-- 3) SNAPSHOT + ACHIEVEMENT REFRESH
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_missions_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'success', true,
    'missions',
      COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', m.id,
            'title', m.title,
            'description', m.description,
            'metricKey', m.metric_key,
            'progress', public.nexora_progress_value(p_player_id, m.metric_key),
            'target', m.target_value,
            'completed', public.nexora_progress_value(p_player_id, m.metric_key) >= m.target_value,
            'claimed', c.mission_id IS NOT NULL,
            'claimedAt', c.claimed_at,
            'reward', m.reward,
            'creditedReward', COALESCE(c.reward, '{}'::jsonb)
          )
          ORDER BY m.sort_order, m.id
        )
        FROM public.game_missions m
        LEFT JOIN public.player_mission_claims c
          ON c.player_id = p_player_id
         AND c.mission_id = m.id
        WHERE m.active IS TRUE
      ), '[]'::jsonb),
    'achievements',
      COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', a.id,
            'title', a.title,
            'description', a.description,
            'metricKey', a.metric_key,
            'progress', public.nexora_progress_value(p_player_id, a.metric_key),
            'target', a.target_value,
            'icon', a.icon,
            'unlocked', pa.achievement_id IS NOT NULL,
            'unlockedAt', pa.unlocked_at
          )
          ORDER BY a.sort_order, a.id
        )
        FROM public.game_achievements a
        LEFT JOIN public.player_achievements pa
          ON pa.player_id = p_player_id
         AND pa.achievement_id = a.id
        WHERE a.active IS TRUE
      ), '[]'::jsonb),
    'metrics',
      jsonb_build_object(
        'hqLevel', public.nexora_progress_value(p_player_id, 'hq_level'),
        'buildingLevels', public.nexora_progress_value(p_player_id, 'building_levels'),
        'unitCount', public.nexora_progress_value(p_player_id, 'unit_count'),
        'researchLevels', public.nexora_progress_value(p_player_id, 'research_levels'),
        'explorationsCompleted', public.nexora_progress_value(p_player_id, 'explorations_completed'),
        'battlesWon', public.nexora_progress_value(p_player_id, 'battles_won'),
        'strategicSites', public.nexora_progress_value(p_player_id, 'strategic_sites')
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.nexora_refresh_achievements(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR NOT EXISTS (SELECT 1 FROM public.players WHERE id = p_player_id) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  INSERT INTO public.player_achievements(player_id, achievement_id, unlocked_at)
  SELECT p_player_id, a.id, now()
    FROM public.game_achievements a
   WHERE a.active IS TRUE
     AND public.nexora_progress_value(p_player_id, a.metric_key) >= a.target_value
  ON CONFLICT (player_id, achievement_id) DO NOTHING;

  RETURN public.nexora_missions_snapshot(p_player_id);
END;
$$;

-- -----------------------------------------------------------------------------
-- 4) ATOMIC MISSION REWARD CLAIM
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_claim_mission(
  p_player_id bigint,
  p_mission_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
  v_reward_water bigint := 0;
  v_reward_crystal bigint := 0;

  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_water bigint := 0;
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

  v_progress := public.nexora_progress_value(p_player_id, v_mission.metric_key);

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
    COALESCE(MAX(CASE WHEN building_type = 'Depo' THEN level END), 0),
    COALESCE(MAX(CASE WHEN building_type = 'Kristal Deposu' THEN level END), 0)
    INTO v_depo_level, v_crystal_depo_level
    FROM public.buildings
   WHERE city_id = v_city.id;

  v_storage := 5000 + GREATEST(v_depo_level, 0) * 2500;
  v_crystal_storage := 3000 + GREATEST(v_crystal_depo_level, 0) * 1500;

  v_reward := COALESCE(v_mission.reward, '{}'::jsonb);
  v_reward_metal := GREATEST(0, COALESCE((v_reward ->> 'metal')::bigint, 0));
  v_reward_energy := GREATEST(0, COALESCE((v_reward ->> 'energy')::bigint, 0));
  v_reward_water := GREATEST(0, COALESCE((v_reward ->> 'water')::bigint, 0));
  v_reward_crystal := GREATEST(0, COALESCE((v_reward ->> 'crystal')::bigint, 0));

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
         updated_at = now()
   WHERE id = v_city.id;

  v_credited := jsonb_build_object(
    'metal', v_credit_metal,
    'energy', v_credit_energy,
    'water', v_credit_water,
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
  INSERT INTO public.player_achievements(player_id, achievement_id, unlocked_at)
  SELECT p_player_id, a.id, now()
    FROM public.game_achievements a
   WHERE a.active IS TRUE
     AND public.nexora_progress_value(p_player_id, a.metric_key) >= a.target_value
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
$$;

-- -----------------------------------------------------------------------------
-- 5) SECURITY
-- Backend uses the service role. Browsers cannot call these RPCs or mutate
-- mission/achievement state directly through Supabase.
-- -----------------------------------------------------------------------------

ALTER TABLE public.game_missions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_mission_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_achievements ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.game_missions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.player_mission_claims FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.game_achievements FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.player_achievements FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.game_missions TO service_role;
GRANT ALL ON TABLE public.player_mission_claims TO service_role;
GRANT ALL ON TABLE public.game_achievements TO service_role;
GRANT ALL ON TABLE public.player_achievements TO service_role;

REVOKE ALL ON FUNCTION public.nexora_progress_value(bigint,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_missions_snapshot(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_refresh_achievements(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_claim_mission(bigint,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_progress_value(bigint,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_missions_snapshot(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_refresh_achievements(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_claim_mission(bigint,text) TO service_role;

COMMIT;
