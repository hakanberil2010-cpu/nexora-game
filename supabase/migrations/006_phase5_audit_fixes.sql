-- Phase 5 audit fixes. Apply after 005; safe to rerun.
-- No existing rows are rewritten. RPC signatures and API actions stay unchanged.
BEGIN;

-- Invalid explicit JSON values give no reward; absent/empty values retain the
-- legacy column fallback. Catch cast errors without blocking mission completion.
CREATE OR REPLACE FUNCTION public.nexora_phase5_reward_amount(
  p_value text, p_fallback bigint
)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN GREATEST(0, COALESCE(NULLIF(p_value, '')::bigint, p_fallback, 0));
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_resolve_world_exploration(
  p_player_id bigint,
  p_mission_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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
  v_reward_metal := public.nexora_phase5_reward_amount(v_site.reward->>'metal', v_site.reward_metal);
  v_reward_energy := public.nexora_phase5_reward_amount(v_site.reward->>'energy', v_site.reward_energy);
  v_reward_water := public.nexora_phase5_reward_amount(v_site.reward->>'water', v_site.reward_water);
  v_reward_crystal := public.nexora_phase5_reward_amount(v_site.reward->>'crystal', v_site.reward_crystal);

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

CREATE OR REPLACE FUNCTION public.nexora_leave_alliance(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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

  -- Re-read after taking the alliance lock: a concurrent leave/kick may have won.
  SELECT * INTO v_member FROM alliance_members
   WHERE player_id = p_player_id AND alliance_id = v_alliance.id
   ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'code', 'NOT_MEMBER',
      'message', 'Bir ittifaka üye değilsin.');
  END IF;

  IF (v_member.role IS NOT DISTINCT FROM 'leader')
       IS DISTINCT FROM (v_alliance.owner_player_id IS NOT DISTINCT FROM p_player_id) THEN
    RETURN jsonb_build_object('success', false, 'code', 'OWNER_MISMATCH',
      'message', 'İttifak liderlik kaydı tutarsız.');
  END IF;

  IF v_member.role IS DISTINCT FROM 'leader' THEN
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
  v_leader alliance_members%ROWTYPE;
  v_target alliance_members%ROWTYPE;
  v_alliance alliances%ROWTYPE;
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
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'code', 'NOT_LEADER',
      'message', 'Bu işlem için ittifak lideri olmalısın.');
  END IF;

  -- Same lock order as leave: alliance, then membership rows.
  SELECT * INTO v_alliance FROM alliances
   WHERE id = v_leader.alliance_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'code', 'NOT_LEADER',
      'message', 'Bu işlem için ittifak lideri olmalısın.');
  END IF;

  SELECT * INTO v_leader FROM alliance_members
   WHERE player_id = p_leader_player_id AND alliance_id = v_alliance.id
   ORDER BY id LIMIT 1 FOR UPDATE;

  IF NOT FOUND OR v_leader.role IS DISTINCT FROM 'leader'
     OR v_alliance.owner_player_id IS DISTINCT FROM p_leader_player_id THEN
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

ALTER FUNCTION public.nexora_start_world_exploration(bigint,bigint,integer,numeric)
  SET search_path = public, pg_temp;

-- PUBLIC revocation alone does not remove existing explicit Supabase grants.
REVOKE ALL ON FUNCTION public.nexora_phase5_reward_amount(text,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_phase5_reward_amount(text,bigint) TO service_role;
REVOKE ALL ON FUNCTION public.nexora_start_world_exploration(bigint,bigint,integer,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_start_world_exploration(bigint,bigint,integer,numeric) TO service_role;
REVOKE ALL ON FUNCTION public.nexora_resolve_world_exploration(bigint,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_resolve_world_exploration(bigint,bigint) TO service_role;
REVOKE ALL ON FUNCTION public.nexora_leave_alliance(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_leave_alliance(bigint) TO service_role;
REVOKE ALL ON FUNCTION public.nexora_kick_alliance_member(bigint,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_kick_alliance_member(bigint,bigint) TO service_role;

-- Mission status/result are trusted by the idempotency check: clients must not
-- reset completed missions directly through the Data API.
REVOKE ALL ON TABLE public.world_exploration_missions FROM PUBLIC, anon, authenticated;
ALTER TABLE public.world_exploration_missions ENABLE ROW LEVEL SECURITY;
GRANT ALL ON TABLE public.world_exploration_missions TO service_role;

COMMIT;
