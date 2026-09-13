-- NEXORA Phase 10 audit fix 7
-- Atomic non-trade city resource spending so building/research/army costs
-- cannot overwrite concurrent trade escrow or delivery balance changes.
-- Apply after 016_phase10_accept_fair_value_guard.sql.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_spend_city_resources(
  p_player_id bigint,
  p_metal bigint,
  p_energy bigint,
  p_water bigint,
  p_crystal bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_city public.cities%ROWTYPE;
  v_metal bigint := COALESCE(p_metal, 0);
  v_energy bigint := COALESCE(p_energy, 0);
  v_water bigint := COALESCE(p_water, 0);
  v_crystal bigint := COALESCE(p_crystal, 0);
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  IF v_metal < 0 OR v_energy < 0 OR v_water < 0 OR v_crystal < 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_COST',
      'message', 'Kaynak maliyeti negatif olamaz.'
    );
  END IF;

  -- This city-row lock is shared with Trade V2 escrow/delivery operations.
  -- Read, sufficiency check and deduction all occur while the same lock is held.
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
     OR COALESCE(v_city.water, 0) < v_water
     OR COALESCE(v_city.crystal, 0) < v_crystal THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INSUFFICIENT_RESOURCES',
      'message', 'Yeterli kaynak yok.',
      'available', jsonb_build_object(
        'metal', COALESCE(v_city.metal, 0),
        'energy', COALESCE(v_city.energy, 0),
        'water', COALESCE(v_city.water, 0),
        'crystal', COALESCE(v_city.crystal, 0)
      ),
      'cost', jsonb_build_object(
        'metal', v_metal,
        'energy', v_energy,
        'water', v_water,
        'crystal', v_crystal
      )
    );
  END IF;

  UPDATE public.cities
     SET metal = COALESCE(metal, 0) - v_metal,
         energy = COALESCE(energy, 0) - v_energy,
         water = COALESCE(water, 0) - v_water,
         crystal = COALESCE(crystal, 0) - v_crystal
   WHERE id = v_city.id
   RETURNING * INTO v_city;

  RETURN jsonb_build_object(
    'success', true,
    'city', to_jsonb(v_city),
    'cost', jsonb_build_object(
      'metal', v_metal,
      'energy', v_energy,
      'water', v_water,
      'crystal', v_crystal
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_spend_city_resources(
  bigint,bigint,bigint,bigint,bigint
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_spend_city_resources(
  bigint,bigint,bigint,bigint,bigint
) TO service_role;

COMMIT;
