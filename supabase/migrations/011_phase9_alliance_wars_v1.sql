-- NEXORA Phase 9 – Alliance Wars V1
-- Alliance challenges, acceptance/rejection, 72-hour wars and battle-based scoring.
-- Apply after 010_phase8_alliance_v2.sql.
-- Additive, production-safe and rerunnable. Existing battle/alliance data is preserved.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) ALLIANCE WAR TABLES
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.alliance_wars (
  id bigserial PRIMARY KEY,
  challenger_alliance_id bigint NOT NULL REFERENCES public.alliances(id) ON DELETE CASCADE,
  target_alliance_id bigint NOT NULL REFERENCES public.alliances(id) ON DELETE CASCADE,
  declared_by_player_id bigint NOT NULL REFERENCES public.players(id) ON DELETE RESTRICT,
  responded_by_player_id bigint REFERENCES public.players(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending',
  challenger_score bigint NOT NULL DEFAULT 0,
  target_score bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  started_at timestamptz,
  ends_at timestamptz,
  finished_at timestamptz,
  winner_alliance_id bigint REFERENCES public.alliances(id) ON DELETE SET NULL,
  result jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT alliance_wars_distinct_alliances
    CHECK (challenger_alliance_id <> target_alliance_id),
  CONSTRAINT alliance_wars_status_check
    CHECK (status IN ('pending','active','finished','rejected','cancelled')),
  CONSTRAINT alliance_wars_score_check
    CHECK (challenger_score >= 0 AND target_score >= 0)
);

CREATE INDEX IF NOT EXISTS idx_alliance_wars_challenger_status
  ON public.alliance_wars(challenger_alliance_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_alliance_wars_target_status
  ON public.alliance_wars(target_alliance_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_alliance_wars_active_end
  ON public.alliance_wars(status, ends_at)
  WHERE status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS idx_alliance_wars_pending_pair
  ON public.alliance_wars(
    LEAST(challenger_alliance_id, target_alliance_id),
    GREATEST(challenger_alliance_id, target_alliance_id)
  )
  WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS public.alliance_war_battles (
  id bigserial PRIMARY KEY,
  war_id bigint NOT NULL REFERENCES public.alliance_wars(id) ON DELETE CASCADE,
  battle_report_id bigint NOT NULL REFERENCES public.battle_reports(id) ON DELETE CASCADE,
  attacker_alliance_id bigint NOT NULL REFERENCES public.alliances(id) ON DELETE CASCADE,
  defender_alliance_id bigint NOT NULL REFERENCES public.alliances(id) ON DELETE CASCADE,
  winner_alliance_id bigint REFERENCES public.alliances(id) ON DELETE SET NULL,
  points bigint NOT NULL DEFAULT 0 CHECK (points >= 0),
  battle_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (battle_report_id)
);

CREATE INDEX IF NOT EXISTS idx_alliance_war_battles_war
  ON public.alliance_war_battles(war_id, battle_at DESC, id DESC);

-- -----------------------------------------------------------------------------
-- 2) WAR FINALIZATION
-- Idempotently closes an expired active war using server time.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_alliance_war_finalize(
  p_war_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_war public.alliance_wars%ROWTYPE;
  v_winner bigint;
  v_result jsonb;
BEGIN
  IF p_war_id IS NULL OR p_war_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_WAR',
      'message', 'Geçersiz ittifak savaşı.'
    );
  END IF;

  SELECT *
    INTO v_war
    FROM public.alliance_wars
   WHERE id = p_war_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WAR_NOT_FOUND',
      'message', 'İttifak savaşı bulunamadı.'
    );
  END IF;

  IF v_war.status <> 'active' THEN
    RETURN jsonb_build_object(
      'success', true,
      'warId', v_war.id,
      'status', v_war.status,
      'winnerAllianceId', v_war.winner_alliance_id,
      'challengerScore', v_war.challenger_score,
      'targetScore', v_war.target_score
    );
  END IF;

  IF v_war.ends_at IS NULL OR v_war.ends_at > now() THEN
    RETURN jsonb_build_object(
      'success', true,
      'warId', v_war.id,
      'status', 'active',
      'remainingSeconds',
        GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_war.ends_at - now())))::integer),
      'challengerScore', v_war.challenger_score,
      'targetScore', v_war.target_score
    );
  END IF;

  v_winner := CASE
    WHEN v_war.challenger_score > v_war.target_score
      THEN v_war.challenger_alliance_id
    WHEN v_war.target_score > v_war.challenger_score
      THEN v_war.target_alliance_id
    ELSE NULL
  END;

  v_result := jsonb_build_object(
    'challengerScore', v_war.challenger_score,
    'targetScore', v_war.target_score,
    'winnerAllianceId', v_winner,
    'draw', v_winner IS NULL
  );

  UPDATE public.alliance_wars
     SET status = 'finished',
         finished_at = now(),
         winner_alliance_id = v_winner,
         result = v_result
   WHERE id = v_war.id;

  INSERT INTO public.alliance_activity(
    alliance_id,
    event_type,
    actor_player_id,
    target_player_id,
    metadata
  )
  VALUES
  (
    v_war.challenger_alliance_id,
    'war_finished',
    NULL,
    NULL,
    jsonb_build_object(
      'warId', v_war.id,
      'opponentAllianceId', v_war.target_alliance_id,
      'ownScore', v_war.challenger_score,
      'opponentScore', v_war.target_score,
      'winnerAllianceId', v_winner
    )
  ),
  (
    v_war.target_alliance_id,
    'war_finished',
    NULL,
    NULL,
    jsonb_build_object(
      'warId', v_war.id,
      'opponentAllianceId', v_war.challenger_alliance_id,
      'ownScore', v_war.target_score,
      'opponentScore', v_war.challenger_score,
      'winnerAllianceId', v_winner
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'warId', v_war.id,
    'status', 'finished',
    'winnerAllianceId', v_winner,
    'challengerScore', v_war.challenger_score,
    'targetScore', v_war.target_score,
    'result', v_result
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 3) DECLARE WAR
-- Leader/officer can send a challenge. A war starts only after the target
-- alliance accepts it.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_alliance_war_declare(
  p_actor_player_id bigint,
  p_target_alliance_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor public.alliance_members%ROWTYPE;
  v_actor_alliance public.alliances%ROWTYPE;
  v_target_alliance public.alliances%ROWTYPE;
  v_actor_role text;
  v_existing public.alliance_wars%ROWTYPE;
  v_active record;
  v_war public.alliance_wars%ROWTYPE;
BEGIN
  IF p_actor_player_id IS NULL OR p_actor_player_id <= 0
     OR p_target_alliance_id IS NULL OR p_target_alliance_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz savaş hedefi.'
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
      'code', 'NOT_MEMBER',
      'message', 'Bir ittifaka üye değilsin.'
    );
  END IF;

  IF v_actor.alliance_id = p_target_alliance_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SELF_ALLIANCE',
      'message', 'Kendi ittifakına savaş ilan edemezsin.'
    );
  END IF;

  -- Lock both alliance rows in stable ID order so concurrent war operations
  -- touching the same alliances serialize consistently.
  PERFORM id
    FROM public.alliances
   WHERE id IN (v_actor.alliance_id, p_target_alliance_id)
   ORDER BY id
   FOR UPDATE;

  SELECT *
    INTO v_actor_alliance
    FROM public.alliances
   WHERE id = v_actor.alliance_id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ALLIANCE_NOT_FOUND',
      'message', 'İttifak bulunamadı.'
    );
  END IF;

  SELECT *
    INTO v_target_alliance
    FROM public.alliances
   WHERE id = p_target_alliance_id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_NOT_FOUND',
      'message', 'Hedef ittifak bulunamadı.'
    );
  END IF;

  SELECT *
    INTO v_actor
    FROM public.alliance_members
   WHERE player_id = p_actor_player_id
     AND alliance_id = v_actor_alliance.id
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

  v_actor_role := CASE
    WHEN v_actor.role = 'leader'
         AND v_actor_alliance.owner_player_id = p_actor_player_id
      THEN 'leader'
    ELSE COALESCE(v_actor.role_v2, 'member')
  END;

  IF v_actor_role NOT IN ('leader', 'officer') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NO_PERMISSION',
      'message', 'Savaş ilan etmek için lider veya subay olmalısın.'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.alliance_members
     WHERE alliance_id = v_target_alliance.id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_EMPTY',
      'message', 'Hedef ittifakta savaşabilecek üye yok.'
    );
  END IF;

  -- Close any expired wars before checking the active-war limit.
  FOR v_active IN
    SELECT id
      FROM public.alliance_wars
     WHERE status = 'active'
       AND ends_at <= now()
       AND (
         challenger_alliance_id IN (v_actor_alliance.id, v_target_alliance.id)
         OR target_alliance_id IN (v_actor_alliance.id, v_target_alliance.id)
       )
  LOOP
    PERFORM public.nexora_alliance_war_finalize(v_active.id);
  END LOOP;

  IF EXISTS (
    SELECT 1
      FROM public.alliance_wars
     WHERE status = 'active'
       AND (
         challenger_alliance_id IN (v_actor_alliance.id, v_target_alliance.id)
         OR target_alliance_id IN (v_actor_alliance.id, v_target_alliance.id)
       )
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVE_WAR',
      'message', 'İttifaklardan biri zaten aktif bir savaşta.'
    );
  END IF;

  SELECT *
    INTO v_existing
    FROM public.alliance_wars
   WHERE status = 'pending'
     AND LEAST(challenger_alliance_id, target_alliance_id)
         = LEAST(v_actor_alliance.id, v_target_alliance.id)
     AND GREATEST(challenger_alliance_id, target_alliance_id)
         = GREATEST(v_actor_alliance.id, v_target_alliance.id)
   ORDER BY id DESC
   LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyPending', true,
      'warId', v_existing.id,
      'status', v_existing.status,
      'message', 'Bu iki ittifak arasında zaten bekleyen bir savaş çağrısı var.'
    );
  END IF;

  INSERT INTO public.alliance_wars(
    challenger_alliance_id,
    target_alliance_id,
    declared_by_player_id,
    status
  )
  VALUES(
    v_actor_alliance.id,
    v_target_alliance.id,
    p_actor_player_id,
    'pending'
  )
  RETURNING * INTO v_war;

  INSERT INTO public.alliance_activity(
    alliance_id,
    event_type,
    actor_player_id,
    target_player_id,
    metadata
  )
  VALUES
  (
    v_actor_alliance.id,
    'war_challenge_sent',
    p_actor_player_id,
    NULL,
    jsonb_build_object(
      'warId', v_war.id,
      'targetAllianceId', v_target_alliance.id,
      'targetAllianceName', v_target_alliance.name,
      'targetAllianceTag', v_target_alliance.tag
    )
  ),
  (
    v_target_alliance.id,
    'war_challenge_received',
    p_actor_player_id,
    NULL,
    jsonb_build_object(
      'warId', v_war.id,
      'challengerAllianceId', v_actor_alliance.id,
      'challengerAllianceName', v_actor_alliance.name,
      'challengerAllianceTag', v_actor_alliance.tag
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'alreadyPending', false,
    'warId', v_war.id,
    'status', 'pending',
    'message', 'Savaş çağrısı gönderildi.'
  );
EXCEPTION
  WHEN unique_violation THEN
    SELECT *
      INTO v_existing
      FROM public.alliance_wars
     WHERE status = 'pending'
       AND LEAST(challenger_alliance_id, target_alliance_id)
           = LEAST(v_actor.alliance_id, p_target_alliance_id)
       AND GREATEST(challenger_alliance_id, target_alliance_id)
           = GREATEST(v_actor.alliance_id, p_target_alliance_id)
     ORDER BY id DESC
     LIMIT 1;

    RETURN jsonb_build_object(
      'success', true,
      'alreadyPending', true,
      'warId', v_existing.id,
      'status', 'pending',
      'message', 'Bu iki ittifak arasında zaten bekleyen bir savaş çağrısı var.'
    );
END;
$$;

-- -----------------------------------------------------------------------------
-- 4) ACCEPT / REJECT WAR
-- Target alliance leader/officer responds. Accepted wars last exactly 72 hours
-- using database server time.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_alliance_war_respond(
  p_actor_player_id bigint,
  p_war_id bigint,
  p_accept boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor public.alliance_members%ROWTYPE;
  v_actor_alliance public.alliances%ROWTYPE;
  v_war public.alliance_wars%ROWTYPE;
  v_actor_role text;
  v_active record;
  v_now timestamptz;
  v_end timestamptz;
BEGIN
  IF p_actor_player_id IS NULL OR p_actor_player_id <= 0
     OR p_war_id IS NULL OR p_war_id <= 0
     OR p_accept IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz savaş yanıtı.'
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
      'code', 'NOT_MEMBER',
      'message', 'Bir ittifaka üye değilsin.'
    );
  END IF;

  SELECT *
    INTO v_war
    FROM public.alliance_wars
   WHERE id = p_war_id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WAR_NOT_FOUND',
      'message', 'Savaş çağrısı bulunamadı.'
    );
  END IF;

  -- Lock both alliances in stable order before changing the war state.
  PERFORM id
    FROM public.alliances
   WHERE id IN (v_war.challenger_alliance_id, v_war.target_alliance_id)
   ORDER BY id
   FOR UPDATE;

  SELECT *
    INTO v_war
    FROM public.alliance_wars
   WHERE id = p_war_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WAR_NOT_FOUND',
      'message', 'Savaş çağrısı bulunamadı.'
    );
  END IF;

  IF v_war.target_alliance_id <> v_actor.alliance_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_TARGET_ALLIANCE',
      'message', 'Bu savaş çağrısına yalnızca hedef ittifak yanıt verebilir.'
    );
  END IF;

  IF v_war.status <> 'pending' THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyResponded', true,
      'warId', v_war.id,
      'status', v_war.status,
      'message', 'Bu savaş çağrısı daha önce yanıtlandı.'
    );
  END IF;

  SELECT *
    INTO v_actor_alliance
    FROM public.alliances
   WHERE id = v_actor.alliance_id
   LIMIT 1;

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
     AND alliance_id = v_actor_alliance.id
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

  v_actor_role := CASE
    WHEN v_actor.role = 'leader'
         AND v_actor_alliance.owner_player_id = p_actor_player_id
      THEN 'leader'
    ELSE COALESCE(v_actor.role_v2, 'member')
  END;

  IF v_actor_role NOT IN ('leader', 'officer') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NO_PERMISSION',
      'message', 'Savaş çağrısını yanıtlamak için lider veya subay olmalısın.'
    );
  END IF;

  IF p_accept IS FALSE THEN
    UPDATE public.alliance_wars
       SET status = 'rejected',
           responded_by_player_id = p_actor_player_id,
           responded_at = now()
     WHERE id = v_war.id;

    INSERT INTO public.alliance_activity(
      alliance_id,
      event_type,
      actor_player_id,
      target_player_id,
      metadata
    )
    VALUES
    (
      v_war.challenger_alliance_id,
      'war_challenge_rejected',
      p_actor_player_id,
      NULL,
      jsonb_build_object('warId', v_war.id, 'opponentAllianceId', v_war.target_alliance_id)
    ),
    (
      v_war.target_alliance_id,
      'war_challenge_rejected',
      p_actor_player_id,
      NULL,
      jsonb_build_object('warId', v_war.id, 'opponentAllianceId', v_war.challenger_alliance_id)
    );

    RETURN jsonb_build_object(
      'success', true,
      'warId', v_war.id,
      'status', 'rejected',
      'message', 'Savaş çağrısı reddedildi.'
    );
  END IF;

  -- Finalize expired wars first. With both alliance rows locked this also
  -- serializes concurrent accept/declare operations involving either alliance.
  FOR v_active IN
    SELECT id
      FROM public.alliance_wars
     WHERE status = 'active'
       AND ends_at <= now()
       AND (
         challenger_alliance_id IN (v_war.challenger_alliance_id, v_war.target_alliance_id)
         OR target_alliance_id IN (v_war.challenger_alliance_id, v_war.target_alliance_id)
       )
  LOOP
    PERFORM public.nexora_alliance_war_finalize(v_active.id);
  END LOOP;

  IF EXISTS (
    SELECT 1
      FROM public.alliance_wars
     WHERE id <> v_war.id
       AND status = 'active'
       AND (
         challenger_alliance_id IN (v_war.challenger_alliance_id, v_war.target_alliance_id)
         OR target_alliance_id IN (v_war.challenger_alliance_id, v_war.target_alliance_id)
       )
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVE_WAR',
      'message', 'İttifaklardan biri zaten aktif bir savaşta.'
    );
  END IF;

  v_now := now();
  v_end := v_now + interval '72 hours';

  UPDATE public.alliance_wars
     SET status = 'active',
         responded_by_player_id = p_actor_player_id,
         responded_at = v_now,
         started_at = v_now,
         ends_at = v_end,
         challenger_score = 0,
         target_score = 0,
         winner_alliance_id = NULL,
         finished_at = NULL,
         result = '{}'::jsonb
   WHERE id = v_war.id;

  INSERT INTO public.alliance_activity(
    alliance_id,
    event_type,
    actor_player_id,
    target_player_id,
    metadata
  )
  VALUES
  (
    v_war.challenger_alliance_id,
    'war_started',
    p_actor_player_id,
    NULL,
    jsonb_build_object(
      'warId', v_war.id,
      'opponentAllianceId', v_war.target_alliance_id,
      'endsAt', v_end
    )
  ),
  (
    v_war.target_alliance_id,
    'war_started',
    p_actor_player_id,
    NULL,
    jsonb_build_object(
      'warId', v_war.id,
      'opponentAllianceId', v_war.challenger_alliance_id,
      'endsAt', v_end
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'warId', v_war.id,
    'status', 'active',
    'startedAt', v_now,
    'endsAt', v_end,
    'durationSeconds', 259200,
    'message', 'İttifak savaşı başladı.'
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 5) BATTLE -> WAR SCORE
-- Existing PvP battle reports remain the source of truth. A report can score in
-- at most one alliance war. Only battles created during the active war window
-- between members of the opposing alliances count.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_alliance_war_record_battle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_attacker_alliance_id bigint;
  v_defender_alliance_id bigint;
  v_war public.alliance_wars%ROWTYPE;
  v_winner_alliance_id bigint;
  v_points bigint := 0;
  v_event_id bigint;
BEGIN
  SELECT alliance_id
    INTO v_attacker_alliance_id
    FROM public.alliance_members
   WHERE player_id = NEW.attacker_player_id
   ORDER BY id
   LIMIT 1;

  SELECT alliance_id
    INTO v_defender_alliance_id
    FROM public.alliance_members
   WHERE player_id = NEW.defender_player_id
   ORDER BY id
   LIMIT 1;

  IF v_attacker_alliance_id IS NULL
     OR v_defender_alliance_id IS NULL
     OR v_attacker_alliance_id = v_defender_alliance_id THEN
    RETURN NEW;
  END IF;

  SELECT *
    INTO v_war
    FROM public.alliance_wars
   WHERE status = 'active'
     AND started_at IS NOT NULL
     AND ends_at IS NOT NULL
     AND NEW.created_at >= started_at
     AND NEW.created_at < ends_at
     AND (
       (challenger_alliance_id = v_attacker_alliance_id
        AND target_alliance_id = v_defender_alliance_id)
       OR
       (challenger_alliance_id = v_defender_alliance_id
        AND target_alliance_id = v_attacker_alliance_id)
     )
   ORDER BY started_at DESC, id DESC
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF NEW.winner_player_id = NEW.attacker_player_id THEN
    v_winner_alliance_id := v_attacker_alliance_id;
    v_points := GREATEST(1, COALESCE(NEW.battle_points, 0));
  ELSIF NEW.winner_player_id = NEW.defender_player_id THEN
    v_winner_alliance_id := v_defender_alliance_id;
    v_points := GREATEST(1, COALESCE(NEW.battle_points, 0));
  ELSE
    v_winner_alliance_id := NULL;
    v_points := 0;
  END IF;

  INSERT INTO public.alliance_war_battles(
    war_id,
    battle_report_id,
    attacker_alliance_id,
    defender_alliance_id,
    winner_alliance_id,
    points,
    battle_at
  )
  VALUES(
    v_war.id,
    NEW.id,
    v_attacker_alliance_id,
    v_defender_alliance_id,
    v_winner_alliance_id,
    v_points,
    NEW.created_at
  )
  ON CONFLICT (battle_report_id) DO NOTHING
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_winner_alliance_id = v_war.challenger_alliance_id THEN
    UPDATE public.alliance_wars
       SET challenger_score = challenger_score + v_points
     WHERE id = v_war.id;
  ELSIF v_winner_alliance_id = v_war.target_alliance_id THEN
    UPDATE public.alliance_wars
       SET target_score = target_score + v_points
     WHERE id = v_war.id;
  END IF;

  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_trigger
     WHERE tgname = 'trg_nexora_alliance_war_record_battle'
       AND tgrelid = 'public.battle_reports'::regclass
       AND NOT tgisinternal
  ) THEN
    CREATE TRIGGER trg_nexora_alliance_war_record_battle
    AFTER INSERT ON public.battle_reports
    FOR EACH ROW
    EXECUTE FUNCTION public.nexora_alliance_war_record_battle();
  END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- 6) WAR SNAPSHOT
