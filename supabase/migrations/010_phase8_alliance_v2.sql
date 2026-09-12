-- NEXORA Phase 8 – Alliance V2
-- Roles, permissions, announcements and activity feed.
-- Apply after 009_phase7_missions_achievements.sql.
-- Additive, production-safe and rerunnable. Existing alliance data is preserved.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) V2 ROLE LAYER
-- Keep the legacy `role` column untouched for compatibility with the existing
-- leader/member flow. `role_v2` adds officer permissions without depending on
-- the legacy role constraint.
-- -----------------------------------------------------------------------------

ALTER TABLE public.alliance_members
  ADD COLUMN IF NOT EXISTS role_v2 text NOT NULL DEFAULT 'member';

UPDATE public.alliance_members
   SET role_v2 = 'leader'
 WHERE role = 'leader'
   AND role_v2 IS DISTINCT FROM 'leader';

UPDATE public.alliance_members
   SET role_v2 = 'member'
 WHERE role IS DISTINCT FROM 'leader'
   AND role_v2 NOT IN ('member', 'officer');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conname = 'alliance_members_role_v2_check'
       AND conrelid = 'public.alliance_members'::regclass
  ) THEN
    ALTER TABLE public.alliance_members
      ADD CONSTRAINT alliance_members_role_v2_check
      CHECK (role_v2 IN ('leader', 'officer', 'member'));
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_alliance_members_alliance_role_v2
  ON public.alliance_members(alliance_id, role_v2);

-- Synchronize the V2 role when the legacy leader role is created/promoted.
CREATE OR REPLACE FUNCTION public.nexora_sync_alliance_role_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.role = 'leader' THEN
    NEW.role_v2 := 'leader';
  ELSIF TG_OP = 'INSERT' THEN
    IF NEW.role_v2 IS NULL OR NEW.role_v2 NOT IN ('member', 'officer') THEN
      NEW.role_v2 := 'member';
    END IF;
  ELSIF OLD.role = 'leader'
        AND NEW.role IS DISTINCT FROM 'leader'
        AND NEW.role_v2 = 'leader' THEN
    NEW.role_v2 := 'member';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_nexora_sync_alliance_role_v2
  ON public.alliance_members;

CREATE TRIGGER trg_nexora_sync_alliance_role_v2
BEFORE INSERT OR UPDATE OF role ON public.alliance_members
FOR EACH ROW
EXECUTE FUNCTION public.nexora_sync_alliance_role_v2();

