-- NEXORA - Beginner Guide V1
-- Migration 040
--
-- Goals:
-- - Add a lightweight, ordered beginner guide without duplicating mission rewards.
-- - Keep guide progress server-authoritative and monotonic.
-- - Reuse existing canonical gameplay state wherever possible.
-- - Treat an NPC-camp victory as the final tutorial milestone.
-- - Preserve the existing missions/achievements response and append only a
--   top-level "guide" object to nexora_refresh_achievements().
--
-- Apply after 039_pve_npc_camps_v1.sql.
-- Backend changes are intentionally not required by this migration.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) PLAYER GUIDE STATE
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.player_beginner_guide_state (
  player_id bigint PRIMARY KEY
    REFERENCES public.players(id) ON DELETE CASCADE,
  completed_step integer NOT NULL DEFAULT 0
    CHECK (completed_step BETWEEN 0 AND 6),
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

ALTER TABLE public.player_beginner_guide_state ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.player_beginner_guide_state
  FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.player_beginner_guide_state
  TO service_role;

-- -----------------------------------------------------------------------------
-- 2) SERVER-AUTHORITATIVE STEP PROGRESS
--
-- Step 4 intentionally accepts historical proof that the player previously had
-- an army of at least 10 units. This prevents a completed tutorial step from
-- being missed merely because troops were deployed or later lost before the
-- guide snapshot refreshed.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_beginner_guide_step_progress(
  p_player_id bigint,
  p_step integer
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_value bigint := 0;
  v_current_units bigint := 0;
  v_pvp_mission_max bigint := 0;
  v_pve_mission_max bigint := 0;
BEGIN
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR p_step IS NULL
     OR p_step < 1
     OR p_step > 6 THEN
    RETURN 0;
  END IF;

  CASE p_step
    WHEN 1 THEN
      SELECT COALESCE(MAX(GREATEST(COALESCE(b.level, 0), 0)), 0)::bigint
        INTO v_value
        FROM public.buildings b
        JOIN public.cities c ON c.id = b.city_id
       WHERE c.player_id = p_player_id
         AND b.building_type = 'Merkez Bina';

    WHEN 2 THEN
      SELECT COALESCE(MAX(GREATEST(COALESCE(b.level, 0), 0)), 0)::bigint
        INTO v_value
        FROM public.buildings b
        JOIN public.cities c ON c.id = b.city_id
       WHERE c.player_id = p_player_id
         AND b.building_type IN (
           'Metal Madeni',
           'Enerji Santrali',
           'Su Arıtma',
           'Kristal Madeni'
         );

    WHEN 3 THEN
      SELECT
        (
          CASE
            WHEN COALESCE(MAX(b.level) FILTER (
              WHERE b.building_type = 'Kışla'
            ), 0) >= 1
            THEN 1
            ELSE 0
          END
          +
          CASE
            WHEN COALESCE(MAX(b.level) FILTER (
              WHERE b.building_type = 'Konut'
            ), 0) >= 1
            THEN 1
            ELSE 0
          END
        )::bigint
        INTO v_value
        FROM public.buildings b
        JOIN public.cities c ON c.id = b.city_id
       WHERE c.player_id = p_player_id
         AND b.building_type IN ('Kışla', 'Konut');

    WHEN 4 THEN
      v_current_units :=
        public.nexora_progress_value(p_player_id, 'unit_count');

      IF EXISTS (
        SELECT 1
          FROM public.player_mission_claims c
         WHERE c.player_id = p_player_id
           AND c.mission_id = 'army_10'
      ) THEN
        v_current_units := GREATEST(v_current_units, 10);
      END IF;

      SELECT COALESCE(MAX(x.total_units), 0)::bigint
        INTO v_pvp_mission_max
        FROM (
          SELECT
            m.id,
            COALESCE(
              SUM(
                CASE
                  WHEN COALESCE(e.unit->>'quantity', '') ~ '^[0-9]+$'
                  THEN GREATEST((e.unit->>'quantity')::bigint, 0)
                  ELSE 0
                END
              ),
              0
            )::bigint AS total_units
          FROM public.military_missions m
          CROSS JOIN LATERAL
            jsonb_array_elements(COALESCE(m.army, '[]'::jsonb))
            AS e(unit)
          WHERE m.attacker_player_id = p_player_id
          GROUP BY m.id
        ) AS x;

      SELECT COALESCE(MAX(x.total_units), 0)::bigint
        INTO v_pve_mission_max
        FROM (
          SELECT
            m.id,
            COALESCE(
              SUM(
                CASE
                  WHEN COALESCE(e.unit->>'quantity', '') ~ '^[0-9]+$'
                  THEN GREATEST((e.unit->>'quantity')::bigint, 0)
                  ELSE 0
                END
              ),
              0
            )::bigint AS total_units
          FROM public.npc_missions m
          CROSS JOIN LATERAL
            jsonb_array_elements(COALESCE(m.army, '[]'::jsonb))
            AS e(unit)
          WHERE m.player_id = p_player_id
          GROUP BY m.id
        ) AS x;

      v_value := GREATEST(
        COALESCE(v_current_units, 0),
        COALESCE(v_pvp_mission_max, 0),
        COALESCE(v_pve_mission_max, 0)
      );

    WHEN 5 THEN
      v_value :=
        public.nexora_progress_value(p_player_id, 'research_levels');

    WHEN 6 THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.npc_battle_reports r
       WHERE r.player_id = p_player_id
         AND r.result = 'Zafer';

    ELSE
      v_value := 0;
  END CASE;

  RETURN GREATEST(COALESCE(v_value, 0), 0);
END;
$function$;

-- -----------------------------------------------------------------------------
-- 3) READ-ONLY GUIDE SNAPSHOT
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_beginner_guide_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_completed_step integer := 0;
  v_completed_at timestamptz;
  v_current_step integer;
  v_progress bigint := 0;
  v_target bigint := 1;
  v_key text;
  v_title text;
  v_description text;
  v_icon text;
  v_action text;
  v_action_label text;
  v_current jsonb := NULL;
