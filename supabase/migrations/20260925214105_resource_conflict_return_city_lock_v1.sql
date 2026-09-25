CREATE OR REPLACE FUNCTION public.nexora_sync_resource_conflict(p_player_id bigint, p_conflict_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  x public.resource_conflict_missions%ROWTYPE;
  target public.resource_gather_missions%ROWTYPE;
  s public.world_sites%ROWTYPE;
  now_at timestamptz:=clock_timestamp();
  result_text text;
  attacker_survivors jsonb;
  defender_survivors jsonb;
  attacker_pop bigint;
  takeover_id bigint;
  remaining integer;
  gather_timing jsonb;
  gather_seconds integer:=60;
  gather_rate numeric:=1;
  v_gather_stock_basis bigint:=0;
BEGIN
  SELECT * INTO x FROM public.resource_conflict_missions
  WHERE id=p_conflict_id AND (attacker_player_id=p_player_id OR defender_player_id=p_player_id)
  FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','CONFLICT_NOT_FOUND','message','Kaynak çatışması bulunamadı.'); END IF;
  IF x.status='completed' THEN RETURN jsonb_build_object('success',true,'completed',true,'conflict',to_jsonb(x)); END IF;

  IF x.status='returning' THEN
    IF x.return_at IS NULL OR x.return_at>now_at THEN
      remaining:=CASE WHEN x.return_at IS NULL THEN GREATEST(1,x.travel_seconds)
        ELSE GREATEST(1,CEIL(EXTRACT(EPOCH FROM(x.return_at-now_at)))::integer) END;
      RETURN jsonb_build_object('success',true,'completed',false,'conflict',to_jsonb(x),'remainingSeconds',remaining);
    END IF;

    -- Serialize unit mutations for this city with the same city-row lock
    -- used by unit-training completion. This prevents concurrent no-row
    -- inserts from creating duplicate unit records.
    PERFORM 1
    FROM public.cities
    WHERE id=x.attacker_city_id
    FOR UPDATE;

    PERFORM public.nexora_resource_return_army(x.attacker_city_id,COALESCE(x.attacker_survivor_army,'[]'::jsonb));
    UPDATE public.resource_conflict_missions SET status='completed',completed_at=now_at,updated_at=now_at
    WHERE id=x.id RETURNING * INTO x;
    RETURN jsonb_build_object('success',true,'completed',true,'conflict',to_jsonb(x));
  END IF;

  IF x.status IS DISTINCT FROM 'traveling' THEN
    RETURN jsonb_build_object('success',false,'code','CONFLICT_STATE','message','Kaynak çatışması beklenmeyen durumda.');
  END IF;

  IF x.arrive_at>now_at THEN
    remaining:=GREATEST(1,CEIL(EXTRACT(EPOCH FROM(x.arrive_at-now_at)))::integer);
    RETURN jsonb_build_object('success',true,'completed',false,'conflict',to_jsonb(x),'remainingSeconds',remaining);
  END IF;

  SELECT * INTO target FROM public.resource_gather_missions WHERE id=x.defender_gather_mission_id FOR UPDATE;
  SELECT * INTO s FROM public.world_sites WHERE id=x.site_id FOR UPDATE;

  IF target.id IS NULL OR target.status IS DISTINCT FROM 'gathering' OR target.site_id IS DISTINCT FROM x.site_id
     OR target.player_id IS DISTINCT FROM x.defender_player_id THEN
    UPDATE public.resource_conflict_missions
    SET status='returning',attacker_survivor_army=attacker_army,
        return_at=now_at+make_interval(secs=>travel_seconds),result='Hedef Ayrıldı',updated_at=now_at
    WHERE id=x.id RETURNING * INTO x;
    RETURN jsonb_build_object('success',true,'completed',false,'conflict',to_jsonb(x),'message','Hedef kaynak ordusu ayrılmış; saldıran birlikler dönüyor.');
  END IF;

  IF x.battle_plan->'defenderArmy' IS DISTINCT FROM target.army THEN
    UPDATE public.resource_conflict_missions
    SET status='returning',attacker_survivor_army=attacker_army,
        return_at=now_at+make_interval(secs=>travel_seconds),result='Hedef Değişti',updated_at=now_at
    WHERE id=x.id RETURNING * INTO x;
    RETURN jsonb_build_object('success',true,'completed',false,'conflict',to_jsonb(x),'message','Hedef ordu değişti; saldıran birlikler dönüyor.');
  END IF;

  result_text:=x.battle_plan->>'result';
  attacker_survivors:=COALESCE(x.battle_plan->'attackerSurvivorArmy','[]'::jsonb);
  defender_survivors:=COALESCE(x.battle_plan->'defenderSurvivorArmy','[]'::jsonb);
  attacker_pop:=public.nexora_military_army_population(attacker_survivors);

  IF result_text='Zafer' AND attacker_pop>0 THEN
    gather_timing:=public.nexora_resource_gather_timing(x.attacker_player_id,s.id);
    IF COALESCE(gather_timing->>'success','false')<>'true' THEN
      RAISE EXCEPTION 'RESOURCE_TAKEOVER_TIMING_FAILED %',gather_timing;
    END IF;
    gather_seconds:=GREATEST(60,COALESCE((gather_timing->>'gatherSeconds')::integer,60));
    gather_rate:=GREATEST(1,COALESCE((gather_timing->>'productionPerMinute')::numeric,1));
    v_gather_stock_basis:=GREATEST(0,COALESCE((gather_timing->>'stockBasis')::bigint,0));
    UPDATE public.resource_gather_missions
    SET status='returning',army=defender_survivors,gathered_amount=0,gather_complete_at=NULL,
        return_at=now_at+make_interval(secs=>travel_seconds),updated_at=now_at
    WHERE id=target.id;

    INSERT INTO public.resource_gather_missions(
      player_id,city_id,site_id,status,army,carry_capacity,resource_type,
      depart_at,arrive_at,gather_complete_at,gather_rate_per_minute,gather_stock_basis,gather_duration_seconds,
      travel_seconds,distance,depart_x,depart_y,target_x,target_y,battle_tactic,guard_plan,updated_at
    )
    VALUES(
      x.attacker_player_id,x.attacker_city_id,x.site_id,'gathering',attacker_survivors,GREATEST(1,attacker_pop*100),s.resource_type,
      x.depart_at,now_at,now_at+make_interval(secs=>gather_seconds),gather_rate,v_gather_stock_basis,gather_seconds,
      x.travel_seconds,sqrt(power((x.target_x-x.depart_x)::numeric,2)+power((x.target_y-x.depart_y)::numeric,2)),
      x.depart_x,x.depart_y,x.target_x,x.target_y,x.battle_tactic,NULL,now_at
    ) RETURNING id INTO takeover_id;

    UPDATE public.resource_conflict_missions
    SET status='completed',result='Zafer',takeover_mission_id=takeover_id,completed_at=now_at,updated_at=now_at
    WHERE id=x.id RETURNING * INTO x;

    RETURN jsonb_build_object('success',true,'completed',true,'conflict',to_jsonb(x),
      'takeoverMissionId',takeover_id,'gatherTiming',gather_timing,'battle',x.battle_plan);
  END IF;

  IF result_text='Beraberlik' OR public.nexora_military_army_population(defender_survivors)=0 THEN
    UPDATE public.resource_gather_missions
    SET status='returning',army=defender_survivors,gathered_amount=0,gather_complete_at=NULL,
        return_at=now_at+make_interval(secs=>travel_seconds),updated_at=now_at
    WHERE id=target.id;
  ELSE
    UPDATE public.resource_gather_missions
    SET army=defender_survivors,
        carry_capacity=GREATEST(1,public.nexora_military_army_population(defender_survivors)*100),
        updated_at=now_at
    WHERE id=target.id;
  END IF;

  UPDATE public.resource_conflict_missions
  SET status='returning',result=result_text,attacker_survivor_army=attacker_survivors,
      return_at=now_at+make_interval(secs=>travel_seconds),updated_at=now_at
  WHERE id=x.id RETURNING * INTO x;

  RETURN jsonb_build_object('success',true,'completed',false,'conflict',to_jsonb(x),'battle',x.battle_plan);
END;
$function$;

REVOKE ALL ON FUNCTION public.nexora_sync_resource_conflict(
  bigint,
  bigint
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_sync_resource_conflict(
  bigint,
  bigint
) TO service_role;
