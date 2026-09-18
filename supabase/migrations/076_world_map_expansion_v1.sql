-- NEXORA - World Map Expansion V1
-- Migration 076
--
-- Goals:
-- - Populate the enlarged 7200x4400 world canvas with real playable content.
-- - Add resource, abandoned, alliance and PvE/NPC destinations.
-- - Preserve the canonical 1..100 world coordinate system and all travel/combat math.
-- - Never move/delete existing cities or world sites.
-- - Preserve existing ownership when an idempotent seed row already exists.
-- - Use the same nexora_city_spawn advisory lock as registration/movement seeds.
-- - Keep rewards on canonical resources only: metal, energy, alloy, crystal.
--
-- Apply after 075_performance_indexes_audit.sql.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) RESOURCE / ABANDONED / ALLIANCE WORLD SITES
-- -----------------------------------------------------------------------------

DO $seed$
DECLARE
  seed record;
  v_site public.world_sites%ROWTYPE;
  v_x integer;
  v_y integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('nexora_city_spawn'));

  FOR seed IN
    SELECT *
    FROM (
      VALUES
        ('resource'::text,'Kuzey Metal Sahası'::text,6,20,
          '{"metal":500,"energy":50,"alloy":60,"crystal":8}'::jsonb,
          'Kuzey kuşağında yoğun metal cevheri barındıran açık maden sahası.'::text),
        ('resource','Doğu Enerji Çekirdeği',94,28,
          '{"metal":60,"energy":500,"alloy":70,"crystal":10}'::jsonb,
          'Eski enerji ağının hâlâ çalışan yüksek kapasiteli çekirdeği.'),
        ('resource','Güney Alaşım Deposu',46,94,
          '{"metal":100,"energy":70,"alloy":450,"crystal":12}'::jsonb,
          'Güney hattında unutulmuş büyük bir alaşım stok alanı.'),
        ('resource','Batı Kristal Yarığı',6,72,
          '{"metal":80,"energy":80,"alloy":50,"crystal":200}'::jsonb,
          'Batı uçurumlarında yüzeye çıkan zengin kristal yarığı.'),
        ('resource','Eski Reaktör Alanı',24,8,
          '{"metal":120,"energy":380,"alloy":80,"crystal":15}'::jsonb,
          'Terk edilmiş reaktörlerin hâlâ enerji ürettiği tehlikeli saha.'),
        ('resource','Derin Maden Kompleksi',52,30,
          '{"metal":400,"energy":70,"alloy":250,"crystal":20}'::jsonb,
          'Birden fazla cevher damarına bağlanan yeraltı maden kompleksi.'),
        ('resource','Donmuş Kristal Ocağı',78,8,
          '{"metal":70,"energy":150,"alloy":50,"crystal":180}'::jsonb,
          'Buz tabakasının altında yüksek saflıkta kristal rezervi.'),
        ('resource','Kızıl Alaşım Sahası',88,84,
          '{"metal":180,"energy":90,"alloy":420,"crystal":20}'::jsonb,
          'Volkanik tortuların oluşturduğu yüksek verimli alaşım sahası.'),
        ('resource','Çorak Metal Damarı',32,58,
          '{"metal":520,"energy":40,"alloy":90,"crystal":8}'::jsonb,
          'Çorak bölgede yüzeye yakın geniş metal damarı.'),
        ('resource','Plazma Toplama Noktası',68,58,
          '{"metal":70,"energy":450,"alloy":90,"crystal":70}'::jsonb,
          'Atmosferik plazmayı enerjiye dönüştüren eski toplama istasyonu.'),
        ('resource','Yüksek Dağ Madeni',24,88,
          '{"metal":250,"energy":60,"alloy":300,"crystal":90}'::jsonb,
          'Dağ sırtlarında metal, alaşım ve kristalin birlikte çıkarıldığı maden.'),
        ('resource','Kadim Enerji Kuyusu',96,70,
          '{"metal":60,"energy":520,"alloy":80,"crystal":40}'::jsonb,
          'Kaynağı bilinmeyen sürekli enerji akışı sağlayan kadim kuyu.'),

        ('abandoned','Terk Edilmiş Araştırma Üssü',16,52,
          '{"metal":350,"energy":250,"alloy":200,"crystal":100}'::jsonb,
          'Eski araştırma ekiplerinin geride bıraktığı malzeme ve kristal kalıntıları.'),
        ('abandoned','Çökmüş Sınır Kolonisi',42,8,
          '{"metal":420,"energy":180,"alloy":240,"crystal":70}'::jsonb,
          'Kuzey sınırında yıllar önce boşaltılmış çökmüş koloni kalıntıları.'),
        ('abandoned','Kayıp Madenci Yerleşimi',72,92,
          '{"metal":380,"energy":150,"alloy":300,"crystal":90}'::jsonb,
          'Güney maden hatlarında kaybolmuş eski işçi yerleşimi.'),
        ('abandoned','Sessiz Garnizon',94,52,
          '{"metal":300,"energy":300,"alloy":260,"crystal":80}'::jsonb,
          'Savunma sistemleri susmuş, depoları kısmen dolu eski garnizon.'),

        ('alliance','Kuzeybatı Gözetleme Kalesi',8,8,
          '{}'::jsonb,
          'Kuzeybatı koridorunu izleyen yüksek görüş avantajlı ittifak kalesi.'),
        ('alliance','Kuzeydoğu İttifak Burcu',92,8,
          '{}'::jsonb,
          'Kuzeydoğu hattındaki sefer yollarını kontrol eden stratejik burç.'),
        ('alliance','Güneybatı Savunma Kulesi',8,92,
          '{}'::jsonb,
          'Güneybatı sınırındaki ittifak hareketlerini destekleyen savunma kulesi.'),
        ('alliance','Güneydoğu Komuta Üssü',92,92,
          '{}'::jsonb,
          'Güneydoğu bölgesinde geniş alan kontrolü sağlayan ittifak komuta üssü.')
    ) AS seeds(
      site_type,
      name,
      preferred_x,
      preferred_y,
      reward,
      description
    )
  LOOP
    v_site := NULL;
    v_x := NULL;
    v_y := NULL;

    SELECT *
      INTO v_site
      FROM public.world_sites
     WHERE name = seed.name
     ORDER BY id
     LIMIT 1
     FOR UPDATE;

    IF v_site.id IS NOT NULL
       AND v_site.site_type IS DISTINCT FROM seed.site_type THEN
      RAISE EXCEPTION
        'World expansion seed name conflicts with another world-site type: %',
        seed.name;
    END IF;

    IF v_site.id IS NULL THEN
      v_x := seed.preferred_x;
      v_y := seed.preferred_y;

      IF EXISTS (
        SELECT 1
          FROM public.cities c
         WHERE c.coordinate_x = v_x
           AND c.coordinate_y = v_y
      )
      OR EXISTS (
        SELECT 1
          FROM public.world_sites ws
         WHERE ws.coordinate_x = v_x
           AND ws.coordinate_y = v_y
      ) THEN
        v_x := NULL;
        v_y := NULL;

        SELECT gx, gy
          INTO v_x, v_y
          FROM generate_series(3,97,3) AS gx
          CROSS JOIN generate_series(3,97,3) AS gy
         WHERE NOT EXISTS (
                 SELECT 1
                   FROM public.cities c
                  WHERE c.coordinate_x = gx
                    AND c.coordinate_y = gy
               )
           AND NOT EXISTS (
                 SELECT 1
                   FROM public.world_sites ws
                  WHERE ws.coordinate_x = gx
                    AND ws.coordinate_y = gy
               )
         ORDER BY
           ((gx - seed.preferred_x) * (gx - seed.preferred_x))
           +
           ((gy - seed.preferred_y) * (gy - seed.preferred_y)),
           gx,
           gy
         LIMIT 1;
      END IF;

      IF v_x IS NULL OR v_y IS NULL THEN
        SELECT gx, gy
          INTO v_x, v_y
          FROM generate_series(1,100) AS gx
          CROSS JOIN generate_series(1,100) AS gy
         WHERE NOT EXISTS (
                 SELECT 1
                   FROM public.cities c
                  WHERE c.coordinate_x = gx
                    AND c.coordinate_y = gy
               )
           AND NOT EXISTS (
                 SELECT 1
                   FROM public.world_sites ws
                  WHERE ws.coordinate_x = gx
                    AND ws.coordinate_y = gy
               )
         ORDER BY
           ((gx - seed.preferred_x) * (gx - seed.preferred_x))
           +
           ((gy - seed.preferred_y) * (gy - seed.preferred_y)),
           gx,
           gy
         LIMIT 1;
      END IF;

      IF v_x IS NULL OR v_y IS NULL THEN
        RAISE EXCEPTION
          'World expansion için boş koordinat bulunamadı: %',
          seed.name;
      END IF;

      INSERT INTO public.world_sites(
        site_type,
        name,
        coordinate_x,
        coordinate_y,
        reward,
        active,
        description,
        owner_player_id,
        owner_alliance_id,
        claimed_at
      )
      VALUES(
        seed.site_type,
        seed.name,
        v_x,
        v_y,
        seed.reward,
        true,
        seed.description,
        NULL,
        NULL,
        NULL
      );
    ELSE
      IF EXISTS (
        SELECT 1
          FROM public.cities c
         WHERE c.coordinate_x = v_site.coordinate_x
           AND c.coordinate_y = v_site.coordinate_y
      ) THEN
        RAISE EXCEPTION
          'Mevcut world expansion noktası bir koloni ile çakışıyor: %',
          seed.name;
      END IF;

      UPDATE public.world_sites
         SET reward = seed.reward,
             active = true,
             description = seed.description
       WHERE id = v_site.id;
    END IF;
  END LOOP;
