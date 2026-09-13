-- NEXORA Phase 11.1 – Alliance Territory Seeds
-- Adds real alliance territory points to the existing world map.
-- Safe/idempotent: does not overwrite existing sites or coordinates.
-- Apply after 021_phase11_alliance_territory.sql.

BEGIN;

INSERT INTO public.world_sites(
  site_type,
  name,
  coordinate_x,
  coordinate_y,
  reward,
  active,
  description
)
SELECT
  'alliance',
  'Batı Sınır Karakolu',
  10,
  60,
  '{}'::jsonb,
  true,
  'İttifakların keşfedip kontrol altına alabileceği stratejik batı karakolu.'
WHERE NOT EXISTS (
  SELECT 1 FROM public.world_sites
   WHERE name = 'Batı Sınır Karakolu'
      OR (coordinate_x = 10 AND coordinate_y = 60)
);

INSERT INTO public.world_sites(
  site_type,
  name,
  coordinate_x,
  coordinate_y,
  reward,
  active,
  description
)
SELECT
  'alliance',
  'Kuzey İttifak Kalesi',
  55,
  10,
  '{}'::jsonb,
  true,
  'Kuzey hattını kontrol eden stratejik ittifak kalesi.'
WHERE NOT EXISTS (
  SELECT 1 FROM public.world_sites
   WHERE name = 'Kuzey İttifak Kalesi'
      OR (coordinate_x = 55 AND coordinate_y = 10)
);

INSERT INTO public.world_sites(
  site_type,
  name,
  coordinate_x,
  coordinate_y,
  reward,
  active,
  description
)
SELECT
  'alliance',
  'Güney Muhafız Geçidi',
  55,
  90,
  '{}'::jsonb,
  true,
  'Güney bölgesine açılan ittifak kontrol noktası.'
WHERE NOT EXISTS (
  SELECT 1 FROM public.world_sites
   WHERE name = 'Güney Muhafız Geçidi'
      OR (coordinate_x = 55 AND coordinate_y = 90)
);

INSERT INTO public.world_sites(
  site_type,
  name,
  coordinate_x,
  coordinate_y,
  reward,
  active,
  description
)
SELECT
  'alliance',
  'Doğu Savunma Üssü',
  90,
  58,
  '{}'::jsonb,
  true,
  'Doğu bölgesindeki ittifaklar için stratejik savunma üssü.'
WHERE NOT EXISTS (
  SELECT 1 FROM public.world_sites
   WHERE name = 'Doğu Savunma Üssü'
      OR (coordinate_x = 90 AND coordinate_y = 58)
);

COMMIT;
