-- NEXORA - Alliance Missions V1
-- Migration 057
--
-- Goals:
-- - Add weekly cooperative alliance missions without changing existing alliance,
--   war, territory or membership contracts.
-- - Reset every Monday 00:00 Europe/Istanbul.
-- - Count only authoritative gameplay records created after the member joined
--   the current alliance and inside the current week.
-- - Expose per-member contribution breakdown.
-- - Unlock one shared weekly chest after all four core goals are complete.
-- - Allow each current alliance member to claim that chest once per week.
-- - Keep rewards atomic, idempotent and city-capacity aware.
--
-- Apply after 056_monster_encounters_elite_boss_v1.sql.
-- Backend/frontend integration is intentionally NOT part of this migration.

BEGIN;

CREATE TABLE IF NOT EXISTS public.game_alliance_missions (
  id text PRIMARY KEY,
  title text NOT NULL,
  description text NOT NULL,
  metric_key text NOT NULL,
  target_value bigint NOT NULL CHECK (target_value > 0),
  sort_order integer NOT NULL DEFAULT 0,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS public.player_alliance_mission_chest_claims (
  player_id bigint NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  alliance_id bigint NOT NULL REFERENCES public.alliances(id) ON DELETE CASCADE,
  week_start date NOT NULL,
  claimed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reward jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(reward) = 'object'),
  PRIMARY KEY (player_id, alliance_id, week_start)
);

CREATE INDEX IF NOT EXISTS idx_alliance_mission_chest_claims_alliance_week
  ON public.player_alliance_mission_chest_claims(
    alliance_id,
    week_start DESC,
    claimed_at DESC
  );

ALTER TABLE public.game_alliance_missions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_alliance_mission_chest_claims ENABLE ROW LEVEL SECURITY;

INSERT INTO public.game_alliance_missions
  (id,title,description,metric_key,target_value,sort_order,active)
VALUES
  (
    'alliance_train_100',
    '🪖 Ortak Seferberlik',
    'İttifak üyeleri bu hafta toplam 100 birlik eğitimine başlasın.',
    'units_training_started',
    100,
    10,
    true
  ),
  (
    'alliance_explore_3',
    '🧭 Ortak Keşif',
    'İttifak üyeleri bu hafta toplam 3 dünya keşfini tamamlasın.',
    'explorations_completed',
    3,
    20,
    true
  ),
  (
    'alliance_battle_10',
    '⚔️ Ortak Zafer',
    'İttifak üyeleri bu hafta NPC veya oyunculara karşı toplam 10 savaş kazansın.',
    'battle_wins',
    10,
    30,
    true
  ),
  (
    'alliance_active_3',
    '📅 Birlikte Aktif',
    'İttifaktan en az bir üye bu hafta 3 farklı günde giriş ödülü alsın.',
    'active_days',
    3,
    40,
    true
  )
ON CONFLICT (id) DO UPDATE SET
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  metric_key = EXCLUDED.metric_key,
  target_value = EXCLUDED.target_value,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active;

