-- TERYNDIS 082 Activity Trade + Alliance V2
-- Extends the existing derived notification feed without adding duplicate event tables.
-- New sources:
-- - delivered trade transactions
-- - alliance activity visible to the actor/target and current members since join time
-- Header unread counts are kept in lockstep with the activity feed.

BEGIN;

CREATE OR REPLACE FUNCTION public.nexora_activity_events(p_player_id bigint)
RETURNS TABLE (
  event_id text,
  event_type text,
  occurred_at timestamptz,
  title text,
  summary text,
  tone text,
  href text,
  meta jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
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

CREATE OR REPLACE FUNCTION public.nexora_header_badges_snapshot(p_player_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_last_seen_at timestamptz;
  v_activity_unread bigint;
  v_message_unread bigint;
  v_friend_incoming bigint;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 OR NOT EXISTS (
    SELECT 1 FROM public.players WHERE id = p_player_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false, 'code', 'PLAYER_NOT_FOUND', 'message', 'Oyuncu bulunamadı.'
    );
  END IF;

  SELECT last_seen_at INTO v_last_seen_at
  FROM public.player_activity_state WHERE player_id = p_player_id;

  -- Strict >, no feed limit and no future-time cutoff, exactly as in 044.
  SELECT SUM(n)::bigint INTO v_activity_unread FROM (
    SELECT COUNT(*) AS n FROM public.battle_reports
    WHERE (attacker_player_id = p_player_id OR defender_player_id = p_player_id)
      AND created_at IS NOT NULL
      AND (v_last_seen_at IS NULL OR created_at > v_last_seen_at)
    UNION ALL
    SELECT COUNT(*) FROM public.npc_battle_reports
    WHERE player_id = p_player_id AND created_at IS NOT NULL
      AND (v_last_seen_at IS NULL OR created_at > v_last_seen_at)
    UNION ALL
    SELECT COUNT(*) FROM public.world_exploration_missions
    WHERE player_id = p_player_id AND status = 'completed' AND completed_at IS NOT NULL
      AND (v_last_seen_at IS NULL OR completed_at > v_last_seen_at)
    UNION ALL
    SELECT COUNT(*) FROM public.player_daily_mission_claims
    WHERE player_id = p_player_id AND claimed_at IS NOT NULL
      AND (v_last_seen_at IS NULL OR claimed_at > v_last_seen_at)
    UNION ALL
    SELECT COUNT(*) FROM public.trade_transactions
    WHERE status = 'delivered'
      AND delivered_at IS NOT NULL
      AND (seller_player_id = p_player_id OR buyer_player_id = p_player_id)
      AND (v_last_seen_at IS NULL OR delivered_at > v_last_seen_at)
    UNION ALL
    SELECT COUNT(*) FROM public.alliance_activity aa
    WHERE aa.created_at IS NOT NULL
      AND (v_last_seen_at IS NULL OR aa.created_at > v_last_seen_at)
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
      )
  ) counts;

  SELECT COUNT(*) INTO v_message_unread
  FROM public.player_private_messages
  WHERE recipient_player_id = p_player_id AND read_at IS NULL;

  -- Requester existence is guaranteed by the existing FK in 047.
  SELECT COUNT(*) INTO v_friend_incoming
  FROM public.player_friendships
  WHERE status = 'pending' AND requester_player_id <> p_player_id
    AND (player_one_id = p_player_id OR player_two_id = p_player_id);

  RETURN jsonb_build_object(
    'success', true,
    'activityUnread', v_activity_unread,
    'messageUnread', v_message_unread,
    'friendIncoming', v_friend_incoming,
    'serverTime', statement_timestamp()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.nexora_activity_events(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_header_badges_snapshot(bigint)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.nexora_activity_events(bigint)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_header_badges_snapshot(bigint)
  TO service_role;

COMMIT;
