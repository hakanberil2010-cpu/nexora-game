-- NEXORA - Monster Encounters + Elite/Boss V1
-- Migration 056
--
-- Goals:
-- - Preserve the existing NPC camp / PvE mission / battle / return flow.
-- - Add encounter metadata without renaming or replacing existing PvE tables.
-- - Keep the existing three NPC camps active and unchanged as combat targets.
-- - Add small monsters, strong monsters, elite monsters and large bosses.
-- - Reuse the existing tier 1..10 field as encounter level.
-- - Use short per-player cooldowns for small monsters and long cooldowns for bosses.
-- - Keep all combat power, losses, rewards and survivor returns server-authoritative.
--
-- Apply after 055_achievements_v2.sql.
-- Backend changes are not required for the new metadata because the existing
-- getNpcCamps action forwards nexora_npc_camps_snapshot unchanged.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) ADDITIVE ENCOUNTER METADATA
-- -----------------------------------------------------------------------------

ALTER TABLE public.npc_camps
  ADD COLUMN IF NOT EXISTS encounter_class text NOT NULL DEFAULT 'camp'
  CHECK (encounter_class IN ('camp','small','strong','elite','boss'));

ALTER TABLE public.npc_camps
  ADD COLUMN IF NOT EXISTS icon text NOT NULL DEFAULT '🏕️'
  CHECK (char_length(icon) BETWEEN 1 AND 16);

ALTER TABLE public.npc_camps
  ADD COLUMN IF NOT EXISTS recommended_hq integer NOT NULL DEFAULT 1
  CHECK (recommended_hq BETWEEN 1 AND 30);

-- Existing PvE camps remain camps. No existing world site, state, mission or
-- report row is deleted or rewritten.
UPDATE public.npc_camps
   SET encounter_class = 'camp',
       icon = '🏕️',
       recommended_hq =
         CASE
           WHEN tier <= 1 THEN 1
           WHEN tier = 2 THEN 2
           ELSE 4
         END,
       updated_at = clock_timestamp()
 WHERE world_site_id IN (
   SELECT ws.id
     FROM public.world_sites ws
    WHERE ws.site_type = 'npc_camp'
      AND ws.name IN (
        'Yağmacı Kampı I',
        'Yağmacı Kampı II',
        'Askeri Üs III'
      )
 );

