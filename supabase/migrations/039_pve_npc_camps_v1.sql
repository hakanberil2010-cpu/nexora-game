-- NEXORA - PvE / NPC Camps V1
-- Migration 039
--
-- Goals:
-- - Add NPC camps as first-class PvE targets without fake player accounts.
-- - Keep PvP military_missions / battle_reports semantics untouched.
-- - Reserve active NPC armies in housing / army-capacity calculations.
-- - Keep NPC victories out of PvP ranking while allowing game objectives to
--   count both PvP and PvE victories.
-- - Keep NPC world sites hidden from the existing generic world-site snapshot
--   until the backend/frontend explicitly opts into nexora_npc_camps_snapshot.
-- - Make start / resolution / survivor return atomic and idempotent.
--
-- Apply after 038_auth_rate_limit_v1.sql.
-- Backend/frontend integration is intentionally NOT part of this migration.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) NPC CAMP DEFINITIONS + PLAYER STATE
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.npc_camps (
  id bigserial PRIMARY KEY,
  world_site_id bigint NOT NULL UNIQUE
    REFERENCES public.world_sites(id) ON DELETE RESTRICT,
  tier integer NOT NULL CHECK (tier BETWEEN 1 AND 10),
  difficulty text NOT NULL
    CHECK (difficulty IN ('easy','medium','hard')),
  army_template jsonb NOT NULL
    CHECK (jsonb_typeof(army_template) = 'array'),
  reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(reward) = 'object'),
  cooldown_seconds integer NOT NULL DEFAULT 600
    CHECK (cooldown_seconds BETWEEN 30 AND 86400),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS public.player_npc_camp_state (
  player_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE CASCADE,
  npc_camp_id bigint NOT NULL
    REFERENCES public.npc_camps(id) ON DELETE CASCADE,
  victories integer NOT NULL DEFAULT 0 CHECK (victories >= 0),
  defeats integer NOT NULL DEFAULT 0 CHECK (defeats >= 0),
  draws integer NOT NULL DEFAULT 0 CHECK (draws >= 0),
  last_battle_at timestamptz,
  available_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (player_id, npc_camp_id)
);

CREATE INDEX IF NOT EXISTS idx_player_npc_camp_state_available
  ON public.player_npc_camp_state(player_id, available_at);

-- -----------------------------------------------------------------------------
-- 2) NPC MISSIONS + REPORTS
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.npc_missions (
  id bigserial PRIMARY KEY,
  player_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE RESTRICT,
  city_id bigint NOT NULL
    REFERENCES public.cities(id) ON DELETE RESTRICT,
  npc_camp_id bigint NOT NULL
    REFERENCES public.npc_camps(id) ON DELETE RESTRICT,

  status text NOT NULL DEFAULT 'traveling'
    CHECK (status IN ('traveling','resolving','returning','completed')),

  depart_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  arrive_at timestamptz NOT NULL,
  completed_at timestamptz,

  attack_power integer NOT NULL DEFAULT 0 CHECK (attack_power >= 0),
  defense_power integer NOT NULL DEFAULT 0 CHECK (defense_power >= 0),

  army jsonb NOT NULL CHECK (jsonb_typeof(army) = 'array'),
  npc_army jsonb NOT NULL CHECK (jsonb_typeof(npc_army) = 'array'),
  reward_snapshot jsonb NOT NULL CHECK (jsonb_typeof(reward_snapshot) = 'object'),

  camp_name text NOT NULL,
  camp_tier integer NOT NULL CHECK (camp_tier BETWEEN 1 AND 10),
  cooldown_seconds integer NOT NULL CHECK (cooldown_seconds BETWEEN 30 AND 86400),

  depart_x integer NOT NULL CHECK (depart_x BETWEEN 1 AND 100),
  depart_y integer NOT NULL CHECK (depart_y BETWEEN 1 AND 100),
  target_x integer NOT NULL CHECK (target_x BETWEEN 1 AND 100),
  target_y integer NOT NULL CHECK (target_y BETWEEN 1 AND 100),

  travel_seconds integer NOT NULL CHECK (travel_seconds BETWEEN 1 AND 86400),
  fleet_speed numeric NOT NULL CHECK (fleet_speed > 0),

  battle_tactic text NOT NULL DEFAULT 'balanced'
    CHECK (battle_tactic IN ('assault','balanced','cautious')),

  result jsonb,
  settled_reward jsonb,

  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS idx_npc_missions_player_status
  ON public.npc_missions(player_id, status, arrive_at, id);

CREATE INDEX IF NOT EXISTS idx_npc_missions_camp_status
  ON public.npc_missions(npc_camp_id, status, arrive_at, id);

-- Separate PvE slot: one active NPC expedition per player.
-- This intentionally does not block one simultaneous PvP military mission.
CREATE UNIQUE INDEX IF NOT EXISTS idx_npc_missions_one_active_per_player
  ON public.npc_missions(player_id)
  WHERE status IN ('traveling','resolving','returning');

CREATE TABLE IF NOT EXISTS public.npc_battle_reports (
  id bigserial PRIMARY KEY,
  npc_mission_id bigint NOT NULL UNIQUE
    REFERENCES public.npc_missions(id) ON DELETE RESTRICT,
  player_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE RESTRICT,
  npc_camp_id bigint NOT NULL
    REFERENCES public.npc_camps(id) ON DELETE RESTRICT,

  camp_name text NOT NULL,
  camp_tier integer NOT NULL CHECK (camp_tier BETWEEN 1 AND 10),

  result text NOT NULL
    CHECK (result IN ('Zafer','Yenilgi','Beraberlik')),

  attack_power integer NOT NULL CHECK (attack_power >= 0),
  defense_power integer NOT NULL CHECK (defense_power >= 0),

  attacker_losses jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(attacker_losses) = 'object'),
  npc_losses jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(npc_losses) = 'object'),

  reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(reward) = 'object'),

  battle_tactic text NOT NULL
    CHECK (battle_tactic IN ('assault','balanced','cautious')),

  report jsonb NOT NULL CHECK (jsonb_typeof(report) = 'object'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS idx_npc_battle_reports_player_created
  ON public.npc_battle_reports(player_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_npc_battle_reports_camp_created
  ON public.npc_battle_reports(npc_camp_id, created_at DESC, id DESC);

-- New tables are backend-only. Security-definer RPCs below are the public
-- application boundary; browsers never receive direct table permissions.
ALTER TABLE public.npc_camps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_npc_camp_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.npc_missions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.npc_battle_reports ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.npc_camps
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.player_npc_camp_state
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.npc_missions
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.npc_battle_reports
  FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.npc_camps TO service_role;
GRANT ALL ON TABLE public.player_npc_camp_state TO service_role;
GRANT ALL ON TABLE public.npc_missions TO service_role;
GRANT ALL ON TABLE public.npc_battle_reports TO service_role;

GRANT USAGE, SELECT ON SEQUENCE public.npc_camps_id_seq TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.npc_missions_id_seq TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.npc_battle_reports_id_seq TO service_role;

-- -----------------------------------------------------------------------------
-- 3) SEED THREE CAMPS ON FREE WORLD COORDINATES
--
-- The same advisory lock used by registration / colony movement prevents a
-- concurrent player spawn from taking a coordinate while these sites are seeded.
-- Existing production cities and world sites are never moved or overwritten.
-- -----------------------------------------------------------------------------

DO $seed$
DECLARE
  seed record;
  v_site public.world_sites%ROWTYPE;
  v_x integer;
  v_y integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('nexora_city_spawn'));

  FOR seed IN
    SELECT *
    FROM (
      VALUES
        (
          1,
          'easy'::text,
          'Yağmacı Kampı I'::text,
          20,
          45,
          '[
            {"unit_type":"piyade","quantity":5,"level":1},
            {"unit_type":"savunma","quantity":2,"level":1}
          ]'::jsonb,
          '{"metal":350,"energy":120,"water":100,"crystal":10}'::jsonb,
          300,
          'Düşük seviyeli yağmacıların kurduğu başlangıç PvE kampı.'::text
        ),
        (
          2,
          'medium'::text,
          'Yağmacı Kampı II'::text,
          50,
          50,
          '[
            {"unit_type":"piyade","quantity":12,"level":1},
            {"unit_type":"savunma","quantity":6,"level":1},
            {"unit_type":"saldiri","quantity":4,"level":1},
            {"unit_type":"okcu","quantity":3,"level":1}
          ]'::jsonb,
          '{"metal":800,"energy":300,"water":250,"crystal":35}'::jsonb,
          600,
          'Orta seviyeli birliklerden oluşan yağmacı kampı.'::text
        ),
        (
          3,
          'hard'::text,
          'Askeri Üs III'::text,
          80,
          45,
          '[
            {"unit_type":"piyade","quantity":15,"level":2},
            {"unit_type":"savunma","quantity":10,"level":2},
            {"unit_type":"saldiri","quantity":10,"level":2},
            {"unit_type":"okcu","quantity":8,"level":2},
            {"unit_type":"tank","quantity":2,"level":1}
          ]'::jsonb,
          '{"metal":1600,"energy":700,"water":500,"crystal":100}'::jsonb,
          900,
          'Güçlü bir garnizon tarafından korunan ileri PvE askeri üssü.'::text
        )
    ) AS seeds(
      tier,
      difficulty,
      name,
      preferred_x,
      preferred_y,
      army_template,
      reward,
      cooldown_seconds,
      description
    )
  LOOP
    SELECT *
      INTO v_site
      FROM public.world_sites
     WHERE name = seed.name
     ORDER BY id
     LIMIT 1
     FOR UPDATE;

    IF v_site.id IS NOT NULL
       AND v_site.site_type IS DISTINCT FROM 'npc_camp' THEN
      RAISE EXCEPTION
        'NPC camp seed name conflicts with another world-site type: %',
        seed.name;
    END IF;

    IF v_site.id IS NULL THEN
      v_x := seed.preferred_x;
      v_y := seed.preferred_y;

      IF EXISTS (
        SELECT 1
          FROM public.cities c
         WHERE c.coordinate_x = v_x
           AND c.coordinate_y = v_y
      )
      OR EXISTS (
        SELECT 1
          FROM public.world_sites ws
         WHERE ws.coordinate_x = v_x
           AND ws.coordinate_y = v_y
      ) THEN
        v_x := NULL;
        v_y := NULL;

        SELECT gx, gy
          INTO v_x, v_y
          FROM generate_series(3, 97, 3) AS gx
          CROSS JOIN generate_series(3, 97, 3) AS gy
         WHERE NOT EXISTS (
                 SELECT 1
                   FROM public.cities c
                  WHERE c.coordinate_x = gx
                    AND c.coordinate_y = gy
               )
           AND NOT EXISTS (
                 SELECT 1
                   FROM public.world_sites ws
                  WHERE ws.coordinate_x = gx
                    AND ws.coordinate_y = gy
               )
         ORDER BY
           ((gx - seed.preferred_x) * (gx - seed.preferred_x))
           +
           ((gy - seed.preferred_y) * (gy - seed.preferred_y)),
           gx,
           gy
         LIMIT 1;
      END IF;

      IF v_x IS NULL OR v_y IS NULL THEN
        SELECT gx, gy
          INTO v_x, v_y
          FROM generate_series(1, 100) AS gx
          CROSS JOIN generate_series(1, 100) AS gy
         WHERE NOT EXISTS (
                 SELECT 1
                   FROM public.cities c
                  WHERE c.coordinate_x = gx
                    AND c.coordinate_y = gy
               )
           AND NOT EXISTS (
                 SELECT 1
                   FROM public.world_sites ws
                  WHERE ws.coordinate_x = gx
                    AND ws.coordinate_y = gy
               )
         ORDER BY
           ((gx - seed.preferred_x) * (gx - seed.preferred_x))
           +
           ((gy - seed.preferred_y) * (gy - seed.preferred_y)),
           gx,
           gy
         LIMIT 1;
      END IF;

      IF v_x IS NULL OR v_y IS NULL THEN
        RAISE EXCEPTION
          'NPC kampı için boş dünya koordinatı bulunamadı: %',
          seed.name;
      END IF;

      INSERT INTO public.world_sites(
        site_type,
        name,
        coordinate_x,
        coordinate_y,
        reward,
        active,
        description,
        owner_player_id,
        owner_alliance_id,
        claimed_at
      )
      VALUES(
        'npc_camp',
        seed.name,
        v_x,
        v_y,
        seed.reward,
        true,
        seed.description,
        NULL,
        NULL,
        NULL
      )
      RETURNING * INTO v_site;
    ELSE
      IF EXISTS (
        SELECT 1
          FROM public.cities c
         WHERE c.coordinate_x = v_site.coordinate_x
           AND c.coordinate_y = v_site.coordinate_y
      ) THEN
        RAISE EXCEPTION
          'Mevcut NPC kamp koordinatı bir koloni ile çakışıyor: %',
          seed.name;
      END IF;

      UPDATE public.world_sites
         SET site_type = 'npc_camp',
             reward = seed.reward,
             active = true,
             description = seed.description,
             owner_player_id = NULL,
             owner_alliance_id = NULL,
             claimed_at = NULL
       WHERE id = v_site.id
       RETURNING * INTO v_site;
    END IF;

    INSERT INTO public.npc_camps(
      world_site_id,
      tier,
      difficulty,
      army_template,
      reward,
      cooldown_seconds,
      active,
      updated_at
    )
    VALUES(
      v_site.id,
      seed.tier,
      seed.difficulty,
      seed.army_template,
      seed.reward,
      seed.cooldown_seconds,
      true,
      clock_timestamp()
    )
    ON CONFLICT (world_site_id)
    DO UPDATE SET
      tier = EXCLUDED.tier,
      difficulty = EXCLUDED.difficulty,
      army_template = EXCLUDED.army_template,
      reward = EXCLUDED.reward,
      cooldown_seconds = EXCLUDED.cooldown_seconds,
      active = true,
      updated_at = clock_timestamp();
  END LOOP;
