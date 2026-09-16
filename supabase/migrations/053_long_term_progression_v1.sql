-- NEXORA - Long Term Progression V1
-- Migration 053
--
-- Goals:
-- - Add a 30-stage long-term progression path after the Beginner Guide.
-- - Keep progression server-authoritative and sequential.
-- - Reuse existing canonical gameplay data instead of trusting client counters.
-- - Preserve existing missions, achievements, guide and daily mission contracts.
-- - Make progression rewards atomic, idempotent and storage-capacity aware.
--
-- Apply after 052_session_security_v2.sql.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) PROGRESSION DEFINITIONS + PLAYER CLAIMS
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.game_progression_missions (
  id text PRIMARY KEY,
  stage_order integer NOT NULL UNIQUE CHECK (stage_order > 0),
  chapter integer NOT NULL CHECK (chapter > 0),
  chapter_title text NOT NULL,
  title text NOT NULL,
  description text NOT NULL,
  icon text NOT NULL DEFAULT '🎯',
  metric_key text NOT NULL,
  target_value bigint NOT NULL CHECK (target_value > 0),
  reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(reward) = 'object'),
  action text,
  action_label text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS public.player_progression_claims (
  player_id bigint NOT NULL
    REFERENCES public.players(id) ON DELETE CASCADE,
  mission_id text NOT NULL
    REFERENCES public.game_progression_missions(id) ON DELETE RESTRICT,
  claimed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reward jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(reward) = 'object'),
  PRIMARY KEY (player_id, mission_id)
);

