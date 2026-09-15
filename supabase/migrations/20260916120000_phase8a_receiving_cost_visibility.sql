-- ============================================================
-- Phase 8A — receiving cost visibility: purchasing cost is manager+ only
-- ============================================================
-- Closure review of 8A found that stock_staff could read purchasing cost: the Rev 3
-- policy pol_gri_select (fn_is_procurement) exposed goods_receipt_items.unit_cost and
-- every post-time cost column over REST, the 8A charge/reversal tables followed the same
-- predicate, and the preview/review RPCs returned landed cost to procurement roles.
--
-- Authoritative role policy (this migration enforces it in the database, not the UI):
--   owner / manager   full receiving: purchase cost, landed cost, allocation, charges,
--                     liability preview; review / POST / reverse
--   stock_staff       operational receiving only: draft header, variants, quantities,
--                     barcodes, status, cancel of a draft. No cost of any kind, no
--                     charges, no allocation, no review/POST/reverse.
--   sales_staff       no receiving access (unchanged)
--
-- How:
--   • goods_receipt_items.unit_cost becomes NULLABLE: stock_staff records the quantity,
--     the manager enters the price later. A line without cost is exactly that — never 0.
--     Review / preview / POST refuse such a document with COST_REQUIRED.
--   • Column-level SELECT privileges: cost columns of goods_receipt_items, the posted
--     totals of goods_receipts and value_removed_base of goods_receipt_reversals are no
--     longer readable by the `authenticated` role at all (no policy, no embed, no
--     select=* reaches them). Managers read them through rpc_goods_receipt_financial /
--     rpc_goods_receipt_list_totals (SECURITY DEFINER, owner|manager).
--   • goods_receipt_charges: SELECT and writes are owner|manager (the table is financial).
--   • Trigger role guards: unit_cost may only be written by owner|manager
--     (trg_cost_role_gri); allocation_method likewise (trg_financial_role_gr). Guards
--     skip sessions without auth.uid() (migrations, seeds, maintenance).
--   • rpc_goods_receipt_upsert_line: the one line-writing path the app uses; cost only
--     with a manager session.
--   • rpc_goods_receipt_preview / _review / rpc_post_goods_receipt: owner|manager.
--
-- Rollback: restore the three RPC bodies from 20260916090000/20260916100000, drop the
-- two guard triggers + functions, drop rpc_goods_receipt_upsert_line / _financial /
-- _list_totals, GRANT ALL on the three tables back to authenticated, restore the charge
-- policies to fn_is_procurement and SET unit_cost NOT NULL (after filling NULLs).
-- ============================================================

-- ------------------------------------------------------------ 1. a line may exist before its price
ALTER TABLE goods_receipt_items ALTER COLUMN unit_cost DROP NOT NULL;

-- ------------------------------------------------------------ 2. column privileges (hard boundary)
REVOKE ALL ON goods_receipt_items FROM anon, authenticated;
GRANT SELECT (id, business_id, goods_receipt_id, variant_id, quantity, labels_printed, created_at)
  ON goods_receipt_items TO authenticated;
GRANT INSERT (business_id, goods_receipt_id, variant_id, quantity, unit_cost, labels_printed)
  ON goods_receipt_items TO authenticated;
GRANT UPDATE (quantity, unit_cost, labels_printed) ON goods_receipt_items TO authenticated;
GRANT DELETE ON goods_receipt_items TO authenticated;

REVOKE ALL ON goods_receipts FROM anon, authenticated;
GRANT SELECT (id, business_id, branch_id, supplier_id, receipt_number, document_ref, received_at, note, status,
              payment_status, invoice_currency, exchange_rate, created_by, posted_by, posted_at, created_at, updated_at,
              allocation_method, reviewed_at, reviewed_by, review_hash)
  ON goods_receipts TO authenticated;
GRANT INSERT (business_id, branch_id, supplier_id, receipt_number, document_ref, received_at, note, status,
              payment_status, invoice_currency, exchange_rate, created_by, allocation_method)
  ON goods_receipts TO authenticated;
