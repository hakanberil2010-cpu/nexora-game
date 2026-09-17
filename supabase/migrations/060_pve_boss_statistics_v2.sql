-- NEXORA - PvE / Boss Statistics V2
-- Migration 060
--
-- Adds one read-only, server-side statistics snapshot derived from existing
-- immutable PvE battle reports and boss kill history.
--
-- No new counters, tables, indexes or reward/economy behavior are introduced.
-- Existing PvE combat, boss rewards and report flows remain unchanged.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_pve_statistics_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_total_battles bigint := 0;
  v_wins bigint := 0;
  v_defeats bigint := 0;
  v_draws bigint := 0;
  v_win_rate numeric := 0;
  v_reward_metal bigint := 0;
  v_reward_energy bigint := 0;
  v_reward_water bigint := 0;
  v_reward_crystal bigint := 0;
  v_elite_kills bigint := 0;
  v_boss_kills bigint := 0;
  v_monster_kills bigint := 0;
  v_unique_bosses bigint := 0;
  v_rare_drops bigint := 0;
  v_rare_drop_rate numeric := 0;
  v_max_tier_defeated integer := 0;
  v_classes jsonb := '[]'::jsonb;
  v_tactics jsonb := '[]'::jsonb;
  v_top_targets jsonb := '[]'::jsonb;
  v_recent jsonb := '[]'::jsonb;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  PERFORM 1
    FROM public.players p
   WHERE p.id = p_player_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  SELECT
    COUNT(*)::bigint,
    COUNT(*) FILTER (WHERE r.result = 'Zafer')::bigint,
    COUNT(*) FILTER (WHERE r.result = 'Yenilgi')::bigint,
    COUNT(*) FILTER (WHERE r.result = 'Beraberlik')::bigint,
    COALESCE(
      SUM(
        CASE
          WHEN COALESCE(r.reward->>'metal', '') ~ '^[0-9]{1,18}$'
            THEN (r.reward->>'metal')::bigint
          ELSE 0
        END
      ),
      0
    )::bigint,
    COALESCE(
      SUM(
        CASE
          WHEN COALESCE(r.reward->>'energy', '') ~ '^[0-9]{1,18}$'
            THEN (r.reward->>'energy')::bigint
          ELSE 0
        END
      ),
      0
    )::bigint,
    COALESCE(
      SUM(
        CASE
          WHEN COALESCE(r.reward->>'water', '') ~ '^[0-9]{1,18}$'
            THEN (r.reward->>'water')::bigint
          ELSE 0
        END
      ),
      0
    )::bigint,
    COALESCE(
      SUM(
        CASE
          WHEN COALESCE(r.reward->>'crystal', '') ~ '^[0-9]{1,18}$'
            THEN (r.reward->>'crystal')::bigint
          ELSE 0
        END
      ),
      0
    )::bigint
  INTO
    v_total_battles,
    v_wins,
    v_defeats,
    v_draws,
    v_reward_metal,
    v_reward_energy,
    v_reward_water,
    v_reward_crystal
  FROM public.npc_battle_reports r
  WHERE r.player_id = p_player_id;

  v_win_rate :=
    CASE
      WHEN v_total_battles <= 0 THEN 0
      ELSE round(
        (v_wins::numeric * 100.0) /
        v_total_battles::numeric,
        1
      )
    END;

  SELECT
    COUNT(*) FILTER (
      WHERE r.result = 'Zafer'
        AND COALESCE(c.encounter_class, 'camp') = 'elite'
    )::bigint,
    COUNT(*) FILTER (
      WHERE r.result = 'Zafer'
        AND COALESCE(c.encounter_class, 'camp') = 'boss'
    )::bigint,
    COUNT(*) FILTER (
      WHERE r.result = 'Zafer'
        AND COALESCE(c.encounter_class, 'camp')
            IN ('small', 'strong', 'elite', 'boss')
    )::bigint,
    COALESCE(
      MAX(r.camp_tier) FILTER (WHERE r.result = 'Zafer'),
      0
    )::integer,
    COUNT(
      DISTINCT r.npc_camp_id
    ) FILTER (
      WHERE r.result = 'Zafer'
        AND COALESCE(c.encounter_class, 'camp') = 'boss'
    )::bigint
  INTO
    v_elite_kills,
    v_boss_kills,
    v_monster_kills,
    v_max_tier_defeated,
    v_unique_bosses
  FROM public.npc_battle_reports r
  JOIN public.npc_camps c
    ON c.id = r.npc_camp_id
  WHERE r.player_id = p_player_id;

  SELECT
    COUNT(*) FILTER (
      WHERE k.rare_drop_key IS NOT NULL
    )::bigint
  INTO v_rare_drops
  FROM public.player_boss_kills k
  WHERE k.player_id = p_player_id;

  v_rare_drop_rate :=
    CASE
      WHEN v_boss_kills <= 0 THEN 0
      ELSE round(
        (v_rare_drops::numeric * 100.0) /
        v_boss_kills::numeric,
        1
      )
    END;

  WITH class_definitions(
    encounter_class,
    label,
    icon,
    sort_order
  ) AS (
    VALUES
      ('camp'::text,   'NPC Kampı'::text,       '🏕️'::text, 1),
      ('small'::text,  'Küçük Canavar'::text,   '🐀'::text, 2),
      ('strong'::text, 'Güçlü Canavar'::text,   '⚡'::text, 3),
      ('elite'::text,  'Elite'::text,            '🐅'::text, 4),
      ('boss'::text,   'Büyük Boss'::text,       '🐉'::text, 5)
  ),
  class_stats AS (
    SELECT
      COALESCE(c.encounter_class, 'camp') AS encounter_class,
      COUNT(*)::bigint AS battles,
      COUNT(*) FILTER (WHERE r.result = 'Zafer')::bigint AS wins,
      COUNT(*) FILTER (WHERE r.result = 'Yenilgi')::bigint AS defeats,
      COUNT(*) FILTER (WHERE r.result = 'Beraberlik')::bigint AS draws
    FROM public.npc_battle_reports r
    JOIN public.npc_camps c
      ON c.id = r.npc_camp_id
    WHERE r.player_id = p_player_id
    GROUP BY COALESCE(c.encounter_class, 'camp')
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'encounterClass', d.encounter_class,
        'label', d.label,
        'icon', d.icon,
        'battles', COALESCE(s.battles, 0),
        'wins', COALESCE(s.wins, 0),
        'defeats', COALESCE(s.defeats, 0),
        'draws', COALESCE(s.draws, 0),
        'winRate',
          CASE
            WHEN COALESCE(s.battles, 0) <= 0 THEN 0
            ELSE round(
              COALESCE(s.wins, 0)::numeric * 100.0 /
              s.battles::numeric,
              1
            )
          END
      )
      ORDER BY d.sort_order
    ),
    '[]'::jsonb
  )
  INTO v_classes
  FROM class_definitions d
  LEFT JOIN class_stats s
    ON s.encounter_class = d.encounter_class;

  WITH tactic_definitions(
    tactic,
    label,
    icon,
    sort_order
  ) AS (
    VALUES
      ('assault'::text,  'Hücum Düzeni'::text,   '⚔️'::text, 1),
      ('balanced'::text, 'Dengeli Düzen'::text,  '⚖️'::text, 2),
      ('cautious'::text, 'Temkinli Düzen'::text, '🛡️'::text, 3)
  ),
  tactic_stats AS (
    SELECT
      CASE
        WHEN lower(btrim(COALESCE(r.battle_tactic, ''))) IN (
          'assault',
          'balanced',
          'cautious'
        )
          THEN lower(btrim(r.battle_tactic))
        ELSE 'balanced'
      END AS tactic,
      COUNT(*)::bigint AS battles,
      COUNT(*) FILTER (WHERE r.result = 'Zafer')::bigint AS wins,
      COUNT(*) FILTER (WHERE r.result = 'Yenilgi')::bigint AS defeats,
      COUNT(*) FILTER (WHERE r.result = 'Beraberlik')::bigint AS draws
    FROM public.npc_battle_reports r
    WHERE r.player_id = p_player_id
    GROUP BY 1
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'tactic', d.tactic,
        'label', d.label,
        'icon', d.icon,
        'battles', COALESCE(s.battles, 0),
        'wins', COALESCE(s.wins, 0),
        'defeats', COALESCE(s.defeats, 0),
        'draws', COALESCE(s.draws, 0),
        'winRate',
          CASE
            WHEN COALESCE(s.battles, 0) <= 0 THEN 0
            ELSE round(
              COALESCE(s.wins, 0)::numeric * 100.0 /
              s.battles::numeric,
              1
            )
          END
      )
      ORDER BY d.sort_order
    ),
    '[]'::jsonb
  )
  INTO v_tactics
  FROM tactic_definitions d
  LEFT JOIN tactic_stats s
    ON s.tactic = d.tactic;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'campId', x.npc_camp_id,
        'name', x.camp_name,
        'tier', x.camp_tier,
        'encounterClass', x.encounter_class,
        'icon', x.icon,
        'battles', x.battles,
        'wins', x.wins,
        'defeats', x.defeats,
        'draws', x.draws,
        'winRate',
          CASE
            WHEN x.battles <= 0 THEN 0
            ELSE round(
              x.wins::numeric * 100.0 /
              x.battles::numeric,
              1
            )
          END,
        'lastBattleAt', x.last_battle_at
      )
      ORDER BY
        x.wins DESC,
        x.battles DESC,
        x.last_battle_at DESC,
        x.npc_camp_id
    ),
    '[]'::jsonb
  )
  INTO v_top_targets
  FROM (
    SELECT
      r.npc_camp_id,
      MAX(r.camp_name) AS camp_name,
      MAX(r.camp_tier)::integer AS camp_tier,
      COALESCE(MAX(c.encounter_class), 'camp') AS encounter_class,
      COALESCE(MAX(c.icon), '🏕️') AS icon,
      COUNT(*)::bigint AS battles,
      COUNT(*) FILTER (WHERE r.result = 'Zafer')::bigint AS wins,
      COUNT(*) FILTER (WHERE r.result = 'Yenilgi')::bigint AS defeats,
      COUNT(*) FILTER (WHERE r.result = 'Beraberlik')::bigint AS draws,
      MAX(r.created_at) AS last_battle_at
    FROM public.npc_battle_reports r
    JOIN public.npc_camps c
      ON c.id = r.npc_camp_id
    WHERE r.player_id = p_player_id
    GROUP BY r.npc_camp_id
    ORDER BY
      COUNT(*) FILTER (WHERE r.result = 'Zafer') DESC,
      COUNT(*) DESC,
      MAX(r.created_at) DESC,
      r.npc_camp_id
    LIMIT 5
  ) x;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'reportId', x.id,
        'campId', x.npc_camp_id,
        'name', x.camp_name,
        'tier', x.camp_tier,
        'encounterClass', x.encounter_class,
        'icon', x.icon,
        'result', x.result,
        'battleTactic', x.battle_tactic,
        'reward', x.reward,
        'createdAt', x.created_at
      )
      ORDER BY x.created_at DESC, x.id DESC
    ),
    '[]'::jsonb
  )
  INTO v_recent
  FROM (
    SELECT
      r.id,
      r.npc_camp_id,
      r.camp_name,
      r.camp_tier,
      COALESCE(c.encounter_class, 'camp') AS encounter_class,
      COALESCE(c.icon, '🏕️') AS icon,
      r.result,
      COALESCE(NULLIF(btrim(r.battle_tactic), ''), 'balanced')
        AS battle_tactic,
      r.reward,
      r.created_at
    FROM public.npc_battle_reports r
    JOIN public.npc_camps c
      ON c.id = r.npc_camp_id
    WHERE r.player_id = p_player_id
    ORDER BY r.created_at DESC, r.id DESC
    LIMIT 10
  ) x;

  RETURN jsonb_build_object(
    'success', true,
    'summary', jsonb_build_object(
      'totalBattles', v_total_battles,
      'wins', v_wins,
      'defeats', v_defeats,
      'draws', v_draws,
      'winRate', v_win_rate,
      'monsterKills', v_monster_kills,
      'eliteKills', v_elite_kills,
      'bossKills', v_boss_kills,
      'maxTierDefeated', v_max_tier_defeated
    ),
    'rewards', jsonb_build_object(
      'metal', v_reward_metal,
      'energy', v_reward_energy,
      'water', v_reward_water,
      'crystal', v_reward_crystal
    ),
    'boss', jsonb_build_object(
      'kills', v_boss_kills,
      'uniqueBossesDefeated', v_unique_bosses,
      'rareDrops', v_rare_drops,
      'rareDropRate', v_rare_drop_rate
    ),
    'classes', v_classes,
    'tactics', v_tactics,
    'topTargets', v_top_targets,
    'recent', v_recent
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.nexora_pve_statistics_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_pve_statistics_snapshot(bigint)
  TO service_role;

COMMIT;
