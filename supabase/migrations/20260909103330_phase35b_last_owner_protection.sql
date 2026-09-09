-- ============================================================
-- BoutiqueOS  •  Phase 3.5B  •  Last owner protection
-- ============================================================
-- Invariant (stated precisely): IF a business currently has an active owner, that last
-- active owner cannot be lost through UPDATE, DELETE or deactivation of the membership
-- row. It is a guard on the TRANSITION, not a guarantee that every business has an owner:
-- a business created with no members at all is untouched by this rule.
--
-- Creating a business together with its first owner atomically is Phase 8 onboarding
-- work; see ADR-14. Until then a freshly created business legitimately has zero owners.
--
-- Why a trigger and not RLS: business_members is writable by owners (and, after
-- 3.5D, by managers for subordinate roles), and future SECURITY DEFINER RPCs will
-- write it too. RLS would only cover the direct-table path. A constraint trigger
-- holds for every writer, including service_role.
--
-- DEFERRABLE INITIALLY DEFERRED so ownership can be transferred inside one
-- transaction in either order (demote-then-promote as well as promote-then-demote).
-- The check runs at COMMIT; it cannot be turned off, only postponed.
--
-- Not fired on INSERT: adding a row can never reduce the owner count.
--
-- Scope: the rule guards a TRANSITION — "this write removed the last owner" — and only
-- fires when the row being changed WAS an active owner. A business that has no owner yet
-- (a tenant seeded before anyone is invited: the pilot seed creates the business and no
-- members at all) must stay editable, otherwise onboarding deadlocks on its first member.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_assert_last_owner()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE v_biz UUID; v_n INT;
BEGIN
  -- OLD is present for both UPDATE and DELETE and names the business that could
  -- have lost an owner. NEW is never referenced: gaining an owner cannot violate.
  -- (NEW must not be touched on DELETE at all — plpgsql plans the whole expression,
  -- so a COALESCE(NEW..., OLD...) would fail with "record new is not assigned yet".)
  v_biz := OLD.business_id;

  -- Only a change to an active owner row can remove the last owner. Anything else --
  -- editing a salesperson, or a business that had no owner to begin with -- is none of
  -- this trigger's business.
  IF NOT (OLD.role = 'owner' AND OLD.is_active) THEN
    RETURN NULL;
  END IF;

  -- The business itself is gone (ON DELETE CASCADE removed its members): nothing to protect.
  IF NOT EXISTS (SELECT 1 FROM businesses WHERE id = v_biz) THEN
    RETURN NULL;
  END IF;

  SELECT count(*) INTO v_n
  FROM business_members
  WHERE business_id = v_biz AND role = 'owner' AND is_active;

  IF v_n = 0 THEN
    RAISE EXCEPTION 'LAST_OWNER: business % must keep at least one active owner', v_biz
      USING ERRCODE = '23514';
  END IF;

  RETURN NULL;
END $$;
REVOKE EXECUTE ON FUNCTION fn_assert_last_owner() FROM PUBLIC, anon, authenticated;

CREATE CONSTRAINT TRIGGER trg_bm_last_owner
  AFTER UPDATE OR DELETE ON business_members
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION fn_assert_last_owner();

-- ============================================================
-- END phase 3.5B
-- ============================================================
