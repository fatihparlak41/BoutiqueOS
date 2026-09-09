-- ============================================================
-- BoutiqueOS  •  Phase 3.5E  •  Sales visibility hardening
-- ============================================================
-- Before: pol_sales_select USING (fn_is_member(business_id)) — and the same for
-- sale_items, sale_payments, returns, return_items, register_sessions,
-- register_session_currency_counts and cash_movements. Every salesperson could read
-- the whole company's turnover, discounts, customers and colleagues' performance.
-- Cost was protected (sale_item_costs / sale_costs are manager+), revenue was not.
--
-- After: visibility is a tenant policy, not a constant. businesses.settings carries
--   sales_visibility_scope : 'own' | 'branch' | 'business'
-- and every affected table resolves through one predicate, so 'branch' and 'business'
-- work the day a tenant asks for them without touching a policy again.
--
-- Fail-closed by design: an absent or unrecognised setting resolves to 'own', the most
-- restrictive value. A policy must never raise (that would make the table unreadable),
-- so this is the one place the "missing key => error" rule of fn_setting is replaced by
-- "missing key => the tightest option". The merge below then gives every existing
-- business an explicit value.
--
-- Child tables resolve through SECURITY DEFINER helpers rather than an EXISTS over
-- sales, so nothing depends on RLS-within-RLS evaluation order.
--
-- Manager and owner keep full business-wide visibility. Cost tables are NOT touched:
-- sale_item_costs, sale_costs, inventory_movement_costs and variant_cost_pools stay
-- manager+ exactly as they were.
-- ============================================================

-- ------------------------------------------------------------
-- settings  (merge, never overwrite)
-- ------------------------------------------------------------
-- jsonb_build_object(...) || settings puts the stored value on the right, so an
-- existing key always wins and only absent keys receive the default.
-- default_charge_allocation_method is carried here too: it is the Phase 6 landed-cost
-- allocation policy, stored as tenant data now so no allocation rule is ever compiled
-- into application code.
UPDATE businesses
SET settings = jsonb_build_object(
      'sales_visibility_scope', 'own',
      'default_charge_allocation_method', 'invoice_value_proportional'
    ) || settings,
    updated_at = now()
WHERE NOT (settings ? 'sales_visibility_scope')
   OR NOT (settings ? 'default_charge_allocation_method');

-- ------------------------------------------------------------
-- helpers
-- ------------------------------------------------------------
-- Internal: only ever called from the SECURITY DEFINER predicates below.
CREATE OR REPLACE FUNCTION fn_sales_visibility_scope(p_business_id UUID)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(
    (SELECT settings ->> 'sales_visibility_scope' FROM businesses
      WHERE id = p_business_id
        AND settings ->> 'sales_visibility_scope' IN ('own','branch','business')),
    'own');
$$;
REVOKE EXECUTE ON FUNCTION fn_sales_visibility_scope(UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_my_branch(p_business_id UUID)
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT branch_id FROM business_members
  WHERE business_id = p_business_id AND user_id = auth.uid() AND is_active;
$$;
REVOKE EXECUTE ON FUNCTION fn_my_branch(UUID) FROM PUBLIC, anon, authenticated;

-- The single sales predicate. 'own' is always granted on top of the configured scope:
-- a salesperson can always see what they themselves sold.
CREATE OR REPLACE FUNCTION fn_can_see_sale(p_business_id UUID, p_sold_by UUID, p_branch_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT fn_is_manager_plus(p_business_id)
      OR (
        fn_is_member(p_business_id) AND (
          p_sold_by = auth.uid()
          OR fn_sales_visibility_scope(p_business_id) = 'business'
          OR (fn_sales_visibility_scope(p_business_id) = 'branch'
              AND fn_my_branch(p_business_id) IS NOT NULL
              AND fn_my_branch(p_business_id) = p_branch_id)
        )
      );
$$;
REVOKE EXECUTE ON FUNCTION fn_can_see_sale(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_can_see_sale(UUID, UUID, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_can_see_sale_id(p_sale_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM sales s
    WHERE s.id = p_sale_id
      AND fn_can_see_sale(s.business_id, s.sold_by, s.branch_id));
$$;
REVOKE EXECUTE ON FUNCTION fn_can_see_sale_id(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_can_see_sale_id(UUID) TO authenticated;

-- A return is visible to whoever processed it, plus anyone who may see the sale it came from.
CREATE OR REPLACE FUNCTION fn_can_see_return_id(p_return_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM returns r
    WHERE r.id = p_return_id
      AND (fn_is_manager_plus(r.business_id)
        OR r.processed_by = auth.uid()
        OR fn_can_see_sale_id(r.original_sale_id)));
$$;
REVOKE EXECUTE ON FUNCTION fn_can_see_return_id(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_can_see_return_id(UUID) TO authenticated;

-- Cash reconciliation: a cashier must see their own drawer, not everyone else's.
CREATE OR REPLACE FUNCTION fn_can_see_register_session_id(p_session_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM register_sessions rs
    WHERE rs.id = p_session_id
      AND (fn_is_manager_plus(rs.business_id)
        OR rs.opened_by = auth.uid()
        OR rs.closed_by = auth.uid()));
$$;
REVOKE EXECUTE ON FUNCTION fn_can_see_register_session_id(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_can_see_register_session_id(UUID) TO authenticated;

-- ------------------------------------------------------------
-- policies
-- ------------------------------------------------------------
DROP POLICY pol_sales_select ON sales;
CREATE POLICY pol_sales_select ON sales FOR SELECT
  USING (fn_can_see_sale(business_id, sold_by, branch_id));

DROP POLICY pol_si_select ON sale_items;
CREATE POLICY pol_si_select ON sale_items FOR SELECT
  USING (fn_is_member(business_id) AND fn_can_see_sale_id(sale_id));

-- NOTE: pol_sp_select also exists on supplier_payments (migration 001). Policy names
-- are per-table; this statement touches sale_payments only.
DROP POLICY pol_sp_select ON sale_payments;
CREATE POLICY pol_sp_select ON sale_payments FOR SELECT
  USING (fn_is_member(business_id) AND fn_can_see_sale_id(sale_id));

DROP POLICY pol_ret_select ON returns;
CREATE POLICY pol_ret_select ON returns FOR SELECT
  USING (fn_is_member(business_id)
     AND (fn_is_manager_plus(business_id)
       OR processed_by = auth.uid()
       OR fn_can_see_sale_id(original_sale_id)));

DROP POLICY pol_ri_select ON return_items;
CREATE POLICY pol_ri_select ON return_items FOR SELECT
  USING (fn_is_member(business_id) AND fn_can_see_return_id(return_id));

DROP POLICY pol_rs_select ON register_sessions;
CREATE POLICY pol_rs_select ON register_sessions FOR SELECT
  USING (fn_is_member(business_id)
     AND (fn_is_manager_plus(business_id)
       OR opened_by = auth.uid()
       OR closed_by = auth.uid()));

DROP POLICY pol_rscc_select ON register_session_currency_counts;
CREATE POLICY pol_rscc_select ON register_session_currency_counts FOR SELECT
  USING (fn_is_member(business_id) AND fn_can_see_register_session_id(register_session_id));

DROP POLICY pol_cm_select ON cash_movements;
CREATE POLICY pol_cm_select ON cash_movements FOR SELECT
  USING (fn_is_member(business_id) AND fn_can_see_register_session_id(register_session_id));

-- ============================================================
-- END phase 3.5E
-- ============================================================