CREATE OR REPLACE FUNCTION public.nexora_alliance_member_metric_value(
  p_alliance_id bigint,
  p_player_id bigint,
  p_metric_key text,
  p_week_start date
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_joined_at timestamptz;
  v_week_start_at timestamptz;
  v_week_end_at timestamptz;
  v_from timestamptz;
  v_value bigint := 0;
BEGIN
  IF p_alliance_id IS NULL
     OR p_alliance_id <= 0
     OR p_player_id IS NULL
     OR p_player_id <= 0
     OR p_metric_key IS NULL
     OR btrim(p_metric_key) = ''
     OR p_week_start IS NULL THEN
    RETURN 0;
  END IF;

  SELECT am.joined_at
    INTO v_joined_at
    FROM public.alliance_members am
   WHERE am.alliance_id = p_alliance_id
     AND am.player_id = p_player_id
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_week_start_at :=
    p_week_start::timestamp AT TIME ZONE 'Europe/Istanbul';

  v_week_end_at :=
    (p_week_start + 7)::timestamp AT TIME ZONE 'Europe/Istanbul';

  v_from := GREATEST(
    v_week_start_at,
    COALESCE(v_joined_at, v_week_start_at)
  );

  CASE p_metric_key
    WHEN 'units_training_started' THEN
      SELECT COALESCE(SUM(GREATEST(COALESCE(q.quantity,0),0)),0)::bigint
        INTO v_value
        FROM public.unit_production_queue q
       WHERE q.player_id = p_player_id
         AND q.created_at >= v_from
         AND q.created_at < v_week_end_at;

    WHEN 'explorations_completed' THEN
      SELECT COUNT(*)::bigint
        INTO v_value
        FROM public.world_exploration_missions m
       WHERE m.player_id = p_player_id
         AND m.status = 'completed'
         AND m.completed_at IS NOT NULL
         AND m.completed_at >= v_from
         AND m.completed_at < v_week_end_at;

    WHEN 'battle_wins' THEN
      SELECT
        (
          SELECT COUNT(*)::bigint
            FROM public.battle_reports b
           WHERE b.winner_player_id = p_player_id
             AND b.created_at >= v_from
             AND b.created_at < v_week_end_at
        )
        +
        (
          SELECT COUNT(*)::bigint
            FROM public.npc_battle_reports n
           WHERE n.player_id = p_player_id
             AND n.result = 'Zafer'
             AND n.created_at >= v_from
             AND n.created_at < v_week_end_at
        )
        INTO v_value;

    WHEN 'active_days' THEN
      SELECT COUNT(DISTINCT c.claim_date)::bigint
        INTO v_value
        FROM public.player_login_reward_claims c
       WHERE c.player_id = p_player_id
         AND c.claimed_at >= v_from
         AND c.claimed_at < v_week_end_at
         AND c.claim_date >= p_week_start
         AND c.claim_date < p_week_start + 7;

    ELSE
      v_value := 0;
  END CASE;

  RETURN GREATEST(COALESCE(v_value,0),0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_alliance_metric_value(
  p_alliance_id bigint,
  p_metric_key text,
  p_week_start date
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_value bigint := 0;
BEGIN
  IF p_alliance_id IS NULL
     OR p_alliance_id <= 0
     OR p_metric_key IS NULL
     OR btrim(p_metric_key) = ''
     OR p_week_start IS NULL THEN
    RETURN 0;
  END IF;

  IF p_metric_key = 'active_days' THEN
    SELECT COUNT(DISTINCT d.claim_date)::bigint
      INTO v_value
      FROM public.alliance_members am
      JOIN public.player_login_reward_claims d
        ON d.player_id = am.player_id
     WHERE am.alliance_id = p_alliance_id
       AND d.claim_date >= p_week_start
       AND d.claim_date < p_week_start + 7
       AND d.claimed_at >= GREATEST(
             p_week_start::timestamp AT TIME ZONE 'Europe/Istanbul',
             COALESCE(
               am.joined_at,
               p_week_start::timestamp AT TIME ZONE 'Europe/Istanbul'
             )
           )
       AND d.claimed_at <
             (p_week_start + 7)::timestamp AT TIME ZONE 'Europe/Istanbul';
  ELSE
    SELECT COALESCE(
             SUM(
               public.nexora_alliance_member_metric_value(
                 p_alliance_id,
                 am.player_id,
                 p_metric_key,
                 p_week_start
               )
             ),
             0
           )::bigint
      INTO v_value
      FROM public.alliance_members am
     WHERE am.alliance_id = p_alliance_id;
  END IF;

  RETURN GREATEST(COALESCE(v_value,0),0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_alliance_missions_snapshot(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_server_time timestamptz := clock_timestamp();
  v_week_start date;
  v_next_reset_at timestamptz;
  v_alliance_id bigint;
  v_alliance_name text;
  v_alliance_tag text;
  v_missions jsonb := '[]'::jsonb;
  v_contributions jsonb := '[]'::jsonb;
  v_completed_count bigint := 0;
  v_core_count bigint := 0;
  v_chest_unlocked boolean := false;
  v_chest_claimed boolean := false;
  v_chest_claimed_at timestamptz;
  v_chest_reward jsonb := '{"metal":800,"energy":400,"water":800,"crystal":200}'::jsonb;
  v_credited_reward jsonb := '{}'::jsonb;
BEGIN
  IF p_player_id IS NULL
     OR p_player_id <= 0
     OR NOT EXISTS (SELECT 1 FROM public.players p WHERE p.id = p_player_id) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  v_week_start :=
    date_trunc('week', v_server_time AT TIME ZONE 'Europe/Istanbul')::date;

  v_next_reset_at :=
    (v_week_start + 7)::timestamp AT TIME ZONE 'Europe/Istanbul';

  SELECT a.id, a.name, a.tag
    INTO v_alliance_id, v_alliance_name, v_alliance_tag
    FROM public.alliance_members am
    JOIN public.alliances a ON a.id = am.alliance_id
   WHERE am.player_id = p_player_id
   LIMIT 1;

  IF v_alliance_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'inAlliance', false,
      'weekKey', to_char(v_week_start,'YYYY-MM-DD'),
      'serverTime', v_server_time,
      'nextResetAt', v_next_reset_at,
      'missions', '[]'::jsonb,
      'contributions', '[]'::jsonb,
      'chest', jsonb_build_object(
        'unlocked', false,
        'claimed', false,
        'claimable', false,
        'reward', v_chest_reward,
        'creditedReward', '{}'::jsonb
      )
    );
  END IF;

  SELECT COUNT(*)::bigint
    INTO v_core_count
    FROM public.game_alliance_missions m
   WHERE m.active IS TRUE;

  SELECT COUNT(*)::bigint
    INTO v_completed_count
    FROM public.game_alliance_missions m
   WHERE m.active IS TRUE
     AND public.nexora_alliance_metric_value(
           v_alliance_id,
           m.metric_key,
           v_week_start
         ) >= m.target_value;

  v_chest_unlocked :=
    v_core_count > 0
    AND v_completed_count >= v_core_count;

  SELECT true, c.claimed_at, c.reward
    INTO v_chest_claimed, v_chest_claimed_at, v_credited_reward
    FROM public.player_alliance_mission_chest_claims c
   WHERE c.player_id = p_player_id
     AND c.alliance_id = v_alliance_id
     AND c.week_start = v_week_start
   LIMIT 1;

  v_chest_claimed := COALESCE(v_chest_claimed,false);
  v_credited_reward := COALESCE(v_credited_reward,'{}'::jsonb);

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', m.id,
               'title', m.title,
               'description', m.description,
               'metricKey', m.metric_key,
               'progress',
                 LEAST(
                   public.nexora_alliance_metric_value(
                     v_alliance_id,
                     m.metric_key,
                     v_week_start
                   ),
                   m.target_value
                 ),
               'target', m.target_value,
               'completed',
                 public.nexora_alliance_metric_value(
                   v_alliance_id,
                   m.metric_key,
                   v_week_start
                 ) >= m.target_value
             )
             ORDER BY m.sort_order,m.id
           ),
           '[]'::jsonb
         )
    INTO v_missions
    FROM public.game_alliance_missions m
   WHERE m.active IS TRUE;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'playerId', am.player_id,
               'username', p.username,
               'role',
                 CASE
                   WHEN a.owner_player_id = am.player_id OR am.role = 'leader'
                     THEN 'leader'
                   WHEN am.role_v2 = 'officer'
                     THEN 'officer'
                   ELSE 'member'
                 END,
               'joinedAt', am.joined_at,
               'unitsTrainingStarted',
                 public.nexora_alliance_member_metric_value(
                   v_alliance_id,am.player_id,'units_training_started',v_week_start
                 ),
               'explorationsCompleted',
                 public.nexora_alliance_member_metric_value(
                   v_alliance_id,am.player_id,'explorations_completed',v_week_start
                 ),
               'battleWins',
                 public.nexora_alliance_member_metric_value(
                   v_alliance_id,am.player_id,'battle_wins',v_week_start
                 ),
               'activeDays',
                 public.nexora_alliance_member_metric_value(
                   v_alliance_id,am.player_id,'active_days',v_week_start
                 )
             )
             ORDER BY
               CASE
                 WHEN a.owner_player_id = am.player_id OR am.role = 'leader'
                   THEN 0
                 WHEN am.role_v2 = 'officer'
                   THEN 1
                 ELSE 2
               END,
               p.username,
               am.player_id
           ),
           '[]'::jsonb
         )
    INTO v_contributions
    FROM public.alliance_members am
    JOIN public.players p ON p.id = am.player_id
    JOIN public.alliances a ON a.id = am.alliance_id
   WHERE am.alliance_id = v_alliance_id;

  RETURN jsonb_build_object(
    'success', true,
    'inAlliance', true,
    'alliance', jsonb_build_object(
      'id', v_alliance_id,
      'name', v_alliance_name,
      'tag', v_alliance_tag
    ),
    'weekKey', to_char(v_week_start,'YYYY-MM-DD'),
    'serverTime', v_server_time,
    'nextResetAt', v_next_reset_at,
    'completedCount', v_completed_count,
    'totalCount', v_core_count,
    'missions', v_missions,
    'contributions', v_contributions,
    'chest', jsonb_build_object(
      'unlocked', v_chest_unlocked,
      'claimed', v_chest_claimed,
      'claimedAt', v_chest_claimed_at,
      'claimable', v_chest_unlocked AND NOT v_chest_claimed,
      'reward', v_chest_reward,
      'creditedReward', v_credited_reward
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_claim_alliance_mission_chest(
  p_player_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_server_time timestamptz := clock_timestamp();
  v_week_start date;
  v_alliance_id bigint;
  v_alliance_name text;
  v_core_count bigint := 0;
  v_completed_count bigint := 0;
  v_city public.cities%ROWTYPE;
  v_reward jsonb := '{"metal":800,"energy":400,"water":800,"crystal":200}'::jsonb;
  v_credit_metal bigint := 0;
  v_credit_energy bigint := 0;
  v_credit_water bigint := 0;
  v_credit_crystal bigint := 0;
  v_credited jsonb;
  v_existing jsonb;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_INPUT',
      'message', 'Geçersiz ittifak görevi ödül isteği.'
    );
  END IF;

  PERFORM id FROM public.players WHERE id = p_player_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PLAYER_NOT_FOUND',
      'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  v_week_start :=
    date_trunc('week', v_server_time AT TIME ZONE 'Europe/Istanbul')::date;

  SELECT a.id, a.name
    INTO v_alliance_id, v_alliance_name
    FROM public.alliance_members am
    JOIN public.alliances a ON a.id = am.alliance_id
   WHERE am.player_id = p_player_id
   LIMIT 1;

  IF v_alliance_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'NOT_IN_ALLIANCE',
      'message', 'Bir ittifakta olmalısın.'
    );
  END IF;

  PERFORM id
    FROM public.alliances
   WHERE id = v_alliance_id
   FOR UPDATE;

  SELECT c.reward
    INTO v_existing
    FROM public.player_alliance_mission_chest_claims c
   WHERE c.player_id = p_player_id
     AND c.alliance_id = v_alliance_id
     AND c.week_start = v_week_start
   LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu haftanın ittifak sandığını zaten aldın.',
      'weekKey', to_char(v_week_start,'YYYY-MM-DD'),
      'allianceId', v_alliance_id,
      'reward', v_reward,
      'creditedReward', COALESCE(v_existing,'{}'::jsonb),
      'snapshot', public.nexora_alliance_missions_snapshot(p_player_id)
    );
  END IF;

  SELECT COUNT(*)::bigint
    INTO v_core_count
    FROM public.game_alliance_missions m
   WHERE m.active IS TRUE;

  SELECT COUNT(*)::bigint
    INTO v_completed_count
    FROM public.game_alliance_missions m
   WHERE m.active IS TRUE
     AND public.nexora_alliance_metric_value(
           v_alliance_id,m.metric_key,v_week_start
         ) >= m.target_value;

  IF v_core_count <= 0 OR v_completed_count < v_core_count THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ALLIANCE_MISSIONS_INCOMPLETE',
      'message', 'İttifak haftalık görevleri henüz tamamlanmadı.',
      'completedCount', v_completed_count,
      'totalCount', v_core_count,
      'snapshot', public.nexora_alliance_missions_snapshot(p_player_id)
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
      'message', 'Şehir bulunamadı.'
    );
  END IF;

  v_credit_metal :=
    LEAST(800,GREATEST(COALESCE(v_city.metal_capacity,0)-COALESCE(v_city.metal,0),0));
  v_credit_energy :=
    LEAST(400,GREATEST(COALESCE(v_city.energy_capacity,0)-COALESCE(v_city.energy,0),0));
  v_credit_water :=
    LEAST(800,GREATEST(COALESCE(v_city.water_capacity,0)-COALESCE(v_city.water,0),0));
  v_credit_crystal :=
    LEAST(200,GREATEST(COALESCE(v_city.crystal_capacity,0)-COALESCE(v_city.crystal,0),0));

  v_credited := jsonb_build_object(
    'metal', v_credit_metal,
    'energy', v_credit_energy,
    'water', v_credit_water,
    'crystal', v_credit_crystal
  );

  INSERT INTO public.player_alliance_mission_chest_claims(
    player_id,alliance_id,week_start,claimed_at,reward
  )
  VALUES(
    p_player_id,v_alliance_id,v_week_start,clock_timestamp(),v_credited
  )
  ON CONFLICT (player_id,alliance_id,week_start) DO NOTHING;

  IF NOT FOUND THEN
    SELECT c.reward
      INTO v_existing
      FROM public.player_alliance_mission_chest_claims c
     WHERE c.player_id = p_player_id
       AND c.alliance_id = v_alliance_id
       AND c.week_start = v_week_start
     LIMIT 1;

    RETURN jsonb_build_object(
      'success', true,
      'alreadyClaimed', true,
      'message', 'Bu haftanın ittifak sandığını zaten aldın.',
      'weekKey', to_char(v_week_start,'YYYY-MM-DD'),
      'allianceId', v_alliance_id,
      'reward', v_reward,
      'creditedReward', COALESCE(v_existing,'{}'::jsonb),
      'snapshot', public.nexora_alliance_missions_snapshot(p_player_id)
    );
  END IF;

  UPDATE public.cities
     SET metal = COALESCE(metal,0) + v_credit_metal,
         energy = COALESCE(energy,0) + v_credit_energy,
         water = COALESCE(water,0) + v_credit_water,
         crystal = COALESCE(crystal,0) + v_credit_crystal,
         updated_at = clock_timestamp()
   WHERE id = v_city.id;

  INSERT INTO public.alliance_activity(
    alliance_id,event_type,actor_player_id,metadata,created_at
  )
  VALUES(
    v_alliance_id,
    'alliance_mission_chest_claimed',
    p_player_id,
    jsonb_build_object(
      'weekKey', to_char(v_week_start,'YYYY-MM-DD'),
      'allianceName', v_alliance_name
    ),
    clock_timestamp()
  );

  RETURN jsonb_build_object(
    'success', true,
    'alreadyClaimed', false,
    'message', 'İttifak haftalık sandığı alındı.',
    'weekKey', to_char(v_week_start,'YYYY-MM-DD'),
    'allianceId', v_alliance_id,
    'reward', v_reward,
    'creditedReward', v_credited,
    'snapshot', public.nexora_alliance_missions_snapshot(p_player_id)
  );
END;
$function$;

REVOKE ALL ON TABLE public.game_alliance_missions
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.player_alliance_mission_chest_claims
  FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.game_alliance_missions TO service_role;
GRANT SELECT, INSERT ON TABLE public.player_alliance_mission_chest_claims TO service_role;

REVOKE ALL ON FUNCTION
  public.nexora_alliance_member_metric_value(bigint,bigint,text,date)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.nexora_alliance_metric_value(bigint,text,date)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.nexora_alliance_missions_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.nexora_claim_alliance_mission_chest(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.nexora_alliance_member_metric_value(bigint,bigint,text,date)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.nexora_alliance_metric_value(bigint,text,date)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.nexora_alliance_missions_snapshot(bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.nexora_claim_alliance_mission_chest(bigint)
  TO service_role;

COMMIT;
