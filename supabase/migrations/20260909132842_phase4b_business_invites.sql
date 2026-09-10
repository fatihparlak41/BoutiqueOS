-- ============================================================
-- BoutiqueOS  •  Phase 4B  •  Tenant invitations
-- ============================================================
-- The invite record is the tenant authority. How the Auth account is delivered is a
-- delivery detail that grants nothing: without a matching invite row no membership
-- can ever come into existence.
--
-- NO SEPARATE INVITE TOKEN. The first draft carried a random secret with a stored
-- sha256. It was removed, deliberately, because it buys no security property that
-- the identity binding does not already provide:
--
--   acceptance requires an authenticated user, whose CONFIRMED address equals
--   invite.email_normalized. Whoever can satisfy that already controls the invited
--   mailbox — which is exactly who the invitation was for.
--
-- So business_invites.id is an identifier, not a capability. A secret token would
-- have to travel somewhere (Auth user_metadata, a cookie, browser storage) and every
-- one of those is a worse place for authorisation state than the row itself.
--
-- The id is a v4 UUID. Learning that some id exists reveals no address, tenant or
-- role, and only a manager+ of that tenant can list ids in the first place.
--
-- Other design points:
--
--  * business_id is an explicit parameter and is re-proved against the caller's real
--    membership. A client naming another tenant is refused by fn_require_member.
--  * 'expired' is NOT an enum value. Without a scheduler nothing would perform the
--    transition and invites would sit "pending" forever. Expiry is derived at read
--    time (fn_invite_effective_status).
--  * An invite is never a second way to change an existing member's role. An active
--    member gets ALREADY_MEMBER; an inactive one is sent to the explicit reactivate
--    action. Role, branch and ceiling changes belong to membership management only.
--  * Acceptance is genuinely idempotent: opening the same link twice succeeds twice
--    for the same person and never produces a second membership.
-- ============================================================

CREATE TYPE invite_status AS ENUM ('pending', 'accepted', 'revoked');

CREATE TABLE business_invites (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  email_normalized TEXT NOT NULL,
  display_name     TEXT,
  role             user_role NOT NULL,
  branch_id        UUID,
  max_discount_pct NUMERIC(5,2) NOT NULL DEFAULT 0
                   CHECK (max_discount_pct >= 0 AND max_discount_pct <= 100),
  status           invite_status NOT NULL DEFAULT 'pending',
  invited_by       UUID REFERENCES profiles(id) ON DELETE SET NULL,
  expires_at       TIMESTAMPTZ NOT NULL,
  accepted_at      TIMESTAMPTZ,
  accepted_by      UUID REFERENCES profiles(id) ON DELETE SET NULL,
  revoked_at       TIMESTAMPTZ,
  revoked_by       UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, id),
  -- a branch from another tenant cannot be referenced, enforced by the composite FK
  FOREIGN KEY (business_id, branch_id) REFERENCES branches (business_id, id),
  -- normalisation is a database invariant: lower()/trim() in SQL, never a Turkish
  -- locale toLocaleLowerCase() in JS, which would fold "I" to "ı" and break matching
  CONSTRAINT chk_invite_email_norm CHECK (email_normalized = lower(trim(email_normalized))
                                          AND length(email_normalized) > 0),
  CONSTRAINT chk_invite_accepted CHECK (
    (status = 'accepted') = (accepted_at IS NOT NULL AND accepted_by IS NOT NULL)),
  CONSTRAINT chk_invite_revoked CHECK ((status = 'revoked') = (revoked_at IS NOT NULL))
);

-- At most one live invite per (tenant, address). The same address may be invited by
-- a different tenant at the same time — the index is business-scoped, not global.
CREATE UNIQUE INDEX uix_invite_pending_per_business
  ON business_invites (business_id, email_normalized) WHERE status = 'pending';
CREATE INDEX ix_invite_business_status ON business_invites (business_id, status, created_at DESC);

ALTER TABLE business_invites ENABLE ROW LEVEL SECURITY;

-- manager+ read. No write policy: the RPCs below are the only writers.
CREATE POLICY pol_invite_select ON business_invites FOR SELECT
  USING (fn_is_manager_plus(business_id));

-- 4A left this column unconstrained because the table did not exist yet.
ALTER TABLE team_audit_log
  ADD CONSTRAINT fk_tal_invite FOREIGN KEY (target_invite_id)
  REFERENCES business_invites(id) ON DELETE SET NULL;

-- ------------------------------------------------------------
-- helpers
-- ------------------------------------------------------------
-- Derived status. A function rather than a stored value so no scheduler is needed
-- and a pending invite can never look live after its expiry.
CREATE OR REPLACE FUNCTION fn_invite_effective_status(p_status invite_status, p_expires_at TIMESTAMPTZ)
RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN p_status = 'pending' AND p_expires_at < now() THEN 'expired'
    ELSE p_status::text
  END;
