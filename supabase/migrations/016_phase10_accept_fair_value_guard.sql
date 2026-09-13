-- NEXORA Phase 10 audit fix 5
-- Revalidates legacy/open offers at accept time so pre-Trade-V2 offers cannot
-- bypass resource, amount, or fair-value anti-funneling rules.
-- Apply after 015_phase10_trade_delivery_sync.sql.

BEGIN;

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
    RAISE EXCEPTION 'Teklifin süresi dolmuş. Teklif sahibi kaynağı iade alabilir.';
  END IF;

  IF v_offer.creator_player_id = p_acceptor_player_id THEN
    RAISE EXCEPTION 'Kendi teklifini kabul edemezsin.';
  END IF;

  -- Re-validate legacy/open offers at accept time too. Phase 4 offers may have
  -- been created before Trade V2 fair-value and amount rules existed.
  IF v_offer.give_resource NOT IN ('metal','energy','water','crystal')
     OR v_offer.want_resource NOT IN ('metal','energy','water','crystal') THEN
    RAISE EXCEPTION 'Teklif geçersiz kaynak içeriyor. Teklif sahibi iptal ederek escrow kaynağını geri alabilir.';
  END IF;

  IF v_offer.give_resource = v_offer.want_resource THEN
    RAISE EXCEPTION 'Teklif aynı kaynak türünü içeriyor. Teklif sahibi iptal ederek escrow kaynağını geri alabilir.';
  END IF;

  IF v_offer.give_amount IS NULL OR v_offer.want_amount IS NULL
     OR v_offer.give_amount < 10 OR v_offer.want_amount < 10
     OR v_offer.give_amount > 100000000 OR v_offer.want_amount > 100000000 THEN
    RAISE EXCEPTION 'Teklif miktarı Trade V2 sınırlarının dışında. Teklif sahibi iptal ederek escrow kaynağını geri alabilir.';
  END IF;

  v_ratio :=
    (v_offer.give_amount::numeric * public.nexora_trade_resource_weight(v_offer.give_resource))
    /
    NULLIF(
      v_offer.want_amount::numeric * public.nexora_trade_resource_weight(v_offer.want_resource),
      0
    );

  IF v_ratio IS NULL OR v_ratio < 0.50 OR v_ratio > 2.00 THEN
    RAISE EXCEPTION 'Teklif değer oranı güvenli piyasa aralığının dışında. Teklif sahibi iptal ederek escrow kaynağını geri alabilir.';
  END IF;

  -- Lock both player city rows first, in stable city-id order. These rows act as
  -- the shared mutex for pair/player daily limits across different offers.
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

  -- Anti-funneling counts happen while both player locks are held, so concurrent
  -- accepts between the same players cannot both observe the pre-limit count.
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

REVOKE ALL ON FUNCTION public.accept_trade_offer(bigint,bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.accept_trade_offer(bigint,bigint)
  TO service_role;

COMMIT;
