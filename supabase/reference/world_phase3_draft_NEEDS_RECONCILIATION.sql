-- NEXORA PHASE 3 – DÜNYA SİSTEMİ
-- Oyuncu kolonileri mevcut cities tablosundan gelir.
-- Yeni sistem: nötr bölgeler, kaynak bölgeleri, terk edilmiş koloniler,
-- keşif görevleri ve ileride kullanılacak ittifak bölgeleri.

CREATE TABLE IF NOT EXISTS world_sites (
  id BIGSERIAL PRIMARY KEY,
  site_type TEXT NOT NULL CHECK (site_type IN ('neutral','resource','abandoned','alliance')),
  name TEXT NOT NULL,
  coordinate_x INTEGER NOT NULL CHECK (coordinate_x BETWEEN 1 AND 100),
  coordinate_y INTEGER NOT NULL CHECK (coordinate_y BETWEEN 1 AND 100),
  description TEXT,
  reward_metal INTEGER NOT NULL DEFAULT 0,
  reward_energy INTEGER NOT NULL DEFAULT 0,
  reward_water INTEGER NOT NULL DEFAULT 0,
  reward_crystal INTEGER NOT NULL DEFAULT 0,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_world_sites_type_active ON world_sites(site_type, active);
CREATE INDEX IF NOT EXISTS idx_world_sites_coordinates ON world_sites(coordinate_x, coordinate_y);

CREATE TABLE IF NOT EXISTS world_exploration_missions (
  id BIGSERIAL PRIMARY KEY,
  player_id BIGINT NOT NULL,
  city_id BIGINT NOT NULL,
  site_id BIGINT NOT NULL REFERENCES world_sites(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'traveling' CHECK (status IN ('traveling','resolving','completed')),
  depart_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  arrive_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ,
  distance NUMERIC NOT NULL DEFAULT 0,
  travel_seconds INTEGER NOT NULL DEFAULT 0,
  result JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_world_explore_player_status
  ON world_exploration_missions(player_id, status, arrive_at);

CREATE INDEX IF NOT EXISTS idx_world_explore_city_status
  ON world_exploration_missions(city_id, status, arrive_at);

-- Oyuncu başına keşif bekleme zamanı. Başlangıçta boş bırakılır.
ALTER TABLE cities ADD COLUMN IF NOT EXISTS last_exploration_at TIMESTAMPTZ;

-- Önceden eklenmiş aynı isimli kayıtları tekrar çoğaltmamak için kontrollü seed.
INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,reward_metal,reward_energy,reward_water,reward_crystal)
SELECT 'neutral','Sisli Geçit',12,22,'Tehlikesiz fakat keşfedilmemiş bir geçit.',0,0,0,0
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='Sisli Geçit');
INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,reward_metal,reward_energy,reward_water,reward_crystal)
SELECT 'neutral','Kadim Harabeler',38,16,'Eski uygarlığın izlerini taşıyan nötr bölge.',0,0,0,0
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='Kadim Harabeler');
INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,reward_metal,reward_energy,reward_water,reward_crystal)
SELECT 'neutral','Kristal Geçidi',73,28,'Kayalıkların arasında stratejik bir geçit.',0,0,0,0
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='Kristal Geçidi');
INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,reward_metal,reward_energy,reward_water,reward_crystal)
SELECT 'neutral','Sessiz Vadi',22,72,'Haritada boş görünen sakin bir vadi.',0,0,0,0
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='Sessiz Vadi');

INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,reward_metal,reward_energy,reward_water,reward_crystal)
SELECT 'resource','Metal Sahası',19,38,'Zengin metal damarları bulunan kaynak bölgesi.',1200,0,0,0
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='Metal Sahası');
INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,reward_metal,reward_energy,reward_water,reward_crystal)
SELECT 'resource','Enerji Alanı',58,18,'Yoğun enerji akımlarının bulunduğu bölge.',0,1000,0,0
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='Enerji Alanı');
INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,reward_metal,reward_energy,reward_water,reward_crystal)
SELECT 'resource','Su Kaynağı',83,57,'Yeraltı su rezervleri bakımından zengin alan.',0,0,1200,0
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='Su Kaynağı');
INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,reward_metal,reward_energy,reward_water,reward_crystal)
SELECT 'resource','Kristal Yatağı',67,76,'Nadir kristallerin bulunduğu kaynak bölgesi.',0,0,0,700
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='Kristal Yatağı');

INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,reward_metal,reward_energy,reward_water,reward_crystal)
SELECT 'abandoned','Terk Edilmiş Koloni Alpha',31,29,'Eski bir koloninin terk edilmiş kalıntıları.',1800,900,700,350
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='Terk Edilmiş Koloni Alpha');
INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,reward_metal,reward_energy,reward_water,reward_crystal)
SELECT 'abandoned','Terk Edilmiş Koloni Beta',76,44,'Savunması çökmüş eski bir yerleşim.',2200,1100,500,450
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='Terk Edilmiş Koloni Beta');
INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,reward_metal,reward_energy,reward_water,reward_crystal)
SELECT 'abandoned','Terk Edilmiş Koloni Gamma',47,67,'Eski lojistik merkezinin kalıntıları.',1400,1500,900,250
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='Terk Edilmiş Koloni Gamma');

-- İleride ittifak sistemi için ayrılmış bölgeler. Şimdilik pasif.
INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,active)
SELECT 'alliance','İttifak Bölgesi Kuzey',50,8,'İttifak kontrol sistemi ileride burada aktif edilecek.',FALSE
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='İttifak Bölgesi Kuzey');
INSERT INTO world_sites (site_type,name,coordinate_x,coordinate_y,description,active)
SELECT 'alliance','İttifak Bölgesi Güney',54,92,'İttifak kontrol sistemi ileride burada aktif edilecek.',FALSE
WHERE NOT EXISTS (SELECT 1 FROM world_sites WHERE name='İttifak Bölgesi Güney');
