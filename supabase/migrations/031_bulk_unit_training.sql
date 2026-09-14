-- NEXORA Phase 15
-- Atomic bulk unit training.
-- Supports requested quantity and MAX mode without repeated API calls.
-- Apply AFTER 030_phase14_battle_state_finalization.sql.

BEGIN;

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
AS $$
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
  max_allowed bigint := 0;

  requested_quantity bigint;
  actual_quantity bigint := 0;

  unit_duration integer := 0;
  total_duration bigint := 0;

  total_metal bigint := 0;
  total_energy bigint := 0;

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


  -- City row is the serialization point shared with
  -- resource spending, military missions and population snapshots.
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
      ('piyade',  100,  20, 1, 20),
      ('savunma', 150,  40, 1, 24),
      ('saldiri',  200,  75, 1, 28),
      ('okcu',     220,  90, 1, 30),
      ('tank',     700, 220, 3, 55),
      ('hava',     650, 260, 2, 50)
  ) AS config(
    kind,
    metal,
    energy,
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
  INTO housing;


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
  INTO barracks;


  army := 50 + 50 * barracks;


  -- Current army + current training queue.
  SELECT COALESCE(SUM(amount), 0)
  INTO population
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

  ) pop;


  -- Armies currently away on military missions still reserve capacity.
  active_military := GREATEST(
    0,
    COALESCE(
      public.nexora_active_military_population(
        p_player_id
      ),
      0
    )
  );

  population :=
    GREATEST(0, population)
    + active_military;


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
      GREATEST(
        0,
        COALESCE(c.metal, 0)
      )::numeric /
      cfg.metal::numeric
    )::bigint;


  max_by_energy :=
    FLOOR(
      GREATEST(
        0,
        COALESCE(c.energy, 0)
      )::numeric /
      cfg.energy::numeric
    )::bigint;


  max_allowed := GREATEST(
    0,
    LEAST(
      max_by_capacity,
      max_by_metal,
      max_by_energy,
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
        'metal', GREATEST(0, COALESCE(c.metal, 0)),
        'energy', GREATEST(0, COALESCE(c.energy, 0))
      )
    );

  END IF;


  -- NULL means MAX mode.
  requested_quantity :=
    COALESCE(
      p_requested_quantity,
      max_allowed
    );


  -- If player asks for more than affordable/capacity allows,
  -- admit the maximum safe amount instead of failing.
  actual_quantity :=
    LEAST(
      requested_quantity,
      max_allowed
    );


  IF actual_quantity <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOTHING_TO_TRAIN',
      'message', 'Üretilebilecek birlik bulunamadı.'
    );
  END IF;


  total_metal :=
    actual_quantity *
    cfg.metal::bigint;

  total_energy :=
    actual_quantity *
    cfg.energy::bigint;


  -- Atomic resource deduction.
  spent :=
    public.nexora_spend_city_resources(
      p_player_id,
      total_metal,
      total_energy,
      0,
      0
    );


  IF NOT COALESCE(
    (spent->>'success')::boolean,
    false
  ) THEN
    RETURN spent;
  END IF;


  -- Preserve existing Barracks training-speed formula.
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
    unit_duration::bigint *
    actual_quantity;


  finish_time :=
    clock_timestamp() +
    make_interval(
      secs => total_duration::double precision
    );


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
  RETURNING *
  INTO q;


  RETURN spent ||
    jsonb_build_object(
      'success', true,
      'production', to_jsonb(q),

      'requestedQuantity',
        p_requested_quantity,

      'acceptedQuantity',
        actual_quantity,

      'maxQuantity',
        max_allowed,

      'unitDurationSeconds',
        unit_duration,

      'totalDurationSeconds',
        total_duration,

      'finishAt',
        finish_time,

      'population',
        population,

      'populationAfter',
        population +
        actual_quantity * cfg.pop::bigint,

      'population_capacity',
        housing,

      'army_capacity',
        army,

      'cost',
        jsonb_build_object(
          'metal', total_metal,
          'energy', total_energy,
          'water', 0,
          'crystal', 0
        )
    );

END;
$$;


REVOKE ALL ON FUNCTION public.nexora_start_unit_training_bulk(
  bigint,
  bigint,
  text,
  bigint
)
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE ON FUNCTION public.nexora_start_unit_training_bulk(
  bigint,
  bigint,
  text,
  bigint
)
TO service_role;


COMMIT;
