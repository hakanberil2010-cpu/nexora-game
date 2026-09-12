-- NEXORA PHASE 5 – keşif görevleri + atomik ittifak işlemleri
-- Mevcut production verisini korur. DROP/TRUNCATE içermez.
-- Önce bu migration uygulanmalı, ardından Phase 5 api/auth.js yüklenmelidir.

-- -----------------------------------------------------------------------------
-- 1) WORLD SITES: mevcut reward JSON alanını koru, eski/taslak reward_* biçimini
--    de okuyabilmek için yalnızca eksik uyumluluk kolonlarını ekle.
-- -----------------------------------------------------------------------------
ALTER TABLE world_sites
  ADD COLUMN IF NOT EXISTS description text,
  ADD COLUMN IF NOT EXISTS reward jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS reward_metal integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reward_energy integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reward_water integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reward_crystal integer NOT NULL DEFAULT 0;

ALTER TABLE cities
  ADD COLUMN IF NOT EXISTS last_explored_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_exploration_at timestamptz;

CREATE TABLE IF NOT EXISTS world_exploration_missions (
  id bigserial PRIMARY KEY,
  player_id bigint NOT NULL,
  city_id bigint NOT NULL,
  site_id bigint NOT NULL REFERENCES world_sites(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'traveling',
  depart_at timestamptz NOT NULL DEFAULT now(),
  arrive_at timestamptz NOT NULL,
  completed_at timestamptz,
  distance numeric NOT NULL DEFAULT 0,
  travel_seconds integer NOT NULL DEFAULT 0,
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Eğer tablo daha önce taslak olarak oluşturulduysa eksik kolonları güvenle tamamla.
ALTER TABLE world_exploration_missions
  ADD COLUMN IF NOT EXISTS player_id bigint,
  ADD COLUMN IF NOT EXISTS city_id bigint,
  ADD COLUMN IF NOT EXISTS site_id bigint,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'traveling',
  ADD COLUMN IF NOT EXISTS depart_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS arrive_at timestamptz,
  ADD COLUMN IF NOT EXISTS completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS distance numeric DEFAULT 0,
  ADD COLUMN IF NOT EXISTS travel_seconds integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS result jsonb,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_world_explore_player_status
  ON world_exploration_missions(player_id, status, arrive_at);

CREATE INDEX IF NOT EXISTS idx_world_explore_city_status
  ON world_exploration_missions(city_id, status, arrive_at);

-- -----------------------------------------------------------------------------
-- 2) ATOMİK KEŞİF BAŞLATMA
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
SET search_path = public
AS $$
DECLARE
  v_city cities%ROWTYPE;
  v_site world_sites%ROWTYPE;
  v_existing world_exploration_missions%ROWTYPE;
  v_mission world_exploration_missions%ROWTYPE;
  v_last timestamptz;
  v_remaining integer;
  v_seconds integer;
  v_distance numeric;
BEGIN
  SELECT *
    INTO v_city
    FROM cities
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
    FROM world_sites
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
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_DISABLED',
      'message', 'İttifak bölgeleri henüz keşfe açık değil.'
    );
  END IF;

  SELECT *
    INTO v_existing
    FROM world_exploration_missions
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

  UPDATE cities
     SET last_exploration_at = now(),
         last_explored_at = now()
   WHERE id = v_city.id;

  INSERT INTO world_exploration_missions(
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

-- -----------------------------------------------------------------------------
-- 3) ATOMİK KEŞİF SONUÇLANDIRMA
-- Aynı mission birden fazla kez sorgulansa bile ödül yalnızca bir kez eklenir.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.nexora_resolve_world_exploration(
  p_player_id bigint,
  p_mission_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_mission world_exploration_missions%ROWTYPE;
  v_city cities%ROWTYPE;
  v_site world_sites%ROWTYPE;
  v_depo_level integer := 0;
  v_crystal_depo_level integer := 0;
  v_storage bigint;
  v_crystal_storage bigint;
  v_reward_metal bigint := 0;
  v_reward_energy bigint := 0;
  v_reward_water bigint := 0;
  v_reward_crystal bigint := 0;
  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_water bigint := 0;
  v_credit_crystal bigint := 0;
  v_result jsonb;
  v_remaining integer;
BEGIN
  SELECT *
    INTO v_mission
    FROM world_exploration_missions
   WHERE id = p_mission_id
     AND player_id = p_player_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'Keşif görevi bulunamadı.'
    );
  END IF;

  IF v_mission.status = 'completed' THEN
    RETURN jsonb_build_object(
      'success', true,
      'mission', jsonb_build_object(
        'id', v_mission.id,
        'status', 'completed',
        'arriveAt', v_mission.arrive_at,
        'remainingSeconds', 0,
        'result', COALESCE(v_mission.result, '{}'::jsonb)
      )
    );
  END IF;

  IF v_mission.arrive_at > now() THEN
    v_remaining := GREATEST(
      0,
      CEIL(EXTRACT(EPOCH FROM (v_mission.arrive_at - now())))::integer
    );

    RETURN jsonb_build_object(
      'success', true,
      'mission', jsonb_build_object(
        'id', v_mission.id,
        'status', 'traveling',
        'arriveAt', v_mission.arrive_at,
        'remainingSeconds', v_remaining,
        'result', COALESCE(v_mission.result, '{}'::jsonb)
      )
    );
  END IF;

  UPDATE world_exploration_missions
     SET status = 'resolving'
   WHERE id = v_mission.id;

  SELECT *
    INTO v_site
    FROM world_sites
   WHERE id = v_mission.site_id
   LIMIT 1;

  IF NOT FOUND THEN
    UPDATE world_exploration_missions
       SET status = 'traveling'
     WHERE id = v_mission.id;

    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_NOT_FOUND',
      'message', 'Keşif noktası artık bulunamıyor.'
    );
  END IF;

  SELECT *
    INTO v_city
    FROM cities
   WHERE id = v_mission.city_id
     AND player_id = p_player_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    UPDATE world_exploration_missions
       SET status = 'traveling'
     WHERE id = v_mission.id;

    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Keşif görevine ait koloni bulunamadı.'
    );
  END IF;

  SELECT
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Depo'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Kristal Deposu'), 0)
  INTO v_depo_level, v_crystal_depo_level
  FROM buildings
  WHERE city_id = v_city.id;

  v_storage := 5000 + GREATEST(0, v_depo_level) * 2500;
  v_crystal_storage := 3000 + GREATEST(0, v_crystal_depo_level) * 1500;

  -- Öncelik mevcut production reward JSON alanındadır.
  -- JSON anahtarı yoksa taslak/eski reward_* kolonlarına düşer.
  v_reward_metal := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'metal', '')::bigint, v_site.reward_metal, 0));
  v_reward_energy := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'energy', '')::bigint, v_site.reward_energy, 0));
  v_reward_water := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'water', '')::bigint, v_site.reward_water, 0));
  v_reward_crystal := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'crystal', '')::bigint, v_site.reward_crystal, 0));

  v_credit_metal := LEAST(v_reward_metal, GREATEST(0, v_storage - COALESCE(v_city.metal, 0)));
  v_credit_energy := LEAST(v_reward_energy, GREATEST(0, v_storage - COALESCE(v_city.energy, 0)));
  v_credit_water := LEAST(v_reward_water, GREATEST(0, v_storage - COALESCE(v_city.water, 0)));
  v_credit_crystal := LEAST(v_reward_crystal, GREATEST(0, v_crystal_storage - COALESCE(v_city.crystal, 0)));

  UPDATE cities
     SET metal = COALESCE(metal, 0) + v_credit_metal,
         energy = COALESCE(energy, 0) + v_credit_energy,
         water = COALESCE(water, 0) + v_credit_water,
         crystal = COALESCE(crystal, 0) + v_credit_crystal
   WHERE id = v_city.id;

  v_result := jsonb_build_object(
    'message', v_site.name || ' keşfi tamamlandı.',
    'siteId', v_site.id,
    'siteName', v_site.name,
    'siteType', v_site.site_type,
    'reward', jsonb_build_object(
      'metal', v_credit_metal,
      'energy', v_credit_energy,
      'water', v_credit_water,
      'crystal', v_credit_crystal
    ),
    'rewardRequested', jsonb_build_object(
      'metal', v_reward_metal,
      'energy', v_reward_energy,
      'water', v_reward_water,
      'crystal', v_reward_crystal
    )
  );

  UPDATE world_exploration_missions
     SET status = 'completed',
         completed_at = now(),
         result = v_result
   WHERE id = v_mission.id;

  RETURN jsonb_build_object(
    'success', true,
    'mission', jsonb_build_object(
      'id', v_mission.id,
      'status', 'completed',
      'arriveAt', v_mission.arrive_at,
      'remainingSeconds', 0,
      'result', v_result
    )
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 4) ATOMİK İTTİFAKTAN AYRILMA / LİDERLİK DEVRİ
-- Lider tek üyeyse ittifak silinir; başka üye varsa en eski üyelik id'si lider olur.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.nexora_leave_alliance(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_member alliance_members%ROWTYPE;
  v_alliance alliances%ROWTYPE;
  v_next alliance_members%ROWTYPE;
