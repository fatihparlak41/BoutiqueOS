-- ============================================================
-- BoutiqueOS  •  Phase 4C  •  Team directory
-- ============================================================
-- The Team screen needs full name, email, role, branch and status in one place.
-- Three constraints collide:
--
--   * profiles.email does not exist, and denormalising it there would create a
--     second copy of an identity field that Auth already owns.
--   * auth.users is not readable by any client, and must stay that way.
--   * pol_profiles_select is deliberately "own row only" (3.5C-era minimisation),
--     so even an owner cannot read a colleague's display name directly.
--
-- Resolution: a SECURITY DEFINER reader that returns a fixed, safe projection for a
-- single business. Email is read from auth.users inside the function and the output
-- is bounded by business_members of the requested tenant, so nothing can escape the
-- caller's own business.
--
-- Deliberately NOT done: widening pol_profiles_select. The earlier plan proposed it;
-- routing the screen through this reader keeps profiles locked to "own row" and
-- removes a whole class of cross-tenant policy mistakes. Less RLS surface, same UI.
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_list_team(p_business_id UUID)
RETURNS TABLE (
  user_id          UUID,
  full_name        TEXT,
  email            TEXT,
  role             user_role,
  branch_id        UUID,
  branch_name      TEXT,
  is_active        BOOLEAN,
  max_discount_pct NUMERIC,
  joined_at        TIMESTAMPTZ,
  is_self          BOOLEAN
) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
BEGIN
  -- Membership and rank are proved here; sales_staff and stock_staff never get past
  -- this line, and a business_id from another tenant fails the same check.
  IF NOT fn_is_manager_plus(p_business_id) THEN
    RAISE EXCEPTION 'FORBIDDEN: manager or owner role required for the team directory'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT m.user_id,
         p.full_name,
         u.email::text,
         m.role,
         m.branch_id,
         b.name,
         m.is_active,
         m.max_discount_pct,
         m.joined_at,
         (m.user_id = auth.uid())
  FROM business_members m
  JOIN auth.users u ON u.id = m.user_id
  LEFT JOIN profiles p ON p.id = m.user_id
  LEFT JOIN branches b ON b.id = m.branch_id AND b.business_id = m.business_id
  WHERE m.business_id = p_business_id
  ORDER BY m.role, lower(COALESCE(p.full_name, u.email::text));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_list_team(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_list_team(UUID) TO authenticated;

-- Pending/handled invitations are a separate list: they are not memberships yet and
-- carry no user_id. Effective status is derived, so an expired invite never shows as
-- "waiting" (there is no scheduler to flip a stored value).
CREATE OR REPLACE FUNCTION rpc_list_invites(p_business_id UUID)
RETURNS TABLE (
  invite_id        UUID,
  email            TEXT,
  display_name     TEXT,
  role             user_role,
  branch_id        UUID,
  branch_name      TEXT,
  max_discount_pct NUMERIC,
  status           TEXT,
  expires_at       TIMESTAMPTZ,
  invited_by_name  TEXT,
  created_at       TIMESTAMPTZ,
  can_manage       BOOLEAN
) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
BEGIN
  IF NOT fn_is_manager_plus(p_business_id) THEN
    RAISE EXCEPTION 'FORBIDDEN: manager or owner role required for the team directory'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT i.id,
         i.email_normalized,
         i.display_name,
         i.role,
         i.branch_id,
         b.name,
         i.max_discount_pct,
         fn_invite_effective_status(i.status, i.expires_at),
         i.expires_at,
         inviter.full_name,
         i.created_at,
         -- drives the UI: a manager sees an owner's invitation but gets no actions
         fn_can_grant_role(p_business_id, i.role, i.max_discount_pct)
  FROM business_invites i
  LEFT JOIN branches b ON b.id = i.branch_id AND b.business_id = i.business_id
  LEFT JOIN profiles inviter ON inviter.id = i.invited_by
  WHERE i.business_id = p_business_id
  ORDER BY i.created_at DESC;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_list_invites(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_list_invites(UUID) TO authenticated;

-- ============================================================
-- END phase 4C
-- ============================================================
