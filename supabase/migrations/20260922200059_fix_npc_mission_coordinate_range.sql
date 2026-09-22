-- Expand NPC mission coordinate checks to match the 200x200 world map.
ALTER TABLE public.npc_missions
  DROP CONSTRAINT IF EXISTS npc_missions_depart_x_check,
  DROP CONSTRAINT IF EXISTS npc_missions_depart_y_check,
  DROP CONSTRAINT IF EXISTS npc_missions_target_x_check,
  DROP CONSTRAINT IF EXISTS npc_missions_target_y_check,
  ADD CONSTRAINT npc_missions_depart_x_check CHECK (depart_x >= 1 AND depart_x <= 200),
  ADD CONSTRAINT npc_missions_depart_y_check CHECK (depart_y >= 1 AND depart_y <= 200),
  ADD CONSTRAINT npc_missions_target_x_check CHECK (target_x >= 1 AND target_x <= 200),
  ADD CONSTRAINT npc_missions_target_y_check CHECK (target_y >= 1 AND target_y <= 200);
