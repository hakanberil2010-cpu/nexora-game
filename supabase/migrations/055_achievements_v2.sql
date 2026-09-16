-- NEXORA - Achievements V2
-- Migration 055
--
-- Goals:
-- - Preserve all existing achievements and unlock history.
-- - Expand the achievement collection from 6 to 40 long-term badges.
-- - Add additive category / tier / points metadata.
-- - Reuse authoritative server-side progress only.
-- - Add cumulative retention metrics without changing existing metric semantics.
-- - Keep achievement points non-spendable; they are collection/progression score only.
-- - Preserve the existing game objectives contract and append achievementSummary.
--
-- Apply after 054_weekly_missions_login_rewards_v1.sql.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) ADDITIVE ACHIEVEMENT METADATA
-- -----------------------------------------------------------------------------

ALTER TABLE public.game_achievements
  ADD COLUMN IF NOT EXISTS category text NOT NULL DEFAULT 'general';

ALTER TABLE public.game_achievements
  ADD COLUMN IF NOT EXISTS tier text NOT NULL DEFAULT 'bronze';

ALTER TABLE public.game_achievements
  ADD COLUMN IF NOT EXISTS points integer NOT NULL DEFAULT 10;

-- Existing V1 achievements keep their IDs, targets and unlock history.
UPDATE public.game_achievements
   SET category = 'colony',
       tier = 'bronze',
       points = 10
 WHERE id = 'builder_20';

UPDATE public.game_achievements
   SET category = 'army',
       tier = 'bronze',
       points = 10
 WHERE id = 'army_50';

UPDATE public.game_achievements
   SET category = 'research',
       tier = 'bronze',
       points = 10
 WHERE id = 'scientist_5';

UPDATE public.game_achievements
   SET category = 'exploration',
       tier = 'bronze',
       points = 10
 WHERE id = 'explorer_5';

UPDATE public.game_achievements
   SET category = 'combat',
       tier = 'bronze',
       points = 10
 WHERE id = 'victor_5';

UPDATE public.game_achievements
   SET category = 'world',
       tier = 'silver',
       points = 25
 WHERE id = 'controller_2';

-- -----------------------------------------------------------------------------
-- 2) LONG-TERM ACHIEVEMENT COLLECTION
-- -----------------------------------------------------------------------------

INSERT INTO public.game_achievements
  (
    id,
    title,
    description,
    metric_key,
    target_value,
    icon,
    sort_order,
    active,
    category,
    tier,
    points
  )