INSERT INTO public.game_progression_missions (
  id,
  stage_order,
  chapter,
  chapter_title,
  title,
  description,
  icon,
  metric_key,
  target_value,
  reward,
  action,
  action_label,
  active
)
VALUES
  ('path_01_hq_3', 1, 1, 'Koloniyi Kur', 'Güçlenen Merkez', 'Merkez Bina seviyesini 3 yap.', '🏛️', 'hq_level', 3, '{"metal":600,"energy":300,"water":200,"crystal":50}'::jsonb, 'game.html', '🏙️ Koloniyi Geliştir', true),
  ('path_02_buildings_15', 2, 1, 'Koloniyi Kur', 'Sağlam Temeller', 'Toplam bina seviyelerinde 15 seviyeye ulaş.', '🏗️', 'building_levels', 15, '{"metal":700,"energy":300,"water":300,"crystal":50}'::jsonb, 'game.html', '🏗️ Binaları Geliştir', true),
  ('path_03_research_3', 3, 1, 'Koloniyi Kur', 'Bilgi Birikimi', 'Toplam 3 araştırma seviyesine ulaş.', '🔬', 'research_levels', 3, '{"metal":300,"energy":600,"water":250,"crystal":100}'::jsonb, 'research.html', '🔬 Araştırmaya Git', true),
  ('path_04_train_25', 4, 1, 'Koloniyi Kur', 'İlk Kuvvet', 'Toplam 25 birlik eğitimine başla.', '🪖', 'units_trained', 25, '{"metal":800,"energy":350,"water":250,"crystal":75}'::jsonb, 'army.html', '🪖 Orduya Git', true),
  ('path_05_explore_2', 5, 1, 'Koloniyi Kur', 'Sınırların Ötesi', 'Toplam 2 dünya keşfini tamamla.', '🧭', 'explorations_completed', 2, '{"metal":400,"energy":300,"water":700,"crystal":100}'::jsonb, 'world.html', '🌍 Dünya Haritasına Git', true),
  ('path_06_wins_2', 6, 1, 'Koloniyi Kur', 'Sahada Başarı', 'NPC veya oyuncu savaşlarında toplam 2 zafer kazan.', '⚔️', 'battle_wins_total', 2, '{"metal":900,"energy":450,"water":300,"crystal":125}'::jsonb, 'world.html', '⚔️ Savaşa Hazırlan', true),

  ('path_07_hq_4', 7, 2, 'Gücü Büyüt', 'Koloni Seviye 4', 'Merkez Bina seviyesini 4 yap.', '🏛️', 'hq_level', 4, '{"metal":1000,"energy":500,"water":350,"crystal":125}'::jsonb, 'game.html', '🏙️ Koloniyi Geliştir', true),
  ('path_08_buildings_25', 8, 2, 'Gücü Büyüt', 'Büyüyen Şehir', 'Toplam bina seviyelerinde 25 seviyeye ulaş.', '🏗️', 'building_levels', 25, '{"metal":1100,"energy":500,"water":500,"crystal":150}'::jsonb, 'game.html', '🏗️ Binaları Geliştir', true),
  ('path_09_research_5', 9, 2, 'Gücü Büyüt', 'Araştırma Ağı', 'Toplam 5 araştırma seviyesine ulaş.', '🔬', 'research_levels', 5, '{"metal":500,"energy":1000,"water":450,"crystal":175}'::jsonb, 'research.html', '🔬 Araştırmaya Git', true),
  ('path_10_train_50', 10, 2, 'Gücü Büyüt', 'Düzenli Ordu', 'Toplam 50 birlik eğitimine başla.', '🪖', 'units_trained', 50, '{"metal":1200,"energy":550,"water":400,"crystal":150}'::jsonb, 'army.html', '🪖 Orduya Git', true),
  ('path_11_wins_5', 11, 2, 'Gücü Büyüt', 'Savaş Deneyimi', 'NPC veya oyuncu savaşlarında toplam 5 zafer kazan.', '⚔️', 'battle_wins_total', 5, '{"metal":1300,"energy":600,"water":450,"crystal":200}'::jsonb, 'world.html', '⚔️ Savaşa Hazırlan', true),
  ('path_12_social_1', 12, 2, 'Gücü Büyüt', 'Bağlantı Kur', 'Bir ittifaka katıl veya en az 1 ticareti başarıyla tamamla.', '🤝', 'social_link', 1, '{"metal":1000,"energy":700,"water":700,"crystal":225}'::jsonb, 'alliance.html', '🤝 İttifaklara Git', true),

  ('path_13_hq_5', 13, 3, 'Bölgesel Güç', 'Koloni Seviye 5', 'Merkez Bina seviyesini 5 yap.', '🏛️', 'hq_level', 5, '{"metal":1500,"energy":750,"water":500,"crystal":225}'::jsonb, 'game.html', '🏙️ Koloniyi Geliştir', true),
  ('path_14_buildings_40', 14, 3, 'Bölgesel Güç', 'Gelişmiş Altyapı', 'Toplam bina seviyelerinde 40 seviyeye ulaş.', '🏗️', 'building_levels', 40, '{"metal":1700,"energy":800,"water":800,"crystal":250}'::jsonb, 'game.html', '🏗️ Binaları Geliştir', true),
  ('path_15_research_8', 15, 3, 'Bölgesel Güç', 'Teknolojik İlerleme', 'Toplam 8 araştırma seviyesine ulaş.', '🔬', 'research_levels', 8, '{"metal":800,"energy":1600,"water":700,"crystal":300}'::jsonb, 'research.html', '🔬 Araştırmaya Git', true),
  ('path_16_train_100', 16, 3, 'Bölgesel Güç', 'Yüz Birlik', 'Toplam 100 birlik eğitimine başla.', '🪖', 'units_trained', 100, '{"metal":1900,"energy":900,"water":650,"crystal":275}'::jsonb, 'army.html', '🪖 Orduya Git', true),
  ('path_17_explore_5', 17, 3, 'Bölgesel Güç', 'Deneyimli Kaşif', 'Toplam 5 dünya keşfini tamamla.', '🧭', 'explorations_completed', 5, '{"metal":1100,"energy":700,"water":1700,"crystal":300}'::jsonb, 'world.html', '🌍 Dünya Haritasına Git', true),
  ('path_18_wins_10', 18, 3, 'Bölgesel Güç', 'On Zafer', 'NPC veya oyuncu savaşlarında toplam 10 zafer kazan.', '⚔️', 'battle_wins_total', 10, '{"metal":2100,"energy":1000,"water":750,"crystal":350}'::jsonb, 'world.html', '⚔️ Savaşa Hazırlan', true),

  ('path_19_hq_6', 19, 4, 'Komutanlık', 'Koloni Seviye 6', 'Merkez Bina seviyesini 6 yap.', '🏛️', 'hq_level', 6, '{"metal":2500,"energy":1200,"water":900,"crystal":350}'::jsonb, 'game.html', '🏙️ Koloniyi Geliştir', true),
  ('path_20_buildings_60', 20, 4, 'Komutanlık', 'Büyük Koloni', 'Toplam bina seviyelerinde 60 seviyeye ulaş.', '🏗️', 'building_levels', 60, '{"metal":2800,"energy":1300,"water":1300,"crystal":400}'::jsonb, 'game.html', '🏗️ Binaları Geliştir', true),
  ('path_21_research_12', 21, 4, 'Komutanlık', 'Araştırma Üssü', 'Toplam 12 araştırma seviyesine ulaş.', '🔬', 'research_levels', 12, '{"metal":1300,"energy":2700,"water":1100,"crystal":450}'::jsonb, 'research.html', '🔬 Araştırmaya Git', true),
  ('path_22_train_200', 22, 4, 'Komutanlık', 'Savaş Makinesi', 'Toplam 200 birlik eğitimine başla.', '🪖', 'units_trained', 200, '{"metal":3200,"energy":1500,"water":1100,"crystal":425}'::jsonb, 'army.html', '🪖 Orduya Git', true),
  ('path_23_wins_20', 23, 4, 'Komutanlık', 'Tecrübeli Komutan', 'NPC veya oyuncu savaşlarında toplam 20 zafer kazan.', '⚔️', 'battle_wins_total', 20, '{"metal":3500,"energy":1700,"water":1200,"crystal":500}'::jsonb, 'world.html', '⚔️ Savaşa Hazırlan', true),
  ('path_24_site_1', 24, 4, 'Komutanlık', 'Stratejik Hakimiyet', 'En az 1 stratejik dünya noktasını kontrol et.', '🏳️', 'strategic_sites', 1, '{"metal":3000,"energy":1800,"water":1500,"crystal":550}'::jsonb, 'world.html', '🌍 Stratejik Noktalara Git', true),

  ('path_25_hq_8', 25, 5, 'NEXORA Hakimiyeti', 'Koloni Seviye 8', 'Merkez Bina seviyesini 8 yap.', '🏛️', 'hq_level', 8, '{"metal":4000,"energy":2000,"water":1500,"crystal":600}'::jsonb, 'game.html', '🏙️ Koloniyi Geliştir', true),
  ('path_26_buildings_80', 26, 5, 'NEXORA Hakimiyeti', 'Metropol', 'Toplam bina seviyelerinde 80 seviyeye ulaş.', '🏗️', 'building_levels', 80, '{"metal":4500,"energy":2200,"water":2200,"crystal":650}'::jsonb, 'game.html', '🏗️ Binaları Geliştir', true),
  ('path_27_research_18', 27, 5, 'NEXORA Hakimiyeti', 'İleri Teknoloji', 'Toplam 18 araştırma seviyesine ulaş.', '🔬', 'research_levels', 18, '{"metal":2200,"energy":4300,"water":1800,"crystal":700}'::jsonb, 'research.html', '🔬 Araştırmaya Git', true),
  ('path_28_train_350', 28, 5, 'NEXORA Hakimiyeti', 'Büyük Ordu', 'Toplam 350 birlik eğitimine başla.', '🪖', 'units_trained', 350, '{"metal":5000,"energy":2500,"water":1800,"crystal":750}'::jsonb, 'army.html', '🪖 Orduya Git', true),
  ('path_29_wins_35', 29, 5, 'NEXORA Hakimiyeti', 'Savaş Ustası', 'NPC veya oyuncu savaşlarında toplam 35 zafer kazan.', '⚔️', 'battle_wins_total', 35, '{"metal":5500,"energy":2700,"water":2000,"crystal":850}'::jsonb, 'world.html', '⚔️ Savaşa Hazırlan', true),
  ('path_30_commander', 30, 5, 'NEXORA Hakimiyeti', 'NEXORA Komutanı', 'Merkez Bina 10, toplam 100 bina seviyesi, 20 araştırma seviyesi, 500 eğitim ve 50 toplam savaş zaferine ulaş.', '👑', 'commander_milestone', 1, '{"metal":7000,"energy":3500,"water":3000,"crystal":1000}'::jsonb, 'game.html', '👑 Son Hedefe İlerle', true)