-- Refreshes expired wars and returns the authenticated player's alliance war
-- state. Backend identity still comes from the auth token.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_alliance_wars_snapshot(
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
  v_role text;
  v_expired record;
  v_targets jsonb;
  v_wars jsonb;
BEGIN
  SELECT *
    INTO v_member
    FROM public.alliance_members
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'alliance', NULL,
      'member', NULL,
      'targets', '[]'::jsonb,
      'wars', '[]'::jsonb
    );
  END IF;

  SELECT *
    INTO v_alliance
    FROM public.alliances
   WHERE id = v_member.alliance_id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ALLIANCE_NOT_FOUND',
      'message', 'İttifak bulunamadı.'
    );
  END IF;

  v_role := CASE
    WHEN v_member.role = 'leader'
         AND v_alliance.owner_player_id = p_player_id
      THEN 'leader'
    ELSE COALESCE(v_member.role_v2, 'member')
  END;

  FOR v_expired IN
    SELECT id
      FROM public.alliance_wars
     WHERE status = 'active'
       AND ends_at <= now()
       AND (
         challenger_alliance_id = v_alliance.id
         OR target_alliance_id = v_alliance.id
       )
  LOOP
    PERFORM public.nexora_alliance_war_finalize(v_expired.id);
  END LOOP;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id,
        'name', a.name,
        'tag', a.tag,
        'memberCount', (
          SELECT COUNT(*)
            FROM public.alliance_members am
           WHERE am.alliance_id = a.id
        )
      )
      ORDER BY a.name, a.id
    ),
    '[]'::jsonb
  )
  INTO v_targets
  FROM public.alliances a
  WHERE a.id <> v_alliance.id
    AND EXISTS (
      SELECT 1
        FROM public.alliance_members am
       WHERE am.alliance_id = a.id
    );

  SELECT COALESCE(
    jsonb_agg(war_json ORDER BY sort_created DESC, sort_id DESC),
    '[]'::jsonb
  )
  INTO v_wars
  FROM (
    SELECT
      w.created_at AS sort_created,
      w.id AS sort_id,
      jsonb_build_object(
        'id', w.id,
        'status', w.status,
        'side',
          CASE
            WHEN w.challenger_alliance_id = v_alliance.id THEN 'challenger'
            ELSE 'target'
          END,
        'challengerAllianceId', w.challenger_alliance_id,
        'challengerAllianceName', ca.name,
        'challengerAllianceTag', ca.tag,
        'targetAllianceId', w.target_alliance_id,
        'targetAllianceName', ta.name,
        'targetAllianceTag', ta.tag,
        'opponentAllianceId',
          CASE
            WHEN w.challenger_alliance_id = v_alliance.id THEN w.target_alliance_id
            ELSE w.challenger_alliance_id
          END,
        'opponentAllianceName',
          CASE
            WHEN w.challenger_alliance_id = v_alliance.id THEN ta.name
            ELSE ca.name
          END,
        'opponentAllianceTag',
          CASE
            WHEN w.challenger_alliance_id = v_alliance.id THEN ta.tag
            ELSE ca.tag
          END,
        'ownScore',
          CASE
            WHEN w.challenger_alliance_id = v_alliance.id THEN w.challenger_score
            ELSE w.target_score
          END,
        'opponentScore',
          CASE
            WHEN w.challenger_alliance_id = v_alliance.id THEN w.target_score
            ELSE w.challenger_score
          END,
        'challengerScore', w.challenger_score,
        'targetScore', w.target_score,
        'winnerAllianceId', w.winner_alliance_id,
        'createdAt', w.created_at,
        'startedAt', w.started_at,
        'endsAt', w.ends_at,
        'finishedAt', w.finished_at,
        'remainingSeconds',
          CASE
            WHEN w.status = 'active' AND w.ends_at IS NOT NULL
              THEN GREATEST(0, CEIL(EXTRACT(EPOCH FROM (w.ends_at - now())))::integer)
            ELSE 0
          END,
        'canRespond',
          (w.status = 'pending'
           AND w.target_alliance_id = v_alliance.id
           AND v_role IN ('leader','officer')),
        'battleCount', (
          SELECT COUNT(*)
            FROM public.alliance_war_battles wb
           WHERE wb.war_id = w.id
        ),
        'lastBattleAt', (
          SELECT MAX(wb.battle_at)
            FROM public.alliance_war_battles wb
           WHERE wb.war_id = w.id
        ),
        'result', COALESCE(w.result, '{}'::jsonb)
      ) AS war_json
    FROM public.alliance_wars w
    JOIN public.alliances ca ON ca.id = w.challenger_alliance_id
    JOIN public.alliances ta ON ta.id = w.target_alliance_id
    WHERE w.challenger_alliance_id = v_alliance.id
       OR w.target_alliance_id = v_alliance.id
    ORDER BY w.created_at DESC, w.id DESC
    LIMIT 50
  ) q;

  RETURN jsonb_build_object(
    'success', true,
    'serverTime', now(),
    'alliance', jsonb_build_object(
      'id', v_alliance.id,
      'name', v_alliance.name,
      'tag', v_alliance.tag
    ),
    'member', jsonb_build_object(
      'playerId', p_player_id,
      'role', v_role,
      'canManageWars', v_role IN ('leader','officer')
    ),
    'targets', v_targets,
    'wars', v_wars
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 7) SECURITY
-- Browser clients never write war state directly. The backend service role calls
-- the RPCs after deriving player identity from the signed auth token.
-- -----------------------------------------------------------------------------

ALTER TABLE public.alliance_wars ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.alliance_war_battles ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.alliance_wars
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.alliance_war_battles
  FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.alliance_wars TO service_role;
GRANT ALL ON TABLE public.alliance_war_battles TO service_role;

GRANT USAGE, SELECT ON SEQUENCE public.alliance_wars_id_seq TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.alliance_war_battles_id_seq TO service_role;

REVOKE ALL ON FUNCTION public.nexora_alliance_war_finalize(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_alliance_war_declare(bigint,bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_alliance_war_respond(bigint,bigint,boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_alliance_war_record_battle()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_alliance_wars_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_alliance_war_finalize(bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_alliance_war_declare(bigint,bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_alliance_war_respond(bigint,bigint,boolean)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_alliance_war_record_battle()
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_alliance_wars_snapshot(bigint)
  TO service_role;

COMMIT;