-- -----------------------------------------------------------------------------
-- 2) SEED MONSTER / ELITE / BOSS ENCOUNTERS
--
-- Existing coordinate allocation rules are preserved:
-- - take the same spawn advisory lock used by the current PvE seed,
-- - prefer a designed coordinate,
-- - fall back to the nearest free world coordinate,
-- - never move or overwrite an existing colony / unrelated world site.
--
-- army_template uses the existing combat unit types only as server-side combat
-- stat profiles. Frontend presentation can label these as monster threat roles.
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
          (
            1,
            'easy'::text,
            'small'::text,
            '🐀'::text,
            1,
            'Mutant Sıçan'::text,
            12,
            28,
            '[
              {"unit_type":"piyade","quantity":2,"level":1}
            ]'::jsonb,
            '{"metal":100,"energy":40,"water":40,"crystal":2}'::jsonb,
            90,
            'Koloni çevresinde dolaşan küçük ve zayıf mutant yaratık.'::text
          ),
          (
            1,
            'easy'::text,
            'small'::text,
            '🦂'::text,
            1,
            'Zehirli Akrep'::text,
            28,
            18,
            '[
              {"unit_type":"piyade","quantity":3,"level":1}
            ]'::jsonb,
            '{"metal":120,"energy":40,"water":60,"crystal":2}'::jsonb,
            120,
            'Çöl bölgelerinde görülen küçük ama saldırgan zehirli yaratık.'::text
          ),
          (
            2,
            'easy'::text,
            'small'::text,
            '🐺'::text,
            2,
            'Vahşi Tazı'::text,
            38,
            72,
            '[
              {"unit_type":"piyade","quantity":4,"level":1},
              {"unit_type":"saldiri","quantity":1,"level":1}
            ]'::jsonb,
            '{"metal":200,"energy":70,"water":80,"crystal":5}'::jsonb,
            180,
            'Sürü halinde gezen hızlı bir avcı. Başlangıç orduları için uygun PvE hedefi.'::text
          ),
          (
            3,
            'medium'::text,
            'strong'::text,
            '🪨'::text,
            3,
            'Kaya Yaratığı'::text,
            62,
            22,
            '[
              {"unit_type":"piyade","quantity":4,"level":2},
              {"unit_type":"savunma","quantity":5,"level":2}
            ]'::jsonb,
            '{"metal":400,"energy":150,"water":120,"crystal":10}'::jsonb,
            300,
            'Kalın taş derisi nedeniyle küçük yaratıklardan daha dayanıklı bir tehdit.'::text
          ),
          (
            4,
            'medium'::text,
            'strong'::text,
            '🦎'::text,
            4,
            'Asit Tüküren'::text,
            72,
            68,
            '[
              {"unit_type":"piyade","quantity":6,"level":2},
              {"unit_type":"okcu","quantity":6,"level":2}
            ]'::jsonb,
            '{"metal":650,"energy":240,"water":180,"crystal":20}'::jsonb,
            420,
            'Uzak mesafeden aşındırıcı saldırılar yapan güçlü mutasyona uğramış yaratık.'::text
          ),
          (
            5,
            'medium'::text,
            'strong'::text,
            '⚡'::text,
            5,
            'Plazma Canavarı'::text,
            45,
            82,
            '[
              {"unit_type":"saldiri","quantity":8,"level":2},
              {"unit_type":"okcu","quantity":6,"level":2},
              {"unit_type":"savunma","quantity":5,"level":2}
            ]'::jsonb,
            '{"metal":950,"energy":350,"water":300,"crystal":40}'::jsonb,
            600,
            'Enerji fırtınalarıyla beslenen yüksek hasarlı güçlü yaratık.'::text
          ),
          (
            6,
            'hard'::text,
            'elite'::text,
            '🐅'::text,
            6,
            'Alfa Yırtıcı'::text,
            18,
            78,
            '[
              {"unit_type":"saldiri","quantity":10,"level":3},
              {"unit_type":"okcu","quantity":8,"level":3},
              {"unit_type":"savunma","quantity":8,"level":3}
            ]'::jsonb,
            '{"metal":1400,"energy":550,"water":450,"crystal":70}'::jsonb,
            900,
            'Bölgesindeki yaratıkları yöneten Elite avcı. Hazırlıksız ordular için ölümcüldür.'::text
          ),
          (
            7,
            'hard'::text,
            'elite'::text,
            '🗿'::text,
            7,
            'Zırhlı Dev'::text,
            84,
            72,
            '[
              {"unit_type":"tank","quantity":6,"level":3},
              {"unit_type":"saldiri","quantity":15,"level":3},
              {"unit_type":"savunma","quantity":10,"level":3}
            ]'::jsonb,
            '{"metal":2000,"energy":750,"water":600,"crystal":110}'::jsonb,
            1200,
            'Ağır zırhlı Elite dev. Yüksek savunma ve büyük bir yakın saldırı gücüne sahiptir.'::text
          ),
          (
            9,
            'hard'::text,
            'boss'::text,
            '👹'::text,
            9,
            'Kadim Titan'::text,
            90,
            20,
            '[
              {"unit_type":"tank","quantity":8,"level":5},
              {"unit_type":"savunma","quantity":20,"level":4},
              {"unit_type":"saldiri","quantity":18,"level":4},
              {"unit_type":"okcu","quantity":15,"level":4}
            ]'::jsonb,
            '{"metal":3500,"energy":1200,"water":1000,"crystal":220}'::jsonb,
            2700,
            'Kadim savaş alanlarından uyanmış devasa dünya bossu. Büyük bir ordu önerilir.'::text
          ),
          (
            10,
            'hard'::text,
            'boss'::text,
            '🐉'::text,
            10,
            'Boşluk Ejderi'::text,
            92,
            88,
            '[
              {"unit_type":"hava","quantity":8,"level":5},
              {"unit_type":"tank","quantity":8,"level":5},
              {"unit_type":"saldiri","quantity":22,"level":5},
              {"unit_type":"okcu","quantity":20,"level":5}
            ]'::jsonb,
            '{"metal":5000,"energy":1800,"water":1500,"crystal":350}'::jsonb,
            3600,
            'NEXORA dünyasındaki en tehlikeli büyük bosslardan biri. Seviye 10 PvE son oyun hedefidir.'::text
          )
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
        'Monster encounter seed name conflicts with another world-site type: %',
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
          FROM generate_series(3, 97, 3) AS gx
          CROSS JOIN generate_series(3, 97, 3) AS gy
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
          FROM generate_series(1, 100) AS gx
          CROSS JOIN generate_series(1, 100) AS gy
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
          'Monster encounter için boş dünya koordinatı bulunamadı: %',
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
          'Mevcut monster encounter koordinatı bir koloni ile çakışıyor: %',
          seed.name;
      END IF;

      UPDATE public.world_sites
         SET reward = seed.reward,
             active = true,
             description = seed.description,
             owner_player_id = NULL,
             owner_alliance_id = NULL,
             claimed_at = NULL
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

