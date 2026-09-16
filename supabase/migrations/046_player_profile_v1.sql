-- NEXORA - Player Profile V1
-- Migration 046
--
-- Goals:
-- - Add one editable public bio per player.
-- - Keep profile storage hidden from browser roles.
-- - Expose profile metadata only through service_role RPCs.
-- - Use server time for profile updates.
--
-- Public combat/colony/research statistics stay derived from existing
-- authoritative game tables in the backend API; they are not duplicated here.
--
-- Apply after 045_private_messages_v1.sql.

BEGIN;

CREATE TABLE IF NOT EXISTS public.player_profiles (
  player_id bigint PRIMARY KEY
    REFERENCES public.players(id) ON DELETE CASCADE,
  bio text NOT NULL DEFAULT ''
    CHECK (char_length(bio) <= 300),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE OR REPLACE FUNCTION public.nexora_player_profile_meta(
  p_requester_player_id bigint,
  p_target_username text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_target_username text := btrim(COALESCE(p_target_username, ''));
  v_target public.players%ROWTYPE;
  v_bio text := '';
  v_profile_updated_at timestamptz;
  v_alliance_id bigint;
  v_alliance_name text;
  v_alliance_tag text;
  v_alliance_role text;
  v_achievement_count bigint := 0;
BEGIN
  IF p_requester_player_id IS NULL
     OR p_requester_player_id <= 0
     OR NOT EXISTS (
       SELECT 1
       FROM public.players p
       WHERE p.id = p_requester_player_id
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
      'message', 'Profil oyuncu adı gerekli.'
    );
  END IF;

  SELECT *
    INTO v_target
  FROM public.players p
  WHERE p.username = v_target_username;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_NOT_FOUND',
      'message', 'Profil bulunamadı.'
    );
  END IF;

  SELECT pp.bio, pp.updated_at
    INTO v_bio, v_profile_updated_at
  FROM public.player_profiles pp
  WHERE pp.player_id = v_target.id;

  v_bio := COALESCE(v_bio, '');

  SELECT
    am.alliance_id,
    a.name,
    a.tag,
    COALESCE(NULLIF(am.role_v2, ''), am.role)
    INTO
      v_alliance_id,
      v_alliance_name,
      v_alliance_tag,
      v_alliance_role
  FROM public.alliance_members am
  JOIN public.alliances a
    ON a.id = am.alliance_id
  WHERE am.player_id = v_target.id
  ORDER BY am.joined_at DESC NULLS LAST, am.id DESC
  LIMIT 1;

  SELECT COUNT(*)::bigint
    INTO v_achievement_count
  FROM public.player_achievements pa
  WHERE pa.player_id = v_target.id;

  RETURN jsonb_build_object(
    'success', true,
    'serverTime', clock_timestamp(),
    'profile', jsonb_build_object(
      'playerId', v_target.id,
      'username', v_target.username,
      'createdAt', v_target.created_at,
      'bio', v_bio,
      'profileUpdatedAt', v_profile_updated_at,
      'isSelf', v_target.id = p_requester_player_id,
      'achievementCount', GREATEST(COALESCE(v_achievement_count, 0), 0),
      'alliance',
        CASE
          WHEN v_alliance_id IS NULL THEN NULL
          ELSE jsonb_build_object(
            'id', v_alliance_id,
            'name', v_alliance_name,
            'tag', v_alliance_tag,
            'role', v_alliance_role
          )
        END
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_update_player_profile(
  p_player_id bigint,
  p_bio text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_player public.players%ROWTYPE;
  v_bio text := btrim(COALESCE(p_bio, ''));
  v_updated_at timestamptz;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  SELECT *
    INTO v_player
  FROM public.players p
  WHERE p.id = p_player_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  IF char_length(v_bio) > 300 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'BIO_TOO_LONG',
      'message', 'Profil açıklaması en fazla 300 karakter olabilir.'
    );
  END IF;

  v_updated_at := clock_timestamp();

  INSERT INTO public.player_profiles (
    player_id,
    bio,
    updated_at
  )
  VALUES (
    v_player.id,
    v_bio,
    v_updated_at
  )
  ON CONFLICT (player_id)
  DO UPDATE SET
    bio = EXCLUDED.bio,
    updated_at = EXCLUDED.updated_at;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Profil güncellendi.',
    'profile', jsonb_build_object(
      'playerId', v_player.id,
      'username', v_player.username,
      'bio', v_bio,
      'profileUpdatedAt', v_updated_at
    )
  );
END;
$function$;

ALTER TABLE public.player_profiles ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.player_profiles
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.player_profiles
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_player_profile_meta(bigint, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_update_player_profile(bigint, text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_player_profile_meta(bigint, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_update_player_profile(bigint, text)
  TO service_role;

COMMIT;
