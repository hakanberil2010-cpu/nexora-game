-- NEXORA Phase 10 audit fix 8
-- Allows oversized legacy Phase 4 escrow to be refunded safely in chunks
-- without clipping resources or making a partially refunded offer acceptable.
-- Apply after 017_phase10_atomic_resource_spend.sql.

BEGIN;

ALTER TABLE public.trade_offers
  ADD COLUMN IF NOT EXISTS escrow_refunded_amount bigint NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.nexora_trade_guard_partial_refund_accept()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.status = 'open'
     AND NEW.status = 'accepted'
     AND COALESCE(OLD.escrow_refunded_amount, 0) > 0 THEN
    RAISE EXCEPTION
      'Bu teklif için escrow iadesi başlamış; teklif artık kabul edilemez.';
  END IF;

  RETURN NEW;
END;
$$;

DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_trigger
     WHERE tgname = 'trg_trade_offer_partial_refund_accept_guard'
       AND tgrelid = 'public.trade_offers'::regclass
       AND NOT tgisinternal
  ) THEN
    EXECUTE '
      CREATE TRIGGER trg_trade_offer_partial_refund_accept_guard
      BEFORE UPDATE OF status ON public.trade_offers
      FOR EACH ROW
      EXECUTE FUNCTION public.nexora_trade_guard_partial_refund_accept()
    ';
  END IF;
END;
$do$;

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

  IF v_offer.give_resource NOT IN ('metal','energy','water','crystal')
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
    WHEN 'water' THEN COALESCE(v_city.water, 0)
    WHEN 'crystal' THEN COALESCE(v_city.crystal, 0)
  END;

  v_capacity := public.nexora_trade_storage_capacity(
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

  v_available := GREATEST(0, v_capacity - v_current);
  v_refund_now := LEAST(v_remaining_before, v_available);
  v_remaining_after := v_remaining_before - v_refund_now;

  IF v_refund_now > 0 THEN
    IF v_offer.give_resource = 'metal' THEN
      UPDATE public.cities
         SET metal = metal + v_refund_now
       WHERE id = v_city.id;
    ELSIF v_offer.give_resource = 'energy' THEN
      UPDATE public.cities
         SET energy = energy + v_refund_now
       WHERE id = v_city.id;
    ELSIF v_offer.give_resource = 'water' THEN
      UPDATE public.cities
         SET water = water + v_refund_now
       WHERE id = v_city.id;
    ELSE
      UPDATE public.cities
         SET crystal = crystal + v_refund_now
       WHERE id = v_city.id;
    END IF;

    UPDATE public.trade_offers
       SET escrow_refunded_amount = v_refunded_before + v_refund_now
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
      'message', 'Teklif kapatıldı ve escrow kaynağının tamamı iade edildi.'
    );
  END IF;

  -- Keep the offer open only so its owner can request the remaining refund
  -- after creating storage space. The trigger above forbids acceptance once
  -- any refund has started.
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
$$;

REVOKE ALL ON FUNCTION public.cancel_trade_offer(bigint,bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_trade_offer(bigint,bigint)
  TO service_role;

REVOKE ALL ON FUNCTION public.nexora_trade_guard_partial_refund_accept()
  FROM PUBLIC, anon, authenticated;

COMMIT;