END;
$seed$;

-- -----------------------------------------------------------------------------
-- 4) KEEP NPC CAMPS OUT OF GENERIC EXPLORE / CLAIM FLOWS
--
-- IMPORTANT: these definitions preserve the newer Phase 11 alliance-territory
-- behavior from migration 021. The only PvE-specific changes are:
-- - npc_camp cannot use generic exploration/claim,
-- - npc_camp is hidden from nexora_world_control_sites until the dedicated
--   PvE frontend/backend explicitly reads nexora_npc_camps_snapshot.
-- -----------------------------------------------------------------------------

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

  IF v_site.site_type = 'npc_camp' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CAMP_COMBAT_ONLY',
      'message', 'NPC kampları keşif hedefi değildir; askeri saldırı gerekir.'
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

    IF v_site.owner_alliance_id IS NOT NULL
       OR v_site.owner_player_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'SITE_OWNED',
        'message', 'Bu ittifak bölgesi zaten kontrol altında.'
      );
    END IF;
  ELSIF v_site.owner_player_id IS NOT NULL
     OR v_site.owner_alliance_id IS NOT NULL THEN
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
      CEIL(
        EXTRACT(
          EPOCH FROM ((v_last + interval '10 minutes') - now())
        )
      )::integer
    );

    RETURN jsonb_build_object(
      'success', false,
      'code', 'EXPLORATION_COOLDOWN',
      'message', 'Keşif için henüz hazır değilsin.',
      'remainingSeconds', v_remaining
    );
  END IF;

  v_seconds := GREATEST(
    10,
    LEAST(COALESCE(p_travel_seconds, 10), 3600)
  );
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
    'mission',
      jsonb_build_object(
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

  IF v_site.site_type = 'npc_camp' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CAMP_COMBAT_ONLY',
      'message', 'NPC kampları kontrol altına alınamaz; yalnızca saldırılabilir.'
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

    IF v_site.owner_alliance_id IS NOT NULL
       OR v_site.owner_player_id IS NOT NULL THEN
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

  IF v_site.owner_player_id IS NOT NULL
     OR v_site.owner_alliance_id IS NOT NULL THEN
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

CREATE OR REPLACE FUNCTION public.nexora_world_control_sites(
  p_player_id bigint
)
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
      to_jsonb(s)
      ||
      jsonb_build_object(
        'owner_username', p.username,
        'owner_alliance_name', a.name,
        'owner_alliance_tag', a.tag,
        'viewer_alliance_id', vm.alliance_id,
        'viewer_alliance_role', vm.alliance_role,
        'claim_scope',
          CASE
            WHEN s.site_type = 'alliance' THEN 'alliance'
            ELSE 'player'
          END,
        'has_explored',
          EXISTS (
            SELECT 1
            FROM public.world_exploration_missions m
            WHERE m.player_id = p_player_id
              AND m.site_id = s.id
              AND m.status = 'completed'
          ),
        'alliance_has_explored',
          CASE
            WHEN s.site_type = 'alliance'
             AND vm.alliance_id IS NOT NULL THEN
              EXISTS (
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
        'can_explore',
          CASE
            WHEN s.site_type = 'alliance' THEN
              vm.alliance_id IS NOT NULL
              AND s.owner_alliance_id IS NULL
              AND s.owner_player_id IS NULL
            ELSE
              s.owner_player_id IS NULL
              AND s.owner_alliance_id IS NULL
          END,
        'can_claim',
          CASE
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
        'is_owned_by_viewer',
          CASE
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
  WHERE s.active = true
    AND s.site_type <> 'npc_camp';
$$;

-- Explicit PvE snapshot for the future backend. Generic world-site consumers do
-- not receive these rows.
CREATE OR REPLACE FUNCTION public.nexora_npc_camps_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'success', true,
    'camps',
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'id', c.id,
            'worldSiteId', s.id,
            'name', s.name,
            'description', s.description,
            'tier', c.tier,
            'difficulty', c.difficulty,
            'coordinateX', s.coordinate_x,
            'coordinateY', s.coordinate_y,
            'armyTemplate', c.army_template,
            'reward', c.reward,
            'cooldownSeconds', c.cooldown_seconds,
            'victories', COALESCE(st.victories, 0),
            'defeats', COALESCE(st.defeats, 0),
            'draws', COALESCE(st.draws, 0),
            'lastBattleAt', st.last_battle_at,
            'availableAt', st.available_at,
            'remainingSeconds',
              GREATEST(
                0,
                CEIL(
                  EXTRACT(
                    EPOCH FROM (
                      COALESCE(st.available_at, 'epoch'::timestamptz)
                      - now()
                    )
                  )
                )::integer
              ),
            'activeMissionId',
              (
                SELECT m.id
                  FROM public.npc_missions m
                 WHERE m.player_id = p_player_id
                   AND m.status IN ('traveling','resolving','returning')
                 ORDER BY m.id DESC
                 LIMIT 1
              ),
            'canAttack',
              COALESCE(st.available_at, 'epoch'::timestamptz) <= now()
              AND NOT EXISTS (
                SELECT 1
                  FROM public.npc_missions m
                 WHERE m.player_id = p_player_id
                   AND m.status IN ('traveling','resolving','returning')
              )
          )
          ORDER BY c.tier, c.id
        ),
        '[]'::jsonb
      )
  )
  FROM public.npc_camps c
  JOIN public.world_sites s
    ON s.id = c.world_site_id
  LEFT JOIN public.player_npc_camp_state st
    ON st.player_id = p_player_id
   AND st.npc_camp_id = c.id
  WHERE c.active = true
    AND s.active = true
    AND s.site_type = 'npc_camp';