$$;
REVOKE EXECUTE ON FUNCTION fn_invite_effective_status(invite_status, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION fn_invite_effective_status(invite_status, TIMESTAMPTZ) TO authenticated;

-- The single definition of "may the caller hand out this role with this ceiling".
-- Mirrors pol_bm_write / pol_bm_write_manager so invitation and direct membership
-- editing can never drift apart.
CREATE OR REPLACE FUNCTION fn_can_grant_role(p_business_id UUID, p_role user_role, p_max_discount NUMERIC)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT CASE
    WHEN fn_has_role(p_business_id, ARRAY['owner']::user_role[]) THEN true
    WHEN fn_has_role(p_business_id, ARRAY['manager']::user_role[]) THEN
      p_role IN ('sales_staff','stock_staff')
      AND COALESCE(p_max_discount, 0) <= fn_my_max_discount(p_business_id)
    ELSE false
  END;
$$;
REVOKE EXECUTE ON FUNCTION fn_can_grant_role(UUID, user_role, NUMERIC) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_can_grant_role(UUID, user_role, NUMERIC) TO authenticated;

-- "May the caller act on this member?" Used by membership actions that are not plain
-- table writes — password reset above all, which must not rely on UI hiding.
CREATE OR REPLACE FUNCTION fn_can_manage_member(p_business_id UUID, p_target_user_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM business_members t
    WHERE t.business_id = p_business_id
      AND t.user_id = p_target_user_id
      AND (
        fn_has_role(p_business_id, ARRAY['owner']::user_role[])
        OR (fn_has_role(p_business_id, ARRAY['manager']::user_role[])
            AND t.role IN ('sales_staff','stock_staff'))
      ));
$$;
REVOKE EXECUTE ON FUNCTION fn_can_manage_member(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_can_manage_member(UUID, UUID) TO authenticated;

-- ------------------------------------------------------------
-- rpc_create_invite
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_create_invite(
  p_business_id      UUID,
  p_email            TEXT,
  p_display_name     TEXT DEFAULT NULL,
  p_role             user_role DEFAULT 'sales_staff',
  p_branch_id        UUID DEFAULT NULL,
  p_max_discount_pct NUMERIC DEFAULT 0,
  p_expires_in_days  INTEGER DEFAULT 7
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_email TEXT; v_id UUID; v_target UUID; v_active BOOLEAN;
BEGIN
  -- The caller's membership in THIS business is proved against the database. A
  -- business_id naming a tenant the caller does not belong to dies here, and a
  -- suspended tenant cannot invite at all.
  PERFORM fn_require_member(p_business_id);

  IF NOT fn_can_grant_role(p_business_id, p_role, p_max_discount_pct) THEN
    RAISE EXCEPTION 'FORBIDDEN: not allowed to grant role % in business %', p_role, p_business_id
      USING ERRCODE = '42501';
  END IF;

  v_email := lower(trim(COALESCE(p_email, '')));
  IF v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION 'INVALID_EMAIL: %', p_email USING ERRCODE = '22023';
  END IF;

  IF p_expires_in_days IS NULL OR p_expires_in_days < 1 OR p_expires_in_days > 30 THEN
    RAISE EXCEPTION 'INVALID_EXPIRY: % days', p_expires_in_days USING ERRCODE = '22023';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    PERFORM fn_assert_branch(p_business_id, p_branch_id);
  END IF;

  -- An invite must never become a second privilege path onto an existing member.
  SELECT u.id INTO v_target FROM auth.users u WHERE lower(u.email) = v_email;
  IF v_target IS NOT NULL THEN
    SELECT m.is_active INTO v_active
    FROM business_members m WHERE m.business_id = p_business_id AND m.user_id = v_target;
    IF v_active THEN
      RAISE EXCEPTION 'ALREADY_MEMBER: % is already an active member', v_email USING ERRCODE = '23505';
    ELSIF v_active IS NOT NULL THEN
      RAISE EXCEPTION 'MEMBER_INACTIVE_USE_REACTIVATE: % is an inactive member; reactivate instead of inviting', v_email
        USING ERRCODE = '23505';
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM business_invites
              WHERE business_id = p_business_id AND email_normalized = v_email AND status = 'pending') THEN
    RAISE EXCEPTION 'INVITE_ALREADY_PENDING: % already has a pending invitation', v_email
      USING ERRCODE = '23505';
  END IF;

  INSERT INTO business_invites (business_id, email_normalized, display_name, role, branch_id,
                                max_discount_pct, invited_by, expires_at)
  VALUES (p_business_id, v_email, nullif(trim(COALESCE(p_display_name, '')), ''), p_role, p_branch_id,
          COALESCE(p_max_discount_pct, 0), fn_actor(),
          now() + make_interval(days => p_expires_in_days))
  RETURNING id INTO v_id;

  -- The address is not copied into the audit payload: target_invite_id already leads
  -- to it, under the same manager+ RLS.
  PERFORM fn_team_audit(p_business_id, 'invite_created', NULL, v_id, '{}'::jsonb,
    jsonb_build_object('role', p_role, 'branch_id', p_branch_id,
                       'max_discount_pct', COALESCE(p_max_discount_pct, 0)));

  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_create_invite(UUID, TEXT, TEXT, user_role, UUID, NUMERIC, INTEGER)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_create_invite(UUID, TEXT, TEXT, user_role, UUID, NUMERIC, INTEGER)
  TO authenticated;

-- ------------------------------------------------------------
-- rpc_invite_delivery_target
-- ------------------------------------------------------------
-- The server action that sends the mail must not take the address from the client.
-- This returns the authoritative address of an invitation the caller may manage.
CREATE OR REPLACE FUNCTION rpc_invite_delivery_target(p_invite_id UUID)
RETURNS TABLE (business_id UUID, email TEXT, display_name TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE inv RECORD;
BEGIN
  SELECT * INTO inv FROM business_invites WHERE id = p_invite_id;
  IF inv.id IS NULL THEN
    RAISE EXCEPTION 'INVITE_NOT_FOUND: %', p_invite_id USING ERRCODE = 'P0002';
  END IF;
  IF NOT fn_is_manager_plus(inv.business_id)
     OR NOT fn_can_grant_role(inv.business_id, inv.role, inv.max_discount_pct) THEN
    RAISE EXCEPTION 'FORBIDDEN: not allowed to manage this invitation' USING ERRCODE = '42501';
  END IF;
  IF inv.status <> 'pending' THEN
    RAISE EXCEPTION 'INVITE_NOT_PENDING: invitation is %', inv.status USING ERRCODE = '55000';
  END IF;
  RETURN QUERY SELECT inv.business_id, inv.email_normalized, inv.display_name, inv.expires_at;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_invite_delivery_target(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_invite_delivery_target(UUID) TO authenticated;

-- ------------------------------------------------------------
-- rpc_revoke_invite
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_revoke_invite(p_invite_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE inv RECORD;
BEGIN
  SELECT * INTO inv FROM business_invites WHERE id = p_invite_id FOR UPDATE;
  IF inv.id IS NULL THEN
    RAISE EXCEPTION 'INVITE_NOT_FOUND: %', p_invite_id USING ERRCODE = 'P0002';
  END IF;
  PERFORM fn_require_member(inv.business_id);
  -- a manager cannot revoke an invitation they could not have created
  IF NOT fn_can_grant_role(inv.business_id, inv.role, inv.max_discount_pct) THEN
    RAISE EXCEPTION 'FORBIDDEN: not allowed to manage this invitation' USING ERRCODE = '42501';
  END IF;
  IF inv.status <> 'pending' THEN
    RAISE EXCEPTION 'INVITE_NOT_PENDING: invitation is %', inv.status USING ERRCODE = '55000';
  END IF;

  UPDATE business_invites
  SET status = 'revoked', revoked_at = now(), revoked_by = fn_actor()
  WHERE id = p_invite_id;

  PERFORM fn_team_audit(inv.business_id, 'invite_revoked', NULL, p_invite_id,
    jsonb_build_object('status', 'pending'), jsonb_build_object('status', 'revoked'));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_revoke_invite(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_revoke_invite(UUID) TO authenticated;

-- ------------------------------------------------------------
-- rpc_resend_invite  (extends the deadline; the link itself never changes)
-- ------------------------------------------------------------
-- With no secret token there is nothing to rotate: the link is /davet/<invite id>
-- and stays valid for exactly as long as the invitation does.
CREATE OR REPLACE FUNCTION rpc_resend_invite(p_invite_id UUID, p_expires_in_days INTEGER DEFAULT 7)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE inv RECORD;
BEGIN
  SELECT * INTO inv FROM business_invites WHERE id = p_invite_id FOR UPDATE;
  IF inv.id IS NULL THEN
    RAISE EXCEPTION 'INVITE_NOT_FOUND: %', p_invite_id USING ERRCODE = 'P0002';
  END IF;
  PERFORM fn_require_member(inv.business_id);
  IF NOT fn_can_grant_role(inv.business_id, inv.role, inv.max_discount_pct) THEN
    RAISE EXCEPTION 'FORBIDDEN: not allowed to manage this invitation' USING ERRCODE = '42501';
  END IF;
  -- an expired invitation is still stored as pending, so resending revives it
  IF inv.status <> 'pending' THEN
    RAISE EXCEPTION 'INVITE_NOT_PENDING: invitation is %', inv.status USING ERRCODE = '55000';
  END IF;
  IF p_expires_in_days IS NULL OR p_expires_in_days < 1 OR p_expires_in_days > 30 THEN
    RAISE EXCEPTION 'INVALID_EXPIRY: % days', p_expires_in_days USING ERRCODE = '22023';
  END IF;

  UPDATE business_invites SET expires_at = now() + make_interval(days => p_expires_in_days)
  WHERE id = p_invite_id;

  PERFORM fn_team_audit(inv.business_id, 'invite_resent', NULL, p_invite_id, '{}'::jsonb,
    jsonb_build_object('expires_in_days', p_expires_in_days));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_resend_invite(UUID, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_resend_invite(UUID, INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- rpc_accept_invite
-- ------------------------------------------------------------
-- Returns (business_id, already_member). `already_member` true means the call was a
-- no-op: the same person had already accepted, or was already an active member.
--
-- Every value that decides anything comes from the invitation row and from the Auth
-- account. business_id, role, branch and ceiling are never read from the client; the
-- acting identity is auth.uid() and the address is read from auth.users rather than
-- the JWT payload, which can be stale. The account's address must be confirmed: an
-- unverified address must not be able to claim a seat.
CREATE OR REPLACE FUNCTION rpc_accept_invite(p_invite_id UUID)
RETURNS TABLE (business_id UUID, already_member BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_user UUID := fn_actor();
  v_email TEXT; v_confirmed TIMESTAMPTZ;
  inv RECORD; v_member RECORD;
BEGIN
  SELECT lower(trim(u.email)), u.email_confirmed_at INTO v_email, v_confirmed
  FROM auth.users u WHERE u.id = v_user;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED: no account for the acting user' USING ERRCODE = '42501';
  END IF;
  IF v_confirmed IS NULL THEN
    RAISE EXCEPTION 'EMAIL_NOT_CONFIRMED: confirm your address before accepting' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO inv FROM business_invites WHERE id = p_invite_id FOR UPDATE;
  IF inv.id IS NULL THEN
    RAISE EXCEPTION 'INVITE_NOT_FOUND: unknown invitation' USING ERRCODE = 'P0002';
  END IF;

  -- The address is checked before any status branch, so a wrong recipient learns
  -- nothing about the invitation's state.
  IF inv.email_normalized <> v_email THEN
    RAISE EXCEPTION 'INVITE_EMAIL_MISMATCH: this invitation is for another address'
      USING ERRCODE = '42501';
  END IF;

  IF inv.status = 'revoked' THEN
    RAISE EXCEPTION 'INVITE_REVOKED: this invitation was withdrawn' USING ERRCODE = '55000';
  END IF;

  -- Idempotency: the same person opening the same link again succeeds quietly.
  IF inv.status = 'accepted' THEN
    IF inv.accepted_by = v_user THEN
      RETURN QUERY SELECT inv.business_id, true;
      RETURN;
    END IF;
    RAISE EXCEPTION 'INVITE_ALREADY_USED: this invitation was already accepted' USING ERRCODE = '55000';
  END IF;

  IF inv.expires_at < now() THEN
    RAISE EXCEPTION 'INVITE_EXPIRED: this invitation has expired' USING ERRCODE = '55000';
  END IF;

  PERFORM fn_require_active_business(inv.business_id);

  SELECT * INTO v_member FROM business_members m
  WHERE m.business_id = inv.business_id AND m.user_id = v_user FOR UPDATE;

  IF v_member.id IS NOT NULL AND NOT v_member.is_active THEN
    -- Accepting must never silently restore a membership an owner switched off.
    RAISE EXCEPTION 'MEMBER_INACTIVE_USE_REACTIVATE: your membership is inactive; ask an owner to reactivate it'
      USING ERRCODE = '55000';
  END IF;

  IF v_member.id IS NULL THEN
    INSERT INTO business_members (business_id, user_id, role, branch_id, max_discount_pct)
    VALUES (inv.business_id, v_user, inv.role, inv.branch_id, inv.max_discount_pct);
  END IF;
  -- An already-active member simply satisfies the invitation; role is NOT rewritten.

  -- Fill a blank display name, never overwrite one the person already set.
  IF inv.display_name IS NOT NULL THEN
    UPDATE profiles SET full_name = inv.display_name, updated_at = now()
    WHERE id = v_user AND (full_name IS NULL OR trim(full_name) = '');
  END IF;

  UPDATE business_invites
  SET status = 'accepted', accepted_at = now(), accepted_by = v_user
  WHERE id = inv.id;

  PERFORM fn_team_audit(inv.business_id, 'invite_accepted', v_user, inv.id,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', 'accepted', 'role', inv.role));

  RETURN QUERY SELECT inv.business_id, (v_member.id IS NOT NULL);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_accept_invite(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_accept_invite(UUID) TO authenticated;

-- ============================================================
-- END phase 4B
-- ============================================================
