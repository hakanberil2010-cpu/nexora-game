-- NEXORA FINAL SYSTEM MIGRATION
-- 1) Ekonomi / kapasite / nüfus / zaman
ALTER TABLE cities
  ADD COLUMN IF NOT EXISTS population integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS population_capacity integer DEFAULT 20,
  ADD COLUMN IF NOT EXISTS metal_capacity integer DEFAULT 5000,
  ADD COLUMN IF NOT EXISTS energy_capacity integer DEFAULT 5000,
  ADD COLUMN IF NOT EXISTS water_capacity integer DEFAULT 5000,
  ADD COLUMN IF NOT EXISTS crystal_capacity integer DEFAULT 2500,
  ADD COLUMN IF NOT EXISTS last_production_at timestamptz DEFAULT NOW(),
  ADD COLUMN IF NOT EXISTS coordinate_x integer DEFAULT 25,
  ADD COLUMN IF NOT EXISTS coordinate_y integer DEFAULT 35;

ALTER TABLE buildings
  ADD COLUMN IF NOT EXISTS upgrade_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS upgrade_finished_at timestamptz;

ALTER TABLE research
  ADD COLUMN IF NOT EXISTS general_power_level integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS unit_attack_level integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS unit_defense_level integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS unit_hp_level integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS travel_speed_level integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS combat_level integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS defense_level integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS production_level integer DEFAULT 0,
  ADD COLUMN IF NOT EXISTS crystal_level integer DEFAULT 0;

ALTER TABLE units
  ADD COLUMN IF NOT EXISTS level integer DEFAULT 1,
  ADD COLUMN IF NOT EXISTS attack integer DEFAULT 100,
  ADD COLUMN IF NOT EXISTS defense integer DEFAULT 100,
  ADD COLUMN IF NOT EXISTS hp integer DEFAULT 100,
  ADD COLUMN IF NOT EXISTS speed integer DEFAULT 100;

-- 2) Bina yükseltme kuyruğu
CREATE TABLE IF NOT EXISTS construction_queue (
  id BIGSERIAL PRIMARY KEY,
  city_id BIGINT NOT NULL,
  building_type TEXT NOT NULL,
  from_level INTEGER NOT NULL,
  to_level INTEGER NOT NULL,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_construction_city_status
  ON construction_queue(city_id, finished_at);

-- 3) Asker üretim kuyruğu
CREATE TABLE IF NOT EXISTS army_queue (
  id BIGSERIAL PRIMARY KEY,
  city_id BIGINT NOT NULL,
  unit_type TEXT NOT NULL,
  quantity INTEGER NOT NULL DEFAULT 1,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_army_queue_city ON army_queue(city_id, finished_at);

-- 4) Araştırma kuyruğu
CREATE TABLE IF NOT EXISTS research_queue (
  id BIGSERIAL PRIMARY KEY,
  player_id BIGINT NOT NULL,
  research_type TEXT NOT NULL,
  from_level INTEGER NOT NULL,
  to_level INTEGER NOT NULL,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_research_queue_player
  ON research_queue(player_id, finished_at);

-- 5) Gerçek zamanlı seferler
CREATE TABLE IF NOT EXISTS military_missions (
  id BIGSERIAL PRIMARY KEY,
  attacker_player_id BIGINT NOT NULL,
  defender_player_id BIGINT NOT NULL,
  attacker_city_id BIGINT NOT NULL,
  defender_city_id BIGINT NOT NULL,
  mission_type TEXT NOT NULL DEFAULT 'attack',
  status TEXT NOT NULL DEFAULT 'traveling',
  depart_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  arrive_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ,
  attack_power INTEGER DEFAULT 0,
  army JSONB NOT NULL DEFAULT '[]'::jsonb,
  result JSONB
);
CREATE INDEX IF NOT EXISTS idx_missions_attacker ON military_missions(attacker_player_id, status);
CREATE INDEX IF NOT EXISTS idx_missions_defender ON military_missions(defender_player_id, status);

-- 6) Sıralama için savaş puanı ve skor yardımcı tablosu
CREATE TABLE IF NOT EXISTS player_scores (
  player_id BIGINT PRIMARY KEY,
  score INTEGER DEFAULT 0,
  battle_points INTEGER DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 7) Yeni birlik türleri için temel seviye kayıtları
CREATE TABLE IF NOT EXISTS unit_levels (
  id BIGSERIAL PRIMARY KEY,
  unit_type TEXT NOT NULL,
  level INTEGER NOT NULL,
  attack INTEGER NOT NULL,
  defense INTEGER NOT NULL,
  hp INTEGER NOT NULL,
  speed INTEGER NOT NULL,
  UNIQUE(unit_type, level)
);

INSERT INTO unit_levels(unit_type, level, attack, defense, hp, speed) VALUES
('menzilli',1,180,70,90,105),
('tank',1,260,220,260,55),
('hava',1,220,100,130,160)
ON CONFLICT (unit_type, level) DO NOTHING;

-- Yeni birliklerin 2-15 seviyeleri için %8 seviye artışı
INSERT INTO unit_levels(unit_type, level, attack, defense, hp, speed)
SELECT base.unit_type,
       lvl,
       ROUND(base.attack * POWER(1.08, lvl-1))::int,
       ROUND(base.defense * POWER(1.08, lvl-1))::int,
       ROUND(base.hp * POWER(1.07, lvl-1))::int,
       ROUND(base.speed * POWER(1.02, lvl-1))::int
FROM (VALUES
  ('menzilli',180,70,90,105),
  ('tank',260,220,260,55),
  ('hava',220,100,130,160)
) AS base(unit_type,attack,defense,hp,speed)
CROSS JOIN generate_series(2,15) AS lvl
ON CONFLICT (unit_type, level) DO NOTHING;

-- Mevcut şehirler için başlangıç değerlerini doldur
UPDATE cities
SET population_capacity = COALESCE(NULLIF(population_capacity,0),20),
    metal_capacity = COALESCE(NULLIF(metal_capacity,0),5000),
    energy_capacity = COALESCE(NULLIF(energy_capacity,0),5000),
    water_capacity = COALESCE(NULLIF(water_capacity,0),5000),
    crystal_capacity = COALESCE(NULLIF(crystal_capacity,0),2500),
    last_production_at = COALESCE(last_production_at, NOW());

-- Birliklerde 0/NULL statüleri varsa seviye tablosundan doldur
UPDATE units AS u
SET level = COALESCE(u.level,1),
    attack = COALESCE(NULLIF(u.attack,0), ul.attack),
    defense = COALESCE(NULLIF(u.defense,0), ul.defense),
    hp = COALESCE(NULLIF(u.hp,0), ul.hp),
    speed = COALESCE(NULLIF(u.speed,0), ul.speed)
FROM unit_levels AS ul
WHERE ul.unit_type = u.unit_type
  AND ul.level = COALESCE(u.level,1);
