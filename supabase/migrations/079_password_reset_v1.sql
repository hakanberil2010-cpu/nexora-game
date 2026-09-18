-- TERYNDIS 079 Password Reset V1
-- Server-only short-lived password reset codes for the existing custom auth flow.

CREATE TABLE IF NOT EXISTS public.password_reset_codes (
  player_id bigint PRIMARY KEY
    REFERENCES public.players(id) ON DELETE CASCADE,
  code_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  last_sent_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT password_reset_codes_attempts_check
    CHECK (attempts >= 0 AND attempts <= 20),
  CONSTRAINT password_reset_codes_hash_check
    CHECK (length(code_hash) = 64)
);

ALTER TABLE public.password_reset_codes
  ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.password_reset_codes
  FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.password_reset_codes
  TO service_role;

COMMENT ON TABLE public.password_reset_codes IS
  'Server-only short-lived password-reset code state for the TERYNDIS custom auth flow.';
