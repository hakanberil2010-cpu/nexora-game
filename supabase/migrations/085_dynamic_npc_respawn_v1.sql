-- TERYNDIS 085 Dynamic NPC Respawn V1
-- A defeated NPC disappears globally, waits its configured cooldown, then
-- respawns at a different free world coordinate.
-- Only one active mission can target a given NPC at a time.

BEGIN;

ALTER TABLE public.npc_camps
  ADD COLUMN IF NOT EXISTS respawn_at timestamptz;

COMMENT ON COLUMN public.npc_camps.respawn_at IS
  'Global NPC respawn time after a victory. NULL while spawned.';

CREATE OR REPLACE FUNCTION public.nexora_npc_camps_snapshot(p_player_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'success', true,
    'camps', COALESCE(jsonb_agg(jsonb_build_object(
      'id', c.id,
      'worldSiteId', s.id,
      'name', s.name,
      'description', s.description,
      'tier', c.tier,
      'level', c.tier,
      'difficulty', c.difficulty,
      'encounterClass', c.encounter_class,
      'icon', c.icon,
      'recommendedHq', c.recommended_hq,
      'isBoss', c.encounter_class = 'boss',
      'coordinateX', s.coordinate_x,
      'coordinateY', s.coordinate_y,
      'armyTemplate', c.army_template,
      'reward', c.reward,
      'cooldownSeconds', c.cooldown_seconds,
      'victories', COALESCE(st.victories,0),
      'defeats', COALESCE(st.defeats,0),
      'draws', COALESCE(st.draws,0),
      'lastBattleAt', st.last_battle_at,
      'availableAt', st.available_at,
      'remainingSeconds', GREATEST(0,CEIL(EXTRACT(EPOCH FROM (COALESCE(st.available_at,'epoch'::timestamptz)-now())))::integer),
      'activeMissionId', (SELECT m.id FROM public.npc_missions m WHERE m.npc_camp_id=c.id AND m.status IN ('traveling','resolving','returning') ORDER BY m.id DESC LIMIT 1),
      'canAttack', COALESCE(st.available_at,'epoch'::timestamptz)<=now() AND NOT EXISTS (SELECT 1 FROM public.npc_missions m WHERE m.npc_camp_id=c.id AND m.status IN ('traveling','resolving','returning'))
    ) ORDER BY c.tier,c.id),'[]'::jsonb)
  )
  FROM public.npc_camps c
  JOIN public.world_sites s ON s.id=c.world_site_id
  LEFT JOIN public.player_npc_camp_state st ON st.player_id=p_player_id AND st.npc_camp_id=c.id
  WHERE c.active=true AND s.active=true AND s.site_type='npc_camp';
$function$;

