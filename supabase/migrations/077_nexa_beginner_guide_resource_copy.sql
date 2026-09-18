-- NEXORA 077 Beginner Guide Resource Copy
-- Replaces the last stale Water reference in the beginner guide copy.
-- Gameplay logic, progress rules, actions, rewards, and resource schema are unchanged.

CREATE OR REPLACE FUNCTION public.nexora_beginner_guide_snapshot(p_player_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
          'Metal, Enerji, Alaşım veya Kristal üretim binalarından en az birini seviye 2 yap.';
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
