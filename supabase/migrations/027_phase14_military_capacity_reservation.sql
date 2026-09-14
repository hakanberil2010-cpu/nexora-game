-- NEXORA Phase 14.6
-- Active military missions continue to reserve housing and army capacity.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_military_army_population(p_army jsonb)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  item jsonb;
  unit_type text;
  quantity_text text;
  quantity bigint;
  population_cost integer;
  total numeric := 0;
BEGIN
  IF p_army IS NULL OR jsonb_typeof(p_army) IS DISTINCT FROM 'array' THEN
    RETURN NULL;
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(p_army) entry(value)
  LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN
      RETURN NULL;
    END IF;

    unit_type := item->>'unit_type';
    quantity_text := item->>'quantity';

    IF unit_type IS NULL
       OR unit_type NOT IN ('piyade','savunma','saldiri','okcu','tank','hava')
       OR quantity_text IS NULL
       OR quantity_text !~ '^[0-9]+$'
       OR char_length(quantity_text) > 10 THEN
      RETURN NULL;
    END IF;

    quantity := quantity_text::bigint;
    IF quantity > 2147483647 THEN
      RETURN NULL;
    END IF;

    population_cost := CASE unit_type
      WHEN 'tank' THEN 3
      WHEN 'hava' THEN 2
      ELSE 1
    END;
    total := total + quantity::numeric * population_cost;
  END LOOP;

  RETURN LEAST(total, 9223372036854775807::numeric)::bigint;
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_active_military_population(p_player_id bigint)
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
    SELECT id, status, army, result
    FROM public.military_missions
    WHERE attacker_player_id = p_player_id
      AND status IN ('traveling','resolving','returning')
    ORDER BY id
  LOOP
    mission_population := NULL;

    IF mission.status = 'returning'
       AND jsonb_typeof(mission.result) = 'object'
       AND jsonb_typeof(mission.result->'survivorArmy') = 'array' THEN
      mission_population := public.nexora_military_army_population(
        mission.result->'survivorArmy'
      );
    END IF;

    IF mission_population IS NULL THEN
      mission_population := public.nexora_military_army_population(mission.army);
    END IF;

    total := total + COALESCE(mission_population, 0);
  END LOOP;

  RETURN LEAST(total, 9223372036854775807::numeric)::bigint;
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
  population := population + public.nexora_active_military_population(p_player_id);
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

REVOKE ALL ON FUNCTION public.nexora_military_army_population(jsonb)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_military_army_population(jsonb)
TO service_role;

REVOKE ALL ON FUNCTION public.nexora_active_military_population(bigint)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_active_military_population(bigint)
TO service_role;

REVOKE ALL ON FUNCTION public.nexora_start_unit_training(bigint,bigint,text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_start_unit_training(bigint,bigint,text)
TO service_role;

COMMIT;
