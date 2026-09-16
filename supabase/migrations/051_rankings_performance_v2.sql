-- NEXORA - Rankings Performance V2. Apply after 050_single_building_construction_queue.sql.
-- Consolidates six full-table rankings reads into one read-only PostgREST RPC.
-- Final score, Turkish username sort, rank and is_me remain in api/auth.js.
-- No tables, indexes or existing RPC contracts are changed.
BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_rankings_metrics_v2()
RETURNS TABLE (
  player_id bigint,
  username text,
  colony_level bigint,
  army_power double precision,
  battle_points double precision,
  wins bigint,
  losses bigint,
  draws bigint,
  research_level bigint,
  buildings_level bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
WITH city_level AS (
  SELECT DISTINCT ON (c.player_id)
    c.player_id,
    CASE
      WHEN c.level IS NULL OR c.level = 0 THEN 1::bigint
      ELSE c.level::bigint
    END AS colony_level
  FROM public.cities c
  WHERE c.player_id IS NOT NULL
  ORDER BY c.player_id, c.id DESC
),
building_metrics AS (
  SELECT
    c.player_id,
    SUM(COALESCE(b.level, 0))::bigint AS buildings_level
  FROM public.cities c
  JOIN public.buildings b
    ON b.city_id = c.id
  WHERE c.player_id IS NOT NULL
  GROUP BY c.player_id
),
unit_metrics AS (
  SELECT
    c.player_id,
    SUM(
      COALESCE(u.quantity, 0)::double precision *
      (
        COALESCE(u.attack, 0)::double precision +
        COALESCE(u.defense, 0)::double precision +
        COALESCE(u.hp, 0)::double precision * 0.5
      )
    )::double precision AS army_power
  FROM public.cities c
  JOIN public.units u
    ON u.city_id = c.id
  WHERE c.player_id IS NOT NULL
  GROUP BY c.player_id
),
research_metrics AS (
  SELECT
    r.player_id,
    SUM(
      COALESCE(r.production_level, 0)::bigint +
      COALESCE(r.combat_level, 0)::bigint +
      COALESCE(r.defense_level, 0)::bigint +
      COALESCE(r.crystal_level, 0)::bigint +
      COALESCE(r.general_power_level, 0)::bigint +
      COALESCE(r.unit_attack_level, 0)::bigint +
      COALESCE(r.unit_defense_level, 0)::bigint +
      COALESCE(r.unit_hp_level, 0)::bigint +
      COALESCE(r.travel_speed_level, 0)::bigint
    )::bigint AS research_level
  FROM public.research r
  WHERE r.player_id IS NOT NULL
  GROUP BY r.player_id
),
report_parsed AS (
  SELECT
    br.attacker_player_id,
    br.defender_player_id,
    br.result,
    br.battle_points,
    br.winner_player_id,
    CASE
      WHEN br.result IS JSON OBJECT THEN br.result::jsonb
      ELSE NULL::jsonb
    END AS result_json
  FROM public.battle_reports br
),
report_normalized AS (
  SELECT
    rp.attacker_player_id,
    rp.defender_player_id,
    CASE
      WHEN rp.result_json IS NOT NULL
        THEN COALESCE(rp.result_json->>'result', '')
      ELSE COALESCE(rp.result, '')
    END AS result_text,
    CASE
      WHEN rp.battle_points IS NOT NULL
        THEN rp.battle_points::double precision
      WHEN COALESCE(rp.result_json->>'battlePoints', '') ~
        '^[[:space:]]*[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?[[:space:]]*$'
        THEN (rp.result_json->>'battlePoints')::double precision
      ELSE 0::double precision
    END AS points,
    CASE
      WHEN rp.winner_player_id IS NOT NULL
        THEN rp.winner_player_id::double precision
      WHEN COALESCE(rp.result_json->>'winnerPlayerId', '') ~
        '^[[:space:]]*[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?[[:space:]]*$'
        THEN (rp.result_json->>'winnerPlayerId')::double precision
      ELSE 0::double precision
    END AS winner_raw
  FROM report_parsed rp
),
report_resolved AS (
  SELECT
    rn.attacker_player_id,
    rn.defender_player_id,
    rn.result_text,
    rn.points,
    CASE
      WHEN COALESCE(rn.winner_raw, 0) <> 0
        THEN rn.winner_raw
      WHEN rn.result_text = 'Zafer'
        THEN COALESCE(rn.attacker_player_id, 0)::double precision
      WHEN rn.result_text = 'Yenilgi'
        THEN COALESCE(rn.defender_player_id, 0)::double precision
      ELSE 0::double precision
    END AS winner
  FROM report_normalized rn
),
battle_contributions AS (
  -- Existing JS credits battle points to a resolved winner before checking draw.
  SELECT
    p.id AS player_id,
    rr.points AS battle_points,
    CASE
      WHEN rr.result_text <> 'Beraberlik' THEN 1::bigint
      ELSE 0::bigint
    END AS wins,
    0::bigint AS losses,
    0::bigint AS draws
  FROM report_resolved rr
  JOIN public.players p
    ON p.id::double precision = rr.winner
  WHERE rr.winner <> 0

  UNION ALL

  SELECT
    p.id,
    0::double precision,
    0::bigint,
    0::bigint,
    1::bigint
  FROM report_resolved rr
  JOIN public.players p
    ON p.id = rr.attacker_player_id
  WHERE rr.result_text = 'Beraberlik'

  UNION ALL

  SELECT
    p.id,
    0::double precision,
    0::bigint,
    0::bigint,
    1::bigint
  FROM report_resolved rr
  JOIN public.players p
    ON p.id = rr.defender_player_id
  WHERE rr.result_text = 'Beraberlik'

  UNION ALL

  SELECT
    p.id,
    0::double precision,
    0::bigint,
    1::bigint,
    0::bigint
  FROM report_resolved rr
  JOIN public.players p
    ON p.id = CASE
      WHEN rr.winner = rr.attacker_player_id::double precision
        THEN rr.defender_player_id
      WHEN rr.winner = rr.defender_player_id::double precision
        THEN rr.attacker_player_id
      ELSE NULL::bigint
    END
  WHERE rr.result_text <> 'Beraberlik'
    AND rr.winner <> 0
),
battle_metrics AS (
  SELECT
    bc.player_id,
    SUM(bc.battle_points)::double precision AS battle_points,
    SUM(bc.wins)::bigint AS wins,
    SUM(bc.losses)::bigint AS losses,
    SUM(bc.draws)::bigint AS draws
  FROM battle_contributions bc
  GROUP BY bc.player_id
)
SELECT
  p.id::bigint AS player_id,
  p.username::text AS username,
  COALESCE(cl.colony_level, 1::bigint) AS colony_level,
  COALESCE(um.army_power, 0::double precision) AS army_power,
  COALESCE(bm.battle_points, 0::double precision) AS battle_points,
  COALESCE(bm.wins, 0::bigint) AS wins,
  COALESCE(bm.losses, 0::bigint) AS losses,
  COALESCE(bm.draws, 0::bigint) AS draws,
  COALESCE(rm.research_level, 0::bigint) AS research_level,
  COALESCE(bld.buildings_level, 0::bigint) AS buildings_level
FROM public.players p
LEFT JOIN city_level cl
  ON cl.player_id = p.id
LEFT JOIN unit_metrics um
  ON um.player_id = p.id
LEFT JOIN battle_metrics bm
  ON bm.player_id = p.id
LEFT JOIN research_metrics rm
  ON rm.player_id = p.id
LEFT JOIN building_metrics bld
  ON bld.player_id = p.id;
$function$;

REVOKE ALL ON FUNCTION public.nexora_rankings_metrics_v2()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_rankings_metrics_v2()
  TO service_role;

COMMIT;
