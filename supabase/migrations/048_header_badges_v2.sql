-- NEXORA - Header Badges V2. Apply after 047_friends_v1.sql.
-- Count the same events as 044, without feed metadata, joins or JSON lists.
-- Existing player/time, unread-message and friendship indexes are reused.
BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_header_badges_snapshot(p_player_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_last_seen_at timestamptz;
  v_activity_unread bigint;
  v_message_unread bigint;
  v_friend_incoming bigint;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 OR NOT EXISTS (
    SELECT 1 FROM public.players WHERE id = p_player_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false, 'code', 'PLAYER_NOT_FOUND', 'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  SELECT last_seen_at INTO v_last_seen_at
  FROM public.player_activity_state WHERE player_id = p_player_id;

  -- Strict >, no feed limit and no future-time cutoff, exactly as in 044.
  SELECT SUM(n)::bigint INTO v_activity_unread FROM (
    SELECT COUNT(*) AS n FROM public.battle_reports
    WHERE (attacker_player_id = p_player_id OR defender_player_id = p_player_id)
      AND created_at IS NOT NULL
      AND (v_last_seen_at IS NULL OR created_at > v_last_seen_at)
    UNION ALL
    SELECT COUNT(*) FROM public.npc_battle_reports
    WHERE player_id = p_player_id AND created_at IS NOT NULL
      AND (v_last_seen_at IS NULL OR created_at > v_last_seen_at)
    UNION ALL
    SELECT COUNT(*) FROM public.world_exploration_missions
    WHERE player_id = p_player_id AND status = 'completed' AND completed_at IS NOT NULL
      AND (v_last_seen_at IS NULL OR completed_at > v_last_seen_at)
    UNION ALL
    SELECT COUNT(*) FROM public.player_daily_mission_claims
    WHERE player_id = p_player_id AND claimed_at IS NOT NULL
      AND (v_last_seen_at IS NULL OR claimed_at > v_last_seen_at)
  ) counts;

  SELECT COUNT(*) INTO v_message_unread
  FROM public.player_private_messages
  WHERE recipient_player_id = p_player_id AND read_at IS NULL;

  -- Requester existence is guaranteed by the existing FK in 047.
  SELECT COUNT(*) INTO v_friend_incoming
  FROM public.player_friendships
  WHERE status = 'pending' AND requester_player_id <> p_player_id
    AND (player_one_id = p_player_id OR player_two_id = p_player_id);

  RETURN jsonb_build_object(
    'success', true,
    'activityUnread', v_activity_unread,
    'messageUnread', v_message_unread,
    'friendIncoming', v_friend_incoming,
    'serverTime', statement_timestamp()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.nexora_header_badges_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_header_badges_snapshot(bigint)
  TO service_role;

COMMIT;
