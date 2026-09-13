-- Phase 10: commit resource spending and its job together.
-- Apply AFTER 018 and BEFORE deploying the matching api/auth.js.
-- No trade functions or production data are replaced.
BEGIN;

-- Costs/durations below are computed by the trusted backend, never request body.
-- The expected level is rechecked under the city + job row locks.
CREATE OR REPLACE FUNCTION public.nexora_start_building_upgrade(
  p_player_id bigint, p_city_id bigint, p_type text, p_level integer,
  p_cost jsonb, p_duration integer
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  c public.cities%ROWTYPE;
  b public.buildings%ROWTYPE;
  spent jsonb;
  ready timestamptz;
BEGIN
  SELECT * INTO c FROM public.cities WHERE player_id=p_player_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF c.id IS NULL OR c.id<>p_city_id THEN RAISE EXCEPTION 'Koloni bulunamadı.'; END IF;
  SELECT * INTO b FROM public.buildings WHERE city_id=c.id AND building_type=p_type ORDER BY id LIMIT 1 FOR UPDATE;
  IF COALESCE(b.is_under_construction,false) OR COALESCE(b.level,0) IS DISTINCT FROM p_level THEN
    RETURN jsonb_build_object('success',false,'message','Bina durumu değişti; tekrar yükle.');
  END IF;
  IF p_level IS NULL OR p_level<0 OR p_duration IS NULL OR p_duration<=0 THEN RAISE EXCEPTION 'Geçersiz inşaat.'; END IF;
  spent := public.nexora_spend_city_resources(p_player_id,(p_cost->>'metal')::bigint,(p_cost->>'energy')::bigint,(p_cost->>'water')::bigint,(p_cost->>'crystal')::bigint);
  IF NOT (spent->>'success')::boolean THEN RETURN spent; END IF;
  ready := clock_timestamp() + make_interval(secs=>p_duration);
  IF b.id IS NULL THEN
    INSERT INTO public.buildings(city_id,building_type,level,is_under_construction,upgrade_ready_at)
      VALUES(c.id,p_type,0,true,ready) RETURNING * INTO b;
  ELSE
    UPDATE public.buildings SET is_under_construction=true,upgrade_ready_at=ready WHERE id=b.id RETURNING * INTO b;
  END IF;
  RETURN spent || jsonb_build_object('building',to_jsonb(b),'finishAt',ready);
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_start_research_upgrade(
  p_player_id bigint, p_city_id bigint, p_column text, p_level integer,
  p_cost jsonb, p_duration integer
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  c public.cities%ROWTYPE;
  r public.research%ROWTYPE;
  spent jsonb;
  ready timestamptz;
BEGIN
  SELECT * INTO c FROM public.cities WHERE player_id=p_player_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF c.id IS NULL OR c.id<>p_city_id THEN RAISE EXCEPTION 'Koloni bulunamadı.'; END IF;
  IF p_column IS NULL OR p_column NOT IN ('production_level','combat_level','defense_level','crystal_level','general_power_level','unit_attack_level','unit_defense_level','unit_hp_level','travel_speed_level') THEN RAISE EXCEPTION 'Geçersiz araştırma.'; END IF;
  SELECT * INTO r FROM public.research WHERE player_id=p_player_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF r.upgrade_ready_at IS NOT NULL OR COALESCE((to_jsonb(r)->>p_column)::integer,0) IS DISTINCT FROM p_level THEN
    RETURN jsonb_build_object('success',false,'message','Araştırma durumu değişti; tekrar yükle.');
  END IF;
  IF p_level IS NULL OR p_level<0 OR p_level>=15 OR p_duration IS NULL OR p_duration<=0 THEN RAISE EXCEPTION 'Geçersiz araştırma.'; END IF;
  spent := public.nexora_spend_city_resources(p_player_id,(p_cost->>'metal')::bigint,(p_cost->>'energy')::bigint,(p_cost->>'water')::bigint,(p_cost->>'crystal')::bigint);
  IF NOT (spent->>'success')::boolean THEN RETURN spent; END IF;
  ready := clock_timestamp() + make_interval(secs=>p_duration);
  IF r.id IS NULL THEN
    INSERT INTO public.research(player_id,production_level,combat_level,defense_level,crystal_level,general_power_level,unit_attack_level,unit_defense_level,unit_hp_level,travel_speed_level,upgrade_ready_at,pending_column)
      VALUES(p_player_id,0,0,0,0,0,0,0,0,0,ready,p_column) RETURNING * INTO r;
  ELSE
    UPDATE public.research SET upgrade_ready_at=ready,pending_column=p_column WHERE id=r.id RETURNING * INTO r;
  END IF;
  RETURN spent || jsonb_build_object('research',to_jsonb(r),'finishAt',ready);
END;
$$;

-- The city lock also serializes queue completion with training admission.
-- Moving a quantity from queue to units must not temporarily free capacity.
CREATE OR REPLACE FUNCTION public.nexora_complete_unit_training(p_player_id bigint,p_city_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  c public.cities%ROWTYPE;
  q public.unit_production_queue%ROWTYPE;
  u public.units%ROWTYPE;
  s public.unit_levels%ROWTYPE;
  remaining jsonb;
BEGIN
  SELECT * INTO c FROM public.cities WHERE id=p_city_id AND player_id=p_player_id FOR UPDATE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'Koloni bulunamadı.'; END IF;
  FOR q IN SELECT * FROM public.unit_production_queue
    WHERE player_id=p_player_id AND city_id=c.id AND status='training' AND finish_at<=clock_timestamp()
    ORDER BY id FOR UPDATE
  LOOP
    SELECT * INTO u FROM public.units WHERE city_id=c.id AND unit_type=q.unit_type ORDER BY id LIMIT 1 FOR UPDATE;
    IF u.id IS NOT NULL THEN
      UPDATE public.units SET quantity=COALESCE(quantity,0)+q.quantity WHERE id=u.id;
    ELSE
      SELECT * INTO s FROM public.unit_levels WHERE unit_type=q.unit_type AND level=1 LIMIT 1;
      INSERT INTO public.units(city_id,unit_type,quantity,level,attack,defense,hp,speed,population_cost)
        VALUES(c.id,q.unit_type,q.quantity,1,COALESCE(s.attack,0),COALESCE(s.defense,0),COALESCE(s.hp,0),COALESCE(s.speed,100),
          CASE q.unit_type WHEN 'tank' THEN 3 WHEN 'hava' THEN 2 ELSE 1 END);
    END IF;
    UPDATE public.unit_production_queue SET status='completed' WHERE id=q.id;
  END LOOP;
  SELECT COALESCE(jsonb_agg(t ORDER BY t.finish_at,t.id),'[]'::jsonb) INTO remaining
    FROM public.unit_production_queue t WHERE player_id=p_player_id AND city_id=c.id AND status='training';
  RETURN jsonb_build_object('success',true,'queue',remaining);
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_start_unit_training(p_player_id bigint,p_city_id bigint,p_type text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  c public.cities%ROWTYPE;
  q public.unit_production_queue%ROWTYPE;
  cfg record;
  spent jsonb;
  population bigint;
  housing integer;
  barracks integer;
  army integer;
  duration integer;
BEGIN
  SELECT * INTO c FROM public.cities WHERE player_id=p_player_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF c.id IS NULL OR c.id<>p_city_id THEN RAISE EXCEPTION 'Koloni bulunamadı.'; END IF;
  SELECT * INTO cfg FROM (VALUES
    ('piyade',100,20,1,20),('savunma',150,40,1,24),('saldiri',200,75,1,28),
    ('okcu',220,90,1,30),('tank',700,220,3,55),('hava',650,260,2,50)
  ) AS config(kind,metal,energy,pop,train) WHERE kind=p_type;
  IF NOT FOUND THEN RAISE EXCEPTION 'Geçersiz birlik türü.'; END IF;
  SELECT 100+50*GREATEST(0,COALESCE((SELECT level FROM public.buildings WHERE city_id=c.id AND building_type='Konut' ORDER BY id LIMIT 1),0)) INTO housing;
  SELECT GREATEST(0,COALESCE((SELECT level FROM public.buildings WHERE city_id=c.id AND building_type='Kışla' ORDER BY id LIMIT 1),0)) INTO barracks;
  army := 50+50*barracks;
  SELECT COALESCE(SUM(amount),0) INTO population FROM (
    SELECT quantity::bigint * CASE unit_type WHEN 'tank' THEN 3 WHEN 'hava' THEN 2
      WHEN 'piyade' THEN 1 WHEN 'savunma' THEN 1 WHEN 'saldiri' THEN 1 WHEN 'okcu' THEN 1
      ELSE COALESCE(NULLIF(population_cost,0),1) END AS amount FROM public.units WHERE city_id=c.id
    UNION ALL
    SELECT quantity::bigint * CASE unit_type WHEN 'tank' THEN 3 WHEN 'hava' THEN 2 ELSE 1 END
      FROM public.unit_production_queue WHERE city_id=c.id AND player_id=p_player_id AND status='training'
  ) pop;
  IF population+cfg.pop>housing OR population+cfg.pop>army THEN
    RETURN jsonb_build_object('success',false,'message',CASE WHEN population+cfg.pop>housing THEN 'Konut kapasitesi yetersiz.' ELSE 'Kışla/ordu kapasitesi yetersiz.' END,
      'population',population,'population_capacity',housing,'army_capacity',army);
  END IF;
  spent := public.nexora_spend_city_resources(p_player_id,cfg.metal::bigint,cfg.energy::bigint,0::bigint,0::bigint);
  IF NOT (spent->>'success')::boolean THEN RETURN spent; END IF;
  duration := GREATEST(10,round(cfg.train*GREATEST(0.35,1-GREATEST(1,barracks)*0.04))::integer);
  INSERT INTO public.unit_production_queue(player_id,city_id,unit_type,quantity,finish_at)
    VALUES(p_player_id,c.id,p_type,1,clock_timestamp()+make_interval(secs=>duration)) RETURNING * INTO q;
  RETURN spent || jsonb_build_object('production',to_jsonb(q),'population',population,'population_capacity',housing,'army_capacity',army);
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_start_building_upgrade(bigint,bigint,text,integer,jsonb,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_start_building_upgrade(bigint,bigint,text,integer,jsonb,integer) TO service_role;
REVOKE ALL ON FUNCTION public.nexora_start_research_upgrade(bigint,bigint,text,integer,jsonb,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_start_research_upgrade(bigint,bigint,text,integer,jsonb,integer) TO service_role;
REVOKE ALL ON FUNCTION public.nexora_complete_unit_training(bigint,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_complete_unit_training(bigint,bigint) TO service_role;
REVOKE ALL ON FUNCTION public.nexora_start_unit_training(bigint,bigint,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_start_unit_training(bigint,bigint,text) TO service_role;


-- Unit upgrades were another absolute city balance writer racing trade.
CREATE OR REPLACE FUNCTION public.nexora_upgrade_unit_atomic(p_player_id bigint,p_city_id bigint,p_unit_id bigint,p_level integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  c public.cities%ROWTYPE;
  u public.units%ROWTYPE;
  s public.unit_levels%ROWTYPE;
  spent jsonb;
BEGIN
  SELECT * INTO c FROM public.cities WHERE player_id=p_player_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF c.id IS NULL OR c.id<>p_city_id THEN RAISE EXCEPTION 'Koloni bulunamadı.'; END IF;
  SELECT * INTO u FROM public.units WHERE id=p_unit_id AND city_id=c.id FOR UPDATE;
  IF u.id IS NULL THEN RAISE EXCEPTION 'Birlik bulunamadı.'; END IF;
  IF p_level IS NULL OR p_level<1 OR p_level>=15 OR GREATEST(1,COALESCE(u.level,1))<>p_level THEN
    RETURN jsonb_build_object('success',false,'message','Birlik seviyesi değişti; tekrar yükle.');
  END IF;
  SELECT * INTO s FROM public.unit_levels WHERE unit_type=u.unit_type AND level=p_level+1 LIMIT 1;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Bir sonraki seviye verisi bulunamadı.'; END IF;
  spent := public.nexora_spend_city_resources(p_player_id,p_level::bigint*500,p_level::bigint*100,0::bigint,p_level::bigint*50);
  IF NOT (spent->>'success')::boolean THEN RETURN spent; END IF;
  UPDATE public.units SET level=p_level+1,attack=s.attack,defense=s.defense,hp=s.hp,speed=s.speed
    WHERE id=u.id RETURNING * INTO u;
  RETURN spent || jsonb_build_object('unit',to_jsonb(u));
END;
$$;

-- Preserve the existing battle calculation; only settle its resource transfer
-- from locked live balances. The marker prevents replaying the same loot.
ALTER TABLE public.military_missions ADD COLUMN IF NOT EXISTS settled_loot jsonb;
CREATE OR REPLACE FUNCTION public.nexora_settle_mission_loot(p_player_id bigint,p_mission_id bigint,p_loot_rate numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  probe public.military_missions%ROWTYPE;
  m public.military_missions%ROWTYPE;
  attacker public.cities%ROWTYPE;
  defender public.cities%ROWTYPE;
  loot jsonb := '{"metal":0,"energy":0,"water":0,"crystal":0}'::jsonb;
  resource text;
  amount bigint;
BEGIN
  IF p_loot_rate IS NULL OR p_loot_rate NOT IN (0,0.10) THEN RAISE EXCEPTION 'Geçersiz yağma oranı.'; END IF;
  SELECT * INTO probe FROM public.military_missions WHERE id=p_mission_id;
  IF probe.id IS NULL OR p_player_id IS NULL OR (p_player_id IS DISTINCT FROM probe.attacker_player_id AND p_player_id IS DISTINCT FROM probe.defender_player_id) THEN RAISE EXCEPTION 'Bu sefere erişemezsin.'; END IF;
  -- Same two-city order as Trade V2. Never acquire an offer or trade transaction.
  PERFORM id FROM public.cities WHERE id IN (probe.attacker_city_id,probe.defender_city_id) ORDER BY id FOR UPDATE;
  SELECT * INTO m FROM public.military_missions WHERE id=p_mission_id FOR UPDATE;
  IF m.settled_loot IS NOT NULL THEN RETURN jsonb_build_object('success',true,'loot',m.settled_loot); END IF;
  IF m.status IS DISTINCT FROM 'resolving' THEN RAISE EXCEPTION 'Sefer çözüm aşamasında değil.'; END IF;
  SELECT * INTO attacker FROM public.cities WHERE id=m.attacker_city_id;
  SELECT * INTO defender FROM public.cities WHERE id=m.defender_city_id;
  IF attacker.id IS NOT NULL AND defender.id IS NOT NULL AND attacker.id<>defender.id AND p_loot_rate>0 THEN
    FOREACH resource IN ARRAY ARRAY['metal','energy','water','crystal'] LOOP
      amount := LEAST(
        FLOOR(GREATEST(0,COALESCE((to_jsonb(defender)->>resource)::bigint,0))*p_loot_rate)::bigint,
        GREATEST(0,public.nexora_trade_storage_capacity(attacker.id,resource)-COALESCE((to_jsonb(attacker)->>resource)::bigint,0))
      );
      -- Identifiers come only from the fixed array above.
      EXECUTE format('UPDATE public.cities SET %1$I=COALESCE(%1$I,0)-$1 WHERE id=$2',resource) USING amount,defender.id;
      EXECUTE format('UPDATE public.cities SET %1$I=COALESCE(%1$I,0)+$1 WHERE id=$2',resource) USING amount,attacker.id;
      loot := jsonb_set(loot,ARRAY[resource],to_jsonb(amount));
    END LOOP;
  END IF;
  UPDATE public.military_missions SET settled_loot=loot WHERE id=m.id;
  RETURN jsonb_build_object('success',true,'loot',loot);
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_upgrade_unit_atomic(bigint,bigint,bigint,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_upgrade_unit_atomic(bigint,bigint,bigint,integer) TO service_role;
REVOKE ALL ON FUNCTION public.nexora_settle_mission_loot(bigint,bigint,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_settle_mission_loot(bigint,bigint,numeric) TO service_role;

COMMIT;