VALUES
  -- Colony / HQ
  (
    'hq_5',
    'Koloni Merkezi',
    'Merkez Bina seviyesini 5 yap.',
    'hq_level',
    5,
    '🏛️',
    70,
    true,
    'colony',
    'bronze',
    10
  ),
  (
    'hq_10',
    'Yükselen Başkent',
    'Merkez Bina seviyesini 10 yap.',
    'hq_level',
    10,
    '🏙️',
    80,
    true,
    'colony',
    'silver',
    25
  ),
  (
    'hq_15',
    'Mega Koloni',
    'Merkez Bina seviyesini 15 yap.',
    'hq_level',
    15,
    '🌆',
    90,
    true,
    'colony',
    'gold',
    50
  ),
  (
    'hq_20',
    'NEXORA Metropolü',
    'Merkez Bina seviyesini 20 yap.',
    'hq_level',
    20,
    '🌐',
    100,
    true,
    'colony',
    'legendary',
    100
  ),

  -- Colony / total building levels
  (
    'builder_40',
    'Usta Mimar',
    'Toplam bina seviyelerinde 40 seviyeye ulaş.',
    'building_levels',
    40,
    '🏗️',
    110,
    true,
    'colony',
    'silver',
    25
  ),
  (
    'builder_80',
    'Şehir Planlayıcısı',
    'Toplam bina seviyelerinde 80 seviyeye ulaş.',
    'building_levels',
    80,
    '🏗️',
    120,
    true,
    'colony',
    'gold',
    50
  ),
  (
    'builder_120',
    'Mega Yapı Ustası',
    'Toplam bina seviyelerinde 120 seviyeye ulaş.',
    'building_levels',
    120,
    '🏗️',
    130,
    true,
    'colony',
    'legendary',
    100
  ),

  -- Army / historical training started
  (
    'trainer_100',
    'Seferberlik',
    'Toplam 100 birlik eğitimine başla.',
    'units_trained_total',
    100,
    '🪖',
    140,
    true,
    'army',
    'bronze',
    10
  ),
  (
    'trainer_250',
    'Ordu Kurucusu',
    'Toplam 250 birlik eğitimine başla.',
    'units_trained_total',
    250,
    '🛡️',
    150,
    true,
    'army',
    'silver',
    25
  ),
  (
    'trainer_500',
    'Savaş Makinesi',
    'Toplam 500 birlik eğitimine başla.',
    'units_trained_total',
    500,
    '⚔️',
    160,
    true,
    'army',
    'gold',
    50
  ),
  (
    'trainer_1000',
    'Efsanevi Ordu',
    'Toplam 1.000 birlik eğitimine başla.',
    'units_trained_total',
    1000,
    '🦅',
    170,
    true,
    'army',
    'legendary',
    100
  ),

  -- Research
  (
    'scientist_10',
    'Araştırmacı',
    'Toplam 10 araştırma seviyesi tamamla.',
    'research_levels',
    10,
    '🔬',
    180,
    true,
    'research',
    'silver',
    25
  ),
  (
    'scientist_20',
    'Baş Bilim İnsanı',
    'Toplam 20 araştırma seviyesi tamamla.',
    'research_levels',
    20,
    '🧪',
    190,
    true,
    'research',
    'gold',
    50
  ),
  (
    'scientist_35',
    'Teknoloji Öncüsü',
    'Toplam 35 araştırma seviyesi tamamla.',
    'research_levels',
    35,
    '🧬',
    200,
    true,
    'research',
    'legendary',
    100
  ),

  -- Exploration
  (
    'explorer_10',
    'Sınırların Ötesinde',
    '10 dünya keşfini başarıyla tamamla.',
    'explorations_completed',
    10,
    '🧭',
    210,
    true,
    'exploration',
    'silver',
    25
  ),
  (
    'explorer_25',
    'Dünya Kaşifi',
    '25 dünya keşfini başarıyla tamamla.',
    'explorations_completed',
    25,
    '🗺️',
    220,
    true,
    'exploration',
    'gold',
    50
  ),
  (
    'explorer_50',
    'Ufukların Efendisi',
    '50 dünya keşfini başarıyla tamamla.',
    'explorations_completed',
    50,
    '🌍',
    230,
    true,
    'exploration',
    'legendary',
    100
  ),

  -- Combat (PvP + NPC, preserving current battles_won semantics)
  (
    'victor_10',
    'Tecrübeli Komutan',
    'Toplam 10 savaş kazan.',
    'battles_won',
    10,
    '🏅',
    240,
    true,
    'combat',
    'silver',
    25
  ),
  (
    'victor_25',
    'Cephe Komutanı',
    'Toplam 25 savaş kazan.',
    'battles_won',
    25,
    '🎖️',
    250,
    true,
    'combat',
    'gold',
    50
  ),
  (
    'victor_50',
    'Savaş Efsanesi',
    'Toplam 50 savaş kazan.',
    'battles_won',
    50,
    '👑',
    260,
    true,
    'combat',
    'legendary',
    100
  ),

  -- World control
  (
    'controller_1',
    'İlk Hakimiyet',
    'Aynı anda 1 stratejik dünya noktasını kontrol et.',
    'strategic_sites',
    1,
    '🏳️',
    270,
    true,
    'world',
    'bronze',
    10
  ),

  -- Trade
  (
    'trader_1',
    'İlk Anlaşma',
    '1 ticareti başarıyla tamamla.',
    'trades_completed',
    1,
    '🤝',
    280,
    true,
    'economy',
    'bronze',
    10
  ),
  (
    'trader_5',
    'Tüccar',
    '5 ticareti başarıyla tamamla.',
    'trades_completed',
    5,
    '💱',
    290,
    true,
    'economy',
    'silver',
    25
  ),
  (
    'trader_20',
    'Ticaret Baronu',
    '20 ticareti başarıyla tamamla.',
    'trades_completed',
    20,
    '💰',
    300,
    true,
    'economy',
    'gold',
    50
  ),

  -- Login loyalty
  (
    'login_7',
    'Sadık Komutan',
    'Toplam 7 günlük giriş ödülü al.',
    'login_rewards_claimed',
    7,
    '🎁',
    310,
    true,
    'loyalty',
    'bronze',
    10
  ),
  (
    'login_30',
    'Koloninin Müdavimi',
    'Toplam 30 günlük giriş ödülü al.',
    'login_rewards_claimed',
    30,
    '📅',
    320,
    true,
    'loyalty',
    'silver',
    25
  ),
  (
    'login_90',
    'NEXORA Sadakati',
    'Toplam 90 günlük giriş ödülü al.',
    'login_rewards_claimed',
    90,
    '💠',
    330,
    true,
    'loyalty',
    'gold',
    50
  ),
  (
    'login_180',
    'Efsanevi Sadakat',
    'Toplam 180 günlük giriş ödülü al.',
    'login_rewards_claimed',
    180,
    '🌟',
    340,
    true,
    'loyalty',
    'legendary',
    100
  ),

  -- Weekly completion chest claims
  (
    'weekly_chest_1',
    'İlk Haftalık Zafer',
    '1 Haftalık Komutan Sandığı ödülü al.',
    'weekly_chests_claimed',
    1,
    '📦',
    350,
    true,
    'weekly',
    'bronze',
    10
  ),
  (
    'weekly_chest_4',
    'Aylık Disiplin',
    '4 Haftalık Komutan Sandığı ödülü al.',
    'weekly_chests_claimed',
    4,
    '🗓️',
    360,
    true,
    'weekly',
    'silver',
    25
  ),
  (
    'weekly_chest_12',
    'Sezon Komutanı',
    '12 Haftalık Komutan Sandığı ödülü al.',
    'weekly_chests_claimed',
    12,
    '🏆',
    370,
    true,
    'weekly',
    'gold',
    50
  ),

  -- Long-term progression stages
  (
    'progression_5',
    'Yolculuk Başladı',
    'Uzun vadeli ilerleme yolunda 5 aşama ödülü al.',
    'progression_stages_claimed',
    5,
    '🧭',
    380,
    true,
    'progression',
    'bronze',
    10
  ),
  (
    'progression_15',
    'Yolun Yarısı',
    'Uzun vadeli ilerleme yolunda 15 aşama ödülü al.',
    'progression_stages_claimed',
    15,
    '🚀',
    390,
    true,
    'progression',
    'silver',
    25
  ),
  (
    'progression_30',
    'NEXORA Efsanesi',
    '30 aşamalı uzun vadeli ilerleme yolunu tamamla.',
    'progression_stages_claimed',
    30,
    '👑',
    400,
    true,
    'progression',
    'legendary',
    100
  )
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  metric_key = EXCLUDED.metric_key,
  target_value = EXCLUDED.target_value,
  icon = EXCLUDED.icon,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active,
  category = EXCLUDED.category,
  tier = EXCLUDED.tier,
  points = EXCLUDED.points;

