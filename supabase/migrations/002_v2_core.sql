-- NEXORA V2 – ekonomi, nüfus, savunma, üretim kuyruğu, zaman ve görev altyapısı

ALTER TABLE cities
  ADD COLUMN IF NOT EXISTS population integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS population_capacity integer NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS army_capacity integer NOT NULL DEFAULT 50,
  ADD COLUMN IF NOT EXISTS metal_capacity integer NOT NULL DEFAULT 5000,
  ADD COLUMN IF NOT EXISTS energy_capacity integer NOT NULL DEFAULT 5000,
  ADD COLUMN IF NOT EXISTS water_capacity integer NOT NULL DEFAULT 5000,
  ADD COLUMN IF NOT EXISTS crystal_capacity integer NOT NULL DEFAULT 3000,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT NOW();


-- Mevcut kolonilerin depo kapasitelerini V2 varsayılanlarına senkronize eder.
UPDATE cities
SET metal_capacity = COALESCE(NULLIF(metal_capacity, 0), 5000),
    energy_capacity = COALESCE(NULLIF(energy_capacity, 0), 5000),
    water_capacity = COALESCE(NULLIF(water_capacity, 0), 5000),
    crystal_capacity = COALESCE(NULLIF(crystal_capacity, 0), 3000),
    metal = LEAST(GREATEST(COALESCE(metal, 0), 0), COALESCE(NULLIF(metal_capacity, 0), 5000)),
    energy = LEAST(GREATEST(COALESCE(energy, 0), 0), COALESCE(NULLIF(energy_capacity, 0), 5000)),
    water = LEAST(GREATEST(COALESCE(water, 0), 0), COALESCE(NULLIF(water_capacity, 0), 5000)),
    crystal = LEAST(GREATEST(COALESCE(crystal, 0), 0), COALESCE(NULLIF(crystal_capacity, 0), 3000));

ALTER TABLE buildings
  ADD COLUMN IF NOT EXISTS upgrade_ready_at timestamptz,
  ADD COLUMN IF NOT EXISTS is_under_construction boolean NOT NULL DEFAULT false;

ALTER TABLE research
  ADD COLUMN IF NOT EXISTS upgrade_ready_at timestamptz,
  ADD COLUMN IF NOT EXISTS pending_column text;

ALTER TABLE units
  ADD COLUMN IF NOT EXISTS population_cost integer NOT NULL DEFAULT 1;

CREATE TABLE IF NOT EXISTS unit_production_queue (
  id BIGSERIAL PRIMARY KEY,
  player_id BIGINT NOT NULL,
  city_id BIGINT NOT NULL,
  unit_type TEXT NOT NULL,
  quantity integer NOT NULL DEFAULT 1,
  started_at timestamptz NOT NULL DEFAULT NOW(),
  finish_at timestamptz NOT NULL,
  status TEXT NOT NULL DEFAULT 'training',
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_unit_levels_type_level ON unit_levels(unit_type, level);

CREATE INDEX IF NOT EXISTS idx_unit_production_queue_player_status
  ON unit_production_queue(player_id, status, finish_at);

CREATE INDEX IF NOT EXISTS idx_unit_production_queue_city_status
  ON unit_production_queue(city_id, status, finish_at);

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

ALTER TABLE military_missions
  ADD COLUMN IF NOT EXISTS completed_at timestamptz;

ALTER TABLE military_missions
  ADD COLUMN IF NOT EXISTS depart_x integer;
ALTER TABLE military_missions
  ADD COLUMN IF NOT EXISTS depart_y integer;
ALTER TABLE military_missions
  ADD COLUMN IF NOT EXISTS target_x integer;
ALTER TABLE military_missions
  ADD COLUMN IF NOT EXISTS target_y integer;
ALTER TABLE military_missions
  ADD COLUMN IF NOT EXISTS travel_seconds integer;
ALTER TABLE military_missions
  ADD COLUMN IF NOT EXISTS fleet_speed numeric;

-- Yeni savunma / ekonomi binalarını kullanabilmek için şablon kayıtlarını zorunlu kılmıyoruz.
-- Bina seviyesi backend tarafından yoksa 1 kabul edilir.

-- V2 için tek ve yetkili birlik seviye tablosu: 6 birlik x 15 seviye.
DO $$
DECLARE
  lvl integer;
  base record;
BEGIN
  FOR base IN SELECT * FROM (VALUES
    ('piyade',100,100,100,100),
    ('savunma',70,140,120,90),
    ('saldiri',150,70,100,110),
    ('okcu',85,55,90,125),
    ('tank',210,220,300,55),
    ('hava',180,120,180,150)
  ) AS t(unit_type,attack,defense,hp,speed) LOOP
    FOR lvl IN 1..15 LOOP
      INSERT INTO unit_levels(unit_type,level,attack,defense,hp,speed)
      VALUES (base.unit_type,lvl,ROUND(base.attack*POWER(1.08,lvl-1))::int,ROUND(base.defense*POWER(1.08,lvl-1))::int,ROUND(base.hp*POWER(1.07,lvl-1))::int,ROUND(base.speed*POWER(1.02,lvl-1))::int)
      ON CONFLICT (unit_type,level) DO UPDATE SET attack=EXCLUDED.attack,defense=EXCLUDED.defense,hp=EXCLUDED.hp,speed=EXCLUDED.speed;
    END LOOP;
  END LOOP;
END $$;

-- Eski birliklerin nüfus maliyeti.
UPDATE units SET population_cost = 1 WHERE unit_type IN ('piyade','savunma','saldiri');
UPDATE units SET population_cost = 1 WHERE unit_type = 'okcu';
UPDATE units SET population_cost = 3 WHERE unit_type = 'tank';
UPDATE units SET population_cost = 2 WHERE unit_type = 'hava';

-- Başlangıç nüfusu mevcut ordu üzerinden senkronize eder.
UPDATE cities c
SET population = COALESCE((
  SELECT SUM(COALESCE(u.quantity,0) * COALESCE(u.population_cost,1))
  FROM units u WHERE u.city_id = c.id
),0);

-- Eski sürümdeki menzilli adı V2'de okcu olarak standardize edilir.
UPDATE units u SET unit_type='okcu'
WHERE u.unit_type='menzilli'
  AND NOT EXISTS (SELECT 1 FROM units x WHERE x.city_id=u.city_id AND x.unit_type='okcu');

-- Mevcut birlik istatistikleri yetkili unit_levels tablosuyla eşitlenir.
UPDATE units AS u
SET level=GREATEST(1,LEAST(15,COALESCE(u.level,1))),
    attack=ul.attack, defense=ul.defense, hp=ul.hp, speed=ul.speed
FROM unit_levels AS ul
WHERE ul.unit_type=u.unit_type AND ul.level=GREATEST(1,LEAST(15,COALESCE(u.level,1)));
