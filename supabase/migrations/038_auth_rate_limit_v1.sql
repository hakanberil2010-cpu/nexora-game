-- NEXORA - Auth Rate Limit V1
-- Additive / production-safe migration.
-- Server-side storage for login/register throttling in a serverless environment.
-- The backend must send SHA-256 hashes only; raw IP addresses and e-mail values
-- are intentionally not stored in this table.

BEGIN;

CREATE TABLE IF NOT EXISTS public.auth_rate_limit_buckets (
  scope text NOT NULL,
  key_hash text NOT NULL,
  window_started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  hit_count integer NOT NULL DEFAULT 1,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (scope, key_hash),
  CONSTRAINT auth_rate_limit_scope_check
    CHECK (scope IN ('login_identity', 'login_ip', 'register_ip')),
  CONSTRAINT auth_rate_limit_key_hash_check
    CHECK (key_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT auth_rate_limit_hit_count_check
    CHECK (hit_count >= 1)
);

CREATE INDEX IF NOT EXISTS idx_auth_rate_limit_buckets_updated_at
  ON public.auth_rate_limit_buckets(updated_at);

ALTER TABLE public.auth_rate_limit_buckets ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.auth_rate_limit_buckets
  FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.auth_rate_limit_buckets
  TO service_role;

CREATE OR REPLACE FUNCTION public.nexora_auth_rate_limit_consume(
  p_scope text,
  p_key_hash text,
  p_limit integer,
  p_window_seconds integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_scope text := lower(trim(COALESCE(p_scope, '')));
  v_key_hash text := lower(trim(COALESCE(p_key_hash, '')));
  v_limit integer := COALESCE(p_limit, 0);
  v_window_seconds integer := COALESCE(p_window_seconds, 0);
  v_now timestamptz := clock_timestamp();
  v_bucket public.auth_rate_limit_buckets%ROWTYPE;
  v_reset_at timestamptz;
  v_allowed boolean;
  v_remaining integer;
  v_retry_after integer := 0;
BEGIN
  IF v_scope NOT IN ('login_identity', 'login_ip', 'register_ip') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_SCOPE',
      'message', 'Geçersiz rate limit kapsamı.'
    );
  END IF;

  IF v_key_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_KEY',
      'message', 'Geçersiz rate limit anahtarı.'
    );
  END IF;

  IF v_limit < 1 OR v_limit > 1000 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_LIMIT',
      'message', 'Geçersiz rate limit değeri.'
    );
  END IF;

  IF v_window_seconds < 1 OR v_window_seconds > 86400 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_WINDOW',
      'message', 'Geçersiz rate limit zaman aralığı.'
    );
  END IF;

  INSERT INTO public.auth_rate_limit_buckets AS bucket (
    scope,
    key_hash,
    window_started_at,
    hit_count,
    updated_at
  )
  VALUES (
    v_scope,
    v_key_hash,
    v_now,
    1,
    v_now
  )
  ON CONFLICT (scope, key_hash)
  DO UPDATE
  SET
    window_started_at = CASE
      WHEN bucket.window_started_at
           + make_interval(secs => v_window_seconds) <= v_now
        THEN v_now
      ELSE bucket.window_started_at
    END,
    hit_count = CASE
      WHEN bucket.window_started_at
           + make_interval(secs => v_window_seconds) <= v_now
        THEN 1
      ELSE bucket.hit_count + 1
    END,
    updated_at = v_now
  RETURNING * INTO v_bucket;

  v_reset_at :=
    v_bucket.window_started_at
    + make_interval(secs => v_window_seconds);

  v_allowed := v_bucket.hit_count <= v_limit;
  v_remaining := GREATEST(v_limit - v_bucket.hit_count, 0);

  IF NOT v_allowed THEN
    v_retry_after := GREATEST(
      1,
      CEIL(EXTRACT(EPOCH FROM (v_reset_at - v_now)))::integer
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'allowed', v_allowed,
    'code', CASE WHEN v_allowed THEN 'OK' ELSE 'RATE_LIMITED' END,
    'count', v_bucket.hit_count,
    'limit', v_limit,
    'remaining', v_remaining,
    'retryAfterSeconds', v_retry_after,
    'resetAt', v_reset_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_auth_rate_limit_clear(
  p_scope text,
  p_key_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_scope text := lower(trim(COALESCE(p_scope, '')));
  v_key_hash text := lower(trim(COALESCE(p_key_hash, '')));
  v_deleted integer := 0;
BEGIN
  IF v_scope NOT IN ('login_identity', 'login_ip', 'register_ip') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_SCOPE'
    );
  END IF;

  IF v_key_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_KEY'
    );
  END IF;

  DELETE FROM public.auth_rate_limit_buckets
  WHERE scope = v_scope
    AND key_hash = v_key_hash;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'success', true,
    'cleared', v_deleted > 0
  );
END;
$$;

REVOKE ALL ON FUNCTION public.nexora_auth_rate_limit_consume(
  text, text, integer, integer
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_auth_rate_limit_consume(
  text, text, integer, integer
) TO service_role;

REVOKE ALL ON FUNCTION public.nexora_auth_rate_limit_clear(
  text, text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_auth_rate_limit_clear(
  text, text
) TO service_role;

COMMIT;
