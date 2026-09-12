-- World V4: strategic ownership. Apply after 006_phase5_audit_fixes.sql. Existing rows/history stay intact.
BEGIN;

ALTER TABLE public.world_sites
  ADD COLUMN IF NOT EXISTS owner_player_id bigint,
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz;
CREATE INDEX IF NOT EXISTS idx_world_sites_owner ON public.world_sites(owner_player_id);
CREATE INDEX IF NOT EXISTS idx_world_explore_completed_site
  ON public.world_exploration_missions(player_id, site_id) WHERE status = 'completed';

CREATE OR REPLACE FUNCTION public.nexora_claim_world_site(p_player_id bigint, p_site_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_site public.world_sites%ROWTYPE;
BEGIN
  IF p_player_id IS NULL OR p_player_id <= 0 OR p_site_id IS NULL OR p_site_id <= 0 THEN
    RETURN jsonb_build_object('success', false, 'code', 'INVALID_ID', 'message', 'Geçersiz oyuncu veya nokta.');
  END IF;
  -- Serialize this player's claims even when they target different sites.
  PERFORM id FROM public.players WHERE id = p_player_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'code', 'PLAYER_NOT_FOUND', 'message', 'Oyuncu bulunamadı.');
  END IF;
  -- Competing players cannot both acquire this row.
  SELECT * INTO v_site FROM public.world_sites WHERE id = p_site_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'code', 'SITE_NOT_FOUND', 'message', 'Dünya noktası bulunamadı.');
  END IF;
  IF v_site.active IS DISTINCT FROM true OR v_site.site_type = 'alliance' THEN
    RETURN jsonb_build_object('success', false, 'code', 'SITE_DISABLED', 'message', 'Bu nokta kontrol altına alınamaz.');
  END IF;
  IF v_site.owner_player_id = p_player_id THEN
    RETURN jsonb_build_object('success', true, 'alreadyOwned', true, 'siteId', v_site.id,
      'owner_player_id', p_player_id, 'claimed_at', v_site.claimed_at, 'message', 'Bu nokta zaten senin kontrolünde.');
  END IF;
  IF v_site.owner_player_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'SITE_OWNED', 'message', 'Bu nokta başka bir oyuncunun kontrolünde.');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.world_exploration_missions
    WHERE player_id = p_player_id AND site_id = p_site_id AND status = 'completed') THEN
    RETURN jsonb_build_object('success', false, 'code', 'EXPLORATION_REQUIRED', 'message', 'Önce bu noktanın keşfini tamamlamalısın.');
  END IF;
  IF (SELECT count(*) FROM public.world_sites WHERE owner_player_id = p_player_id) >= 2 THEN
    RETURN jsonb_build_object('success', false, 'code', 'CLAIM_LIMIT', 'message', 'En fazla 2 stratejik nokta kontrol edebilirsin.');
  END IF;
  UPDATE public.world_sites SET owner_player_id = p_player_id, claimed_at = now()
   WHERE id = p_site_id RETURNING * INTO v_site;
  RETURN jsonb_build_object('success', true, 'alreadyOwned', false, 'siteId', v_site.id,
    'owner_player_id', p_player_id, 'claimed_at', v_site.claimed_at, 'message', 'Nokta kontrol altına alındı.');
END;
$$;

-- One snapshot supplies eligibility and all-time completed exploration history;
-- it does not depend on the Data API row limit or expose another player's missions.
CREATE OR REPLACE FUNCTION public.nexora_world_control_sites(p_player_id bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(jsonb_agg(to_jsonb(s) || jsonb_build_object(
    'owner_username', p.username,
    'has_explored', EXISTS (SELECT 1 FROM public.world_exploration_missions m
      WHERE m.player_id = p_player_id AND m.site_id = s.id AND m.status = 'completed'),
    'can_claim', s.site_type <> 'alliance' AND s.owner_player_id IS NULL
      AND (SELECT count(*) FROM public.world_sites WHERE owner_player_id = p_player_id) < 2
      AND EXISTS (SELECT 1 FROM public.world_exploration_missions m
        WHERE m.player_id = p_player_id AND m.site_id = s.id AND m.status = 'completed')
  ) ORDER BY s.id), '[]'::jsonb)
  FROM public.world_sites s LEFT JOIN public.players p ON p.id = s.owner_player_id
  WHERE s.active = true;
$$;

REVOKE ALL ON FUNCTION public.nexora_claim_world_site(bigint,bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_world_control_sites(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_claim_world_site(bigint,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_world_control_sites(bigint) TO service_role;

-- Claim trusts completed missions and ownership; clients cannot forge either.
-- Preserve Phase 5 bodies, signatures and backend access.
REVOKE ALL ON FUNCTION public.nexora_start_world_exploration(bigint,bigint,integer,numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.nexora_resolve_world_exploration(bigint,bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.world_exploration_missions FROM PUBLIC, anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.world_sites FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.nexora_start_world_exploration(bigint,bigint,integer,numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public.nexora_resolve_world_exploration(bigint,bigint) TO service_role;
GRANT ALL ON TABLE public.world_exploration_missions, public.world_sites TO service_role;

COMMIT;
