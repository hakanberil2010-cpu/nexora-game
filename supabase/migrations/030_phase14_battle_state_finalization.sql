-- NEXORA Phase 14.8
-- Finalize due battle-relevant jobs and return one consistent battle snapshot.
-- Apply AFTER 029 and BEFORE deploying the matching api/auth.js.
--
-- Goal:
-- Battle power must not depend on whether either player happened to visit
-- colony/research/army screens before the battle was resolved.
--
-- This function:
-- - locks both battle cities in deterministic id order
-- - locks the mission
-- - finalizes due defender buildings
-- - finalizes due attacker + defender research
-- - finalizes due defender unit training
-- - returns defender units/buildings/research + attacker research from the
--   same database transaction
--
-- Existing combat math and atomic settlement remain unchanged.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_prepare_military_battle_snapshot(
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
  attacker public.cities%ROWTYPE;
  defender public.cities%ROWTYPE;
  q public.unit_production_queue%ROWTYPE;
  u public.units%ROWTYPE;
  s public.unit_levels%ROWTYPE;
  v_now timestamptz;
  v_defender_units jsonb := '[]'::jsonb;
  v_defender_buildings jsonb := '[]'::jsonb;
  v_defender_research jsonb := '{}'::jsonb;
  v_attacker_research jsonb := '{}'::jsonb;
BEGIN
  IF p_player_id IS NULL OR p_mission_id IS NULL OR p_mission_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_MISSION',
      'message', 'Geçersiz sefer.'
    );
  END IF;

  SELECT *
  INTO probe
  FROM public.military_missions
  WHERE id = p_mission_id;

  IF probe.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'Sefer bulunamadı.'
    );
  END IF;

  IF p_player_id IS DISTINCT FROM probe.attacker_player_id
     AND p_player_id IS DISTINCT FROM probe.defender_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu sefere erişemezsin.'
    );
  END IF;

  -- Same deterministic two-city order used by battle settlement.
  PERFORM id
  FROM public.cities
  WHERE id IN (probe.attacker_city_id, probe.defender_city_id)
  ORDER BY id
  FOR UPDATE;

  SELECT *
  INTO mission
  FROM public.military_missions
  WHERE id = p_mission_id
  FOR UPDATE;

  IF mission.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'Sefer bulunamadı.'
    );
  END IF;

  IF p_player_id IS DISTINCT FROM mission.attacker_player_id
     AND p_player_id IS DISTINCT FROM mission.defender_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu sefere erişemezsin.'
    );
  END IF;

  IF mission.status IN ('returning', 'completed') THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyResolved', true,
      'mission', to_jsonb(mission)
    );
  END IF;

  IF mission.status IS DISTINCT FROM 'resolving' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_STATE',
      'message', 'Sefer çözüm aşamasında değil.'
    );
  END IF;

  -- Capture the authoritative snapshot time only after the city + mission
  -- locks are held. If this transaction had to wait for another writer,
  -- jobs that became due during that wait must be visible to this battle.
  v_now := clock_timestamp();

  IF mission.arrive_at > v_now THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'BATTLE_NOT_READY',
      'message', 'Sefer henüz hedefe ulaşmadı.'
    );
  END IF;

  SELECT * INTO attacker
  FROM public.cities
  WHERE id = mission.attacker_city_id;

  SELECT * INTO defender
  FROM public.cities
  WHERE id = mission.defender_city_id;

  IF attacker.id IS NULL OR defender.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Savaş kolonilerinden biri bulunamadı.'
    );
  END IF;

  -- Finalize every defender building whose timer is already due.
  -- UPDATE itself takes the building row locks while both city rows remain held.
  UPDATE public.buildings
  SET level = GREATEST(0, COALESCE(level, 0)) + 1,
      is_under_construction = false,
      upgrade_ready_at = NULL
  WHERE city_id = defender.id
    AND COALESCE(is_under_construction, false) = true
    AND upgrade_ready_at IS NOT NULL
    AND upgrade_ready_at <= v_now;

  -- Research admission locks city -> research. We already own both city locks,
  -- so lock both research rows in deterministic player/id order.
  PERFORM id
  FROM public.research
  WHERE player_id IN (mission.attacker_player_id, mission.defender_player_id)
  ORDER BY player_id, id
  FOR UPDATE;

  UPDATE public.research
  SET production_level = COALESCE(production_level, 0)
        + CASE WHEN pending_column = 'production_level' THEN 1 ELSE 0 END,
      combat_level = COALESCE(combat_level, 0)
        + CASE WHEN pending_column = 'combat_level' THEN 1 ELSE 0 END,
      defense_level = COALESCE(defense_level, 0)
        + CASE WHEN pending_column = 'defense_level' THEN 1 ELSE 0 END,
      crystal_level = COALESCE(crystal_level, 0)
        + CASE WHEN pending_column = 'crystal_level' THEN 1 ELSE 0 END,
      general_power_level = COALESCE(general_power_level, 0)
        + CASE WHEN pending_column = 'general_power_level' THEN 1 ELSE 0 END,
      unit_attack_level = COALESCE(unit_attack_level, 0)
        + CASE WHEN pending_column = 'unit_attack_level' THEN 1 ELSE 0 END,
      unit_defense_level = COALESCE(unit_defense_level, 0)
        + CASE WHEN pending_column = 'unit_defense_level' THEN 1 ELSE 0 END,
      unit_hp_level = COALESCE(unit_hp_level, 0)
        + CASE WHEN pending_column = 'unit_hp_level' THEN 1 ELSE 0 END,
      travel_speed_level = COALESCE(travel_speed_level, 0)
        + CASE WHEN pending_column = 'travel_speed_level' THEN 1 ELSE 0 END,
      upgrade_ready_at = NULL,
      pending_column = NULL
  WHERE player_id IN (mission.attacker_player_id, mission.defender_player_id)
    AND upgrade_ready_at IS NOT NULL
    AND upgrade_ready_at <= v_now
    AND pending_column IN (
      'production_level',
      'combat_level',
      'defense_level',
      'crystal_level',
      'general_power_level',
      'unit_attack_level',
      'unit_defense_level',
      'unit_hp_level',
      'travel_speed_level'
    );

  -- Complete defender training that is due before this battle snapshot.
  -- This mirrors nexora_complete_unit_training, but stays inside the same
  -- transaction as the battle snapshot.
  FOR q IN
    SELECT *
    FROM public.unit_production_queue
    WHERE player_id = mission.defender_player_id
      AND city_id = defender.id
      AND status = 'training'
      AND finish_at <= v_now
    ORDER BY id
    FOR UPDATE
  LOOP
    SELECT *
    INTO u
    FROM public.units
    WHERE city_id = defender.id
      AND unit_type = q.unit_type
    ORDER BY id
    LIMIT 1
    FOR UPDATE;

    IF u.id IS NOT NULL THEN
      UPDATE public.units
      SET quantity = COALESCE(quantity, 0) + q.quantity
      WHERE id = u.id;
    ELSE
      SELECT *
      INTO s
      FROM public.unit_levels
      WHERE unit_type = q.unit_type
        AND level = 1
      LIMIT 1;

      INSERT INTO public.units(
        city_id,
        unit_type,
        quantity,
        level,
        attack,
        defense,
        hp,
        speed,
        population_cost
      )
      VALUES(
        defender.id,
        q.unit_type,
        q.quantity,
        1,
        COALESCE(s.attack, 0),
        COALESCE(s.defense, 0),
        COALESCE(s.hp, 0),
        COALESCE(s.speed, 100),
        CASE q.unit_type
          WHEN 'tank' THEN 3
          WHEN 'hava' THEN 2
          ELSE 1
        END
      );
    END IF;

    UPDATE public.unit_production_queue
    SET status = 'completed'
    WHERE id = q.id;
  END LOOP;

  -- Lock the finalized defender army while collecting the snapshot.
  PERFORM id
  FROM public.units
  WHERE city_id = defender.id
  ORDER BY id
  FOR UPDATE;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.id), '[]'::jsonb)
  INTO v_defender_units
  FROM public.units x
  WHERE x.city_id = defender.id;

  SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.id), '[]'::jsonb)
  INTO v_defender_buildings
  FROM public.buildings b
  WHERE b.city_id = defender.id;

  SELECT COALESCE((
    SELECT to_jsonb(r)
    FROM public.research r
    WHERE r.player_id = mission.defender_player_id
    ORDER BY r.id
    LIMIT 1
  ), '{}'::jsonb)
  INTO v_defender_research;

  SELECT COALESCE((
    SELECT to_jsonb(r)
    FROM public.research r
    WHERE r.player_id = mission.attacker_player_id
    ORDER BY r.id
    LIMIT 1
  ), '{}'::jsonb)
  INTO v_attacker_research;

  RETURN jsonb_build_object(
    'success', true,
    'mission', to_jsonb(mission),
    'snapshotAt', v_now,
    'defenderUnits', v_defender_units,
    'defenderBuildings', v_defender_buildings,
    'defenderResearch', v_defender_research,
    'attackerResearch', v_attacker_research
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_prepare_military_battle_snapshot(bigint,bigint)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_prepare_military_battle_snapshot(bigint,bigint)
TO service_role;

COMMIT;
