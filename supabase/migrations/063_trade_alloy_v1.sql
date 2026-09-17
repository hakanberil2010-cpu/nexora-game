-- NEXORA - Economy Rebalance V1 / Trade Alloy
-- Migration 063
--
-- Converts Trade V2 from legacy water to canonical alloy while preserving:
-- - escrow and partial refunds
-- - tax and fair-value checks
-- - anti-funneling limits
-- - distance-based delivery
-- - blocked delivery retries
-- - existing lock order / concurrency protections
--
-- Production audit before this migration:
--   water trade offers       = 0
--   water trade transactions = 0
--
-- Migration intentionally aborts if legacy water trade rows appear before apply.

BEGIN;

DO $guard$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM public.trade_offers
     WHERE give_resource = 'water'
        OR want_resource = 'water'
  )
  OR EXISTS (
    SELECT 1
      FROM public.trade_transactions
     WHERE give_resource = 'water'
        OR want_resource = 'water'
  ) THEN
    RAISE EXCEPTION
      'Legacy water trade rows exist; migrate them before enabling alloy-only trade.';
  END IF;
END;
$guard$;

CREATE OR REPLACE FUNCTION public.nexora_trade_resource_weight(
  p_resource text
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $function$
  SELECT CASE p_resource
    WHEN 'metal' THEN 1::numeric
    WHEN 'energy' THEN 1::numeric
    WHEN 'alloy' THEN 1::numeric
    WHEN 'crystal' THEN 4::numeric
    ELSE 0::numeric
  END;
$function$;

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
AS $function$
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

  IF p_give_resource NOT IN ('metal','energy','alloy','crystal')
     OR p_want_resource NOT IN ('metal','energy','alloy','crystal') THEN
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
    (
      p_give_amount::numeric
      * public.nexora_trade_resource_weight(p_give_resource)
    )
    /
    NULLIF(
      p_want_amount::numeric
      * public.nexora_trade_resource_weight(p_want_resource),
      0
    );

  IF v_ratio < 0.50 OR v_ratio > 2.00 THEN
    RAISE EXCEPTION
      'Teklif değer oranı güvenli piyasa aralığının dışında.';
  END IF;

  PERFORM public.nexora_trade_sync_player(p_player_id);

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

  SELECT COUNT(*)
    INTO v_open_count
    FROM public.trade_offers
   WHERE creator_player_id = p_player_id
     AND status = 'open'
     AND expires_at > now();

  IF v_open_count >= 5 THEN
    RAISE EXCEPTION 'Aynı anda en fazla 5 açık teklif verebilirsin.';
  END IF;

  v_current := CASE p_give_resource
    WHEN 'metal' THEN COALESCE(v_city.metal, 0)
    WHEN 'energy' THEN COALESCE(v_city.energy, 0)
    WHEN 'alloy' THEN COALESCE(v_city.alloy, 0)
    WHEN 'crystal' THEN COALESCE(v_city.crystal, 0)
  END;

  IF v_current < p_give_amount THEN
    RAISE EXCEPTION 'Verilecek kaynak yetersiz.';
  END IF;

  IF p_give_resource = 'metal' THEN
    UPDATE public.cities
       SET metal = v_current - p_give_amount
     WHERE id = v_city.id;
  ELSIF p_give_resource = 'energy' THEN
    UPDATE public.cities
       SET energy = v_current - p_give_amount
     WHERE id = v_city.id;
  ELSIF p_give_resource = 'alloy' THEN
    UPDATE public.cities
       SET alloy = v_current - p_give_amount
     WHERE id = v_city.id;
  ELSE
    UPDATE public.cities
       SET crystal = v_current - p_give_amount
     WHERE id = v_city.id;
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
$function$;

CREATE OR REPLACE FUNCTION public.accept_trade_offer(
  p_offer_id bigint,
  p_acceptor_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
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
  v_ratio numeric;
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
    RAISE EXCEPTION
      'Teklifin süresi dolmuş. Teklif sahibi kaynağı iade alabilir.';
  END IF;

  IF v_offer.creator_player_id = p_acceptor_player_id THEN
    RAISE EXCEPTION 'Kendi teklifini kabul edemezsin.';
  END IF;

  IF v_offer.give_resource NOT IN ('metal','energy','alloy','crystal')
     OR v_offer.want_resource NOT IN ('metal','energy','alloy','crystal') THEN
    RAISE EXCEPTION
      'Teklif geçersiz kaynak içeriyor. Teklif sahibi iptal ederek escrow kaynağını geri alabilir.';
  END IF;

  IF v_offer.give_resource = v_offer.want_resource THEN
    RAISE EXCEPTION
      'Teklif aynı kaynak türünü içeriyor. Teklif sahibi iptal ederek escrow kaynağını geri alabilir.';
  END IF;

  IF v_offer.give_amount IS NULL OR v_offer.want_amount IS NULL
     OR v_offer.give_amount < 10 OR v_offer.want_amount < 10
     OR v_offer.give_amount > 100000000
     OR v_offer.want_amount > 100000000 THEN
    RAISE EXCEPTION
      'Teklif miktarı Trade V2 sınırlarının dışında. Teklif sahibi iptal ederek escrow kaynağını geri alabilir.';
  END IF;

  v_ratio :=
    (
      v_offer.give_amount::numeric
      * public.nexora_trade_resource_weight(v_offer.give_resource)
    )
    /
    NULLIF(
      v_offer.want_amount::numeric
      * public.nexora_trade_resource_weight(v_offer.want_resource),
      0
    );

  IF v_ratio IS NULL OR v_ratio < 0.50 OR v_ratio > 2.00 THEN
    RAISE EXCEPTION
      'Teklif değer oranı güvenli piyasa aralığının dışında. Teklif sahibi iptal ederek escrow kaynağını geri alabilir.';
  END IF;

  PERFORM id
    FROM public.cities
   WHERE player_id IN (
     v_offer.creator_player_id,
     p_acceptor_player_id
   )
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

  v_buyer_value := CASE v_offer.want_resource
    WHEN 'metal' THEN COALESCE(v_buyer.metal, 0)
    WHEN 'energy' THEN COALESCE(v_buyer.energy, 0)
    WHEN 'alloy' THEN COALESCE(v_buyer.alloy, 0)
    WHEN 'crystal' THEN COALESCE(v_buyer.crystal, 0)
  END;

  IF v_buyer_value < v_offer.want_amount THEN
    RAISE EXCEPTION 'İstenen kaynak alıcıda yetersiz.';
  END IF;

  v_seller_tax :=
    CEIL(v_offer.want_amount::numeric * v_tax_rate)::bigint;

  v_buyer_tax :=
    CEIL(v_offer.give_amount::numeric * v_tax_rate)::bigint;

  v_seller_receive :=
    GREATEST(0, v_offer.want_amount - v_seller_tax);

  v_buyer_receive :=
    GREATEST(0, v_offer.give_amount - v_buyer_tax);

  IF v_seller_receive <= 0 OR v_buyer_receive <= 0 THEN
    RAISE EXCEPTION 'Vergi sonrası teslimat miktarı geçersiz.';
  END IF;

  v_seller_current := CASE v_offer.want_resource
    WHEN 'metal' THEN COALESCE(v_seller.metal, 0)
    WHEN 'energy' THEN COALESCE(v_seller.energy, 0)
    WHEN 'alloy' THEN COALESCE(v_seller.alloy, 0)
    WHEN 'crystal' THEN COALESCE(v_seller.crystal, 0)
  END;

  v_buyer_current := CASE v_offer.give_resource
    WHEN 'metal' THEN COALESCE(v_buyer.metal, 0)
    WHEN 'energy' THEN COALESCE(v_buyer.energy, 0)
    WHEN 'alloy' THEN COALESCE(v_buyer.alloy, 0)
    WHEN 'crystal' THEN COALESCE(v_buyer.crystal, 0)
  END;

  v_seller_capacity :=
    public.nexora_trade_storage_capacity(
      v_seller.id,
      v_offer.want_resource
    );

  v_buyer_capacity :=
    public.nexora_trade_storage_capacity(
      v_buyer.id,
      v_offer.give_resource
    );

  IF v_seller_current + v_seller_receive > v_seller_capacity THEN
    RAISE EXCEPTION
      'Satıcının deposunda teslimat için yeterli alan yok.';
  END IF;

  IF v_buyer_current + v_buyer_receive > v_buyer_capacity THEN
    RAISE EXCEPTION
      'Alıcının deposunda teslimat için yeterli alan yok.';
  END IF;

  v_distance := ROUND(
    SQRT(
      POWER(
        COALESCE(v_seller.coordinate_x, 0)
        - COALESCE(v_buyer.coordinate_x, 0),
        2
      )
      +
      POWER(
        COALESCE(v_seller.coordinate_y, 0)
        - COALESCE(v_buyer.coordinate_y, 0),
        2
      )
    )::numeric,
    2
  );

  v_delivery_seconds := GREATEST(
    30,
    LEAST(
      7200,
      CEIL(
        GREATEST(1::numeric, v_distance) * 10
      )::integer
    )
  );

  v_delivery_at :=
    now() + make_interval(secs => v_delivery_seconds);

  IF v_offer.want_resource = 'metal' THEN
    UPDATE public.cities
       SET metal = v_buyer_value - v_offer.want_amount
     WHERE id = v_buyer.id;
  ELSIF v_offer.want_resource = 'energy' THEN
    UPDATE public.cities
       SET energy = v_buyer_value - v_offer.want_amount
     WHERE id = v_buyer.id;
  ELSIF v_offer.want_resource = 'alloy' THEN
    UPDATE public.cities
       SET alloy = v_buyer_value - v_offer.want_amount
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
    'message',
      'Ticaret kabul edildi. Kaynaklar lojistik teslimata çıktı.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_trade_offer(
  p_offer_id bigint,
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_offer public.trade_offers%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_current bigint;
  v_capacity bigint;
  v_available bigint;
  v_refunded_before bigint;
  v_remaining_before bigint;
  v_refund_now bigint;
  v_remaining_after bigint;
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

  IF v_offer.give_resource NOT IN (
    'metal',
    'energy',
    'alloy',
    'crystal'
  )
     OR v_offer.give_amount IS NULL
     OR v_offer.give_amount < 0 THEN
    RAISE EXCEPTION 'Teklif escrow verisi geçersiz.';
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
    WHEN 'alloy' THEN COALESCE(v_city.alloy, 0)
    WHEN 'crystal' THEN COALESCE(v_city.crystal, 0)
  END;

  v_capacity :=
    public.nexora_trade_storage_capacity(
      v_city.id,
      v_offer.give_resource
    );

  v_refunded_before := GREATEST(
    0,
    LEAST(
      COALESCE(v_offer.escrow_refunded_amount, 0),
      v_offer.give_amount
    )
  );

  v_remaining_before := GREATEST(
    0,
    v_offer.give_amount - v_refunded_before
  );

  v_available :=
    GREATEST(0, v_capacity - v_current);

  v_refund_now :=
    LEAST(v_remaining_before, v_available);

  v_remaining_after :=
    v_remaining_before - v_refund_now;

  IF v_refund_now > 0 THEN
    IF v_offer.give_resource = 'metal' THEN
      UPDATE public.cities
         SET metal = COALESCE(metal, 0) + v_refund_now
       WHERE id = v_city.id;
    ELSIF v_offer.give_resource = 'energy' THEN
      UPDATE public.cities
         SET energy = COALESCE(energy, 0) + v_refund_now
       WHERE id = v_city.id;
    ELSIF v_offer.give_resource = 'alloy' THEN
      UPDATE public.cities
         SET alloy = COALESCE(alloy, 0) + v_refund_now
       WHERE id = v_city.id;
    ELSE
      UPDATE public.cities
         SET crystal = COALESCE(crystal, 0) + v_refund_now
       WHERE id = v_city.id;
    END IF;

    UPDATE public.trade_offers
       SET escrow_refunded_amount =
             v_refunded_before + v_refund_now
     WHERE id = v_offer.id;
  END IF;

  IF v_remaining_after = 0 THEN
    v_status := CASE
      WHEN v_offer.expires_at <= now() THEN 'expired'
      ELSE 'cancelled'
    END;

    UPDATE public.trade_offers
       SET status = v_status,
           escrow_refunded_amount = v_offer.give_amount
     WHERE id = v_offer.id;

    RETURN jsonb_build_object(
      'success', true,
      'offerId', v_offer.id,
      'status', v_status,
      'partialRefund', false,
      'refundedResource', v_offer.give_resource,
      'refundedAmount', v_refund_now,
      'refundedTotal', v_offer.give_amount,
      'remainingRefund', 0,
      'message',
        'Teklif kapatıldı ve escrow kaynağının tamamı iade edildi.'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'offerId', v_offer.id,
    'status', 'open',
    'partialRefund', true,
    'refundedResource', v_offer.give_resource,
    'refundedAmount', v_refund_now,
    'refundedTotal', v_refunded_before + v_refund_now,
    'remainingRefund', v_remaining_after,
    'message',
      CASE
        WHEN v_refund_now > 0 THEN
          'Escrow kaynağının depoya sığan kısmı iade edildi. Kalan miktar için depoda yer açıp tekrar iade al.'
        ELSE
          'Escrow iadesi için depoda boş alan yok. Depoda yer açıp tekrar dene.'
      END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_trade_finalize_transaction(
  p_transaction_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
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
     AND COALESCE(
       v_probe.delivery_retry_at,
       v_probe.delivery_at,
       v_probe.created_at
     ) > now() THEN
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
                COALESCE(
                  v_probe.delivery_retry_at,
                  v_probe.delivery_at,
                  v_probe.created_at
                )
                - now()
              )
            )
          )::integer
        )
    );
  END IF;

  IF v_probe.status = 'in_transit'
     AND COALESCE(
       v_probe.delivery_at,
       v_probe.created_at
     ) > now() THEN
    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_probe.id,
      'status', 'in_transit',
      'remainingSeconds',
        GREATEST(
          0,
          CEIL(
            EXTRACT(
              EPOCH FROM (
                COALESCE(
                  v_probe.delivery_at,
                  v_probe.created_at
                )
                - now()
              )
            )
          )::integer
        )
    );
  END IF;

  PERFORM id
    FROM public.cities
   WHERE player_id IN (
     v_probe.seller_player_id,
     v_probe.buyer_player_id
   )
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
     AND COALESCE(
       v_tx.delivery_retry_at,
       v_tx.delivery_at,
       v_tx.created_at
     ) > now() THEN
    RETURN jsonb_build_object(
      'success', true,
      'transactionId', v_tx.id,
      'status', 'blocked'
    );
  END IF;

  IF v_tx.status = 'in_transit'
     AND COALESCE(
       v_tx.delivery_at,
       v_tx.created_at
     ) > now() THEN
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
    COALESCE(
      v_tx.seller_receive_amount,
      v_tx.want_amount
    )
  );

  v_buyer_receive := GREATEST(
    0,
    COALESCE(
      v_tx.buyer_receive_amount,
      v_tx.give_amount
    )
  );

  v_seller_current := CASE v_tx.want_resource
    WHEN 'metal' THEN COALESCE(v_seller.metal, 0)
    WHEN 'energy' THEN COALESCE(v_seller.energy, 0)
    WHEN 'alloy' THEN COALESCE(v_seller.alloy, 0)
    WHEN 'crystal' THEN COALESCE(v_seller.crystal, 0)
    ELSE 0
  END;

  v_buyer_current := CASE v_tx.give_resource
    WHEN 'metal' THEN COALESCE(v_buyer.metal, 0)
    WHEN 'energy' THEN COALESCE(v_buyer.energy, 0)
    WHEN 'alloy' THEN COALESCE(v_buyer.alloy, 0)
    WHEN 'crystal' THEN COALESCE(v_buyer.crystal, 0)
    ELSE 0
  END;

  v_seller_capacity :=
    public.nexora_trade_storage_capacity(
      v_seller.id,
      v_tx.want_resource
    );

  v_buyer_capacity :=
    public.nexora_trade_storage_capacity(
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
      'message',
        'Teslimat depo kapasitesi nedeniyle bekliyor.'
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
  ELSIF v_tx.want_resource = 'alloy' THEN
    UPDATE public.cities
       SET alloy = COALESCE(alloy, 0) + v_seller_receive
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
  ELSIF v_tx.give_resource = 'alloy' THEN
    UPDATE public.cities
       SET alloy = COALESCE(alloy, 0) + v_buyer_receive
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
$function$;

ALTER TABLE public.trade_offers
  DROP CONSTRAINT IF EXISTS trade_offers_give_resource_check;

ALTER TABLE public.trade_offers
  ADD CONSTRAINT trade_offers_give_resource_check
  CHECK (
    give_resource = ANY (
      ARRAY[
        'metal'::text,
        'energy'::text,
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
        'alloy'::text,
        'crystal'::text
      ]
    )
  );

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

REVOKE ALL ON FUNCTION public.nexora_trade_finalize_transaction(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_trade_finalize_transaction(bigint)
  TO service_role;

COMMIT;
