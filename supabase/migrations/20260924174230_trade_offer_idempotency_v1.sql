ALTER TABLE public.trade_offers
  ADD COLUMN request_key text;

ALTER TABLE public.trade_offers
  ADD CONSTRAINT trade_offers_request_key_check
  CHECK (
    request_key IS NULL
    OR (
      char_length(request_key) BETWEEN 8 AND 128
      AND request_key ~ '^[A-Za-z0-9._:-]+$'
    )
  );

CREATE UNIQUE INDEX idx_trade_offers_creator_request_key
  ON public.trade_offers(creator_player_id, request_key)
  WHERE request_key IS NOT NULL;

CREATE OR REPLACE FUNCTION public.create_trade_offer(
  p_player_id bigint,
  p_give_resource text,
  p_give_amount bigint,
  p_want_resource text,
  p_want_amount bigint,
  p_expires_at timestamptz,
  p_request_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_request_key text;
  v_existing public.trade_offers%ROWTYPE;
  v_result jsonb;
  v_offer_id bigint;
BEGIN
  v_request_key := nullif(btrim(coalesce(p_request_key, '')), '');

  IF v_request_key IS NULL THEN
    RETURN public.create_trade_offer(
      p_player_id,
      p_give_resource,
      p_give_amount,
      p_want_resource,
      p_want_amount,
      p_expires_at
    );
  END IF;

  IF char_length(v_request_key) < 8
     OR char_length(v_request_key) > 128
     OR v_request_key !~ '^[A-Za-z0-9._:-]+$' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_REQUEST_KEY',
      'message', 'Geçersiz ticaret istek anahtarı.'
    );
  END IF;

  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  -- Serialize idempotent offer creation attempts per player before checking
  -- whether this request key has already created an escrow-backed offer.
  PERFORM pg_advisory_xact_lock(p_player_id);

  SELECT *
    INTO v_existing
    FROM public.trade_offers
   WHERE creator_player_id = p_player_id
     AND request_key = v_request_key
   ORDER BY id
   LIMIT 1;

  IF v_existing.id IS NOT NULL THEN
    IF v_existing.give_resource IS DISTINCT FROM p_give_resource
       OR v_existing.give_amount IS DISTINCT FROM p_give_amount
       OR v_existing.want_resource IS DISTINCT FROM p_want_resource
       OR v_existing.want_amount IS DISTINCT FROM p_want_amount
       OR v_existing.expires_at IS DISTINCT FROM p_expires_at THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'IDEMPOTENCY_KEY_REUSED',
        'message', 'Bu ticaret istek anahtarı farklı bir teklif için zaten kullanılmış.'
      );
    END IF;

    RETURN jsonb_build_object(
      'success', true,
      'offer', to_jsonb(v_existing),
      'idempotentReplay', true,
      'message', 'Ticaret teklifi daha önce oluşturuldu.'
    );
  END IF;

  v_result := public.create_trade_offer(
    p_player_id,
    p_give_resource,
    p_give_amount,
    p_want_resource,
    p_want_amount,
    p_expires_at
  );

  IF v_result IS NULL
     OR COALESCE((v_result->>'success')::boolean, false) IS NOT TRUE THEN
    RETURN v_result;
  END IF;

  BEGIN
    v_offer_id := nullif(v_result->'offer'->>'id', '')::bigint;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Ticaret teklif kimliği doğrulanamadı.';
  END;

  IF v_offer_id IS NULL OR v_offer_id <= 0 THEN
    RAISE EXCEPTION 'Ticaret teklif kimliği doğrulanamadı.';
  END IF;

  UPDATE public.trade_offers
     SET request_key = v_request_key
   WHERE id = v_offer_id
     AND creator_player_id = p_player_id
  RETURNING * INTO v_existing;

  IF v_existing.id IS NULL THEN
    RAISE EXCEPTION 'Ticaret istek anahtarı teklife kaydedilemedi.';
  END IF;

  RETURN v_result || jsonb_build_object(
    'offer', to_jsonb(v_existing),
    'idempotentReplay', false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.create_trade_offer(
  bigint,
  text,
  bigint,
  text,
  bigint,
  timestamptz,
  text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.create_trade_offer(
  bigint,
  text,
  bigint,
  text,
  bigint,
  timestamptz,
  text
) TO service_role;