-- NEXORA - Notification System V2
-- Migration 067
--
-- Goals:
-- - Build one server-side notification snapshot from existing authoritative systems.
-- - Preserve Activity Center V1 read state and existing message/friend semantics.
-- - Avoid a duplicate notification table or copied event rows.
-- - Keep browser roles away from private notification sources.
-- - Return only the authenticated player's own social notification data.
--
-- Sources:
-- - nexora_activity_snapshot / player_activity_state
-- - player_private_messages
-- - player_friendships
--
-- Apply after 066_final_water_cleanup.sql.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_notifications_snapshot(
  p_player_id bigint,
  p_activity_limit integer DEFAULT 30,
  p_social_limit integer DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_server_time timestamptz := clock_timestamp();
  v_activity_limit integer :=
    LEAST(50, GREATEST(1, COALESCE(p_activity_limit, 30)));
  v_social_limit integer :=
    LEAST(10, GREATEST(1, COALESCE(p_social_limit, 5)));
  v_activity jsonb := '{}'::jsonb;
  v_activity_unread bigint := 0;
  v_message_unread bigint := 0;
  v_friend_incoming bigint := 0;
  v_messages jsonb := '[]'::jsonb;
  v_friend_requests jsonb := '[]'::jsonb;
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

  v_activity :=
    public.nexora_activity_snapshot(
      p_player_id,
      v_activity_limit
    );

  IF COALESCE((v_activity ->> 'success')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVITY_UNAVAILABLE',
      'message', 'Aktivite bilgileri şu anda alınamıyor.'
    );
  END IF;

  v_activity_unread :=
    GREATEST(
      COALESCE((v_activity ->> 'unreadCount')::bigint, 0),
      0
    );

  SELECT COUNT(*)::bigint
  INTO v_message_unread
  FROM public.player_private_messages m
  WHERE m.recipient_player_id = p_player_id
    AND m.read_at IS NULL;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', q.id,
               'senderPlayerId', q.sender_player_id,
               'senderUsername', q.sender_username,
               'message', q.message,
               'createdAt', q.created_at,
               'readAt', q.read_at,
               'unread', q.read_at IS NULL
             )
             ORDER BY q.created_at DESC, q.id DESC
           ),
           '[]'::jsonb
         )
  INTO v_messages
  FROM (
    SELECT
      m.id,
      m.sender_player_id,
      p.username AS sender_username,
      m.message,
      m.created_at,
      m.read_at
    FROM public.player_private_messages m
    JOIN public.players p
      ON p.id = m.sender_player_id
    WHERE m.recipient_player_id = p_player_id
    ORDER BY m.created_at DESC, m.id DESC
    LIMIT v_social_limit
  ) q;

  SELECT COUNT(*)::bigint
  INTO v_friend_incoming
  FROM public.player_friendships f
  WHERE f.status = 'pending'
    AND f.requester_player_id <> p_player_id
    AND (
      f.player_one_id = p_player_id
      OR f.player_two_id = p_player_id
    );

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'playerId', q.player_id,
               'username', q.username,
               'requestedAt', q.requested_at
             )
             ORDER BY q.requested_at DESC, q.player_id DESC
           ),
           '[]'::jsonb
         )
  INTO v_friend_requests
  FROM (
    SELECT
      p.id AS player_id,
      p.username,
      f.created_at AS requested_at
    FROM public.player_friendships f
    JOIN public.players p
      ON p.id = f.requester_player_id
    WHERE f.status = 'pending'
      AND f.requester_player_id <> p_player_id
      AND (
        f.player_one_id = p_player_id
        OR f.player_two_id = p_player_id
      )
    ORDER BY f.created_at DESC, p.id DESC
    LIMIT v_social_limit
  ) q;

  RETURN jsonb_build_object(
    'success', true,
    'serverTime', v_server_time,
    'totalUnread',
      GREATEST(COALESCE(v_activity_unread, 0), 0)
      + GREATEST(COALESCE(v_message_unread, 0), 0)
      + GREATEST(COALESCE(v_friend_incoming, 0), 0),
    'counts', jsonb_build_object(
      'activityUnread',
        GREATEST(COALESCE(v_activity_unread, 0), 0),
      'messageUnread',
        GREATEST(COALESCE(v_message_unread, 0), 0),
      'friendIncoming',
        GREATEST(COALESCE(v_friend_incoming, 0), 0)
    ),
    'activity', v_activity,
    'messages', COALESCE(v_messages, '[]'::jsonb),
    'friendRequests', COALESCE(v_friend_requests, '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.nexora_notifications_snapshot(
  bigint,
  integer,
  integer
)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_notifications_snapshot(
  bigint,
  integer,
  integer
)
TO service_role;

COMMIT;
