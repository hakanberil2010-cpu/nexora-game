-- TERYNDIS 091 World Map V3 fog of war, discovery memory and intel scans
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM public.resource_gather_missions WHERE status IN ('traveling','gathering','returning'))
     OR EXISTS(SELECT 1 FROM public.resource_conflict_missions WHERE status IN ('traveling','returning'))
     OR EXISTS(SELECT 1 FROM public.military_missions WHERE status IN ('traveling','resolving','returning'))
     OR EXISTS(SELECT 1 FROM public.npc_missions WHERE status IN ('traveling','resolving','returning'))
     OR EXISTS(SELECT 1 FROM public.world_exploration_missions WHERE status IN ('traveling','resolving'))
     OR EXISTS(SELECT 1 FROM public.espionage_missions WHERE status IN ('traveling','resolving')) THEN
    RAISE EXCEPTION 'WORLD_V3_ACTIVE_MISSIONS';
  END IF;
END;
$guard$;

CREATE TABLE IF NOT EXISTS public.world_discovery_memory(
  id bigserial PRIMARY KEY,
  player_id bigint NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  target_type text NOT NULL CHECK(target_type IN ('player','npc','site')),
  target_id bigint NOT NULL CHECK(target_id>0),
  coordinate_x integer NOT NULL CHECK(coordinate_x BETWEEN 1 AND 200),
  coordinate_y integer NOT NULL CHECK(coordinate_y BETWEEN 1 AND 200),
  snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  source text NOT NULL DEFAULT 'vision' CHECK(source IN ('vision','exploration','espionage')),
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(player_id,target_type,target_id)
);

ALTER TABLE public.world_discovery_memory ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_world_discovery_memory_player_seen
  ON public.world_discovery_memory(player_id,last_seen_at DESC);

