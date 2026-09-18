-- TERYNDIS 087 Resource Rarity, Guards and Resource PvP
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM public.resource_gather_missions WHERE status IN ('traveling','returning'))
     OR EXISTS(SELECT 1 FROM public.military_missions WHERE status IN ('traveling','resolving','returning'))
     OR EXISTS(SELECT 1 FROM public.npc_missions WHERE status IN ('traveling','resolving','returning'))
     OR EXISTS(SELECT 1 FROM public.world_exploration_missions WHERE status IN ('traveling','resolving')) THEN
    RAISE EXCEPTION 'RESOURCE_PVP_ACTIVE_MISSIONS';
  END IF;
END;
$guard$;

ALTER TABLE public.world_sites
  ADD COLUMN IF NOT EXISTS resource_rarity text NOT NULL DEFAULT 'normal',
  ADD COLUMN IF NOT EXISTS resource_gather_seconds integer NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS resource_guard_template jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS resource_guard_army jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS resource_guard_active boolean NOT NULL DEFAULT false;

ALTER TABLE public.world_sites DROP CONSTRAINT IF EXISTS world_sites_resource_rarity_check;
ALTER TABLE public.world_sites ADD CONSTRAINT world_sites_resource_rarity_check
  CHECK(resource_rarity IN ('normal','rare','elite'));
ALTER TABLE public.world_sites DROP CONSTRAINT IF EXISTS world_sites_resource_gather_seconds_check;
ALTER TABLE public.world_sites ADD CONSTRAINT world_sites_resource_gather_seconds_check
  CHECK(resource_gather_seconds BETWEEN 5 AND 3600);

WITH ranked AS(
  SELECT id,resource_type,row_number() OVER(PARTITION BY resource_type ORDER BY id) rn
  FROM public.world_sites
  WHERE site_type='resource'
), typed AS(
  SELECT id,resource_type,
    CASE WHEN rn<=4 THEN 'normal' WHEN rn=5 THEN 'rare' ELSE 'elite' END rarity
  FROM ranked
)
UPDATE public.world_sites s
SET resource_rarity=t.rarity,
    resource_capacity=CASE
      WHEN t.resource_type='crystal' THEN CASE t.rarity WHEN 'normal' THEN 2500 WHEN 'rare' THEN 5000 ELSE 7500 END
      ELSE CASE t.rarity WHEN 'normal' THEN 5000 WHEN 'rare' THEN 10000 ELSE 15000 END
    END,
    resource_stock=CASE
      WHEN t.resource_type='crystal' THEN CASE t.rarity WHEN 'normal' THEN 2500 WHEN 'rare' THEN 5000 ELSE 7500 END
      ELSE CASE t.rarity WHEN 'normal' THEN 5000 WHEN 'rare' THEN 10000 ELSE 15000 END
    END,
    resource_gather_seconds=CASE t.rarity WHEN 'normal' THEN 30 WHEN 'rare' THEN 60 ELSE 90 END,
    resource_respawn_seconds=CASE
      WHEN t.resource_type='crystal' THEN CASE t.rarity WHEN 'normal' THEN 900 WHEN 'rare' THEN 1800 ELSE 2700 END
      ELSE CASE t.rarity WHEN 'normal' THEN 600 WHEN 'rare' THEN 1200 ELSE 1800 END
    END,
    resource_guard_template=CASE t.rarity
      WHEN 'rare' THEN '[{"unit_type":"piyade","quantity":6,"level":1},{"unit_type":"savunma","quantity":2,"level":1}]'::jsonb
      WHEN 'elite' THEN '[{"unit_type":"piyade","quantity":10,"level":2},{"unit_type":"savunma","quantity":4,"level":2},{"unit_type":"tank","quantity":2,"level":1}]'::jsonb
      ELSE '[]'::jsonb
    END,
    resource_guard_army=CASE t.rarity
      WHEN 'rare' THEN '[{"unit_type":"piyade","quantity":6,"level":1},{"unit_type":"savunma","quantity":2,"level":1}]'::jsonb
      WHEN 'elite' THEN '[{"unit_type":"piyade","quantity":10,"level":2},{"unit_type":"savunma","quantity":4,"level":2},{"unit_type":"tank","quantity":2,"level":1}]'::jsonb
      ELSE '[]'::jsonb
    END,
    resource_guard_active=(t.rarity IN ('rare','elite'))
FROM typed t
WHERE s.id=t.id;

ALTER TABLE public.resource_gather_missions
  ADD COLUMN IF NOT EXISTS gather_complete_at timestamptz,
  ADD COLUMN IF NOT EXISTS battle_tactic text NOT NULL DEFAULT 'balanced',
  ADD COLUMN IF NOT EXISTS guard_plan jsonb;

