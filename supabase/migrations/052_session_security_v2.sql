-- NEXORA - Session Security V2. Apply after 051_rankings_performance_v2.sql.
-- Adds a per-player session version used to invalidate previously issued JWTs
-- after a password change. Existing sessions remain version 1 until rotated.
-- No existing rows are deleted and no indexes or RPCs are added.

BEGIN;

ALTER TABLE public.players
  ADD COLUMN IF NOT EXISTS session_version bigint NOT NULL DEFAULT 1;

COMMIT;
