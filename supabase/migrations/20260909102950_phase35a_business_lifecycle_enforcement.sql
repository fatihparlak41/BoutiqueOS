-- ============================================================
-- BoutiqueOS  •  Phase 3.5A  •  Business lifecycle enforcement
-- ============================================================
-- businesses.status has existed since 001 but nothing read it: a suspended or
-- cancelled tenant behaved exactly like an active one. Hiding it in the UI is not
-- security, so the rule is enforced in the database:
--
--   active     -> unchanged
--   suspended  -> may SELECT its history, may NOT write
--   cancelled  -> same as suspended
--
-- Two enforcement surfaces, because there are two ways to write:
--   1. direct table writes  -> every write RLS policy gains fn_is_business_active()
--   2. SECURITY DEFINER RPC -> fn_require_member() (the single gate every posting
--      RPC passes through) plus rpc_set_fx_rate, which guards itself.
--
-- Deliberately NOT gated, so a suspended tenant can be brought back:
--   pol_businesses_update  (owner edits businesses.status / settings)
--   pol_profiles_update    (per-user row, not business-scoped)
--   every FOR SELECT policy (history stays readable)
-- ============================================================

-- ------------------------------------------------------------
-- helper
-- ------------------------------------------------------------
-- Granted to authenticated because RLS policies are evaluated as the querying
-- role and must be able to call it (same contract as fn_is_member).
CREATE OR REPLACE FUNCTION fn_is_business_active(p_business_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (SELECT 1 FROM businesses WHERE id = p_business_id AND status = 'active');
$$;
REVOKE EXECUTE ON FUNCTION fn_is_business_active(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_is_business_active(UUID) TO authenticated;

-- Raising variant for RPC bodies. Internal only.
CREATE OR REPLACE FUNCTION fn_require_active_business(p_business_id UUID)
RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE v business_status;
BEGIN
  SELECT status INTO v FROM businesses WHERE id = p_business_id;
  IF v IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: business %', p_business_id USING ERRCODE='P0002';
  END IF;
  IF v <> 'active' THEN
    RAISE EXCEPTION 'BUSINESS_SUSPENDED: business % is % and cannot accept writes', p_business_id, v
      USING ERRCODE='55000';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION fn_require_active_business(UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- RPC gate
-- ------------------------------------------------------------
-- Every posting RPC in 004 and rpc_create_goods_receipt reach membership through
-- fn_require_member (directly or via fn_require_role), so one guard here closes
-- the whole RPC write surface. Read-only rpc_get_fx_rate uses fn_is_member and is
-- intentionally untouched.
CREATE OR REPLACE FUNCTION fn_require_member(p_business_id UUID)
RETURNS user_role LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v user_role;
BEGIN
  SELECT role INTO v FROM business_members
  WHERE business_id = p_business_id AND user_id = fn_actor() AND is_active;
  IF v IS NULL THEN RAISE EXCEPTION 'FORBIDDEN: not an active member of business %', p_business_id USING ERRCODE='42501'; END IF;
  PERFORM fn_require_active_business(p_business_id);
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION fn_require_member(UUID) FROM PUBLIC, anon, authenticated;

-- rpc_set_fx_rate checks fn_is_manager_plus directly instead of fn_require_role,
-- so it is the one RPC the gate above does not reach. Body unchanged except for
-- the added lifecycle guard.
CREATE OR REPLACE FUNCTION rpc_set_fx_rate(
  p_business_id  UUID,
  p_currency     TEXT,
  p_rate_to_base NUMERIC,
  p_rate_date    DATE DEFAULT CURRENT_DATE,
  p_source       TEXT DEFAULT 'manual'
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_old_id  UUID; v_old_ver INTEGER := 0; v_new_id UUID;
BEGIN
  IF NOT fn_is_manager_plus(p_business_id) THEN
    RAISE EXCEPTION 'FORBIDDEN: manager or owner role required' USING ERRCODE='42501';
  END IF;
  PERFORM fn_require_active_business(p_business_id);
  IF p_currency IS NULL OR p_currency = 'TRY' OR p_currency NOT IN ('GBP','EUR','USD') THEN
    RAISE EXCEPTION 'INVALID_CURRENCY: %', p_currency USING ERRCODE='22023';
  END IF;
  IF p_rate_to_base IS NULL OR p_rate_to_base <= 0 THEN
    RAISE EXCEPTION 'INVALID_RATE: rate must be > 0' USING ERRCODE='22023';
  END IF;
  IF p_rate_date IS NULL OR p_rate_date > CURRENT_DATE + 1 THEN
    RAISE EXCEPTION 'INVALID_DATE: rate_date % not allowed', p_rate_date USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_business_id::text || ':' || p_currency || ':' || p_rate_date::text));

  SELECT id, version INTO v_old_id, v_old_ver
  FROM fx_rates
  WHERE business_id = p_business_id AND currency = p_currency AND rate_date = p_rate_date AND is_current
  FOR UPDATE;

  v_new_id := gen_random_uuid();

  IF v_old_id IS NOT NULL THEN
    UPDATE fx_rates SET is_current = false, superseded_by = v_new_id WHERE id = v_old_id;
  END IF;

  INSERT INTO fx_rates (id, business_id, rate_date, currency, rate_to_base, source, version, is_current, created_by)
  VALUES (v_new_id, p_business_id, p_rate_date, p_currency, p_rate_to_base, p_source,
          COALESCE(v_old_ver, 0) + 1, true, auth.uid());

  RETURN v_new_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_set_fx_rate(UUID, TEXT, NUMERIC, DATE, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_set_fx_rate(UUID, TEXT, NUMERIC, DATE, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- write policies  (predicate unchanged, lifecycle condition added)
-- ------------------------------------------------------------
-- 001: branches / business_members
DROP POLICY pol_branches_write ON branches;
CREATE POLICY pol_branches_write ON branches FOR ALL
  USING (fn_has_role(business_id, ARRAY['owner']::user_role[]) AND fn_is_business_active(business_id))
  WITH CHECK (fn_has_role(business_id, ARRAY['owner']::user_role[]) AND fn_is_business_active(business_id));

DROP POLICY pol_bm_write ON business_members;
CREATE POLICY pol_bm_write ON business_members FOR ALL
  USING (fn_has_role(business_id, ARRAY['owner']::user_role[]) AND fn_is_business_active(business_id))
  WITH CHECK (fn_has_role(business_id, ARRAY['owner']::user_role[]) AND fn_is_business_active(business_id));

-- 001: master data (manager+)
DROP POLICY pol_brands_write ON brands;
CREATE POLICY pol_brands_write ON brands FOR ALL
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_categories_write ON categories;
CREATE POLICY pol_categories_write ON categories FOR ALL
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_suppliers_write ON suppliers;
CREATE POLICY pol_suppliers_write ON suppliers FOR ALL
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_po_write ON product_options;
CREATE POLICY pol_po_write ON product_options FOR ALL
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_ov_write ON option_values;
CREATE POLICY pol_ov_write ON option_values FOR ALL
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_products_write ON products;
CREATE POLICY pol_products_write ON products FOR ALL
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_variants_write ON product_variants;
CREATE POLICY pol_variants_write ON product_variants FOR ALL
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_vov_write ON variant_option_values;
CREATE POLICY pol_vov_write ON variant_option_values FOR ALL
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_barcodes_write ON barcodes;
CREATE POLICY pol_barcodes_write ON barcodes FOR ALL
  USING (fn_is_procurement(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_procurement(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_images_write ON product_images;
CREATE POLICY pol_images_write ON product_images FOR ALL
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

-- 001: goods receipts
DROP POLICY pol_gr_insert ON goods_receipts;
CREATE POLICY pol_gr_insert ON goods_receipts FOR INSERT
  WITH CHECK (fn_is_procurement(business_id) AND fn_is_business_active(business_id) AND status = 'draft');

DROP POLICY pol_gr_update ON goods_receipts;
CREATE POLICY pol_gr_update ON goods_receipts FOR UPDATE
  USING (fn_is_procurement(business_id) AND fn_is_business_active(business_id) AND status = 'draft')
  WITH CHECK (fn_is_procurement(business_id) AND fn_is_business_active(business_id) AND status IN ('draft','cancelled'));

DROP POLICY pol_gr_delete ON goods_receipts;
CREATE POLICY pol_gr_delete ON goods_receipts FOR DELETE
  USING (fn_is_procurement(business_id) AND fn_is_business_active(business_id) AND status = 'draft');

DROP POLICY pol_gri_write ON goods_receipt_items;
CREATE POLICY pol_gri_write ON goods_receipt_items FOR ALL
  USING (fn_is_procurement(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_procurement(business_id) AND fn_is_business_active(business_id));

-- 003: customers / cash registers
DROP POLICY pol_cust_insert ON customers;
CREATE POLICY pol_cust_insert ON customers FOR INSERT
  WITH CHECK (fn_is_member(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_cust_update ON customers;
CREATE POLICY pol_cust_update ON customers FOR UPDATE
  USING (fn_is_member(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_member(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_cr_write ON cash_registers;
CREATE POLICY pol_cr_write ON cash_registers FOR ALL
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

-- 003: stock transfers / inventory counts
DROP POLICY pol_st_insert ON stock_transfers;
CREATE POLICY pol_st_insert ON stock_transfers FOR INSERT
  WITH CHECK (fn_is_procurement(business_id) AND fn_is_business_active(business_id) AND status = 'draft');

DROP POLICY pol_st_update ON stock_transfers;
CREATE POLICY pol_st_update ON stock_transfers FOR UPDATE
  USING (fn_is_procurement(business_id) AND fn_is_business_active(business_id) AND status = 'draft')
  WITH CHECK (fn_is_procurement(business_id) AND fn_is_business_active(business_id) AND status IN ('draft','cancelled'));

DROP POLICY pol_st_delete ON stock_transfers;
CREATE POLICY pol_st_delete ON stock_transfers FOR DELETE
  USING (fn_is_procurement(business_id) AND fn_is_business_active(business_id) AND status = 'draft');

DROP POLICY pol_stl_write ON stock_transfer_lines;
CREATE POLICY pol_stl_write ON stock_transfer_lines FOR ALL
  USING (fn_is_procurement(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_procurement(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_ic_write ON inventory_counts;
CREATE POLICY pol_ic_write ON inventory_counts FOR ALL
  USING (fn_is_procurement(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_procurement(business_id) AND fn_is_business_active(business_id));

DROP POLICY pol_icl_write ON inventory_count_lines;
CREATE POLICY pol_icl_write ON inventory_count_lines FOR ALL
  USING (fn_is_procurement(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_procurement(business_id) AND fn_is_business_active(business_id));

-- ============================================================
-- END phase 3.5A
-- ============================================================