BEGIN
  SELECT *
    INTO v_member
    FROM alliance_members
   WHERE player_id = p_player_id
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
    INTO v_alliance
    FROM alliances
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

  IF v_member.role <> 'leader' THEN
    DELETE FROM alliance_members WHERE id = v_member.id;

    RETURN jsonb_build_object(
      'success', true,
      'action', 'left',
      'message', 'İttifaktan ayrıldın.'
    );
  END IF;

  SELECT *
    INTO v_next
    FROM alliance_members
   WHERE alliance_id = v_member.alliance_id
     AND player_id <> p_player_id
   ORDER BY id ASC
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    DELETE FROM alliance_members WHERE id = v_member.id;
    DELETE FROM alliances WHERE id = v_member.alliance_id;

    RETURN jsonb_build_object(
      'success', true,
      'action', 'deleted',
      'message', 'Son üye olarak ayrıldığın için ittifak kapatıldı.'
    );
  END IF;

  UPDATE alliance_members
     SET role = 'leader'
   WHERE id = v_next.id;

  UPDATE alliances
     SET owner_player_id = v_next.player_id
   WHERE id = v_member.alliance_id;

  DELETE FROM alliance_members
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
-- 5) ATOMİK ÜYE ÇIKARMA
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.nexora_kick_alliance_member(
  p_leader_player_id bigint,
  p_target_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_leader alliance_members%ROWTYPE;
  v_target alliance_members%ROWTYPE;
BEGIN
  IF p_leader_player_id = p_target_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SELF_KICK',
      'message', 'Kendini ittifaktan çıkaramazsın. Ayrıl işlemini kullan.'
    );
  END IF;

  SELECT *
    INTO v_leader
    FROM alliance_members
   WHERE player_id = p_leader_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND OR v_leader.role <> 'leader' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_LEADER',
      'message', 'Bu işlem için ittifak lideri olmalısın.'
    );
  END IF;

  SELECT *
    INTO v_target
    FROM alliance_members
   WHERE player_id = p_target_player_id
     AND alliance_id = v_leader.alliance_id
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

  IF v_target.role = 'leader' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_LEADER',
      'message', 'İttifak lideri bu işlemle çıkarılamaz.'
    );
  END IF;

  DELETE FROM alliance_members
   WHERE id = v_target.id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Oyuncu ittifaktan çıkarıldı.',
    'playerId', p_target_player_id
  );
END;
$$;

-- RPC'leri yalnızca backend service role çağırabilsin.
REVOKE ALL ON FUNCTION public.nexora_start_world_exploration(bigint,bigint,integer,numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.nexora_resolve_world_exploration(bigint,bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.nexora_leave_alliance(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.nexora_kick_alliance_member(bigint,bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.nexora_start_world_exploration(bigint,bigint,integer,numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_resolve_world_exploration(bigint,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_leave_alliance(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_kick_alliance_member(bigint,bigint) TO service_role;
