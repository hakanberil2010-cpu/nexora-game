-- NEXORA Phase 10 – Trade V2
-- Adds market tax, trade limits, distance-based delivery, richer history fields
-- and anti-funneling protections while preserving the existing trade API actions.
-- Apply after 011_phase9_alliance_wars_v1.sql.
-- Additive / production-safe: no existing trade rows are deleted.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) V2 TRANSACTION METADATA
-- Legacy transactions remain delivered with zero V2 tax.
-- -----------------------------------------------------------------------------

ALTER TABLE public.trade_transactions
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'delivered',
  ADD COLUMN IF NOT EXISTS tax_rate numeric(6,5) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS seller_tax_amount bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS buyer_tax_amount bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS seller_receive_amount bigint,
  ADD COLUMN IF NOT EXISTS buyer_receive_amount bigint,
  ADD COLUMN IF NOT EXISTS distance numeric(10,2),
  ADD COLUMN IF NOT EXISTS delivery_seconds integer,
  ADD COLUMN IF NOT EXISTS delivery_at timestamptz,
  ADD COLUMN IF NOT EXISTS delivered_at timestamptz,
  ADD COLUMN IF NOT EXISTS delivery_block_reason text;

CREATE INDEX IF NOT EXISTS idx_trade_transactions_delivery
  ON public.trade_transactions(status, delivery_at, id)
  WHERE status IN ('in_transit','blocked');

CREATE INDEX IF NOT EXISTS idx_trade_transactions_pair_recent
  ON public.trade_transactions(seller_player_id, buyer_player_id, created_at DESC);

-- -----------------------------------------------------------------------------
-- 2) V2 CONFIG / HELPERS
-- Resource weights are used only for abuse prevention, not for price fixing.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_trade_resource_weight(
  p_resource text
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE p_resource
    WHEN 'metal' THEN 1::numeric
    WHEN 'energy' THEN 1::numeric
    WHEN 'water' THEN 1::numeric
    WHEN 'crystal' THEN 4::numeric
    ELSE 0::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_trade_storage_capacity(
  p_city_id bigint,
  p_resource text
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_depo integer := 0;
  v_crystal_depo integer := 0;
BEGIN
  SELECT
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Depo'), 0),
    COALESCE(MAX(level) FILTER (WHERE building_type = 'Kristal Deposu'), 0)
  INTO v_depo, v_crystal_depo
  FROM public.buildings
  WHERE city_id = p_city_id;

  IF p_resource = 'crystal' THEN
    RETURN 3000 + GREATEST(0, v_crystal_depo) * 1500;
  END IF;

  RETURN 5000 + GREATEST(0, v_depo) * 2500;
END;
$$;

CREATE OR REPLACE FUNCTION public.nexora_trade_config()
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'taxRate', 0.05,
    'maxOpenOffers', 5,
    'maxPairTrades24h', 10,
    'maxPlayerTrades24h', 30,
    'maxOfferAmount', 100000000,
    'minOfferAmount', 10,
    'minFairValueRatio', 0.50,
    'maxFairValueRatio', 2.00,
    'secondsPerTile', 10,
    'minDeliverySeconds', 30,
    'maxDeliverySeconds', 7200
  );
$$;

-- -----------------------------------------------------------------------------
-- 3) DELIVERY FINALIZER
-- Trade resources remain escrowed while in transit. Delivery uses database
-- server time and is idempotent. If storage is full, delivery is blocked until
-- enough room exists; resources are never silently discarded.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_trade_finalize_transaction(
  p_transaction_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
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

  IF COALESCE(v_tx.delivery_at, v_tx.created_at) > now() THEN
    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_tx.id,
      'status', 'in_transit',
      'remainingSeconds',
        GREATEST(
          0,
          CEIL(
            EXTRACT(
              EPOCH FROM (COALESCE(v_tx.delivery_at, v_tx.created_at) - now())
            )
          )::integer
        )
    );
  END IF;

  -- Stable lock order protects concurrent deliveries and other resource writes.
  PERFORM id
    FROM public.cities
   WHERE player_id IN (v_tx.seller_player_id, v_tx.buyer_player_id)
   ORDER BY id
   FOR UPDATE;

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
           delivery_block_reason = 'CITY_MISSING'
     WHERE id = v_tx.id;

    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_tx.id,
      'status', 'blocked',
      'code', 'CITY_MISSING',
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
           delivery_block_reason = 'STORAGE_FULL'
     WHERE id = v_tx.id;

    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_tx.id,
      'status', 'blocked',
      'code', 'STORAGE_FULL',
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
         delivery_block_reason = NULL
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