-- -----------------------------------------------------------------------------
-- 3) SERVER-AUTHORITATIVE CUMULATIVE ACHIEVEMENT METRICS
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_achievement_metrics_v2(
  p_player_id bigint
)
RETURNS TABLE(
  metric_key text,
  metric_value bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  SELECT
    metrics.metric_key,
    GREATEST(COALESCE(metrics.metric_value, 0), 0)::bigint
  FROM (
    SELECT
      'hq_level'::text AS metric_key,
      COALESCE(MAX(b.level), 0)::bigint AS metric_value
    FROM public.buildings b
    JOIN public.cities c
      ON c.id = b.city_id
    WHERE c.player_id = p_player_id
      AND b.building_type = 'Merkez Bina'

    UNION ALL

    SELECT
      'building_levels'::text,
      COALESCE(
        SUM(GREATEST(COALESCE(b.level, 0), 0)),
        0
      )::bigint
    FROM public.buildings b
    JOIN public.cities c
      ON c.id = b.city_id
    WHERE c.player_id = p_player_id

    UNION ALL

    SELECT
      'unit_count'::text,
      COALESCE(
        SUM(GREATEST(COALESCE(u.quantity, 0), 0)),
        0
      )::bigint
    FROM public.units u
    JOIN public.cities c
      ON c.id = u.city_id
    WHERE c.player_id = p_player_id

    UNION ALL

    SELECT
      'research_levels'::text,
      COALESCE(
        SUM(
          GREATEST(COALESCE(r.general_power_level, 0), 0)
          + GREATEST(COALESCE(r.unit_attack_level, 0), 0)
          + GREATEST(COALESCE(r.unit_defense_level, 0), 0)
          + GREATEST(COALESCE(r.unit_hp_level, 0), 0)
          + GREATEST(COALESCE(r.travel_speed_level, 0), 0)
          + GREATEST(COALESCE(r.combat_level, 0), 0)
          + GREATEST(COALESCE(r.defense_level, 0), 0)
          + GREATEST(COALESCE(r.production_level, 0), 0)
          + GREATEST(COALESCE(r.crystal_level, 0), 0)
        ),
        0
      )::bigint
    FROM public.research r
    WHERE r.player_id = p_player_id

    UNION ALL

    SELECT
      'explorations_completed'::text,
      COUNT(*)::bigint
    FROM public.world_exploration_missions m
    WHERE m.player_id = p_player_id
      AND m.status = 'completed'

    UNION ALL

    SELECT
      'battles_won'::text,
      (
        (
          SELECT COUNT(*)::bigint
          FROM public.battle_reports b
          WHERE b.winner_player_id = p_player_id
        )
        +
        (
          SELECT COUNT(*)::bigint
          FROM public.npc_battle_reports n
          WHERE n.player_id = p_player_id
            AND n.result = 'Zafer'
        )
      )::bigint

    UNION ALL

    SELECT
      'strategic_sites'::text,
      COUNT(*)::bigint
    FROM public.world_sites s
    WHERE s.owner_player_id = p_player_id
      AND s.active IS TRUE

    UNION ALL

    SELECT
      'units_trained_total'::text,
      COALESCE(
        SUM(GREATEST(COALESCE(q.quantity, 0), 0)),
        0
      )::bigint
    FROM public.unit_production_queue q
    WHERE q.player_id = p_player_id

    UNION ALL

    SELECT
      'trades_completed'::text,
      COUNT(*)::bigint
    FROM public.trade_offers t
    WHERE t.status = 'accepted'
      AND (
        t.creator_player_id = p_player_id
        OR t.accepted_by_player_id = p_player_id
      )

    UNION ALL

    SELECT
      'login_rewards_claimed'::text,
      COUNT(*)::bigint
    FROM public.player_login_reward_claims c
    WHERE c.player_id = p_player_id

    UNION ALL

    SELECT
      'weekly_chests_claimed'::text,
      COUNT(*)::bigint
    FROM public.player_weekly_mission_claims c
    WHERE c.player_id = p_player_id
      AND c.mission_id = 'weekly_complete_all'

    UNION ALL

    SELECT
      'progression_stages_claimed'::text,
      COUNT(*)::bigint
    FROM public.player_progression_claims c
    WHERE c.player_id = p_player_id
  ) metrics;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_progress_value(
  p_player_id bigint,
  p_metric_key text
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
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
        JOIN public.cities c
          ON c.id = b.city_id
       WHERE c.player_id = p_player_id
         AND b.building_type = 'Merkez Bina';

    WHEN 'building_levels' THEN
      SELECT COALESCE(
               SUM(GREATEST(COALESCE(b.level, 0), 0)),
               0
             )::bigint
        INTO v_value
        FROM public.buildings b
        JOIN public.cities c
          ON c.id = b.city_id
       WHERE c.player_id = p_player_id;

    WHEN 'unit_count' THEN
      SELECT COALESCE(
               SUM(GREATEST(COALESCE(u.quantity, 0), 0)),
               0
             )::bigint
        INTO v_value
        FROM public.units u
        JOIN public.cities c
          ON c.id = u.city_id
       WHERE c.player_id = p_player_id;

    WHEN 'research_levels' THEN
      SELECT COALESCE(
               SUM(
                 GREATEST(COALESCE(r.general_power_level, 0), 0)
                 + GREATEST(COALESCE(r.unit_attack_level, 0), 0)
                 + GREATEST(COALESCE(r.unit_defense_level, 0), 0)
                 + GREATEST(COALESCE(r.unit_hp_level, 0), 0)
                 + GREATEST(COALESCE(r.travel_speed_level, 0), 0)
                 + GREATEST(COALESCE(r.combat_level, 0), 0)
                 + GREATEST(COALESCE(r.defense_level, 0), 0)
                 + GREATEST(COALESCE(r.production_level, 0), 0)
                 + GREATEST(COALESCE(r.crystal_level, 0), 0)
               ),
               0
             )::bigint
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
      SELECT
        (
          SELECT COUNT(*)::bigint
            FROM public.battle_reports b
           WHERE b.winner_player_id = p_player_id
        )
        +
        (
          SELECT COUNT(*)::bigint
            FROM public.npc_battle_reports n
           WHERE n.player_id = p_player_id
             AND n.result = 'Zafer'
        )
        INTO v_value;

    WHEN 'strategic_sites' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.world_sites s
       WHERE s.owner_player_id = p_player_id
         AND s.active IS TRUE;

    WHEN 'units_trained_total' THEN
      SELECT COALESCE(
               SUM(GREATEST(COALESCE(q.quantity, 0), 0)),
               0
             )::bigint
        INTO v_value
        FROM public.unit_production_queue q
       WHERE q.player_id = p_player_id;

    WHEN 'trades_completed' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.trade_offers t
       WHERE t.status = 'accepted'
         AND (
           t.creator_player_id = p_player_id
           OR t.accepted_by_player_id = p_player_id
         );

    WHEN 'login_rewards_claimed' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.player_login_reward_claims c
       WHERE c.player_id = p_player_id;

    WHEN 'weekly_chests_claimed' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.player_weekly_mission_claims c
       WHERE c.player_id = p_player_id
         AND c.mission_id = 'weekly_complete_all';

    WHEN 'progression_stages_claimed' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.player_progression_claims c
       WHERE c.player_id = p_player_id;

    ELSE
      v_value := 0;
  END CASE;

  RETURN GREATEST(COALESCE(v_value, 0), 0);
END;
$function$;

-- -----------------------------------------------------------------------------
-- 4) ADDITIVE ACHIEVEMENT COLLECTION SNAPSHOT
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_missions_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH achievement_metrics AS MATERIALIZED (
    SELECT metric_key, metric_value
      FROM public.nexora_achievement_metrics_v2(p_player_id)
  )
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
            'progress', COALESCE(am.metric_value, 0),
            'target', a.target_value,
            'icon', a.icon,
            'category', a.category,
            'tier', a.tier,
            'points', a.points,
            'unlocked', pa.achievement_id IS NOT NULL,
            'unlockedAt', pa.unlocked_at
          )
          ORDER BY a.sort_order, a.id
        )
        FROM public.game_achievements a
        LEFT JOIN achievement_metrics am
          ON am.metric_key = a.metric_key
        LEFT JOIN public.player_achievements pa
          ON pa.player_id = p_player_id
         AND pa.achievement_id = a.id
        WHERE a.active IS TRUE
      ), '[]'::jsonb),
    'achievementSummary',
      jsonb_build_object(
        'unlockedCount',
          (
            SELECT COUNT(*)::bigint
              FROM public.game_achievements a
              JOIN public.player_achievements pa
                ON pa.player_id = p_player_id
               AND pa.achievement_id = a.id
             WHERE a.active IS TRUE
          ),
        'totalCount',
          (
            SELECT COUNT(*)::bigint
              FROM public.game_achievements a
             WHERE a.active IS TRUE
          ),
        'points',
          (
            SELECT COALESCE(SUM(GREATEST(a.points, 0)), 0)::bigint
              FROM public.game_achievements a
              JOIN public.player_achievements pa
                ON pa.player_id = p_player_id
               AND pa.achievement_id = a.id
             WHERE a.active IS TRUE
          ),
        'maxPoints',
          (
            SELECT COALESCE(SUM(GREATEST(a.points, 0)), 0)::bigint
              FROM public.game_achievements a
             WHERE a.active IS TRUE
          )
      ),
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
$function$;

-- Refresh remains API-compatible, but computes all achievement metrics as one
-- consolidated set instead of re-running the same metric for every badge.
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
    JOIN public.nexora_achievement_metrics_v2(p_player_id) m
      ON m.metric_key = a.metric_key
    LEFT JOIN public.player_achievements pa
      ON pa.player_id = p_player_id
     AND pa.achievement_id = a.id
   WHERE a.active IS TRUE
     AND pa.achievement_id IS NULL
     AND m.metric_value >= a.target_value
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
-- 5) SECURITY
-- -----------------------------------------------------------------------------

REVOKE ALL ON FUNCTION
  public.nexora_achievement_metrics_v2(bigint)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  public.nexora_progress_value(bigint, text)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  public.nexora_missions_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  public.nexora_refresh_achievements(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.nexora_achievement_metrics_v2(bigint)
  TO service_role;

GRANT EXECUTE ON FUNCTION
  public.nexora_progress_value(bigint, text)
  TO service_role;

GRANT EXECUTE ON FUNCTION
  public.nexora_missions_snapshot(bigint)
  TO service_role;

GRANT EXECUTE ON FUNCTION
  public.nexora_refresh_achievements(bigint)
  TO service_role;

COMMIT;
