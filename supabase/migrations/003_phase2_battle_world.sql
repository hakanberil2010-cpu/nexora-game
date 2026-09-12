-- NEXORA PHASE 2 – gelişmiş savaş, sıralama, dünya keşfi ve bina ön koşulları
-- Bu dosya mevcut V2 şemasının ÜZERİNE uygulanır.

ALTER TABLE battle_reports
  ADD COLUMN IF NOT EXISTS battle_points integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS winner_player_id bigint;

CREATE INDEX IF NOT EXISTS idx_battle_reports_attacker_created
  ON battle_reports(attacker_player_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_battle_reports_defender_created
  ON battle_reports(defender_player_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_battle_reports_winner
  ON battle_reports(winner_player_id);

ALTER TABLE cities
  ADD COLUMN IF NOT EXISTS last_explored_at timestamptz;

CREATE TABLE IF NOT EXISTS world_sites (
  id BIGSERIAL PRIMARY KEY,
  site_type text NOT NULL,
  name text NOT NULL,
  coordinate_x integer NOT NULL CHECK (coordinate_x BETWEEN 1 AND 100),
  coordinate_y integer NOT NULL CHECK (coordinate_y BETWEEN 1 AND 100),
  reward JSONB NOT NULL DEFAULT '{}'::jsonb,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_world_sites_coordinates
  ON world_sites(coordinate_x, coordinate_y);

INSERT INTO world_sites(site_type,name,coordinate_x,coordinate_y,reward)
VALUES
 ('resource','Metal Harabeleri',12,25,'{"metal":450,"energy":40,"water":20,"crystal":5}'::jsonb),
 ('resource','Orman Kaynağı',38,18,'{"metal":60,"energy":30,"water":400,"crystal":10}'::jsonb),
 ('resource','Buz Enerji İstasyonu',84,20,'{"metal":50,"energy":450,"water":80,"crystal":10}'::jsonb),
 ('resource','Dağ Kristal Damari',28,76,'{"metal":80,"energy":80,"water":40,"crystal":180}'::jsonb),
 ('abandoned','Terk Edilmiş Koloni',62,38,'{"metal":300,"energy":180,"water":180,"crystal":80}'::jsonb),
 ('resource','Volkanik Maden',76,78,'{"metal":180,"energy":100,"water":20,"crystal":220}'::jsonb)
ON CONFLICT (coordinate_x, coordinate_y) DO NOTHING;

-- Bina ön koşulları backend tarafından uygulanır:
-- Kristal Madeni: Merkez Bina 2
-- Kristal Deposu: Merkez Bina 2
-- Kışla: Merkez Bina 2
-- Konut: Merkez Bina 2
-- Sur: Merkez Bina 3
-- Savunma Kulesi: Merkez Bina 5 + Sur 2

-- Birlik seviye tablosu değişmez: 6 birlik x 15 seviye.
-- Birlik geliştirme maliyeti mevcut seviye ile çarpılır.
