-- ============================================================
-- BoutiqueOS  •  Phase 3.5D  •  Manager subordinate role management
-- ============================================================
-- Until now business_members was owner-only, so a store manager could not add a new
-- salesperson without the owner. This grants managers a strictly bounded slice:
--
--   may create / edit / remove rows whose role is sales_staff or stock_staff
--   may NOT create or touch an owner or manager row
--   may NOT touch their own row (no self-promotion, no self-demotion)
--   may NOT grant a discount ceiling above their own
--
-- Mechanics: policies are permissive, so the new manager policy is OR'ed with the
-- existing owner policy. Owners are unaffected — and still bound by 3.5B.
--
-- FOR ALL splits the checks the way the escalation paths need:
--   UPDATE -> USING sees the OLD row (cannot pick an owner/manager as target)
--          -> WITH CHECK sees the NEW row (cannot promote the target upward)
--   INSERT -> WITH CHECK only
--   DELETE -> USING only
--
-- max_discount_pct note: the column defaults to 0 and, per J-4, is only consulted for
-- sales_staff — a manager's own value is "not configured" until an owner sets it. The
-- cap below is therefore fail-closed: a manager with an unset ceiling can grant 0.
-- Raising a manager's authority stays an owner decision.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_my_max_discount(p_business_id UUID)
RETURNS NUMERIC LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(
    (SELECT max_discount_pct FROM business_members
      WHERE business_id = p_business_id AND user_id = auth.uid() AND is_active),
    0);
$$;
REVOKE EXECUTE ON FUNCTION fn_my_max_discount(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_my_max_discount(UUID) TO authenticated;

CREATE POLICY pol_bm_write_manager ON business_members FOR ALL
  USING (
    fn_has_role(business_id, ARRAY['manager']::user_role[])
    AND fn_is_business_active(business_id)
    AND role IN ('sales_staff','stock_staff')
    AND user_id <> auth.uid()
  )
  WITH CHECK (
    fn_has_role(business_id, ARRAY['manager']::user_role[])
    AND fn_is_business_active(business_id)
    AND role IN ('sales_staff','stock_staff')
    AND user_id <> auth.uid()
    AND max_discount_pct <= fn_my_max_discount(business_id)
  );

-- ============================================================
-- END phase 3.5D
-- ============================================================
