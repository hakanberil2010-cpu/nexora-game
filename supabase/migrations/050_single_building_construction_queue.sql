-- NEXORA - Single Building Construction Queue. Apply after 049_city_snapshot_v2.sql.
-- Enforces one active building construction per city under the existing city-row lock.
-- Existing active constructions are not cancelled, reordered or modified by this migration.
BEGIN;

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
BEGIN
  IF p_slot IS NULL OR p_slot NOT IN (1,2) THEN
    RAISE EXCEPTION 'Geçersiz bina yuvası.';
  END IF;

  IF p_slot = 2
     AND p_type NOT IN (
       'Metal Madeni',
       'Enerji Santrali',
       'Su Arıtma',
       'Kristal Madeni',
       'Depo'
     ) THEN
    RAISE EXCEPTION 'Bu bina türünün ikinci kopyası olamaz.';
  END IF;

  -- City row is the serialization point. Concurrent construction starts for the
  -- same city cannot pass this lock at the same time.
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

  -- Finish any construction whose server-authoritative ready time has passed.
  -- This mirrors the city snapshot finalizer and prevents a completed job from
  -- blocking the next valid construction start.
  UPDATE public.buildings
     SET level = level + 1,
         is_under_construction = false,
         upgrade_ready_at = NULL
   WHERE city_id = c.id
     AND is_under_construction = true
     AND upgrade_ready_at IS NOT NULL
     AND upgrade_ready_at <= v_now;

  -- Exactly one city-wide construction slot is allowed.
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
        active_building.building_type ||
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
    IF p_type = 'Depo' AND center_level < 7 THEN
      RETURN jsonb_build_object(
        'success', false,
        'message', 'Depo II için Merkez Bina seviye 7 gerekli.',
        'required', jsonb_build_object(
          'building', 'Merkez Bina',
          'level', 7
        )
      );
    END IF;

    IF p_type IN (
         'Metal Madeni',
         'Enerji Santrali',
         'Su Arıtma',
         'Kristal Madeni'
       )
       AND center_level < 5 THEN
      RETURN jsonb_build_object(
        'success', false,
        'message', p_type || ' II için Merkez Bina seviye 5 gerekli.',
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
     AND building_type = p_type
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

  spent := public.nexora_spend_city_resources(
    p_player_id,
    (p_cost->>'metal')::bigint,
    (p_cost->>'energy')::bigint,
    (p_cost->>'water')::bigint,
    (p_cost->>'crystal')::bigint
  );

  IF NOT (spent->>'success')::boolean THEN
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
      p_type,
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

REVOKE ALL ON FUNCTION public.nexora_start_building_upgrade_slot(
  bigint,bigint,text,integer,integer,jsonb,integer
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_start_building_upgrade_slot(
  bigint,bigint,text,integer,integer,jsonb,integer
) TO service_role;

COMMIT;
