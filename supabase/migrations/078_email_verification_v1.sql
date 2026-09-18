-- NEXORA 078 Email Verification V1
-- Adds email verification state without replacing the existing custom auth flow.
-- Existing players are trusted as verified; the new API will explicitly create new players unverified.

ALTER TABLE public.players
  ADD COLUMN IF NOT EXISTS email_verified_at timestamptz;

UPDATE public.players
   SET email_verified_at = COALESCE(created_at, now())
 WHERE email_verified_at IS NULL;

ALTER TABLE public.players
  ALTER COLUMN email_verified_at SET DEFAULT now();

CREATE TABLE IF NOT EXISTS public.email_verification_codes (
  player_id bigint PRIMARY KEY
    REFERENCES public.players(id) ON DELETE CASCADE,
  code_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  last_sent_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT email_verification_codes_attempts_check
    CHECK (attempts >= 0 AND attempts <= 20),
  CONSTRAINT email_verification_codes_hash_check
    CHECK (length(code_hash) = 64)
);

ALTER TABLE public.email_verification_codes
  ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.email_verification_codes
  FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.email_verification_codes
  TO service_role;

COMMENT ON TABLE public.email_verification_codes IS
  'Server-only short-lived verification-code state for the NEXORA custom auth flow.';