GRANT UPDATE (branch_id, supplier_id, document_ref, received_at, note, status, payment_status, invoice_currency,
              exchange_rate, allocation_method)
  ON goods_receipts TO authenticated;
GRANT DELETE ON goods_receipts TO authenticated;

REVOKE ALL ON goods_receipt_reversals FROM anon, authenticated;
GRANT SELECT (id, business_id, goods_receipt_id, reason, reversed_by, reversed_at) ON goods_receipt_reversals TO authenticated;

-- ------------------------------------------------------------ 3. charges are financial: manager+
DROP POLICY pol_grc_select ON goods_receipt_charges;
DROP POLICY pol_grc_write  ON goods_receipt_charges;
CREATE POLICY pol_grc_select ON goods_receipt_charges FOR SELECT USING (fn_is_manager_plus(business_id));
CREATE POLICY pol_grc_write  ON goods_receipt_charges FOR ALL
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

-- ------------------------------------------------------------ 4. role guards on financial writes
-- Only owner|manager may set or change a line's purchase cost. Sessions without a JWT
-- subject (migrations, seeds, maintenance) are trusted; SECURITY DEFINER RPCs carry the
-- caller's subject, so the guard sees the real actor there too.
CREATE OR REPLACE FUNCTION fn_guard_gri_cost_role()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_biz UUID;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF (TG_OP = 'INSERT' AND NEW.unit_cost IS NOT NULL)
     OR (TG_OP = 'UPDATE' AND NEW.unit_cost IS DISTINCT FROM OLD.unit_cost) THEN
    SELECT business_id INTO v_biz FROM goods_receipts WHERE id = NEW.goods_receipt_id;
    IF NOT fn_is_manager_plus(v_biz) THEN
      RAISE EXCEPTION 'FORBIDDEN: purchase cost is entered by owner or manager' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cost_role_gri BEFORE INSERT OR UPDATE ON goods_receipt_items
  FOR EACH ROW EXECUTE FUNCTION fn_guard_gri_cost_role();

CREATE OR REPLACE FUNCTION fn_guard_gr_financial_role()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF NEW.allocation_method IS DISTINCT FROM OLD.allocation_method AND NOT fn_is_manager_plus(NEW.business_id) THEN
    RAISE EXCEPTION 'FORBIDDEN: charge allocation is set by owner or manager' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_financial_role_gr BEFORE UPDATE ON goods_receipts
  FOR EACH ROW EXECUTE FUNCTION fn_guard_gr_financial_role();

-- ------------------------------------------------------------ 5. allocation refuses lines without a price
CREATE OR REPLACE FUNCTION fn_goods_receipt_allocation(p_goods_receipt_id UUID)
RETURNS TABLE (
  item_id UUID, variant_id UUID, quantity INTEGER, unit_cost cost6,
  unit_cost_base cost6, total_cost_base value6,
  allocated_charge_base value6, landed_unit_cost_base cost6, landed_total_cost_base value6
) LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, public AS $$
DECLARE
  gr RECORD; v_charges NUMERIC; v_sum_value NUMERIC; v_sum_qty NUMERIC; v_n INTEGER; v_missing INTEGER; v_share NUMERIC; it RECORD;
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE = 'P0002'; END IF;

  SELECT count(*) INTO v_missing FROM goods_receipt_items i WHERE i.goods_receipt_id = gr.id AND i.unit_cost IS NULL;
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'COST_REQUIRED: % line(s) of receipt % have no purchase cost yet', v_missing, gr.receipt_number USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(SUM(amount_base), 0) INTO v_charges FROM goods_receipt_charges
  WHERE goods_receipt_id = gr.id AND include_in_landed;

  SELECT COALESCE(SUM(i.quantity * round(i.unit_cost * gr.exchange_rate, 6)), 0), COALESCE(SUM(i.quantity), 0), count(*)
  INTO v_sum_value, v_sum_qty, v_n
  FROM goods_receipt_items i WHERE i.goods_receipt_id = gr.id;
  IF v_n = 0 THEN RETURN; END IF;

  IF gr.allocation_method = 'manual' THEN
    RAISE EXCEPTION 'NOT_IMPLEMENTED: manual charge allocation is architected but not enabled yet' USING ERRCODE = '0A000';
  END IF;
  IF v_charges > 0 AND gr.allocation_method = 'invoice_value_proportional' AND v_sum_value <= 0 THEN
    RAISE EXCEPTION 'ALLOCATION_BASIS: charges cannot be allocated by value when every line costs 0; use quantity or equal allocation' USING ERRCODE = '22023';
  END IF;

  FOR it IN SELECT i.id, i.variant_id, i.quantity, i.unit_cost,
                   round(i.unit_cost * gr.exchange_rate, 6) AS unit_base,
                   i.quantity * round(i.unit_cost * gr.exchange_rate, 6) AS value_base
            FROM goods_receipt_items i WHERE i.goods_receipt_id = gr.id ORDER BY i.variant_id LOOP
    IF v_charges = 0 THEN
      v_share := 0;
    ELSE
      v_share := round(CASE gr.allocation_method
        WHEN 'invoice_value_proportional' THEN v_charges * it.value_base / v_sum_value
        WHEN 'quantity_proportional'      THEN v_charges * it.quantity / v_sum_qty
        ELSE                                   v_charges / v_n
      END, 6);
    END IF;
    item_id := it.id; variant_id := it.variant_id; quantity := it.quantity; unit_cost := it.unit_cost;
    unit_cost_base := it.unit_base; total_cost_base := it.value_base;
    allocated_charge_base := v_share;
    landed_total_cost_base := it.value_base + v_share;
    landed_unit_cost_base := round((it.value_base + v_share) / it.quantity, 6);
    RETURN NEXT;
  END LOOP;
  RETURN;
