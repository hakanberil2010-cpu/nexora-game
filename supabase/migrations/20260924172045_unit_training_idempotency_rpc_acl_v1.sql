REVOKE ALL ON FUNCTION public.nexora_start_unit_training_bulk(
  bigint,
  bigint,
  text,
  bigint,
  text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_start_unit_training_bulk(
  bigint,
  bigint,
  text,
  bigint,
  text
) TO service_role;