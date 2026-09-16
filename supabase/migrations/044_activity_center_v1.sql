-- NEXORA - Activity Center V1
-- Migration 044
--
-- Goals:
-- - Add a unified player activity feed without changing existing gameplay writes.
-- - Derive events from authoritative existing tables.
-- - Track unread state only with a server-side last_seen_at timestamp.
-- - Never trust a client timestamp for read/unread state.
-- - Keep all RPC/table access server-only via service_role.
--
-- V1 event sources:
-- - PvP battle reports
-- - NPC battle reports
-- - completed world explorations
-- - claimed daily mission rewards
--
-- Apply after 043_daily_missions_v1.sql.
-- Backend/frontend integration is intentionally handled in later stages.

BEGIN;

CREATE TABLE IF NOT EXISTS public.player_activity_state (
  player_id bigint PRIMARY KEY REFERENCES public.players(id) ON DELETE CASCADE,
  last_seen_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE OR REPLACE FUNCTION public.nexora_activity_events(p_player_id bigint)
RETURNS TABLE (
  event_id text,
  event_type text,
  occurred_at timestamptz,
  title text,
  summary text,
  tone text,
  href text,
  meta jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  SELECT
    'pvp:' || br.id::text AS event_id,
    'pvp_battle'::text AS event_type,
    br.created_at AS occurred_at,
    CASE
      WHEN br.attacker_player_id = p_player_id THEN '⚔️ Saldırı Sonucu'
      ELSE '🛡️ Savunma Sonucu'
    END AS title,
    CASE
      WHEN br.attacker_player_id = p_player_id THEN
        COALESCE(opponent.username, 'Oyuncu') ||
        ' oyuncusuna karşı saldırın: ' ||
        CASE
          WHEN br.winner_player_id = p_player_id THEN 'Zafer'
          WHEN br.winner_player_id IS NULL THEN 'Beraberlik'
          ELSE 'Yenilgi'
        END || '.'
      ELSE
        COALESCE(opponent.username, 'Oyuncu') ||
        ' oyuncusunun saldırısı: ' ||
        CASE
          WHEN br.winner_player_id = p_player_id THEN 'Zafer'
          WHEN br.winner_player_id IS NULL THEN 'Beraberlik'
          ELSE 'Yenilgi'
        END || '.'
    END AS summary,
    CASE
      WHEN br.winner_player_id = p_player_id THEN 'success'
      WHEN br.winner_player_id IS NULL THEN 'neutral'
      ELSE 'danger'
    END AS tone,
    'reports.html'::text AS href,
    jsonb_build_object(
      'reportId', br.id,
      'role', CASE
        WHEN br.attacker_player_id = p_player_id THEN 'attacker'
        ELSE 'defender'
      END,
      'outcome', CASE
        WHEN br.winner_player_id = p_player_id THEN 'Zafer'
        WHEN br.winner_player_id IS NULL THEN 'Beraberlik'
        ELSE 'Yenilgi'
      END,
      'opponentPlayerId', opponent.id,
      'opponentUsername', opponent.username,
      'battlePoints', COALESCE(br.battle_points, 0),
      'loot', COALESCE(br.loot, '{}'::jsonb)
    ) AS meta
  FROM public.battle_reports br
  LEFT JOIN public.players opponent
    ON opponent.id = CASE
      WHEN br.attacker_player_id = p_player_id THEN br.defender_player_id
      ELSE br.attacker_player_id
    END
  WHERE br.created_at IS NOT NULL
    AND (
      br.attacker_player_id = p_player_id
      OR br.defender_player_id = p_player_id
    )

  UNION ALL

  SELECT
    'npc:' || r.id::text AS event_id,
    'npc_battle'::text AS event_type,
    r.created_at AS occurred_at,
    '🏕️ NPC Savaşı'::text AS title,
    COALESCE(NULLIF(btrim(r.camp_name), ''), 'NPC Kampı') ||
      ': ' || COALESCE(NULLIF(btrim(r.result), ''), 'Sonuçlandı') || '.' AS summary,
    CASE
      WHEN r.result = 'Zafer' THEN 'success'
      WHEN r.result = 'Yenilgi' THEN 'danger'
      ELSE 'neutral'
    END AS tone,
    'reports.html'::text AS href,
    jsonb_build_object(
      'reportId', r.id,
      'npcMissionId', r.npc_mission_id,
      'npcCampId', r.npc_camp_id,
      'campName', r.camp_name,
      'campTier', r.camp_tier,
      'outcome', r.result,
      'reward', COALESCE(r.reward, '{}'::jsonb)
    ) AS meta
  FROM public.npc_battle_reports r
  WHERE r.player_id = p_player_id
    AND r.created_at IS NOT NULL

  UNION ALL

  SELECT
    'explore:' || m.id::text AS event_id,
    'world_exploration'::text AS event_type,
    m.completed_at AS occurred_at,
    '🧭 Keşif Tamamlandı'::text AS title,
    COALESCE(NULLIF(btrim(s.name), ''), 'Dünya noktası') ||
      ' keşfi tamamlandı.' AS summary,
    'success'::text AS tone,
    'world.html'::text AS href,
    jsonb_build_object(
      'missionId', m.id,
      'siteId', m.site_id,
      'siteName', s.name,
      'result', COALESCE(m.result, '{}'::jsonb)
    ) AS meta
  FROM public.world_exploration_missions m
  LEFT JOIN public.world_sites s
    ON s.id = m.site_id
  WHERE m.player_id = p_player_id
    AND m.status = 'completed'
    AND m.completed_at IS NOT NULL

  UNION ALL

  SELECT
    'daily:' || c.mission_date::text || ':' || c.mission_id AS event_id,
    'daily_mission_claim'::text AS event_type,
    c.claimed_at AS occurred_at,
    '🎯 Günlük Görev Ödülü'::text AS title,
    COALESCE(NULLIF(btrim(d.title), ''), 'Günlük görev') ||
      ' ödülü alındı.' AS summary,
    'success'::text AS tone,
    'missions.html'::text AS href,
    jsonb_build_object(
      'missionDate', c.mission_date,
      'missionId', c.mission_id,
      'missionTitle', d.title,
      'rewardCredited', COALESCE(c.reward, '{}'::jsonb)
    ) AS meta
  FROM public.player_daily_mission_claims c
  LEFT JOIN public.game_daily_missions d
    ON d.id = c.mission_id
  WHERE c.player_id = p_player_id
    AND c.claimed_at IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_activity_snapshot(
  p_player_id bigint,
  p_limit integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_server_time timestamptz := clock_timestamp();
  v_last_seen_at timestamptz;
  v_limit integer := LEAST(50, GREATEST(1, COALESCE(p_limit, 30)));
  v_unread_count bigint := 0;
  v_items jsonb := '[]'::jsonb;
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

  SELECT s.last_seen_at
    INTO v_last_seen_at
  FROM public.player_activity_state s
  WHERE s.player_id = p_player_id;

  SELECT COUNT(*)::bigint
    INTO v_unread_count
  FROM public.nexora_activity_events(p_player_id) e
  WHERE v_last_seen_at IS NULL
     OR e.occurred_at > v_last_seen_at;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', e.event_id,
        'type', e.event_type,
        'occurredAt', e.occurred_at,
        'title', e.title,
        'summary', e.summary,
        'tone', e.tone,
        'href', e.href,
        'meta', COALESCE(e.meta, '{}'::jsonb),
        'unread', v_last_seen_at IS NULL OR e.occurred_at > v_last_seen_at
      )
      ORDER BY e.occurred_at DESC, e.event_id DESC
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM (
    SELECT *
    FROM public.nexora_activity_events(p_player_id)
    ORDER BY occurred_at DESC, event_id DESC
    LIMIT v_limit
  ) e;

  RETURN jsonb_build_object(
    'success', true,
    'serverTime', v_server_time,
    'lastSeenAt', v_last_seen_at,
    'unreadCount', GREATEST(COALESCE(v_unread_count, 0), 0),
    'items', v_items
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_mark_activity_seen(p_player_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_seen_at timestamptz;
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

  v_seen_at := clock_timestamp();

  INSERT INTO public.player_activity_state (
    player_id,
    last_seen_at,
    updated_at
  )
  VALUES (
    p_player_id,
    v_seen_at,
    v_seen_at
  )
  ON CONFLICT (player_id) DO UPDATE SET
    last_seen_at = GREATEST(
      COALESCE(public.player_activity_state.last_seen_at, '-infinity'::timestamptz),
      EXCLUDED.last_seen_at
    ),
    updated_at = EXCLUDED.updated_at;

  RETURN public.nexora_activity_snapshot(p_player_id, 30);
END;
$function$;

ALTER TABLE public.player_activity_state ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.player_activity_state
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.player_activity_state
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_activity_events(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_activity_snapshot(bigint, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_mark_activity_seen(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_activity_events(bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_activity_snapshot(bigint, integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_mark_activity_seen(bigint)
  TO service_role;

COMMIT;