END $$;
REVOKE EXECUTE ON FUNCTION fn_goods_receipt_allocation(UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ 6. line writes: one RPC, cost only for managers
-- Insert-or-update of the (receipt, variant) line. p_unit_cost NULL keeps whatever cost
-- the line has (a stock_staff quantity update never blanks a manager's price); a non-NULL
-- cost needs owner|manager. The trigger guard above enforces the same rule for any
-- direct table write.
CREATE OR REPLACE FUNCTION rpc_goods_receipt_upsert_line(
  p_goods_receipt_id UUID, p_variant_id UUID, p_quantity INTEGER, p_unit_cost NUMERIC DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE gr RECORD; v_id UUID;
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(gr.business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
  PERFORM fn_require_active_business(gr.business_id);
  IF gr.status <> 'draft' THEN RAISE EXCEPTION 'INVALID_STATE: receipt % is %', gr.receipt_number, gr.status USING ERRCODE = '55000'; END IF;
  PERFORM fn_assert_variant(gr.business_id, p_variant_id);
  IF p_quantity IS NULL OR p_quantity <= 0 THEN RAISE EXCEPTION 'INVALID_QTY: quantity must be positive' USING ERRCODE = '22023'; END IF;
  IF p_unit_cost IS NOT NULL THEN
    PERFORM fn_require_role(gr.business_id, ARRAY['owner','manager']::user_role[]);
    IF p_unit_cost < 0 THEN RAISE EXCEPTION 'INVALID_COST: unit cost must not be negative' USING ERRCODE = '22023'; END IF;
  END IF;

  SELECT id INTO v_id FROM goods_receipt_items WHERE goods_receipt_id = gr.id AND variant_id = p_variant_id;
  IF v_id IS NULL THEN
    INSERT INTO goods_receipt_items (business_id, goods_receipt_id, variant_id, quantity, unit_cost)
    VALUES (gr.business_id, gr.id, p_variant_id, p_quantity, p_unit_cost) RETURNING id INTO v_id;
  ELSE
    UPDATE goods_receipt_items SET quantity = p_quantity, unit_cost = COALESCE(p_unit_cost, unit_cost) WHERE id = v_id;
  END IF;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_goods_receipt_upsert_line(UUID, UUID, INTEGER, NUMERIC) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_goods_receipt_upsert_line(UUID, UUID, INTEGER, NUMERIC) TO authenticated;

-- ------------------------------------------------------------ 7. financial reads: manager+
-- Everything the cost columns held, for one receipt. Charges stay a direct (manager+)
-- table read. Never reachable by stock_staff or sales_staff.
CREATE OR REPLACE FUNCTION rpc_goods_receipt_financial(p_goods_receipt_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, public AS $$
DECLARE gr RECORD;
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(gr.business_id, ARRAY['owner','manager']::user_role[]);
  RETURN jsonb_build_object(
    'items', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'item_id', i.id, 'unit_cost', i.unit_cost, 'total_cost_original', i.total_cost_original,
                'fx_rate_snapshot', i.fx_rate_snapshot, 'unit_cost_base', i.unit_cost_base, 'total_cost_base', i.total_cost_base,
                'allocated_charge_base', i.allocated_charge_base, 'landed_unit_cost_base', i.landed_unit_cost_base,
                'landed_total_cost_base', i.landed_total_cost_base, 'manual_allocation_base', i.manual_allocation_base
              ) ORDER BY i.variant_id), '[]'::jsonb)
              FROM goods_receipt_items i WHERE i.goods_receipt_id = gr.id),
    'missing_cost_lines', (SELECT count(*) FROM goods_receipt_items i WHERE i.goods_receipt_id = gr.id AND i.unit_cost IS NULL),
    'posted_invoice_total_original', gr.posted_invoice_total_original,
    'posted_charges_base', gr.posted_charges_base,
    'posted_landed_total_base', gr.posted_landed_total_base,
    'reversal_value_removed_base', (SELECT r.value_removed_base FROM goods_receipt_reversals r WHERE r.goods_receipt_id = gr.id)
  );
END $$;
REVOKE EXECUTE ON FUNCTION rpc_goods_receipt_financial(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_goods_receipt_financial(UUID) TO authenticated;

-- Invoice totals for the receipt list. Every receipt must belong to a business where the
-- caller is owner|manager; otherwise the whole call is refused.
CREATE OR REPLACE FUNCTION rpc_goods_receipt_list_totals(p_goods_receipt_ids UUID[])
RETURNS TABLE (goods_receipt_id UUID, total_original NUMERIC, missing_cost_lines INTEGER)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, public AS $$
DECLARE b RECORD;
BEGIN
  FOR b IN SELECT DISTINCT g.business_id FROM goods_receipts g WHERE g.id = ANY(p_goods_receipt_ids) LOOP
    PERFORM fn_require_role(b.business_id, ARRAY['owner','manager']::user_role[]);
  END LOOP;
  RETURN QUERY
    SELECT g.id,
           COALESCE((SELECT sum(i.quantity * i.unit_cost) FROM goods_receipt_items i WHERE i.goods_receipt_id = g.id), 0)::numeric,
           (SELECT count(*) FROM goods_receipt_items i WHERE i.goods_receipt_id = g.id AND i.unit_cost IS NULL)::integer
    FROM goods_receipts g WHERE g.id = ANY(p_goods_receipt_ids);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_goods_receipt_list_totals(UUID[]) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_goods_receipt_list_totals(UUID[]) TO authenticated;

-- ------------------------------------------------------------ 8. preview / review / POST: manager+
CREATE OR REPLACE FUNCTION rpc_goods_receipt_preview(p_goods_receipt_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, public AS $$
DECLARE gr RECORD; v_lines JSONB; v_current BOOLEAN;
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(gr.business_id, ARRAY['owner','manager']::user_role[]);
  IF gr.status <> 'draft' THEN
    RETURN jsonb_build_object('status', gr.status, 'lines', '[]'::jsonb, 'review_current', false);
  END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.variant_id), '[]'::jsonb) INTO v_lines FROM fn_goods_receipt_allocation_fixed(gr.id) a;
  v_current := gr.review_hash IS NOT NULL AND gr.review_hash = fn_goods_receipt_hash(gr.id);
  RETURN jsonb_build_object('status', gr.status, 'lines', v_lines, 'review_current', v_current, 'reviewed_at', gr.reviewed_at);
END $$;

CREATE OR REPLACE FUNCTION rpc_goods_receipt_review(p_goods_receipt_id UUID)
RETURNS TABLE (
  item_id UUID, variant_id UUID, quantity INTEGER, unit_cost cost6,
  unit_cost_base cost6, total_cost_base value6,
  allocated_charge_base value6, landed_unit_cost_base cost6, landed_total_cost_base value6
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); gr RECORD; c RECORD; v_missing INTEGER;
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id FOR UPDATE;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(gr.business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(gr.business_id);
  IF gr.status <> 'draft' THEN RAISE EXCEPTION 'INVALID_STATE: receipt % is %', gr.receipt_number, gr.status USING ERRCODE = '55000'; END IF;
  PERFORM fn_assert_branch(gr.business_id, gr.branch_id);
  IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = gr.supplier_id AND business_id = gr.business_id AND status = 'active') THEN
    RAISE EXCEPTION 'INVALID_SUPPLIER: supplier % not active', gr.supplier_id USING ERRCODE = '22023';
  END IF;
  IF gr.invoice_currency = 'TRY' AND gr.exchange_rate <> 1 THEN
    RAISE EXCEPTION 'INVALID_FX: TRY invoice must have exchange_rate = 1' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM goods_receipt_items WHERE goods_receipt_id = gr.id) THEN
    RAISE EXCEPTION 'EMPTY_DOCUMENT: receipt % has no items', gr.receipt_number USING ERRCODE = '22023';
  END IF;
  SELECT count(*) INTO v_missing FROM goods_receipt_items i WHERE i.goods_receipt_id = gr.id AND i.unit_cost IS NULL;
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'COST_REQUIRED: % line(s) of receipt % have no purchase cost yet', v_missing, gr.receipt_number USING ERRCODE = '22023';
  END IF;

  FOR c IN SELECT * FROM goods_receipt_charges WHERE goods_receipt_id = gr.id LOOP
    IF c.liability_mode = 'add_to_invoice' AND c.currency <> gr.invoice_currency THEN
      RAISE EXCEPTION 'CHARGE_CURRENCY: a charge billed on the invoice must be in the invoice currency (% vs %)', c.currency, gr.invoice_currency USING ERRCODE = '22023';
    END IF;
    IF c.liability_mode = 'separate_supplier' AND NOT EXISTS (
      SELECT 1 FROM suppliers WHERE id = c.payee_supplier_id AND business_id = gr.business_id AND status = 'active') THEN
      RAISE EXCEPTION 'INVALID_SUPPLIER: charge payee % not active', c.payee_supplier_id USING ERRCODE = '22023';
    END IF;
  END LOOP;

  UPDATE goods_receipts
  SET reviewed_at = now(), reviewed_by = v_actor, review_hash = fn_goods_receipt_hash(gr.id), updated_at = now()
  WHERE id = gr.id;

  RETURN QUERY SELECT * FROM fn_goods_receipt_allocation_fixed(gr.id);
