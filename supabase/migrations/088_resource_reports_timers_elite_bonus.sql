-- TERYNDIS 088 Resource PvP reports, live map timers and elite delivery bonus
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM public.resource_gather_missions WHERE status IN ('traveling','gathering','returning'))
     OR EXISTS(SELECT 1 FROM public.resource_conflict_missions WHERE status IN ('traveling','returning')) THEN
    RAISE EXCEPTION 'RESOURCE_088_ACTIVE_MISSIONS';
  END IF;
END;
$guard$;

ALTER TABLE public.resource_gather_missions
  ADD COLUMN IF NOT EXISTS gathered_base_amount bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS elite_bonus_amount bigint NOT NULL DEFAULT 0;

UPDATE public.resource_gather_missions
SET gathered_base_amount=GREATEST(0,COALESCE(gathered_amount,0)),
    elite_bonus_amount=0
WHERE status='completed' OR COALESCE(gathered_amount,0)>0;

ALTER TABLE public.resource_gather_missions
  DROP CONSTRAINT IF EXISTS resource_gather_missions_gathered_base_amount_check;
ALTER TABLE public.resource_gather_missions
  DROP CONSTRAINT IF EXISTS resource_gather_missions_elite_bonus_amount_check;
ALTER TABLE public.resource_gather_missions
  ADD CONSTRAINT resource_gather_missions_gathered_base_amount_check CHECK(gathered_base_amount>=0),
  ADD CONSTRAINT resource_gather_missions_elite_bonus_amount_check CHECK(elite_bonus_amount>=0);

