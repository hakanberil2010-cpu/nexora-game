-- NEXORA PHASE 4 – EKONOMİ / TİCARET SİSTEMİ V1
-- Mevcut ekonomi, kapasite ve savaş sistemi korunur.
-- Teklif oluşturulurken verilen kaynak escrow'a alınır; kabul edilince atomik olarak takas edilir.

CREATE TABLE IF NOT EXISTS trade_offers (
  id BIGSERIAL PRIMARY KEY,
  creator_player_id BIGINT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  give_resource TEXT NOT NULL CHECK (give_resource IN ('metal','energy','water','crystal')),
  give_amount BIGINT NOT NULL CHECK (give_amount > 0),
  want_resource TEXT NOT NULL CHECK (want_resource IN ('metal','energy','water','crystal')),
  want_amount BIGINT NOT NULL CHECK (want_amount > 0),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','accepted','cancelled','expired')),
  expires_at TIMESTAMPTZ NOT NULL,
  accepted_by_player_id BIGINT REFERENCES players(id) ON DELETE SET NULL,
  accepted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (give_resource <> want_resource)
);

CREATE INDEX IF NOT EXISTS idx_trade_offers_open ON trade_offers(status, expires_at, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trade_offers_creator ON trade_offers(creator_player_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS trade_transactions (
  id BIGSERIAL PRIMARY KEY,
  offer_id BIGINT NOT NULL REFERENCES trade_offers(id) ON DELETE RESTRICT,
  seller_player_id BIGINT NOT NULL REFERENCES players(id) ON DELETE RESTRICT,
  buyer_player_id BIGINT NOT NULL REFERENCES players(id) ON DELETE RESTRICT,
  give_resource TEXT NOT NULL CHECK (give_resource IN ('metal','energy','water','crystal')),
  give_amount BIGINT NOT NULL CHECK (give_amount > 0),
  want_resource TEXT NOT NULL CHECK (want_resource IN ('metal','energy','water','crystal')),
  want_amount BIGINT NOT NULL CHECK (want_amount > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_trade_transactions_seller ON trade_transactions(seller_player_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trade_transactions_buyer ON trade_transactions(buyer_player_id, created_at DESC);

CREATE OR REPLACE FUNCTION create_trade_offer(
  p_player_id BIGINT,
  p_give_resource TEXT,
  p_give_amount BIGINT,
  p_want_resource TEXT,
  p_want_amount BIGINT,
  p_expires_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c cities%ROWTYPE;
  new_offer trade_offers%ROWTYPE;
  current_value BIGINT;
BEGIN
  IF p_give_resource NOT IN ('metal','energy','water','crystal') OR p_want_resource NOT IN ('metal','energy','water','crystal') THEN
    RAISE EXCEPTION 'Geçersiz kaynak.';
  END IF;
  IF p_give_resource = p_want_resource OR p_give_amount <= 0 OR p_want_amount <= 0 THEN
    RAISE EXCEPTION 'Geçersiz ticaret miktarı.';
  END IF;
  IF p_expires_at <= NOW() THEN
    RAISE EXCEPTION 'Teklif süresi geçersiz.';
  END IF;

  SELECT * INTO c FROM cities WHERE player_id = p_player_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Koloni bulunamadı.'; END IF;

  current_value := CASE p_give_resource
    WHEN 'metal' THEN c.metal
    WHEN 'energy' THEN c.energy
    WHEN 'water' THEN c.water
    WHEN 'crystal' THEN c.crystal
  END;
  IF COALESCE(current_value,0) < p_give_amount THEN RAISE EXCEPTION 'Verilecek kaynak yetersiz.'; END IF;

  IF p_give_resource='metal' THEN c.metal:=c.metal-p_give_amount;
  ELSIF p_give_resource='energy' THEN c.energy:=c.energy-p_give_amount;
  ELSIF p_give_resource='water' THEN c.water:=c.water-p_give_amount;
  ELSE c.crystal:=c.crystal-p_give_amount;
  END IF;

  UPDATE cities SET metal=c.metal,energy=c.energy,water=c.water,crystal=c.crystal WHERE id=c.id;

  INSERT INTO trade_offers(creator_player_id,give_resource,give_amount,want_resource,want_amount,expires_at)
  VALUES(p_player_id,p_give_resource,p_give_amount,p_want_resource,p_want_amount,p_expires_at)
  RETURNING * INTO new_offer;

  RETURN jsonb_build_object('offer',to_jsonb(new_offer));
END;
$$;

CREATE OR REPLACE FUNCTION accept_trade_offer(
  p_offer_id BIGINT,
  p_acceptor_player_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  o trade_offers%ROWTYPE;
  seller cities%ROWTYPE;
  buyer cities%ROWTYPE;
  buyer_value BIGINT;
  seller_id BIGINT;
  tx trade_transactions%ROWTYPE;
BEGIN
  SELECT * INTO o FROM trade_offers WHERE id=p_offer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Teklif bulunamadı.'; END IF;
  IF o.status <> 'open' THEN RAISE EXCEPTION 'Bu teklif artık açık değil.'; END IF;
  IF o.expires_at <= NOW() THEN
    UPDATE trade_offers SET status='expired' WHERE id=o.id;
    -- Escrow iadesi için creator kolonisinin kilitlenmesi aşağıda yapılır.
    SELECT * INTO seller FROM cities WHERE player_id=o.creator_player_id ORDER BY id LIMIT 1 FOR UPDATE;
    IF FOUND THEN
      IF o.give_resource='metal' THEN seller.metal:=seller.metal+o.give_amount;
      ELSIF o.give_resource='energy' THEN seller.energy:=seller.energy+o.give_amount;
      ELSIF o.give_resource='water' THEN seller.water:=seller.water+o.give_amount;
      ELSE seller.crystal:=seller.crystal+o.give_amount;
      END IF;
      UPDATE cities SET metal=seller.metal,energy=seller.energy,water=seller.water,crystal=seller.crystal WHERE id=seller.id;
    END IF;
    RAISE EXCEPTION 'Teklifin süresi dolmuş.';
  END IF;
  IF o.creator_player_id=p_acceptor_player_id THEN RAISE EXCEPTION 'Kendi teklifini kabul edemezsin.'; END IF;

  SELECT * INTO seller FROM cities WHERE player_id=o.creator_player_id ORDER BY id LIMIT 1 FOR UPDATE;
  SELECT * INTO buyer FROM cities WHERE player_id=p_acceptor_player_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Alıcı kolonisi bulunamadı.'; END IF;
  IF seller.id IS NULL THEN RAISE EXCEPTION 'Satıcı kolonisi bulunamadı.'; END IF;

  buyer_value := CASE o.want_resource
    WHEN 'metal' THEN buyer.metal
    WHEN 'energy' THEN buyer.energy
    WHEN 'water' THEN buyer.water
    WHEN 'crystal' THEN buyer.crystal
  END;
  IF COALESCE(buyer_value,0) < o.want_amount THEN RAISE EXCEPTION 'İstenen kaynak alıcıda yetersiz.'; END IF;

  -- Alıcının istediği kaynak satıcıya, escrow kaynak alıcıya aktarılır.
  IF o.want_resource='metal' THEN buyer.metal:=buyer.metal-o.want_amount; seller.metal:=seller.metal+o.want_amount;
  ELSIF o.want_resource='energy' THEN buyer.energy:=buyer.energy-o.want_amount; seller.energy:=seller.energy+o.want_amount;
  ELSIF o.want_resource='water' THEN buyer.water:=buyer.water-o.want_amount; seller.water:=seller.water+o.want_amount;
  ELSE buyer.crystal:=buyer.crystal-o.want_amount; seller.crystal:=seller.crystal+o.want_amount;
  END IF;

  IF o.give_resource='metal' THEN buyer.metal:=buyer.metal+o.give_amount;
  ELSIF o.give_resource='energy' THEN buyer.energy:=buyer.energy+o.give_amount;
  ELSIF o.give_resource='water' THEN buyer.water:=buyer.water+o.give_amount;
  ELSE buyer.crystal:=buyer.crystal+o.give_amount;
  END IF;

  UPDATE cities SET metal=seller.metal,energy=seller.energy,water=seller.water,crystal=seller.crystal WHERE id=seller.id;
  UPDATE cities SET metal=buyer.metal,energy=buyer.energy,water=buyer.water,crystal=buyer.crystal WHERE id=buyer.id;
  UPDATE trade_offers SET status='accepted',accepted_by_player_id=p_acceptor_player_id,accepted_at=NOW() WHERE id=o.id;

  INSERT INTO trade_transactions(offer_id,seller_player_id,buyer_player_id,give_resource,give_amount,want_resource,want_amount)
  VALUES(o.id,o.creator_player_id,p_acceptor_player_id,o.give_resource,o.give_amount,o.want_resource,o.want_amount)
  RETURNING * INTO tx;

  RETURN jsonb_build_object('transaction',to_jsonb(tx));
END;
$$;

CREATE OR REPLACE FUNCTION cancel_trade_offer(
  p_offer_id BIGINT,
  p_player_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  o trade_offers%ROWTYPE;
  c cities%ROWTYPE;
BEGIN
  SELECT * INTO o FROM trade_offers WHERE id=p_offer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Teklif bulunamadı.'; END IF;
  IF o.creator_player_id<>p_player_id THEN RAISE EXCEPTION 'Bu teklif sana ait değil.'; END IF;
  IF o.status<>'open' THEN RAISE EXCEPTION 'Bu teklif artık açık değil.'; END IF;

  SELECT * INTO c FROM cities WHERE player_id=p_player_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Koloni bulunamadı.'; END IF;
  IF o.give_resource='metal' THEN c.metal:=c.metal+o.give_amount;
  ELSIF o.give_resource='energy' THEN c.energy:=c.energy+o.give_amount;
  ELSIF o.give_resource='water' THEN c.water:=c.water+o.give_amount;
  ELSE c.crystal:=c.crystal+o.give_amount;
  END IF;
  UPDATE cities SET metal=c.metal,energy=c.energy,water=c.water,crystal=c.crystal WHERE id=c.id;
  UPDATE trade_offers SET status='cancelled' WHERE id=o.id;
  RETURN jsonb_build_object('offer_id',o.id);
END;
$$;
