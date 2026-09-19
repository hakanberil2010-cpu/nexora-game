-- TERYNDIS 089 production-speed based resource gathering
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM public.resource_gather_missions WHERE status IN ('traveling','gathering','returning'))
     OR EXISTS(SELECT 1 FROM public.resource_conflict_missions WHERE status IN ('traveling','returning')) THEN
    RAISE EXCEPTION 'RESOURCE_089_ACTIVE_MISSIONS';
  END IF;
END;
$guard$;

ALTER TABLE public.resource_gather_missions
  ADD COLUMN IF NOT EXISTS gather_rate_per_minute numeric,
  ADD COLUMN IF NOT EXISTS gather_stock_basis bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS gather_duration_seconds integer;

ALTER TABLE public.resource_gather_missions
  DROP CONSTRAINT IF EXISTS resource_gather_missions_gather_rate_per_minute_check;
ALTER TABLE public.resource_gather_missions
  DROP CONSTRAINT IF EXISTS resource_gather_missions_gather_stock_basis_check;
ALTER TABLE public.resource_gather_missions
  DROP CONSTRAINT IF EXISTS resource_gather_missions_gather_duration_seconds_check;

ALTER TABLE public.resource_gather_missions
  ADD CONSTRAINT resource_gather_missions_gather_rate_per_minute_check
    CHECK(gather_rate_per_minute IS NULL OR gather_rate_per_minute>0),
  ADD CONSTRAINT resource_gather_missions_gather_stock_basis_check
    CHECK(gather_stock_basis>=0),
  ADD CONSTRAINT resource_gather_missions_gather_duration_seconds_check
    CHECK(gather_duration_seconds IS NULL OR gather_duration_seconds>=60);

