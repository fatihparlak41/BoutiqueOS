-- ============================================================
-- BoutiqueOS  •  Phase 3.5C  •  business_members read minimisation
-- ============================================================
-- Before: pol_bm_select USING (fn_is_member(business_id)) — every member could read
-- every colleague's row, including role and max_discount_pct (J-4 discount authority).
--
-- After: managers and owners keep full team visibility; everyone else sees only their
-- own membership row. Tenant resolution is unaffected because the application reads
-- business_members filtered by user_id = auth.uid().
--
-- Safe because every authorisation helper (fn_is_member, fn_has_role, fn_my_role,
-- fn_is_manager_plus, fn_is_procurement, fn_my_business_ids, fn_require_member) is
-- SECURITY DEFINER and therefore reads this table without RLS. Narrowing the policy
-- restricts what a client can SELECT, not what the system can decide. T38 asserts that.
--
-- A staff-facing team list, if one is ever needed, gets a dedicated view exposing
-- name/branch only — never role or max_discount_pct. Not created here: no consumer yet.
-- ============================================================

DROP POLICY pol_bm_select ON business_members;
CREATE POLICY pol_bm_select ON business_members FOR SELECT
  USING (fn_is_manager_plus(business_id) OR user_id = auth.uid());

-- ============================================================
-- END phase 3.5C
-- ============================================================
