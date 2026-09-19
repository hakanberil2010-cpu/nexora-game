-- TERYNDIS 092 separate discovery memory from live visibility
BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_world_target_visibility(p_player_id bigint, p_target_type text, p_target_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
    'seen',COALESCE(v_seen,false),
    'lastSeenAt',v_last_seen,
    'liveVisible',v_live
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.nexora_world_target_visibility(bigint,text,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_world_target_visibility(bigint,text,bigint) TO service_role;

COMMIT;
