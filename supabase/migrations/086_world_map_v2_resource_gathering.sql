-- TERYNDIS 086 World Map V2 + Resource Gathering
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM public.military_missions WHERE status IN ('traveling','resolving','returning'))
     OR EXISTS(SELECT 1 FROM public.npc_missions WHERE status IN ('traveling','resolving','returning'))
     OR EXISTS(SELECT 1 FROM public.world_exploration_missions WHERE status IN ('traveling','resolving'))
     OR EXISTS(SELECT 1 FROM public.espionage_missions WHERE status IN ('traveling','resolving','returning')) THEN
    RAISE EXCEPTION 'WORLD_V2_ACTIVE_MISSIONS';
  END IF;
END;
$guard$;

ALTER TABLE public.world_sites DROP CONSTRAINT IF EXISTS world_sites_coordinate_x_check;
ALTER TABLE public.world_sites DROP CONSTRAINT IF EXISTS world_sites_coordinate_y_check;
ALTER TABLE public.world_sites
  ADD CONSTRAINT world_sites_coordinate_x_check CHECK(coordinate_x BETWEEN 1 AND 200),
  ADD CONSTRAINT world_sites_coordinate_y_check CHECK(coordinate_y BETWEEN 1 AND 200);

UPDATE public.cities SET coordinate_x=coordinate_x*2-1,coordinate_y=coordinate_y*2-1;
UPDATE public.world_sites SET coordinate_x=coordinate_x*2-1,coordinate_y=coordinate_y*2-1;

ALTER TABLE public.world_sites
  ADD COLUMN IF NOT EXISTS resource_type text,
  ADD COLUMN IF NOT EXISTS resource_stock bigint,
  ADD COLUMN IF NOT EXISTS resource_capacity bigint,
  ADD COLUMN IF NOT EXISTS resource_respawn_at timestamptz,
  ADD COLUMN IF NOT EXISTS resource_respawn_seconds integer NOT NULL DEFAULT 600;

ALTER TABLE public.world_sites DROP CONSTRAINT IF EXISTS world_sites_resource_type_check;
ALTER TABLE public.world_sites DROP CONSTRAINT IF EXISTS world_sites_resource_stock_check;
ALTER TABLE public.world_sites DROP CONSTRAINT IF EXISTS world_sites_resource_capacity_check;
ALTER TABLE public.world_sites ADD CONSTRAINT world_sites_resource_type_check CHECK(resource_type IS NULL OR resource_type IN('metal','energy','alloy','crystal'));
ALTER TABLE public.world_sites ADD CONSTRAINT world_sites_resource_stock_check CHECK(resource_stock IS NULL OR resource_stock>=0);
ALTER TABLE public.world_sites ADD CONSTRAINT world_sites_resource_capacity_check CHECK(resource_capacity IS NULL OR resource_capacity>=0);

WITH typed AS(
 SELECT id,CASE greatest(
   COALESCE((reward->>'metal')::int,0),COALESCE((reward->>'energy')::int,0),
   COALESCE((reward->>'alloy')::int,0),COALESCE((reward->>'crystal')::int,0))
   WHEN COALESCE((reward->>'metal')::int,0) THEN 'metal'
   WHEN COALESCE((reward->>'energy')::int,0) THEN 'energy'
   WHEN COALESCE((reward->>'alloy')::int,0) THEN 'alloy'
   ELSE 'crystal' END AS resource_type
 FROM public.world_sites WHERE site_type='resource'
)
UPDATE public.world_sites s SET resource_type=t.resource_type,
 resource_capacity=CASE WHEN t.resource_type='crystal' THEN 2500 ELSE 5000 END,
 resource_stock=CASE WHEN t.resource_type='crystal' THEN 2500 ELSE 5000 END,
 resource_respawn_seconds=CASE WHEN t.resource_type='crystal' THEN 900 ELSE 600 END,
 resource_respawn_at=NULL,owner_player_id=NULL,owner_alliance_id=NULL,claimed_at=NULL,active=true
FROM typed t WHERE s.id=t.id;

INSERT INTO public.world_sites(site_type,name,description,coordinate_x,coordinate_y,reward,active,
 resource_type,resource_stock,resource_capacity,resource_respawn_seconds)
VALUES
 ('resource','Derin Metal Damarı','Yoğun metal cevheri bulunan büyük bir maden sahası.',120,30,'{"metal":500}'::jsonb,true,'metal',5000,5000,600),
 ('resource','Sınır Metal Ocağı','Uzak bölgede keşfedilmiş zengin metal yatağı.',170,50,'{"metal":500}'::jsonb,true,'metal',5000,5000,600),
 ('resource','Plazma Enerji Çekirdeği','Kararsız fakat yüksek verimli enerji toplama noktası.',130,120,'{"energy":500}'::jsonb,true,'energy',5000,5000,600),
 ('resource','Alaşım Enkaz Sahası','Eski savaş makinelerinden yüksek kalite alaşım çıkarılabilir.',180,140,'{"alloy":500}'::jsonb,true,'alloy',5000,5000,600),
 ('resource','Eski Alaşım Fabrikası','Terk edilmiş üretim hatlarında kullanılabilir alaşım stokları var.',110,170,'{"alloy":500}'::jsonb,true,'alloy',5000,5000,600),
 ('resource','Kristal Yarık Kümesi','Yeraltından yüzeye çıkan nadir kristal oluşumları.',150,180,'{"crystal":250}'::jsonb,true,'crystal',2500,2500,900),
 ('resource','Kadim Kristal Damarı','Yüksek saflıkta kristal içeren eski bir damar.',190,110,'{"crystal":250}'::jsonb,true,'crystal',2500,2500,900);

