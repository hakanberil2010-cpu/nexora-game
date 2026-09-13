-- NEXORA Phase 10 audit fix 3/4
-- Prevents delivery-sync lock accumulation deadlocks and blocked-row starvation.
-- Delivery finalization is performed one transaction per RPC from the backend.
-- Apply after 014_phase10_trade_limit_concurrency.sql.

BEGIN;

ALTER TABLE public.trade_transactions
  ADD COLUMN IF NOT EXISTS delivery_retry_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_trade_transactions_retry
  ON public.trade_transactions(status, delivery_retry_at, delivery_at, id)
  WHERE status IN ('in_transit','blocked');

CREATE OR REPLACE FUNCTION public.nexora_trade_finalize_transaction(
  p_transaction_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_probe public.trade_transactions%ROWTYPE;
  v_tx public.trade_transactions%ROWTYPE;
  v_seller public.cities%ROWTYPE;
  v_buyer public.cities%ROWTYPE;
  v_seller_current bigint;
  v_buyer_current bigint;
  v_seller_capacity bigint;
  v_buyer_capacity bigint;
  v_seller_receive bigint;
  v_buyer_receive bigint;
BEGIN
  IF p_transaction_id IS NULL OR p_transaction_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_TRANSACTION',
      'message', 'Geçersiz ticaret kaydı.'
    );
  END IF;

  -- First read without a row lock only to learn both player ids.
  SELECT *
    INTO v_probe
    FROM public.trade_transactions
   WHERE id = p_transaction_id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TRANSACTION_NOT_FOUND',
      'message', 'Ticaret kaydı bulunamadı.'
    );
  END IF;

  IF v_probe.status = 'delivered' THEN
    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_probe.id,
      'status', 'delivered',
      'deliveredAt', v_probe.delivered_at
    );
  END IF;

  IF v_probe.status NOT IN ('in_transit','blocked') THEN
    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_probe.id,
      'status', v_probe.status
    );
  END IF;

  IF v_probe.status = 'blocked'
     AND COALESCE(v_probe.delivery_retry_at, v_probe.delivery_at, v_probe.created_at) > now() THEN
    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_probe.id,
      'status', 'blocked',
      'remainingSeconds',
        GREATEST(
          0,
          CEIL(
            EXTRACT(
              EPOCH FROM (
                COALESCE(v_probe.delivery_retry_at, v_probe.delivery_at, v_probe.created_at)
                - now()
              )
            )
          )::integer
        )
    );
  END IF;

  IF v_probe.status = 'in_transit'
     AND COALESCE(v_probe.delivery_at, v_probe.created_at) > now() THEN
    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_probe.id,
      'status', 'in_transit',
      'remainingSeconds',
        GREATEST(
          0,
          CEIL(
            EXTRACT(
              EPOCH FROM (COALESCE(v_probe.delivery_at, v_probe.created_at) - now())
            )
          )::integer
        )
    );
  END IF;

  -- Stable global lock order: city rows first, ordered by city id.
  -- The transaction row is locked only after both city locks are acquired.
  PERFORM id
    FROM public.cities
   WHERE player_id IN (v_probe.seller_player_id, v_probe.buyer_player_id)
   ORDER BY id
   FOR UPDATE;

  SELECT *
    INTO v_tx
    FROM public.trade_transactions
   WHERE id = p_transaction_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'TRANSACTION_NOT_FOUND',
      'message', 'Ticaret kaydı bulunamadı.'
    );
  END IF;

  -- Re-check after taking locks because another request may have completed it.
  IF v_tx.status = 'delivered' THEN
    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_tx.id,
      'status', 'delivered',
      'deliveredAt', v_tx.delivered_at
    );
  END IF;

  IF v_tx.status NOT IN ('in_transit','blocked') THEN
    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_tx.id,
      'status', v_tx.status
    );
  END IF;

  IF v_tx.status = 'blocked'
     AND COALESCE(v_tx.delivery_retry_at, v_tx.delivery_at, v_tx.created_at) > now() THEN
    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_tx.id,
      'status', 'blocked'
    );
  END IF;

  IF v_tx.status = 'in_transit'
     AND COALESCE(v_tx.delivery_at, v_tx.created_at) > now() THEN
    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_tx.id,
      'status', 'in_transit'
    );
  END IF;

  SELECT *
    INTO v_seller
    FROM public.cities
   WHERE player_id = v_tx.seller_player_id
   ORDER BY id
   LIMIT 1;

  SELECT *
    INTO v_buyer
    FROM public.cities
   WHERE player_id = v_tx.buyer_player_id
   ORDER BY id
   LIMIT 1;

  IF v_seller.id IS NULL OR v_buyer.id IS NULL THEN
    UPDATE public.trade_transactions
       SET status = 'blocked',
           delivery_block_reason = 'CITY_MISSING',
           delivery_retry_at = now() + interval '5 minutes'
     WHERE id = v_tx.id;

    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_tx.id,
      'status', 'blocked',
      'code', 'CITY_MISSING',
      'retryAt', now() + interval '5 minutes',
      'message', 'Teslimat için koloni bulunamadı.'
    );
  END IF;

  v_seller_receive := GREATEST(
    0,
    COALESCE(v_tx.seller_receive_amount, v_tx.want_amount)
  );
  v_buyer_receive := GREATEST(
    0,
    COALESCE(v_tx.buyer_receive_amount, v_tx.give_amount)
  );

  v_seller_current := CASE v_tx.want_resource
    WHEN 'metal' THEN COALESCE(v_seller.metal, 0)
    WHEN 'energy' THEN COALESCE(v_seller.energy, 0)
    WHEN 'water' THEN COALESCE(v_seller.water, 0)
    WHEN 'crystal' THEN COALESCE(v_seller.crystal, 0)
    ELSE 0
  END;

  v_buyer_current := CASE v_tx.give_resource
    WHEN 'metal' THEN COALESCE(v_buyer.metal, 0)
    WHEN 'energy' THEN COALESCE(v_buyer.energy, 0)
    WHEN 'water' THEN COALESCE(v_buyer.water, 0)
    WHEN 'crystal' THEN COALESCE(v_buyer.crystal, 0)
    ELSE 0
  END;

  v_seller_capacity := public.nexora_trade_storage_capacity(
    v_seller.id,
    v_tx.want_resource
  );
  v_buyer_capacity := public.nexora_trade_storage_capacity(
    v_buyer.id,
    v_tx.give_resource
  );

  IF v_seller_current + v_seller_receive > v_seller_capacity
     OR v_buyer_current + v_buyer_receive > v_buyer_capacity THEN
    UPDATE public.trade_transactions
       SET status = 'blocked',
           delivery_block_reason = 'STORAGE_FULL',
           delivery_retry_at = now() + interval '5 minutes'
     WHERE id = v_tx.id;

    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_tx.id,
      'status', 'blocked',
      'code', 'STORAGE_FULL',
      'retryAt', now() + interval '5 minutes',
      'message', 'Teslimat depo kapasitesi nedeniyle bekliyor.'
    );
  END IF;

  IF v_tx.want_resource = 'metal' THEN
    UPDATE public.cities
       SET metal = COALESCE(metal, 0) + v_seller_receive
     WHERE id = v_seller.id;
  ELSIF v_tx.want_resource = 'energy' THEN
    UPDATE public.cities
       SET energy = COALESCE(energy, 0) + v_seller_receive
     WHERE id = v_seller.id;
  ELSIF v_tx.want_resource = 'water' THEN
    UPDATE public.cities
       SET water = COALESCE(water, 0) + v_seller_receive
     WHERE id = v_seller.id;
  ELSE
    UPDATE public.cities
       SET crystal = COALESCE(crystal, 0) + v_seller_receive
     WHERE id = v_seller.id;
  END IF;

  IF v_tx.give_resource = 'metal' THEN
    UPDATE public.cities
       SET metal = COALESCE(metal, 0) + v_buyer_receive
     WHERE id = v_buyer.id;
  ELSIF v_tx.give_resource = 'energy' THEN
    UPDATE public.cities
       SET energy = COALESCE(energy, 0) + v_buyer_receive
     WHERE id = v_buyer.id;
  ELSIF v_tx.give_resource = 'water' THEN
    UPDATE public.cities
       SET water = COALESCE(water, 0) + v_buyer_receive
     WHERE id = v_buyer.id;
  ELSE
    UPDATE public.cities
       SET crystal = COALESCE(crystal, 0) + v_buyer_receive
     WHERE id = v_buyer.id;
  END IF;

  UPDATE public.trade_transactions
     SET status = 'delivered',
         delivered_at = now(),
         delivery_block_reason = NULL,
         delivery_retry_at = NULL
   WHERE id = v_tx.id;

  RETURN jsonb_build_object(
    'success', true,
    'transactionId', v_tx.id,
    'status', 'delivered',
    'deliveredAt', now(),
    'sellerReceiveAmount', v_seller_receive,
    'buyerReceiveAmount', v_buyer_receive
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_trade_due_transactions(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ids jsonb := '[]'::jsonb;
  v_pending integer := 0;
  v_due integer := 0;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  SELECT COALESCE(jsonb_agg(id ORDER BY priority, due_at, id), '[]'::jsonb)
    INTO v_ids
    FROM (
      SELECT
        id,
        CASE WHEN status = 'in_transit' THEN 0 ELSE 1 END AS priority,
        CASE
          WHEN status = 'blocked'
            THEN COALESCE(delivery_retry_at, delivery_at, created_at)
          ELSE COALESCE(delivery_at, created_at)
        END AS due_at
      FROM public.trade_transactions
      WHERE (
        seller_player_id = p_player_id
        OR buyer_player_id = p_player_id
      )
        AND status IN ('in_transit','blocked')
        AND (
          (
            status = 'in_transit'
            AND COALESCE(delivery_at, created_at) <= now()
          )
          OR
          (
            status = 'blocked'
            AND COALESCE(delivery_retry_at, delivery_at, created_at) <= now()
          )
        )
      ORDER BY priority, due_at, id
      LIMIT 100
    ) q;

  v_due := jsonb_array_length(v_ids);

  SELECT COUNT(*)
    INTO v_pending
    FROM public.trade_transactions
   WHERE (
     seller_player_id = p_player_id
     OR buyer_player_id = p_player_id
   )
     AND status IN ('in_transit','blocked');

  RETURN jsonb_build_object(
    'success', true,
    'transactionIds', v_ids,
    'due', v_due,
    'checked', 0,
    'delivered', 0,
    'blocked', 0,
    'pending', v_pending,
    'serverTime', now(),
    'config', public.nexora_trade_config()
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_trade_sync_player(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.nexora_trade_due_transactions(p_player_id);
$$;

REVOKE ALL ON FUNCTION public.nexora_trade_finalize_transaction(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_trade_finalize_transaction(bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_trade_due_transactions(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_trade_due_transactions(bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_trade_sync_player(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_trade_sync_player(bigint)
  TO service_role;

COMMIT;
