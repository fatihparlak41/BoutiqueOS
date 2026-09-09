-- ============================================================
-- BoutiqueOS  •  Phase 3.5F  •  Platform admin foundation
-- ============================================================
-- Platform authority and tenant authority are different things and must never share a
-- namespace. super_admin is deliberately NOT added to user_role: that enum is written
-- into business_members, which owners (and, since 3.5D, managers) can write — a tenant
-- would be able to mint its own platform administrator.
--
-- So the platform lives in its own tables with their own access rule:
--   platform_admins     who may operate on the platform
--   platform_audit_log  what they did
--
-- Both have RLS enabled and ZERO policies. That is the point: no authenticated user of
-- any tenant can read them, not even an owner. They are reached only through
-- SECURITY DEFINER functions, i.e. through audited operations.
--
-- Equally deliberate: no tenant policy gains an "OR fn_is_platform_admin()" branch. A
-- platform admin does not get blanket SELECT over customer data; they get a small set of
-- narrow operations. T41 asserts that no such branch exists anywhere.
--
-- One operation ships now, because 3.5A can suspend a business and nothing could put it
-- back except its own owner. No UI — RPC and audit trail only.
-- ============================================================

CREATE TABLE platform_admins (
  user_id    UUID PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  is_active  BOOLEAN NOT NULL DEFAULT true,
  note       TEXT,
  granted_by UUID REFERENCES profiles(id),
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE platform_audit_log (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id      UUID NOT NULL REFERENCES profiles(id),
  action             TEXT NOT NULL,
  target_business_id UUID REFERENCES businesses(id),
  payload            JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_platform_audit_business ON platform_audit_log (target_business_id, occurred_at DESC);

-- RLS on, no policies: unreachable from any tenant session.
ALTER TABLE platform_admins     ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform_audit_log  ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform_admins     FORCE ROW LEVEL SECURITY;
ALTER TABLE platform_audit_log  FORCE ROW LEVEL SECURITY;

-- Supabase (and the test harness) grant ALL on new tables to anon/authenticated by
-- default privileges. RLS already blocks them; revoking the grants as well means a
-- future policy added by mistake cannot silently expose the table.
REVOKE ALL ON TABLE platform_admins    FROM anon, authenticated;
REVOKE ALL ON TABLE platform_audit_log FROM anon, authenticated;

-- ------------------------------------------------------------
-- helpers
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_is_platform_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (SELECT 1 FROM platform_admins WHERE user_id = auth.uid() AND is_active);
$$;
REVOKE EXECUTE ON FUNCTION fn_is_platform_admin() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_require_platform_admin()
RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE v UUID := fn_actor();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM platform_admins WHERE user_id = v AND is_active) THEN
    RAISE EXCEPTION 'FORBIDDEN: platform administrator role required' USING ERRCODE='42501';
  END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION fn_require_platform_admin() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- the one platform operation
-- ------------------------------------------------------------
-- Narrow on purpose: it changes businesses.status and nothing else, and every call is
-- written to platform_audit_log in the same transaction.
CREATE OR REPLACE FUNCTION rpc_platform_set_business_status(
  p_business_id UUID,
  p_status      TEXT,
  p_reason      TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v_old business_status;
BEGIN
  IF p_status NOT IN ('active','suspended','cancelled') THEN
    RAISE EXCEPTION 'INVALID_STATUS: %', p_status USING ERRCODE='22023';
  END IF;

  SELECT status INTO v_old FROM businesses WHERE id = p_business_id FOR UPDATE;
  IF v_old IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: business %', p_business_id USING ERRCODE='P0002';
  END IF;

  UPDATE businesses SET status = p_status::business_status, updated_at = now() WHERE id = p_business_id;

  INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, payload)
  VALUES (v_admin, 'set_business_status', p_business_id,
          jsonb_build_object('from', v_old, 'to', p_status, 'reason', p_reason));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_set_business_status(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_set_business_status(UUID, TEXT, TEXT) TO authenticated;

-- ============================================================
-- END phase 3.5F
-- ============================================================