CREATE TABLE public.resource_gather_missions(
 id bigserial PRIMARY KEY,
 player_id bigint NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
 city_id bigint NOT NULL REFERENCES public.cities(id) ON DELETE CASCADE,
 site_id bigint NOT NULL REFERENCES public.world_sites(id) ON DELETE RESTRICT,
 status text NOT NULL DEFAULT 'traveling' CHECK(status IN('traveling','returning','completed')),
 army jsonb NOT NULL,carry_capacity bigint NOT NULL CHECK(carry_capacity>0),
 resource_type text NOT NULL CHECK(resource_type IN('metal','energy','alloy','crystal')),
 gathered_amount bigint NOT NULL DEFAULT 0 CHECK(gathered_amount>=0),
 depart_at timestamptz NOT NULL DEFAULT clock_timestamp(),arrive_at timestamptz NOT NULL,
 return_at timestamptz,completed_at timestamptz,travel_seconds integer NOT NULL CHECK(travel_seconds>0),
 distance numeric NOT NULL DEFAULT 0 CHECK(distance>=0),depart_x integer NOT NULL,depart_y integer NOT NULL,
 target_x integer NOT NULL,target_y integer NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.resource_gather_missions ENABLE ROW LEVEL SECURITY;
CREATE INDEX resource_gather_missions_player_idx ON public.resource_gather_missions(player_id);
CREATE INDEX resource_gather_missions_city_idx ON public.resource_gather_missions(city_id);
CREATE INDEX resource_gather_missions_site_idx ON public.resource_gather_missions(site_id);
CREATE UNIQUE INDEX resource_gather_one_active_player_idx ON public.resource_gather_missions(player_id) WHERE status IN('traveling','returning');

CREATE OR REPLACE FUNCTION public.nexora_create_starting_city(p_player_id bigint, p_name text DEFAULT 'Yeni Koloni'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  existing_city public.cities%ROWTYPE;
  created_city public.cities%ROWTYPE;
  spawn_x integer;
  spawn_y integer;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  -- Preserve the existing registration spawn serialization.
  PERFORM pg_advisory_xact_lock(hashtext('nexora_city_spawn'));

  SELECT *
    INTO existing_city
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF existing_city.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyExists', true,
      'city', to_jsonb(existing_city)
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.players
     WHERE id = p_player_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  SELECT gx, gy
    INTO spawn_x, spawn_y
    FROM generate_series(3, 197, 3) AS gx
    CROSS JOIN generate_series(3, 197, 3) AS gy
   WHERE NOT EXISTS (
           SELECT 1
             FROM public.cities c
            WHERE c.coordinate_x = gx
              AND c.coordinate_y = gy
         )
     AND NOT EXISTS (
           SELECT 1
             FROM public.world_sites ws
            WHERE ws.active = true
              AND ws.coordinate_x = gx
              AND ws.coordinate_y = gy
         )
   ORDER BY md5(
     p_player_id::text || ':' || gx::text || ':' || gy::text
   )
   LIMIT 1;

  IF spawn_x IS NULL OR spawn_y IS NULL THEN
    SELECT gx, gy
      INTO spawn_x, spawn_y
      FROM generate_series(1, 200) AS gx
      CROSS JOIN generate_series(1, 200) AS gy
     WHERE NOT EXISTS (
             SELECT 1
               FROM public.cities c
              WHERE c.coordinate_x = gx
                AND c.coordinate_y = gy
           )
       AND NOT EXISTS (
             SELECT 1
               FROM public.world_sites ws
              WHERE ws.active = true
                AND ws.coordinate_x = gx
                AND ws.coordinate_y = gy
           )
     ORDER BY md5(
       p_player_id::text || ':' || gx::text || ':' || gy::text
     )
     LIMIT 1;
  END IF;

  IF spawn_x IS NULL OR spawn_y IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WORLD_FULL',
      'message', 'Dünya haritasında boş koloni koordinatı kalmadı.'
    );
  END IF;

  INSERT INTO public.cities(
    player_id,
    name,
    level,
    metal,
    energy,
    alloy,
    crystal,
    coordinate_x,
    coordinate_y
  )
  VALUES (
    p_player_id,
    COALESCE(NULLIF(BTRIM(p_name), ''), 'Yeni Koloni'),
    1,
    2250,
    800,
    800,
    300,
    spawn_x,
    spawn_y
  )
  RETURNING *
    INTO created_city;

  UPDATE public.cities
     SET metal = 10000,
         energy = 10000,
         alloy = 10000,
         crystal = 10000,
         metal_capacity = 10000,
         energy_capacity = 10000,
         alloy_capacity = 10000,
         crystal_capacity = 10000,
         updated_at = clock_timestamp()
   WHERE id = created_city.id
   RETURNING *
    INTO created_city;

  -- Starter infrastructure is created inside the same DB transaction as the
  -- city. Any unexpected failure here rolls the entire city creation back.
  INSERT INTO public.buildings(
    city_id,
    building_type,
    slot,
    level,
    is_under_construction,
    upgrade_ready_at
  )
  VALUES
    (created_city.id, 'Merkez Bina',       1, 1, false, NULL),
    (created_city.id, 'Metal Madeni',      1, 1, false, NULL),
    (created_city.id, 'Enerji Santrali',   1, 1, false, NULL),
    (created_city.id, 'Alaşım Rafinerisi',         1, 1, false, NULL)
  ON CONFLICT (city_id, building_type, slot) DO NOTHING;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyExists', false,
    'city', to_jsonb(created_city)
  );
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_move_colony_atomic(p_player_id bigint, p_x integer, p_y integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_city public.cities%ROWTYPE;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  IF p_x IS NULL OR p_y IS NULL
     OR p_x NOT BETWEEN 1 AND 200
     OR p_y NOT BETWEEN 1 AND 200 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_COORDINATE',
      'message', 'X ve Y koordinatları 1-200 arasında tam sayı olmalı.'
    );
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('nexora_city_spawn'));

  SELECT *
    INTO v_city
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF v_city.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  IF COALESCE(v_city.coordinate_x, 0) = p_x
     AND COALESCE(v_city.coordinate_y, 0) = p_y THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SAME_COORDINATE',
      'message', 'Zaten bu koordinattasın.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.military_missions
     WHERE attacker_player_id = p_player_id
       AND status IN ('traveling','resolving','returning')
     LIMIT 1
  )
  OR EXISTS (
    SELECT 1
      FROM public.npc_missions
     WHERE player_id = p_player_id
       AND status IN ('traveling','resolving','returning')
     LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVE_MISSION',
      'message', 'Aktif sefer varken koloni koordinatı değiştirilemez.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.world_sites
     WHERE active = true
       AND coordinate_x = p_x
       AND coordinate_y = p_y
     LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WORLD_SITE_OCCUPIED',
      'message', 'Bu koordinatta aktif bir dünya noktası bulunuyor.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.cities
     WHERE id <> v_city.id
       AND coordinate_x = p_x
       AND coordinate_y = p_y
     LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'COORDINATE_OCCUPIED',
      'message', 'Bu koordinat dolu.'
    );
  END IF;

  UPDATE public.cities
     SET coordinate_x = p_x,
         coordinate_y = p_y,
         updated_at = clock_timestamp()
   WHERE id = v_city.id
   RETURNING * INTO v_city;

  RETURN jsonb_build_object(
    'success', true,
    'code', 'MOVED',
    'message', 'Koloni taşındı.',
    'city', to_jsonb(v_city)
  );
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_region_key(p_x numeric, p_y numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT r.region_key
  FROM (
    VALUES
      ('desert'::text,   1, 20::numeric, 36::numeric),
      ('forest'::text,   2, 84::numeric, 24::numeric),
      ('ice'::text,      3, 182::numeric, 34::numeric),
      ('mountain'::text, 4, 60::numeric, 166::numeric),
      ('volcanic'::text, 5, 144::numeric, 170::numeric),
      ('ocean'::text,    6, 190::numeric, 110::numeric)
  ) AS r(region_key, priority, anchor_x, anchor_y)
  ORDER BY
    (COALESCE(p_x,0) - r.anchor_x) * (COALESCE(p_x,0) - r.anchor_x)
    +
    (COALESCE(p_y,0) - r.anchor_y) * (COALESCE(p_y,0) - r.anchor_y),
    r.priority
  LIMIT 1;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_start_military_mission(p_attacker_player_id bigint, p_defender_player_id bigint, p_attacker_city_id bigint, p_defender_city_id bigint, p_army jsonb, p_attack_power integer, p_depart_x integer, p_depart_y integer, p_target_x integer, p_target_y integer, p_travel_seconds integer, p_fleet_speed numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  attacker public.cities%ROWTYPE;
  defender public.cities%ROWTYPE;
  unit_row public.units%ROWTYPE;
  mission public.military_missions%ROWTYPE;
  item jsonb;
  requested_type text;
  quantity_text text;
  level_text text;
  requested_quantity bigint;
  requested_level integer;
  item_count integer;
  distinct_type_count integer;
  unit_id bigint;
  affected integer;
  depart_time timestamptz;
  arrive_time timestamptz;
  v_now timestamptz;
  v_target_protected_until timestamptz;
  v_target_remaining_seconds integer := 0;
  v_attacker_protection_ended integer := 0;
BEGIN
  IF p_attacker_player_id IS NULL OR p_defender_player_id IS NULL
     OR p_attacker_city_id IS NULL OR p_defender_city_id IS NULL
     OR p_attacker_player_id = p_defender_player_id
     OR p_attacker_city_id = p_defender_city_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_TARGET',
      'message', 'Geçersiz hedef oyuncu.'
    );
  END IF;

  IF p_travel_seconds IS NULL OR p_travel_seconds <= 0 OR p_travel_seconds > 86400
     OR p_fleet_speed IS NULL OR p_fleet_speed <= 0
     OR p_attack_power IS NULL OR p_attack_power <= 0
     OR p_depart_x IS NULL OR p_depart_y IS NULL
     OR p_target_x IS NULL OR p_target_y IS NULL
     OR p_depart_x NOT BETWEEN 0 AND 200
     OR p_depart_y NOT BETWEEN 0 AND 200
     OR p_target_x NOT BETWEEN 0 AND 200
     OR p_target_y NOT BETWEEN 0 AND 200 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_MISSION',
      'message', 'Geçersiz sefer bilgisi.'
    );
  END IF;

  -- Lock both cities in deterministic order. The attacker-city lock remains the
  -- serialization point for concurrent mission-start requests from one player.
  PERFORM id
  FROM public.cities
  WHERE id IN (p_attacker_city_id, p_defender_city_id)
  ORDER BY id
  FOR UPDATE;

  SELECT * INTO attacker
  FROM public.cities
  WHERE id = p_attacker_city_id
    AND player_id = p_attacker_player_id;

  IF attacker.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Saldıran koloni bulunamadı.'
    );
  END IF;

  SELECT * INTO defender
  FROM public.cities
  WHERE id = p_defender_city_id
    AND player_id = p_defender_player_id;

  IF defender.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_CITY_NOT_FOUND',
      'message', 'Hedef koloni bulunamadı.'
    );
  END IF;

  -- Do not start with stale coordinates if either colony moved between the
  -- backend read and this transaction.
  IF COALESCE(attacker.coordinate_x, 0) <> p_depart_x
     OR COALESCE(attacker.coordinate_y, 0) <> p_depart_y
     OR COALESCE(defender.coordinate_x, 0) <> p_target_x
     OR COALESCE(defender.coordinate_y, 0) <> p_target_y THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_CHANGED',
      'message', 'Koloni koordinatları değişti; haritayı yenileyip tekrar deneyin.'
    );
  END IF;

  -- Protection rows are locked after the existing deterministic city locks.
  -- Missing rows mean legacy/pre-migration players and therefore no protection.
  PERFORM player_id
  FROM public.player_pvp_protection
  WHERE player_id IN (p_attacker_player_id, p_defender_player_id)
  ORDER BY player_id
  FOR UPDATE;

  v_now := clock_timestamp();

  SELECT s.protected_until
    INTO v_target_protected_until
    FROM public.player_pvp_protection s
   WHERE s.player_id = p_defender_player_id
     AND s.ended_at IS NULL;

  IF v_target_protected_until IS NOT NULL
     AND v_target_protected_until > v_now THEN
    v_target_remaining_seconds := GREATEST(
      0,
      CEIL(
        EXTRACT(
          EPOCH FROM (v_target_protected_until - v_now)
        )
      )::integer
    );

    RETURN jsonb_build_object(
      'success', false,
      'code', 'TARGET_PVP_PROTECTED',
      'message', 'Bu oyuncu yeni oyuncu PvP koruması altında.',
      'protectedUntil', v_target_protected_until,
      'remainingSeconds', v_target_remaining_seconds
    );
  END IF;

  -- This check is authoritative because it runs after the attacker-city lock.
  IF EXISTS (
    SELECT 1
    FROM public.military_missions
    WHERE attacker_player_id = p_attacker_player_id
      AND status IN ('traveling', 'resolving', 'returning')
    LIMIT 1
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ACTIVE_MISSION',
      'message', 'Zaten aktif bir seferin bulunuyor.'
    );
  END IF;

  IF p_army IS NULL OR jsonb_typeof(p_army) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ARMY',
      'message', 'Geçersiz ordu bilgisi.'
    );
  END IF;

  SELECT COUNT(*), COUNT(DISTINCT (value->>'unit_type'))
  INTO item_count, distinct_type_count
  FROM jsonb_array_elements(p_army) AS army_item(value);

  IF item_count < 1 OR item_count > 6 OR distinct_type_count <> item_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ARMY',
      'message', 'Geçersiz veya tekrarlanan birlik seçimi.'
    );
  END IF;

  -- Validate every requested unit and lock the live unit rows before any write.
  FOR item IN
    SELECT value FROM jsonb_array_elements(p_army) AS army_item(value)
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
       OR requested_type NOT IN ('piyade','savunma','saldiri','okcu','tank','hava') THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_UNIT',
        'message', 'Geçersiz birlik türü.'
      );
    END IF;

    IF quantity_text IS NULL
       OR quantity_text !~ '^[1-9][0-9]*$'
       OR char_length(quantity_text) > 10 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Birlik miktarı pozitif tam sayı olmalı.'
      );
    END IF;

    requested_quantity := quantity_text::bigint;
    IF requested_quantity <= 0 OR requested_quantity > 2147483647 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz birlik miktarı.'
      );
    END IF;

    IF level_text IS NULL
       OR level_text !~ '^[1-9][0-9]*$'
       OR char_length(level_text) > 2 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz birlik seviyesi.'
      );
    END IF;

    requested_level := level_text::integer;
    IF requested_level < 1 OR requested_level > 15 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INVALID_ARMY',
        'message', 'Geçersiz birlik seviyesi.'
      );
    END IF;

    SELECT * INTO unit_row
    FROM public.units
    WHERE city_id = attacker.id
      AND unit_type = requested_type
    ORDER BY id
    LIMIT 1
    FOR UPDATE;

    IF unit_row.id IS NULL OR COALESCE(unit_row.quantity, 0) < requested_quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INSUFFICIENT_UNITS',
        'message', requested_type || ' için yeterli birlik yok.'
      );
    END IF;

    IF GREATEST(1, COALESCE(unit_row.level, 1)) <> requested_level THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'UNIT_CHANGED',
        'message', 'Birlik seviyesi değişti; orduyu yenileyip tekrar deneyin.'
      );
    END IF;
  END LOOP;

  -- Every failure-return above has passed. If the attacker is still protected,
  -- voluntarily starting this valid real-player attack ends that protection.
  -- This update and the army deduction / mission insert are in one transaction;
  -- any unexpected exception later rolls all of them back together.
  v_now := clock_timestamp();

  UPDATE public.player_pvp_protection
     SET ended_at = v_now,
         ended_reason = 'pvp_attack',
         updated_at = v_now
   WHERE player_id = p_attacker_player_id
     AND ended_at IS NULL
     AND protected_until > v_now;

  GET DIAGNOSTICS v_attacker_protection_ended = ROW_COUNT;

  -- All checks passed. Spend each unit exactly once while the rows remain locked.
  FOR item IN
    SELECT value FROM jsonb_array_elements(p_army) AS army_item(value)
  LOOP
    requested_type := item->>'unit_type';
    requested_quantity := (item->>'quantity')::bigint;

    SELECT id INTO unit_id
    FROM public.units
    WHERE city_id = attacker.id
      AND unit_type = requested_type
    ORDER BY id
    LIMIT 1;

    UPDATE public.units
    SET quantity = quantity - requested_quantity
    WHERE id = unit_id
      AND quantity >= requested_quantity;

    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected <> 1 THEN
      RAISE EXCEPTION 'Ordu miktarı işlem sırasında değişti.';
    END IF;
  END LOOP;

  depart_time := clock_timestamp();
  arrive_time := depart_time + make_interval(secs => p_travel_seconds);

  INSERT INTO public.military_missions(
    attacker_player_id,
    defender_player_id,
    attacker_city_id,
    defender_city_id,
    mission_type,
    status,
    depart_at,
    arrive_at,
    attack_power,
    army,
    depart_x,
    depart_y,
    target_x,
    target_y,
    travel_seconds,
    fleet_speed
  ) VALUES (
    p_attacker_player_id,
    p_defender_player_id,
    attacker.id,
    defender.id,
    'attack',
    'traveling',
    depart_time,
    arrive_time,
    p_attack_power,
    p_army,
    p_depart_x,
    p_depart_y,
    p_target_x,
    p_target_y,
    p_travel_seconds,
    p_fleet_speed
  )
  RETURNING * INTO mission;

  RETURN jsonb_build_object(
    'success', true,
    'mission', to_jsonb(mission),
    'attackerProtectionEnded', v_attacker_protection_ended = 1
  );
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_start_military_mission(p_attacker_player_id bigint, p_defender_player_id bigint, p_attacker_city_id bigint, p_defender_city_id bigint, p_army jsonb, p_attack_power integer, p_depart_x integer, p_depart_y integer, p_target_x integer, p_target_y integer, p_travel_seconds integer, p_fleet_speed numeric, p_battle_tactic text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_result jsonb;
  v_mission_id bigint;
  v_mission public.military_missions%ROWTYPE;
  v_tactic text;
BEGIN
  v_tactic := lower(trim(COALESCE(p_battle_tactic, '')));

  IF v_tactic NOT IN ('assault', 'balanced', 'cautious') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_TACTIC',
      'message', 'Geçersiz savaş taktiği.'
    );
  END IF;

  SELECT public.nexora_start_military_mission(
    p_attacker_player_id,
    p_defender_player_id,
    p_attacker_city_id,
    p_defender_city_id,
    p_army,
    p_attack_power,
    p_depart_x,
    p_depart_y,
    p_target_x,
    p_target_y,
    p_travel_seconds,
    p_fleet_speed
  )
  INTO v_result;

  IF v_result IS NULL OR v_result->>'success' IS DISTINCT FROM 'true' THEN
    RETURN v_result;
  END IF;

  BEGIN
    v_mission_id := NULLIF(v_result->'mission'->>'id', '')::bigint;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Sefer kimliği doğrulanamadı.';
  END;

  IF v_mission_id IS NULL OR v_mission_id <= 0 THEN
    RAISE EXCEPTION 'Sefer kimliği doğrulanamadı.';
  END IF;

  UPDATE public.military_missions
  SET battle_tactic = v_tactic
  WHERE id = v_mission_id
    AND attacker_player_id = p_attacker_player_id
  RETURNING * INTO v_mission;

  IF v_mission.id IS NULL THEN
    RAISE EXCEPTION 'Savaş taktiği sefere kaydedilemedi.';
  END IF;

  RETURN v_result || jsonb_build_object(
    'mission', to_jsonb(v_mission)
  );
