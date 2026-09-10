-- ============================================================
-- BoutiqueOS  •  Phase 4D  •  Password reset authority
-- ============================================================
-- "Send a reset link" is an action an owner or manager triggers against somebody
-- else's account. Two things must not be true of it:
--
--   * it must not rely on the UI hiding the button, and
--   * it must not take the target address from the client. A server action that
--     accepts an email and forwards it to resetPasswordForEmail is an open mail
--     relay pointed at Supabase's rate limit.
--
-- So the caller names a member — business + user id — and the database decides both
-- whether that is allowed and what address the mail goes to.
--
--   owner    -> any member of their own tenant
--   manager  -> sales_staff and stock_staff only, never an owner or another manager
--   anyone else, or a target outside the tenant -> refused
--
-- The address is returned to the caller, who is manager+ and already sees it in the
-- team directory, so this reveals nothing new. It is never returned for a target the
-- caller may not manage.
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_reset_target_email(p_business_id UUID, p_target_user_id UUID)
RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE v_email TEXT;
BEGIN
  -- membership, rank and the subordinate rule in one place
  IF NOT fn_can_manage_member(p_business_id, p_target_user_id) THEN
    RAISE EXCEPTION 'FORBIDDEN: not allowed to act on this member' USING ERRCODE = '42501';
  END IF;

  SELECT lower(trim(u.email)) INTO v_email FROM auth.users u WHERE u.id = p_target_user_id;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: no account for this member' USING ERRCODE = 'P0002';
  END IF;

  RETURN v_email;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_reset_target_email(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_reset_target_email(UUID, UUID) TO authenticated;

-- ============================================================
-- END phase 4D
-- ============================================================
