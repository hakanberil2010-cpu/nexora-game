-- TERYNDIS 093 lock down World V3 sequence privileges
BEGIN;

REVOKE ALL ON SEQUENCE public.world_discovery_memory_id_seq
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.world_intel_scans_id_seq
  FROM PUBLIC, anon, authenticated;

GRANT USAGE, SELECT ON SEQUENCE public.world_discovery_memory_id_seq TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.world_intel_scans_id_seq TO service_role;

-- Migrations create public sequences as postgres. Prevent future server-only
-- sequences from inheriting direct anon/authenticated access.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated;

COMMIT;