ON CONFLICT (id) DO UPDATE SET
  stage_order = EXCLUDED.stage_order,
  chapter = EXCLUDED.chapter,
  chapter_title = EXCLUDED.chapter_title,
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  icon = EXCLUDED.icon,
  metric_key = EXCLUDED.metric_key,
  target_value = EXCLUDED.target_value,
  reward = EXCLUDED.reward,
  action = EXCLUDED.action,
  action_label = EXCLUDED.action_label,
  active = EXCLUDED.active;

-- -----------------------------------------------------------------------------
-- 2) SERVER-AUTHORITATIVE PROGRESSION METRICS
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_progression_value(
  p_player_id bigint,
  p_metric_key text
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_value bigint := 0;
  v_hq bigint := 0;
  v_buildings bigint := 0;
  v_research bigint := 0;
  v_units_trained bigint := 0;
  v_battle_wins bigint := 0;
BEGIN
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR p_metric_key IS NULL
     OR btrim(p_metric_key) = '' THEN
    RETURN 0;
  END IF;

  CASE p_metric_key
    WHEN 'hq_level' THEN
      v_value := public.nexora_progress_value(p_player_id, 'hq_level');

    WHEN 'building_levels' THEN
      v_value := public.nexora_progress_value(p_player_id, 'building_levels');

    WHEN 'research_levels' THEN
      v_value := public.nexora_progress_value(p_player_id, 'research_levels');

    WHEN 'explorations_completed' THEN
      v_value := public.nexora_progress_value(p_player_id, 'explorations_completed');

    WHEN 'strategic_sites' THEN
      v_value := public.nexora_progress_value(p_player_id, 'strategic_sites');

    WHEN 'units_trained' THEN
      SELECT COALESCE(
               SUM(GREATEST(COALESCE(q.quantity, 0), 0)),
               0
             )::bigint
        INTO v_value
        FROM public.unit_production_queue q
       WHERE q.player_id = p_player_id;

    WHEN 'battle_wins_total' THEN
      SELECT (
        public.nexora_progress_value(p_player_id, 'battles_won')
        +
        COALESCE((
          SELECT COUNT(*)::bigint
            FROM public.npc_battle_reports r
           WHERE r.player_id = p_player_id
             AND r.result = 'Zafer'
        ), 0)
      )::bigint
        INTO v_value;

    WHEN 'social_link' THEN
      SELECT CASE
        WHEN EXISTS (
          SELECT 1
            FROM public.alliance_members a
           WHERE a.player_id = p_player_id
        )
        OR EXISTS (
          SELECT 1
            FROM public.trade_offers t
           WHERE t.status = 'accepted'
             AND (
               t.creator_player_id = p_player_id
               OR t.accepted_by_player_id = p_player_id
             )
        )
        THEN 1::bigint
        ELSE 0::bigint
      END
        INTO v_value;

    WHEN 'commander_milestone' THEN
      v_hq := public.nexora_progress_value(p_player_id, 'hq_level');
      v_buildings := public.nexora_progress_value(p_player_id, 'building_levels');
      v_research := public.nexora_progress_value(p_player_id, 'research_levels');

      SELECT COALESCE(
               SUM(GREATEST(COALESCE(q.quantity, 0), 0)),
               0
             )::bigint
        INTO v_units_trained
        FROM public.unit_production_queue q
       WHERE q.player_id = p_player_id;

      SELECT (
        public.nexora_progress_value(p_player_id, 'battles_won')
        +
        COALESCE((
          SELECT COUNT(*)::bigint
            FROM public.npc_battle_reports r
           WHERE r.player_id = p_player_id
             AND r.result = 'Zafer'
        ), 0)
      )::bigint
        INTO v_battle_wins;

      v_value := CASE
        WHEN v_hq >= 10
         AND v_buildings >= 100
         AND v_research >= 20
         AND v_units_trained >= 500
         AND v_battle_wins >= 50
        THEN 1
        ELSE 0
      END;

    ELSE
      v_value := 0;
  END CASE;

  RETURN GREATEST(COALESCE(v_value, 0), 0);
END;
$function$;

-- -----------------------------------------------------------------------------
-- 3) READ-ONLY LONG-TERM PROGRESSION SNAPSHOT
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_progression_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_unlocked boolean := false;
  v_total integer := 0;
  v_claimed integer := 0;
  v_current public.game_progression_missions%ROWTYPE;
  v_progress bigint := 0;
  v_current_json jsonb := NULL;
  v_next_steps jsonb := '[]'::jsonb;
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

  SELECT EXISTS (
    SELECT 1
      FROM public.player_beginner_guide_state s
     WHERE s.player_id = p_player_id
       AND s.completed_step >= 6
  )
    INTO v_unlocked;

  SELECT COUNT(*)::integer
    INTO v_total
    FROM public.game_progression_missions m
   WHERE m.active IS TRUE;

  SELECT COUNT(*)::integer
    INTO v_claimed
    FROM public.player_progression_claims c
    JOIN public.game_progression_missions m
      ON m.id = c.mission_id
   WHERE c.player_id = p_player_id
     AND m.active IS TRUE;

  SELECT m.*
    INTO v_current
    FROM public.game_progression_missions m
   WHERE m.active IS TRUE
     AND NOT EXISTS (
       SELECT 1
         FROM public.player_progression_claims c
        WHERE c.player_id = p_player_id
          AND c.mission_id = m.id
     )
   ORDER BY m.stage_order, m.id
   LIMIT 1;

  IF FOUND THEN
    v_progress := public.nexora_progression_value(
      p_player_id,
      v_current.metric_key
    );

    v_current_json := jsonb_build_object(
      'id', v_current.id,
      'order', v_current.stage_order,
      'chapter', v_current.chapter,
      'chapterTitle', v_current.chapter_title,
      'title', v_current.title,
      'description', v_current.description,
      'icon', v_current.icon,
      'metricKey', v_current.metric_key,
      'progress', LEAST(v_progress, v_current.target_value),
      'target', v_current.target_value,
      'completed', v_progress >= v_current.target_value,
      'claimable', v_unlocked AND v_progress >= v_current.target_value,
      'reward', v_current.reward,
      'action', v_current.action,
      'actionLabel', v_current.action_label
    );

    SELECT COALESCE(
             jsonb_agg(
               jsonb_build_object(
                 'id', n.id,
                 'order', n.stage_order,
                 'chapter', n.chapter,
                 'chapterTitle', n.chapter_title,
                 'title', n.title,
                 'icon', n.icon
               )
               ORDER BY n.stage_order, n.id
             ),
             '[]'::jsonb
           )
      INTO v_next_steps
      FROM (
        SELECT m.*
          FROM public.game_progression_missions m
         WHERE m.active IS TRUE
           AND m.stage_order > v_current.stage_order
         ORDER BY m.stage_order, m.id
         LIMIT 2
      ) n;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'unlocked', v_unlocked,
    'completed', v_total > 0 AND v_claimed >= v_total,
    'claimedCount', v_claimed,
    'totalStages', v_total,
    'currentStep', v_current_json,
    'nextSteps', v_next_steps
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 4) ATOMIC, SEQUENTIAL PROGRESSION REWARD CLAIM
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.nexora_claim_progression_mission(
  p_player_id bigint,
  p_mission_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_mission public.game_progression_missions%ROWTYPE;
  v_current public.game_progression_missions%ROWTYPE;
  v_city public.cities%ROWTYPE;
  v_guide jsonb;
  v_progress bigint := 0;
  v_reward jsonb;

  v_depo_level bigint := 0;
  v_crystal_depo_level bigint := 0;
  v_storage bigint := 5000;
  v_crystal_storage bigint := 3000;

  v_reward_metal bigint := 0;
  v_reward_energy bigint := 0;
  v_reward_water bigint := 0;
  v_reward_crystal bigint := 0;

  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_water bigint := 0;
  v_credit_crystal bigint := 0;
  v_credited jsonb;
BEGIN
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR p_mission_id IS NULL
     OR btrim(p_mission_id) = '' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz ilerleme görevi isteği.'
    );
  END IF;

  PERFORM id
    FROM public.players
   WHERE id = p_player_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  SELECT *
    INTO v_mission
    FROM public.game_progression_missions m
   WHERE m.id = p_mission_id
     AND m.active IS TRUE
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PROGRESSION_MISSION_NOT_FOUND',
      'message', 'İlerleme görevi bulunamadı.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.player_progression_claims c
     WHERE c.player_id = p_player_id
       AND c.mission_id = v_mission.id
  ) THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu ilerleme görevi ödülü zaten alındı.',
      'snapshot', public.nexora_progression_snapshot(p_player_id)
    );
  END IF;

  v_guide := public.nexora_refresh_beginner_guide(p_player_id);

  IF COALESCE((v_guide ->> 'completed')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PROGRESSION_LOCKED',
      'message', 'Uzun vadeli ilerleme yolu Başlangıç Rehberi tamamlanınca açılır.',
      'snapshot', public.nexora_progression_snapshot(p_player_id)
    );
  END IF;

  SELECT m.*
    INTO v_current
    FROM public.game_progression_missions m
   WHERE m.active IS TRUE
     AND NOT EXISTS (
       SELECT 1
         FROM public.player_progression_claims c
        WHERE c.player_id = p_player_id
          AND c.mission_id = m.id
     )
   ORDER BY m.stage_order, m.id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PROGRESSION_COMPLETE',
      'message', 'Uzun vadeli ilerleme yolunun tüm aşamaları tamamlandı.',
      'snapshot', public.nexora_progression_snapshot(p_player_id)
    );
  END IF;

  IF v_current.id <> v_mission.id THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PROGRESSION_STAGE_LOCKED',
      'message', 'Önce mevcut ilerleme aşamasını tamamlamalısın.',
      'snapshot', public.nexora_progression_snapshot(p_player_id)
    );
  END IF;

  v_progress := public.nexora_progression_value(
    p_player_id,
    v_mission.metric_key
  );

  IF v_progress < v_mission.target_value THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PROGRESSION_MISSION_INCOMPLETE',
      'message', 'İlerleme görevi henüz tamamlanmadı.',
      'progress', LEAST(v_progress, v_mission.target_value),
      'target', v_mission.target_value
    );
  END IF;

  SELECT *
    INTO v_city
    FROM public.cities c
   WHERE c.player_id = p_player_id
   ORDER BY c.id
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CITY_NOT_FOUND',
      'message', 'Koloni bulunamadı.'
    );
  END IF;

  SELECT
    COALESCE(
      SUM(GREATEST(COALESCE(b.level, 0), 0))
        FILTER (WHERE b.building_type = 'Depo'),
      0
    )::bigint,
    COALESCE(
      SUM(GREATEST(COALESCE(b.level, 0), 0))
        FILTER (WHERE b.building_type = 'Kristal Deposu'),
      0
    )::bigint
    INTO v_depo_level, v_crystal_depo_level
    FROM public.buildings b
   WHERE b.city_id = v_city.id;

  v_storage := 5000 + GREATEST(v_depo_level, 0) * 2500;
  v_crystal_storage := 3000 + GREATEST(v_crystal_depo_level, 0) * 1500;

  v_reward := COALESCE(v_mission.reward, '{}'::jsonb);

  v_reward_metal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'metal', '')::bigint, 0));
  v_reward_energy :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'energy', '')::bigint, 0));
  v_reward_water :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'water', '')::bigint, 0));
  v_reward_crystal :=
    GREATEST(0, COALESCE(NULLIF(v_reward ->> 'crystal', '')::bigint, 0));

  v_credit_metal := LEAST(
    v_reward_metal,
    GREATEST(0, v_storage - GREATEST(COALESCE(v_city.metal, 0), 0))
  );
  v_credit_energy := LEAST(
    v_reward_energy,
    GREATEST(0, v_storage - GREATEST(COALESCE(v_city.energy, 0), 0))
  );
  v_credit_water := LEAST(
    v_reward_water,
    GREATEST(0, v_storage - GREATEST(COALESCE(v_city.water, 0), 0))
  );
  v_credit_crystal := LEAST(
    v_reward_crystal,
    GREATEST(0, v_crystal_storage - GREATEST(COALESCE(v_city.crystal, 0), 0))
  );

  UPDATE public.cities
     SET metal = GREATEST(COALESCE(metal, 0), 0) + v_credit_metal,
         energy = GREATEST(COALESCE(energy, 0), 0) + v_credit_energy,
         water = GREATEST(COALESCE(water, 0), 0) + v_credit_water,
         crystal = GREATEST(COALESCE(crystal, 0), 0) + v_credit_crystal,
         metal_capacity = v_storage,
         energy_capacity = v_storage,
         water_capacity = v_storage,
         crystal_capacity = v_crystal_storage,
         updated_at = clock_timestamp()
   WHERE id = v_city.id;

  v_credited := jsonb_build_object(
    'metal', v_credit_metal,
    'energy', v_credit_energy,
    'water', v_credit_water,
    'crystal', v_credit_crystal
  );

  INSERT INTO public.player_progression_claims(
    player_id,
    mission_id,
    claimed_at,
    reward
  )
  VALUES(
    p_player_id,
    v_mission.id,
    clock_timestamp(),
    v_credited
  );

  RETURN jsonb_build_object(
    'success', true,
    'alreadyClaimed', false,
    'message', 'İlerleme görevi ödülü alındı.',
    'rewardConfigured', v_reward,
    'rewardCredited', v_credited,
    'snapshot', public.nexora_progression_snapshot(p_player_id)
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 5) APPEND PROGRESSION TO THE EXISTING GAME-OBJECTIVES SNAPSHOT
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
  v_daily jsonb;
  v_progression jsonb;
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

  v_guide := public.nexora_refresh_beginner_guide(p_player_id);
  v_daily := public.nexora_daily_missions_snapshot(p_player_id);
  v_progression := public.nexora_progression_snapshot(p_player_id);

  RETURN
    public.nexora_missions_snapshot(p_player_id)
    ||
    jsonb_build_object(
      'guide', v_guide,
      'daily', v_daily,
      'progression', v_progression
    );
END;
$function$;

-- -----------------------------------------------------------------------------
-- 6) SECURITY
-- -----------------------------------------------------------------------------

ALTER TABLE public.game_progression_missions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_progression_claims ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.game_progression_missions
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.player_progression_claims
  FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.game_progression_missions
  TO service_role;
GRANT ALL ON TABLE public.player_progression_claims
  TO service_role;

REVOKE ALL ON FUNCTION
  public.nexora_progression_value(bigint, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.nexora_progression_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.nexora_claim_progression_mission(bigint, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.nexora_refresh_achievements(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.nexora_progression_value(bigint, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.nexora_progression_snapshot(bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.nexora_claim_progression_mission(bigint, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.nexora_refresh_achievements(bigint)
  TO service_role;

COMMIT;
