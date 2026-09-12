-- NEXORA Phase 6 hotfix: owned strategic sites cannot be explored again.
-- Apply after 007_phase6_world_control.sql. Safe to rerun.
BEGIN;

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
  v_last timestamptz;
  v_remaining integer;
  v_seconds integer;
  v_distance numeric;
BEGIN
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
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_DISABLED',
      'message', 'İttifak bölgeleri henüz keşfe açık değil.'
    );
  END IF;

  IF v_site.owner_player_id IS NOT NULL THEN
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
    p_site_id,
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

REVOKE ALL ON FUNCTION public.nexora_start_world_exploration(bigint,bigint,integer,numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_start_world_exploration(bigint,bigint,integer,numeric)
  TO service_role;

COMMIT;
