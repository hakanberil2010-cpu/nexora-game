-- NEXORA - Friends V1
-- Migration 047
--
-- Scope:
-- - Send friend request by exact username.
-- - List accepted friends, incoming requests and outgoing requests.
-- - Accept / reject incoming requests.
-- - Remove an accepted friend.
-- - Prevent self-friendship and duplicate relationships.
--
-- Browser roles never access the table or functions directly.
-- Backend service_role remains the only Data API caller.

BEGIN;

CREATE TABLE IF NOT EXISTS public.player_friendships (
  player_one_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE CASCADE,
  player_two_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE CASCADE,
  requester_player_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (player_one_id, player_two_id),
  CHECK (player_one_id < player_two_id),
  CHECK (
    requester_player_id = player_one_id
    OR requester_player_id = player_two_id
  )
);

CREATE INDEX IF NOT EXISTS idx_player_friendships_requester_status
  ON public.player_friendships(requester_player_id, status);

CREATE INDEX IF NOT EXISTS idx_player_friendships_player_two_status
  ON public.player_friendships(player_two_id, status);

CREATE OR REPLACE FUNCTION public.nexora_friends_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_friends jsonb := '[]'::jsonb;
  v_incoming jsonb := '[]'::jsonb;
  v_outgoing jsonb := '[]'::jsonb;
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

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'playerId', q.other_player_id,
        'username', q.other_username,
        'friendsSince', q.updated_at
      )
      ORDER BY lower(q.other_username), q.other_username
    ),
    '[]'::jsonb
  )
  INTO v_friends
  FROM (
    SELECT
      CASE
        WHEN f.player_one_id = p_player_id
          THEN f.player_two_id
        ELSE f.player_one_id
      END AS other_player_id,
      p.username AS other_username,
      f.updated_at
    FROM public.player_friendships f
    JOIN public.players p
      ON p.id = CASE
        WHEN f.player_one_id = p_player_id
          THEN f.player_two_id
        ELSE f.player_one_id
      END
    WHERE f.status = 'accepted'
      AND (
        f.player_one_id = p_player_id
        OR f.player_two_id = p_player_id
      )
  ) q;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'playerId', p.id,
        'username', p.username,
        'requestedAt', f.created_at
      )
      ORDER BY f.created_at DESC, f.requester_player_id DESC
    ),
    '[]'::jsonb
  )
  INTO v_incoming
  FROM public.player_friendships f
  JOIN public.players p
    ON p.id = f.requester_player_id
  WHERE f.status = 'pending'
    AND f.requester_player_id <> p_player_id
    AND (
      f.player_one_id = p_player_id
      OR f.player_two_id = p_player_id
    );

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'playerId', p.id,
        'username', p.username,
        'requestedAt', f.created_at
      )
      ORDER BY f.created_at DESC, p.id DESC
    ),
    '[]'::jsonb
  )
  INTO v_outgoing
  FROM public.player_friendships f
  JOIN public.players p
    ON p.id = CASE
      WHEN f.player_one_id = p_player_id
        THEN f.player_two_id
      ELSE f.player_one_id
    END
  WHERE f.status = 'pending'
    AND f.requester_player_id = p_player_id
    AND (
      f.player_one_id = p_player_id
      OR f.player_two_id = p_player_id
    );

  RETURN jsonb_build_object(
    'success', true,
    'serverTime', clock_timestamp(),
    'counts', jsonb_build_object(
      'friends', jsonb_array_length(v_friends),
      'incoming', jsonb_array_length(v_incoming),
      'outgoing', jsonb_array_length(v_outgoing)
    ),
    'friends', v_friends,
    'incoming', v_incoming,
    'outgoing', v_outgoing
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_send_friend_request(
  p_player_id bigint,
  p_target_username text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_target_username text := btrim(COALESCE(p_target_username, ''));
  v_target_player_id bigint;
  v_one bigint;
  v_two bigint;
  v_existing_status text;
  v_existing_requester bigint;
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

  IF v_target_username = '' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_REQUIRED',
      'message', 'Oyuncu adı gerekli.'
    );
  END IF;

  SELECT p.id
  INTO v_target_player_id
  FROM public.players p
  WHERE p.username = v_target_username;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  IF v_target_player_id = p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CANNOT_FRIEND_SELF',
      'message', 'Kendine arkadaşlık isteği gönderemezsin.'
    );
  END IF;

  v_one := LEAST(p_player_id, v_target_player_id);
  v_two := GREATEST(p_player_id, v_target_player_id);

  SELECT f.status, f.requester_player_id
  INTO v_existing_status, v_existing_requester
  FROM public.player_friendships f
  WHERE f.player_one_id = v_one
    AND f.player_two_id = v_two
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_status = 'accepted' THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'ALREADY_FRIENDS',
        'message', 'Bu oyuncu zaten arkadaşın.'
      );
    END IF;

    IF v_existing_requester = p_player_id THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'REQUEST_ALREADY_SENT',
        'message', 'Arkadaşlık isteği zaten gönderilmiş.'
      );
    END IF;

    RETURN jsonb_build_object(
      'success', false,
      'code', 'INCOMING_REQUEST_EXISTS',
      'message', 'Bu oyuncudan zaten bekleyen bir arkadaşlık isteğin var.'
    );
  END IF;

  BEGIN
    INSERT INTO public.player_friendships (
      player_one_id,
      player_two_id,
      requester_player_id,
      status,
      created_at,
      updated_at
    )
    VALUES (
      v_one,
      v_two,
      p_player_id,
      'pending',
      clock_timestamp(),
      clock_timestamp()
    );
  EXCEPTION
    WHEN unique_violation THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'REQUEST_CONFLICT',
        'message', 'Arkadaşlık durumu değişti. Listeyi yenileyip tekrar dene.'
      );
  END;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Arkadaşlık isteği gönderildi.',
    'target', jsonb_build_object(
      'playerId', v_target_player_id,
      'username', v_target_username
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_accept_friend_request(
  p_player_id bigint,
  p_requester_username text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_requester_username text := btrim(COALESCE(p_requester_username, ''));
  v_requester_player_id bigint;
  v_one bigint;
  v_two bigint;
  v_status text;
  v_requester bigint;
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

  SELECT p.id
  INTO v_requester_player_id
  FROM public.players p
  WHERE p.username = v_requester_username;

  IF NOT FOUND OR v_requester_player_id = p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'REQUEST_NOT_FOUND',
      'message', 'Arkadaşlık isteği bulunamadı.'
    );
  END IF;

  v_one := LEAST(p_player_id, v_requester_player_id);
  v_two := GREATEST(p_player_id, v_requester_player_id);

  SELECT f.status, f.requester_player_id
  INTO v_status, v_requester
  FROM public.player_friendships f
  WHERE f.player_one_id = v_one
    AND f.player_two_id = v_two
  FOR UPDATE;

  IF NOT FOUND
     OR v_status <> 'pending'
     OR v_requester <> v_requester_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'REQUEST_NOT_FOUND',
      'message', 'Arkadaşlık isteği bulunamadı.'
    );
  END IF;

  UPDATE public.player_friendships
  SET
    status = 'accepted',
    updated_at = clock_timestamp()
  WHERE player_one_id = v_one
    AND player_two_id = v_two;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Arkadaşlık isteği kabul edildi.',
    'friend', jsonb_build_object(
      'playerId', v_requester_player_id,
      'username', v_requester_username
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_reject_friend_request(
  p_player_id bigint,
  p_requester_username text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_requester_username text := btrim(COALESCE(p_requester_username, ''));
  v_requester_player_id bigint;
  v_one bigint;
  v_two bigint;
  v_status text;
  v_requester bigint;
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

  SELECT p.id
  INTO v_requester_player_id
  FROM public.players p
  WHERE p.username = v_requester_username;

  IF NOT FOUND OR v_requester_player_id = p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'REQUEST_NOT_FOUND',
      'message', 'Arkadaşlık isteği bulunamadı.'
    );
  END IF;

  v_one := LEAST(p_player_id, v_requester_player_id);
  v_two := GREATEST(p_player_id, v_requester_player_id);

  SELECT f.status, f.requester_player_id
  INTO v_status, v_requester
  FROM public.player_friendships f
  WHERE f.player_one_id = v_one
    AND f.player_two_id = v_two
  FOR UPDATE;

  IF NOT FOUND
     OR v_status <> 'pending'
     OR v_requester <> v_requester_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'REQUEST_NOT_FOUND',
      'message', 'Arkadaşlık isteği bulunamadı.'
    );
  END IF;

  DELETE FROM public.player_friendships
  WHERE player_one_id = v_one
    AND player_two_id = v_two;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Arkadaşlık isteği reddedildi.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_remove_friend(
  p_player_id bigint,
  p_friend_username text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_friend_username text := btrim(COALESCE(p_friend_username, ''));
  v_friend_player_id bigint;
  v_one bigint;
  v_two bigint;
  v_status text;
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

  SELECT p.id
  INTO v_friend_player_id
  FROM public.players p
  WHERE p.username = v_friend_username;

  IF NOT FOUND OR v_friend_player_id = p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FRIEND_NOT_FOUND',
      'message', 'Arkadaş bulunamadı.'
    );
  END IF;

  v_one := LEAST(p_player_id, v_friend_player_id);
  v_two := GREATEST(p_player_id, v_friend_player_id);

  SELECT f.status
  INTO v_status
  FROM public.player_friendships f
  WHERE f.player_one_id = v_one
    AND f.player_two_id = v_two
  FOR UPDATE;

  IF NOT FOUND OR v_status <> 'accepted' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FRIEND_NOT_FOUND',
      'message', 'Arkadaş bulunamadı.'
    );
  END IF;

  DELETE FROM public.player_friendships
  WHERE player_one_id = v_one
    AND player_two_id = v_two;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Oyuncu arkadaş listesinden çıkarıldı.'
  );
END;
$function$;

ALTER TABLE public.player_friendships ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.player_friendships
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.player_friendships
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_friends_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_send_friend_request(bigint, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_accept_friend_request(bigint, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_reject_friend_request(bigint, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_remove_friend(bigint, text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_friends_snapshot(bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_send_friend_request(bigint, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_accept_friend_request(bigint, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_reject_friend_request(bigint, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_remove_friend(bigint, text)
  TO service_role;

COMMIT;
