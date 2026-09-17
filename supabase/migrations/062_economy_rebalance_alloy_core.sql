-- NEXORA - Economy Rebalance V1 / Alloy Core
-- Migration 062
--
-- Canonical economy rules:
--   Metal  : core construction / standard military
--   Alloy  : construction / standard military
--   Energy : advanced technology / Tank / Air
--   Crystal: rare / advanced progression
--
-- Production:
--   Metal  = 12 per total mine level / minute
--   Energy =  6 per total plant level / minute
--   Alloy  = 10 per total refinery level / minute
--   Crystal=  5 per total mine level / minute
--
-- Legacy water remains synchronized by migration 061 only during rollout.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_spend_city_resources_v2(
  p_player_id bigint,
  p_metal bigint,
  p_energy bigint,
  p_alloy bigint,
  p_crystal bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_city public.cities%ROWTYPE;
  v_metal bigint := COALESCE(p_metal, 0);
  v_energy bigint := COALESCE(p_energy, 0);
  v_alloy bigint := COALESCE(p_alloy, 0);
  v_crystal bigint := COALESCE(p_crystal, 0);
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  IF v_metal < 0 OR v_energy < 0 OR v_alloy < 0 OR v_crystal < 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_COST',
      'message', 'Kaynak maliyeti negatif olamaz.'
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

  IF COALESCE(v_city.metal, 0) < v_metal
     OR COALESCE(v_city.energy, 0) < v_energy
     OR COALESCE(v_city.alloy, 0) < v_alloy
     OR COALESCE(v_city.crystal, 0) < v_crystal THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INSUFFICIENT_RESOURCES',
      'message', 'Yeterli kaynak yok.',
      'available', jsonb_build_object(
        'metal', COALESCE(v_city.metal, 0),
        'energy', COALESCE(v_city.energy, 0),
        'alloy', COALESCE(v_city.alloy, 0),
        'crystal', COALESCE(v_city.crystal, 0)
      ),
      'cost', jsonb_build_object(
        'metal', v_metal,
        'energy', v_energy,
        'alloy', v_alloy,
        'crystal', v_crystal
      )
    );
  END IF;

  UPDATE public.cities
     SET metal = COALESCE(metal, 0) - v_metal,
         energy = COALESCE(energy, 0) - v_energy,
         alloy = COALESCE(alloy, 0) - v_alloy,
         crystal = COALESCE(crystal, 0) - v_crystal
   WHERE id = v_city.id
   RETURNING * INTO v_city;

  RETURN jsonb_build_object(
    'success', true,
    'city', to_jsonb(v_city),
    'cost', jsonb_build_object(
      'metal', v_metal,
      'energy', v_energy,
      'alloy', v_alloy,
      'crystal', v_crystal
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_sync_city_production(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_city public.cities%ROWTYPE;
  v_now timestamptz := now();
  v_last timestamptz;
  v_elapsed_minutes integer := 0;

  v_metal_level integer := 0;
  v_energy_level integer := 0;
  v_alloy_level integer := 0;
  v_crystal_level integer := 0;
  v_depo_level integer := 0;
  v_crystal_depo_level integer := 0;

  v_production_research integer := 0;
  v_crystal_research integer := 0;

  v_region_bonus jsonb := '{}'::jsonb;
  v_region_bonus_active boolean := false;
  v_region_bonus_key text;

  v_metal_rate numeric := 0;
  v_energy_rate numeric := 0;
  v_alloy_rate numeric := 0;
  v_crystal_rate numeric := 0;

  v_storage bigint := 5000;
  v_crystal_storage bigint := 3000;

  v_add_metal bigint := 0;
  v_add_energy bigint := 0;
  v_add_alloy bigint := 0;
  v_add_crystal bigint := 0;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
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

  SELECT
    COALESCE(SUM(level) FILTER (
      WHERE building_type = 'Metal Madeni'
    ),0)::integer,
    COALESCE(SUM(level) FILTER (
      WHERE building_type = 'Enerji Santrali'
    ),0)::integer,
    COALESCE(SUM(level) FILTER (
      WHERE building_type IN ('Su Arıtma', 'Alaşım Rafinerisi')
    ),0)::integer,
    COALESCE(SUM(level) FILTER (
      WHERE building_type = 'Kristal Madeni'
    ),0)::integer,
    COALESCE(SUM(level) FILTER (
      WHERE building_type = 'Depo'
    ),0)::integer,
    COALESCE(MAX(level) FILTER (
      WHERE building_type = 'Kristal Deposu'
    ),0)::integer
  INTO
    v_metal_level,
    v_energy_level,
    v_alloy_level,
    v_crystal_level,
    v_depo_level,
    v_crystal_depo_level
  FROM public.buildings
  WHERE city_id = v_city.id;

  SELECT
    COALESCE(production_level,0),
    COALESCE(crystal_level,0)
  INTO
    v_production_research,
    v_crystal_research
  FROM public.research
  WHERE player_id = p_player_id
  ORDER BY id
  LIMIT 1;

  IF NOT FOUND THEN
    v_production_research := 0;
    v_crystal_research := 0;
  END IF;

  v_region_bonus :=
    public.nexora_player_alliance_region_bonus(p_player_id);

  IF COALESCE(v_region_bonus->>'success','false') = 'true' THEN
    v_region_bonus_active :=
      COALESCE((v_region_bonus->>'active')::boolean,false);
    v_region_bonus_key := v_region_bonus->>'bonusKey';
  END IF;

  v_storage :=
    5000 + GREATEST(0,v_depo_level) * 2500;

  v_crystal_storage :=
    3000 + GREATEST(0,v_crystal_depo_level) * 1500;

  v_metal_rate :=
    GREATEST(0,v_metal_level) * 12
    * (1 + GREATEST(0,v_production_research) * 0.10);

  v_energy_rate :=
    GREATEST(0,v_energy_level) * 6
    * (1 + GREATEST(0,v_production_research) * 0.10);

  v_alloy_rate :=
    GREATEST(0,v_alloy_level) * 10
    * (1 + GREATEST(0,v_production_research) * 0.10);

  v_crystal_rate :=
    GREATEST(0,v_crystal_level) * 5
    * (1 + GREATEST(0,v_crystal_research) * 0.08);

  IF v_region_bonus_active THEN
    CASE v_region_bonus_key
      WHEN 'metal_production' THEN
        v_metal_rate := v_metal_rate * 1.05;
      WHEN 'energy_production' THEN
        v_energy_rate := v_energy_rate * 1.05;
      WHEN 'water_production' THEN
        v_alloy_rate := v_alloy_rate * 1.05;
      WHEN 'alloy_production' THEN
        v_alloy_rate := v_alloy_rate * 1.05;
      WHEN 'crystal_production' THEN
        v_crystal_rate := v_crystal_rate * 1.05;
      ELSE
        NULL;
    END CASE;
  END IF;

  v_last := COALESCE(
    v_city.last_production_at,
    v_city.updated_at,
    v_now
  );

  v_elapsed_minutes := GREATEST(
    0,
    FLOOR(
      EXTRACT(EPOCH FROM (v_now - v_last)) / 60
    )::integer
  );

  IF v_elapsed_minutes > 0 THEN
    v_add_metal :=
      FLOOR(v_metal_rate * v_elapsed_minutes)::bigint;
    v_add_energy :=
      FLOOR(v_energy_rate * v_elapsed_minutes)::bigint;
    v_add_alloy :=
      FLOOR(v_alloy_rate * v_elapsed_minutes)::bigint;
    v_add_crystal :=
      FLOOR(v_crystal_rate * v_elapsed_minutes)::bigint;

    UPDATE public.cities
       SET metal = LEAST(
             v_storage,
             GREATEST(0,COALESCE(metal,0) + v_add_metal)
           ),
           energy = LEAST(
             v_storage,
             GREATEST(0,COALESCE(energy,0) + v_add_energy)
           ),
           alloy = LEAST(
             v_storage,
             GREATEST(0,COALESCE(alloy,0) + v_add_alloy)
           ),
           crystal = LEAST(
             v_crystal_storage,
             GREATEST(0,COALESCE(crystal,0) + v_add_crystal)
           ),
           metal_capacity = v_storage,
           energy_capacity = v_storage,
           alloy_capacity = v_storage,
           crystal_capacity = v_crystal_storage,
           last_production_at = v_now,
           updated_at = v_now
     WHERE id = v_city.id
     RETURNING * INTO v_city;
  ELSE
    UPDATE public.cities
       SET metal_capacity = v_storage,
           energy_capacity = v_storage,
           alloy_capacity = v_storage,
           crystal_capacity = v_crystal_storage
     WHERE id = v_city.id
       AND (
         metal_capacity IS DISTINCT FROM v_storage
         OR energy_capacity IS DISTINCT FROM v_storage
         OR alloy_capacity IS DISTINCT FROM v_storage
         OR crystal_capacity IS DISTINCT FROM v_crystal_storage
       )
     RETURNING * INTO v_city;

    IF NOT FOUND THEN
      SELECT *
        INTO v_city
        FROM public.cities
       WHERE player_id = p_player_id
       ORDER BY id
       LIMIT 1;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'city', to_jsonb(v_city),
    'serverTime', v_now,
    'elapsedMinutes', v_elapsed_minutes,
    'production', jsonb_build_object(
      'metalPerMinute', v_metal_rate,
      'energyPerMinute', v_energy_rate,
      'alloyPerMinute', v_alloy_rate,
      'waterPerMinute', v_alloy_rate,
      'crystalPerMinute', v_crystal_rate
    ),
    'capacities', jsonb_build_object(
      'storage', v_storage,
      'alloyStorage', v_storage,
      'waterStorage', v_storage,
      'crystalStorage', v_crystal_storage
    ),
    'allianceRegionBonus', v_region_bonus
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_start_unit_training_bulk(
  p_player_id bigint,
  p_city_id bigint,
  p_type text,
  p_requested_quantity bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  c public.cities%ROWTYPE;
  q public.unit_production_queue%ROWTYPE;
  cfg record;
  spent jsonb;

  population bigint := 0;
  active_military bigint := 0;
  housing integer := 100;
  barracks integer := 0;
  army integer := 50;

  available_capacity bigint := 0;
  max_by_capacity bigint := 0;
  max_by_metal bigint := 0;
  max_by_energy bigint := 0;
  max_by_alloy bigint := 0;
  max_allowed bigint := 0;

  requested_quantity bigint := 0;
  actual_quantity bigint := 0;

  unit_duration integer := 0;
  total_duration bigint := 0;
  total_metal bigint := 0;
  total_energy bigint := 0;
  total_alloy bigint := 0;
  finish_time timestamptz;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  IF p_city_id IS NULL OR p_city_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_CITY',
      'message', 'Geçersiz koloni.'
    );
  END IF;

  IF p_requested_quantity IS NOT NULL
     AND (
       p_requested_quantity <= 0
       OR p_requested_quantity > 1000000
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_QUANTITY',
      'message', 'Geçersiz üretim adedi.'
    );
  END IF;

  SELECT *
    INTO c
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF c.id IS NULL OR c.id <> p_city_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  SELECT *
    INTO cfg
    FROM (
      VALUES
        ('piyade',   85,   0,  30, 1, 20),
        ('savunma', 130,   0,  60, 1, 24),
        ('saldiri', 170,   0, 110, 1, 28),
        ('okcu',    190,   0, 135, 1, 30),
        ('tank',    600, 275,   0, 3, 55),
        ('hava',    550, 325,   0, 2, 50)
    ) AS config(
      kind,
      metal,
      energy,
      alloy,
      pop,
      train
    )
   WHERE kind = p_type;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_UNIT',
      'message', 'Geçersiz birlik türü.'
    );
  END IF;

  housing := (
    SELECT
      100 +
      50 * GREATEST(
        0,
        COALESCE(
          (
            SELECT level
              FROM public.buildings
             WHERE city_id = c.id
               AND building_type = 'Konut'
             ORDER BY id
             LIMIT 1
          ),
          0
        )
      )
  );

  barracks := (
    SELECT GREATEST(
      0,
      COALESCE(
        (
          SELECT level
            FROM public.buildings
           WHERE city_id = c.id
             AND building_type = 'Kışla'
           ORDER BY id
           LIMIT 1
        ),
        0
      )
    )
  );

  IF barracks < 1 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'BARRACKS_REQUIRED',
      'message', 'Birlik üretmek için Kışla seviye 1 gerekli.',
      'required', jsonb_build_object(
        'building', 'Kışla',
        'level', 1
      ),
      'maxQuantity', 0
    );
  END IF;

  army := 50 + 50 * barracks;

  population := (
    SELECT COALESCE(SUM(amount), 0)::bigint
      FROM (
        SELECT
          quantity::bigint *
          CASE unit_type
            WHEN 'tank' THEN 3
            WHEN 'hava' THEN 2
            WHEN 'piyade' THEN 1
            WHEN 'savunma' THEN 1
            WHEN 'saldiri' THEN 1
            WHEN 'okcu' THEN 1
            ELSE COALESCE(NULLIF(population_cost, 0), 1)
          END AS amount
          FROM public.units
         WHERE city_id = c.id

        UNION ALL

        SELECT
          quantity::bigint *
          CASE unit_type
            WHEN 'tank' THEN 3
            WHEN 'hava' THEN 2
            ELSE 1
          END AS amount
          FROM public.unit_production_queue
         WHERE city_id = c.id
           AND player_id = p_player_id
           AND status = 'training'
      ) pop
  );

  active_military := GREATEST(
    0,
    COALESCE(
      public.nexora_active_military_population(p_player_id),
      0
    )
  );

  population := GREATEST(0, population) + active_military;

  available_capacity := GREATEST(
    0,
    LEAST(
      housing::bigint - population,
      army::bigint - population
    )
  );

  max_by_capacity :=
    FLOOR(
      available_capacity::numeric /
      cfg.pop::numeric
    )::bigint;

  max_by_metal :=
    FLOOR(
      GREATEST(0,COALESCE(c.metal,0))::numeric /
      cfg.metal::numeric
    )::bigint;

  max_by_energy :=
    CASE
      WHEN cfg.energy <= 0 THEN 1000000
      ELSE FLOOR(
        GREATEST(0,COALESCE(c.energy,0))::numeric /
        cfg.energy::numeric
      )::bigint
    END;

  max_by_alloy :=
    CASE
      WHEN cfg.alloy <= 0 THEN 1000000
      ELSE FLOOR(
        GREATEST(0,COALESCE(c.alloy,0))::numeric /
        cfg.alloy::numeric
      )::bigint
    END;

  max_allowed := GREATEST(
    0,
    LEAST(
      max_by_capacity,
      max_by_metal,
      max_by_energy,
      max_by_alloy,
      1000000::bigint
    )
  );

  IF max_allowed <= 0 THEN
    IF max_by_capacity <= 0 THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'CAPACITY_FULL',
        'message',
          CASE
            WHEN population >= housing
              THEN 'Konut kapasitesi yetersiz.'
            ELSE 'Kışla/ordu kapasitesi yetersiz.'
          END,
        'population', population,
        'population_capacity', housing,
        'army_capacity', army,
        'maxQuantity', 0
      );
    END IF;

    RETURN jsonb_build_object(
      'success', false,
      'code', 'INSUFFICIENT_RESOURCES',
      'message', 'Bu birlik için yeterli kaynak yok.',
      'maxQuantity', 0,
      'available', jsonb_build_object(
        'metal', GREATEST(0,COALESCE(c.metal,0)),
        'energy', GREATEST(0,COALESCE(c.energy,0)),
        'alloy', GREATEST(0,COALESCE(c.alloy,0))
      )
    );
  END IF;

  requested_quantity :=
    COALESCE(p_requested_quantity, max_allowed);

  actual_quantity :=
    LEAST(requested_quantity, max_allowed);

  IF actual_quantity <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOTHING_TO_TRAIN',
      'message', 'Üretilebilecek birlik bulunamadı.'
    );
  END IF;

  total_metal := actual_quantity * cfg.metal::bigint;
  total_energy := actual_quantity * cfg.energy::bigint;
  total_alloy := actual_quantity * cfg.alloy::bigint;

  spent := public.nexora_spend_city_resources_v2(
    p_player_id,
    total_metal,
    total_energy,
    total_alloy,
    0
  );

  IF NOT COALESCE((spent->>'success')::boolean,false) THEN
    RETURN spent;
  END IF;

  unit_duration :=
    GREATEST(
      10,
      ROUND(
        cfg.train *
        GREATEST(
          0.35,
          1 - GREATEST(1, barracks) * 0.04
        )
      )::integer
    );

  total_duration :=
    unit_duration::bigint * actual_quantity;

  finish_time :=
    clock_timestamp() +
    make_interval(secs => total_duration::double precision);

  INSERT INTO public.unit_production_queue(
    player_id,
    city_id,
    unit_type,
    quantity,
    finish_at
  )
  VALUES(
    p_player_id,
    c.id,
    p_type,
    actual_quantity::integer,
    finish_time
  )
  RETURNING * INTO q;

  RETURN spent ||
    jsonb_build_object(
      'success', true,
      'production', to_jsonb(q),
      'requestedQuantity', p_requested_quantity,
      'acceptedQuantity', actual_quantity,
      'maxQuantity', max_allowed,
      'unitDurationSeconds', unit_duration,
      'totalDurationSeconds', total_duration,
      'finishAt', finish_time,
      'population', population,
      'populationAfter',
        population + actual_quantity * cfg.pop::bigint,
      'population_capacity', housing,
      'army_capacity', army,
      'cost', jsonb_build_object(
        'metal', total_metal,
        'energy', total_energy,
        'alloy', total_alloy,
        'crystal', 0
      )
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_upgrade_unit_atomic(
  p_player_id bigint,
  p_city_id bigint,
  p_unit_id bigint,
  p_level integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  c public.cities%ROWTYPE;
  u public.units%ROWTYPE;
  s public.unit_levels%ROWTYPE;
  spent jsonb;
  v_metal bigint := 0;
  v_energy bigint := 0;
  v_alloy bigint := 0;
  v_crystal bigint := 0;
BEGIN
  SELECT *
    INTO c
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF c.id IS NULL OR c.id <> p_city_id THEN
    RAISE EXCEPTION 'Koloni bulunamadı.';
  END IF;

  SELECT *
    INTO u
    FROM public.units
   WHERE id = p_unit_id
     AND city_id = c.id
   FOR UPDATE;

  IF u.id IS NULL THEN
    RAISE EXCEPTION 'Birlik bulunamadı.';
  END IF;

  IF p_level IS NULL
     OR p_level < 1
     OR p_level >= 15
     OR GREATEST(1,COALESCE(u.level,1)) <> p_level THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Birlik seviyesi değişti; tekrar yükle.'
    );
  END IF;

  SELECT *
    INTO s
    FROM public.unit_levels
   WHERE unit_type = u.unit_type
     AND level = p_level + 1
   LIMIT 1;

  IF s.id IS NULL THEN
    RAISE EXCEPTION 'Bir sonraki seviye verisi bulunamadı.';
  END IF;

  IF u.unit_type IN ('tank','hava') THEN
    v_metal := p_level::bigint * 500;
    v_energy := p_level::bigint * 200;
    v_alloy := 0;
    v_crystal := p_level::bigint * 75;
  ELSE
    v_metal := p_level::bigint * 400;
    v_energy := 0;
    v_alloy := p_level::bigint * 150;
    v_crystal := p_level::bigint * 50;
  END IF;

  spent := public.nexora_spend_city_resources_v2(
    p_player_id,
    v_metal,
    v_energy,
    v_alloy,
    v_crystal
  );

  IF NOT COALESCE((spent->>'success')::boolean,false) THEN
    RETURN spent;
  END IF;

  UPDATE public.units
     SET level = p_level + 1,
         attack = s.attack,
         defense = s.defense,
         hp = s.hp,
         speed = s.speed
   WHERE id = u.id
   RETURNING * INTO u;

  RETURN spent || jsonb_build_object(
    'unit', to_jsonb(u)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_start_building_upgrade_slot(
  p_player_id bigint,
  p_city_id bigint,
  p_type text,
  p_slot integer,
  p_level integer,
  p_cost jsonb,
  p_duration integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  c public.cities%ROWTYPE;
  b public.buildings%ROWTYPE;
  active_building public.buildings%ROWTYPE;
  spent jsonb;
  ready timestamptz;
  center_level integer := 0;
  v_now timestamptz := clock_timestamp();
  v_type text;
  v_alloy bigint := 0;
BEGIN
  v_type :=
    CASE
      WHEN p_type = 'Alaşım Rafinerisi' THEN 'Su Arıtma'
      ELSE p_type
    END;

  IF p_slot IS NULL OR p_slot NOT IN (1,2) THEN
    RAISE EXCEPTION 'Geçersiz bina yuvası.';
  END IF;

  IF p_slot = 2
     AND v_type NOT IN (
       'Metal Madeni',
       'Enerji Santrali',
       'Su Arıtma',
       'Kristal Madeni',
       'Depo'
     ) THEN
    RAISE EXCEPTION 'Bu bina türünün ikinci kopyası olamaz.';
  END IF;

  SELECT *
    INTO c
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF c.id IS NULL OR c.id <> p_city_id THEN
    RAISE EXCEPTION 'Koloni bulunamadı.';
  END IF;

  UPDATE public.buildings
     SET level = level + 1,
         is_under_construction = false,
         upgrade_ready_at = NULL
   WHERE city_id = c.id
     AND is_under_construction = true
     AND upgrade_ready_at IS NOT NULL
     AND upgrade_ready_at <= v_now;

  SELECT *
    INTO active_building
    FROM public.buildings
   WHERE city_id = c.id
     AND is_under_construction = true
   ORDER BY upgrade_ready_at NULLS LAST, id
   LIMIT 1;

  IF active_building.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CONSTRUCTION_BUSY',
      'message',
        CASE
          WHEN active_building.building_type = 'Su Arıtma'
            THEN 'Alaşım Rafinerisi'
          ELSE active_building.building_type
        END ||
        CASE
          WHEN COALESCE(active_building.slot, 1) = 2 THEN ' II'
          ELSE ''
        END ||
        ' inşaatı sürüyor. Önce onu tamamla.',
      'finishAt', active_building.upgrade_ready_at,
      'activeBuilding', to_jsonb(active_building)
    );
  END IF;

  SELECT COALESCE(MAX(level),0)::integer
    INTO center_level
    FROM public.buildings
   WHERE city_id = c.id
     AND building_type = 'Merkez Bina'
     AND slot = 1;

  IF p_slot = 2 THEN
    IF v_type = 'Depo' AND center_level < 7 THEN
      RETURN jsonb_build_object(
        'success', false,
        'message', 'Depo II için Merkez Bina seviye 7 gerekli.',
        'required', jsonb_build_object(
          'building', 'Merkez Bina',
          'level', 7
        )
      );
    END IF;

    IF v_type IN (
         'Metal Madeni',
         'Enerji Santrali',
         'Su Arıtma',
         'Kristal Madeni'
       )
       AND center_level < 5 THEN
      RETURN jsonb_build_object(
        'success', false,
        'message',
          CASE
            WHEN v_type = 'Su Arıtma'
              THEN 'Alaşım Rafinerisi'
            ELSE v_type
          END ||
          ' II için Merkez Bina seviye 5 gerekli.',
        'required', jsonb_build_object(
          'building', 'Merkez Bina',
          'level', 5
        )
      );
    END IF;
  END IF;

  SELECT *
    INTO b
    FROM public.buildings
   WHERE city_id = c.id
     AND building_type = v_type
     AND slot = p_slot
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF COALESCE(b.is_under_construction,false)
     OR COALESCE(b.level,0) IS DISTINCT FROM p_level THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Bina durumu değişti; tekrar yükle.'
    );
  END IF;

  IF p_level IS NULL
     OR p_level < 0
     OR p_duration IS NULL
     OR p_duration <= 0 THEN
    RAISE EXCEPTION 'Geçersiz inşaat.';
  END IF;

  v_alloy :=
    COALESCE(
      NULLIF(p_cost->>'alloy','')::bigint,
      NULLIF(p_cost->>'water','')::bigint,
      0
    );

  spent := public.nexora_spend_city_resources_v2(
    p_player_id,
    COALESCE(NULLIF(p_cost->>'metal','')::bigint,0),
    COALESCE(NULLIF(p_cost->>'energy','')::bigint,0),
    v_alloy,
    COALESCE(NULLIF(p_cost->>'crystal','')::bigint,0)
  );

  IF NOT COALESCE((spent->>'success')::boolean,false) THEN
    RETURN spent;
  END IF;

  ready := clock_timestamp() + make_interval(secs => p_duration);

  IF b.id IS NULL THEN
    INSERT INTO public.buildings(
      city_id,
      building_type,
      slot,
      level,
      is_under_construction,
      upgrade_ready_at
    )
    VALUES(
      c.id,
      v_type,
      p_slot,
      0,
      true,
      ready
    )
    RETURNING * INTO b;
  ELSE
    UPDATE public.buildings
       SET is_under_construction = true,
           upgrade_ready_at = ready
     WHERE id = b.id
     RETURNING * INTO b;
  END IF;

  RETURN spent || jsonb_build_object(
    'building', to_jsonb(b),
    'finishAt', ready
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_start_research_upgrade(
  p_player_id bigint,
  p_city_id bigint,
  p_column text,
  p_level integer,
  p_cost jsonb,
  p_duration integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  c public.cities%ROWTYPE;
  r public.research%ROWTYPE;
  spent jsonb;
  ready timestamptz;
  v_alloy bigint := 0;
BEGIN
  SELECT *
    INTO c
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF c.id IS NULL OR c.id <> p_city_id THEN
    RAISE EXCEPTION 'Koloni bulunamadı.';
  END IF;

  IF p_column IS NULL OR p_column NOT IN (
    'production_level',
    'combat_level',
    'defense_level',
    'crystal_level',
    'general_power_level',
    'unit_attack_level',
    'unit_defense_level',
    'unit_hp_level',
    'travel_speed_level'
  ) THEN
    RAISE EXCEPTION 'Geçersiz araştırma.';
  END IF;

  SELECT *
    INTO r
    FROM public.research
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF r.upgrade_ready_at IS NOT NULL
     OR COALESCE((to_jsonb(r)->>p_column)::integer,0)
        IS DISTINCT FROM p_level THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Araştırma durumu değişti; tekrar yükle.'
    );
  END IF;

  IF p_level IS NULL
     OR p_level < 0
     OR p_level >= 15
     OR p_duration IS NULL
     OR p_duration <= 0 THEN
    RAISE EXCEPTION 'Geçersiz araştırma.';
  END IF;

  v_alloy :=
    COALESCE(
      NULLIF(p_cost->>'alloy','')::bigint,
      NULLIF(p_cost->>'water','')::bigint,
      0
    );

  spent := public.nexora_spend_city_resources_v2(
    p_player_id,
    COALESCE(NULLIF(p_cost->>'metal','')::bigint,0),
    COALESCE(NULLIF(p_cost->>'energy','')::bigint,0),
    v_alloy,
    COALESCE(NULLIF(p_cost->>'crystal','')::bigint,0)
  );

  IF NOT COALESCE((spent->>'success')::boolean,false) THEN
    RETURN spent;
  END IF;

  ready := clock_timestamp() + make_interval(secs => p_duration);

  IF r.id IS NULL THEN
    INSERT INTO public.research(
      player_id,
      production_level,
      combat_level,
      defense_level,
      crystal_level,
      general_power_level,
      unit_attack_level,
      unit_defense_level,
      unit_hp_level,
      travel_speed_level,
      upgrade_ready_at,
      pending_column
    )
    VALUES(
      p_player_id,
      0,0,0,0,0,0,0,0,0,
      ready,
      p_column
    )
    RETURNING * INTO r;
  ELSE
    UPDATE public.research
       SET upgrade_ready_at = ready,
           pending_column = p_column
     WHERE id = r.id
     RETURNING * INTO r;
  END IF;

  RETURN spent || jsonb_build_object(
    'research', to_jsonb(r),
    'finishAt', ready
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.nexora_spend_city_resources_v2(
  bigint,bigint,bigint,bigint,bigint
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_spend_city_resources_v2(
  bigint,bigint,bigint,bigint,bigint
) TO service_role;

COMMIT;