-- -----------------------------------------------------------------------------
-- 2) ANNOUNCEMENTS + ACTIVITY
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.alliance_announcements (
  id bigserial PRIMARY KEY,
  alliance_id bigint NOT NULL REFERENCES public.alliances(id) ON DELETE CASCADE,
  author_player_id bigint NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  message text NOT NULL CHECK (char_length(btrim(message)) BETWEEN 1 AND 500),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_alliance_announcements_feed
  ON public.alliance_announcements(alliance_id, created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS public.alliance_activity (
  id bigserial PRIMARY KEY,
  alliance_id bigint NOT NULL REFERENCES public.alliances(id) ON DELETE CASCADE,
  event_type text NOT NULL,
  actor_player_id bigint REFERENCES public.players(id) ON DELETE SET NULL,
  target_player_id bigint REFERENCES public.players(id) ON DELETE SET NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_alliance_activity_feed
  ON public.alliance_activity(alliance_id, created_at DESC, id DESC);

-- Existing create/join API inserts directly into alliance_members. Log those
-- events automatically without changing the current API contract.
CREATE OR REPLACE FUNCTION public.nexora_log_alliance_member_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_owner bigint;
  v_event text;
BEGIN
  SELECT owner_player_id
    INTO v_owner
    FROM public.alliances
   WHERE id = NEW.alliance_id
   LIMIT 1;

  IF NEW.role = 'leader' AND v_owner IS NOT DISTINCT FROM NEW.player_id THEN
    v_event := 'alliance_created';
  ELSE
    v_event := 'member_joined';
  END IF;

  INSERT INTO public.alliance_activity(
    alliance_id,
    event_type,
    actor_player_id,
    target_player_id,
    metadata
  )
  VALUES(
    NEW.alliance_id,
    v_event,
    NEW.player_id,
    NEW.player_id,
    jsonb_build_object('role', COALESCE(NEW.role_v2, NEW.role, 'member'))
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_nexora_log_alliance_member_insert
  ON public.alliance_members;

CREATE TRIGGER trg_nexora_log_alliance_member_insert
AFTER INSERT ON public.alliance_members
FOR EACH ROW
EXECUTE FUNCTION public.nexora_log_alliance_member_insert();

-- -----------------------------------------------------------------------------
-- 3) ROLE MANAGEMENT
-- Only the alliance owner/leader can promote or demote officers.
-- Leadership itself is still managed by the existing leave/transfer flow.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_alliance_set_member_role(
  p_actor_player_id bigint,
  p_target_player_id bigint,
  p_role text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor public.alliance_members%ROWTYPE;
  v_target public.alliance_members%ROWTYPE;
  v_alliance public.alliances%ROWTYPE;
  v_role text;
  v_old_role text;
BEGIN
  v_role := lower(btrim(COALESCE(p_role, '')));

  IF p_actor_player_id IS NULL OR p_target_player_id IS NULL
     OR p_actor_player_id <= 0 OR p_target_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  IF v_role NOT IN ('officer', 'member') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ROLE',
      'message', 'Rol yalnızca subay veya üye olabilir.'
    );
  END IF;

  IF p_actor_player_id = p_target_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SELF_ROLE_CHANGE',
      'message', 'Kendi lider rolünü bu işlemle değiştiremezsin.'
    );
  END IF;

  SELECT *
    INTO v_actor
    FROM public.alliance_members
   WHERE player_id = p_actor_player_id
   ORDER BY id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_LEADER',
      'message', 'Bu işlem için ittifak lideri olmalısın.'
    );
  END IF;

  SELECT *
    INTO v_alliance
    FROM public.alliances
   WHERE id = v_actor.alliance_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ALLIANCE_NOT_FOUND',
      'message', 'İttifak bulunamadı.'
    );
  END IF;

  SELECT *
    INTO v_actor
    FROM public.alliance_members
   WHERE player_id = p_actor_player_id
     AND alliance_id = v_alliance.id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND
     OR v_actor.role IS DISTINCT FROM 'leader'
     OR v_actor.role_v2 IS DISTINCT FROM 'leader'
     OR v_alliance.owner_player_id IS DISTINCT FROM p_actor_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_LEADER',
      'message', 'Bu işlem için ittifak lideri olmalısın.'
    );
  END IF;

  SELECT *
    INTO v_target
    FROM public.alliance_members
   WHERE player_id = p_target_player_id
     AND alliance_id = v_alliance.id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_NOT_MEMBER',
      'message', 'Oyuncu bu ittifakta değil.'
    );
  END IF;

  IF v_target.role = 'leader' OR v_target.role_v2 = 'leader' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_LEADER',
      'message', 'İttifak liderinin rolü bu işlemle değiştirilemez.'
    );
  END IF;

  v_old_role := COALESCE(v_target.role_v2, 'member');

  IF v_old_role = v_role THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadySet', true,
      'playerId', p_target_player_id,
      'role', v_role,
      'message', 'Oyuncu zaten bu rolde.'
    );
  END IF;

  UPDATE public.alliance_members
     SET role_v2 = v_role
   WHERE id = v_target.id;

  INSERT INTO public.alliance_activity(
    alliance_id,
    event_type,
    actor_player_id,
    target_player_id,
    metadata
  )
  VALUES(
    v_alliance.id,
    'role_changed',
    p_actor_player_id,
    p_target_player_id,
    jsonb_build_object('oldRole', v_old_role, 'newRole', v_role)
  );

  RETURN jsonb_build_object(
    'success', true,
    'alreadySet', false,
    'playerId', p_target_player_id,
    'role', v_role,
    'message',
      CASE v_role
        WHEN 'officer' THEN 'Oyuncu subay yapıldı.'
        ELSE 'Oyuncu üye rolüne alındı.'
      END
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 4) ANNOUNCEMENT MANAGEMENT
-- Leader and officers can publish. Leader can delete any announcement; officers
-- can delete only their own announcements.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_alliance_post_announcement(
  p_actor_player_id bigint,
  p_message text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_member public.alliance_members%ROWTYPE;
  v_alliance public.alliances%ROWTYPE;
  v_message text;
  v_announcement public.alliance_announcements%ROWTYPE;
  v_role text;
BEGIN
  v_message := btrim(COALESCE(p_message, ''));

  IF char_length(v_message) < 1 OR char_length(v_message) > 500 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_MESSAGE',
      'message', 'Duyuru 1-500 karakter arasında olmalı.'
    );
  END IF;

  SELECT *
    INTO v_member
    FROM public.alliance_members
   WHERE player_id = p_actor_player_id
   ORDER BY id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_MEMBER',
      'message', 'Bir ittifaka üye değilsin.'
    );
  END IF;

  SELECT *
    INTO v_alliance
    FROM public.alliances
   WHERE id = v_member.alliance_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ALLIANCE_NOT_FOUND',
      'message', 'İttifak bulunamadı.'
    );
  END IF;

  SELECT *
    INTO v_member
    FROM public.alliance_members
   WHERE player_id = p_actor_player_id
     AND alliance_id = v_alliance.id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_MEMBER',
      'message', 'Bir ittifaka üye değilsin.'
    );
  END IF;

  v_role := CASE
    WHEN v_member.role = 'leader'
         AND v_alliance.owner_player_id = p_actor_player_id
      THEN 'leader'
    ELSE COALESCE(v_member.role_v2, 'member')
  END;

  IF v_role NOT IN ('leader', 'officer') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NO_PERMISSION',
      'message', 'Duyuru yayınlamak için lider veya subay olmalısın.'
    );
  END IF;

  INSERT INTO public.alliance_announcements(
    alliance_id,
    author_player_id,
    message
  )
  VALUES(
    v_alliance.id,
    p_actor_player_id,
    v_message
  )
  RETURNING * INTO v_announcement;

  INSERT INTO public.alliance_activity(
    alliance_id,
    event_type,
    actor_player_id,
    metadata
  )
  VALUES(
    v_alliance.id,
    'announcement_posted',
    p_actor_player_id,
    jsonb_build_object('announcementId', v_announcement.id)
  );

  RETURN jsonb_build_object(
    'success', true,
    'message', 'İttifak duyurusu yayınlandı.',
    'announcement', jsonb_build_object(
      'id', v_announcement.id,
      'allianceId', v_announcement.alliance_id,
      'authorPlayerId', v_announcement.author_player_id,
      'message', v_announcement.message,
      'createdAt', v_announcement.created_at
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_alliance_delete_announcement(
  p_actor_player_id bigint,
  p_announcement_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_member public.alliance_members%ROWTYPE;
  v_alliance public.alliances%ROWTYPE;
  v_announcement public.alliance_announcements%ROWTYPE;
  v_role text;
BEGIN
  IF p_announcement_id IS NULL OR p_announcement_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ANNOUNCEMENT',
      'message', 'Geçersiz duyuru.'
    );
  END IF;

  SELECT *
    INTO v_member
    FROM public.alliance_members
   WHERE player_id = p_actor_player_id
   ORDER BY id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_MEMBER',
      'message', 'Bir ittifaka üye değilsin.'
    );
  END IF;

  SELECT *
    INTO v_alliance
    FROM public.alliances
   WHERE id = v_member.alliance_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ALLIANCE_NOT_FOUND',
      'message', 'İttifak bulunamadı.'
    );
  END IF;

  SELECT *
    INTO v_member
    FROM public.alliance_members
   WHERE player_id = p_actor_player_id
     AND alliance_id = v_alliance.id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_MEMBER',
      'message', 'Bir ittifaka üye değilsin.'
    );
  END IF;

  SELECT *
    INTO v_announcement
    FROM public.alliance_announcements
   WHERE id = p_announcement_id
     AND alliance_id = v_alliance.id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ANNOUNCEMENT_NOT_FOUND',
      'message', 'Duyuru bulunamadı.'
    );
  END IF;

  v_role := CASE
    WHEN v_member.role = 'leader'
         AND v_alliance.owner_player_id = p_actor_player_id
      THEN 'leader'
    ELSE COALESCE(v_member.role_v2, 'member')
  END;

  IF v_role = 'leader' THEN
    NULL;
  ELSIF v_role = 'officer'
        AND v_announcement.author_player_id = p_actor_player_id THEN
    NULL;
  ELSE
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NO_PERMISSION',
      'message', 'Bu duyuruyu silemezsin.'
    );
  END IF;

  DELETE FROM public.alliance_announcements
   WHERE id = v_announcement.id;

  INSERT INTO public.alliance_activity(
    alliance_id,
    event_type,
    actor_player_id,
    metadata
  )
  VALUES(
    v_alliance.id,
    'announcement_deleted',
    p_actor_player_id,
    jsonb_build_object('announcementId', v_announcement.id)
  );

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Duyuru silindi.',
    'announcementId', v_announcement.id
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 5) LEAVE FLOW – keep Phase 5 behavior and add V2 role sync/activity.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_leave_alliance(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_member public.alliance_members%ROWTYPE;
  v_alliance public.alliances%ROWTYPE;
  v_next public.alliance_members%ROWTYPE;
BEGIN
  SELECT *
    INTO v_member
    FROM public.alliance_members
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_MEMBER',
      'message', 'Bir ittifaka üye değilsin.'
    );
  END IF;

  SELECT *
    INTO v_alliance
    FROM public.alliances
   WHERE id = v_member.alliance_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ALLIANCE_NOT_FOUND',
      'message', 'İttifak bulunamadı.'
    );
  END IF;

  SELECT *
    INTO v_member
    FROM public.alliance_members
   WHERE player_id = p_player_id
     AND alliance_id = v_alliance.id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_MEMBER',
      'message', 'Bir ittifaka üye değilsin.'
    );
  END IF;

  IF (v_member.role IS NOT DISTINCT FROM 'leader')
       IS DISTINCT FROM
     (v_alliance.owner_player_id IS NOT DISTINCT FROM p_player_id) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'OWNER_MISMATCH',
      'message', 'İttifak liderlik kaydı tutarsız.'
    );
  END IF;

  IF v_member.role IS DISTINCT FROM 'leader' THEN
    INSERT INTO public.alliance_activity(
      alliance_id,
      event_type,
      actor_player_id,
      target_player_id,
      metadata
    )
    VALUES(
      v_alliance.id,
      'member_left',
      p_player_id,
      p_player_id,
      jsonb_build_object('role', COALESCE(v_member.role_v2, 'member'))
    );

    DELETE FROM public.alliance_members
     WHERE id = v_member.id;

    RETURN jsonb_build_object(
      'success', true,
      'action', 'left',
      'message', 'İttifaktan ayrıldın.'
    );
  END IF;

  SELECT *
    INTO v_next
    FROM public.alliance_members
   WHERE alliance_id = v_member.alliance_id
     AND player_id <> p_player_id
   ORDER BY
     CASE COALESCE(role_v2, 'member')
       WHEN 'officer' THEN 0
       ELSE 1
     END,
     id ASC
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    DELETE FROM public.alliance_members
     WHERE id = v_member.id;

    DELETE FROM public.alliances
     WHERE id = v_member.alliance_id;

    RETURN jsonb_build_object(
      'success', true,
      'action', 'deleted',
      'message', 'Son üye olarak ayrıldığın için ittifak kapatıldı.'
    );
  END IF;

  UPDATE public.alliance_members
     SET role = 'leader',
         role_v2 = 'leader'
   WHERE id = v_next.id;

  UPDATE public.alliances
     SET owner_player_id = v_next.player_id
   WHERE id = v_member.alliance_id;

  INSERT INTO public.alliance_activity(
    alliance_id,
    event_type,
    actor_player_id,
    target_player_id,
    metadata
  )
  VALUES(
    v_alliance.id,
    'leadership_transferred',
    p_player_id,
    v_next.player_id,
    jsonb_build_object('reason', 'leader_left')
  );

  DELETE FROM public.alliance_members
   WHERE id = v_member.id;

  RETURN jsonb_build_object(
    'success', true,
    'action', 'transferred',
    'newLeaderPlayerId', v_next.player_id,
    'message', 'İttifaktan ayrıldın. Liderlik başka bir üyeye devredildi.'
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 6) KICK FLOW – leader can kick officer/member; officer can kick only members.
-- Existing RPC signature stays unchanged for backend compatibility.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_kick_alliance_member(
  p_leader_player_id bigint,
  p_target_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor public.alliance_members%ROWTYPE;
  v_target public.alliance_members%ROWTYPE;
  v_alliance public.alliances%ROWTYPE;
  v_actor_role text;
  v_target_role text;
BEGIN
  IF p_leader_player_id = p_target_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SELF_KICK',
      'message', 'Kendini ittifaktan çıkaramazsın. Ayrıl işlemini kullan.'
    );
  END IF;

  SELECT *
    INTO v_actor
    FROM public.alliance_members
   WHERE player_id = p_leader_player_id
   ORDER BY id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NO_PERMISSION',
      'message', 'Bu işlem için yetkin yok.'
    );
  END IF;

  SELECT *
    INTO v_alliance
    FROM public.alliances
   WHERE id = v_actor.alliance_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ALLIANCE_NOT_FOUND',
      'message', 'İttifak bulunamadı.'
    );
  END IF;

  SELECT *
    INTO v_actor
    FROM public.alliance_members
   WHERE player_id = p_leader_player_id
     AND alliance_id = v_alliance.id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NO_PERMISSION',
      'message', 'Bu işlem için yetkin yok.'
    );
  END IF;

  v_actor_role := CASE
    WHEN v_actor.role = 'leader'
         AND v_alliance.owner_player_id = p_leader_player_id
      THEN 'leader'
    ELSE COALESCE(v_actor.role_v2, 'member')
  END;

  IF v_actor_role NOT IN ('leader', 'officer') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NO_PERMISSION',
      'message', 'Üye çıkarmak için lider veya subay olmalısın.'
    );
  END IF;

  SELECT *
    INTO v_target
    FROM public.alliance_members
   WHERE player_id = p_target_player_id
     AND alliance_id = v_alliance.id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_NOT_MEMBER',
      'message', 'Oyuncu bu ittifakta değil.'
    );
  END IF;

  v_target_role := CASE
    WHEN v_target.role = 'leader'
         AND v_alliance.owner_player_id = p_target_player_id
      THEN 'leader'
    ELSE COALESCE(v_target.role_v2, 'member')
  END;

  IF v_target_role = 'leader' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_LEADER',
      'message', 'İttifak lideri bu işlemle çıkarılamaz.'
    );
  END IF;

  IF v_actor_role = 'officer' AND v_target_role <> 'member' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NO_PERMISSION',
      'message', 'Subay yalnızca normal üyeleri çıkarabilir.'
    );
  END IF;

  INSERT INTO public.alliance_activity(
    alliance_id,
    event_type,
    actor_player_id,
    target_player_id,
    metadata
  )
  VALUES(
    v_alliance.id,
    'member_kicked',
    p_leader_player_id,
    p_target_player_id,
    jsonb_build_object('targetRole', v_target_role)
  );

  DELETE FROM public.alliance_members
   WHERE id = v_target.id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Oyuncu ittifaktan çıkarıldı.',
    'playerId', p_target_player_id
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 7) SECURITY
-- -----------------------------------------------------------------------------

ALTER TABLE public.alliance_announcements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.alliance_activity ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.alliance_announcements
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.alliance_activity
  FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.alliance_announcements TO service_role;
GRANT ALL ON TABLE public.alliance_activity TO service_role;

GRANT USAGE, SELECT ON SEQUENCE public.alliance_announcements_id_seq TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.alliance_activity_id_seq TO service_role;

REVOKE ALL ON FUNCTION public.nexora_sync_alliance_role_v2()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_log_alliance_member_insert()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_alliance_set_member_role(bigint,bigint,text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_alliance_post_announcement(bigint,text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_alliance_delete_announcement(bigint,bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_leave_alliance(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_kick_alliance_member(bigint,bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_sync_alliance_role_v2()
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_log_alliance_member_insert()
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_alliance_set_member_role(bigint,bigint,text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_alliance_post_announcement(bigint,text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_alliance_delete_announcement(bigint,bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_leave_alliance(bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_kick_alliance_member(bigint,bigint)
  TO service_role;

COMMIT;