ALTER TABLE public.resource_gather_missions DROP CONSTRAINT IF EXISTS resource_gather_missions_status_check;
ALTER TABLE public.resource_gather_missions ADD CONSTRAINT resource_gather_missions_status_check
  CHECK(status IN ('traveling','gathering','returning','completed'));
ALTER TABLE public.resource_gather_missions DROP CONSTRAINT IF EXISTS resource_gather_missions_battle_tactic_check;
ALTER TABLE public.resource_gather_missions ADD CONSTRAINT resource_gather_missions_battle_tactic_check
  CHECK(battle_tactic IN ('assault','balanced','cautious'));

DROP INDEX IF EXISTS public.resource_gather_one_active_player_idx;
CREATE UNIQUE INDEX resource_gather_one_active_player_idx
  ON public.resource_gather_missions(player_id)
  WHERE status IN ('traveling','gathering','returning');
CREATE UNIQUE INDEX IF NOT EXISTS resource_gather_one_occupant_site_idx
  ON public.resource_gather_missions(site_id)
  WHERE status IN ('traveling','gathering');

CREATE TABLE public.resource_conflict_missions(
  id bigserial PRIMARY KEY,
  attacker_player_id bigint NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  defender_player_id bigint NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  attacker_city_id bigint NOT NULL REFERENCES public.cities(id) ON DELETE CASCADE,
  defender_gather_mission_id bigint NOT NULL REFERENCES public.resource_gather_missions(id) ON DELETE RESTRICT,
  site_id bigint NOT NULL REFERENCES public.world_sites(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'traveling' CHECK(status IN ('traveling','returning','completed')),
  attacker_army jsonb NOT NULL,
  attacker_survivor_army jsonb NOT NULL DEFAULT '[]'::jsonb,
  defender_survivor_army jsonb NOT NULL DEFAULT '[]'::jsonb,
  battle_plan jsonb NOT NULL,
  battle_tactic text NOT NULL DEFAULT 'balanced' CHECK(battle_tactic IN ('assault','balanced','cautious')),
  result text,
  takeover_mission_id bigint REFERENCES public.resource_gather_missions(id) ON DELETE SET NULL,
  depart_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  arrive_at timestamptz NOT NULL,
  return_at timestamptz,
  completed_at timestamptz,
  travel_seconds integer NOT NULL CHECK(travel_seconds>0),
  depart_x integer NOT NULL,
  depart_y integer NOT NULL,
  target_x integer NOT NULL,
  target_y integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.resource_conflict_missions ENABLE ROW LEVEL SECURITY;
CREATE INDEX resource_conflict_attacker_idx ON public.resource_conflict_missions(attacker_player_id);
CREATE INDEX resource_conflict_defender_idx ON public.resource_conflict_missions(defender_player_id);
CREATE INDEX resource_conflict_site_idx ON public.resource_conflict_missions(site_id);
CREATE UNIQUE INDEX resource_conflict_one_active_attacker_idx
  ON public.resource_conflict_missions(attacker_player_id) WHERE status IN ('traveling','returning');
CREATE UNIQUE INDEX resource_conflict_one_inbound_site_idx
  ON public.resource_conflict_missions(site_id) WHERE status='traveling';

CREATE OR REPLACE FUNCTION public.nexora_resource_return_army(p_city_id bigint,p_army jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  item jsonb;
  typ text;
  qty bigint;
  lvl integer;
  existing public.units%ROWTYPE;
  stats public.unit_levels%ROWTYPE;
  pop_cost integer;
BEGIN
  IF p_city_id IS NULL OR p_city_id<=0 OR p_army IS NULL OR jsonb_typeof(p_army) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'INVALID_RETURN_ARMY';
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(p_army) a(value)
  LOOP
    typ:=item->>'unit_type';
    qty:=COALESCE(NULLIF(item->>'quantity','')::bigint,0);
    lvl:=COALESCE(NULLIF(item->>'level','')::integer,1);

    IF typ NOT IN ('piyade','savunma','saldiri','okcu','tank','hava')
       OR qty<0 OR qty>2147483647 OR lvl<1 OR lvl>15 THEN
      RAISE EXCEPTION 'INVALID_RETURN_ARMY_ITEM';
    END IF;

    IF qty=0 THEN CONTINUE; END IF;

    SELECT * INTO stats
    FROM public.unit_levels
    WHERE unit_type=typ AND level=lvl
    LIMIT 1;

    IF NOT FOUND THEN RAISE EXCEPTION 'RETURN_UNIT_LEVEL_NOT_FOUND'; END IF;

    pop_cost:=CASE typ WHEN 'tank' THEN 3 WHEN 'hava' THEN 2 ELSE 1 END;

    SELECT * INTO existing
    FROM public.units
    WHERE city_id=p_city_id AND unit_type=typ
    ORDER BY id
    LIMIT 1
    FOR UPDATE;

    IF existing.id IS NOT NULL THEN
      UPDATE public.units SET quantity=COALESCE(quantity,0)+qty WHERE id=existing.id;
    ELSE
      INSERT INTO public.units(city_id,unit_type,quantity,level,attack,defense,hp,speed,population_cost)
      VALUES(p_city_id,typ,qty,lvl,stats.attack,stats.defense,stats.hp,stats.speed,pop_cost);
    END IF;
  END LOOP;
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_start_resource_gather_v2(
  p_player_id bigint,p_city_id bigint,p_site_id bigint,p_army jsonb,
  p_depart_x integer,p_depart_y integer,p_travel_seconds integer,
  p_battle_tactic text,p_guard_plan jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  c public.cities%ROWTYPE;
  s public.world_sites%ROWTYPE;
  m public.resource_gather_missions%ROWTYPE;
  u public.units%ROWTYPE;
  item jsonb;
  clean_army jsonb:='[]'::jsonb;
  typ text;
  qty_text text;
  lvl_text text;
  qty bigint;
  lvl integer;
  cnt integer;
  distinct_cnt integer;
  cap bigint:=0;
  pop_cost integer;
  now_at timestamptz:=clock_timestamp();
  dist numeric;
  unit_id bigint;
  affected integer;
  tactic text:=lower(COALESCE(p_battle_tactic,'balanced'));
BEGIN
  IF p_player_id IS NULL OR p_player_id<=0 OR p_city_id IS NULL OR p_city_id<=0
     OR p_site_id IS NULL OR p_site_id<=0 OR p_depart_x NOT BETWEEN 1 AND 200
     OR p_depart_y NOT BETWEEN 1 AND 200 OR p_travel_seconds NOT BETWEEN 1 AND 86400
     OR tactic NOT IN ('assault','balanced','cautious') THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_MISSION','message','Geçersiz kaynak seferi.');
  END IF;

  SELECT * INTO c FROM public.cities WHERE id=p_city_id AND player_id=p_player_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','CITY_NOT_FOUND','message','Koloni bulunamadı.'); END IF;
  IF c.coordinate_x<>p_depart_x OR c.coordinate_y<>p_depart_y THEN
    RETURN jsonb_build_object('success',false,'code','CITY_CHANGED','message','Koloni koordinatı değişti; tekrar deneyin.');
  END IF;

  IF EXISTS(SELECT 1 FROM public.resource_gather_missions WHERE player_id=p_player_id AND status IN ('traveling','gathering','returning')) THEN
    RETURN jsonb_build_object('success',false,'code','ACTIVE_RESOURCE_MISSION','message','Zaten aktif bir kaynak toplama seferin bulunuyor.');
  END IF;

  SELECT * INTO s FROM public.world_sites
  WHERE id=p_site_id AND site_type='resource' AND active=true
    AND resource_type IN ('metal','energy','alloy','crystal') AND COALESCE(resource_stock,0)>0
  FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','RESOURCE_SITE_NOT_FOUND','message','Kaynak noktası kullanılamıyor.'); END IF;

  IF EXISTS(SELECT 1 FROM public.resource_gather_missions WHERE site_id=s.id AND status IN ('traveling','gathering')) THEN
    RETURN jsonb_build_object('success',false,'code','RESOURCE_SITE_BUSY','message','Bu kaynak noktasına başka bir ordu gidiyor veya toplama yapıyor.');
  END IF;

  IF s.resource_guard_active THEN
    IF p_guard_plan IS NULL OR jsonb_typeof(p_guard_plan) IS DISTINCT FROM 'object'
       OR p_guard_plan->'defenderArmy' IS DISTINCT FROM COALESCE(s.resource_guard_army,'[]'::jsonb)
       OR COALESCE(p_guard_plan->>'result','') NOT IN ('Zafer','Yenilgi','Beraberlik')
       OR jsonb_typeof(COALESCE(p_guard_plan->'attackerSurvivorArmy','[]'::jsonb)) IS DISTINCT FROM 'array'
       OR jsonb_typeof(COALESCE(p_guard_plan->'defenderSurvivorArmy','[]'::jsonb)) IS DISTINCT FROM 'array' THEN
      RETURN jsonb_build_object('success',false,'code','GUARD_PLAN_REQUIRED','message','Muhafız savaş planı doğrulanamadı; haritayı yenileyip tekrar deneyin.');
    END IF;
  ELSE
    p_guard_plan:=NULL;
  END IF;

  IF p_army IS NULL OR jsonb_typeof(p_army) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_ARMY','message','Geçersiz birlik seçimi.');
  END IF;

  SELECT COUNT(*),COUNT(DISTINCT value->>'unit_type') INTO cnt,distinct_cnt FROM jsonb_array_elements(p_army) a(value);
  IF cnt<1 OR cnt>6 OR cnt<>distinct_cnt THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_ARMY','message','Geçersiz veya tekrarlanan birlik seçimi.');
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(p_army) a(value)
  LOOP
    typ:=item->>'unit_type'; qty_text:=item->>'quantity'; lvl_text:=item->>'level';
    IF typ NOT IN ('piyade','savunma','saldiri','okcu','tank','hava')
       OR qty_text IS NULL OR qty_text !~ '^[1-9][0-9]*$' OR char_length(qty_text)>10
       OR lvl_text IS NULL OR lvl_text !~ '^[1-9][0-9]*$' OR char_length(lvl_text)>2 THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_ARMY','message','Geçersiz birlik seçimi.');
    END IF;
    qty:=qty_text::bigint; lvl:=lvl_text::integer;
    IF qty>2147483647 OR lvl<1 OR lvl>15 THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_ARMY','message','Geçersiz birlik miktarı veya seviyesi.');
    END IF;

    SELECT * INTO u FROM public.units WHERE city_id=c.id AND unit_type=typ ORDER BY id LIMIT 1 FOR UPDATE;
    IF u.id IS NULL OR COALESCE(u.quantity,0)<qty THEN
      RETURN jsonb_build_object('success',false,'code','INSUFFICIENT_UNITS','message',typ||' için yeterli birlik yok.');
    END IF;
    IF GREATEST(1,COALESCE(u.level,1))<>lvl THEN
      RETURN jsonb_build_object('success',false,'code','UNIT_CHANGED','message','Birlik seviyesi değişti; tekrar deneyin.');
    END IF;

    pop_cost:=CASE typ WHEN 'tank' THEN 3 WHEN 'hava' THEN 2 ELSE 1 END;
    cap:=cap+qty*pop_cost*100;
    clean_army:=clean_army||jsonb_build_array(jsonb_build_object(
      'unit_type',typ,'quantity',qty,'level',lvl,'population_cost',pop_cost
    ));
  END LOOP;

  IF p_guard_plan IS NOT NULL AND p_guard_plan->'attackerArmy' IS DISTINCT FROM clean_army THEN
    RETURN jsonb_build_object('success',false,'code','GUARD_PLAN_STALE','message','Muhafız savaş planı birliklerle uyuşmuyor.');
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(clean_army) a(value)
  LOOP
    typ:=item->>'unit_type'; qty:=(item->>'quantity')::bigint;
    SELECT id INTO unit_id FROM public.units WHERE city_id=c.id AND unit_type=typ ORDER BY id LIMIT 1;
    UPDATE public.units SET quantity=quantity-qty WHERE id=unit_id AND quantity>=qty;
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected<>1 THEN RAISE EXCEPTION 'RESOURCE_GATHER_UNIT_CHANGED'; END IF;
  END LOOP;

  dist:=sqrt(power((s.coordinate_x-c.coordinate_x)::numeric,2)+power((s.coordinate_y-c.coordinate_y)::numeric,2));

  INSERT INTO public.resource_gather_missions(
    player_id,city_id,site_id,status,army,carry_capacity,resource_type,
    depart_at,arrive_at,travel_seconds,distance,depart_x,depart_y,target_x,target_y,
    battle_tactic,guard_plan,updated_at
  ) VALUES(
    p_player_id,c.id,s.id,'traveling',clean_army,cap,s.resource_type,
    now_at,now_at+make_interval(secs=>p_travel_seconds),p_travel_seconds,dist,
    c.coordinate_x,c.coordinate_y,s.coordinate_x,s.coordinate_y,
    tactic,p_guard_plan,now_at
  ) RETURNING * INTO m;

  RETURN jsonb_build_object('success',true,'message','🚚 Birlikler kaynak noktasına gönderildi.',
    'mission',to_jsonb(m),'site',to_jsonb(s));
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_start_resource_gather(
  p_player_id bigint,p_city_id bigint,p_site_id bigint,p_army jsonb,
  p_depart_x integer,p_depart_y integer,p_travel_seconds integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
BEGIN
  RETURN public.nexora_start_resource_gather_v2(
    p_player_id,p_city_id,p_site_id,p_army,p_depart_x,p_depart_y,p_travel_seconds,
    'balanced',NULL
  );
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_sync_resource_gather_mission(p_player_id bigint,p_mission_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  m public.resource_gather_missions%ROWTYPE;
  s public.world_sites%ROWTYPE;
  c public.cities%ROWTYPE;
  now_at timestamptz:=clock_timestamp();
  gathered bigint:=0;
  new_stock bigint:=0;
  remaining integer:=0;
  attacker_survivors jsonb;
  defender_survivors jsonb;
  result_text text;
  survivor_pop bigint;
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
            gather_complete_at=now_at+make_interval(secs=>GREATEST(5,COALESCE(s.resource_gather_seconds,30))),
            updated_at=now_at
        WHERE id=m.id RETURNING * INTO m;
        RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),
          'guardBattle',m.guard_plan,'remainingSeconds',GREATEST(5,COALESCE(s.resource_gather_seconds,30)));
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
        gather_complete_at=now_at+make_interval(secs=>GREATEST(5,COALESCE(s.resource_gather_seconds,30))),
        updated_at=now_at
    WHERE id=m.id RETURNING * INTO m;

    RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),
      'remainingSeconds',GREATEST(5,COALESCE(s.resource_gather_seconds,30)));
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
    SET status='returning',gathered_amount=gathered,
        return_at=now_at+make_interval(secs=>travel_seconds),updated_at=now_at
    WHERE id=m.id RETURNING * INTO m;

    RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),
      'gatheredAmount',gathered,'remainingSeconds',m.travel_seconds);
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

  RETURN jsonb_build_object('success',true,'completed',true,'alreadyCompleted',false,
    'mission',to_jsonb(m),'resourceType',m.resource_type,'gatheredAmount',m.gathered_amount);
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_start_resource_conflict(
  p_attacker_player_id bigint,p_attacker_city_id bigint,p_defender_gather_mission_id bigint,
  p_army jsonb,p_battle_tactic text,p_battle_plan jsonb,p_travel_seconds integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  c public.cities%ROWTYPE;
  target public.resource_gather_missions%ROWTYPE;
  s public.world_sites%ROWTYPE;
  conflict public.resource_conflict_missions%ROWTYPE;
  u public.units%ROWTYPE;
  item jsonb;
  clean_army jsonb:='[]'::jsonb;
  typ text; qty_text text; lvl_text text; qty bigint; lvl integer;
  cnt integer; distinct_cnt integer; unit_id bigint; affected integer;
  tactic text:=lower(COALESCE(p_battle_tactic,'balanced'));
  now_at timestamptz:=clock_timestamp();
  attacker_alliance bigint;
  defender_alliance bigint;
  attacker_protection jsonb;
  defender_protection jsonb;
BEGIN
  IF p_attacker_player_id IS NULL OR p_attacker_player_id<=0 OR p_attacker_city_id IS NULL OR p_attacker_city_id<=0
     OR p_defender_gather_mission_id IS NULL OR p_defender_gather_mission_id<=0
     OR p_travel_seconds NOT BETWEEN 1 AND 86400 OR tactic NOT IN ('assault','balanced','cautious')
     OR p_battle_plan IS NULL OR jsonb_typeof(p_battle_plan) IS DISTINCT FROM 'object'
     OR COALESCE(p_battle_plan->>'result','') NOT IN ('Zafer','Yenilgi','Beraberlik') THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_CONFLICT','message','Geçersiz kaynak çatışması.');
  END IF;

  SELECT * INTO c FROM public.cities WHERE id=p_attacker_city_id AND player_id=p_attacker_player_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','CITY_NOT_FOUND','message','Koloni bulunamadı.'); END IF;

  SELECT * INTO target FROM public.resource_gather_missions
  WHERE id=p_defender_gather_mission_id AND status='gathering'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','TARGET_LEFT','message','Kaynak ordusu artık bu noktada değil.'); END IF;

  IF target.player_id=p_attacker_player_id THEN
    RETURN jsonb_build_object('success',false,'code','SELF_TARGET','message','Kendi kaynak orduna saldıramazsın.');
  END IF;

  SELECT * INTO s FROM public.world_sites WHERE id=target.site_id AND site_type='resource' AND active=true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','RESOURCE_SITE_NOT_FOUND','message','Kaynak noktası bulunamadı.'); END IF;

  IF target.gather_complete_at IS NULL OR target.gather_complete_at<=now_at+make_interval(secs=>p_travel_seconds) THEN
    RETURN jsonb_build_object('success',false,'code','TARGET_LEAVING','message','Hedef ordu sen varmadan kaynak noktasından ayrılacak.');
  END IF;

  IF EXISTS(SELECT 1 FROM public.resource_conflict_missions WHERE attacker_player_id=p_attacker_player_id AND status IN ('traveling','returning')) THEN
    RETURN jsonb_build_object('success',false,'code','ACTIVE_RESOURCE_CONFLICT','message','Zaten aktif bir kaynak çatışma seferin var.');
  END IF;

  IF EXISTS(SELECT 1 FROM public.resource_gather_missions WHERE player_id=p_attacker_player_id AND status IN ('traveling','gathering','returning')) THEN
    RETURN jsonb_build_object('success',false,'code','ACTIVE_RESOURCE_MISSION','message','Aktif kaynak seferin varken kaynak ordusuna saldırı gönderemezsin.');
  END IF;

  IF EXISTS(SELECT 1 FROM public.resource_conflict_missions WHERE site_id=s.id AND status='traveling') THEN
    RETURN jsonb_build_object('success',false,'code','RESOURCE_UNDER_ATTACK','message','Bu kaynak ordusuna başka bir saldırı zaten yolda.');
  END IF;

  SELECT alliance_id INTO attacker_alliance FROM public.alliance_members WHERE player_id=p_attacker_player_id ORDER BY id LIMIT 1;
  SELECT alliance_id INTO defender_alliance FROM public.alliance_members WHERE player_id=target.player_id ORDER BY id LIMIT 1;
  IF attacker_alliance IS NOT NULL AND attacker_alliance=defender_alliance THEN
    RETURN jsonb_build_object('success',false,'code','SAME_ALLIANCE','message','Aynı ittifaktaki oyuncunun kaynak ordusuna saldıramazsın.');
  END IF;

  attacker_protection:=public.nexora_pvp_protection_state(p_attacker_player_id);
  defender_protection:=public.nexora_pvp_protection_state(target.player_id);
  IF COALESCE((attacker_protection->>'protected')::boolean,false) THEN
    RETURN jsonb_build_object('success',false,'code','ATTACKER_PROTECTED','message','PvP koruman sürerken kaynak ordusuna saldıramazsın.');
  END IF;
  IF COALESCE((defender_protection->>'protected')::boolean,false) THEN
    RETURN jsonb_build_object('success',false,'code','DEFENDER_PROTECTED','message','Hedef oyuncunun PvP koruması aktif.');
  END IF;

  IF p_battle_plan->'defenderArmy' IS DISTINCT FROM target.army THEN
    RETURN jsonb_build_object('success',false,'code','DEFENDER_CHANGED','message','Kaynak ordusu değişti; savaş planı yenilenmeli.');
  END IF;

  IF p_army IS NULL OR jsonb_typeof(p_army) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_ARMY','message','Geçersiz birlik seçimi.');
  END IF;
  SELECT COUNT(*),COUNT(DISTINCT value->>'unit_type') INTO cnt,distinct_cnt FROM jsonb_array_elements(p_army) a(value);
  IF cnt<1 OR cnt>6 OR cnt<>distinct_cnt THEN RETURN jsonb_build_object('success',false,'code','INVALID_ARMY','message','Geçersiz birlik seçimi.'); END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(p_army) a(value)
  LOOP
    typ:=item->>'unit_type'; qty_text:=item->>'quantity'; lvl_text:=item->>'level';
    IF typ NOT IN ('piyade','savunma','saldiri','okcu','tank','hava')
       OR qty_text IS NULL OR qty_text !~ '^[1-9][0-9]*$' OR lvl_text IS NULL OR lvl_text !~ '^[1-9][0-9]*$' THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_ARMY','message','Geçersiz birlik seçimi.');
    END IF;
    qty:=qty_text::bigint; lvl:=lvl_text::integer;
    SELECT * INTO u FROM public.units WHERE city_id=c.id AND unit_type=typ ORDER BY id LIMIT 1 FOR UPDATE;
    IF u.id IS NULL OR COALESCE(u.quantity,0)<qty OR GREATEST(1,COALESCE(u.level,1))<>lvl THEN
      RETURN jsonb_build_object('success',false,'code','UNIT_CHANGED','message','Birlik durumu değişti; tekrar deneyin.');
    END IF;
    clean_army:=clean_army||jsonb_build_array(jsonb_build_object(
      'unit_type',typ,'quantity',qty,'level',lvl,
      'population_cost',CASE typ WHEN 'tank' THEN 3 WHEN 'hava' THEN 2 ELSE 1 END
    ));
  END LOOP;

  IF p_battle_plan->'attackerArmy' IS DISTINCT FROM clean_army
     OR jsonb_typeof(COALESCE(p_battle_plan->'attackerSurvivorArmy','[]'::jsonb)) IS DISTINCT FROM 'array'
     OR jsonb_typeof(COALESCE(p_battle_plan->'defenderSurvivorArmy','[]'::jsonb)) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('success',false,'code','BATTLE_PLAN_STALE','message','Savaş planı birliklerle uyuşmuyor.');
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(clean_army) a(value)
  LOOP
    typ:=item->>'unit_type'; qty:=(item->>'quantity')::bigint;
    SELECT id INTO unit_id FROM public.units WHERE city_id=c.id AND unit_type=typ ORDER BY id LIMIT 1;
    UPDATE public.units SET quantity=quantity-qty WHERE id=unit_id AND quantity>=qty;
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected<>1 THEN RAISE EXCEPTION 'RESOURCE_CONFLICT_UNIT_CHANGED'; END IF;
  END LOOP;

  INSERT INTO public.resource_conflict_missions(
    attacker_player_id,defender_player_id,attacker_city_id,defender_gather_mission_id,site_id,status,
    attacker_army,attacker_survivor_army,defender_survivor_army,battle_plan,battle_tactic,
    depart_at,arrive_at,travel_seconds,depart_x,depart_y,target_x,target_y,updated_at
  ) VALUES(
    p_attacker_player_id,target.player_id,c.id,target.id,s.id,'traveling',
    clean_army,p_battle_plan->'attackerSurvivorArmy',p_battle_plan->'defenderSurvivorArmy',
    p_battle_plan,tactic,now_at,now_at+make_interval(secs=>p_travel_seconds),p_travel_seconds,
    c.coordinate_x,c.coordinate_y,s.coordinate_x,s.coordinate_y,now_at
  ) RETURNING * INTO conflict;

  RETURN jsonb_build_object('success',true,'message','⚔️ Kaynak ordusuna saldırı başladı.','conflict',to_jsonb(conflict));
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_sync_resource_conflict(p_player_id bigint,p_conflict_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
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
    UPDATE public.resource_gather_missions
    SET status='returning',army=defender_survivors,gathered_amount=0,gather_complete_at=NULL,
        return_at=now_at+make_interval(secs=>travel_seconds),updated_at=now_at
    WHERE id=target.id;

    INSERT INTO public.resource_gather_missions(
      player_id,city_id,site_id,status,army,carry_capacity,resource_type,
      depart_at,arrive_at,gather_complete_at,travel_seconds,distance,
      depart_x,depart_y,target_x,target_y,battle_tactic,guard_plan,updated_at
    )
    VALUES(
      x.attacker_player_id,x.attacker_city_id,x.site_id,'gathering',attacker_survivors,GREATEST(1,attacker_pop*100),s.resource_type,
      x.depart_at,now_at,now_at+make_interval(secs=>GREATEST(5,COALESCE(s.resource_gather_seconds,30))),
      x.travel_seconds,sqrt(power((x.target_x-x.depart_x)::numeric,2)+power((x.target_y-x.depart_y)::numeric,2)),
      x.depart_x,x.depart_y,x.target_x,x.target_y,x.battle_tactic,NULL,now_at
    ) RETURNING id INTO takeover_id;

    UPDATE public.resource_conflict_missions
    SET status='completed',result='Zafer',takeover_mission_id=takeover_id,completed_at=now_at,updated_at=now_at
    WHERE id=x.id RETURNING * INTO x;

    RETURN jsonb_build_object('success',true,'completed',true,'conflict',to_jsonb(x),
      'takeoverMissionId',takeover_id,'battle',x.battle_plan);
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
CREATE OR REPLACE FUNCTION public.nexora_resource_gather_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  rec record;
  conflicts integer:=0;
  gathers integer:=0;
  respawned integer:=0;
  sid bigint;
  i integer;
BEGIN
  FOR rec IN
    SELECT id,attacker_player_id
    FROM public.resource_conflict_missions
    WHERE (status='traveling' AND arrive_at<=clock_timestamp())
       OR (status='returning' AND return_at IS NOT NULL AND return_at<=clock_timestamp())
    ORDER BY COALESCE(return_at,arrive_at),id
    LIMIT 20
  LOOP
    PERFORM public.nexora_sync_resource_conflict(rec.attacker_player_id,rec.id);
    conflicts:=conflicts+1;
  END LOOP;

  FOR rec IN
    SELECT id,player_id
    FROM public.resource_gather_missions
    WHERE (status='traveling' AND arrive_at<=clock_timestamp())
       OR (status='gathering' AND gather_complete_at IS NOT NULL AND gather_complete_at<=clock_timestamp())
       OR (status='returning' AND return_at IS NOT NULL AND return_at<=clock_timestamp())
    ORDER BY COALESCE(return_at,gather_complete_at,arrive_at),id
    LIMIT 30
  LOOP
    PERFORM public.nexora_sync_resource_gather_mission(rec.player_id,rec.id);
    gathers:=gathers+1;
  END LOOP;

  FOR i IN 1..10 LOOP
    sid:=public.nexora_respawn_due_resource_site();
    EXIT WHEN sid IS NULL;
    respawned:=respawned+1;
  END LOOP;

  RETURN jsonb_build_object('success',true,'conflicts',conflicts,'gathers',gathers,'respawned',respawned);
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_respawn_due_resource_site()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE s public.world_sites%ROWTYPE; x integer; y integer; now_at timestamptz:=clock_timestamp();
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('teryndis_resource_respawn'));
  SELECT * INTO s FROM public.world_sites
  WHERE site_type='resource' AND active=false AND resource_respawn_at IS NOT NULL AND resource_respawn_at<=now_at
    AND NOT EXISTS(SELECT 1 FROM public.resource_gather_missions m WHERE m.site_id=world_sites.id AND m.status IN ('traveling','gathering'))
  ORDER BY resource_respawn_at,id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT gx,gy INTO x,y FROM generate_series(3,197) gx CROSS JOIN generate_series(3,197) gy
  WHERE NOT(gx=s.coordinate_x AND gy=s.coordinate_y)
    AND NOT EXISTS(SELECT 1 FROM public.cities c WHERE c.coordinate_x=gx AND c.coordinate_y=gy)
    AND NOT EXISTS(SELECT 1 FROM public.world_sites w WHERE w.id<>s.id AND w.coordinate_x=gx AND w.coordinate_y=gy)
  ORDER BY md5(s.id::text||':'||s.resource_respawn_at::text||':'||gx::text||':'||gy::text) LIMIT 1;
  IF x IS NULL OR y IS NULL THEN RETURN NULL; END IF;

  UPDATE public.world_sites SET coordinate_x=x,coordinate_y=y,
    resource_stock=GREATEST(1,COALESCE(resource_capacity,1)),
    resource_respawn_at=NULL,
    resource_guard_army=COALESCE(resource_guard_template,'[]'::jsonb),
    resource_guard_active=COALESCE(jsonb_array_length(resource_guard_template),0)>0,
    active=true WHERE id=s.id;
  RETURN s.id;
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_active_military_population(p_player_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

    UNION ALL

    SELECT status, army, NULL::jsonb AS result
      FROM public.resource_gather_missions
     WHERE player_id = p_player_id
       AND status IN ('traveling','gathering','returning')

    UNION ALL

    SELECT status, attacker_army AS army,
      CASE
        WHEN status='returning' THEN jsonb_build_object('survivorArmy',attacker_survivor_army)
        ELSE NULL::jsonb
      END AS result
      FROM public.resource_conflict_missions
     WHERE attacker_player_id = p_player_id
       AND status IN ('traveling','returning')
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
$function$;
CREATE OR REPLACE FUNCTION public.nexora_world_control_sites(p_player_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
            WHEN s.site_type = 'resource' THEN 'resource'
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
            WHEN s.site_type = 'resource' THEN false
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
            WHEN s.site_type = 'resource' THEN false
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
        'resource_collector_mission_id',
          (SELECT rg.id FROM public.resource_gather_missions rg
            WHERE rg.site_id=s.id AND rg.status='gathering'
            ORDER BY rg.id DESC LIMIT 1),
        'resource_collector_player_id',
          (SELECT rg.player_id FROM public.resource_gather_missions rg
            WHERE rg.site_id=s.id AND rg.status='gathering'
            ORDER BY rg.id DESC LIMIT 1),
        'resource_collector_username',
          (SELECT rp.username FROM public.resource_gather_missions rg
            JOIN public.players rp ON rp.id=rg.player_id
            WHERE rg.site_id=s.id AND rg.status='gathering'
            ORDER BY rg.id DESC LIMIT 1),
        'resource_collector_alliance_id',
          (SELECT ram.alliance_id FROM public.resource_gather_missions rg
            LEFT JOIN public.alliance_members ram ON ram.player_id=rg.player_id
            WHERE rg.site_id=s.id AND rg.status='gathering'
            ORDER BY rg.id DESC,ram.id LIMIT 1),
        'resource_gather_complete_at',
          (SELECT rg.gather_complete_at FROM public.resource_gather_missions rg
            WHERE rg.site_id=s.id AND rg.status='gathering'
            ORDER BY rg.id DESC LIMIT 1),
        'resource_under_attack',
          EXISTS(SELECT 1 FROM public.resource_conflict_missions rc
            WHERE rc.site_id=s.id AND rc.status='traveling'),
        'is_owned_by_viewer',
          CASE
            WHEN s.site_type = 'resource' THEN false
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
$function$;

REVOKE ALL ON FUNCTION public.nexora_resource_return_army(bigint,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.nexora_start_resource_gather_v2(bigint,bigint,bigint,jsonb,integer,integer,integer,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.nexora_start_resource_conflict(bigint,bigint,bigint,jsonb,text,jsonb,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.nexora_sync_resource_conflict(bigint,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_resource_return_army(bigint,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_start_resource_gather_v2(bigint,bigint,bigint,jsonb,integer,integer,integer,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_start_resource_conflict(bigint,bigint,bigint,jsonb,text,jsonb,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_sync_resource_conflict(bigint,bigint) TO service_role;

COMMIT;
