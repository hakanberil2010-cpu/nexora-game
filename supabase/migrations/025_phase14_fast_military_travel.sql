-- NEXORA Phase 14.4
-- Atomic battle resolution + atomic survivor return.
-- Apply AFTER 023 and BEFORE deploying the matching api/auth.js change.
-- Existing combat math stays in the trusted backend; all DB settlement is committed atomically.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_resolve_military_mission(
  p_player_id bigint,
  p_mission_id bigint,
  p_defender_snapshot jsonb,
  p_defender_losses jsonb,
  p_report_base jsonb,
  p_attack_power integer,
  p_defense_power integer,
  p_loot_rate numeric,
  p_battle_points integer,
  p_winner_player_id bigint,
  p_return_seconds integer
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  probe public.military_missions%ROWTYPE;
  mission public.military_missions%ROWTYPE;
  attacker public.cities%ROWTYPE;
  defender public.cities%ROWTYPE;
  unit_row public.units%ROWTYPE;
  snapshot_item jsonb;
  snapshot_id_text text;
  snapshot_type text;
  snapshot_quantity_text text;
  snapshot_level_text text;
  snapshot_id bigint;
  snapshot_quantity bigint;
  snapshot_level integer;
  snapshot_count integer;
  snapshot_distinct_types integer;
  live_positive_count integer;
  loss_key text;
  loss_text text;
  loss_quantity bigint;
  resource_name text;
  amount bigint;
  loot jsonb := '{"metal":0,"energy":0,"water":0,"crystal":0}'::jsonb;
  battle_result text;
  expected_winner bigint;
  battle_at timestamptz;
  return_at timestamptz;
  report jsonb;
  report_id bigint;
  report_result_udt text;
BEGIN
  IF p_player_id IS NULL OR p_mission_id IS NULL OR p_mission_id <= 0 THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_MISSION','message','Geçersiz sefer.');
  END IF;

  SELECT * INTO probe
  FROM public.military_missions
  WHERE id = p_mission_id;

  IF probe.id IS NULL THEN
    RETURN jsonb_build_object('success',false,'code','MISSION_NOT_FOUND','message','Sefer bulunamadı.');
  END IF;

  IF p_player_id IS DISTINCT FROM probe.attacker_player_id
     AND p_player_id IS DISTINCT FROM probe.defender_player_id THEN
    RETURN jsonb_build_object('success',false,'code','FORBIDDEN','message','Bu sefere erişemezsin.');
  END IF;

  PERFORM id
  FROM public.cities
  WHERE id IN (probe.attacker_city_id, probe.defender_city_id)
  ORDER BY id
  FOR UPDATE;

  SELECT * INTO mission
  FROM public.military_missions
  WHERE id = p_mission_id
  FOR UPDATE;

  IF mission.id IS NULL THEN
    RETURN jsonb_build_object('success',false,'code','MISSION_NOT_FOUND','message','Sefer bulunamadı.');
  END IF;

  IF p_player_id IS DISTINCT FROM mission.attacker_player_id
     AND p_player_id IS DISTINCT FROM mission.defender_player_id THEN
    RETURN jsonb_build_object('success',false,'code','FORBIDDEN','message','Bu sefere erişemezsin.');
  END IF;

  IF mission.status IN ('returning','completed') THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyResolved', true,
      'mission', to_jsonb(mission),
      'loot', COALESCE(mission.settled_loot, mission.result->'loot', loot)
    );
  END IF;

  IF mission.status IS DISTINCT FROM 'resolving' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_STATE',
      'message', 'Sefer çözüm aşamasında değil.'
    );
  END IF;

  SELECT * INTO attacker FROM public.cities WHERE id = mission.attacker_city_id;
  SELECT * INTO defender FROM public.cities WHERE id = mission.defender_city_id;
  IF attacker.id IS NULL OR defender.id IS NULL THEN
    RETURN jsonb_build_object('success',false,'code','CITY_NOT_FOUND','message','Savaş kolonilerinden biri bulunamadı.');
  END IF;

  IF p_attack_power IS NULL OR p_attack_power < 0
     OR p_defense_power IS NULL OR p_defense_power < 0
     OR p_battle_points IS NULL OR p_battle_points < 0
     OR p_return_seconds IS NULL OR p_return_seconds < 1 OR p_return_seconds > 86400
     OR p_loot_rate IS NULL OR p_loot_rate NOT IN (0::numeric,0.10::numeric) THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_RESULT','message','Geçersiz savaş sonucu.');
  END IF;

  IF p_report_base IS NULL OR jsonb_typeof(p_report_base) IS DISTINCT FROM 'object'
     OR jsonb_typeof(COALESCE(p_report_base->'attackerLosses','{}'::jsonb)) IS DISTINCT FROM 'object'
     OR jsonb_typeof(COALESCE(p_report_base->'survivorArmy','[]'::jsonb)) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_REPORT','message','Geçersiz savaş raporu.');
  END IF;

  battle_result := p_report_base->>'result';
  IF battle_result IS NULL OR battle_result NOT IN ('Zafer','Yenilgi','Beraberlik') THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_RESULT','message','Geçersiz savaş sonucu.');
  END IF;

  expected_winner := CASE
    WHEN battle_result = 'Zafer' THEN mission.attacker_player_id
    WHEN battle_result = 'Yenilgi' THEN mission.defender_player_id
    ELSE NULL
  END;

  IF p_winner_player_id IS DISTINCT FROM expected_winner THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_WINNER','message','Savaş kazananı doğrulanamadı.');
  END IF;

  IF (battle_result = 'Zafer' AND p_loot_rate <> 0.10::numeric)
     OR (battle_result <> 'Zafer' AND p_loot_rate <> 0::numeric) THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_LOOT','message','Yağma oranı savaş sonucuyla uyuşmuyor.');
  END IF;

  IF p_defender_snapshot IS NULL OR jsonb_typeof(p_defender_snapshot) IS DISTINCT FROM 'array'
     OR p_defender_losses IS NULL OR jsonb_typeof(p_defender_losses) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_DEFENSE','message','Geçersiz savunma verisi.');
  END IF;

  PERFORM id
  FROM public.units
  WHERE city_id = mission.defender_city_id
  ORDER BY id
  FOR UPDATE;

  SELECT COUNT(*) INTO live_positive_count
  FROM public.units
  WHERE city_id = mission.defender_city_id
    AND COALESCE(quantity,0) > 0;

  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
  INTO snapshot_count, snapshot_distinct_types
  FROM jsonb_array_elements(p_defender_snapshot) AS s(value);

  IF snapshot_count <> live_positive_count
     OR snapshot_distinct_types <> snapshot_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'DEFENDER_CHANGED',
      'message', 'Savunma ordusu değişti; savaş yeniden hesaplanmalı.'
    );
  END IF;

  FOR snapshot_item IN
    SELECT value FROM jsonb_array_elements(p_defender_snapshot) AS s(value)
  LOOP
    IF jsonb_typeof(snapshot_item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_DEFENSE','message','Geçersiz savunma verisi.');
    END IF;

    snapshot_id_text := snapshot_item->>'id';
    snapshot_type := snapshot_item->>'unit_type';
    snapshot_quantity_text := snapshot_item->>'quantity';
    snapshot_level_text := snapshot_item->>'level';

    IF snapshot_id_text IS NULL OR snapshot_id_text !~ '^[1-9][0-9]*$'
       OR char_length(snapshot_id_text) > 19
       OR snapshot_type IS NULL
       OR snapshot_type NOT IN ('piyade','savunma','saldiri','okcu','tank','hava')
       OR snapshot_quantity_text IS NULL OR snapshot_quantity_text !~ '^[1-9][0-9]*$'
       OR char_length(snapshot_quantity_text) > 10
       OR snapshot_level_text IS NULL OR snapshot_level_text !~ '^[1-9][0-9]*$'
       OR char_length(snapshot_level_text) > 2 THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_DEFENSE','message','Geçersiz savunma verisi.');
    END IF;

    snapshot_id := snapshot_id_text::bigint;
    snapshot_quantity := snapshot_quantity_text::bigint;
    snapshot_level := snapshot_level_text::integer;

    IF snapshot_quantity > 2147483647 OR snapshot_level < 1 OR snapshot_level > 15 THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_DEFENSE','message','Geçersiz savunma verisi.');
    END IF;

    SELECT * INTO unit_row
    FROM public.units
    WHERE id = snapshot_id
      AND city_id = mission.defender_city_id
      AND unit_type = snapshot_type
    LIMIT 1;

    IF unit_row.id IS NULL
       OR COALESCE(unit_row.quantity,0) <> snapshot_quantity
       OR GREATEST(1,COALESCE(unit_row.level,1)) <> snapshot_level THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'DEFENDER_CHANGED',
        'message', 'Savunma ordusu değişti; savaş yeniden hesaplanmalı.'
      );
    END IF;
  END LOOP;

  FOR loss_key, loss_text IN
    SELECT key, value FROM jsonb_each_text(p_defender_losses)
  LOOP
    IF loss_key NOT IN ('piyade','savunma','saldiri','okcu','tank','hava')
       OR loss_text IS NULL OR loss_text !~ '^[0-9]+$'
       OR char_length(loss_text) > 10 THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_LOSSES','message','Geçersiz savunma kaybı.');
    END IF;

    loss_quantity := loss_text::bigint;
    IF loss_quantity > 2147483647 THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_LOSSES','message','Geçersiz savunma kaybı.');
    END IF;

    IF loss_quantity > 0 AND NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_defender_snapshot) s(value)
      WHERE value->>'unit_type' = loss_key
        AND (value->>'quantity')::bigint >= loss_quantity
    ) THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_LOSSES','message','Savunma kaybı mevcut birlikten fazla.');
    END IF;
  END LOOP;

  FOR snapshot_item IN
    SELECT value FROM jsonb_array_elements(p_defender_snapshot) AS s(value)
  LOOP
    snapshot_id := (snapshot_item->>'id')::bigint;
    snapshot_type := snapshot_item->>'unit_type';
    snapshot_quantity := (snapshot_item->>'quantity')::bigint;
    loss_quantity := COALESCE((p_defender_losses->>snapshot_type)::bigint,0);

    IF loss_quantity < 0 OR loss_quantity > snapshot_quantity THEN
      RETURN jsonb_build_object('success',false,'code','INVALID_LOSSES','message','Savunma kaybı mevcut birlikten fazla.');
    END IF;

    IF loss_quantity > 0 THEN
      UPDATE public.units
      SET quantity = quantity - loss_quantity
      WHERE id = snapshot_id;
    END IF;
  END LOOP;

  IF mission.settled_loot IS NOT NULL THEN
    loot := mission.settled_loot;
  ELSIF p_loot_rate > 0 THEN
    FOREACH resource_name IN ARRAY ARRAY['metal','energy','water','crystal'] LOOP
      amount := LEAST(
        FLOOR(
          GREATEST(0,COALESCE((to_jsonb(defender)->>resource_name)::bigint,0))
          * p_loot_rate
        )::bigint,
        GREATEST(
          0,
          public.nexora_trade_storage_capacity(attacker.id,resource_name)
          - COALESCE((to_jsonb(attacker)->>resource_name)::bigint,0)
        )
      );

      EXECUTE format(
        'UPDATE public.cities SET %1$I=COALESCE(%1$I,0)-$1 WHERE id=$2',
        resource_name
      ) USING amount, defender.id;

      EXECUTE format(
        'UPDATE public.cities SET %1$I=COALESCE(%1$I,0)+$1 WHERE id=$2',
        resource_name
      ) USING amount, attacker.id;

      loot := jsonb_set(loot,ARRAY[resource_name],to_jsonb(amount));
    END LOOP;
  END IF;

  battle_at := clock_timestamp();
  return_at := battle_at + make_interval(secs => p_return_seconds);

  report := p_report_base || jsonb_build_object(
    'result', battle_result,
    'attackPower', p_attack_power,
    'defensePower', p_defense_power,
    'defenderLosses', p_defender_losses,
    'loot', loot,
    'returnAt', return_at,
    'battleAt', battle_at,
    'battlePoints', p_battle_points,
    'winnerPlayerId', p_winner_player_id
  );

  SELECT c.udt_name
  INTO report_result_udt
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'battle_reports'
    AND c.column_name = 'result';

  IF report_result_udt IN ('json','jsonb') THEN
    INSERT INTO public.battle_reports(
      attacker_player_id, defender_player_id, result, attack_power, defense_power,
      attacker_losses, defender_losses, loot, battle_points, winner_player_id
    ) VALUES (
      mission.attacker_player_id, mission.defender_player_id, report,
      p_attack_power, p_defense_power,
      COALESCE(p_report_base->'attackerLosses','{}'::jsonb),
      p_defender_losses, loot, p_battle_points, p_winner_player_id
    )
    RETURNING id INTO report_id;
  ELSE
    INSERT INTO public.battle_reports(
      attacker_player_id, defender_player_id, result, attack_power, defense_power,
      attacker_losses, defender_losses, loot, battle_points, winner_player_id
    ) VALUES (
      mission.attacker_player_id, mission.defender_player_id, report::text,
      p_attack_power, p_defense_power,
      COALESCE(p_report_base->'attackerLosses','{}'::jsonb),
      p_defender_losses, loot, p_battle_points, p_winner_player_id
    )
    RETURNING id INTO report_id;
  END IF;

  UPDATE public.military_missions
  SET status = 'returning',
      arrive_at = return_at,
      attack_power = p_attack_power,
      result = report,
      settled_loot = loot
  WHERE id = mission.id
  RETURNING * INTO mission;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyResolved', false,
    'mission', to_jsonb(mission),
    'battleReportId', report_id,
    'loot', loot
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_complete_military_return(
  p_player_id bigint,
  p_mission_id bigint
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  probe public.military_missions%ROWTYPE;
  mission public.military_missions%ROWTYPE;
  survivor jsonb;
  survivor_type text;
  quantity_text text;
  level_text text;
  survivor_quantity bigint;
  survivor_level integer;
  existing public.units%ROWTYPE;
  stats public.unit_levels%ROWTYPE;
  population_cost integer;
  remaining_seconds integer;
BEGIN
  IF p_player_id IS NULL OR p_mission_id IS NULL OR p_mission_id <= 0 THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_MISSION','message','Geçersiz sefer.');
  END IF;

  SELECT * INTO probe
  FROM public.military_missions
  WHERE id = p_mission_id;

  IF probe.id IS NULL THEN
    RETURN jsonb_build_object('success',false,'code','MISSION_NOT_FOUND','message','Sefer bulunamadı.');
  END IF;

  IF p_player_id IS DISTINCT FROM probe.attacker_player_id
     AND p_player_id IS DISTINCT FROM probe.defender_player_id THEN
    RETURN jsonb_build_object('success',false,'code','FORBIDDEN','message','Bu sefere erişemezsin.');
  END IF;

  PERFORM id
  FROM public.cities
  WHERE id = probe.attacker_city_id
  FOR UPDATE;

  SELECT * INTO mission
  FROM public.military_missions
  WHERE id = p_mission_id
  FOR UPDATE;

  IF mission.id IS NULL THEN
    RETURN jsonb_build_object('success',false,'code','MISSION_NOT_FOUND','message','Sefer bulunamadı.');
  END IF;

  IF p_player_id IS DISTINCT FROM mission.attacker_player_id
     AND p_player_id IS DISTINCT FROM mission.defender_player_id THEN
    RETURN jsonb_build_object('success',false,'code','FORBIDDEN','message','Bu sefere erişemezsin.');
  END IF;

  IF mission.status = 'completed' THEN
    RETURN jsonb_build_object('success',true,'alreadyCompleted',true,'mission',to_jsonb(mission));
  END IF;

  IF mission.status IS DISTINCT FROM 'returning' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_STATE',
      'message', 'Sefer dönüş aşamasında değil.'
    );
  END IF;

  IF mission.arrive_at > clock_timestamp() THEN
    remaining_seconds := GREATEST(
      0,
      CEIL(EXTRACT(EPOCH FROM (mission.arrive_at - clock_timestamp())))::integer
    );
    RETURN jsonb_build_object(
      'success', true,
      'notReady', true,
      'remainingSeconds', remaining_seconds,
      'mission', to_jsonb(mission)
    );
  END IF;

  IF mission.result IS NULL
     OR jsonb_typeof(mission.result) IS DISTINCT FROM 'object'
     OR jsonb_typeof(COALESCE(mission.result->'survivorArmy','[]'::jsonb)) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_RESULT',
      'message', 'Sefer dönüş verisi geçersiz.'
    );
  END IF;

  PERFORM id
  FROM public.units
  WHERE city_id = mission.attacker_city_id
  ORDER BY id
  FOR UPDATE;

  FOR survivor IN
    SELECT value FROM jsonb_array_elements(COALESCE(mission.result->'survivorArmy','[]'::jsonb)) s(value)
  LOOP
    IF jsonb_typeof(survivor) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'Geçersiz dönüş ordusu.';
    END IF;

    survivor_type := survivor->>'unit_type';
    quantity_text := survivor->>'quantity';
    level_text := survivor->>'level';

    IF survivor_type IS NULL
       OR survivor_type NOT IN ('piyade','savunma','saldiri','okcu','tank','hava')
       OR quantity_text IS NULL OR quantity_text !~ '^[0-9]+$'
       OR char_length(quantity_text) > 10
       OR level_text IS NULL OR level_text !~ '^[1-9][0-9]*$'
       OR char_length(level_text) > 2 THEN
      RAISE EXCEPTION 'Geçersiz dönüş ordusu.';
    END IF;

    survivor_quantity := quantity_text::bigint;
    survivor_level := level_text::integer;

    IF survivor_quantity > 2147483647 OR survivor_level < 1 OR survivor_level > 15 THEN
      RAISE EXCEPTION 'Geçersiz dönüş ordusu.';
    END IF;

    IF survivor_quantity = 0 THEN
      CONTINUE;
    END IF;

    SELECT * INTO stats
    FROM public.unit_levels
    WHERE unit_type = survivor_type
      AND level = survivor_level
    LIMIT 1;

    IF stats.id IS NULL THEN
      RAISE EXCEPTION 'Birlik seviye verisi bulunamadı.';
    END IF;

    SELECT * INTO existing
    FROM public.units
    WHERE city_id = mission.attacker_city_id
      AND unit_type = survivor_type
    ORDER BY id
    LIMIT 1
    FOR UPDATE;

    population_cost := CASE survivor_type
      WHEN 'tank' THEN 3
      WHEN 'hava' THEN 2
      ELSE 1
    END;

    IF existing.id IS NOT NULL THEN
      UPDATE public.units
      SET quantity = COALESCE(quantity,0) + survivor_quantity
      WHERE id = existing.id;
    ELSE
      INSERT INTO public.units(
        city_id,unit_type,quantity,level,attack,defense,hp,speed,population_cost
      ) VALUES (
        mission.attacker_city_id,
        survivor_type,
        survivor_quantity,
        survivor_level,
        stats.attack,
        stats.defense,
        stats.hp,
        stats.speed,
        population_cost
      );
    END IF;
  END LOOP;

  UPDATE public.military_missions
  SET status = 'completed',
      completed_at = clock_timestamp()
  WHERE id = mission.id
  RETURNING * INTO mission;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyCompleted', false,
    'mission', to_jsonb(mission)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_resolve_military_mission(
  bigint,bigint,jsonb,jsonb,jsonb,integer,integer,numeric,integer,bigint,integer
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_resolve_military_mission(
  bigint,bigint,jsonb,jsonb,jsonb,integer,integer,numeric,integer,bigint,integer
) TO service_role;

REVOKE ALL ON FUNCTION public.nexora_complete_military_return(
  bigint,bigint
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_complete_military_return(
  bigint,bigint
) TO service_role;

COMMIT;