-- -----------------------------------------------------------------------------
-- 3) SNAPSHOT: PRESERVE OLD FIELDS + APPEND ENCOUNTER METADATA
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_npc_camps_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  SELECT jsonb_build_object(
    'success', true,
    'camps',
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'id', c.id,
            'worldSiteId', s.id,
            'name', s.name,
            'description', s.description,
            'tier', c.tier,
            'level', c.tier,
            'difficulty', c.difficulty,
            'encounterClass', c.encounter_class,
            'icon', c.icon,
            'recommendedHq', c.recommended_hq,
            'isBoss', c.encounter_class = 'boss',
            'coordinateX', s.coordinate_x,
            'coordinateY', s.coordinate_y,
            'armyTemplate', c.army_template,
            'reward', c.reward,
            'cooldownSeconds', c.cooldown_seconds,
            'victories', COALESCE(st.victories, 0),
            'defeats', COALESCE(st.defeats, 0),
            'draws', COALESCE(st.draws, 0),
            'lastBattleAt', st.last_battle_at,
            'availableAt', st.available_at,
            'remainingSeconds',
              GREATEST(
                0,
                CEIL(
                  EXTRACT(
                    EPOCH FROM (
                      COALESCE(st.available_at, 'epoch'::timestamptz)
                      - now()
                    )
                  )
                )::integer
              ),
            'activeMissionId',
              (
                SELECT m.id
                  FROM public.npc_missions m
                 WHERE m.player_id = p_player_id
                   AND m.status IN ('traveling','resolving','returning')
                 ORDER BY m.id DESC
                 LIMIT 1
              ),
            'canAttack',
              COALESCE(st.available_at, 'epoch'::timestamptz) <= now()
              AND NOT EXISTS (
                SELECT 1
                  FROM public.npc_missions m
                 WHERE m.player_id = p_player_id
                   AND m.status IN ('traveling','resolving','returning')
              )
          )
          ORDER BY c.tier, c.id
        ),
        '[]'::jsonb
      )
  )
  FROM public.npc_camps c
  JOIN public.world_sites s
    ON s.id = c.world_site_id
  LEFT JOIN public.player_npc_camp_state st
    ON st.player_id = p_player_id
   AND st.npc_camp_id = c.id
  WHERE c.active = true
    AND s.active = true
    AND s.site_type = 'npc_camp';
$function$;

-- Keep the dedicated PvE snapshot backend-only, matching the existing PvE
-- security boundary.
REVOKE ALL ON FUNCTION
  public.nexora_npc_camps_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.nexora_npc_camps_snapshot(bigint)
  TO service_role;

COMMIT;
