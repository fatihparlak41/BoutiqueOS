-- ============================================================
-- BoutiqueOS  •  Phase 3.5G  •  businesses.status is platform controlled
-- ============================================================
-- 3.5A left pol_businesses_update exempt from the lifecycle check so that a suspended
-- tenant would not be locked out of its own reactivation. That was the wrong model: it
-- also meant a tenant owner could lift a platform suspension imposed for non-payment or
-- abuse. businesses.status is a PLATFORM field, not a tenant field.
--
-- RLS cannot express "this column may not change" — a policy sees one row, not the
-- OLD/NEW pair — so the rule is a BEFORE UPDATE OF status trigger.
--
-- The guard runs SECURITY INVOKER on purpose. A SECURITY DEFINER trigger would see
-- current_user = its own owner (postgres) for every caller, which makes any privilege
-- test inside it meaningless — the guard would wave everyone through. Running as the
-- invoker is what lets it tell a tenant session apart from a maintenance session.
--
-- Three paths, in order:
--
--   1. audited platform path
--      a transaction-local marker naming this exact business AND an active platform_admins
--      row for auth.uid(). Both halves are required and neither is sufficient: the marker
--      is forgeable (set_config is not privileged) but platform admin status is not, and a
--      platform admin who edits the table directly has no marker and is refused — which is
--      what makes the audit row unavoidable rather than merely customary.
--
--   2. break-glass maintenance
--      no marker, and BOTH current_user and session_user are superuser/BYPASSRLS roles.
--      session_user survives SET ROLE and SECURITY DEFINER, so this cannot be reached from
--      a PostgREST session: there session_user is the authenticator role, which is neither.
--      Requiring both is what stops a future SECURITY DEFINER function owned by postgres
--      from silently inheriting the maintenance path — current_user would be postgres, but
--      session_user would still be the authenticator.
--      This is bootstrap (appointing the first platform admin) and disaster recovery. It is
--      the only unaudited path and it needs database credentials.
--
--   3. everything else -> PLATFORM_MANAGED_FIELD
--
-- Harness note: the plain-PostgreSQL shim logs in as postgres and only does SET ROLE, so
-- session_user is postgres there even for a "tenant" session. current_user still separates
-- them correctly, which is why both are required rather than either.
--
-- pol_businesses_update is intentionally left as it was: an owner still edits name,
-- address, phone, email, logo and settings. Only status is taken away from them.
-- ============================================================

-- The invoker-side guard has to be able to ask "is the caller a platform admin?", so this
-- predicate becomes callable by authenticated. It answers only about the current user and
-- exposes no row of platform_admins, which stays unreadable (RLS + revoked grants).
GRANT EXECUTE ON FUNCTION fn_is_platform_admin() TO authenticated;

CREATE OR REPLACE FUNCTION fn_guard_business_status()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = pg_catalog, public AS $$
DECLARE v_marker TEXT; v_cur BOOLEAN; v_sess BOOLEAN;
BEGIN
  -- Mentioning status in the SET list without changing it is not a status change.
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  v_marker := NULLIF(current_setting('boutiqueos.platform_status_change', true), '');

  -- 1. audited platform path
  IF v_marker IS NOT NULL AND v_marker = NEW.id::text AND fn_is_platform_admin() THEN
    RETURN NEW;
  END IF;

  -- 2. break-glass maintenance
  SELECT COALESCE(bool_or(rolsuper OR rolbypassrls), false) INTO v_cur
  FROM pg_roles WHERE rolname = current_user;
  SELECT COALESCE(bool_or(rolsuper OR rolbypassrls), false) INTO v_sess
  FROM pg_roles WHERE rolname = session_user;

  IF v_marker IS NULL AND v_cur AND v_sess THEN
    RETURN NEW;
  END IF;

  -- 3. refuse
  RAISE EXCEPTION
    'PLATFORM_MANAGED_FIELD: businesses.status is platform controlled; use rpc_platform_set_business_status (business %, % -> %)',
    NEW.id, OLD.status, NEW.status
    USING ERRCODE = '42501';
END $$;
-- EXECUTE is only checked when the trigger is created, never when it fires, so the guard
-- stays uncallable as a plain function.
REVOKE EXECUTE ON FUNCTION fn_guard_business_status() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_businesses_status_guard
  BEFORE UPDATE OF status ON businesses
  FOR EACH ROW EXECUTE FUNCTION fn_guard_business_status();

-- ------------------------------------------------------------
-- the platform RPC now announces itself to the guard
-- ------------------------------------------------------------
-- set_config(..., is_local => true) so the marker dies with the transaction and can never
-- leak into a later statement on a pooled connection. It is cleared right after the UPDATE
-- as well, so the window is one statement wide.
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

  PERFORM set_config('boutiqueos.platform_status_change', p_business_id::text, true);
  UPDATE businesses SET status = p_status::business_status, updated_at = now() WHERE id = p_business_id;
  PERFORM set_config('boutiqueos.platform_status_change', '', true);

  INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, payload)
  VALUES (v_admin, 'set_business_status', p_business_id,
          jsonb_build_object('from', v_old, 'to', p_status, 'reason', p_reason));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_set_business_status(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_set_business_status(UUID, TEXT, TEXT) TO authenticated;

-- ============================================================
-- END phase 3.5G
-- ============================================================
