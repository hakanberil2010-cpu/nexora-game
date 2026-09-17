-- NEXORA - Economy Rebalance V1 / Alloy Compatibility
-- Migration 061
--
-- Stage 1 of the Water -> Alloy transition.
-- This migration is intentionally backward-compatible:
-- - adds alloy resource columns without removing legacy water columns yet
-- - copies all current balances/capacities 1:1
-- - keeps old and new columns synchronized during the rollout
-- - allows trade schema to accept alloy while still accepting legacy water
--
-- Final cleanup of legacy water fields happens only after backend/frontend
-- have been switched and verified in production.

BEGIN;

ALTER TABLE public.cities
  ADD COLUMN IF NOT EXISTS alloy integer;

ALTER TABLE public.cities
  ADD COLUMN IF NOT EXISTS alloy_capacity integer;

UPDATE public.cities
   SET alloy = COALESCE(alloy, water, 500),
       alloy_capacity = COALESCE(alloy_capacity, water_capacity, 5000);

ALTER TABLE public.cities
  ALTER COLUMN alloy SET DEFAULT 500,
  ALTER COLUMN alloy SET NOT NULL,
  ALTER COLUMN alloy_capacity SET DEFAULT 5000,
  ALTER COLUMN alloy_capacity SET NOT NULL;

ALTER TABLE public.world_sites
  ADD COLUMN IF NOT EXISTS reward_alloy integer;

UPDATE public.world_sites
   SET reward_alloy = COALESCE(reward_alloy, reward_water, 0);

ALTER TABLE public.world_sites
  ALTER COLUMN reward_alloy SET DEFAULT 0,
  ALTER COLUMN reward_alloy SET NOT NULL;

CREATE OR REPLACE FUNCTION public.nexora_sync_city_alloy_compat()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.alloy := COALESCE(NEW.alloy, NEW.water, 500);
    NEW.water := COALESCE(NEW.water, NEW.alloy, 500);

    NEW.alloy_capacity :=
      COALESCE(NEW.alloy_capacity, NEW.water_capacity, 5000);

    NEW.water_capacity :=
      COALESCE(NEW.water_capacity, NEW.alloy_capacity, 5000);

    RETURN NEW;
  END IF;

  IF NEW.alloy IS DISTINCT FROM OLD.alloy
     AND NEW.water IS NOT DISTINCT FROM OLD.water THEN
    NEW.water := NEW.alloy;
  ELSIF NEW.water IS DISTINCT FROM OLD.water
        AND NEW.alloy IS NOT DISTINCT FROM OLD.alloy THEN
    NEW.alloy := NEW.water;
  ELSIF NEW.alloy IS DISTINCT FROM OLD.alloy
        AND NEW.water IS DISTINCT FROM OLD.water
        AND NEW.alloy IS DISTINCT FROM NEW.water THEN
    -- During dual-write conflicts the new resource is canonical.
    NEW.water := NEW.alloy;
  END IF;

  IF NEW.alloy_capacity IS DISTINCT FROM OLD.alloy_capacity
     AND NEW.water_capacity IS NOT DISTINCT FROM OLD.water_capacity THEN
    NEW.water_capacity := NEW.alloy_capacity;
  ELSIF NEW.water_capacity IS DISTINCT FROM OLD.water_capacity
        AND NEW.alloy_capacity IS NOT DISTINCT FROM OLD.alloy_capacity THEN
    NEW.alloy_capacity := NEW.water_capacity;
  ELSIF NEW.alloy_capacity IS DISTINCT FROM OLD.alloy_capacity
        AND NEW.water_capacity IS DISTINCT FROM OLD.water_capacity
        AND NEW.alloy_capacity IS DISTINCT FROM NEW.water_capacity THEN
    NEW.water_capacity := NEW.alloy_capacity;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_nexora_sync_city_alloy_compat
  ON public.cities;

CREATE TRIGGER trg_nexora_sync_city_alloy_compat
BEFORE INSERT OR UPDATE OF
  water,
  water_capacity,
  alloy,
  alloy_capacity
ON public.cities
FOR EACH ROW
EXECUTE FUNCTION public.nexora_sync_city_alloy_compat();

CREATE OR REPLACE FUNCTION public.nexora_sync_world_site_alloy_compat()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.reward_alloy := COALESCE(NEW.reward_alloy, NEW.reward_water, 0);
    NEW.reward_water := COALESCE(NEW.reward_water, NEW.reward_alloy, 0);
    RETURN NEW;
  END IF;

  IF NEW.reward_alloy IS DISTINCT FROM OLD.reward_alloy
     AND NEW.reward_water IS NOT DISTINCT FROM OLD.reward_water THEN
    NEW.reward_water := NEW.reward_alloy;
  ELSIF NEW.reward_water IS DISTINCT FROM OLD.reward_water
        AND NEW.reward_alloy IS NOT DISTINCT FROM OLD.reward_alloy THEN
    NEW.reward_alloy := NEW.reward_water;
  ELSIF NEW.reward_alloy IS DISTINCT FROM OLD.reward_alloy
        AND NEW.reward_water IS DISTINCT FROM OLD.reward_water
        AND NEW.reward_alloy IS DISTINCT FROM NEW.reward_water THEN
    NEW.reward_water := NEW.reward_alloy;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_nexora_sync_world_site_alloy_compat
  ON public.world_sites;

CREATE TRIGGER trg_nexora_sync_world_site_alloy_compat
BEFORE INSERT OR UPDATE OF
  reward_water,
  reward_alloy
ON public.world_sites
FOR EACH ROW
EXECUTE FUNCTION public.nexora_sync_world_site_alloy_compat();

ALTER TABLE public.trade_offers
  DROP CONSTRAINT IF EXISTS trade_offers_give_resource_check;

ALTER TABLE public.trade_offers
  ADD CONSTRAINT trade_offers_give_resource_check
  CHECK (
    give_resource = ANY (
      ARRAY[
        'metal'::text,
        'energy'::text,
        'water'::text,
        'alloy'::text,
        'crystal'::text
      ]
    )
  );

ALTER TABLE public.trade_offers
  DROP CONSTRAINT IF EXISTS trade_offers_want_resource_check;

ALTER TABLE public.trade_offers
  ADD CONSTRAINT trade_offers_want_resource_check
  CHECK (
    want_resource = ANY (
      ARRAY[
        'metal'::text,
        'energy'::text,
        'water'::text,
        'alloy'::text,
        'crystal'::text
      ]
    )
  );

ALTER TABLE public.trade_transactions
  DROP CONSTRAINT IF EXISTS trade_transactions_give_resource_check;

ALTER TABLE public.trade_transactions
  ADD CONSTRAINT trade_transactions_give_resource_check
  CHECK (
    give_resource = ANY (
      ARRAY[
        'metal'::text,
        'energy'::text,
        'water'::text,
        'alloy'::text,
        'crystal'::text
      ]
    )
  );

ALTER TABLE public.trade_transactions
  DROP CONSTRAINT IF EXISTS trade_transactions_want_resource_check;

ALTER TABLE public.trade_transactions
  ADD CONSTRAINT trade_transactions_want_resource_check
  CHECK (
    want_resource = ANY (
      ARRAY[
        'metal'::text,
        'energy'::text,
        'water'::text,
        'alloy'::text,
        'crystal'::text
      ]
    )
  );

REVOKE ALL ON FUNCTION public.nexora_sync_city_alloy_compat()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.nexora_sync_world_site_alloy_compat()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_sync_city_alloy_compat()
  TO service_role;

GRANT EXECUTE ON FUNCTION public.nexora_sync_world_site_alloy_compat()
  TO service_role;

COMMIT;