CREATE OR REPLACE FUNCTION public.nexora_start_npc_mission(p_player_id bigint, p_city_id bigint, p_camp_id bigint, p_army jsonb, p_attack_power integer, p_depart_x integer, p_depart_y integer, p_travel_seconds integer, p_fleet_speed numeric, p_battle_tactic text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_city public.cities%ROWTYPE;
  v_camp public.npc_camps%ROWTYPE;
  v_site public.world_sites%ROWTYPE;
  v_state public.player_npc_camp_state%ROWTYPE;
  v_mission public.npc_missions%ROWTYPE;
  v_unit public.units%ROWTYPE;

  item jsonb;
  requested_type text;
  quantity_text text;
  level_text text;
  requested_quantity bigint;
  requested_level integer;

  item_count integer;
  distinct_type_count integer;

  camp_item_count integer;
  camp_distinct_type_count integer;

  unit_id bigint;
  affected integer;

  v_tactic text;
  v_now timestamptz;
  v_remaining integer;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR p_city_id IS NULL OR p_city_id <= 0
     OR p_camp_id IS NULL OR p_camp_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_TARGET',
      'message', 'Geçersiz PvE hedefi.'
    );
  END IF;

  IF p_attack_power IS NULL OR p_attack_power <= 0
     OR p_travel_seconds IS NULL
     OR p_travel_seconds < 1
     OR p_travel_seconds > 86400
     OR p_fleet_speed IS NULL
     OR p_fleet_speed <= 0
     OR p_depart_x IS NULL
     OR p_depart_y IS NULL
     OR p_depart_x NOT BETWEEN 1 AND 100
     OR p_depart_y NOT BETWEEN 1 AND 100 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_MISSION',
      'message', 'Geçersiz PvE sefer bilgisi.'
    );
  END IF;

  v_tactic := lower(trim(COALESCE(p_battle_tactic, '')));

  IF v_tactic NOT IN ('assault','balanced','cautious') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_TACTIC',
      'message', 'Geçersiz savaş taktiği.'
    );
  END IF;

  -- City lock serializes NPC starts with resource / population / colony writes.
  SELECT *
    INTO v_city
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF v_city.id IS NULL OR v_city.id <> p_city_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  v_now := clock_timestamp();

  IF COALESCE(v_city.coordinate_x, 0) <> p_depart_x
     OR COALESCE(v_city.coordinate_y, 0) <> p_depart_y THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_CHANGED',
      'message', 'Koloni koordinatı değişti; haritayı yenileyip tekrar deneyin.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.npc_missions
     WHERE player_id = p_player_id
       AND status IN ('traveling','resolving','returning')
     LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVE_NPC_MISSION',
      'message', 'Zaten aktif bir PvE seferin bulunuyor.'
    );
  END IF;

  SELECT *
    INTO v_camp
    FROM public.npc_camps
   WHERE id = p_camp_id
     AND active = true
   LIMIT 1
   FOR UPDATE;

  IF v_camp.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CAMP_NOT_FOUND',
      'message', 'NPC kampı bulunamadı veya aktif değil.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.npc_missions m
     WHERE m.npc_camp_id = v_camp.id
       AND m.status IN ('traveling','resolving','returning')
     LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CAMP_BUSY',
      'message', 'Bu canavara başka bir ordu zaten seferde.'
    );
  END IF;

  SELECT *
    INTO v_site
    FROM public.world_sites
   WHERE id = v_camp.world_site_id
     AND active = true
     AND site_type = 'npc_camp'
   LIMIT 1;

  IF v_site.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CAMP_DISABLED',
      'message', 'NPC kampı şu anda kullanılamıyor.'
    );
  END IF;

  SELECT *
    INTO v_state
    FROM public.player_npc_camp_state
   WHERE player_id = p_player_id
     AND npc_camp_id = v_camp.id
   FOR UPDATE;

  IF v_state.available_at IS NOT NULL
     AND v_state.available_at > v_now THEN
    v_remaining := GREATEST(
      1,
      CEIL(
        EXTRACT(EPOCH FROM (v_state.available_at - v_now))
      )::integer
    );

    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CAMP_COOLDOWN',
      'message', 'Bu NPC kampı henüz yeniden saldırıya açık değil.',
      'availableAt', v_state.available_at,
      'remainingSeconds', v_remaining
    );
  END IF;

  IF p_army IS NULL
     OR jsonb_typeof(p_army) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ARMY',
      'message', 'Geçersiz ordu bilgisi.'
    );
  END IF;

  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
    INTO item_count, distinct_type_count
    FROM jsonb_array_elements(p_army) AS army_item(value);

  IF item_count < 1
     OR item_count > 6
     OR distinct_type_count <> item_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ARMY',
      'message', 'Geçersiz veya tekrarlanan birlik seçimi.'
    );
  END IF;

  IF v_camp.army_template IS NULL
     OR jsonb_typeof(v_camp.army_template) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CONFIG_INVALID',
      'message', 'NPC kamp ordusu yapılandırması geçersiz.'
    );
  END IF;

  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
    INTO camp_item_count, camp_distinct_type_count
    FROM jsonb_array_elements(v_camp.army_template) AS camp_item(value);

  IF camp_item_count < 1
     OR camp_item_count > 6
     OR camp_distinct_type_count <> camp_item_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CONFIG_INVALID',
      'message', 'NPC kamp ordusu yapılandırması geçersiz.'
    );
  END IF;

  -- Validate configured NPC army and make sure every configured level exists.
  FOR item IN
    SELECT value
      FROM jsonb_array_elements(v_camp.army_template) AS camp_item(value)
  LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'NPC_CONFIG_INVALID',
        'message', 'NPC kamp ordusu yapılandırması geçersiz.'
      );
    END IF;

    requested_type := item->>'unit_type';
    quantity_text := item->>'quantity';
    level_text := item->>'level';

    IF requested_type IS NULL
       OR requested_type NOT IN (
         'piyade','savunma','saldiri','okcu','tank','hava'
       )
       OR quantity_text IS NULL
       OR quantity_text !~ '^[1-9][0-9]*$'
       OR char_length(quantity_text) > 10
       OR level_text IS NULL
       OR level_text !~ '^[1-9][0-9]*$'
       OR char_length(level_text) > 2 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'NPC_CONFIG_INVALID',
        'message', 'NPC kamp ordusu yapılandırması geçersiz.'
      );
    END IF;

    requested_quantity := quantity_text::bigint;
    requested_level := level_text::integer;

    IF requested_quantity > 2147483647
       OR requested_level < 1
       OR requested_level > 15
       OR NOT EXISTS (
         SELECT 1
           FROM public.unit_levels ul
          WHERE ul.unit_type = requested_type
            AND ul.level = requested_level
       ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'NPC_CONFIG_INVALID',
        'message', 'NPC kamp ordusu yapılandırması geçersiz.'
      );
    END IF;
  END LOOP;

  IF v_camp.reward IS NULL
     OR jsonb_typeof(v_camp.reward) IS DISTINCT FROM 'object'
     OR EXISTS (
       SELECT 1
         FROM jsonb_each_text(v_camp.reward) AS r(key, value)
        WHERE key NOT IN ('metal','energy','alloy','crystal')
           OR value !~ '^[0-9]+$'
           OR char_length(value) > 12
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CONFIG_INVALID',
      'message', 'NPC kamp ödülü yapılandırması geçersiz.'
    );
  END IF;

  -- Validate and lock every live player-unit row before any deduction.
  FOR item IN
    SELECT value
      FROM jsonb_array_elements(p_army) AS army_item(value)
  LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz ordu bilgisi.'
      );
    END IF;

    requested_type := item->>'unit_type';
    quantity_text := item->>'quantity';
    level_text := item->>'level';

    IF requested_type IS NULL
       OR requested_type NOT IN (
         'piyade','savunma','saldiri','okcu','tank','hava'
       )
       OR quantity_text IS NULL
       OR quantity_text !~ '^[1-9][0-9]*$'
       OR char_length(quantity_text) > 10
       OR level_text IS NULL
       OR level_text !~ '^[1-9][0-9]*$'
       OR char_length(level_text) > 2 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz ordu bilgisi.'
      );
    END IF;

    requested_quantity := quantity_text::bigint;
    requested_level := level_text::integer;

    IF requested_quantity <= 0
       OR requested_quantity > 2147483647
       OR requested_level < 1
       OR requested_level > 15 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz birlik miktarı veya seviyesi.'
      );
    END IF;

    SELECT *
      INTO v_unit
      FROM public.units
     WHERE city_id = v_city.id
       AND unit_type = requested_type
     ORDER BY id
     LIMIT 1
     FOR UPDATE;

    IF v_unit.id IS NULL
       OR COALESCE(v_unit.quantity, 0) < requested_quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INSUFFICIENT_UNITS',
        'message', requested_type || ' için yeterli birlik yok.'
      );
    END IF;

    IF GREATEST(1, COALESCE(v_unit.level, 1)) <> requested_level THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'UNIT_CHANGED',
        'message', 'Birlik seviyesi değişti; orduyu yenileyip tekrar deneyin.'
      );
    END IF;
  END LOOP;

  -- Deduct the selected army exactly once.
  FOR item IN
    SELECT value
      FROM jsonb_array_elements(p_army) AS army_item(value)
  LOOP
    requested_type := item->>'unit_type';
    requested_quantity := (item->>'quantity')::bigint;

    SELECT id
      INTO unit_id
      FROM public.units
     WHERE city_id = v_city.id
       AND unit_type = requested_type
     ORDER BY id
     LIMIT 1;

    UPDATE public.units
       SET quantity = quantity - requested_quantity
     WHERE id = unit_id
       AND quantity >= requested_quantity;

    GET DIAGNOSTICS affected = ROW_COUNT;

    IF affected <> 1 THEN
      RAISE EXCEPTION
        'NPC seferi başlatılırken ordu miktarı beklenmedik biçimde değişti.';
    END IF;
  END LOOP;

  INSERT INTO public.npc_missions(
    player_id,
    city_id,
    npc_camp_id,
    status,
    depart_at,
    arrive_at,
    attack_power,
    defense_power,
    army,
    npc_army,
    reward_snapshot,
    camp_name,
    camp_tier,
    cooldown_seconds,
    depart_x,
    depart_y,
    target_x,
    target_y,
    travel_seconds,
    fleet_speed,
    battle_tactic,
    updated_at
  )
  VALUES(
    p_player_id,
    v_city.id,
    v_camp.id,
    'traveling',
    v_now,
    v_now + make_interval(secs => p_travel_seconds),
    p_attack_power,
    0,
    p_army,
    v_camp.army_template,
    v_camp.reward,
    v_site.name,
    v_camp.tier,
    v_camp.cooldown_seconds,
    p_depart_x,
    p_depart_y,
    v_site.coordinate_x,
    v_site.coordinate_y,
    p_travel_seconds,
    p_fleet_speed,
    v_tactic,
    v_now
  )
  RETURNING * INTO v_mission;

  RETURN jsonb_build_object(
    'success', true,
    'message', '⚔️ Ordu NPC kampına sefere çıktı.',
    'mission', to_jsonb(v_mission),
    'camp',
      jsonb_build_object(
        'id', v_camp.id,
        'worldSiteId', v_site.id,
        'name', v_site.name,
        'tier', v_camp.tier,
        'difficulty', v_camp.difficulty,
        'coordinateX', v_site.coordinate_x,
        'coordinateY', v_site.coordinate_y
      )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_resolve_npc_mission(p_player_id bigint, p_mission_id bigint, p_npc_losses jsonb, p_report_base jsonb, p_attack_power integer, p_defense_power integer, p_return_seconds integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  probe public.npc_missions%ROWTYPE;
  mission public.npc_missions%ROWTYPE;
  v_city public.cities%ROWTYPE;

  v_result text;
  v_expected_result text;

  survivor_item jsonb;
  original_item jsonb;
  survivor_count integer;
  survivor_distinct integer;
  survivor_type text;
  survivor_quantity_text text;
  survivor_level_text text;
  survivor_quantity bigint;
  survivor_level integer;

  original_type text;
  original_quantity bigint;
  original_level integer;

  loss_key text;
  loss_text text;
  loss_quantity bigint;

  npc_item jsonb;
  npc_type text;
  npc_quantity bigint;

  resource_name text;
  reward_text text;
  reward_amount bigint;
  current_amount bigint;
  capacity bigint;
  credit_amount bigint;
  credited_reward jsonb :=
    '{"metal":0,"energy":0,"alloy":0,"crystal":0}'::jsonb;

  v_battle_at timestamptz;
  v_return_at timestamptz;
  v_available_at timestamptz;

  v_report jsonb;
  v_report_id bigint;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR p_mission_id IS NULL OR p_mission_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_MISSION',
      'message', 'Geçersiz PvE seferi.'
    );
  END IF;

  IF p_attack_power IS NULL OR p_attack_power < 0
     OR p_defense_power IS NULL OR p_defense_power < 0
     OR p_return_seconds IS NULL
     OR p_return_seconds < 1
     OR p_return_seconds > 86400 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_RESULT',
      'message', 'Geçersiz PvE savaş sonucu.'
    );
  END IF;

  IF p_report_base IS NULL
     OR jsonb_typeof(p_report_base) IS DISTINCT FROM 'object'
     OR jsonb_typeof(
          COALESCE(p_report_base->'attackerLosses', '{}'::jsonb)
        ) IS DISTINCT FROM 'object'
     OR jsonb_typeof(
          COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
        ) IS DISTINCT FROM 'array'
     OR p_npc_losses IS NULL
     OR jsonb_typeof(p_npc_losses) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_REPORT',
      'message', 'Geçersiz PvE savaş raporu.'
    );
  END IF;

  SELECT *
    INTO probe
    FROM public.npc_missions
   WHERE id = p_mission_id;

  IF probe.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'PvE seferi bulunamadı.'
    );
  END IF;

  IF probe.player_id IS DISTINCT FROM p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu PvE seferine erişemezsin.'
    );
  END IF;

  SELECT *
    INTO v_city
    FROM public.cities
   WHERE id = probe.city_id
     AND player_id = p_player_id
   FOR UPDATE;

  IF v_city.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  SELECT *
    INTO mission
    FROM public.npc_missions
   WHERE id = p_mission_id
   FOR UPDATE;

  IF mission.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_NOT_FOUND',
      'message', 'PvE seferi bulunamadı.'
    );
  END IF;

  IF mission.player_id IS DISTINCT FROM p_player_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'FORBIDDEN',
      'message', 'Bu PvE seferine erişemezsin.'
    );
  END IF;

  IF mission.status IN ('returning','completed') THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyResolved', true,
      'mission', to_jsonb(mission),
      'reward',
        COALESCE(
          mission.settled_reward,
          mission.result->'reward',
          credited_reward
        )
    );
  END IF;

  IF mission.status IS DISTINCT FROM 'resolving' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'MISSION_STATE',
      'message', 'PvE seferi çözüm aşamasında değil.'
    );
  END IF;

  IF mission.arrive_at > clock_timestamp() THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'BATTLE_NOT_READY',
      'message', 'PvE seferi henüz hedefe ulaşmadı.'
    );
  END IF;

  v_result := p_report_base->>'result';

  IF v_result IS NULL
     OR v_result NOT IN ('Zafer','Yenilgi','Beraberlik') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_RESULT',
      'message', 'Geçersiz PvE savaş sonucu.'
    );
  END IF;

  v_expected_result := CASE
    WHEN p_attack_power > p_defense_power THEN 'Zafer'
    WHEN p_attack_power < p_defense_power THEN 'Yenilgi'
    ELSE 'Beraberlik'
  END;

  IF v_result IS DISTINCT FROM v_expected_result THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_RESULT',
      'message', 'PvE savaş sonucu güç değerleriyle uyuşmuyor.'
    );
  END IF;

  -- Validate survivor array shape and duplicate types.
  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
    INTO survivor_count, survivor_distinct
    FROM jsonb_array_elements(
      COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
    ) AS survivor(value);

  IF survivor_distinct <> survivor_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_SURVIVORS',
      'message', 'Dönüş ordusunda tekrarlanan birlik türü var.'
    );
  END IF;

  FOR survivor_item IN
    SELECT value
      FROM jsonb_array_elements(
        COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
      ) AS survivor(value)
  LOOP
    IF jsonb_typeof(survivor_item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_SURVIVORS',
        'message', 'Geçersiz dönüş ordusu.'
      );
    END IF;

    survivor_type := survivor_item->>'unit_type';
    survivor_quantity_text := survivor_item->>'quantity';
    survivor_level_text := survivor_item->>'level';

    IF survivor_type IS NULL
       OR survivor_type NOT IN (
         'piyade','savunma','saldiri','okcu','tank','hava'
       )
       OR survivor_quantity_text IS NULL
       OR survivor_quantity_text !~ '^[0-9]+$'
       OR char_length(survivor_quantity_text) > 10
       OR survivor_level_text IS NULL
       OR survivor_level_text !~ '^[1-9][0-9]*$'
       OR char_length(survivor_level_text) > 2 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_SURVIVORS',
        'message', 'Geçersiz dönüş ordusu.'
      );
    END IF;

    survivor_quantity := survivor_quantity_text::bigint;
    survivor_level := survivor_level_text::integer;

    IF survivor_quantity > 2147483647
       OR survivor_level < 1
       OR survivor_level > 15
       OR NOT EXISTS (
         SELECT 1
           FROM jsonb_array_elements(mission.army) original(value)
          WHERE value->>'unit_type' = survivor_type
            AND (value->>'level')::integer = survivor_level
            AND (value->>'quantity')::bigint >= survivor_quantity
       ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_SURVIVORS',
        'message', 'Dönüş ordusu gönderilen ordudan büyük veya uyumsuz.'
      );
    END IF;
  END LOOP;

  -- Loss object may only contain valid unit types and non-negative integers.
  IF EXISTS (
    SELECT 1
      FROM jsonb_each_text(
        COALESCE(p_report_base->'attackerLosses', '{}'::jsonb)
      ) AS losses(key, value)
     WHERE key NOT IN (
       'piyade','savunma','saldiri','okcu','tank','hava'
     )
        OR value !~ '^[0-9]+$'
        OR char_length(value) > 10
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_LOSSES',
      'message', 'Geçersiz saldıran kaybı.'
    );
  END IF;

  -- Exact accounting: survivor + attacker loss must equal each sent quantity.
  FOR original_item IN
    SELECT value
      FROM jsonb_array_elements(mission.army) original(value)
  LOOP
    original_type := original_item->>'unit_type';
    original_quantity := (original_item->>'quantity')::bigint;
    original_level := (original_item->>'level')::integer;

    SELECT COALESCE(MAX((value->>'quantity')::bigint), 0)
      INTO survivor_quantity
      FROM jsonb_array_elements(
        COALESCE(p_report_base->'survivorArmy', '[]'::jsonb)
      ) survivor(value)
     WHERE value->>'unit_type' = original_type
       AND (value->>'level')::integer = original_level;

    loss_text :=
      COALESCE(
        p_report_base->'attackerLosses'->>original_type,
        '0'
      );

    IF loss_text !~ '^[0-9]+$'
       OR char_length(loss_text) > 10 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_LOSSES',
        'message', 'Geçersiz saldıran kaybı.'
      );
    END IF;

    loss_quantity := loss_text::bigint;

    IF loss_quantity > 2147483647
       OR survivor_quantity + loss_quantity <> original_quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ACCOUNTING',
        'message', 'Saldıran kayıp ve sağ kalan hesabı uyuşmuyor.'
      );
    END IF;
  END LOOP;

  -- No positive attacker-loss entry may reference a unit type that was not sent.
  IF EXISTS (
    SELECT 1
      FROM jsonb_each_text(
        COALESCE(p_report_base->'attackerLosses', '{}'::jsonb)
      ) losses(key, value)
     WHERE value::bigint > 0
       AND NOT EXISTS (
         SELECT 1
           FROM jsonb_array_elements(mission.army) original(item)
          WHERE item->>'unit_type' = key
       )
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_LOSSES',
      'message', 'Gönderilmeyen birlik türü için kayıp bildirildi.'
    );
  END IF;

  -- Validate NPC loss reporting against the immutable NPC snapshot.
  IF EXISTS (
    SELECT 1
      FROM jsonb_each_text(p_npc_losses) losses(key, value)
     WHERE key NOT IN (
       'piyade','savunma','saldiri','okcu','tank','hava'
     )
        OR value !~ '^[0-9]+$'
        OR char_length(value) > 10
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_NPC_LOSSES',
      'message', 'Geçersiz NPC kaybı.'
    );
  END IF;

  FOR loss_key, loss_text IN
    SELECT key, value
      FROM jsonb_each_text(p_npc_losses)
  LOOP
    loss_quantity := loss_text::bigint;

    IF loss_quantity > 2147483647 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_NPC_LOSSES',
        'message', 'Geçersiz NPC kaybı.'
      );
    END IF;

    SELECT value
      INTO npc_item
      FROM jsonb_array_elements(mission.npc_army) npc(value)
     WHERE value->>'unit_type' = loss_key
     LIMIT 1;

    IF npc_item IS NULL THEN
      IF loss_quantity > 0 THEN
        RETURN jsonb_build_object(
          'success', false,
          'code', 'INVALID_NPC_LOSSES',
          'message', 'NPC ordusunda olmayan birlik türü için kayıp bildirildi.'
        );
      END IF;
      CONTINUE;
    END IF;

    npc_type := npc_item->>'unit_type';
    npc_quantity := (npc_item->>'quantity')::bigint;

    IF npc_type IS DISTINCT FROM loss_key
       OR loss_quantity > npc_quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_NPC_LOSSES',
        'message', 'NPC kaybı mevcut birlikten fazla.'
      );
    END IF;
  END LOOP;

  -- Validate immutable reward snapshot before any credit.
  IF mission.reward_snapshot IS NULL
     OR jsonb_typeof(mission.reward_snapshot) IS DISTINCT FROM 'object'
     OR EXISTS (
       SELECT 1
         FROM jsonb_each_text(mission.reward_snapshot) r(key, value)
        WHERE key NOT IN ('metal','energy','alloy','crystal')
           OR value !~ '^[0-9]+$'
           OR char_length(value) > 12
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_REWARD_INVALID',
      'message', 'NPC ödül yapılandırması geçersiz.'
    );
  END IF;

  -- Only victories credit reward. Capacity overflow is not credited and is
  -- recorded as such in settled_reward.
  IF v_result = 'Zafer' THEN
    FOREACH resource_name IN ARRAY
      ARRAY['metal','energy','alloy','crystal']
    LOOP
      reward_text :=
        COALESCE(mission.reward_snapshot->>resource_name, '0');

      IF reward_text !~ '^[0-9]+$'
         OR char_length(reward_text) > 12 THEN
        RETURN jsonb_build_object(
          'success', false,
          'code', 'NPC_REWARD_INVALID',
          'message', 'NPC ödül yapılandırması geçersiz.'
        );
      END IF;

      reward_amount := reward_text::bigint;

      current_amount := CASE resource_name
        WHEN 'metal' THEN GREATEST(0, COALESCE(v_city.metal, 0))
        WHEN 'energy' THEN GREATEST(0, COALESCE(v_city.energy, 0))
        WHEN 'alloy' THEN GREATEST(0, COALESCE(v_city.alloy, 0))
        WHEN 'crystal' THEN GREATEST(0, COALESCE(v_city.crystal, 0))
        ELSE 0
      END;

      capacity :=
        public.nexora_trade_storage_capacity(
          v_city.id,
          resource_name
        );

      credit_amount := reward_amount;

      IF credit_amount > 0 THEN
        EXECUTE format(
          'UPDATE public.cities
              SET %1$I = COALESCE(%1$I,0) + $1,
                  updated_at = clock_timestamp()
            WHERE id = $2',
          resource_name
        )
        USING credit_amount, v_city.id;
      END IF;

      credited_reward :=
        jsonb_set(
          credited_reward,
          ARRAY[resource_name],
          to_jsonb(credit_amount),
          true
        );
    END LOOP;
  END IF;

  v_battle_at := clock_timestamp();
  v_return_at :=
    v_battle_at + make_interval(secs => p_return_seconds);
  v_available_at :=
    v_battle_at + make_interval(secs => mission.cooldown_seconds);

  IF v_expected_result = 'Zafer' THEN
    UPDATE public.npc_camps
       SET active = false,
           respawn_at = v_available_at,
           updated_at = v_battle_at
     WHERE id = mission.npc_camp_id;
  END IF;

  v_report :=
    p_report_base
    ||
    jsonb_build_object(
      'result', v_expected_result,
      'attackPower', p_attack_power,
      'defensePower', p_defense_power,
      'npcLosses', p_npc_losses,
      'configuredReward', mission.reward_snapshot,
      'reward', credited_reward,
      'campId', mission.npc_camp_id,
      'campName', mission.camp_name,
      'campTier', mission.camp_tier,
      'battleTactic', mission.battle_tactic,
      'battleAt', v_battle_at,
      'returnAt', v_return_at,
      'campAvailableAt', v_available_at
    );

  INSERT INTO public.npc_battle_reports(
    npc_mission_id,
    player_id,
    npc_camp_id,
    camp_name,
    camp_tier,
    result,
    attack_power,
    defense_power,
    attacker_losses,
    npc_losses,
    reward,
    battle_tactic,
    report,
    created_at
  )
  VALUES(
    mission.id,
    p_player_id,
    mission.npc_camp_id,
    mission.camp_name,
    mission.camp_tier,
    v_expected_result,
    p_attack_power,
    p_defense_power,
    COALESCE(p_report_base->'attackerLosses', '{}'::jsonb),
    p_npc_losses,
    credited_reward,
    mission.battle_tactic,
    v_report,
    v_battle_at
  )
  RETURNING id INTO v_report_id;

  INSERT INTO public.player_npc_camp_state AS state(
    player_id,
    npc_camp_id,
    victories,
    defeats,
    draws,
    last_battle_at,
    available_at,
    updated_at
  )
  VALUES(
    p_player_id,
    mission.npc_camp_id,
    CASE WHEN v_expected_result = 'Zafer' THEN 1 ELSE 0 END,
    CASE WHEN v_expected_result = 'Yenilgi' THEN 1 ELSE 0 END,
    CASE WHEN v_expected_result = 'Beraberlik' THEN 1 ELSE 0 END,
    v_battle_at,
    v_available_at,
    v_battle_at
  )
  ON CONFLICT (player_id, npc_camp_id)
  DO UPDATE SET
    victories =
      state.victories
      + CASE WHEN v_expected_result = 'Zafer' THEN 1 ELSE 0 END,
    defeats =
      state.defeats
      + CASE WHEN v_expected_result = 'Yenilgi' THEN 1 ELSE 0 END,
    draws =
      state.draws
      + CASE WHEN v_expected_result = 'Beraberlik' THEN 1 ELSE 0 END,
    last_battle_at = v_battle_at,
    available_at = v_available_at,
    updated_at = v_battle_at;

  UPDATE public.npc_missions
     SET status = 'returning',
         arrive_at = v_return_at,
         attack_power = p_attack_power,
         defense_power = p_defense_power,
         result = v_report,
         settled_reward = credited_reward,
         updated_at = v_battle_at
   WHERE id = mission.id
   RETURNING * INTO mission;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyResolved', false,
    'mission', to_jsonb(mission),
    'npcBattleReportId', v_report_id,
    'reward', credited_reward,
    'campAvailableAt', v_available_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_respawn_due_npc()
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_camp public.npc_camps%ROWTYPE;
  v_site public.world_sites%ROWTYPE;
  v_x integer;
  v_y integer;
  v_now timestamptz := clock_timestamp();
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('teryndis_npc_respawn'));

  SELECT c.*
    INTO v_camp
    FROM public.npc_camps c
   WHERE c.active = false
     AND c.respawn_at IS NOT NULL
     AND c.respawn_at <= v_now
     AND EXISTS (
       SELECT 1
         FROM public.world_sites s
        WHERE s.id = c.world_site_id
          AND s.active = true
          AND s.site_type = 'npc_camp'
     )
     AND NOT EXISTS (
       SELECT 1
         FROM public.npc_missions m
        WHERE m.npc_camp_id = c.id
          AND m.status IN ('traveling','resolving','returning')
     )
   ORDER BY c.respawn_at, c.id
   LIMIT 1
   FOR UPDATE SKIP LOCKED;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT s.*
    INTO v_site
    FROM public.world_sites s
   WHERE s.id = v_camp.world_site_id
     AND s.active = true
     AND s.site_type = 'npc_camp'
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT gx, gy
    INTO v_x, v_y
    FROM generate_series(3,97) AS gx
    CROSS JOIN generate_series(3,97) AS gy
   WHERE NOT (
           gx = v_site.coordinate_x
       AND gy = v_site.coordinate_y
         )
     AND NOT EXISTS (
       SELECT 1
         FROM public.cities city
        WHERE city.coordinate_x = gx
          AND city.coordinate_y = gy
     )
     AND NOT EXISTS (
       SELECT 1
         FROM public.world_sites occupied
        WHERE occupied.id <> v_site.id
          AND occupied.coordinate_x = gx
          AND occupied.coordinate_y = gy
     )
   ORDER BY md5(
     v_camp.id::text || ':' ||
     v_camp.respawn_at::text || ':' ||
     gx::text || ':' || gy::text
   )
   LIMIT 1;

  IF v_x IS NULL OR v_y IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public.world_sites
     SET coordinate_x = v_x,
         coordinate_y = v_y
   WHERE id = v_site.id;

  UPDATE public.npc_camps
     SET active = true,
         respawn_at = NULL,
         updated_at = v_now
   WHERE id = v_camp.id;

  RETURN v_camp.id;
END;
$function$;

REVOKE ALL ON FUNCTION public.nexora_respawn_due_npc()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_respawn_due_npc()
  TO service_role;

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM cron.job
     WHERE jobname = 'teryndis-npc-respawn'
  ) THEN
    PERFORM cron.schedule(
      'teryndis-npc-respawn',
      '10 seconds',
      $cron$SELECT public.nexora_respawn_due_npc();$cron$
    );
  END IF;
END;
$do$;

COMMIT;
