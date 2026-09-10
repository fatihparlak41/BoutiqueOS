-- ============================================================
-- BoutiqueOS  •  Phase 4A  •  Team audit log
-- ============================================================
-- Nothing in the schema records who changed a colleague's role, branch, discount
-- ceiling or active flag. platform_audit_log is the wrong home: it is platform
-- authority, unreadable by any tenant on purpose (3.5F).
--
-- Written by a TRIGGER, not by RPCs. business_members is writable directly under
-- the 3.5D policies, so an RPC-only writer would leave every direct UPDATE silently
-- unaudited. A trigger holds for every path, including service_role.
--
-- Multi-field updates: one statement can change role, branch, ceiling and is_active
-- at once. The row records EVERY changed whitelist field in old_values/new_values;
-- `action` narrows to the specific verb only when exactly one field moved, and is
-- 'member_updated' otherwise. Nothing is lost either way.
--
-- Whitelist is closed: role, branch_id, max_discount_pct, is_active. No password,
-- no token, no email ever reaches this table. The invitee's address is reachable
-- through target_invite_id under the same manager+ RLS, so it is not copied here.
-- ============================================================

CREATE TYPE team_audit_action AS ENUM (
  'member_added',
  'member_updated',
  'role_changed',
  'branch_changed',
  'discount_limit_changed',
  'member_deactivated',
  'member_reactivated',
  'member_removed',
  'invite_created',
  'invite_revoked',
  'invite_resent',
  'invite_accepted'
);

CREATE TABLE team_audit_log (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  -- NULL when the write came from a maintenance session with no auth.uid().
  -- An invented actor would be worse than an honest "system".
  actor_user_id    UUID REFERENCES profiles(id) ON DELETE SET NULL,
  target_user_id   UUID REFERENCES profiles(id) ON DELETE SET NULL,
  target_invite_id UUID,                      -- FK added in 4B, once the table exists
  action           team_audit_action NOT NULL,
  old_values       JSONB NOT NULL DEFAULT '{}'::jsonb,
  new_values       JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_team_audit_business ON team_audit_log (business_id, occurred_at DESC);
CREATE INDEX ix_team_audit_target   ON team_audit_log (business_id, target_user_id);

ALTER TABLE team_audit_log ENABLE ROW LEVEL SECURITY;

-- manager+ read. No write policy at all: the trigger and the 4B RPCs are the only
-- writers, exactly like fx_rates.
CREATE POLICY pol_tal_select ON team_audit_log FOR SELECT
  USING (fn_is_manager_plus(business_id));

-- ------------------------------------------------------------
-- writer
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_team_audit(
  p_business_id      UUID,
  p_action           team_audit_action,
  p_target_user_id   UUID DEFAULT NULL,
  p_target_invite_id UUID DEFAULT NULL,
  p_old              JSONB DEFAULT '{}'::jsonb,
  p_new              JSONB DEFAULT '{}'::jsonb
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
BEGIN
  INSERT INTO team_audit_log (business_id, actor_user_id, target_user_id, target_invite_id,
                              action, old_values, new_values)
  VALUES (p_business_id, auth.uid(), p_target_user_id, p_target_invite_id,
          p_action, COALESCE(p_old, '{}'::jsonb), COALESCE(p_new, '{}'::jsonb));
END $$;
REVOKE EXECUTE ON FUNCTION fn_team_audit(UUID, team_audit_action, UUID, UUID, JSONB, JSONB)
  FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- business_members trigger
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_audit_business_member()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
  v_old JSONB := '{}'::jsonb;
  v_new JSONB := '{}'::jsonb;
  v_action team_audit_action;
  v_changed INT := 0;
  v_single TEXT := NULL;
BEGIN
  -- OLD and NEW must never be referenced in the same expression: plpgsql plans the
  -- whole expression, so a branch that merely mentions the unassigned record fails.
  IF TG_OP = 'INSERT' THEN
    PERFORM fn_team_audit(
      NEW.business_id, 'member_added', NEW.user_id, NULL, '{}'::jsonb,
      jsonb_build_object('role', NEW.role, 'branch_id', NEW.branch_id,
                         'max_discount_pct', NEW.max_discount_pct, 'is_active', NEW.is_active));
    RETURN NULL;
  END IF;

  IF TG_OP = 'DELETE' THEN
    PERFORM fn_team_audit(
      OLD.business_id, 'member_removed', OLD.user_id, NULL,
      jsonb_build_object('role', OLD.role, 'branch_id', OLD.branch_id,
                         'max_discount_pct', OLD.max_discount_pct, 'is_active', OLD.is_active),
      '{}'::jsonb);
    RETURN NULL;
  END IF;

  -- UPDATE: collect every changed whitelist field, then name the action.
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    v_old := v_old || jsonb_build_object('role', OLD.role);
    v_new := v_new || jsonb_build_object('role', NEW.role);
    v_changed := v_changed + 1; v_single := 'role';
  END IF;
  IF NEW.branch_id IS DISTINCT FROM OLD.branch_id THEN
    v_old := v_old || jsonb_build_object('branch_id', OLD.branch_id);
    v_new := v_new || jsonb_build_object('branch_id', NEW.branch_id);
    v_changed := v_changed + 1; v_single := 'branch_id';
  END IF;
  IF NEW.max_discount_pct IS DISTINCT FROM OLD.max_discount_pct THEN
    v_old := v_old || jsonb_build_object('max_discount_pct', OLD.max_discount_pct);
    v_new := v_new || jsonb_build_object('max_discount_pct', NEW.max_discount_pct);
    v_changed := v_changed + 1; v_single := 'max_discount_pct';
  END IF;
  IF NEW.is_active IS DISTINCT FROM OLD.is_active THEN
    v_old := v_old || jsonb_build_object('is_active', OLD.is_active);
    v_new := v_new || jsonb_build_object('is_active', NEW.is_active);
    v_changed := v_changed + 1; v_single := 'is_active';
  END IF;

  IF v_changed = 0 THEN
    RETURN NULL;   -- touching joined_at or nothing at all is not a team event
  END IF;

  IF v_changed = 1 THEN
    v_action := CASE v_single
      WHEN 'role'             THEN 'role_changed'
      WHEN 'branch_id'        THEN 'branch_changed'
      WHEN 'max_discount_pct' THEN 'discount_limit_changed'
      WHEN 'is_active'        THEN CASE WHEN NEW.is_active THEN 'member_reactivated' ELSE 'member_deactivated' END
    END::team_audit_action;
  ELSE
    v_action := 'member_updated';
  END IF;

  PERFORM fn_team_audit(NEW.business_id, v_action, NEW.user_id, NULL, v_old, v_new);
  RETURN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION fn_audit_business_member() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_bm_audit
  AFTER INSERT OR UPDATE OR DELETE ON business_members
  FOR EACH ROW EXECUTE FUNCTION fn_audit_business_member();

-- ============================================================
-- END phase 4A
-- ============================================================