END;
$seed$;

-- -----------------------------------------------------------------------------
-- 2) NEW PVE / NPC ENCOUNTERS
-- -----------------------------------------------------------------------------

DO $seed$
DECLARE
  seed record;
  v_site public.world_sites%ROWTYPE;
  v_x integer;
  v_y integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('nexora_city_spawn'));

  FOR seed IN
    SELECT *
    FROM (
      VALUES
        (1,'easy'::text,'camp'::text,'🏕️'::text,1,
          'Sınır Yağmacıları'::text,8,42,
          '[{"unit_type":"piyade","quantity":5,"level":1},{"unit_type":"savunma","quantity":2,"level":1}]'::jsonb,
          '{"metal":350,"energy":120,"alloy":100,"crystal":10}'::jsonb,
          300,
          'Batı sınır yollarını yağmalayan düşük seviyeli kamp.'::text),

        (2,'medium','camp','🏕️',2,
          'Kara Pazar Üssü',34,34,
          '[{"unit_type":"piyade","quantity":12,"level":1},{"unit_type":"savunma","quantity":6,"level":1},{"unit_type":"saldiri","quantity":4,"level":1},{"unit_type":"okcu","quantity":3,"level":1}]'::jsonb,
          '{"metal":800,"energy":300,"alloy":250,"crystal":35}'::jsonb,
          600,
          'Kaçak kaynak ticaretini koruyan orta seviye silahlı üs.'),

        (3,'hard','camp','🏕️',4,
          'Kızıl Muhafız Üssü',66,38,
          '[{"unit_type":"piyade","quantity":15,"level":2},{"unit_type":"savunma","quantity":10,"level":2},{"unit_type":"saldiri","quantity":10,"level":2},{"unit_type":"okcu","quantity":8,"level":2},{"unit_type":"tank","quantity":2,"level":1}]'::jsonb,
          '{"metal":1600,"energy":700,"alloy":500,"crystal":100}'::jsonb,
          900,
          'Kızıl bölge geçişlerini tutan ağır silahlı ileri garnizon.'),

        (1,'easy','small','🪲',1,
          'Radyoaktif Böcek Sürüsü',8,12,
          '[{"unit_type":"piyade","quantity":2,"level":1}]'::jsonb,
          '{"metal":100,"energy":40,"alloy":40,"crystal":2}'::jsonb,
          90,
          'Kuzeybatı atık sahalarında çoğalan küçük mutant böcek sürüsü.'),

        (2,'easy','small','🐕',2,
          'Gölge Çakal',22,62,
          '[{"unit_type":"piyade","quantity":4,"level":1},{"unit_type":"saldiri","quantity":1,"level":1}]'::jsonb,
          '{"metal":220,"energy":80,"alloy":90,"crystal":6}'::jsonb,
          180,
          'Karanlık vadilerde sürü halinde dolaşan hızlı avcı.'),

        (3,'medium','strong','❄️',3,
          'Buz Avcısı',70,12,
          '[{"unit_type":"piyade","quantity":4,"level":2},{"unit_type":"savunma","quantity":5,"level":2}]'::jsonb,
          '{"metal":420,"energy":160,"alloy":130,"crystal":12}'::jsonb,
          300,
          'Donmuş bölgelerde kalın zırh geliştirmiş dayanıklı yaratık.'),

        (4,'medium','strong','🌩️',4,
          'Fırtına Sürüngeni',92,42,
          '[{"unit_type":"piyade","quantity":6,"level":2},{"unit_type":"okcu","quantity":6,"level":2}]'::jsonb,
          '{"metal":680,"energy":260,"alloy":190,"crystal":22}'::jsonb,
          420,
          'Elektrik yüklü fırtına kuşaklarında yaşayan menzilli tehdit.'),

        (5,'medium','strong','💠',5,
          'Kristal Golem',60,88,
          '[{"unit_type":"saldiri","quantity":8,"level":2},{"unit_type":"okcu","quantity":6,"level":2},{"unit_type":"savunma","quantity":5,"level":2}]'::jsonb,
          '{"metal":1000,"energy":380,"alloy":320,"crystal":45}'::jsonb,
          600,
          'Kristal damarlarından oluşmuş ağır ve yüksek dirençli savaş yaratığı.'),

        (6,'hard','elite','🦖',6,
          'Kızıl Yırtıcı',12,90,
          '[{"unit_type":"saldiri","quantity":10,"level":3},{"unit_type":"okcu","quantity":8,"level":3},{"unit_type":"savunma","quantity":8,"level":3}]'::jsonb,
          '{"metal":1450,"energy":560,"alloy":460,"crystal":75}'::jsonb,
          900,
          'Güneybatı bölgesinin baskın Elite avcısı.'),

        (7,'hard','elite','🤖',7,
          'Mekanik Dev',82,62,
          '[{"unit_type":"tank","quantity":6,"level":3},{"unit_type":"saldiri","quantity":15,"level":3},{"unit_type":"savunma","quantity":10,"level":3}]'::jsonb,
          '{"metal":2050,"energy":780,"alloy":620,"crystal":115}'::jsonb,
          1200,
          'Eski savaş fabrikalarından kalan ağır zırhlı Elite makine.'),

        (8,'hard','elite','👁️',8,
          'Boşluk Avcısı',38,92,
          '[{"unit_type":"tank","quantity":5,"level":4},{"unit_type":"hava","quantity":4,"level":4},{"unit_type":"saldiri","quantity":16,"level":4},{"unit_type":"okcu","quantity":12,"level":4}]'::jsonb,
          '{"metal":2700,"energy":950,"alloy":800,"crystal":160}'::jsonb,
          1800,
          'Boyut çatlaklarının çevresinde görülen yüksek seviyeli Elite avcı.'),

        (8,'hard','boss','🐋',8,
          'Fırtına Leviathanı',96,10,
          '[{"unit_type":"tank","quantity":7,"level":4},{"unit_type":"hava","quantity":6,"level":4},{"unit_type":"savunma","quantity":16,"level":4},{"unit_type":"saldiri","quantity":14,"level":4}]'::jsonb,
          '{"metal":2800,"energy":1050,"alloy":850,"crystal":180}'::jsonb,
          2100,
          'Kuzeydoğu fırtına kuşağında dolaşan devasa dünya bossu.')
    ) AS seeds(
      tier,
      difficulty,
      encounter_class,
      icon,
      recommended_hq,
      name,
      preferred_x,
      preferred_y,
      army_template,
      reward,
      cooldown_seconds,
      description
    )
  LOOP
    v_site := NULL;
    v_x := NULL;
    v_y := NULL;

    SELECT *
      INTO v_site
      FROM public.world_sites
     WHERE name = seed.name
     ORDER BY id
     LIMIT 1
     FOR UPDATE;

    IF v_site.id IS NOT NULL
       AND v_site.site_type IS DISTINCT FROM 'npc_camp' THEN
      RAISE EXCEPTION
        'World expansion NPC seed name conflicts with another world-site type: %',
        seed.name;
    END IF;

    IF v_site.id IS NULL THEN
      v_x := seed.preferred_x;
      v_y := seed.preferred_y;

      IF EXISTS (
        SELECT 1
          FROM public.cities c
         WHERE c.coordinate_x = v_x
           AND c.coordinate_y = v_y
      )
      OR EXISTS (
        SELECT 1
          FROM public.world_sites ws
         WHERE ws.coordinate_x = v_x
           AND ws.coordinate_y = v_y
      ) THEN
        v_x := NULL;
        v_y := NULL;

        SELECT gx, gy
          INTO v_x, v_y
          FROM generate_series(3,97,3) AS gx
          CROSS JOIN generate_series(3,97,3) AS gy
         WHERE NOT EXISTS (
                 SELECT 1
                   FROM public.cities c
                  WHERE c.coordinate_x = gx
                    AND c.coordinate_y = gy
               )
           AND NOT EXISTS (
                 SELECT 1
                   FROM public.world_sites ws
                  WHERE ws.coordinate_x = gx
                    AND ws.coordinate_y = gy
               )
         ORDER BY
           ((gx - seed.preferred_x) * (gx - seed.preferred_x))
           +
           ((gy - seed.preferred_y) * (gy - seed.preferred_y)),
           gx,
           gy
         LIMIT 1;
      END IF;

      IF v_x IS NULL OR v_y IS NULL THEN
        SELECT gx, gy
          INTO v_x, v_y
          FROM generate_series(1,100) AS gx
          CROSS JOIN generate_series(1,100) AS gy
         WHERE NOT EXISTS (
                 SELECT 1
                   FROM public.cities c
                  WHERE c.coordinate_x = gx
                    AND c.coordinate_y = gy
               )
           AND NOT EXISTS (
                 SELECT 1
                   FROM public.world_sites ws
                  WHERE ws.coordinate_x = gx
                    AND ws.coordinate_y = gy
               )
         ORDER BY
           ((gx - seed.preferred_x) * (gx - seed.preferred_x))
           +
           ((gy - seed.preferred_y) * (gy - seed.preferred_y)),
           gx,
           gy
         LIMIT 1;
      END IF;

      IF v_x IS NULL OR v_y IS NULL THEN
        RAISE EXCEPTION
          'World expansion NPC için boş koordinat bulunamadı: %',
          seed.name;
      END IF;

      INSERT INTO public.world_sites(
        site_type,
        name,
        coordinate_x,
        coordinate_y,
        reward,
        active,
        description,
        owner_player_id,
        owner_alliance_id,
        claimed_at
      )
      VALUES(
        'npc_camp',
        seed.name,
        v_x,
        v_y,
        seed.reward,
        true,
        seed.description,
        NULL,
        NULL,
        NULL
      )
      RETURNING * INTO v_site;
    ELSE
      IF EXISTS (
        SELECT 1
          FROM public.cities c
         WHERE c.coordinate_x = v_site.coordinate_x
           AND c.coordinate_y = v_site.coordinate_y
      ) THEN
        RAISE EXCEPTION
          'Mevcut world expansion NPC noktası bir koloni ile çakışıyor: %',
          seed.name;
      END IF;

      UPDATE public.world_sites
         SET reward = seed.reward,
             active = true,
             description = seed.description
       WHERE id = v_site.id
       RETURNING * INTO v_site;
    END IF;

    INSERT INTO public.npc_camps(
      world_site_id,
      tier,
      difficulty,
      army_template,
      reward,
      cooldown_seconds,
      active,
      encounter_class,
      icon,
      recommended_hq,
      updated_at
    )
    VALUES(
      v_site.id,
      seed.tier,
      seed.difficulty,
      seed.army_template,
      seed.reward,
      seed.cooldown_seconds,
      true,
      seed.encounter_class,
      seed.icon,
      seed.recommended_hq,
      clock_timestamp()
    )
    ON CONFLICT (world_site_id)
    DO UPDATE SET
      tier = EXCLUDED.tier,
      difficulty = EXCLUDED.difficulty,
      army_template = EXCLUDED.army_template,
      reward = EXCLUDED.reward,
      cooldown_seconds = EXCLUDED.cooldown_seconds,
      active = true,
      encounter_class = EXCLUDED.encounter_class,
      icon = EXCLUDED.icon,
      recommended_hq = EXCLUDED.recommended_hq,
      updated_at = clock_timestamp();
  END LOOP;
END;
$seed$;

COMMIT;
