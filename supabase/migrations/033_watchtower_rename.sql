-- NEXORA - Rename legacy defense tower to watchtower
-- Existing building level / construction state is preserved.
-- Run after 032_multi_building_slots.sql and the matching backend deployment.

BEGIN;

-- Safety guard: if a city somehow already has both names in the same slot,
-- stop without changing anything so no building state can be lost.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.buildings legacy
    JOIN public.buildings watch
      ON watch.city_id = legacy.city_id
     AND COALESCE(watch.slot, 1) = COALESCE(legacy.slot, 1)
     AND watch.building_type = 'Gözcü Kulesi'
    WHERE legacy.building_type = 'Savunma Kulesi'
  ) THEN
    RAISE EXCEPTION 'Aynı kolonide hem Savunma Kulesi hem Gözcü Kulesi bulundu; otomatik dönüşüm durduruldu.';
  END IF;
END $$;

UPDATE public.buildings
SET building_type = 'Gözcü Kulesi'
WHERE building_type = 'Savunma Kulesi';

-- Verify the legacy name is fully gone.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.buildings
    WHERE building_type = 'Savunma Kulesi'
  ) THEN
    RAISE EXCEPTION 'Savunma Kulesi dönüşümü tamamlanamadı.';
  END IF;
END $$;

COMMIT;