BEGIN
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR NOT EXISTS (
       SELECT 1
         FROM public.players p
        WHERE p.id = p_player_id
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  SELECT
    COALESCE(s.completed_step, 0),
    s.completed_at
    INTO v_completed_step, v_completed_at
    FROM public.player_beginner_guide_state s
   WHERE s.player_id = p_player_id;

  v_completed_step :=
    GREATEST(0, LEAST(6, COALESCE(v_completed_step, 0)));

  IF v_completed_step < 6 THEN
    v_current_step := v_completed_step + 1;
    v_progress :=
      public.nexora_beginner_guide_step_progress(
        p_player_id,
        v_current_step
      );

    CASE v_current_step
      WHEN 1 THEN
        v_key := 'hq_level_2';
        v_title := 'Komuta Merkezi';
        v_description := 'Merkez Bina seviyesini 2 yap.';
        v_icon := '🏛️';
        v_target := 2;
        v_action := 'game.html';
        v_action_label := '🏙️ Kolonide Geliştir';

      WHEN 2 THEN
        v_key := 'production_level_2';
        v_title := 'Üretimi Güçlendir';
        v_description :=
          'Metal, Enerji, Su veya Kristal üretim binalarından en az birini seviye 2 yap.';
        v_icon := '⚙️';
        v_target := 2;
        v_action := 'game.html';
        v_action_label := '⚙️ Üretim Binasına Git';

      WHEN 3 THEN
        v_key := 'army_infrastructure';
        v_title := 'Ordu Altyapısı';
        v_description := 'Kışla seviye 1 ve Konut seviye 1 sahibi ol.';
        v_icon := '🏠';
        v_target := 2;
        v_action := 'game.html';
        v_action_label := '🏗️ Yapıları Kur';

      WHEN 4 THEN
        v_key := 'army_10';
        v_title := 'İlk Birliklerin';
        v_description := 'Toplam 10 birlik oluştur.';
        v_icon := '🪖';
        v_target := 10;
        v_action := 'army.html';
        v_action_label := '🪖 Orduya Git';

      WHEN 5 THEN
        v_key := 'research_1';
        v_title := 'Araştırmaya Başla';
        v_description := 'En az 1 araştırma seviyesi tamamla.';
        v_icon := '🔬';
        v_target := 1;
        v_action := 'research.html';
        v_action_label := '🔬 Araştırmaya Git';

      WHEN 6 THEN
        v_key := 'npc_victory_1';
        v_title := 'İlk PvE Zaferin';
        v_description := 'Dünya Haritasındaki bir NPC kampını yen.';
        v_icon := '🏕️';
        v_target := 1;
        v_action := 'world.html';
        v_action_label := '🌍 Dünya Haritasına Git';
    END CASE;

    v_current := jsonb_build_object(
      'key', v_key,
      'order', v_current_step,
      'title', v_title,
      'description', v_description,
      'icon', v_icon,
      'progress', LEAST(GREATEST(COALESCE(v_progress, 0), 0), v_target),
      'target', v_target,
      'action', v_action,
      'actionLabel', v_action_label
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'completed', v_completed_step >= 6,
    'completedStep', v_completed_step,
    'totalSteps', 6,
    'completedAt', v_completed_at,
    'currentStep', v_current
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 4) MONOTONIC GUIDE REFRESH
--
-- Progress can only move forward. Repeated polling does not write unless a new
-- step is actually completed.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_refresh_beginner_guide(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_stored_step integer := 0;
  v_completed_step integer := 0;
  v_next_step integer;
  v_progress bigint;
  v_target bigint;
  v_existing_completed_at timestamptz;
BEGIN
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR NOT EXISTS (
       SELECT 1
         FROM public.players p
        WHERE p.id = p_player_id
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  INSERT INTO public.player_beginner_guide_state(
    player_id,
    completed_step,
    created_at,
    updated_at
  )
  VALUES(
    p_player_id,
    0,
    clock_timestamp(),
    clock_timestamp()
  )
  ON CONFLICT (player_id) DO NOTHING;

  SELECT
    COALESCE(s.completed_step, 0),
    s.completed_at
    INTO v_stored_step, v_existing_completed_at
    FROM public.player_beginner_guide_state s
   WHERE s.player_id = p_player_id;

  v_stored_step :=
    GREATEST(0, LEAST(6, COALESCE(v_stored_step, 0)));
  v_completed_step := v_stored_step;

  WHILE v_completed_step < 6 LOOP
    v_next_step := v_completed_step + 1;

    v_target :=
      CASE v_next_step
        WHEN 1 THEN 2
        WHEN 2 THEN 2
        WHEN 3 THEN 2
        WHEN 4 THEN 10
        WHEN 5 THEN 1
        WHEN 6 THEN 1
        ELSE 1
      END;

    v_progress :=
      public.nexora_beginner_guide_step_progress(
        p_player_id,
        v_next_step
      );

    EXIT WHEN COALESCE(v_progress, 0) < v_target;

    v_completed_step := v_next_step;
  END LOOP;

  IF v_completed_step > v_stored_step
     OR (
       v_completed_step >= 6
       AND v_existing_completed_at IS NULL
     ) THEN
    UPDATE public.player_beginner_guide_state
       SET completed_step = GREATEST(completed_step, v_completed_step),
           completed_at =
             CASE
               WHEN GREATEST(completed_step, v_completed_step) >= 6
               THEN COALESCE(completed_at, clock_timestamp())
               ELSE completed_at
             END,
           updated_at = clock_timestamp()
     WHERE player_id = p_player_id;
  END IF;

  RETURN public.nexora_beginner_guide_snapshot(p_player_id);
END;
$function$;

-- -----------------------------------------------------------------------------
-- 5) APPEND GUIDE TO THE EXISTING GAME-OBJECTIVES SNAPSHOT
--
-- Existing missions, achievements and metrics are preserved exactly. The only
-- response-shape addition is the top-level "guide" property.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_refresh_achievements(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_guide jsonb;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0
     OR NOT EXISTS (
       SELECT 1
         FROM public.players p
        WHERE p.id = p_player_id
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  INSERT INTO public.player_achievements(
    player_id,
    achievement_id,
    unlocked_at
  )
  SELECT
    p_player_id,
    a.id,
    now()
    FROM public.game_achievements a
   WHERE a.active IS TRUE
     AND public.nexora_progress_value(
       p_player_id,
       a.metric_key
     ) >= a.target_value
  ON CONFLICT (player_id, achievement_id) DO NOTHING;

  v_guide :=
    public.nexora_refresh_beginner_guide(p_player_id);

  RETURN
    public.nexora_missions_snapshot(p_player_id)
    ||
    jsonb_build_object(
      'guide',
      v_guide
    );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 6) FUNCTION PERMISSIONS
-- -----------------------------------------------------------------------------

REVOKE ALL ON FUNCTION
  public.nexora_beginner_guide_step_progress(bigint, integer)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  public.nexora_beginner_guide_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  public.nexora_refresh_beginner_guide(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.nexora_beginner_guide_step_progress(bigint, integer)
  TO service_role;

GRANT EXECUTE ON FUNCTION
  public.nexora_beginner_guide_snapshot(bigint)
  TO service_role;

GRANT EXECUTE ON FUNCTION
  public.nexora_refresh_beginner_guide(bigint)
  TO service_role;

GRANT EXECUTE ON FUNCTION
  public.nexora_refresh_achievements(bigint)
  TO service_role;

COMMIT;