END $$;

CREATE OR REPLACE FUNCTION rpc_post_goods_receipt(p_goods_receipt_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor UUID := fn_actor(); gr RECORD; a RECORD; c RECORD; pr t_cost_pool_result;
  v_vids UUID[]; v_invoice_total NUMERIC := 0; v_liab NUMERIC := 0; v_charges_base NUMERIC := 0; v_landed_total NUMERIC := 0;
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id FOR UPDATE;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(gr.business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(gr.business_id);
  IF gr.status <> 'draft' THEN RAISE EXCEPTION 'INVALID_STATE: receipt % is %', gr.id, gr.status USING ERRCODE = '55000'; END IF;
  PERFORM fn_assert_branch(gr.business_id, gr.branch_id);
  IF gr.invoice_currency = 'TRY' AND gr.exchange_rate <> 1 THEN
    RAISE EXCEPTION 'INVALID_FX: TRY invoice must have exchange_rate = 1' USING ERRCODE = '22023';
  END IF;
  IF gr.reviewed_at IS NULL OR gr.review_hash IS NULL THEN
    RAISE EXCEPTION 'NOT_REVIEWED: receipt % must be reviewed before posting', gr.receipt_number USING ERRCODE = '55000';
  END IF;
  IF gr.review_hash <> fn_goods_receipt_hash(gr.id) THEN
    RAISE EXCEPTION 'STALE_DRAFT: receipt % changed after its review; review it again', gr.receipt_number USING ERRCODE = '55000';
  END IF;

  SELECT array_agg(variant_id ORDER BY variant_id) INTO v_vids FROM goods_receipt_items WHERE goods_receipt_id = gr.id;
  IF v_vids IS NULL THEN RAISE EXCEPTION 'EMPTY_DOCUMENT: receipt % has no items', gr.id USING ERRCODE = '22023'; END IF;
  PERFORM fn_lock_pools(gr.business_id, gr.branch_id, v_vids);

  FOR a IN SELECT * FROM fn_goods_receipt_allocation_fixed(gr.id) ORDER BY variant_id LOOP
    UPDATE goods_receipt_items
    SET fx_rate_snapshot = gr.exchange_rate, unit_cost_base = a.unit_cost_base, total_cost_base = a.total_cost_base,
        allocated_charge_base = a.allocated_charge_base,
        landed_unit_cost_base = a.landed_unit_cost_base, landed_total_cost_base = a.landed_total_cost_base
    WHERE id = a.item_id;

    pr := fn_post_to_cost_pool(gr.business_id, gr.branch_id, a.variant_id, a.quantity, NULL, a.landed_total_cost_base);
    PERFORM fn_ledger_post(gr.business_id, gr.branch_id, a.variant_id, 'sellable', a.quantity, 'goods_receipt',
                           'goods_receipt_item', a.item_id, pr.unit_cost_used, pr.value_delta_base, NULL, now(), v_actor);
    v_invoice_total := v_invoice_total + a.quantity * a.unit_cost;
    v_charges_base := v_charges_base + a.allocated_charge_base;
    v_landed_total := v_landed_total + a.landed_total_cost_base;
  END LOOP;

  v_liab := v_invoice_total;
  FOR c IN SELECT * FROM goods_receipt_charges WHERE goods_receipt_id = gr.id LOOP
    IF c.liability_mode = 'add_to_invoice' THEN
      IF c.currency <> gr.invoice_currency THEN
        RAISE EXCEPTION 'CHARGE_CURRENCY: a charge billed on the invoice must be in the invoice currency' USING ERRCODE = '22023';
      END IF;
      v_liab := v_liab + c.amount;
    ELSIF c.liability_mode = 'separate_supplier' THEN
      INSERT INTO supplier_account_entries (business_id, supplier_id, entry_type, amount_original, currency, exchange_rate,
                                            reference_type, reference_id, note, created_by)
      VALUES (gr.business_id, c.payee_supplier_id, 'liability', c.amount, c.currency, c.exchange_rate,
              'goods_receipt_charge', c.id, 'Charge on goods receipt ' || gr.receipt_number, v_actor);
    END IF;
  END LOOP;
  IF v_liab > 0 THEN
    INSERT INTO supplier_account_entries (business_id, supplier_id, entry_type, amount_original, currency, exchange_rate,
                                          reference_type, reference_id, note, created_by)
    VALUES (gr.business_id, gr.supplier_id, 'liability', round(v_liab, 2), gr.invoice_currency, gr.exchange_rate,
            'goods_receipt', gr.id, 'Goods receipt ' || gr.receipt_number, v_actor);
  END IF;

  UPDATE goods_receipts
  SET status = 'posted', posted_by = v_actor, posted_at = now(),
      posted_invoice_total_original = round(v_invoice_total, 2),
      posted_charges_base = v_charges_base, posted_landed_total_base = v_landed_total
  WHERE id = gr.id;
END $$;

-- CREATE OR REPLACE keeps the existing grants; restated so the privilege set is explicit here.
REVOKE EXECUTE ON FUNCTION rpc_goods_receipt_preview(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_goods_receipt_preview(UUID) TO authenticated;
REVOKE EXECUTE ON FUNCTION rpc_goods_receipt_review(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_goods_receipt_review(UUID) TO authenticated;
REVOKE EXECUTE ON FUNCTION rpc_post_goods_receipt(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_post_goods_receipt(UUID) TO authenticated;