END;
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
     OR p_depart_x NOT BETWEEN 1 AND 200
     OR p_depart_y NOT BETWEEN 1 AND 200 THEN
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
    FROM generate_series(3,197) AS gx
    CROSS JOIN generate_series(3,197) AS gy
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
CREATE OR REPLACE FUNCTION public.nexora_start_resource_gather(
  p_player_id bigint, p_city_id bigint, p_site_id bigint, p_army jsonb,
  p_depart_x integer, p_depart_y integer, p_travel_seconds integer
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  c public.cities%ROWTYPE; s public.world_sites%ROWTYPE; m public.resource_gather_missions%ROWTYPE;
  u public.units%ROWTYPE; item jsonb; clean_army jsonb:='[]'::jsonb;
  typ text; qty_text text; lvl_text text; qty bigint; lvl integer; cnt integer; distinct_cnt integer;
  cap bigint:=0; pop_cost integer; now_at timestamptz:=clock_timestamp(); dist numeric;
  unit_id bigint; affected integer;
BEGIN
  IF p_player_id IS NULL OR p_player_id<=0 OR p_city_id IS NULL OR p_city_id<=0
     OR p_site_id IS NULL OR p_site_id<=0 OR p_depart_x NOT BETWEEN 1 AND 200
     OR p_depart_y NOT BETWEEN 1 AND 200 OR p_travel_seconds NOT BETWEEN 1 AND 86400 THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_MISSION','message','Geçersiz kaynak seferi.');
  END IF;

  SELECT * INTO c FROM public.cities WHERE id=p_city_id AND player_id=p_player_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','CITY_NOT_FOUND','message','Koloni bulunamadı.'); END IF;
  IF c.coordinate_x<>p_depart_x OR c.coordinate_y<>p_depart_y THEN
    RETURN jsonb_build_object('success',false,'code','CITY_CHANGED','message','Koloni koordinatı değişti; haritayı yenileyip tekrar deneyin.');
  END IF;

  IF EXISTS(SELECT 1 FROM public.resource_gather_missions WHERE player_id=p_player_id AND status IN ('traveling','returning')) THEN
    RETURN jsonb_build_object('success',false,'code','ACTIVE_RESOURCE_MISSION','message','Zaten aktif bir kaynak toplama seferin bulunuyor.');
  END IF;

  SELECT * INTO s FROM public.world_sites
  WHERE id=p_site_id AND site_type='resource' AND active=true
    AND resource_type IN ('metal','energy','alloy','crystal') AND COALESCE(resource_stock,0)>0
  FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','RESOURCE_SITE_NOT_FOUND','message','Kaynak noktası artık kullanılamıyor.'); END IF;

  IF p_army IS NULL OR jsonb_typeof(p_army) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_ARMY','message','Geçersiz birlik seçimi.');
  END IF;
  SELECT COUNT(*),COUNT(DISTINCT value->>'unit_type') INTO cnt,distinct_cnt FROM jsonb_array_elements(p_army) a(value);
  IF cnt<1 OR cnt>6 OR cnt<>distinct_cnt THEN
    RETURN jsonb_build_object('success',false,'code','INVALID_ARMY','message','Geçersiz veya tekrarlanan birlik seçimi.');
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(p_army) a(value) LOOP
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
    cap:=cap + qty*pop_cost*100;
    clean_army:=clean_army||jsonb_build_array(jsonb_build_object(
      'unit_type',typ,'quantity',qty,'level',lvl,'population_cost',pop_cost
    ));
  END LOOP;

  FOR item IN SELECT value FROM jsonb_array_elements(clean_army) a(value) LOOP
    typ:=item->>'unit_type'; qty:=(item->>'quantity')::bigint;
    SELECT id INTO unit_id FROM public.units WHERE city_id=c.id AND unit_type=typ ORDER BY id LIMIT 1;
    UPDATE public.units SET quantity=quantity-qty WHERE id=unit_id AND quantity>=qty;
    GET DIAGNOSTICS affected=ROW_COUNT;
    IF affected<>1 THEN RAISE EXCEPTION 'Kaynak seferi birlik miktarı beklenmedik biçimde değişti.'; END IF;
  END LOOP;

  dist:=sqrt(power((s.coordinate_x-c.coordinate_x)::numeric,2)+power((s.coordinate_y-c.coordinate_y)::numeric,2));
  INSERT INTO public.resource_gather_missions(
    player_id,city_id,site_id,status,army,carry_capacity,resource_type,
    depart_at,arrive_at,travel_seconds,distance,depart_x,depart_y,target_x,target_y,updated_at
  ) VALUES(
    p_player_id,c.id,s.id,'traveling',clean_army,cap,s.resource_type,
    now_at,now_at+make_interval(secs=>p_travel_seconds),p_travel_seconds,dist,
    c.coordinate_x,c.coordinate_y,s.coordinate_x,s.coordinate_y,now_at
  ) RETURNING * INTO m;

  RETURN jsonb_build_object('success',true,'message','🚚 Birlikler kaynak toplamaya gönderildi.',
    'mission',to_jsonb(m),'site',jsonb_build_object(
      'id',s.id,'name',s.name,'resourceType',s.resource_type,'stock',s.resource_stock,
      'capacity',s.resource_capacity,'coordinateX',s.coordinate_x,'coordinateY',s.coordinate_y
    ));
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_sync_resource_gather_mission(p_player_id bigint,p_mission_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  m public.resource_gather_missions%ROWTYPE; s public.world_sites%ROWTYPE; c public.cities%ROWTYPE;
  item jsonb; typ text; qty bigint; lvl integer; existing public.units%ROWTYPE; stats public.unit_levels%ROWTYPE;
  pop_cost integer; now_at timestamptz:=clock_timestamp(); gathered bigint:=0; new_stock bigint:=0; remaining integer:=0;
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

    UPDATE public.resource_gather_missions SET
      status='returning',gathered_amount=gathered,
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

  FOR item IN SELECT value FROM jsonb_array_elements(m.army) a(value) LOOP
    typ:=item->>'unit_type'; qty:=COALESCE(NULLIF(item->>'quantity','')::bigint,0); lvl:=COALESCE(NULLIF(item->>'level','')::integer,1);
    IF typ NOT IN ('piyade','savunma','saldiri','okcu','tank','hava')
       OR qty<0 OR qty>2147483647 OR lvl<1 OR lvl>15 THEN
      RAISE EXCEPTION 'Kaynak seferi dönüş ordusu geçersiz.';
    END IF;
    IF qty=0 THEN CONTINUE; END IF;

    SELECT * INTO stats FROM public.unit_levels WHERE unit_type=typ AND level=lvl LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'Kaynak seferi dönüş birlik seviyesi bulunamadı.'; END IF;
    pop_cost:=CASE typ WHEN 'tank' THEN 3 WHEN 'hava' THEN 2 ELSE 1 END;

    SELECT * INTO existing FROM public.units WHERE city_id=m.city_id AND unit_type=typ ORDER BY id LIMIT 1 FOR UPDATE;
    IF existing.id IS NOT NULL THEN
      UPDATE public.units SET quantity=COALESCE(quantity,0)+qty WHERE id=existing.id;
    ELSE
      INSERT INTO public.units(city_id,unit_type,quantity,level,attack,defense,hp,speed,population_cost)
      VALUES(m.city_id,typ,qty,lvl,stats.attack,stats.defense,stats.hp,stats.speed,pop_cost);
    END IF;
  END LOOP;

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
CREATE OR REPLACE FUNCTION public.nexora_respawn_due_resource_site()
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE s public.world_sites%ROWTYPE; x integer; y integer; now_at timestamptz:=clock_timestamp();
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('teryndis_resource_respawn'));
  SELECT * INTO s FROM public.world_sites
  WHERE site_type='resource' AND active=false AND resource_respawn_at IS NOT NULL AND resource_respawn_at<=now_at
    AND NOT EXISTS(SELECT 1 FROM public.resource_gather_missions m WHERE m.site_id=world_sites.id AND m.status='traveling')
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
    resource_respawn_at=NULL,active=true WHERE id=s.id;
  RETURN s.id;
END;
$function$;
CREATE OR REPLACE FUNCTION public.nexora_resource_gather_tick()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE rec record; processed integer:=0; respawned integer:=0; sid bigint; i integer;
BEGIN
  FOR rec IN
    SELECT id,player_id FROM public.resource_gather_missions
    WHERE (status='traveling' AND arrive_at<=clock_timestamp())
       OR (status='returning' AND return_at IS NOT NULL AND return_at<=clock_timestamp())
    ORDER BY COALESCE(return_at,arrive_at),id LIMIT 20
  LOOP
    PERFORM public.nexora_sync_resource_gather_mission(rec.player_id,rec.id);
    processed:=processed+1;
  END LOOP;

  FOR i IN 1..10 LOOP
    sid:=public.nexora_respawn_due_resource_site();
    EXIT WHEN sid IS NULL;
    respawned:=respawned+1;
  END LOOP;
  RETURN jsonb_build_object('success',true,'processed',processed,'respawned',respawned);
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

  IF v_site.site_type = 'resource' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'RESOURCE_GATHER_ONLY',
      'message', 'Kaynak noktalarına keşif yerine asker göndererek kaynak toplanır.'
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
CREATE OR REPLACE FUNCTION public.nexora_claim_world_site(p_player_id bigint, p_site_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_site public.world_sites%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_member public.alliance_members%ROWTYPE;
  v_alliance public.alliances%ROWTYPE;
  v_role text;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR p_site_id IS NULL OR p_site_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ID',
      'message', 'Geçersiz oyuncu veya nokta.'
    );
  END IF;

  SELECT *
    INTO v_site
    FROM public.world_sites
   WHERE id = p_site_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_NOT_FOUND',
      'message', 'Dünya noktası bulunamadı.'
    );
  END IF;

  IF v_site.active IS DISTINCT FROM true THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_DISABLED',
      'message', 'Bu nokta kontrol altına alınamaz.'
    );
  END IF;

  IF v_site.site_type = 'resource' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'RESOURCE_GATHER_ONLY',
      'message', 'Kaynak noktaları kontrol altına alınmaz; asker göndererek kaynak toplanır.'
    );
  END IF;

  IF v_site.site_type = 'npc_camp' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NPC_CAMP_COMBAT_ONLY',
      'message', 'NPC kampları kontrol altına alınamaz; yalnızca saldırılabilir.'
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
        'message', 'İttifak bölgesini almak için bir ittifakta olmalısın.'
      );
    END IF;

    SELECT *
      INTO v_alliance
      FROM public.alliances
     WHERE id = v_member.alliance_id
     FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'ALLIANCE_NOT_FOUND',
        'message', 'İttifak bulunamadı.'
      );
    END IF;

    SELECT *
      INTO v_member
      FROM public.alliance_members
     WHERE player_id = p_player_id
       AND alliance_id = v_alliance.id
     ORDER BY id
     LIMIT 1
     FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'ALLIANCE_CHANGED',
        'message', 'İttifak üyeliğin değişti. Tekrar dene.'
      );
    END IF;

    v_role := CASE
      WHEN v_member.role = 'leader' THEN 'leader'
      WHEN v_member.role_v2 = 'officer' THEN 'officer'
      ELSE 'member'
    END;

    IF v_role NOT IN ('leader', 'officer') THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'INSUFFICIENT_ROLE',
        'message', 'İttifak bölgesini yalnız lider veya subay kontrol altına alabilir.'
      );
    END IF;

    IF v_site.owner_alliance_id = v_alliance.id THEN
      RETURN jsonb_build_object(
        'success', true,
        'alreadyOwned', true,
        'siteId', v_site.id,
        'owner_alliance_id', v_alliance.id,
        'claimed_at', v_site.claimed_at,
        'message', 'Bu bölge zaten ittifakının kontrolünde.'
      );
    END IF;

    IF v_site.owner_alliance_id IS NOT NULL
       OR v_site.owner_player_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'SITE_OWNED',
        'message', 'Bu bölge başka bir güç tarafından kontrol ediliyor.'
      );
    END IF;

    IF NOT EXISTS (
      SELECT 1
        FROM public.world_exploration_missions m
        JOIN public.alliance_members am
          ON am.player_id = m.player_id
         AND am.alliance_id = v_alliance.id
       WHERE m.site_id = p_site_id
         AND m.status = 'completed'
    ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'EXPLORATION_REQUIRED',
        'message', 'Önce ittifak üyelerinden biri bu bölgenin keşfini tamamlamalı.'
      );
    END IF;

    IF (
      SELECT COUNT(*)
        FROM public.world_sites
       WHERE site_type = 'alliance'
         AND owner_alliance_id = v_alliance.id
    ) >= 2 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'ALLIANCE_CLAIM_LIMIT',
        'message', 'Bir ittifak en fazla 2 ittifak bölgesi kontrol edebilir.'
      );
    END IF;

    UPDATE public.world_sites
       SET owner_alliance_id = v_alliance.id,
           owner_player_id = NULL,
           claimed_at = now()
     WHERE id = v_site.id
     RETURNING * INTO v_site;

    INSERT INTO public.alliance_activity(
      alliance_id,
      event_type,
      actor_player_id,
      target_player_id,
      metadata
    )
    VALUES(
      v_alliance.id,
      'territory_claimed',
      p_player_id,
      NULL,
      jsonb_build_object(
        'siteId', v_site.id,
        'siteName', v_site.name,
        'coordinateX', v_site.coordinate_x,
        'coordinateY', v_site.coordinate_y
      )
    );

    RETURN jsonb_build_object(
      'success', true,
      'alreadyOwned', false,
      'siteId', v_site.id,
      'owner_alliance_id', v_alliance.id,
      'owner_alliance_name', v_alliance.name,
      'owner_alliance_tag', v_alliance.tag,
      'claimed_at', v_site.claimed_at,
      'message', 'İttifak bölgesi kontrol altına alındı.'
    );
  END IF;

  PERFORM id
    FROM public.players
   WHERE id = p_player_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  IF v_site.owner_player_id = p_player_id THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyOwned', true,
      'siteId', v_site.id,
      'owner_player_id', p_player_id,
      'claimed_at', v_site.claimed_at,
      'message', 'Bu nokta zaten senin kontrolünde.'
    );
  END IF;

  IF v_site.owner_player_id IS NOT NULL
     OR v_site.owner_alliance_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SITE_OWNED',
      'message', 'Bu nokta başka bir oyuncunun kontrolünde.'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.world_exploration_missions
     WHERE player_id = p_player_id
       AND site_id = p_site_id
       AND status = 'completed'
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'EXPLORATION_REQUIRED',
      'message', 'Önce bu noktanın keşfini tamamlamalısın.'
    );
  END IF;

  IF (
    SELECT COUNT(*)
      FROM public.world_sites
     WHERE owner_player_id = p_player_id
  ) >= 2 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CLAIM_LIMIT',
      'message', 'En fazla 2 stratejik nokta kontrol edebilirsin.'
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

  UPDATE public.world_sites
     SET owner_player_id = p_player_id,
         owner_alliance_id = NULL,
         claimed_at = now()
   WHERE id = p_site_id
   RETURNING * INTO v_site;

  RETURN jsonb_build_object(
    'success', true,
    'alreadyOwned', false,
    'siteId', v_site.id,
    'owner_player_id', p_player_id,
    'claimed_at', v_site.claimed_at,
    'message', 'Nokta kontrol altına alındı.'
  );
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

REVOKE ALL ON FUNCTION public.nexora_start_resource_gather(bigint,bigint,bigint,jsonb,integer,integer,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.nexora_sync_resource_gather_mission(bigint,bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.nexora_respawn_due_resource_site() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.nexora_resource_gather_tick() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_start_resource_gather(bigint,bigint,bigint,jsonb,integer,integer,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_sync_resource_gather_mission(bigint,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_respawn_due_resource_site() TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_resource_gather_tick() TO service_role;

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
DO $cron_setup$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobname='teryndis-resource-gather') THEN
   PERFORM cron.schedule('teryndis-resource-gather','10 seconds',$cron$SELECT public.nexora_resource_gather_tick();$cron$);
 END IF;
END;
$cron_setup$;

COMMIT;
