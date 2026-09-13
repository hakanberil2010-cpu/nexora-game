-- NEXORA Phase 11 – Alliance Territory V1
-- Enables alliance world sites without changing existing player-owned strategic points.
-- Apply after 020_phase10_nullable_escrow_refund.sql.

BEGIN;

ALTER TABLE public.world_sites
  ADD COLUMN IF NOT EXISTS owner_alliance_id bigint;

CREATE INDEX IF NOT EXISTS idx_world_sites_owner_alliance
  ON public.world_sites(owner_alliance_id);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conname = 'world_sites_owner_alliance_fk'
       AND conrelid = 'public.world_sites'::regclass
  ) THEN
    ALTER TABLE public.world_sites
      ADD CONSTRAINT world_sites_owner_alliance_fk
      FOREIGN KEY (owner_alliance_id)
      REFERENCES public.alliances(id)
      ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conname = 'world_sites_single_owner_check'
       AND conrelid = 'public.world_sites'::regclass
  ) THEN
    ALTER TABLE public.world_sites
      ADD CONSTRAINT world_sites_single_owner_check
      CHECK (owner_player_id IS NULL OR owner_alliance_id IS NULL);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_start_world_exploration(
  p_player_id bigint,
  p_site_id bigint,
  p_travel_seconds integer,
  p_distance numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_city public.cities%ROWTYPE;
  v_site public.world_sites%ROWTYPE;
  v_existing public.world_exploration_missions%ROWTYPE;
  v_mission public.world_exploration_missions%ROWTYPE;
  v_member public.alliance_members%ROWTYPE;
  v_last timestamptz;
  v_remaining integer;
  v_seconds integer;
  v_distance numeric;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR p_site_id IS NULL OR p_site_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz keşif isteği.'
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

  SELECT *
    INTO v_site
    FROM public.world_sites
   WHERE id = p_site_id
     AND active = true
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_NOT_FOUND',
      'message', 'Keşif noktası bulunamadı veya aktif değil.'
    );
  END IF;

  IF v_site.site_type = 'alliance' THEN
    SELECT *
      INTO v_member
      FROM public.alliance_members
     WHERE player_id = p_player_id
     ORDER BY id
     LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'ALLIANCE_REQUIRED',
        'message', 'İttifak bölgesini keşfetmek için bir ittifakta olmalısın.'
      );
    END IF;

    IF v_site.owner_alliance_id IS NOT NULL OR v_site.owner_player_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'SITE_OWNED',
        'message', 'Bu ittifak bölgesi zaten kontrol altında.'
      );
    END IF;
  ELSIF v_site.owner_player_id IS NOT NULL OR v_site.owner_alliance_id IS NOT NULL THEN
    -- Preserve Phase 6 hotfix 008: owned strategic sites cannot be explored again.
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_OWNED',
      'message', 'Kontrol altındaki noktalar yeniden keşfedilemez.'
    );
  END IF;

  SELECT *
    INTO v_existing
    FROM public.world_exploration_missions
   WHERE player_id = p_player_id
     AND status IN ('traveling', 'resolving')
   ORDER BY id DESC
   LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVE_EXPLORATION',
      'message', 'Zaten aktif bir keşif görevin bulunuyor.',
      'missionId', v_existing.id
    );
  END IF;

  v_last := GREATEST(
    COALESCE(v_city.last_exploration_at, 'epoch'::timestamptz),
    COALESCE(v_city.last_explored_at, 'epoch'::timestamptz)
  );

  IF v_last > now() - interval '10 minutes' THEN
    v_remaining := GREATEST(
      1,
      CEIL(EXTRACT(EPOCH FROM ((v_last + interval '10 minutes') - now())))::integer
    );

    RETURN jsonb_build_object(
      'success', false,
      'code', 'EXPLORATION_COOLDOWN',
      'message', 'Keşif için henüz hazır değilsin.',
      'remainingSeconds', v_remaining
    );
  END IF;

  v_seconds := GREATEST(10, LEAST(COALESCE(p_travel_seconds, 10), 3600));
  v_distance := GREATEST(0, COALESCE(p_distance, 0));

  UPDATE public.cities
     SET last_exploration_at = now(),
         last_explored_at = now()
   WHERE id = v_city.id;

  INSERT INTO public.world_exploration_missions(
    player_id,
    city_id,
    site_id,
    status,
    depart_at,
    arrive_at,
    distance,
    travel_seconds
  )
  VALUES(
    p_player_id,
    v_city.id,
    v_site.id,
    'traveling',
    now(),
    now() + make_interval(secs => v_seconds),
    v_distance,
    v_seconds
  )
  RETURNING * INTO v_mission;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Keşif görevi başlatıldı.',
    'mission', jsonb_build_object(
      'id', v_mission.id,
      'status', v_mission.status,
      'arriveAt', v_mission.arrive_at,
      'travelSeconds', v_mission.travel_seconds,
      'distance', v_mission.distance,
      'siteId', v_mission.site_id
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_claim_world_site(
  p_player_id bigint,
  p_site_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_site public.world_sites%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_member public.alliance_members%ROWTYPE;
  v_alliance public.alliances%ROWTYPE;
  v_role text;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR p_site_id IS NULL OR p_site_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ID',
      'message', 'Geçersiz oyuncu veya nokta.'
    );
  END IF;

  SELECT *
    INTO v_site
    FROM public.world_sites
   WHERE id = p_site_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_NOT_FOUND',
      'message', 'Dünya noktası bulunamadı.'
    );
  END IF;

  IF v_site.active IS DISTINCT FROM true THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_DISABLED',
      'message', 'Bu nokta kontrol altına alınamaz.'
    );
  END IF;

  IF v_site.site_type = 'alliance' THEN
    SELECT *
      INTO v_member
      FROM public.alliance_members
     WHERE player_id = p_player_id
     ORDER BY id
     LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'ALLIANCE_REQUIRED',
        'message', 'İttifak bölgesini almak için bir ittifakta olmalısın.'
      );
    END IF;

    SELECT *
      INTO v_alliance
      FROM public.alliances
     WHERE id = v_member.alliance_id
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
        'code', 'ALLIANCE_CHANGED',
        'message', 'İttifak üyeliğin değişti. Tekrar dene.'
      );
    END IF;

    v_role := CASE
      WHEN v_member.role = 'leader' THEN 'leader'
      WHEN v_member.role_v2 = 'officer' THEN 'officer'
      ELSE 'member'
    END;

    IF v_role NOT IN ('leader', 'officer') THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INSUFFICIENT_ROLE',
        'message', 'İttifak bölgesini yalnız lider veya subay kontrol altına alabilir.'
      );
    END IF;

    IF v_site.owner_alliance_id = v_alliance.id THEN
      RETURN jsonb_build_object(
        'success', true,
        'alreadyOwned', true,
        'siteId', v_site.id,
        'owner_alliance_id', v_alliance.id,
        'claimed_at', v_site.claimed_at,
        'message', 'Bu bölge zaten ittifakının kontrolünde.'
      );
    END IF;

    IF v_site.owner_alliance_id IS NOT NULL OR v_site.owner_player_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'SITE_OWNED',
        'message', 'Bu bölge başka bir güç tarafından kontrol ediliyor.'
      );
    END IF;

    IF NOT EXISTS (
      SELECT 1
        FROM public.world_exploration_missions m
        JOIN public.alliance_members am
          ON am.player_id = m.player_id
         AND am.alliance_id = v_alliance.id
       WHERE m.site_id = p_site_id
         AND m.status = 'completed'
    ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'EXPLORATION_REQUIRED',
        'message', 'Önce ittifak üyelerinden biri bu bölgenin keşfini tamamlamalı.'
      );
    END IF;

    IF (
      SELECT COUNT(*)
        FROM public.world_sites
       WHERE site_type = 'alliance'
         AND owner_alliance_id = v_alliance.id
    ) >= 2 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'ALLIANCE_CLAIM_LIMIT',
        'message', 'Bir ittifak en fazla 2 ittifak bölgesi kontrol edebilir.'
      );
    END IF;

    UPDATE public.world_sites
       SET owner_alliance_id = v_alliance.id,
           owner_player_id = NULL,
           claimed_at = now()
     WHERE id = v_site.id
     RETURNING * INTO v_site;

    INSERT INTO public.alliance_activity(
      alliance_id,
      event_type,
      actor_player_id,
      target_player_id,
      metadata
    )
    VALUES(
      v_alliance.id,
      'territory_claimed',
      p_player_id,
      NULL,
      jsonb_build_object(
        'siteId', v_site.id,
        'siteName', v_site.name,
        'coordinateX', v_site.coordinate_x,
        'coordinateY', v_site.coordinate_y
      )
    );

    RETURN jsonb_build_object(
      'success', true,
      'alreadyOwned', false,
      'siteId', v_site.id,
      'owner_alliance_id', v_alliance.id,
      'owner_alliance_name', v_alliance.name,
      'owner_alliance_tag', v_alliance.tag,
      'claimed_at', v_site.claimed_at,
      'message', 'İttifak bölgesi kontrol altına alındı.'
    );
  END IF;

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

  IF v_site.owner_player_id = p_player_id THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyOwned', true,
      'siteId', v_site.id,
      'owner_player_id', p_player_id,
      'claimed_at', v_site.claimed_at,
      'message', 'Bu nokta zaten senin kontrolünde.'
    );
  END IF;

  IF v_site.owner_player_id IS NOT NULL OR v_site.owner_alliance_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_OWNED',
      'message', 'Bu nokta başka bir oyuncunun kontrolünde.'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.world_exploration_missions
     WHERE player_id = p_player_id
       AND site_id = p_site_id
       AND status = 'completed'
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'EXPLORATION_REQUIRED',
      'message', 'Önce bu noktanın keşfini tamamlamalısın.'
    );
  END IF;

  IF (
    SELECT COUNT(*)
      FROM public.world_sites
     WHERE owner_player_id = p_player_id
  ) >= 2 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CLAIM_LIMIT',
      'message', 'En fazla 2 stratejik nokta kontrol edebilirsin.'
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

  UPDATE public.world_sites
     SET owner_player_id = p_player_id,
         owner_alliance_id = NULL,
         claimed_at = now()
   WHERE id = p_site_id
   RETURNING * INTO v_site;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyOwned', false,
    'siteId', v_site.id,
    'owner_player_id', p_player_id,
    'claimed_at', v_site.claimed_at,
    'message', 'Nokta kontrol altına alındı.'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_world_control_sites(p_player_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH viewer AS (
    SELECT
      am.alliance_id,
      CASE
        WHEN am.role = 'leader' THEN 'leader'
        WHEN am.role_v2 = 'officer' THEN 'officer'
        ELSE 'member'
      END AS alliance_role
    FROM public.alliance_members am
    WHERE am.player_id = p_player_id
    ORDER BY am.id
    LIMIT 1
  ),
  viewer_meta AS (
    SELECT
      v.alliance_id,
      v.alliance_role,
      (
        SELECT COUNT(*)
        FROM public.world_sites owned
        WHERE owned.site_type = 'alliance'
          AND owned.owner_alliance_id = v.alliance_id
      ) AS alliance_claim_count
    FROM viewer v
  )
  SELECT COALESCE(
    jsonb_agg(
      to_jsonb(s) || jsonb_build_object(
        'owner_username', p.username,
        'owner_alliance_name', a.name,
        'owner_alliance_tag', a.tag,
        'viewer_alliance_id', vm.alliance_id,
        'viewer_alliance_role', vm.alliance_role,
        'claim_scope', CASE WHEN s.site_type = 'alliance' THEN 'alliance' ELSE 'player' END,
        'has_explored', EXISTS (
          SELECT 1
          FROM public.world_exploration_missions m
          WHERE m.player_id = p_player_id
            AND m.site_id = s.id
            AND m.status = 'completed'
        ),
        'alliance_has_explored', CASE
          WHEN s.site_type = 'alliance' AND vm.alliance_id IS NOT NULL THEN EXISTS (
            SELECT 1
            FROM public.world_exploration_missions m
            JOIN public.alliance_members am
              ON am.player_id = m.player_id
             AND am.alliance_id = vm.alliance_id
            WHERE m.site_id = s.id
              AND m.status = 'completed'
          )
          ELSE false
        END,
        'can_explore', CASE
          WHEN s.site_type = 'alliance' THEN
            vm.alliance_id IS NOT NULL
            AND s.owner_alliance_id IS NULL
            AND s.owner_player_id IS NULL
          ELSE
            s.owner_player_id IS NULL
            AND s.owner_alliance_id IS NULL
        END,
        'can_claim', CASE
          WHEN s.site_type = 'alliance' THEN
            vm.alliance_id IS NOT NULL
            AND vm.alliance_role IN ('leader','officer')
            AND s.owner_alliance_id IS NULL
            AND s.owner_player_id IS NULL
            AND COALESCE(vm.alliance_claim_count, 0) < 2
            AND EXISTS (
              SELECT 1
              FROM public.world_exploration_missions m
              JOIN public.alliance_members am
                ON am.player_id = m.player_id
               AND am.alliance_id = vm.alliance_id
              WHERE m.site_id = s.id
                AND m.status = 'completed'
            )
          ELSE
            s.owner_player_id IS NULL
            AND s.owner_alliance_id IS NULL
            AND (
              SELECT COUNT(*)
              FROM public.world_sites owned
              WHERE owned.owner_player_id = p_player_id
            ) < 2
            AND EXISTS (
              SELECT 1
              FROM public.world_exploration_missions m
              WHERE m.player_id = p_player_id
                AND m.site_id = s.id
                AND m.status = 'completed'
            )
        END,
        'is_owned_by_viewer', CASE
          WHEN s.site_type = 'alliance' THEN
            vm.alliance_id IS NOT NULL
            AND s.owner_alliance_id = vm.alliance_id
          ELSE
            s.owner_player_id = p_player_id
        END
      )
      ORDER BY s.id
    ),
    '[]'::jsonb
  )
  FROM public.world_sites s
  LEFT JOIN public.players p
    ON p.id = s.owner_player_id
  LEFT JOIN public.alliances a
    ON a.id = s.owner_alliance_id
  LEFT JOIN viewer_meta vm
    ON true
  WHERE s.active = true;
$$;

REVOKE ALL ON FUNCTION public.nexora_start_world_exploration(bigint,bigint,integer,numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_start_world_exploration(bigint,bigint,integer,numeric)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_claim_world_site(bigint,bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_claim_world_site(bigint,bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_world_control_sites(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_world_control_sites(bigint)
  TO service_role;

COMMIT;