$$;

-- -----------------------------------------------------------------------------
-- 5) ATOMIC NPC MISSION START
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_start_npc_mission(
  p_player_id bigint,
  p_city_id bigint,
  p_camp_id bigint,
  p_army jsonb,
  p_attack_power integer,
  p_depart_x integer,
  p_depart_y integer,
  p_travel_seconds integer,
  p_fleet_speed numeric,
  p_battle_tactic text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_city public.cities%ROWTYPE;
  v_camp public.npc_camps%ROWTYPE;
  v_site public.world_sites%ROWTYPE;
  v_state public.player_npc_camp_state%ROWTYPE;
  v_mission public.npc_missions%ROWTYPE;
  v_unit public.units%ROWTYPE;

  item jsonb;
  requested_type text;
  quantity_text text;
  level_text text;
  requested_quantity bigint;
  requested_level integer;

  item_count integer;
  distinct_type_count integer;

  camp_item_count integer;
  camp_distinct_type_count integer;

  unit_id bigint;
  affected integer;

  v_tactic text;
  v_now timestamptz;
  v_remaining integer;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR p_city_id IS NULL OR p_city_id <= 0
     OR p_camp_id IS NULL OR p_camp_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_TARGET',
      'message', 'Geçersiz PvE hedefi.'
    );
  END IF;

  IF p_attack_power IS NULL OR p_attack_power <= 0
     OR p_travel_seconds IS NULL
     OR p_travel_seconds < 1
     OR p_travel_seconds > 86400
     OR p_fleet_speed IS NULL
     OR p_fleet_speed <= 0
     OR p_depart_x IS NULL
     OR p_depart_y IS NULL
     OR p_depart_x NOT BETWEEN 1 AND 100
     OR p_depart_y NOT BETWEEN 1 AND 100 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_MISSION',
      'message', 'Geçersiz PvE sefer bilgisi.'
    );
  END IF;

  v_tactic := lower(trim(COALESCE(p_battle_tactic, '')));

  IF v_tactic NOT IN ('assault','balanced','cautious') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_TACTIC',
      'message', 'Geçersiz savaş taktiği.'
    );
  END IF;

  -- City lock serializes NPC starts with resource / population / colony writes.
  SELECT *
    INTO v_city
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF v_city.id IS NULL OR v_city.id <> p_city_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  v_now := clock_timestamp();

  IF COALESCE(v_city.coordinate_x, 0) <> p_depart_x
     OR COALESCE(v_city.coordinate_y, 0) <> p_depart_y THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_CHANGED',
      'message', 'Koloni koordinatı değişti; haritayı yenileyip tekrar deneyin.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.npc_missions
     WHERE player_id = p_player_id
       AND status IN ('traveling','resolving','returning')
     LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVE_NPC_MISSION',
      'message', 'Zaten aktif bir PvE seferin bulunuyor.'
    );
  END IF;

  SELECT *
    INTO v_camp
    FROM public.npc_camps
   WHERE id = p_camp_id
     AND active = true
   LIMIT 1;

  IF v_camp.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CAMP_NOT_FOUND',
      'message', 'NPC kampı bulunamadı veya aktif değil.'
    );
  END IF;

  SELECT *
    INTO v_site
    FROM public.world_sites
   WHERE id = v_camp.world_site_id
     AND active = true
     AND site_type = 'npc_camp'
   LIMIT 1;

  IF v_site.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CAMP_DISABLED',
      'message', 'NPC kampı şu anda kullanılamıyor.'
    );
  END IF;

  SELECT *
    INTO v_state
    FROM public.player_npc_camp_state
   WHERE player_id = p_player_id
     AND npc_camp_id = v_camp.id
   FOR UPDATE;

  IF v_state.available_at IS NOT NULL
     AND v_state.available_at > v_now THEN
    v_remaining := GREATEST(
      1,
      CEIL(
        EXTRACT(EPOCH FROM (v_state.available_at - v_now))
      )::integer
    );

    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CAMP_COOLDOWN',
      'message', 'Bu NPC kampı henüz yeniden saldırıya açık değil.',
      'availableAt', v_state.available_at,
      'remainingSeconds', v_remaining
    );
  END IF;

  IF p_army IS NULL
     OR jsonb_typeof(p_army) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ARMY',
      'message', 'Geçersiz ordu bilgisi.'
    );
  END IF;

  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
    INTO item_count, distinct_type_count
    FROM jsonb_array_elements(p_army) AS army_item(value);

  IF item_count < 1
     OR item_count > 6
     OR distinct_type_count <> item_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ARMY',
      'message', 'Geçersiz veya tekrarlanan birlik seçimi.'
    );
  END IF;

  IF v_camp.army_template IS NULL
     OR jsonb_typeof(v_camp.army_template) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CONFIG_INVALID',
      'message', 'NPC kamp ordusu yapılandırması geçersiz.'
    );
  END IF;

  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
    INTO camp_item_count, camp_distinct_type_count
    FROM jsonb_array_elements(v_camp.army_template) AS camp_item(value);

  IF camp_item_count < 1
     OR camp_item_count > 6
     OR camp_distinct_type_count <> camp_item_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CONFIG_INVALID',
      'message', 'NPC kamp ordusu yapılandırması geçersiz.'
    );
  END IF;

  -- Validate configured NPC army and make sure every configured level exists.
  FOR item IN
    SELECT value
      FROM jsonb_array_elements(v_camp.army_template) AS camp_item(value)
  LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'NPC_CONFIG_INVALID',
        'message', 'NPC kamp ordusu yapılandırması geçersiz.'
      );
    END IF;

    requested_type := item->>'unit_type';
    quantity_text := item->>'quantity';
    level_text := item->>'level';

    IF requested_type IS NULL
       OR requested_type NOT IN (
         'piyade','savunma','saldiri','okcu','tank','hava'
       )
       OR quantity_text IS NULL
       OR quantity_text !~ '^[1-9][0-9]*$'
       OR char_length(quantity_text) > 10
       OR level_text IS NULL
       OR level_text !~ '^[1-9][0-9]*$'
       OR char_length(level_text) > 2 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'NPC_CONFIG_INVALID',
        'message', 'NPC kamp ordusu yapılandırması geçersiz.'
      );
    END IF;

    requested_quantity := quantity_text::bigint;
    requested_level := level_text::integer;

    IF requested_quantity > 2147483647
       OR requested_level < 1
       OR requested_level > 15
       OR NOT EXISTS (
         SELECT 1
           FROM public.unit_levels ul
          WHERE ul.unit_type = requested_type
            AND ul.level = requested_level
       ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'NPC_CONFIG_INVALID',
        'message', 'NPC kamp ordusu yapılandırması geçersiz.'
      );
    END IF;
  END LOOP;

  IF v_camp.reward IS NULL
     OR jsonb_typeof(v_camp.reward) IS DISTINCT FROM 'object'
     OR EXISTS (
       SELECT 1
         FROM jsonb_each_text(v_camp.reward) AS r(key, value)
        WHERE key NOT IN ('metal','energy','water','crystal')
           OR value !~ '^[0-9]+$'
           OR char_length(value) > 12
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CONFIG_INVALID',
      'message', 'NPC kamp ödülü yapılandırması geçersiz.'
    );
  END IF;

  -- Validate and lock every live player-unit row before any deduction.
  FOR item IN
    SELECT value
      FROM jsonb_array_elements(p_army) AS army_item(value)
  LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz ordu bilgisi.'
      );
    END IF;

    requested_type := item->>'unit_type';
    quantity_text := item->>'quantity';
    level_text := item->>'level';

    IF requested_type IS NULL
       OR requested_type NOT IN (
         'piyade','savunma','saldiri','okcu','tank','hava'
       )
       OR quantity_text IS NULL
       OR quantity_text !~ '^[1-9][0-9]*$'
       OR char_length(quantity_text) > 10
       OR level_text IS NULL
       OR level_text !~ '^[1-9][0-9]*$'
       OR char_length(level_text) > 2 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz ordu bilgisi.'
      );
    END IF;

    requested_quantity := quantity_text::bigint;
    requested_level := level_text::integer;

    IF requested_quantity <= 0
       OR requested_quantity > 2147483647
       OR requested_level < 1
       OR requested_level > 15 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz birlik miktarı veya seviyesi.'
      );
    END IF;

    SELECT *
      INTO v_unit
      FROM public.units
     WHERE city_id = v_city.id
       AND unit_type = requested_type
     ORDER BY id
     LIMIT 1
     FOR UPDATE;

    IF v_unit.id IS NULL
       OR COALESCE(v_unit.quantity, 0) < requested_quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INSUFFICIENT_UNITS',
        'message', requested_type || ' için yeterli birlik yok.'
      );
    END IF;

    IF GREATEST(1, COALESCE(v_unit.level, 1)) <> requested_level THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'UNIT_CHANGED',
        'message', 'Birlik seviyesi değişti; orduyu yenileyip tekrar deneyin.'
      );
    END IF;
  END LOOP;

  -- Deduct the selected army exactly once.
  FOR item IN
    SELECT value
      FROM jsonb_array_elements(p_army) AS army_item(value)
  LOOP
    requested_type := item->>'unit_type';
    requested_quantity := (item->>'quantity')::bigint;

    SELECT id
      INTO unit_id
      FROM public.units
     WHERE city_id = v_city.id
       AND unit_type = requested_type
     ORDER BY id
     LIMIT 1;

    UPDATE public.units
       SET quantity = quantity - requested_quantity
     WHERE id = unit_id
       AND quantity >= requested_quantity;

    GET DIAGNOSTICS affected = ROW_COUNT;

    IF affected <> 1 THEN
      RAISE EXCEPTION
        'NPC seferi başlatılırken ordu miktarı beklenmedik biçimde değişti.';
    END IF;
  END LOOP;

  INSERT INTO public.npc_missions(
    player_id,
    city_id,
    npc_camp_id,
    status,
    depart_at,
    arrive_at,
    attack_power,
    defense_power,
    army,
    npc_army,
    reward_snapshot,
    camp_name,
    camp_tier,
    cooldown_seconds,
    depart_x,
    depart_y,
    target_x,
    target_y,
    travel_seconds,
    fleet_speed,
    battle_tactic,
    updated_at
  )
  VALUES(
    p_player_id,
    v_city.id,
    v_camp.id,
    'traveling',
    v_now,
    v_now + make_interval(secs => p_travel_seconds),
    p_attack_power,
    0,
    p_army,
    v_camp.army_template,
    v_camp.reward,
    v_site.name,
    v_camp.tier,
    v_camp.cooldown_seconds,
    p_depart_x,
    p_depart_y,
    v_site.coordinate_x,
    v_site.coordinate_y,
    p_travel_seconds,
    p_fleet_speed,
    v_tactic,
    v_now
  )
  RETURNING * INTO v_mission;

  RETURN jsonb_build_object(
    'success', true,
    'message', '⚔️ Ordu NPC kampına sefere çıktı.',
    'mission', to_jsonb(v_mission),
    'camp',
      jsonb_build_object(
        'id', v_camp.id,
        'worldSiteId', v_site.id,
        'name', v_site.name,
        'tier', v_camp.tier,
        'difficulty', v_camp.difficulty,
        'coordinateX', v_site.coordinate_x,
        'coordinateY', v_site.coordinate_y
      )
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 6) ATOMIC NPC BATTLE PREPARATION
--
-- Claims a due traveling mission into resolving, finalizes any attacker
-- research that became ready before the battle snapshot, then hydrates the
-- immutable NPC army snapshot from unit_levels.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_prepare_npc_battle_snapshot(
  p_player_id bigint,
  p_mission_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  probe public.npc_missions%ROWTYPE;
  mission public.npc_missions%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_research jsonb := '{}'::jsonb;
  v_now timestamptz;
  v_claim_traveling boolean := false;

  item jsonb;
  unit_type text;
  quantity_text text;
  level_text text;
  quantity bigint;
  unit_level integer;
  stats public.unit_levels%ROWTYPE;
  v_hydrated jsonb := '[]'::jsonb;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR p_mission_id IS NULL OR p_mission_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_MISSION',
      'message', 'Geçersiz PvE seferi.'
    );
  END IF;

  SELECT *
    INTO probe
    FROM public.npc_missions
   WHERE id = p_mission_id;

  IF probe.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'PvE seferi bulunamadı.'
    );
  END IF;

  IF probe.player_id IS DISTINCT FROM p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu PvE seferine erişemezsin.'
    );
  END IF;

  -- Same city lock used by start / return / training / colony movement.
  SELECT *
    INTO v_city
    FROM public.cities
   WHERE id = probe.city_id
     AND player_id = p_player_id
   FOR UPDATE;

  IF v_city.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  SELECT *
    INTO mission
    FROM public.npc_missions
   WHERE id = p_mission_id
   FOR UPDATE;

  IF mission.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'PvE seferi bulunamadı.'
    );
  END IF;

  IF mission.player_id IS DISTINCT FROM p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu PvE seferine erişemezsin.'
    );
  END IF;

  IF mission.status IN ('returning','completed') THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyResolved', true,
      'mission', to_jsonb(mission)
    );
  END IF;

  v_now := clock_timestamp();

  IF mission.arrive_at > v_now THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'BATTLE_NOT_READY',
      'message', 'PvE seferi henüz hedefe ulaşmadı.'
    );
  END IF;

  IF mission.status = 'traveling' THEN
    v_claim_traveling := true;
  ELSIF mission.status IS DISTINCT FROM 'resolving' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_STATE',
      'message', 'PvE seferi çözüm aşamasında değil.'
    );
  END IF;

  -- Mirror PvP battle-snapshot behavior for attacker research.
  PERFORM id
    FROM public.research
   WHERE player_id = p_player_id
   ORDER BY id
   FOR UPDATE;

  UPDATE public.research
     SET production_level = COALESCE(production_level, 0)
           + CASE WHEN pending_column = 'production_level' THEN 1 ELSE 0 END,
         combat_level = COALESCE(combat_level, 0)
           + CASE WHEN pending_column = 'combat_level' THEN 1 ELSE 0 END,
         defense_level = COALESCE(defense_level, 0)
           + CASE WHEN pending_column = 'defense_level' THEN 1 ELSE 0 END,
         crystal_level = COALESCE(crystal_level, 0)
           + CASE WHEN pending_column = 'crystal_level' THEN 1 ELSE 0 END,
         general_power_level = COALESCE(general_power_level, 0)
           + CASE WHEN pending_column = 'general_power_level' THEN 1 ELSE 0 END,
         unit_attack_level = COALESCE(unit_attack_level, 0)
           + CASE WHEN pending_column = 'unit_attack_level' THEN 1 ELSE 0 END,
         unit_defense_level = COALESCE(unit_defense_level, 0)
           + CASE WHEN pending_column = 'unit_defense_level' THEN 1 ELSE 0 END,
         unit_hp_level = COALESCE(unit_hp_level, 0)
           + CASE WHEN pending_column = 'unit_hp_level' THEN 1 ELSE 0 END,
         travel_speed_level = COALESCE(travel_speed_level, 0)
           + CASE WHEN pending_column = 'travel_speed_level' THEN 1 ELSE 0 END,
         upgrade_ready_at = NULL,
         pending_column = NULL
   WHERE player_id = p_player_id
     AND upgrade_ready_at IS NOT NULL
     AND upgrade_ready_at <= v_now
     AND pending_column IN (
       'production_level',
       'combat_level',
       'defense_level',
       'crystal_level',
       'general_power_level',
       'unit_attack_level',
       'unit_defense_level',
       'unit_hp_level',
       'travel_speed_level'
     );

  SELECT COALESCE(
           (
             SELECT to_jsonb(r)
               FROM public.research r
              WHERE r.player_id = p_player_id
              ORDER BY r.id
              LIMIT 1
           ),
           '{}'::jsonb
         )
    INTO v_research;

  FOR item IN
    SELECT value
      FROM jsonb_array_elements(mission.npc_army) AS npc_item(value)
  LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'NPC_CONFIG_INVALID',
        'message', 'NPC kamp ordusu yapılandırması geçersiz.'
      );
    END IF;

    unit_type := item->>'unit_type';
    quantity_text := item->>'quantity';
    level_text := item->>'level';

    IF unit_type IS NULL
       OR unit_type NOT IN (
         'piyade','savunma','saldiri','okcu','tank','hava'
       )
       OR quantity_text IS NULL
       OR quantity_text !~ '^[1-9][0-9]*$'
       OR level_text IS NULL
       OR level_text !~ '^[1-9][0-9]*$' THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'NPC_CONFIG_INVALID',
        'message', 'NPC kamp ordusu yapılandırması geçersiz.'
      );
    END IF;

    quantity := quantity_text::bigint;
    unit_level := level_text::integer;

    SELECT *
      INTO stats
      FROM public.unit_levels ul
     WHERE ul.unit_type = (item->>'unit_type')
       AND ul.level = (item->>'level')::integer
     LIMIT 1;

    IF stats.id IS NULL
       OR quantity <= 0
       OR quantity > 2147483647
       OR unit_level < 1
       OR unit_level > 15 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'NPC_CONFIG_INVALID',
        'message', 'NPC kamp ordusu yapılandırması geçersiz.'
      );
    END IF;

    v_hydrated :=
      v_hydrated
      ||
      jsonb_build_array(
        item
        ||
        jsonb_build_object(
          'attack', stats.attack,
          'defense', stats.defense,
          'hp', stats.hp,
          'speed', stats.speed,
          'population_cost',
            CASE item->>'unit_type'
              WHEN 'tank' THEN 3
              WHEN 'hava' THEN 2
              ELSE 1
            END
        )
      );

  END LOOP;

  IF v_claim_traveling THEN
    UPDATE public.npc_missions
       SET status = 'resolving',
           updated_at = v_now
     WHERE id = mission.id
       AND status = 'traveling'
     RETURNING * INTO mission;

    IF mission.id IS NULL THEN
      RAISE EXCEPTION 'PvE seferi çözüm durumuna alınamadı.';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyResolved', false,
    'mission', to_jsonb(mission),
    'snapshotAt', v_now,
    'attackerResearch', v_research,
    'npcArmy', v_hydrated,
    'rewardSnapshot', mission.reward_snapshot,
    'camp',
      jsonb_build_object(
        'id', mission.npc_camp_id,
        'name', mission.camp_name,
        'tier', mission.camp_tier,
        'targetX', mission.target_x,
        'targetY', mission.target_y
      )
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 7) ATOMIC NPC BATTLE SETTLEMENT
--
-- Combat math remains in the trusted backend, exactly like PvP. This RPC:
-- - validates result consistency against supplied attack/defense power,
-- - validates survivor/loss accounting against the immutable sent army,
-- - credits only the mission's server-snapshotted reward,
-- - respects current storage capacity,
-- - writes a PvE-only report,
-- - starts the return timer,
-- - starts player-specific camp cooldown exactly once.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_resolve_npc_mission(
  p_player_id bigint,
  p_mission_id bigint,
  p_npc_losses jsonb,
  p_report_base jsonb,
  p_attack_power integer,
  p_defense_power integer,
  p_return_seconds integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  probe public.npc_missions%ROWTYPE;
  mission public.npc_missions%ROWTYPE;
  v_city public.cities%ROWTYPE;

  v_result text;
  v_expected_result text;

  survivor_item jsonb;
  original_item jsonb;
  survivor_count integer;
  survivor_distinct integer;
  survivor_type text;
  survivor_quantity_text text;
  survivor_level_text text;
  survivor_quantity bigint;
  survivor_level integer;

  original_type text;
  original_quantity bigint;
  original_level integer;

  loss_key text;
  loss_text text;
  loss_quantity bigint;

  npc_item jsonb;
  npc_type text;
  npc_quantity bigint;

  resource_name text;
  reward_text text;
  reward_amount bigint;
  current_amount bigint;
  capacity bigint;
  credit_amount bigint;
  credited_reward jsonb :=
    '{"metal":0,"energy":0,"water":0,"crystal":0}'::jsonb;

  v_battle_at timestamptz;
  v_return_at timestamptz;
  v_available_at timestamptz;

  v_report jsonb;
  v_report_id bigint;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR p_mission_id IS NULL OR p_mission_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_MISSION',
      'message', 'Geçersiz PvE seferi.'
    );
  END IF;

  IF p_attack_power IS NULL OR p_attack_power < 0
     OR p_defense_power IS NULL OR p_defense_power < 0
     OR p_return_seconds IS NULL
     OR p_return_seconds < 1
     OR p_return_seconds > 86400 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_RESULT',
      'message', 'Geçersiz PvE savaş sonucu.'
    );
  END IF;

  IF p_report_base IS NULL
     OR jsonb_typeof(p_report_base) IS DISTINCT FROM 'object'
     OR jsonb_typeof(
          COALESCE(p_report_base->'attackerLosses', '{}'::jsonb)
        ) IS DISTINCT FROM 'object'
     OR jsonb_typeof(
          COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
        ) IS DISTINCT FROM 'array'
     OR p_npc_losses IS NULL
     OR jsonb_typeof(p_npc_losses) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_REPORT',
      'message', 'Geçersiz PvE savaş raporu.'
    );
  END IF;

  SELECT *
    INTO probe
    FROM public.npc_missions
   WHERE id = p_mission_id;

  IF probe.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'PvE seferi bulunamadı.'
    );
  END IF;

  IF probe.player_id IS DISTINCT FROM p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu PvE seferine erişemezsin.'
    );
  END IF;

  SELECT *
    INTO v_city
    FROM public.cities
   WHERE id = probe.city_id
     AND player_id = p_player_id
   FOR UPDATE;

  IF v_city.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  SELECT *
    INTO mission
    FROM public.npc_missions
   WHERE id = p_mission_id
   FOR UPDATE;

  IF mission.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'PvE seferi bulunamadı.'
    );
  END IF;

  IF mission.player_id IS DISTINCT FROM p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu PvE seferine erişemezsin.'
    );
  END IF;

  IF mission.status IN ('returning','completed') THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyResolved', true,
      'mission', to_jsonb(mission),
      'reward',
        COALESCE(
          mission.settled_reward,
          mission.result->'reward',
          credited_reward
        )
    );
  END IF;

  IF mission.status IS DISTINCT FROM 'resolving' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_STATE',
      'message', 'PvE seferi çözüm aşamasında değil.'
    );
  END IF;

  IF mission.arrive_at > clock_timestamp() THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'BATTLE_NOT_READY',
      'message', 'PvE seferi henüz hedefe ulaşmadı.'
    );
  END IF;

  v_result := p_report_base->>'result';

  IF v_result IS NULL
     OR v_result NOT IN ('Zafer','Yenilgi','Beraberlik') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_RESULT',
      'message', 'Geçersiz PvE savaş sonucu.'
    );
  END IF;

  v_expected_result := CASE
    WHEN p_attack_power > p_defense_power THEN 'Zafer'
    WHEN p_attack_power < p_defense_power THEN 'Yenilgi'
    ELSE 'Beraberlik'
  END;

  IF v_result IS DISTINCT FROM v_expected_result THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_RESULT',
      'message', 'PvE savaş sonucu güç değerleriyle uyuşmuyor.'
    );
  END IF;

  -- Validate survivor array shape and duplicate types.
  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
    INTO survivor_count, survivor_distinct
    FROM jsonb_array_elements(
      COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
    ) AS survivor(value);

  IF survivor_distinct <> survivor_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_SURVIVORS',
      'message', 'Dönüş ordusunda tekrarlanan birlik türü var.'
    );
  END IF;

  FOR survivor_item IN
    SELECT value
      FROM jsonb_array_elements(
        COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
      ) AS survivor(value)
  LOOP
    IF jsonb_typeof(survivor_item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_SURVIVORS',
        'message', 'Geçersiz dönüş ordusu.'
      );
    END IF;

    survivor_type := survivor_item->>'unit_type';
    survivor_quantity_text := survivor_item->>'quantity';
    survivor_level_text := survivor_item->>'level';

    IF survivor_type IS NULL
       OR survivor_type NOT IN (
         'piyade','savunma','saldiri','okcu','tank','hava'
       )
       OR survivor_quantity_text IS NULL
       OR survivor_quantity_text !~ '^[0-9]+$'
       OR char_length(survivor_quantity_text) > 10
       OR survivor_level_text IS NULL
       OR survivor_level_text !~ '^[1-9][0-9]*$'
       OR char_length(survivor_level_text) > 2 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_SURVIVORS',
        'message', 'Geçersiz dönüş ordusu.'
      );
    END IF;

    survivor_quantity := survivor_quantity_text::bigint;
    survivor_level := survivor_level_text::integer;

    IF survivor_quantity > 2147483647
       OR survivor_level < 1
       OR survivor_level > 15
       OR NOT EXISTS (
         SELECT 1
           FROM jsonb_array_elements(mission.army) original(value)
          WHERE value->>'unit_type' = survivor_type
            AND (value->>'level')::integer = survivor_level
            AND (value->>'quantity')::bigint >= survivor_quantity
       ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_SURVIVORS',
        'message', 'Dönüş ordusu gönderilen ordudan büyük veya uyumsuz.'
      );
    END IF;
  END LOOP;

  -- Loss object may only contain valid unit types and non-negative integers.
  IF EXISTS (
    SELECT 1
      FROM jsonb_each_text(
        COALESCE(p_report_base->'attackerLosses', '{}'::jsonb)
      ) AS losses(key, value)
     WHERE key NOT IN (
       'piyade','savunma','saldiri','okcu','tank','hava'
     )
        OR value !~ '^[0-9]+$'
        OR char_length(value) > 10
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_LOSSES',
      'message', 'Geçersiz saldıran kaybı.'
    );
  END IF;

  -- Exact accounting: survivor + attacker loss must equal each sent quantity.
  FOR original_item IN
    SELECT value
      FROM jsonb_array_elements(mission.army) original(value)
  LOOP
    original_type := original_item->>'unit_type';
    original_quantity := (original_item->>'quantity')::bigint;
    original_level := (original_item->>'level')::integer;

    SELECT COALESCE(MAX((value->>'quantity')::bigint), 0)
      INTO survivor_quantity
      FROM jsonb_array_elements(
        COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
      ) survivor(value)
     WHERE value->>'unit_type' = original_type
       AND (value->>'level')::integer = original_level;

    loss_text :=
      COALESCE(
        p_report_base->'attackerLosses'->>original_type,
        '0'
      );

    IF loss_text !~ '^[0-9]+$'
       OR char_length(loss_text) > 10 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_LOSSES',
        'message', 'Geçersiz saldıran kaybı.'
      );
    END IF;

    loss_quantity := loss_text::bigint;

    IF loss_quantity > 2147483647
       OR survivor_quantity + loss_quantity <> original_quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ACCOUNTING',
        'message', 'Saldıran kayıp ve sağ kalan hesabı uyuşmuyor.'
      );
    END IF;
  END LOOP;

  -- No positive attacker-loss entry may reference a unit type that was not sent.
  IF EXISTS (
    SELECT 1
      FROM jsonb_each_text(
        COALESCE(p_report_base->'attackerLosses', '{}'::jsonb)
      ) losses(key, value)
     WHERE value::bigint > 0
       AND NOT EXISTS (
         SELECT 1
           FROM jsonb_array_elements(mission.army) original(item)
          WHERE item->>'unit_type' = key
       )
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_LOSSES',
      'message', 'Gönderilmeyen birlik türü için kayıp bildirildi.'
    );
  END IF;

  -- Validate NPC loss reporting against the immutable NPC snapshot.
  IF EXISTS (
    SELECT 1
      FROM jsonb_each_text(p_npc_losses) losses(key, value)
     WHERE key NOT IN (
       'piyade','savunma','saldiri','okcu','tank','hava'
     )
        OR value !~ '^[0-9]+$'
        OR char_length(value) > 10
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_NPC_LOSSES',
      'message', 'Geçersiz NPC kaybı.'
    );
  END IF;

  FOR loss_key, loss_text IN
    SELECT key, value
      FROM jsonb_each_text(p_npc_losses)
  LOOP
    loss_quantity := loss_text::bigint;

    IF loss_quantity > 2147483647 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_NPC_LOSSES',
        'message', 'Geçersiz NPC kaybı.'
      );
    END IF;

    SELECT value
      INTO npc_item
      FROM jsonb_array_elements(mission.npc_army) npc(value)
     WHERE value->>'unit_type' = loss_key
     LIMIT 1;

    IF npc_item IS NULL THEN
      IF loss_quantity > 0 THEN
        RETURN jsonb_build_object(
          'success', false,
          'code', 'INVALID_NPC_LOSSES',
          'message', 'NPC ordusunda olmayan birlik türü için kayıp bildirildi.'
        );
      END IF;
      CONTINUE;
    END IF;

    npc_type := npc_item->>'unit_type';
    npc_quantity := (npc_item->>'quantity')::bigint;

    IF npc_type IS DISTINCT FROM loss_key
       OR loss_quantity > npc_quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_NPC_LOSSES',
        'message', 'NPC kaybı mevcut birlikten fazla.'
      );
    END IF;
  END LOOP;

  -- Validate immutable reward snapshot before any credit.
  IF mission.reward_snapshot IS NULL
     OR jsonb_typeof(mission.reward_snapshot) IS DISTINCT FROM 'object'
     OR EXISTS (
       SELECT 1
         FROM jsonb_each_text(mission.reward_snapshot) r(key, value)
        WHERE key NOT IN ('metal','energy','water','crystal')
           OR value !~ '^[0-9]+$'
           OR char_length(value) > 12
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_REWARD_INVALID',
      'message', 'NPC ödül yapılandırması geçersiz.'
    );
  END IF;

  -- Only victories credit reward. Capacity overflow is not credited and is
  -- recorded as such in settled_reward.
  IF v_result = 'Zafer' THEN
    FOREACH resource_name IN ARRAY
      ARRAY['metal','energy','water','crystal']
    LOOP
      reward_text :=
        COALESCE(mission.reward_snapshot->>resource_name, '0');

      IF reward_text !~ '^[0-9]+$'
         OR char_length(reward_text) > 12 THEN
        RETURN jsonb_build_object(
          'success', false,
          'code', 'NPC_REWARD_INVALID',
          'message', 'NPC ödül yapılandırması geçersiz.'
        );
      END IF;

      reward_amount := reward_text::bigint;

      current_amount := CASE resource_name
        WHEN 'metal' THEN GREATEST(0, COALESCE(v_city.metal, 0))
        WHEN 'energy' THEN GREATEST(0, COALESCE(v_city.energy, 0))
        WHEN 'water' THEN GREATEST(0, COALESCE(v_city.water, 0))
        WHEN 'crystal' THEN GREATEST(0, COALESCE(v_city.crystal, 0))
        ELSE 0
      END;

      capacity :=
        public.nexora_trade_storage_capacity(
          v_city.id,
          resource_name
        );

      credit_amount :=
        LEAST(
          reward_amount,
          GREATEST(0, capacity - current_amount)
        );

      IF credit_amount > 0 THEN
        EXECUTE format(
          'UPDATE public.cities
              SET %1$I = COALESCE(%1$I,0) + $1,
                  updated_at = clock_timestamp()
            WHERE id = $2',
          resource_name
        )
        USING credit_amount, v_city.id;
      END IF;

      credited_reward :=
        jsonb_set(
          credited_reward,
          ARRAY[resource_name],
          to_jsonb(credit_amount),
          true
        );
    END LOOP;
  END IF;

  v_battle_at := clock_timestamp();
  v_return_at :=
    v_battle_at + make_interval(secs => p_return_seconds);
  v_available_at :=
    v_battle_at + make_interval(secs => mission.cooldown_seconds);

  v_report :=
    p_report_base
    ||
    jsonb_build_object(
      'result', v_expected_result,
      'attackPower', p_attack_power,
      'defensePower', p_defense_power,
      'npcLosses', p_npc_losses,
      'configuredReward', mission.reward_snapshot,
      'reward', credited_reward,
      'campId', mission.npc_camp_id,
      'campName', mission.camp_name,
      'campTier', mission.camp_tier,
      'battleTactic', mission.battle_tactic,
      'battleAt', v_battle_at,
      'returnAt', v_return_at,
      'campAvailableAt', v_available_at
    );

  INSERT INTO public.npc_battle_reports(
    npc_mission_id,
    player_id,
    npc_camp_id,
    camp_name,
    camp_tier,
    result,
    attack_power,
    defense_power,
    attacker_losses,
    npc_losses,
    reward,
    battle_tactic,
    report,
    created_at
  )
  VALUES(
    mission.id,
    p_player_id,
    mission.npc_camp_id,
    mission.camp_name,
    mission.camp_tier,
    v_expected_result,
    p_attack_power,
    p_defense_power,
    COALESCE(p_report_base->'attackerLosses', '{}'::jsonb),
    p_npc_losses,
    credited_reward,
    mission.battle_tactic,
    v_report,
    v_battle_at
  )
  RETURNING id INTO v_report_id;

  INSERT INTO public.player_npc_camp_state AS state(
    player_id,
    npc_camp_id,
    victories,
    defeats,
    draws,
    last_battle_at,
    available_at,
    updated_at
  )
  VALUES(
    p_player_id,
    mission.npc_camp_id,
    CASE WHEN v_expected_result = 'Zafer' THEN 1 ELSE 0 END,
    CASE WHEN v_expected_result = 'Yenilgi' THEN 1 ELSE 0 END,
    CASE WHEN v_expected_result = 'Beraberlik' THEN 1 ELSE 0 END,
    v_battle_at,
    v_available_at,
    v_battle_at
  )
  ON CONFLICT (player_id, npc_camp_id)
  DO UPDATE SET
    victories =
      state.victories
      + CASE WHEN v_expected_result = 'Zafer' THEN 1 ELSE 0 END,
    defeats =
      state.defeats
      + CASE WHEN v_expected_result = 'Yenilgi' THEN 1 ELSE 0 END,
    draws =
      state.draws
      + CASE WHEN v_expected_result = 'Beraberlik' THEN 1 ELSE 0 END,
    last_battle_at = v_battle_at,
    available_at = v_available_at,
    updated_at = v_battle_at;

  UPDATE public.npc_missions
     SET status = 'returning',
         arrive_at = v_return_at,
         attack_power = p_attack_power,
         defense_power = p_defense_power,
         result = v_report,
         settled_reward = credited_reward,
         updated_at = v_battle_at
   WHERE id = mission.id
   RETURNING * INTO mission;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyResolved', false,
    'mission', to_jsonb(mission),
    'npcBattleReportId', v_report_id,
    'reward', credited_reward,
    'campAvailableAt', v_available_at
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 8) ATOMIC NPC SURVIVOR RETURN
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_complete_npc_return(
  p_player_id bigint,
  p_mission_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  probe public.npc_missions%ROWTYPE;
  mission public.npc_missions%ROWTYPE;
  v_city public.cities%ROWTYPE;

  survivor jsonb;
  survivor_type text;
  quantity_text text;
  level_text text;
  survivor_quantity bigint;
  survivor_level integer;

  existing public.units%ROWTYPE;
  stats public.unit_levels%ROWTYPE;
  population_cost integer;

  survivor_count integer;
  survivor_distinct integer;
  remaining_seconds integer;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR p_mission_id IS NULL OR p_mission_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_MISSION',
      'message', 'Geçersiz PvE seferi.'
    );
  END IF;

  SELECT *
    INTO probe
    FROM public.npc_missions
   WHERE id = p_mission_id;

  IF probe.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'PvE seferi bulunamadı.'
    );
  END IF;

  IF probe.player_id IS DISTINCT FROM p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu PvE seferine erişemezsin.'
    );
  END IF;

  SELECT *
    INTO v_city
    FROM public.cities
   WHERE id = probe.city_id
     AND player_id = p_player_id
   FOR UPDATE;

  IF v_city.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  SELECT *
    INTO mission
    FROM public.npc_missions
   WHERE id = p_mission_id
   FOR UPDATE;

  IF mission.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'PvE seferi bulunamadı.'
    );
  END IF;

  IF mission.player_id IS DISTINCT FROM p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu PvE seferine erişemezsin.'
    );
  END IF;

  IF mission.status = 'completed' THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyCompleted', true,
      'mission', to_jsonb(mission)
    );
  END IF;

  IF mission.status IS DISTINCT FROM 'returning' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_STATE',
      'message', 'PvE ordusu henüz dönüş aşamasında değil.'
    );
  END IF;

  IF mission.arrive_at > clock_timestamp() THEN
    remaining_seconds := GREATEST(
      1,
      CEIL(
        EXTRACT(EPOCH FROM (mission.arrive_at - clock_timestamp()))
      )::integer
    );

    RETURN jsonb_build_object(
      'success', true,
      'completed', false,
      'mission', to_jsonb(mission),
      'remainingSeconds', remaining_seconds
    );
  END IF;

  IF mission.result IS NULL
     OR jsonb_typeof(mission.result) IS DISTINCT FROM 'object'
     OR jsonb_typeof(
          COALESCE(mission.result->'survivorArmy', '[]'::jsonb)
        ) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'NPC dönüş ordusu bulunamadı veya geçersiz.';
  END IF;

  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
    INTO survivor_count, survivor_distinct
    FROM jsonb_array_elements(
      COALESCE(mission.result->'survivorArmy', '[]'::jsonb)
    ) survivor(value);

  IF survivor_count <> survivor_distinct THEN
    RAISE EXCEPTION 'NPC dönüş ordusunda tekrarlanan birlik türü var.';
  END IF;

  FOR survivor IN
    SELECT value
      FROM jsonb_array_elements(
        COALESCE(mission.result->'survivorArmy', '[]'::jsonb)
      ) survivor_row(value)
  LOOP
    IF jsonb_typeof(survivor) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'Geçersiz NPC dönüş ordusu.';
    END IF;

    survivor_type := survivor->>'unit_type';
    quantity_text := survivor->>'quantity';
    level_text := survivor->>'level';

    IF survivor_type IS NULL
       OR survivor_type NOT IN (
         'piyade','savunma','saldiri','okcu','tank','hava'
       )
       OR quantity_text IS NULL
       OR quantity_text !~ '^[0-9]+$'
       OR char_length(quantity_text) > 10
       OR level_text IS NULL
       OR level_text !~ '^[1-9][0-9]*$'
       OR char_length(level_text) > 2 THEN
      RAISE EXCEPTION 'Geçersiz NPC dönüş ordusu.';
    END IF;

    survivor_quantity := quantity_text::bigint;
    survivor_level := level_text::integer;

    IF survivor_quantity > 2147483647
       OR survivor_level < 1
       OR survivor_level > 15 THEN
      RAISE EXCEPTION 'Geçersiz NPC dönüş ordusu.';
    END IF;

    IF survivor_quantity = 0 THEN
      CONTINUE;
    END IF;

    SELECT *
      INTO stats
      FROM public.unit_levels ul
     WHERE ul.unit_type = survivor_type
       AND ul.level = survivor_level
     LIMIT 1;

    IF stats.id IS NULL THEN
      RAISE EXCEPTION 'NPC dönüş birlik seviyesi bulunamadı.';
    END IF;

    population_cost := CASE survivor_type
      WHEN 'tank' THEN 3
      WHEN 'hava' THEN 2
      ELSE 1
    END;

    SELECT *
      INTO existing
      FROM public.units
     WHERE city_id = mission.city_id
       AND unit_type = survivor_type
     ORDER BY id
     LIMIT 1
     FOR UPDATE;

    IF existing.id IS NOT NULL THEN
      UPDATE public.units
         SET quantity = COALESCE(quantity, 0) + survivor_quantity
       WHERE id = existing.id;
    ELSE
      INSERT INTO public.units(
        city_id,
        unit_type,
        quantity,
        level,
        attack,
        defense,
        hp,
        speed,
        population_cost
      )
      VALUES(
        mission.city_id,
        survivor_type,
        survivor_quantity,
        survivor_level,
        stats.attack,
        stats.defense,
        stats.hp,
        stats.speed,
        population_cost
      );
    END IF;

  END LOOP;

  UPDATE public.npc_missions
     SET status = 'completed',
         completed_at = clock_timestamp(),
         updated_at = clock_timestamp()
   WHERE id = mission.id
   RETURNING * INTO mission;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyCompleted', false,
    'completed', true,
    'mission', to_jsonb(mission)
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 9) ACTIVE ARMY CAPACITY NOW INCLUDES PvP + PvE
--
-- Existing training RPCs already call this helper, including bulk training.
-- Returning missions reserve only surviving units.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_active_military_population(
  p_player_id bigint
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  mission record;
  mission_population bigint;
  total numeric := 0;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN 0;
  END IF;

  FOR mission IN
    SELECT status, army, result
      FROM public.military_missions
     WHERE attacker_player_id = p_player_id
       AND status IN ('traveling','resolving','returning')

    UNION ALL

    SELECT status, army, result
      FROM public.npc_missions
     WHERE player_id = p_player_id
       AND status IN ('traveling','resolving','returning')
  LOOP
    mission_population := NULL;

    IF mission.status = 'returning'
       AND jsonb_typeof(mission.result) = 'object'
       AND jsonb_typeof(mission.result->'survivorArmy') = 'array' THEN
      mission_population :=
        public.nexora_military_army_population(
          mission.result->'survivorArmy'
        );
    END IF;

    IF mission_population IS NULL THEN
      mission_population :=
        public.nexora_military_army_population(mission.army);
    END IF;

    total := total + COALESCE(mission_population, 0);
  END LOOP;

  RETURN LEAST(
    total,
    9223372036854775807::numeric
  )::bigint;
END;
$$;

-- -----------------------------------------------------------------------------
-- 10) COLONY MOVEMENT MUST ALSO RESPECT ACTIVE PvE MISSIONS
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_move_colony_atomic(
  p_player_id bigint,
  p_x integer,
  p_y integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_city public.cities%ROWTYPE;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  IF p_x IS NULL OR p_y IS NULL
     OR p_x NOT BETWEEN 1 AND 100
     OR p_y NOT BETWEEN 1 AND 100 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_COORDINATE',
      'message', 'X ve Y koordinatları 1-100 arasında tam sayı olmalı.'
    );
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('nexora_city_spawn'));

  SELECT *
    INTO v_city
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF v_city.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  IF COALESCE(v_city.coordinate_x, 0) = p_x
     AND COALESCE(v_city.coordinate_y, 0) = p_y THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SAME_COORDINATE',
      'message', 'Zaten bu koordinattasın.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.military_missions
     WHERE attacker_player_id = p_player_id
       AND status IN ('traveling','resolving','returning')
     LIMIT 1
  )
  OR EXISTS (
    SELECT 1
      FROM public.npc_missions
     WHERE player_id = p_player_id
       AND status IN ('traveling','resolving','returning')
     LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVE_MISSION',
      'message', 'Aktif sefer varken koloni koordinatı değiştirilemez.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.world_sites
     WHERE active = true
       AND coordinate_x = p_x
       AND coordinate_y = p_y
     LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WORLD_SITE_OCCUPIED',
      'message', 'Bu koordinatta aktif bir dünya noktası bulunuyor.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.cities
     WHERE id <> v_city.id
       AND coordinate_x = p_x
       AND coordinate_y = p_y
     LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'COORDINATE_OCCUPIED',
      'message', 'Bu koordinat dolu.'
    );
  END IF;

  UPDATE public.cities
     SET coordinate_x = p_x,
         coordinate_y = p_y,
         updated_at = clock_timestamp()
   WHERE id = v_city.id
   RETURNING * INTO v_city;

  RETURN jsonb_build_object(
    'success', true,
    'code', 'MOVED',
    'message', 'Koloni taşındı.',
    'city', to_jsonb(v_city)
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 11) GAME OBJECTIVES: "battles_won" = PvP wins + PvE wins
--
-- PvE reports remain separate, therefore rankings that read battle_reports are
-- unchanged and cannot be farmed through NPC camps.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_progress_value(
  p_player_id bigint,
  p_metric_key text
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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

    ELSE
      v_value := 0;
  END CASE;

  RETURN GREATEST(COALESCE(v_value, 0), 0);
END;
$$;

-- -----------------------------------------------------------------------------
-- 12) FUNCTION PERMISSIONS
-- -----------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.nexora_claim_world_site(bigint,bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_claim_world_site(bigint,bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_world_control_sites(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_world_control_sites(bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_start_world_exploration(
  bigint,bigint,integer,numeric
)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_start_world_exploration(
  bigint,bigint,integer,numeric
)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_npc_camps_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_npc_camps_snapshot(bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_start_npc_mission(
  bigint,bigint,bigint,jsonb,integer,integer,integer,integer,numeric,text
)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_start_npc_mission(
  bigint,bigint,bigint,jsonb,integer,integer,integer,integer,numeric,text
)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_prepare_npc_battle_snapshot(
  bigint,bigint
)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_prepare_npc_battle_snapshot(
  bigint,bigint
)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_resolve_npc_mission(
  bigint,bigint,jsonb,jsonb,integer,integer,integer
)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_resolve_npc_mission(
  bigint,bigint,jsonb,jsonb,integer,integer,integer
)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_complete_npc_return(bigint,bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_complete_npc_return(bigint,bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_active_military_population(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_active_military_population(bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_move_colony_atomic(
  bigint,integer,integer
)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_move_colony_atomic(
  bigint,integer,integer
)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_progress_value(bigint,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_progress_value(bigint,text)
  TO service_role;

COMMIT;