CREATE OR REPLACE FUNCTION public.nexora_sync_resource_gather_mission(p_player_id bigint, p_mission_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  m public.resource_gather_missions%ROWTYPE;
  s public.world_sites%ROWTYPE;
  c public.cities%ROWTYPE;
  now_at timestamptz:=clock_timestamp();
  gathered bigint:=0;
  elite_bonus bigint:=0;
  new_stock bigint:=0;
  remaining integer:=0;
  attacker_survivors jsonb;
  defender_survivors jsonb;
  result_text text;
  survivor_pop bigint;
BEGIN
  SELECT * INTO m FROM public.resource_gather_missions WHERE id=p_mission_id AND player_id=p_player_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','MISSION_NOT_FOUND','message','Kaynak seferi bulunamadı.'); END IF;
  IF m.status='completed' THEN RETURN jsonb_build_object('success',true,'completed',true,'alreadyCompleted',true,'mission',to_jsonb(m)); END IF;

  IF m.status='traveling' THEN
    IF m.arrive_at>now_at THEN
      remaining:=GREATEST(1,CEIL(EXTRACT(EPOCH FROM(m.arrive_at-now_at)))::integer);
      RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'remainingSeconds',remaining);
    END IF;

    SELECT * INTO s FROM public.world_sites WHERE id=m.site_id AND site_type='resource' FOR UPDATE;
    IF NOT FOUND OR s.active IS DISTINCT FROM true OR COALESCE(s.resource_stock,0)<=0 THEN
      UPDATE public.resource_gather_missions
      SET status='returning',return_at=now_at+make_interval(secs=>travel_seconds),updated_at=now_at
      WHERE id=m.id RETURNING * INTO m;
      RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'message','Kaynak noktası artık kullanılamıyor; birlikler dönüyor.');
    END IF;

    IF s.resource_guard_active THEN
      IF m.guard_plan IS NULL OR m.guard_plan->'defenderArmy' IS DISTINCT FROM COALESCE(s.resource_guard_army,'[]'::jsonb) THEN
        UPDATE public.resource_gather_missions
        SET status='returning',return_at=now_at+make_interval(secs=>travel_seconds),updated_at=now_at
        WHERE id=m.id RETURNING * INTO m;
        RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'message','Muhafız durumu değişti; birlikler dönüyor.');
      END IF;

      result_text:=m.guard_plan->>'result';
      attacker_survivors:=COALESCE(m.guard_plan->'attackerSurvivorArmy','[]'::jsonb);
      defender_survivors:=COALESCE(m.guard_plan->'defenderSurvivorArmy','[]'::jsonb);

      UPDATE public.world_sites
      SET resource_guard_army=defender_survivors,
          resource_guard_active=public.nexora_military_army_population(defender_survivors)>0
      WHERE id=s.id;

      survivor_pop:=public.nexora_military_army_population(attacker_survivors);

      IF result_text='Zafer' AND survivor_pop>0 THEN
        UPDATE public.resource_gather_missions
        SET status='gathering',army=attacker_survivors,carry_capacity=GREATEST(1,survivor_pop*100),
            gather_complete_at=now_at+make_interval(secs=>GREATEST(5,COALESCE(s.resource_gather_seconds,30))),
            updated_at=now_at
        WHERE id=m.id RETURNING * INTO m;
        RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),
          'guardBattle',m.guard_plan,'remainingSeconds',GREATEST(5,COALESCE(s.resource_gather_seconds,30)));
      END IF;

      UPDATE public.resource_gather_missions
      SET status='returning',army=attacker_survivors,carry_capacity=GREATEST(1,COALESCE(carry_capacity,1)),
          return_at=now_at+make_interval(secs=>travel_seconds),updated_at=now_at
      WHERE id=m.id RETURNING * INTO m;
      RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'guardBattle',m.guard_plan,
        'message','Muhafız savaşı sonrası birlikler koloniye dönüyor.');
    END IF;

    UPDATE public.resource_gather_missions
    SET status='gathering',
        gather_complete_at=now_at+make_interval(secs=>GREATEST(5,COALESCE(s.resource_gather_seconds,30))),
        updated_at=now_at
    WHERE id=m.id RETURNING * INTO m;

    RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),
      'remainingSeconds',GREATEST(5,COALESCE(s.resource_gather_seconds,30)));
  END IF;

  IF m.status='gathering' THEN
    IF EXISTS(SELECT 1 FROM public.resource_conflict_missions rc
      WHERE rc.defender_gather_mission_id=m.id AND rc.status='traveling') THEN
      RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'underAttack',true);
    END IF;

    IF m.gather_complete_at IS NULL OR m.gather_complete_at>now_at THEN
      remaining:=CASE WHEN m.gather_complete_at IS NULL THEN 1
        ELSE GREATEST(1,CEIL(EXTRACT(EPOCH FROM(m.gather_complete_at-now_at)))::integer) END;
      RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'remainingSeconds',remaining);
    END IF;

    SELECT * INTO s FROM public.world_sites WHERE id=m.site_id AND site_type='resource' FOR UPDATE;
    IF FOUND AND s.active=true AND s.resource_type=m.resource_type AND COALESCE(s.resource_stock,0)>0 THEN
      gathered:=LEAST(GREATEST(0,m.carry_capacity),GREATEST(0,s.resource_stock));
      elite_bonus:=CASE
        WHEN s.resource_rarity='elite' THEN FLOOR(gathered::numeric*0.20)::bigint
        ELSE 0
      END;
      new_stock:=GREATEST(0,s.resource_stock-gathered);
      UPDATE public.world_sites SET
        resource_stock=new_stock,
        active=CASE WHEN new_stock=0 THEN false ELSE active END,
        resource_respawn_at=CASE WHEN new_stock=0
          THEN now_at+make_interval(secs=>GREATEST(60,COALESCE(resource_respawn_seconds,600)))
          ELSE resource_respawn_at END
      WHERE id=s.id;
    END IF;

    UPDATE public.resource_gather_missions
    SET status='returning',
        gathered_base_amount=gathered,
        elite_bonus_amount=elite_bonus,
        gathered_amount=gathered+elite_bonus,
        return_at=now_at+make_interval(secs=>travel_seconds),
        updated_at=now_at
    WHERE id=m.id RETURNING * INTO m;

    RETURN jsonb_build_object(
      'success',true,'completed',false,'mission',to_jsonb(m),
      'gatheredBaseAmount',gathered,
      'eliteBonusAmount',elite_bonus,
      'gatheredAmount',gathered+elite_bonus,
      'remainingSeconds',m.travel_seconds
    );
  END IF;

  IF m.status IS DISTINCT FROM 'returning' THEN
    RETURN jsonb_build_object('success',false,'code','MISSION_STATE','message','Kaynak seferi beklenmeyen durumda.');
  END IF;

  IF m.return_at IS NULL OR m.return_at>now_at THEN
    remaining:=CASE WHEN m.return_at IS NULL THEN GREATEST(1,m.travel_seconds)
      ELSE GREATEST(1,CEIL(EXTRACT(EPOCH FROM(m.return_at-now_at)))::integer) END;
    RETURN jsonb_build_object('success',true,'completed',false,'mission',to_jsonb(m),'remainingSeconds',remaining);
  END IF;

  SELECT * INTO c FROM public.cities WHERE id=m.city_id AND player_id=p_player_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'code','CITY_NOT_FOUND','message','Koloni bulunamadı.'); END IF;

  PERFORM public.nexora_resource_return_army(c.id,COALESCE(m.army,'[]'::jsonb));

  UPDATE public.cities SET
    metal=COALESCE(metal,0)+CASE WHEN m.resource_type='metal' THEN m.gathered_amount ELSE 0 END,
    energy=COALESCE(energy,0)+CASE WHEN m.resource_type='energy' THEN m.gathered_amount ELSE 0 END,
    alloy=COALESCE(alloy,0)+CASE WHEN m.resource_type='alloy' THEN m.gathered_amount ELSE 0 END,
    crystal=COALESCE(crystal,0)+CASE WHEN m.resource_type='crystal' THEN m.gathered_amount ELSE 0 END
  WHERE id=c.id;

  UPDATE public.resource_gather_missions SET status='completed',completed_at=now_at,updated_at=now_at
  WHERE id=m.id RETURNING * INTO m;

  RETURN jsonb_build_object(
    'success',true,'completed',true,'alreadyCompleted',false,
    'mission',to_jsonb(m),
    'resourceType',m.resource_type,
    'gatheredBaseAmount',COALESCE(m.gathered_base_amount,0),
    'eliteBonusAmount',COALESCE(m.elite_bonus_amount,0),
    'gatheredAmount',m.gathered_amount
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nexora_world_control_sites(p_player_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH viewer AS (
    SELECT
      am.alliance_id,
      CASE
        WHEN am.role = 'leader' THEN 'leader'
        WHEN am.role_v2 = 'officer' THEN 'officer'
        ELSE 'member'
      END AS alliance_role
    FROM public.alliance_members am
    WHERE am.player_id = p_player_id
    ORDER BY am.id
    LIMIT 1
  ),
  viewer_meta AS (
    SELECT
      v.alliance_id,
      v.alliance_role,
      (
        SELECT COUNT(*)
        FROM public.world_sites owned
        WHERE owned.site_type = 'alliance'
          AND owned.owner_alliance_id = v.alliance_id
      ) AS alliance_claim_count
    FROM viewer v
  )
  SELECT COALESCE(
    jsonb_agg(
      to_jsonb(s)
      ||
      jsonb_build_object(
        'owner_username', p.username,
        'owner_alliance_name', a.name,
        'owner_alliance_tag', a.tag,
        'viewer_alliance_id', vm.alliance_id,
        'viewer_alliance_role', vm.alliance_role,
        'claim_scope',
          CASE
            WHEN s.site_type = 'alliance' THEN 'alliance'
            WHEN s.site_type = 'resource' THEN 'resource'
            ELSE 'player'
          END,
        'has_explored',
          EXISTS (
            SELECT 1
            FROM public.world_exploration_missions m
            WHERE m.player_id = p_player_id
              AND m.site_id = s.id
              AND m.status = 'completed'
          ),
        'alliance_has_explored',
          CASE
            WHEN s.site_type = 'alliance'
             AND vm.alliance_id IS NOT NULL THEN
              EXISTS (
                SELECT 1
                FROM public.world_exploration_missions m
                JOIN public.alliance_members am
                  ON am.player_id = m.player_id
                 AND am.alliance_id = vm.alliance_id
                WHERE m.site_id = s.id
                  AND m.status = 'completed'
              )
            ELSE false
          END,
        'can_explore',
          CASE
            WHEN s.site_type = 'resource' THEN false
            WHEN s.site_type = 'alliance' THEN
              vm.alliance_id IS NOT NULL
              AND s.owner_alliance_id IS NULL
              AND s.owner_player_id IS NULL
            ELSE
              s.owner_player_id IS NULL
              AND s.owner_alliance_id IS NULL
          END,
        'can_claim',
          CASE
            WHEN s.site_type = 'resource' THEN false
            WHEN s.site_type = 'alliance' THEN
              vm.alliance_id IS NOT NULL
              AND vm.alliance_role IN ('leader','officer')
              AND s.owner_alliance_id IS NULL
              AND s.owner_player_id IS NULL
              AND COALESCE(vm.alliance_claim_count, 0) < 2
              AND EXISTS (
                SELECT 1
                FROM public.world_exploration_missions m
                JOIN public.alliance_members am
                  ON am.player_id = m.player_id
                 AND am.alliance_id = vm.alliance_id
                WHERE m.site_id = s.id
                  AND m.status = 'completed'
              )
            ELSE
              s.owner_player_id IS NULL
              AND s.owner_alliance_id IS NULL
              AND (
                SELECT COUNT(*)
                FROM public.world_sites owned
                WHERE owned.owner_player_id = p_player_id
              ) < 2
              AND EXISTS (
                SELECT 1
                FROM public.world_exploration_missions m
                WHERE m.player_id = p_player_id
                  AND m.site_id = s.id
                  AND m.status = 'completed'
              )
          END,
        'resource_collector_mission_id',
          (SELECT rg.id FROM public.resource_gather_missions rg
            WHERE rg.site_id=s.id AND rg.status='gathering'
            ORDER BY rg.id DESC LIMIT 1),
        'resource_collector_player_id',
          (SELECT rg.player_id FROM public.resource_gather_missions rg
            WHERE rg.site_id=s.id AND rg.status='gathering'
            ORDER BY rg.id DESC LIMIT 1),
        'resource_collector_username',
          (SELECT rp.username FROM public.resource_gather_missions rg
            JOIN public.players rp ON rp.id=rg.player_id
            WHERE rg.site_id=s.id AND rg.status='gathering'
            ORDER BY rg.id DESC LIMIT 1),
        'resource_collector_alliance_id',
          (SELECT ram.alliance_id FROM public.resource_gather_missions rg
            LEFT JOIN public.alliance_members ram ON ram.player_id=rg.player_id
            WHERE rg.site_id=s.id AND rg.status='gathering'
            ORDER BY rg.id DESC,ram.id LIMIT 1),
        'resource_gather_complete_at',
          (SELECT rg.gather_complete_at FROM public.resource_gather_missions rg
            WHERE rg.site_id=s.id AND rg.status='gathering'
            ORDER BY rg.id DESC LIMIT 1),
        'resource_under_attack',
          EXISTS(SELECT 1 FROM public.resource_conflict_missions rc
            WHERE rc.site_id=s.id AND rc.status='traveling'),
        'resource_attack_conflict_id',
          (SELECT rc.id FROM public.resource_conflict_missions rc
            WHERE rc.site_id=s.id AND rc.status='traveling'
            ORDER BY rc.arrive_at,rc.id LIMIT 1),
        'resource_attack_arrive_at',
          (SELECT rc.arrive_at FROM public.resource_conflict_missions rc
            WHERE rc.site_id=s.id AND rc.status='traveling'
            ORDER BY rc.arrive_at,rc.id LIMIT 1),
        'is_owned_by_viewer',
          CASE
            WHEN s.site_type = 'resource' THEN false
            WHEN s.site_type = 'alliance' THEN
              vm.alliance_id IS NOT NULL
              AND s.owner_alliance_id = vm.alliance_id
            ELSE
              s.owner_player_id = p_player_id
          END
      )
      ORDER BY s.id
    ),
    '[]'::jsonb
  )
  FROM public.world_sites s
  LEFT JOIN public.players p
    ON p.id = s.owner_player_id
  LEFT JOIN public.alliances a
    ON a.id = s.owner_alliance_id
  LEFT JOIN viewer_meta vm
    ON true
  WHERE s.active = true
    AND s.site_type <> 'npc_camp';
$function$;

CREATE OR REPLACE FUNCTION public.nexora_activity_events(p_player_id bigint)
 RETURNS TABLE(event_id text, event_type text, occurred_at timestamp with time zone, title text, summary text, tone text, href text, meta jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    'pvp:' || br.id::text AS event_id,
    'pvp_battle'::text AS event_type,
    br.created_at AS occurred_at,
    CASE
      WHEN br.attacker_player_id = p_player_id THEN '⚔️ Saldırı Sonucu'
      ELSE '🛡️ Savunma Sonucu'
    END AS title,
    CASE
      WHEN br.attacker_player_id = p_player_id THEN
        COALESCE(opponent.username, 'Oyuncu') ||
        ' oyuncusuna karşı saldırın: ' ||
        CASE
          WHEN br.winner_player_id = p_player_id THEN 'Zafer'
          WHEN br.winner_player_id IS NULL THEN 'Beraberlik'
          ELSE 'Yenilgi'
        END || '.'
      ELSE
        COALESCE(opponent.username, 'Oyuncu') ||
        ' oyuncusunun saldırısı: ' ||
        CASE
          WHEN br.winner_player_id = p_player_id THEN 'Zafer'
          WHEN br.winner_player_id IS NULL THEN 'Beraberlik'
          ELSE 'Yenilgi'
        END || '.'
    END AS summary,
    CASE
      WHEN br.winner_player_id = p_player_id THEN 'success'
      WHEN br.winner_player_id IS NULL THEN 'neutral'
      ELSE 'danger'
    END AS tone,
    'reports.html'::text AS href,
    jsonb_build_object(
      'reportId', br.id,
      'role', CASE
        WHEN br.attacker_player_id = p_player_id THEN 'attacker'
        ELSE 'defender'
      END,
      'outcome', CASE
        WHEN br.winner_player_id = p_player_id THEN 'Zafer'
        WHEN br.winner_player_id IS NULL THEN 'Beraberlik'
        ELSE 'Yenilgi'
      END,
      'opponentPlayerId', opponent.id,
      'opponentUsername', opponent.username,
      'battlePoints', COALESCE(br.battle_points, 0),
      'loot', COALESCE(br.loot, '{}'::jsonb)
    ) AS meta
  FROM public.battle_reports br
  LEFT JOIN public.players opponent
    ON opponent.id = CASE
      WHEN br.attacker_player_id = p_player_id THEN br.defender_player_id
      ELSE br.attacker_player_id
    END
  WHERE br.created_at IS NOT NULL
    AND (
      br.attacker_player_id = p_player_id
      OR br.defender_player_id = p_player_id
    )

  UNION ALL

  SELECT
    'npc:' || r.id::text AS event_id,
    'npc_battle'::text AS event_type,
    r.created_at AS occurred_at,
    '🏕️ NPC Savaşı'::text AS title,
    COALESCE(NULLIF(btrim(r.camp_name), ''), 'NPC Kampı') ||
      ': ' || COALESCE(NULLIF(btrim(r.result), ''), 'Sonuçlandı') || '.' AS summary,
    CASE
      WHEN r.result = 'Zafer' THEN 'success'
      WHEN r.result = 'Yenilgi' THEN 'danger'
      ELSE 'neutral'
    END AS tone,
    'reports.html'::text AS href,
    jsonb_build_object(
      'reportId', r.id,
      'npcMissionId', r.npc_mission_id,
      'npcCampId', r.npc_camp_id,
      'campName', r.camp_name,
      'campTier', r.camp_tier,
      'outcome', r.result,
      'reward', COALESCE(r.reward, '{}'::jsonb)
    ) AS meta
  FROM public.npc_battle_reports r
  WHERE r.player_id = p_player_id
    AND r.created_at IS NOT NULL

  UNION ALL

  SELECT
    'explore:' || m.id::text AS event_id,
    'world_exploration'::text AS event_type,
    m.completed_at AS occurred_at,
    '🧭 Keşif Tamamlandı'::text AS title,
    COALESCE(NULLIF(btrim(s.name), ''), 'Dünya noktası') ||
      ' keşfi tamamlandı.' AS summary,
    'success'::text AS tone,
    'world.html'::text AS href,
    jsonb_build_object(
      'missionId', m.id,
      'siteId', m.site_id,
      'siteName', s.name,
      'result', COALESCE(m.result, '{}'::jsonb)
    ) AS meta
  FROM public.world_exploration_missions m
  LEFT JOIN public.world_sites s
    ON s.id = m.site_id
  WHERE m.player_id = p_player_id
    AND m.status = 'completed'
    AND m.completed_at IS NOT NULL

  UNION ALL

  SELECT
    'daily:' || c.mission_date::text || ':' || c.mission_id AS event_id,
    'daily_mission_claim'::text AS event_type,
    c.claimed_at AS occurred_at,
    '🎯 Günlük Görev Ödülü'::text AS title,
    COALESCE(NULLIF(btrim(d.title), ''), 'Günlük görev') ||
      ' ödülü alındı.' AS summary,
    'success'::text AS tone,
    'missions.html'::text AS href,
    jsonb_build_object(
      'missionDate', c.mission_date,
      'missionId', c.mission_id,
      'missionTitle', d.title,
      'rewardCredited', COALESCE(c.reward, '{}'::jsonb)
    ) AS meta
  FROM public.player_daily_mission_claims c
  LEFT JOIN public.game_daily_missions d
    ON d.id = c.mission_id
  WHERE c.player_id = p_player_id
    AND c.claimed_at IS NOT NULL

  UNION ALL

  SELECT
    'trade:' || t.id::text AS event_id,
    'trade_delivery'::text AS event_type,
    t.delivered_at AS occurred_at,
    '💱 Ticaret Teslim Edildi'::text AS title,
    COALESCE(counterpart.username, 'Oyuncu') ||
      ' ile ticaret tamamlandı. ' ||
      CASE
        WHEN (CASE WHEN t.buyer_player_id = p_player_id THEN t.give_resource ELSE t.want_resource END) = 'metal' THEN 'Metal'
        WHEN (CASE WHEN t.buyer_player_id = p_player_id THEN t.give_resource ELSE t.want_resource END) = 'energy' THEN 'Enerji'
        WHEN (CASE WHEN t.buyer_player_id = p_player_id THEN t.give_resource ELSE t.want_resource END) = 'alloy' THEN 'Alaşım'
        WHEN (CASE WHEN t.buyer_player_id = p_player_id THEN t.give_resource ELSE t.want_resource END) = 'crystal' THEN 'Kristal'
        ELSE 'Kaynak'
      END ||
      ' +' ||
      (CASE WHEN t.buyer_player_id = p_player_id
        THEN COALESCE(t.buyer_receive_amount, 0)
        ELSE COALESCE(t.seller_receive_amount, 0)
      END)::text || '.' AS summary,
    'success'::text AS tone,
    'trade.html'::text AS href,
    jsonb_build_object(
      'transactionId', t.id,
      'offerId', t.offer_id,
      'counterpartyPlayerId', counterpart.id,
      'counterpartyUsername', counterpart.username,
      'receivedResource',
        CASE WHEN t.buyer_player_id = p_player_id THEN t.give_resource ELSE t.want_resource END,
      'receivedAmount',
        CASE WHEN t.buyer_player_id = p_player_id
          THEN COALESCE(t.buyer_receive_amount, 0)
          ELSE COALESCE(t.seller_receive_amount, 0)
        END
    ) AS meta
  FROM public.trade_transactions t
  LEFT JOIN public.players counterpart
    ON counterpart.id = CASE
      WHEN t.buyer_player_id = p_player_id THEN t.seller_player_id
      ELSE t.buyer_player_id
    END
  WHERE t.status = 'delivered'
    AND t.delivered_at IS NOT NULL
    AND (
      t.seller_player_id = p_player_id
      OR t.buyer_player_id = p_player_id
    )

  UNION ALL

  SELECT
    'resource-pvp:' || rc.id::text AS event_id,
    'resource_pvp'::text AS event_type,
    rc.completed_at AS occurred_at,
    CASE
      WHEN rc.attacker_player_id=p_player_id THEN '⚔️ Kaynak Çatışması'
      ELSE '🛡️ Kaynak Ordun Saldırıya Uğradı'
    END AS title,
    COALESCE(NULLIF(btrim(s.name),''),'Kaynak noktası') ||
      ' için ' ||
      CASE
        WHEN rc.attacker_player_id=p_player_id THEN COALESCE(opponent.username,'Oyuncu') || ' oyuncusuna karşı: '
        ELSE COALESCE(opponent.username,'Oyuncu') || ' oyuncusunun saldırısı: '
      END ||
      CASE
        WHEN rc.result='Beraberlik' THEN 'Beraberlik'
        WHEN rc.attacker_player_id=p_player_id THEN rc.result
        WHEN rc.result='Zafer' THEN 'Yenilgi'
        WHEN rc.result='Yenilgi' THEN 'Zafer'
        ELSE rc.result
      END || '.' AS summary,
    CASE
      WHEN rc.result='Beraberlik' THEN 'neutral'
      WHEN (
        CASE
          WHEN rc.attacker_player_id=p_player_id THEN rc.result
          WHEN rc.result='Zafer' THEN 'Yenilgi'
          WHEN rc.result='Yenilgi' THEN 'Zafer'
          ELSE rc.result
        END
      )='Zafer' THEN 'success'
      ELSE 'danger'
    END::text AS tone,
    'reports.html'::text AS href,
    jsonb_build_object(
      'conflictId',rc.id,
      'siteId',rc.site_id,
      'siteName',s.name,
      'resourceType',s.resource_type,
      'resourceRarity',s.resource_rarity,
      'role',CASE WHEN rc.attacker_player_id=p_player_id THEN 'attacker' ELSE 'defender' END,
      'outcome',CASE
        WHEN rc.result='Beraberlik' THEN 'Beraberlik'
        WHEN rc.attacker_player_id=p_player_id THEN rc.result
        WHEN rc.result='Zafer' THEN 'Yenilgi'
        WHEN rc.result='Yenilgi' THEN 'Zafer'
        ELSE rc.result
      END,
      'opponentPlayerId',opponent.id,
      'opponentUsername',opponent.username,
      'battlePlan',COALESCE(rc.battle_plan,'{}'::jsonb),
      'takeoverMissionId',rc.takeover_mission_id
    ) AS meta
  FROM public.resource_conflict_missions rc
  LEFT JOIN public.world_sites s ON s.id=rc.site_id
  LEFT JOIN public.players opponent
    ON opponent.id=CASE
      WHEN rc.attacker_player_id=p_player_id THEN rc.defender_player_id
      ELSE rc.attacker_player_id
    END
  WHERE rc.status='completed'
    AND rc.completed_at IS NOT NULL
    AND rc.result IN ('Zafer','Yenilgi','Beraberlik')
    AND (rc.attacker_player_id=p_player_id OR rc.defender_player_id=p_player_id)

  UNION ALL

  SELECT
    'alliance:' || aa.id::text AS event_id,
    'alliance_activity'::text AS event_type,
    aa.created_at AS occurred_at,
    CASE aa.event_type
      WHEN 'alliance_created' THEN '🤝 İttifak Kuruldu'
      WHEN 'member_joined' THEN '🤝 Üye Katıldı'
      WHEN 'role_changed' THEN '🎖️ İttifak Rolü Güncellendi'
      WHEN 'announcement_posted' THEN '📣 İttifak Duyurusu'
      WHEN 'announcement_deleted' THEN '📣 Duyuru Kaldırıldı'
      WHEN 'member_left' THEN '↩️ Üye Ayrıldı'
      WHEN 'leadership_transferred' THEN '👑 Liderlik Devredildi'
      WHEN 'member_kicked' THEN '🚪 Üye Çıkarıldı'
      WHEN 'war_challenge_sent' THEN '⚔️ Savaş Çağrısı Gönderildi'
      WHEN 'war_challenge_received' THEN '⚔️ Savaş Çağrısı Alındı'
      WHEN 'war_challenge_rejected' THEN '🛡️ Savaş Çağrısı Reddedildi'
      WHEN 'war_started' THEN '🔥 İttifak Savaşı Başladı'
      WHEN 'war_finished' THEN '🏁 İttifak Savaşı Bitti'
      ELSE '🤝 İttifak Aktivitesi'
    END AS title,
    CASE aa.event_type
      WHEN 'alliance_created' THEN COALESCE(a.name, 'İttifak') || ' kuruldu.'
      WHEN 'member_joined' THEN COALESCE(target.username, actor.username, 'Bir oyuncu') || ' ittifaka katıldı.'
      WHEN 'role_changed' THEN COALESCE(target.username, 'Bir oyuncu') || ' oyuncusunun ittifak rolü güncellendi.'
      WHEN 'announcement_posted' THEN 'Yeni ittifak duyurusu yayınlandı.'
      WHEN 'announcement_deleted' THEN 'Bir ittifak duyurusu kaldırıldı.'
      WHEN 'member_left' THEN COALESCE(target.username, actor.username, 'Bir oyuncu') || ' ittifaktan ayrıldı.'
      WHEN 'leadership_transferred' THEN 'İttifak liderliği ' || COALESCE(target.username, 'başka bir oyuncu') || ' oyuncusuna devredildi.'
      WHEN 'member_kicked' THEN COALESCE(target.username, 'Bir oyuncu') || ' ittifaktan çıkarıldı.'
      WHEN 'war_challenge_sent' THEN 'Başka bir ittifaka savaş çağrısı gönderildi.'
      WHEN 'war_challenge_received' THEN 'İttifakına savaş çağrısı geldi.'
      WHEN 'war_challenge_rejected' THEN 'İttifak savaş çağrısı reddedildi.'
      WHEN 'war_started' THEN 'İttifak savaşı başladı.'
      WHEN 'war_finished' THEN 'İttifak savaşı sona erdi.'
      ELSE 'Yeni bir ittifak aktivitesi gerçekleşti.'
    END AS summary,
    CASE
      WHEN aa.event_type IN ('alliance_created','member_joined','war_started') THEN 'success'
      WHEN aa.event_type IN ('member_kicked','war_challenge_received') THEN 'danger'
      ELSE 'neutral'
    END::text AS tone,
    'alliance.html'::text AS href,
    jsonb_build_object(
      'activityId', aa.id,
      'allianceId', aa.alliance_id,
      'allianceName', a.name,
      'eventType', aa.event_type,
      'actorPlayerId', aa.actor_player_id,
      'actorUsername', actor.username,
      'targetPlayerId', aa.target_player_id,
      'targetUsername', target.username,
      'metadata', COALESCE(aa.metadata, '{}'::jsonb)
    ) AS meta
  FROM public.alliance_activity aa
  LEFT JOIN public.alliances a
    ON a.id = aa.alliance_id
  LEFT JOIN public.players actor
    ON actor.id = aa.actor_player_id
  LEFT JOIN public.players target
    ON target.id = aa.target_player_id
  WHERE aa.created_at IS NOT NULL
    AND (
      aa.actor_player_id = p_player_id
      OR aa.target_player_id = p_player_id
      OR EXISTS (
        SELECT 1
        FROM public.alliance_members am
        WHERE am.alliance_id = aa.alliance_id
          AND am.player_id = p_player_id
          AND aa.created_at >= am.joined_at
      )
    );
$function$;

COMMIT;