CREATE TABLE IF NOT EXISTS public.world_intel_scans(
  id bigserial PRIMARY KEY,
  player_id bigint NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  source_mission_id bigint NOT NULL UNIQUE,
  center_x integer NOT NULL CHECK(center_x BETWEEN 1 AND 200),
  center_y integer NOT NULL CHECK(center_y BETWEEN 1 AND 200),
  radius integer NOT NULL CHECK(radius BETWEEN 1 AND 100),
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.world_intel_scans ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_world_intel_scans_player_expiry
  ON public.world_intel_scans(player_id,expires_at);

CREATE OR REPLACE FUNCTION public.nexora_world_point_live_visible(
  p_player_id bigint,
  p_x integer,
  p_y integer
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_city public.cities%ROWTYPE;
  v_watchtower integer:=0;
  v_radius integer:=18;
BEGIN
  IF p_player_id IS NULL OR p_player_id<=0
     OR p_x IS NULL OR p_y IS NULL
     OR p_x NOT BETWEEN 1 AND 200
     OR p_y NOT BETWEEN 1 AND 200 THEN
    RETURN false;
  END IF;

  SELECT * INTO v_city
  FROM public.cities
  WHERE player_id=p_player_id
  ORDER BY id
  LIMIT 1;

  IF NOT FOUND THEN RETURN false; END IF;

  SELECT COALESCE(MAX(
    GREATEST(0,COALESCE(level,0))+
    CASE
      WHEN COALESCE(is_under_construction,false)=true
       AND upgrade_ready_at IS NOT NULL
       AND upgrade_ready_at<=now()
      THEN 1 ELSE 0
    END
  ),0)
  INTO v_watchtower
  FROM public.buildings
  WHERE city_id=v_city.id
    AND building_type='Gözcü Kulesi';

  v_radius:=18+GREATEST(0,v_watchtower)*4;

  IF power(p_x-v_city.coordinate_x,2)+power(p_y-v_city.coordinate_y,2)
     <= power(v_radius,2) THEN
    RETURN true;
  END IF;

  RETURN EXISTS(
    SELECT 1
    FROM public.world_intel_scans s
    WHERE s.player_id=p_player_id
      AND s.expires_at>now()
      AND power(p_x-s.center_x,2)+power(p_y-s.center_y,2)
          <= power(s.radius,2)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_world_target_visibility(
  p_player_id bigint,
  p_target_type text,
  p_target_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_type text:=lower(trim(COALESCE(p_target_type,'')));
  v_x integer;
  v_y integer;
  v_seen boolean:=false;
  v_last_seen timestamptz;
  v_live boolean:=false;
BEGIN
  IF p_player_id IS NULL OR p_player_id<=0
     OR p_target_id IS NULL OR p_target_id<=0
     OR v_type NOT IN ('player','npc','site') THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_TARGET');
  END IF;

  IF v_type='player' THEN
    SELECT coordinate_x,coordinate_y
      INTO v_x,v_y
    FROM public.cities
    WHERE player_id=p_target_id
    ORDER BY id
    LIMIT 1;
  ELSIF v_type='npc' THEN
    SELECT s.coordinate_x,s.coordinate_y
      INTO v_x,v_y
    FROM public.npc_camps c
    JOIN public.world_sites s ON s.id=c.world_site_id
    WHERE c.id=p_target_id
      AND c.active=true
      AND s.active=true
    LIMIT 1;
  ELSE
    SELECT coordinate_x,coordinate_y
      INTO v_x,v_y
    FROM public.world_sites
    WHERE id=p_target_id
      AND active=true
    LIMIT 1;
  END IF;

  IF v_x IS NULL OR v_y IS NULL THEN
    RETURN jsonb_build_object('success',false,'code','TARGET_NOT_FOUND');
  END IF;

  SELECT true,last_seen_at
    INTO v_seen,v_last_seen
  FROM public.world_discovery_memory
  WHERE player_id=p_player_id
    AND target_type=v_type
    AND target_id=p_target_id
  LIMIT 1;

  IF v_type='site' AND COALESCE(v_seen,false)=false THEN
    SELECT EXISTS(
      SELECT 1
      FROM public.world_exploration_missions m
      WHERE m.player_id=p_player_id
        AND m.site_id=p_target_id
        AND m.status='completed'
    )
    OR EXISTS(
      SELECT 1
      FROM public.world_sites s
      JOIN public.alliance_members viewer ON viewer.player_id=p_player_id
      WHERE s.id=p_target_id
        AND s.site_type='alliance'
        AND EXISTS(
          SELECT 1
          FROM public.world_exploration_missions m
          JOIN public.alliance_members am
            ON am.player_id=m.player_id
           AND am.alliance_id=viewer.alliance_id
          WHERE m.site_id=s.id
            AND m.status='completed'
        )
    )
    INTO v_seen;
  END IF;

  v_live:=public.nexora_world_point_live_visible(p_player_id,v_x,v_y);

  RETURN jsonb_build_object(
    'success',true,
    'targetType',v_type,
    'targetId',p_target_id,
    'coordinateX',v_x,
    'coordinateY',v_y,
    'seen',COALESCE(v_seen,false) OR v_live,
    'lastSeenAt',v_last_seen,
    'liveVisible',v_live
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_world_refresh_memory(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_city public.cities%ROWTYPE;
  v_watchtower integer:=0;
  v_radius integer:=18;
  v_alliance_id bigint;
  v_now timestamptz:=clock_timestamp();
  v_memory jsonb:='[]'::jsonb;
  v_live_players jsonb:='[]'::jsonb;
  v_live_npcs jsonb:='[]'::jsonb;
  v_live_sites jsonb:='[]'::jsonb;
BEGIN
  SELECT * INTO v_city
  FROM public.cities
  WHERE player_id=p_player_id
  ORDER BY id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',false,'code','CITY_NOT_FOUND');
  END IF;

  SELECT COALESCE(MAX(
    GREATEST(0,COALESCE(level,0))+
    CASE
      WHEN COALESCE(is_under_construction,false)=true
       AND upgrade_ready_at IS NOT NULL
       AND upgrade_ready_at<=v_now
      THEN 1 ELSE 0
    END
  ),0)
  INTO v_watchtower
  FROM public.buildings
  WHERE city_id=v_city.id
    AND building_type='Gözcü Kulesi';

  v_radius:=18+GREATEST(0,v_watchtower)*4;

  SELECT alliance_id INTO v_alliance_id
  FROM public.alliance_members
  WHERE player_id=p_player_id
  ORDER BY id
  LIMIT 1;

  DELETE FROM public.world_intel_scans
  WHERE player_id=p_player_id
    AND expires_at<=v_now;

  INSERT INTO public.world_discovery_memory(
    player_id,target_type,target_id,coordinate_x,coordinate_y,
    snapshot,source,first_seen_at,last_seen_at,updated_at
  )
  SELECT
    p_player_id,'player',c.player_id,c.coordinate_x,c.coordinate_y,
    jsonb_build_object(
      'id',c.id,
      'player_id',c.player_id,
      'username',COALESCE(p.username,'Oyuncu'),
      'name',c.name,
      'level',c.level,
      'coordinate_x',c.coordinate_x,
      'coordinate_y',c.coordinate_y
    ),
    'vision',v_now,v_now,v_now
  FROM public.cities c
  LEFT JOIN public.players p ON p.id=c.player_id
  WHERE c.player_id<>p_player_id
    AND public.nexora_world_point_live_visible(p_player_id,c.coordinate_x,c.coordinate_y)
  ON CONFLICT(player_id,target_type,target_id)
  DO UPDATE SET
    coordinate_x=EXCLUDED.coordinate_x,
    coordinate_y=EXCLUDED.coordinate_y,
    snapshot=EXCLUDED.snapshot,
    source='vision',
    last_seen_at=EXCLUDED.last_seen_at,
    updated_at=EXCLUDED.updated_at;

  INSERT INTO public.world_discovery_memory(
    player_id,target_type,target_id,coordinate_x,coordinate_y,
    snapshot,source,first_seen_at,last_seen_at,updated_at
  )
  SELECT
    p_player_id,'npc',c.id,s.coordinate_x,s.coordinate_y,
    jsonb_build_object(
      'id',c.id,
      'worldSiteId',s.id,
      'name',s.name,
      'description',s.description,
      'tier',c.tier,
      'level',c.tier,
      'difficulty',c.difficulty,
      'encounterClass',c.encounter_class,
      'icon',c.icon,
      'recommendedHq',c.recommended_hq,
      'isBoss',c.encounter_class='boss',
      'coordinateX',s.coordinate_x,
      'coordinateY',s.coordinate_y,
      'armyTemplate',c.army_template,
      'reward',c.reward,
      'cooldownSeconds',c.cooldown_seconds,
      'victories',COALESCE(st.victories,0),
      'defeats',COALESCE(st.defeats,0),
      'draws',COALESCE(st.draws,0),
      'lastBattleAt',st.last_battle_at,
      'availableAt',st.available_at,
      'remainingSeconds',GREATEST(0,CEIL(EXTRACT(EPOCH FROM (COALESCE(st.available_at,'epoch'::timestamptz)-v_now)))::integer),
      'activeMissionId',(SELECT m.id FROM public.npc_missions m WHERE m.npc_camp_id=c.id AND m.status IN ('traveling','resolving','returning') ORDER BY m.id DESC LIMIT 1),
      'canAttack',COALESCE(st.available_at,'epoch'::timestamptz)<=v_now
        AND NOT EXISTS(SELECT 1 FROM public.npc_missions m WHERE m.npc_camp_id=c.id AND m.status IN ('traveling','resolving','returning'))
    ),
    'vision',v_now,v_now,v_now
  FROM public.npc_camps c
  JOIN public.world_sites s ON s.id=c.world_site_id
  LEFT JOIN public.player_npc_camp_state st
    ON st.player_id=p_player_id AND st.npc_camp_id=c.id
  WHERE c.active=true
    AND s.active=true
    AND s.site_type='npc_camp'
    AND public.nexora_world_point_live_visible(p_player_id,s.coordinate_x,s.coordinate_y)
  ON CONFLICT(player_id,target_type,target_id)
  DO UPDATE SET
    coordinate_x=EXCLUDED.coordinate_x,
    coordinate_y=EXCLUDED.coordinate_y,
    snapshot=EXCLUDED.snapshot,
    source='vision',
    last_seen_at=EXCLUDED.last_seen_at,
    updated_at=EXCLUDED.updated_at;

  INSERT INTO public.world_discovery_memory(
    player_id,target_type,target_id,coordinate_x,coordinate_y,
    snapshot,source,first_seen_at,last_seen_at,updated_at
  )
  SELECT
    p_player_id,'site',s.id,s.coordinate_x,s.coordinate_y,
    to_jsonb(s)||jsonb_build_object(
      'owner_username',p.username,
      'owner_alliance_name',a.name,
      'owner_alliance_tag',a.tag,
      'has_explored',true
    ),
    'vision',v_now,v_now,v_now
  FROM public.world_sites s
  LEFT JOIN public.players p ON p.id=s.owner_player_id
  LEFT JOIN public.alliances a ON a.id=s.owner_alliance_id
  WHERE s.active=true
    AND s.site_type<>'npc_camp'
    AND public.nexora_world_point_live_visible(p_player_id,s.coordinate_x,s.coordinate_y)
    AND (
      s.owner_player_id=p_player_id
      OR (v_alliance_id IS NOT NULL AND s.owner_alliance_id=v_alliance_id)
      OR EXISTS(
        SELECT 1 FROM public.world_exploration_missions m
        WHERE m.player_id=p_player_id
          AND m.site_id=s.id
          AND m.status='completed'
      )
      OR (
        s.site_type='alliance'
        AND v_alliance_id IS NOT NULL
        AND EXISTS(
          SELECT 1
          FROM public.world_exploration_missions m
          JOIN public.alliance_members am
            ON am.player_id=m.player_id
           AND am.alliance_id=v_alliance_id
          WHERE m.site_id=s.id
            AND m.status='completed'
        )
      )
    )
  ON CONFLICT(player_id,target_type,target_id)
  DO UPDATE SET
    coordinate_x=EXCLUDED.coordinate_x,
    coordinate_y=EXCLUDED.coordinate_y,
    snapshot=EXCLUDED.snapshot,
    source='vision',
    last_seen_at=EXCLUDED.last_seen_at,
    updated_at=EXCLUDED.updated_at;

  v_live_players:=COALESCE((
    SELECT jsonb_agg(c.player_id ORDER BY c.player_id)
    FROM public.cities c
    WHERE c.player_id<>p_player_id
      AND public.nexora_world_point_live_visible(p_player_id,c.coordinate_x,c.coordinate_y)
  ),'[]'::jsonb);

  v_live_npcs:=COALESCE((
    SELECT jsonb_agg(c.id ORDER BY c.id)
    FROM public.npc_camps c
    JOIN public.world_sites s ON s.id=c.world_site_id
    WHERE c.active=true AND s.active=true
      AND public.nexora_world_point_live_visible(p_player_id,s.coordinate_x,s.coordinate_y)
  ),'[]'::jsonb);

  v_live_sites:=COALESCE((
    SELECT jsonb_agg(s.id ORDER BY s.id)
    FROM public.world_sites s
    WHERE s.active=true
      AND s.site_type<>'npc_camp'
      AND public.nexora_world_point_live_visible(p_player_id,s.coordinate_x,s.coordinate_y)
  ),'[]'::jsonb);

  v_memory:=COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'targetType',m.target_type,
      'targetId',m.target_id,
      'coordinateX',m.coordinate_x,
      'coordinateY',m.coordinate_y,
      'snapshot',m.snapshot,
      'source',m.source,
      'firstSeenAt',m.first_seen_at,
      'lastSeenAt',m.last_seen_at
    ) ORDER BY m.target_type,m.target_id)
    FROM public.world_discovery_memory m
    WHERE m.player_id=p_player_id
  ),'[]'::jsonb);

  RETURN jsonb_build_object(
    'success',true,
    'viewerX',v_city.coordinate_x,
    'viewerY',v_city.coordinate_y,
    'watchtowerLevel',v_watchtower,
    'visionRadius',v_radius,
    'livePlayerIds',v_live_players,
    'liveNpcIds',v_live_npcs,
    'liveSiteIds',v_live_sites,
    'memory',v_memory,
    'activeIntelScans',COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'centerX',s.center_x,
        'centerY',s.center_y,
        'radius',s.radius,
        'expiresAt',s.expires_at
      ) ORDER BY s.expires_at)
      FROM public.world_intel_scans s
      WHERE s.player_id=p_player_id
        AND s.expires_at>v_now
    ),'[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_start_world_exploration(p_player_id bigint, p_site_id bigint, p_travel_seconds integer, p_distance numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.nexora_resolve_world_exploration(p_player_id bigint, p_mission_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_reward_alloy bigint := 0;
  v_reward_crystal bigint := 0;
  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_alloy bigint := 0;
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
    COALESCE(SUM(level) FILTER (WHERE building_type = 'Depo'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Kristal Deposu'), 0)
  INTO v_depo_level, v_crystal_depo_level
  FROM buildings
  WHERE city_id = v_city.id;

  v_storage := 10000 + GREATEST(0, v_depo_level) * 5000;
  v_crystal_storage := 10000 + GREATEST(0, v_crystal_depo_level) * 5000;

  -- Kaynak noktası keşfi kimliği açar; keşif ödülü üretmez.
  IF v_site.site_type = 'resource' THEN
    v_reward_metal := 0;
    v_reward_energy := 0;
    v_reward_alloy := 0;
    v_reward_crystal := 0;
  ELSE
    -- Öncelik mevcut production reward JSON alanındadır.
    -- JSON anahtarı yoksa taslak/eski reward_* kolonlarına düşer.
    v_reward_metal := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'metal', '')::bigint, v_site.reward_metal, 0));
    v_reward_energy := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'energy', '')::bigint, v_site.reward_energy, 0));
    v_reward_alloy := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'alloy', '')::bigint, v_site.reward_alloy, 0));
    v_reward_crystal := GREATEST(0, COALESCE(NULLIF(v_site.reward->>'crystal', '')::bigint, v_site.reward_crystal, 0));
  END IF;

  v_credit_metal := v_reward_metal;
  v_credit_energy := v_reward_energy;
  v_credit_alloy := v_reward_alloy;
  v_credit_crystal := v_reward_crystal;

  UPDATE cities
     SET metal = COALESCE(metal, 0) + v_credit_metal,
         energy = COALESCE(energy, 0) + v_credit_energy,
         alloy = COALESCE(alloy, 0) + v_credit_alloy,
         crystal = COALESCE(crystal, 0) + v_credit_crystal
   WHERE id = v_city.id;

  INSERT INTO public.world_discovery_memory(
    player_id,target_type,target_id,coordinate_x,coordinate_y,
    snapshot,source,first_seen_at,last_seen_at,updated_at
  )
  VALUES(
    p_player_id,'site',v_site.id,v_site.coordinate_x,v_site.coordinate_y,
    to_jsonb(v_site),'exploration',now(),now(),now()
  )
  ON CONFLICT(player_id,target_type,target_id)
  DO UPDATE SET
    coordinate_x=EXCLUDED.coordinate_x,
    coordinate_y=EXCLUDED.coordinate_y,
    snapshot=EXCLUDED.snapshot,
    source='exploration',
    last_seen_at=EXCLUDED.last_seen_at,
    updated_at=EXCLUDED.updated_at;

  v_result := jsonb_build_object(
    'message',
      CASE
        WHEN v_site.site_type='resource'
          THEN v_site.name || ' keşfedildi. Kaynak toplamak için noktanın güncel görüş alanında olması gerekir.'
        ELSE v_site.name || ' keşfi tamamlandı.'
      END,
    'siteId', v_site.id,
    'siteName', v_site.name,
    'siteType', v_site.site_type,
    'reward', jsonb_build_object(
      'metal', v_credit_metal,
      'energy', v_credit_energy,
      'alloy', v_credit_alloy,
      'crystal', v_credit_crystal
    ),
    'rewardRequested', jsonb_build_object(
      'metal', v_reward_metal,
      'energy', v_reward_energy,
      'alloy', v_reward_alloy,
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
$function$;

CREATE OR REPLACE FUNCTION public.nexora_resolve_espionage(p_player_id bigint, p_mission_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mission public.espionage_missions%ROWTYPE;
  v_defender_city public.cities%ROWTYPE;
  v_sync jsonb;
  v_defender_watchtower integer := 0;
  v_attack_level integer := 0;
  v_advantage integer := 0;
  v_detection_chance integer := 30;
  v_roll integer := 1;
  v_detected boolean := false;
  v_intel_level integer := 0;
  v_remaining integer := 0;
  v_resources jsonb := '{}'::jsonb;
  v_buildings jsonb := '[]'::jsonb;
  v_army jsonb := '[]'::jsonb;
  v_research jsonb := '{}'::jsonb;
  v_result jsonb;
BEGIN
  SELECT *
    INTO v_mission
    FROM public.espionage_missions
   WHERE id = p_mission_id
     AND attacker_player_id = p_player_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'Casusluk görevi bulunamadı.'
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

  IF v_mission.status NOT IN ('traveling', 'resolving') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_STATUS',
      'message', 'Casusluk görevi sonuçlandırılamıyor.'
    );
  END IF;

  UPDATE public.espionage_missions
     SET status = 'resolving'
   WHERE id = v_mission.id;

  -- Synchronize passive production before taking the resource snapshot.
  SELECT public.nexora_sync_city_production(v_mission.defender_player_id)
    INTO v_sync;

  SELECT *
    INTO v_defender_city
    FROM public.cities
   WHERE id = v_mission.defender_city_id
     AND player_id = v_mission.defender_player_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    v_result := jsonb_build_object(
      'outcome', 'target_missing',
      'detected', false,
      'intelLevel', 0,
      'message', 'Hedef koloni artık bulunamıyor.'
    );

    UPDATE public.espionage_missions
       SET status = 'completed',
           completed_at = now(),
           detected = false,
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
  END IF;

  SELECT COALESCE(
    MAX(
      GREATEST(0, COALESCE(level, 0)) +
      CASE
        WHEN COALESCE(is_under_construction, false) = true
         AND upgrade_ready_at IS NOT NULL
         AND upgrade_ready_at <= now()
        THEN 1
        ELSE 0
      END
    ),
    0
  )
  INTO v_defender_watchtower
  FROM public.buildings
  WHERE city_id = v_defender_city.id
    AND building_type = 'Gözcü Kulesi';

  v_attack_level := GREATEST(1, COALESCE(v_mission.attacker_watchtower_level, 1));
  v_advantage := v_attack_level - v_defender_watchtower;

  -- Equal towers = 30% detection.
  -- Better defender tower raises detection; better attacker tower lowers it.
  v_detection_chance := GREATEST(
    10,
    LEAST(80, 30 + ((v_defender_watchtower - v_attack_level) * 8))
  );

  v_roll := FLOOR(random() * 100)::integer + 1;
  v_detected := v_roll <= v_detection_chance;

  IF v_detected THEN
    v_result := jsonb_build_object(
      'outcome', 'detected',
      'detected', true,
      'intelLevel', 0,
      'message', '🚨 Casusun hedef kolonide yakalandı. İstihbarat alınamadı.'
    );
  ELSE
    v_intel_level := CASE
      WHEN v_advantage >= 4 THEN 4
      WHEN v_advantage >= 2 THEN 3
      WHEN v_advantage >= 0 THEN 2
      ELSE 1
    END;

    v_resources := jsonb_build_object(
      'metal', GREATEST(0, COALESCE(v_defender_city.metal, 0)),
      'energy', GREATEST(0, COALESCE(v_defender_city.energy, 0)),
      'alloy', GREATEST(0, COALESCE(v_defender_city.alloy, 0)),
      'crystal', GREATEST(0, COALESCE(v_defender_city.crystal, 0))
    );

    IF v_intel_level >= 2 THEN
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'building', x.building_type,
            'slot', x.slot,
            'level', x.effective_level
          )
          ORDER BY x.building_type, x.slot
        ),
        '[]'::jsonb
      )
      INTO v_buildings
      FROM (
        SELECT
          building_type,
          COALESCE(slot, 1) AS slot,
          GREATEST(0, COALESCE(level, 0)) +
          CASE
            WHEN COALESCE(is_under_construction, false) = true
             AND upgrade_ready_at IS NOT NULL
             AND upgrade_ready_at <= now()
            THEN 1
            ELSE 0
          END AS effective_level
        FROM public.buildings
        WHERE city_id = v_defender_city.id
        ORDER BY building_type, COALESCE(slot, 1)
      ) AS x;
    END IF;

    IF v_intel_level >= 3 THEN
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'unitType', u.unit_type,
            'quantity', GREATEST(0, COALESCE(u.quantity, 0)),
            'level', GREATEST(1, COALESCE(u.level, 1))
          )
          ORDER BY u.unit_type
        ),
        '[]'::jsonb
      )
      INTO v_army
      FROM public.units AS u
      WHERE u.city_id = v_defender_city.id
        AND COALESCE(u.quantity, 0) > 0;
    END IF;

    IF v_intel_level >= 4 THEN
      SELECT jsonb_build_object(
        'production', COALESCE(r.production_level, 0),
        'combat', COALESCE(r.combat_level, 0),
        'defense', COALESCE(r.defense_level, 0),
        'crystal', COALESCE(r.crystal_level, 0),
        'generalPower', COALESCE(r.general_power_level, 0),
        'unitAttack', COALESCE(r.unit_attack_level, 0),
        'unitDefense', COALESCE(r.unit_defense_level, 0),
        'unitHp', COALESCE(r.unit_hp_level, 0),
        'travelSpeed', COALESCE(r.travel_speed_level, 0)
      )
      INTO v_research
      FROM public.research AS r
      WHERE r.player_id = v_mission.defender_player_id
      LIMIT 1;

      v_research := COALESCE(v_research, '{}'::jsonb);
    END IF;

    v_result := jsonb_build_object(
      'outcome', 'success',
      'detected', false,
      'intelLevel', v_intel_level,
      'message', '🕵️ Casusluk başarılı. Hedef koloni hakkında istihbarat toplandı.',
      'targetPlayerId', v_mission.defender_player_id,
      'targetCityId', v_mission.defender_city_id,
      'resources', v_resources,
      'buildings', CASE WHEN v_intel_level >= 2 THEN v_buildings ELSE NULL END,
      'army', CASE WHEN v_intel_level >= 3 THEN v_army ELSE NULL END,
      'research', CASE WHEN v_intel_level >= 4 THEN v_research ELSE NULL END
    );

    INSERT INTO public.world_discovery_memory(
      player_id,target_type,target_id,coordinate_x,coordinate_y,
      snapshot,source,first_seen_at,last_seen_at,updated_at
    )
    SELECT
      p_player_id,'player',v_mission.defender_player_id,
      v_defender_city.coordinate_x,v_defender_city.coordinate_y,
      jsonb_build_object(
        'id',v_defender_city.id,
        'player_id',v_mission.defender_player_id,
        'username',COALESCE(p.username,'Oyuncu'),
        'name',v_defender_city.name,
        'level',v_defender_city.level,
        'coordinate_x',v_defender_city.coordinate_x,
        'coordinate_y',v_defender_city.coordinate_y
      ),
      'espionage',now(),now(),now()
    FROM public.players p
    WHERE p.id=v_mission.defender_player_id
    ON CONFLICT(player_id,target_type,target_id)
    DO UPDATE SET
      coordinate_x=EXCLUDED.coordinate_x,
      coordinate_y=EXCLUDED.coordinate_y,
      snapshot=EXCLUDED.snapshot,
      source='espionage',
      last_seen_at=EXCLUDED.last_seen_at,
      updated_at=EXCLUDED.updated_at;

    INSERT INTO public.world_intel_scans(
      player_id,source_mission_id,center_x,center_y,radius,expires_at,created_at
    )
    VALUES(
      p_player_id,v_mission.id,
      v_defender_city.coordinate_x,v_defender_city.coordinate_y,
      LEAST(60,12+GREATEST(1,v_attack_level)*2),
      now()+interval '10 minutes',
      now()
    )
    ON CONFLICT(source_mission_id)
    DO UPDATE SET
      center_x=EXCLUDED.center_x,
      center_y=EXCLUDED.center_y,
      radius=EXCLUDED.radius,
      expires_at=EXCLUDED.expires_at;
  END IF;

  UPDATE public.espionage_missions
     SET status = 'completed',
         completed_at = now(),
         defender_watchtower_level = v_defender_watchtower,
         detected = v_detected,
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
$function$;