CREATE OR REPLACE FUNCTION public.nexora_trade_sync_player(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row record;
  v_result jsonb;
  v_checked integer := 0;
  v_delivered integer := 0;
  v_blocked integer := 0;
  v_pending integer := 0;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  END IF;

  FOR v_row IN
    SELECT id
      FROM public.trade_transactions
     WHERE (
       seller_player_id = p_player_id
       OR buyer_player_id = p_player_id
     )
       AND status IN ('in_transit','blocked')
       AND COALESCE(delivery_at, created_at) <= now()
     ORDER BY id
     LIMIT 100
  LOOP
    v_checked := v_checked + 1;
    v_result := public.nexora_trade_finalize_transaction(v_row.id);

    IF v_result->>'status' = 'delivered' THEN
      v_delivered := v_delivered + 1;
    ELSIF v_result->>'status' = 'blocked' THEN
      v_blocked := v_blocked + 1;
    END IF;
  END LOOP;

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
    'checked', v_checked,
    'delivered', v_delivered,
    'blocked', v_blocked,
    'pending', v_pending,
    'serverTime', now(),
    'config', public.nexora_trade_config()
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 4) CREATE OFFER V2
-- Same RPC signature as V1, so existing backend action remains compatible.
-- Limits: 5 live offers; 10..100,000,000 units; 0.5x..2x weighted value ratio.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_trade_offer(
  p_player_id bigint,
  p_give_resource text,
  p_give_amount bigint,
  p_want_resource text,
  p_want_amount bigint,
  p_expires_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_city public.cities%ROWTYPE;
  v_offer public.trade_offers%ROWTYPE;
  v_current bigint;
  v_open_count integer;
  v_ratio numeric;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RAISE EXCEPTION 'Geçersiz oyuncu.';
  END IF;

  IF p_give_resource NOT IN ('metal','energy','water','crystal')
     OR p_want_resource NOT IN ('metal','energy','water','crystal') THEN
    RAISE EXCEPTION 'Geçersiz kaynak.';
  END IF;

  IF p_give_resource = p_want_resource THEN
    RAISE EXCEPTION 'Verilen ve istenen kaynak farklı olmalı.';
  END IF;

  IF p_give_amount < 10 OR p_want_amount < 10
     OR p_give_amount > 100000000 OR p_want_amount > 100000000 THEN
    RAISE EXCEPTION 'Ticaret miktarı 10 ile 100000000 arasında olmalı.';
  END IF;

  IF p_expires_at IS NULL
     OR p_expires_at <= now() + interval '5 minutes'
     OR p_expires_at > now() + interval '73 hours' THEN
    RAISE EXCEPTION 'Teklif süresi geçersiz.';
  END IF;

  v_ratio :=
    (p_give_amount::numeric * public.nexora_trade_resource_weight(p_give_resource))
    /
    NULLIF(
      p_want_amount::numeric * public.nexora_trade_resource_weight(p_want_resource),
      0
    );

  IF v_ratio < 0.50 OR v_ratio > 2.00 THEN
    RAISE EXCEPTION
      'Teklif değer oranı güvenli piyasa aralığının dışında.';
  END IF;

  PERFORM public.nexora_trade_sync_player(p_player_id);

  SELECT COUNT(*)
    INTO v_open_count
    FROM public.trade_offers
   WHERE creator_player_id = p_player_id
     AND status = 'open'
     AND expires_at > now();

  IF v_open_count >= 5 THEN
    RAISE EXCEPTION 'Aynı anda en fazla 5 açık teklif verebilirsin.';
  END IF;

  SELECT *
    INTO v_city
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Koloni bulunamadı.';
  END IF;

  v_current := CASE p_give_resource
    WHEN 'metal' THEN COALESCE(v_city.metal, 0)
    WHEN 'energy' THEN COALESCE(v_city.energy, 0)
    WHEN 'water' THEN COALESCE(v_city.water, 0)
    WHEN 'crystal' THEN COALESCE(v_city.crystal, 0)
  END;

  IF v_current < p_give_amount THEN
    RAISE EXCEPTION 'Verilecek kaynak yetersiz.';
  END IF;

  IF p_give_resource = 'metal' THEN
    UPDATE public.cities SET metal = v_current - p_give_amount WHERE id = v_city.id;
  ELSIF p_give_resource = 'energy' THEN
    UPDATE public.cities SET energy = v_current - p_give_amount WHERE id = v_city.id;
  ELSIF p_give_resource = 'water' THEN
    UPDATE public.cities SET water = v_current - p_give_amount WHERE id = v_city.id;
  ELSE
    UPDATE public.cities SET crystal = v_current - p_give_amount WHERE id = v_city.id;
  END IF;

  INSERT INTO public.trade_offers(
    creator_player_id,
    give_resource,
    give_amount,
    want_resource,
    want_amount,
    expires_at
  )
  VALUES(
    p_player_id,
    p_give_resource,
    p_give_amount,
    p_want_resource,
    p_want_amount,
    p_expires_at
  )
  RETURNING * INTO v_offer;

  RETURN jsonb_build_object(
    'success', true,
    'offer', to_jsonb(v_offer),
    'fairValueRatio', ROUND(v_ratio, 4),
    'taxRate', 0.05,
    'message', 'Ticaret teklifi oluşturuldu.'
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 5) ACCEPT OFFER V2
-- The buyer payment is escrowed immediately. Both net receipts travel according
-- to colony distance and are credited together at delivery time.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.accept_trade_offer(
  p_offer_id bigint,
  p_acceptor_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offer public.trade_offers%ROWTYPE;
  v_seller public.cities%ROWTYPE;
  v_buyer public.cities%ROWTYPE;
  v_tx public.trade_transactions%ROWTYPE;
  v_buyer_value bigint;
  v_seller_current bigint;
  v_buyer_current bigint;
  v_seller_capacity bigint;
  v_buyer_capacity bigint;
  v_pair_count integer;
  v_seller_recent integer;
  v_buyer_recent integer;
  v_distance numeric;
  v_delivery_seconds integer;
  v_delivery_at timestamptz;
  v_tax_rate numeric := 0.05;
  v_seller_tax bigint;
  v_buyer_tax bigint;
  v_seller_receive bigint;
  v_buyer_receive bigint;
BEGIN
  IF p_offer_id IS NULL OR p_offer_id <= 0
     OR p_acceptor_player_id IS NULL OR p_acceptor_player_id <= 0 THEN
    RAISE EXCEPTION 'Geçersiz ticaret isteği.';
  END IF;

  SELECT *
    INTO v_offer
    FROM public.trade_offers
   WHERE id = p_offer_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Teklif bulunamadı.';
  END IF;

  IF v_offer.status <> 'open' THEN
    RAISE EXCEPTION 'Bu teklif artık açık değil.';
  END IF;

  IF v_offer.expires_at <= now() THEN
    RAISE EXCEPTION 'Teklifin süresi dolmuş. Teklif sahibi kaynağı iade alabilir.';
  END IF;

  IF v_offer.creator_player_id = p_acceptor_player_id THEN
    RAISE EXCEPTION 'Kendi teklifini kabul edemezsin.';
  END IF;

  -- Anti-funneling: repeated pair trades and excessive daily trading are capped.
  SELECT COUNT(*)
    INTO v_pair_count
    FROM public.trade_transactions
   WHERE created_at >= now() - interval '24 hours'
     AND status IN ('in_transit','blocked','delivered')
     AND (
       (
         seller_player_id = v_offer.creator_player_id
         AND buyer_player_id = p_acceptor_player_id
       )
       OR
       (
         seller_player_id = p_acceptor_player_id
         AND buyer_player_id = v_offer.creator_player_id
       )
     );

  IF v_pair_count >= 10 THEN
    RAISE EXCEPTION
      'Bu iki oyuncu son 24 saatte maksimum ticaret sayısına ulaştı.';
  END IF;

  SELECT COUNT(*)
    INTO v_seller_recent
    FROM public.trade_transactions
   WHERE created_at >= now() - interval '24 hours'
     AND status IN ('in_transit','blocked','delivered')
     AND (
       seller_player_id = v_offer.creator_player_id
       OR buyer_player_id = v_offer.creator_player_id
     );

  SELECT COUNT(*)
    INTO v_buyer_recent
    FROM public.trade_transactions
   WHERE created_at >= now() - interval '24 hours'
     AND status IN ('in_transit','blocked','delivered')
     AND (
       seller_player_id = p_acceptor_player_id
       OR buyer_player_id = p_acceptor_player_id
     );

  IF v_seller_recent >= 30 OR v_buyer_recent >= 30 THEN
    RAISE EXCEPTION
      'Oyunculardan biri günlük ticaret limitine ulaştı.';
  END IF;

  PERFORM id
    FROM public.cities
   WHERE player_id IN (v_offer.creator_player_id, p_acceptor_player_id)
   ORDER BY id
   FOR UPDATE;

  SELECT *
    INTO v_seller
    FROM public.cities
   WHERE player_id = v_offer.creator_player_id
   ORDER BY id
   LIMIT 1;

  SELECT *
    INTO v_buyer
    FROM public.cities
   WHERE player_id = p_acceptor_player_id
   ORDER BY id
   LIMIT 1;

  IF v_seller.id IS NULL THEN
    RAISE EXCEPTION 'Satıcı kolonisi bulunamadı.';
  END IF;

  IF v_buyer.id IS NULL THEN
    RAISE EXCEPTION 'Alıcı kolonisi bulunamadı.';
  END IF;

  v_buyer_value := CASE v_offer.want_resource
    WHEN 'metal' THEN COALESCE(v_buyer.metal, 0)
    WHEN 'energy' THEN COALESCE(v_buyer.energy, 0)
    WHEN 'water' THEN COALESCE(v_buyer.water, 0)
    WHEN 'crystal' THEN COALESCE(v_buyer.crystal, 0)
  END;

  IF v_buyer_value < v_offer.want_amount THEN
    RAISE EXCEPTION 'İstenen kaynak alıcıda yetersiz.';
  END IF;

  v_seller_tax := CEIL(v_offer.want_amount::numeric * v_tax_rate)::bigint;
  v_buyer_tax := CEIL(v_offer.give_amount::numeric * v_tax_rate)::bigint;
  v_seller_receive := GREATEST(0, v_offer.want_amount - v_seller_tax);
  v_buyer_receive := GREATEST(0, v_offer.give_amount - v_buyer_tax);

  IF v_seller_receive <= 0 OR v_buyer_receive <= 0 THEN
    RAISE EXCEPTION 'Vergi sonrası teslimat miktarı geçersiz.';
  END IF;

  v_seller_current := CASE v_offer.want_resource
    WHEN 'metal' THEN COALESCE(v_seller.metal, 0)
    WHEN 'energy' THEN COALESCE(v_seller.energy, 0)
    WHEN 'water' THEN COALESCE(v_seller.water, 0)
    WHEN 'crystal' THEN COALESCE(v_seller.crystal, 0)
  END;

  v_buyer_current := CASE v_offer.give_resource
    WHEN 'metal' THEN COALESCE(v_buyer.metal, 0)
    WHEN 'energy' THEN COALESCE(v_buyer.energy, 0)
    WHEN 'water' THEN COALESCE(v_buyer.water, 0)
    WHEN 'crystal' THEN COALESCE(v_buyer.crystal, 0)
  END;

  v_seller_capacity := public.nexora_trade_storage_capacity(
    v_seller.id,
    v_offer.want_resource
  );
  v_buyer_capacity := public.nexora_trade_storage_capacity(
    v_buyer.id,
    v_offer.give_resource
  );

  IF v_seller_current + v_seller_receive > v_seller_capacity THEN
    RAISE EXCEPTION 'Satıcının deposunda teslimat için yeterli alan yok.';
  END IF;

  IF v_buyer_current + v_buyer_receive > v_buyer_capacity THEN
    RAISE EXCEPTION 'Alıcının deposunda teslimat için yeterli alan yok.';
  END IF;

  v_distance := ROUND(
    SQRT(
      POWER(COALESCE(v_seller.coordinate_x, 0) - COALESCE(v_buyer.coordinate_x, 0), 2)
      +
      POWER(COALESCE(v_seller.coordinate_y, 0) - COALESCE(v_buyer.coordinate_y, 0), 2)
    )::numeric,
    2
  );

  v_delivery_seconds := GREATEST(
    30,
    LEAST(
      7200,
      CEIL(GREATEST(1::numeric, v_distance) * 10)::integer
    )
  );
  v_delivery_at := now() + make_interval(secs => v_delivery_seconds);

  -- Escrow buyer payment now. Seller's give amount is already escrowed by offer.
  IF v_offer.want_resource = 'metal' THEN
    UPDATE public.cities
       SET metal = v_buyer_value - v_offer.want_amount
     WHERE id = v_buyer.id;
  ELSIF v_offer.want_resource = 'energy' THEN
    UPDATE public.cities
       SET energy = v_buyer_value - v_offer.want_amount
     WHERE id = v_buyer.id;
  ELSIF v_offer.want_resource = 'water' THEN
    UPDATE public.cities
       SET water = v_buyer_value - v_offer.want_amount
     WHERE id = v_buyer.id;
  ELSE
    UPDATE public.cities
       SET crystal = v_buyer_value - v_offer.want_amount
     WHERE id = v_buyer.id;
  END IF;

  UPDATE public.trade_offers
     SET status = 'accepted',
         accepted_by_player_id = p_acceptor_player_id,
         accepted_at = now()
   WHERE id = v_offer.id;

  INSERT INTO public.trade_transactions(
    offer_id,
    seller_player_id,
    buyer_player_id,
    give_resource,
    give_amount,
    want_resource,
    want_amount,
    status,
    tax_rate,
    seller_tax_amount,
    buyer_tax_amount,
    seller_receive_amount,
    buyer_receive_amount,
    distance,
    delivery_seconds,
    delivery_at
  )
  VALUES(
    v_offer.id,
    v_offer.creator_player_id,
    p_acceptor_player_id,
    v_offer.give_resource,
    v_offer.give_amount,
    v_offer.want_resource,
    v_offer.want_amount,
    'in_transit',
    v_tax_rate,
    v_seller_tax,
    v_buyer_tax,
    v_seller_receive,
    v_buyer_receive,
    v_distance,
    v_delivery_seconds,
    v_delivery_at
  )
  RETURNING * INTO v_tx;

  RETURN jsonb_build_object(
    'success', true,
    'transaction', to_jsonb(v_tx),
    'remainingSeconds', v_delivery_seconds,
    'serverTime', now(),
    'message', 'Ticaret kabul edildi. Kaynaklar lojistik teslimata çıktı.'
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 6) CANCEL / REFUND V2
-- An expired open offer can still be reclaimed by its creator. Full escrow is
-- returned only when storage has enough room, preventing over-cap resources.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cancel_trade_offer(
  p_offer_id bigint,
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offer public.trade_offers%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_current bigint;
  v_capacity bigint;
  v_status text;
BEGIN
  IF p_offer_id IS NULL OR p_offer_id <= 0
     OR p_player_id IS NULL OR p_player_id <= 0 THEN
    RAISE EXCEPTION 'Geçersiz teklif.';
  END IF;

  SELECT *
    INTO v_offer
    FROM public.trade_offers
   WHERE id = p_offer_id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Teklif bulunamadı.';
  END IF;

  IF v_offer.creator_player_id <> p_player_id THEN
    RAISE EXCEPTION 'Bu teklif sana ait değil.';
  END IF;

  IF v_offer.status <> 'open' THEN
    RAISE EXCEPTION 'Bu teklif artık açık değil.';
  END IF;

  SELECT *
    INTO v_city
    FROM public.cities
   WHERE player_id = p_player_id
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Koloni bulunamadı.';
  END IF;

  v_current := CASE v_offer.give_resource
    WHEN 'metal' THEN COALESCE(v_city.metal, 0)
    WHEN 'energy' THEN COALESCE(v_city.energy, 0)
    WHEN 'water' THEN COALESCE(v_city.water, 0)
    WHEN 'crystal' THEN COALESCE(v_city.crystal, 0)
  END;

  v_capacity := public.nexora_trade_storage_capacity(
    v_city.id,
    v_offer.give_resource
  );

  IF v_current + v_offer.give_amount > v_capacity THEN
    RAISE EXCEPTION
      'Kaynak iadesi için depoda yeterli boş alan yok.';
  END IF;

  IF v_offer.give_resource = 'metal' THEN
    UPDATE public.cities
       SET metal = v_current + v_offer.give_amount
     WHERE id = v_city.id;
  ELSIF v_offer.give_resource = 'energy' THEN
    UPDATE public.cities
       SET energy = v_current + v_offer.give_amount
     WHERE id = v_city.id;
  ELSIF v_offer.give_resource = 'water' THEN
    UPDATE public.cities
       SET water = v_current + v_offer.give_amount
     WHERE id = v_city.id;
  ELSE
    UPDATE public.cities
       SET crystal = v_current + v_offer.give_amount
     WHERE id = v_city.id;
  END IF;

  v_status := CASE
    WHEN v_offer.expires_at <= now() THEN 'expired'
    ELSE 'cancelled'
  END;

  UPDATE public.trade_offers
     SET status = v_status
   WHERE id = v_offer.id;

  RETURN jsonb_build_object(
    'success', true,
    'offerId', v_offer.id,
    'status', v_status,
    'refundedResource', v_offer.give_resource,
    'refundedAmount', v_offer.give_amount,
    'message', 'Teklif kapatıldı ve escrow kaynağı iade edildi.'
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 7) SECURITY
-- Trading is server-authoritative. Browser clients use /api/auth only.
-- -----------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.nexora_trade_resource_weight(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_trade_resource_weight(text)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_trade_storage_capacity(bigint,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_trade_storage_capacity(bigint,text)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_trade_config()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_trade_config()
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_trade_finalize_transaction(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_trade_finalize_transaction(bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_trade_sync_player(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_trade_sync_player(bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.create_trade_offer(
  bigint,text,bigint,text,bigint,timestamptz
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_trade_offer(
  bigint,text,bigint,text,bigint,timestamptz
) TO service_role;

REVOKE ALL ON FUNCTION public.accept_trade_offer(bigint,bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.accept_trade_offer(bigint,bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.cancel_trade_offer(bigint,bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_trade_offer(bigint,bigint)
  TO service_role;

ALTER TABLE public.trade_offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trade_transactions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.trade_offers
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.trade_transactions
  FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.trade_offers TO service_role;
GRANT ALL ON TABLE public.trade_transactions TO service_role;

GRANT USAGE, SELECT ON SEQUENCE public.trade_offers_id_seq TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.trade_transactions_id_seq TO service_role;

COMMIT;