CREATE OR REPLACE FUNCTION public.nexora_resource_gather_timing(
  p_player_id bigint,
  p_site_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_city_id bigint;
  v_resource_type text;
  v_stock bigint:=0;
  v_metal_level integer:=0;
  v_energy_level integer:=0;
  v_alloy_level integer:=0;
  v_crystal_level integer:=0;
  v_production_research integer:=0;
  v_crystal_research integer:=0;
  v_region_bonus jsonb:='{}'::jsonb;
  v_region_bonus_active boolean:=false;
  v_region_bonus_key text;
  v_rate numeric:=0;
  v_effective_rate numeric:=1;
  v_production_minutes numeric:=0;
  v_gather_seconds integer:=60;
BEGIN
  IF p_player_id IS NULL OR p_player_id<=0 OR p_site_id IS NULL OR p_site_id<=0 THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_INPUT');
  END IF;

  SELECT id INTO v_city_id
  FROM public.cities
  WHERE player_id=p_player_id
  ORDER BY id
  LIMIT 1;

  IF v_city_id IS NULL THEN
    RETURN jsonb_build_object('success',false,'code','CITY_NOT_FOUND');
  END IF;

  SELECT resource_type,GREATEST(0,COALESCE(resource_stock,0))
  INTO v_resource_type,v_stock
  FROM public.world_sites
  WHERE id=p_site_id AND site_type='resource'
  LIMIT 1;

  IF v_resource_type NOT IN ('metal','energy','alloy','crystal') OR v_stock<=0 THEN
    RETURN jsonb_build_object('success',false,'code','RESOURCE_SITE_NOT_FOUND');
  END IF;

  SELECT
    COALESCE(SUM(level) FILTER (WHERE building_type='Metal Madeni'),0)::integer,
    COALESCE(SUM(level) FILTER (WHERE building_type='Enerji Santrali'),0)::integer,
    COALESCE(SUM(level) FILTER (WHERE building_type='Alaşım Rafinerisi'),0)::integer,
    COALESCE(SUM(level) FILTER (WHERE building_type='Kristal Madeni'),0)::integer
  INTO v_metal_level,v_energy_level,v_alloy_level,v_crystal_level
  FROM public.buildings
  WHERE city_id=v_city_id;

  SELECT COALESCE(production_level,0),COALESCE(crystal_level,0)
  INTO v_production_research,v_crystal_research
  FROM public.research
  WHERE player_id=p_player_id
  ORDER BY id
  LIMIT 1;

  IF NOT FOUND THEN
    v_production_research:=0;
    v_crystal_research:=0;
  END IF;

  CASE v_resource_type
    WHEN 'metal' THEN
      v_rate:=GREATEST(0,v_metal_level)*12*(1+GREATEST(0,v_production_research)*0.10);
    WHEN 'energy' THEN
      v_rate:=GREATEST(0,v_energy_level)*6*(1+GREATEST(0,v_production_research)*0.10);
    WHEN 'alloy' THEN
      v_rate:=GREATEST(0,v_alloy_level)*10*(1+GREATEST(0,v_production_research)*0.10);
    WHEN 'crystal' THEN
      v_rate:=GREATEST(0,v_crystal_level)*5*(1+GREATEST(0,v_crystal_research)*0.08);
  END CASE;

  v_region_bonus:=public.nexora_player_alliance_region_bonus(p_player_id);
  IF COALESCE(v_region_bonus->>'success','false')='true' THEN
    v_region_bonus_active:=COALESCE((v_region_bonus->>'active')::boolean,false);
    v_region_bonus_key:=v_region_bonus->>'bonusKey';
  END IF;

  IF v_region_bonus_active AND (
    (v_resource_type='metal' AND v_region_bonus_key='metal_production') OR
    (v_resource_type='energy' AND v_region_bonus_key='energy_production') OR
    (v_resource_type='alloy' AND v_region_bonus_key='alloy_production') OR
    (v_resource_type='crystal' AND v_region_bonus_key='crystal_production')
  ) THEN
    v_rate:=v_rate*1.05;
  END IF;

  v_effective_rate:=GREATEST(1,v_rate);
  v_production_minutes:=v_stock::numeric/v_effective_rate;
  v_gather_seconds:=GREATEST(
    60,
    CEIL((v_production_minutes/3)*60)::integer
  );

  RETURN jsonb_build_object(
    'success',true,
    'playerId',p_player_id,
    'siteId',p_site_id,
    'resourceType',v_resource_type,
    'stockBasis',v_stock,
    'productionPerMinute',v_effective_rate,
    'rawProductionPerMinute',v_rate,
    'productionMinutes',v_production_minutes,
    'gatherSeconds',v_gather_seconds,
    'speedFactor',3
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_sync_resource_gather_mission(p_player_id bigint, p_mission_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  m public.resource_gather_missions%ROWTYPE;
  s public.world_sites%ROWTYPE;
  c public.cities%ROWTYPE;
  now_at timestamptz:=clock_timestamp();
  gathered bigint:=0;
  elite_bonus bigint:=0;
  new_stock bigint:=0;
  remaining integer:=0;
  attacker_survivors jsonb;
  defender_survivors jsonb;
  result_text text;
  survivor_pop bigint;
  gather_timing jsonb;
  gather_seconds integer:=60;
  gather_rate numeric:=1;
  gather_stock_basis bigint:=0;
BEGIN
  SELECT * INTO m FROM public.resource_gather_missions WHERE id=p_mission_id AND player_id=p_player_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','MISSION_NOT_FOUND','message','Kaynak seferi bulunamadı.'); END IF;
  IF m.status='completed' THEN RETURN jsonb_build_object('success',true,'completed',true,'alreadyCompleted',true,'mission',to_jsonb(m)); END IF;

  IF m.status='traveling' THEN
    IF m.arrive_at>now_at THEN
      remaining:=GREATEST(1,CEIL(EXTRACT(EPOCH FROM(m.arrive_at-now_at)))::integer);
      RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'remainingSeconds',remaining);
    END IF;

    SELECT * INTO s FROM public.world_sites WHERE id=m.site_id AND site_type='resource' FOR UPDATE;
    IF NOT FOUND OR s.active IS DISTINCT FROM true OR COALESCE(s.resource_stock,0)<=0 THEN
      UPDATE public.resource_gather_missions
      SET status='returning',return_at=now_at+make_interval(secs=>travel_seconds),updated_at=now_at
      WHERE id=m.id RETURNING * INTO m;
      RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'message','Kaynak noktası artık kullanılamıyor; birlikler dönüyor.');
    END IF;

    gather_timing:=public.nexora_resource_gather_timing(p_player_id,s.id);
    IF COALESCE(gather_timing->>'success','false')<>'true' THEN
      RAISE EXCEPTION 'RESOURCE_GATHER_TIMING_FAILED %',gather_timing;
    END IF;
    gather_seconds:=GREATEST(60,COALESCE((gather_timing->>'gatherSeconds')::integer,60));
    gather_rate:=GREATEST(1,COALESCE((gather_timing->>'productionPerMinute')::numeric,1));
    gather_stock_basis:=GREATEST(0,COALESCE((gather_timing->>'stockBasis')::bigint,0));

    IF s.resource_guard_active THEN
      IF m.guard_plan IS NULL OR m.guard_plan->'defenderArmy' IS DISTINCT FROM COALESCE(s.resource_guard_army,'[]'::jsonb) THEN
        UPDATE public.resource_gather_missions
        SET status='returning',return_at=now_at+make_interval(secs=>travel_seconds),updated_at=now_at
        WHERE id=m.id RETURNING * INTO m;
        RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'message','Muhafız durumu değişti; birlikler dönüyor.');
      END IF;

      result_text:=m.guard_plan->>'result';
      attacker_survivors:=COALESCE(m.guard_plan->'attackerSurvivorArmy','[]'::jsonb);
      defender_survivors:=COALESCE(m.guard_plan->'defenderSurvivorArmy','[]'::jsonb);

      UPDATE public.world_sites
      SET resource_guard_army=defender_survivors,
          resource_guard_active=public.nexora_military_army_population(defender_survivors)>0
      WHERE id=s.id;

      survivor_pop:=public.nexora_military_army_population(attacker_survivors);

      IF result_text='Zafer' AND survivor_pop>0 THEN
        UPDATE public.resource_gather_missions
        SET status='gathering',army=attacker_survivors,carry_capacity=GREATEST(1,survivor_pop*100),
            gather_rate_per_minute=gather_rate,
            gather_stock_basis=gather_stock_basis,
            gather_duration_seconds=gather_seconds,
            gather_complete_at=now_at+make_interval(secs=>gather_seconds),
            updated_at=now_at
        WHERE id=m.id RETURNING * INTO m;
        RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),
          'guardBattle',m.guard_plan,'gatherTiming',gather_timing,'remainingSeconds',gather_seconds);
      END IF;

      UPDATE public.resource_gather_missions
      SET status='returning',army=attacker_survivors,carry_capacity=GREATEST(1,COALESCE(carry_capacity,1)),
          return_at=now_at+make_interval(secs=>travel_seconds),updated_at=now_at
      WHERE id=m.id RETURNING * INTO m;
      RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'guardBattle',m.guard_plan,
        'message','Muhafız savaşı sonrası birlikler koloniye dönüyor.');
    END IF;

    UPDATE public.resource_gather_missions
    SET status='gathering',
        gather_rate_per_minute=gather_rate,
        gather_stock_basis=gather_stock_basis,
        gather_duration_seconds=gather_seconds,
        gather_complete_at=now_at+make_interval(secs=>gather_seconds),
        updated_at=now_at
    WHERE id=m.id RETURNING * INTO m;

    RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),
      'gatherTiming',gather_timing,'remainingSeconds',gather_seconds);
  END IF;

  IF m.status='gathering' THEN
    IF EXISTS(SELECT 1 FROM public.resource_conflict_missions rc
      WHERE rc.defender_gather_mission_id=m.id AND rc.status='traveling') THEN
      RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'underAttack',true);
    END IF;

    IF m.gather_complete_at IS NULL OR m.gather_complete_at>now_at THEN
      remaining:=CASE WHEN m.gather_complete_at IS NULL THEN 1
        ELSE GREATEST(1,CEIL(EXTRACT(EPOCH FROM(m.gather_complete_at-now_at)))::integer) END;
      RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'remainingSeconds',remaining);
    END IF;

    SELECT * INTO s FROM public.world_sites WHERE id=m.site_id AND site_type='resource' FOR UPDATE;
    IF FOUND AND s.active=true AND s.resource_type=m.resource_type AND COALESCE(s.resource_stock,0)>0 THEN
      gathered:=LEAST(GREATEST(0,m.carry_capacity),GREATEST(0,s.resource_stock));
      elite_bonus:=CASE
        WHEN s.resource_rarity='elite' THEN FLOOR(gathered::numeric*0.20)::bigint
        ELSE 0
      END;
      new_stock:=GREATEST(0,s.resource_stock-gathered);
      UPDATE public.world_sites SET
        resource_stock=new_stock,
        active=CASE WHEN new_stock=0 THEN false ELSE active END,
        resource_respawn_at=CASE WHEN new_stock=0
          THEN now_at+make_interval(secs=>GREATEST(60,COALESCE(resource_respawn_seconds,600)))
          ELSE resource_respawn_at END
      WHERE id=s.id;
    END IF;

    UPDATE public.resource_gather_missions
    SET status='returning',
        gathered_base_amount=gathered,
        elite_bonus_amount=elite_bonus,
        gathered_amount=gathered+elite_bonus,
        return_at=now_at+make_interval(secs=>travel_seconds),
        updated_at=now_at
    WHERE id=m.id RETURNING * INTO m;

    RETURN jsonb_build_object(
      'success',true,'completed',false,'mission',to_jsonb(m),
      'gatheredBaseAmount',gathered,
      'eliteBonusAmount',elite_bonus,
      'gatheredAmount',gathered+elite_bonus,
      'remainingSeconds',m.travel_seconds
    );
  END IF;

  IF m.status IS DISTINCT FROM 'returning' THEN
    RETURN jsonb_build_object('success',false,'code','MISSION_STATE','message','Kaynak seferi beklenmeyen durumda.');
  END IF;

  IF m.return_at IS NULL OR m.return_at>now_at THEN
    remaining:=CASE WHEN m.return_at IS NULL THEN GREATEST(1,m.travel_seconds)
      ELSE GREATEST(1,CEIL(EXTRACT(EPOCH FROM(m.return_at-now_at)))::integer) END;
    RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'remainingSeconds',remaining);
  END IF;

  SELECT * INTO c FROM public.cities WHERE id=m.city_id AND player_id=p_player_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','CITY_NOT_FOUND','message','Koloni bulunamadı.'); END IF;

  PERFORM public.nexora_resource_return_army(c.id,COALESCE(m.army,'[]'::jsonb));

  UPDATE public.cities SET
    metal=COALESCE(metal,0)+CASE WHEN m.resource_type='metal' THEN m.gathered_amount ELSE 0 END,
    energy=COALESCE(energy,0)+CASE WHEN m.resource_type='energy' THEN m.gathered_amount ELSE 0 END,
    alloy=COALESCE(alloy,0)+CASE WHEN m.resource_type='alloy' THEN m.gathered_amount ELSE 0 END,
    crystal=COALESCE(crystal,0)+CASE WHEN m.resource_type='crystal' THEN m.gathered_amount ELSE 0 END
  WHERE id=c.id;

  UPDATE public.resource_gather_missions SET status='completed',completed_at=now_at,updated_at=now_at
  WHERE id=m.id RETURNING * INTO m;

  RETURN jsonb_build_object(
    'success',true,'completed',true,'alreadyCompleted',false,
    'mission',to_jsonb(m),
    'resourceType',m.resource_type,
    'gatheredBaseAmount',COALESCE(m.gathered_base_amount,0),
    'eliteBonusAmount',COALESCE(m.elite_bonus_amount,0),
    'gatheredAmount',m.gathered_amount
  );
END;
$function$;

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
  gather_stock_basis bigint:=0;
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
    gather_stock_basis:=GREATEST(0,COALESCE((gather_timing->>'stockBasis')::bigint,0));
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
      x.depart_at,now_at,now_at+make_interval(secs=>gather_seconds),gather_rate,gather_stock_basis,gather_seconds,
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

REVOKE ALL ON FUNCTION public.nexora_resource_gather_timing(bigint,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_resource_gather_timing(bigint,bigint) TO service_role;

COMMIT;