INSERT INTO public.world_discovery_memory(
  player_id,target_type,target_id,coordinate_x,coordinate_y,
  snapshot,source,first_seen_at,last_seen_at,updated_at
)
SELECT
  m.player_id,'site',s.id,s.coordinate_x,s.coordinate_y,
  to_jsonb(s),'exploration',
  COALESCE(m.completed_at,m.created_at,now()),
  COALESCE(m.completed_at,m.created_at,now()),
  now()
FROM public.world_exploration_missions m
JOIN public.world_sites s ON s.id=m.site_id
WHERE m.status='completed'
ON CONFLICT(player_id,target_type,target_id)
DO UPDATE SET
  coordinate_x=EXCLUDED.coordinate_x,
  coordinate_y=EXCLUDED.coordinate_y,
  snapshot=EXCLUDED.snapshot,
  source='exploration',
  last_seen_at=GREATEST(public.world_discovery_memory.last_seen_at,EXCLUDED.last_seen_at),
  updated_at=now();

REVOKE ALL ON TABLE public.world_discovery_memory FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.world_intel_scans FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.world_discovery_memory TO service_role;
GRANT ALL ON TABLE public.world_intel_scans TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.world_discovery_memory_id_seq TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.world_intel_scans_id_seq TO service_role;

REVOKE ALL ON FUNCTION public.nexora_world_point_live_visible(bigint,integer,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.nexora_world_target_visibility(bigint,text,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.nexora_world_refresh_memory(bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_world_point_live_visible(bigint,integer,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_world_target_visibility(bigint,text,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_world_refresh_memory(bigint) TO service_role;

COMMIT;
