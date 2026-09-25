CREATE OR REPLACE FUNCTION public.nexora_start_building_upgrade(
  p_player_id bigint,
  p_city_id bigint,
  p_type text,
  p_level integer,
  p_cost jsonb,
  p_duration integer
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'success', false,
    'code', 'LEGACY_RPC_DISABLED',
    'message', 'Eski bina yükseltme yolu devre dışı. Güncel bina yükseltme akışını kullan.'
  );
$function$;

REVOKE ALL ON FUNCTION public.nexora_start_building_upgrade(
  bigint,
  bigint,
  text,
  integer,
  jsonb,
  integer
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_start_building_upgrade(
  bigint,
  bigint,
  text,
  integer,
  jsonb,
  integer
) TO service_role;

CREATE OR REPLACE FUNCTION public.nexora_start_unit_training(
  p_player_id bigint,
  p_city_id bigint,
  p_type text
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'success', false,
    'code', 'LEGACY_RPC_DISABLED',
    'message', 'Eski birlik üretim yolu devre dışı. Güncel toplu üretim akışını kullan.'
  );
$function$;

REVOKE ALL ON FUNCTION public.nexora_start_unit_training(
  bigint,
  bigint,
  text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_start_unit_training(
  bigint,
  bigint,
  text
) TO service_role;