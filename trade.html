-- NEXORA - Economy & Balance Audit / Trade Resource Weights
-- Migration 071
--
-- Align fair-value checks with canonical base production scarcity:
-- - Metal:   12/min -> baseline weight 1.00
-- - Energy:   6/min -> weight 2.00
-- - Alloy:   10/min -> weight 1.20
-- - Crystal:  5/min -> keep strategic premium weight 4.00
--
-- This changes only fair-value validation for new/accepted offers.
-- No existing trade rows or historical transactions are rewritten.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_trade_resource_weight(
  p_resource text
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE p_resource
    WHEN 'metal' THEN 1::numeric
    WHEN 'energy' THEN 2::numeric
    WHEN 'alloy' THEN 1.2::numeric
    WHEN 'crystal' THEN 4::numeric
    ELSE 0::numeric
  END;
$function$;

COMMIT;
