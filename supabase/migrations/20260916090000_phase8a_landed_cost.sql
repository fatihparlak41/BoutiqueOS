-- ============================================================
-- Phase 8A — goods receiving + landed cost engine
-- ============================================================
-- Additive on the Rev 3 receiving document (goods_receipts / goods_receipt_items,
-- rpc_create_goods_receipt, posted-document guards). What changes:
--
--   goods_receipt_charges          additional charges on a receipt (freight, customs, …)
--                                  with their own currency, an eligibility flag for landed
--                                  cost and an explicit liability mode
--   goods_receipts                 + allocation_method, review columns (reviewed_at/by,
--                                  review_hash) and posted totals for audit
--   goods_receipt_items            + allocated_charge_base, landed_unit_cost_base,
--                                  landed_total_cost_base (written at POST, frozen after),
--                                  manual_allocation_base (architected; 'manual' method
--                                  is refused until a UI exists)
--   goods_receipt_reversals        one row per reversed receipt; the posted receipt itself
--                                  is never edited
--   fn_goods_receipt_allocation    the single allocation computation (preview and POST
--                                  use the same function, so the review is what gets posted)
--   rpc_goods_receipt_review       validates, previews, stamps reviewed_at + review_hash
--   rpc_post_goods_receipt         REPLACED: requires an unchanged review, posts landed cost
--   rpc_reverse_goods_receipt      REPLACED (was a NOT_IMPLEMENTED stub): reversal document
--
-- Cost rules (unchanged where they existed):
--   • the item's unit_cost in invoice currency is the authoritative purchase cost
--   • landed unit cost = purchase cost (base) + allocated eligible charges (base) / quantity
--   • pools receive the landed total; ledger cost rows carry the landed unit cost
--   • MWA per business + branch + variant, via fn_post_to_cost_pool as before
--   • no silent zero cost: a zero-cost item still passes through COST_REQUIRED unless the
--     invoice says 0 and the person entered 0 explicitly (existing behaviour kept)
--   • supplier liability = invoice value (+ charges the invoice supplier bills, same
--     currency); a charge billed by another supplier is that supplier's liability; a charge
--     marked no_liability touches no supplier account. Never twice.
--   • VAT is not modelled: costs are posted exactly as entered (net or gross is the
--     boutique's explicit choice per document).
--
-- Rollback: drop the two RPC bodies back to 004 (rpc_post_goods_receipt) / the stub
-- (rpc_reverse_goods_receipt), drop fn_goods_receipt_allocation / fn_goods_receipt_hash,
-- goods_receipt_reversals, goods_receipt_charges, the added columns and the three enums.
-- ============================================================

CREATE TYPE charge_kind AS ENUM ('freight','customs','insurance','handling','other');
CREATE TYPE charge_liability_mode AS ENUM ('add_to_invoice','separate_supplier','no_liability');
CREATE TYPE charge_allocation_method AS ENUM ('invoice_value_proportional','quantity_proportional','equal_per_line','manual');

-- ------------------------------------------------------------ header + items
ALTER TABLE goods_receipts
  ADD COLUMN allocation_method          charge_allocation_method NOT NULL DEFAULT 'invoice_value_proportional',
  ADD COLUMN reviewed_at                TIMESTAMPTZ,
  ADD COLUMN reviewed_by                UUID REFERENCES profiles(id),
  ADD COLUMN review_hash                TEXT,
  ADD COLUMN posted_invoice_total_original NUMERIC(14,2),
  ADD COLUMN posted_charges_base        value6,
  ADD COLUMN posted_landed_total_base   value6;

ALTER TABLE goods_receipt_items
  ADD COLUMN manual_allocation_base   value6 CHECK (manual_allocation_base IS NULL OR manual_allocation_base >= 0),
  ADD COLUMN allocated_charge_base    value6,
  ADD COLUMN landed_unit_cost_base    cost6,
  ADD COLUMN landed_total_cost_base   value6;

-- ------------------------------------------------------------ charges
CREATE TABLE goods_receipt_charges (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID NOT NULL REFERENCES businesses(id),   -- trigger-populated from the receipt
  goods_receipt_id   UUID NOT NULL,
  kind               charge_kind NOT NULL DEFAULT 'other',
  description        TEXT,
  amount             NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  currency           iso_currency NOT NULL DEFAULT 'TRY',
  exchange_rate      fx6 NOT NULL DEFAULT 1,
  CONSTRAINT chk_grc_try_rate CHECK (currency <> 'TRY' OR exchange_rate = 1),
  amount_base        value6 GENERATED ALWAYS AS (amount * exchange_rate) STORED,
  -- part of the landed cost of the goods (freight, customs) or not (a fee you expense)
  include_in_landed  BOOLEAN NOT NULL DEFAULT true,
  liability_mode     charge_liability_mode NOT NULL DEFAULT 'add_to_invoice',
  payee_supplier_id  UUID,
  CONSTRAINT chk_grc_payee CHECK (
    (liability_mode = 'separate_supplier' AND payee_supplier_id IS NOT NULL)
    OR (liability_mode <> 'separate_supplier' AND payee_supplier_id IS NULL)
  ),
  created_by         UUID REFERENCES profiles(id),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, goods_receipt_id)  REFERENCES goods_receipts (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, payee_supplier_id) REFERENCES suppliers      (business_id, id)
);
CREATE INDEX ix_grc_receipt ON goods_receipt_charges (goods_receipt_id);

CREATE TRIGGER trg_bid_grc BEFORE INSERT OR UPDATE ON goods_receipt_charges
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('goods_receipts','goods_receipt_id');
CREATE TRIGGER trg_created_by_grc BEFORE INSERT ON goods_receipt_charges
  FOR EACH ROW EXECUTE FUNCTION fn_stamp_created_by();

-- charges of a posted receipt are frozen, like its items
CREATE OR REPLACE FUNCTION fn_guard_posted_grc()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_status goods_receipt_status;
BEGIN
  SELECT status INTO v_status FROM goods_receipts WHERE id = COALESCE(NEW.goods_receipt_id, OLD.goods_receipt_id);
  IF v_status = 'posted' THEN
    RAISE EXCEPTION 'IMMUTABLE: charges of posted goods receipt cannot be %', TG_OP USING ERRCODE = '55000';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_posted_grc BEFORE INSERT OR UPDATE OR DELETE ON goods_receipt_charges
  FOR EACH ROW EXECUTE FUNCTION fn_guard_posted_grc();

ALTER TABLE goods_receipt_charges ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_grc_select ON goods_receipt_charges FOR SELECT USING (fn_is_procurement(business_id));
CREATE POLICY pol_grc_write  ON goods_receipt_charges FOR ALL
  USING (fn_is_procurement(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_procurement(business_id) AND fn_is_business_active(business_id));

-- ------------------------------------------------------------ reversals
-- A reversal is its own document. The posted receipt keeps every value it was posted
-- with; the reversal takes the goods back out at the branch moving average of that
-- moment and credits every liability the receipt created. One reversal per receipt.
CREATE TABLE goods_receipt_reversals (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID NOT NULL REFERENCES businesses(id),
  goods_receipt_id   UUID NOT NULL UNIQUE,
  reason             TEXT NOT NULL CHECK (length(trim(reason)) >= 3),
  reversed_by        UUID REFERENCES profiles(id),
  reversed_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  value_removed_base value6 NOT NULL,
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, goods_receipt_id) REFERENCES goods_receipts (business_id, id)
);
ALTER TABLE goods_receipt_reversals ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_grr_select ON goods_receipt_reversals FOR SELECT USING (fn_is_procurement(business_id));
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON goods_receipt_reversals FROM anon, authenticated;
CREATE TRIGGER trg_imm_grr BEFORE UPDATE OR DELETE ON goods_receipt_reversals
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_update_delete();

-- one ledger row per reversed item, ever
CREATE UNIQUE INDEX uix_movement_gr_reversal_item
  ON inventory_movements (reference_id) WHERE reference_type = 'goods_receipt_reversal_item';

-- ------------------------------------------------------------ allocation (the one computation)
-- Returns one row per item with the raw (rounded) charge share and the landed cost, for
-- the receipt as it is right now. Only charges with include_in_landed are allocated.
-- fn_goods_receipt_allocation_fixed below folds the rounding remainder into the largest
-- share so the sum equals the charge total exactly. Nothing is written.
CREATE OR REPLACE FUNCTION fn_goods_receipt_allocation(p_goods_receipt_id UUID)
RETURNS TABLE (
  item_id UUID, variant_id UUID, quantity INTEGER, unit_cost cost6,
  unit_cost_base cost6, total_cost_base value6,
  allocated_charge_base value6, landed_unit_cost_base cost6, landed_total_cost_base value6
) LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, public AS $$
DECLARE
  gr RECORD; v_charges NUMERIC; v_sum_value NUMERIC; v_sum_qty NUMERIC; v_n INTEGER; v_share NUMERIC; it RECORD;
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE = 'P0002'; END IF;

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

-- Allocation with the rounding remainder folded into the largest line. This is what the
-- review shows and what POST writes.
CREATE OR REPLACE FUNCTION fn_goods_receipt_allocation_fixed(p_goods_receipt_id UUID)
RETURNS TABLE (
  item_id UUID, variant_id UUID, quantity INTEGER, unit_cost cost6,
  unit_cost_base cost6, total_cost_base value6,
  allocated_charge_base value6, landed_unit_cost_base cost6, landed_total_cost_base value6
) LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, public AS $$
DECLARE v_charges NUMERIC; v_assigned NUMERIC; v_diff NUMERIC; v_target UUID; r RECORD;
BEGIN
  SELECT COALESCE(SUM(c.amount_base), 0) INTO v_charges FROM goods_receipt_charges c
  WHERE c.goods_receipt_id = p_goods_receipt_id AND c.include_in_landed;
  SELECT COALESCE(SUM(a.allocated_charge_base), 0) INTO v_assigned FROM fn_goods_receipt_allocation(p_goods_receipt_id) a;
  v_diff := v_charges - v_assigned;
  IF v_diff <> 0 THEN
    SELECT a.item_id INTO v_target FROM fn_goods_receipt_allocation(p_goods_receipt_id) a
    ORDER BY a.allocated_charge_base DESC, a.total_cost_base DESC, a.item_id LIMIT 1;
  END IF;
  FOR r IN SELECT * FROM fn_goods_receipt_allocation(p_goods_receipt_id) LOOP
    item_id := r.item_id; variant_id := r.variant_id; quantity := r.quantity; unit_cost := r.unit_cost;
    unit_cost_base := r.unit_cost_base; total_cost_base := r.total_cost_base;
    allocated_charge_base := r.allocated_charge_base + CASE WHEN r.item_id = v_target THEN v_diff ELSE 0 END;
    landed_total_cost_base := r.total_cost_base + allocated_charge_base;
    landed_unit_cost_base := round(landed_total_cost_base / r.quantity, 6);
    RETURN NEXT;
  END LOOP;
  RETURN;
END $$;
REVOKE EXECUTE ON FUNCTION fn_goods_receipt_allocation_fixed(UUID) FROM PUBLIC, anon, authenticated;

-- Fingerprint of everything POST depends on. Review stores it; POST recomputes it: an
-- edited draft cannot be posted on an old review.
CREATE OR REPLACE FUNCTION fn_goods_receipt_hash(p_goods_receipt_id UUID)
RETURNS TEXT LANGUAGE sql SECURITY DEFINER STABLE SET search_path = pg_catalog, public AS $$
  SELECT md5(
    (SELECT concat_ws('|', supplier_id, branch_id, invoice_currency, exchange_rate, received_at, allocation_method)
       FROM goods_receipts WHERE id = p_goods_receipt_id)
    || '#' ||
    COALESCE((SELECT string_agg(concat_ws(':', variant_id, quantity, unit_cost, manual_allocation_base), ',' ORDER BY variant_id)
       FROM goods_receipt_items WHERE goods_receipt_id = p_goods_receipt_id), '')
    || '#' ||
    COALESCE((SELECT string_agg(concat_ws(':', kind, amount, currency, exchange_rate, include_in_landed, liability_mode, payee_supplier_id), ',' ORDER BY id)
       FROM goods_receipt_charges WHERE goods_receipt_id = p_goods_receipt_id), '')
  );
$$;
REVOKE EXECUTE ON FUNCTION fn_goods_receipt_hash(UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ rpc_goods_receipt_review (procurement)
-- Validates the draft as it would be posted, returns the landed-cost preview and stamps
-- the review. Nothing else is written; stock, cost and liabilities are untouched.
CREATE OR REPLACE FUNCTION rpc_goods_receipt_review(p_goods_receipt_id UUID)
RETURNS TABLE (
  item_id UUID, variant_id UUID, quantity INTEGER, unit_cost cost6,
  unit_cost_base cost6, total_cost_base value6,
  allocated_charge_base value6, landed_unit_cost_base cost6, landed_total_cost_base value6
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); gr RECORD; c RECORD;
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id FOR UPDATE;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(gr.business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
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

  -- charge rules
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
REVOKE EXECUTE ON FUNCTION rpc_goods_receipt_review(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_goods_receipt_review(UUID) TO authenticated;

-- ------------------------------------------------------------ rpc_post_goods_receipt (REPLACED)
-- Same signature and role as 004. New: requires a review whose fingerprint still matches
-- the document (STALE_DRAFT otherwise), writes landed cost into items, pools and ledger,
-- and books liabilities per the charge modes. One transaction; the header lock makes a
-- concurrent second call wait and then fail on INVALID_STATE.
CREATE OR REPLACE FUNCTION rpc_post_goods_receipt(p_goods_receipt_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor UUID := fn_actor(); gr RECORD; a RECORD; c RECORD; pr t_cost_pool_result;
  v_vids UUID[]; v_invoice_total NUMERIC := 0; v_liab NUMERIC := 0; v_charges_base NUMERIC := 0; v_landed_total NUMERIC := 0;
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id FOR UPDATE;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(gr.business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
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

    -- pool receives the landed value; ledger carries the landed unit cost
    pr := fn_post_to_cost_pool(gr.business_id, gr.branch_id, a.variant_id, a.quantity, NULL, a.landed_total_cost_base);
    PERFORM fn_ledger_post(gr.business_id, gr.branch_id, a.variant_id, 'sellable', a.quantity, 'goods_receipt',
                           'goods_receipt_item', a.item_id, pr.unit_cost_used, pr.value_delta_base, NULL, now(), v_actor);
    v_invoice_total := v_invoice_total + a.quantity * a.unit_cost;
    v_charges_base := v_charges_base + a.allocated_charge_base;
    v_landed_total := v_landed_total + a.landed_total_cost_base;
  END LOOP;

  -- liabilities: invoice supplier gets the invoice value plus the charges it bills;
  -- other payees get their own entry; no_liability charges book nothing
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
REVOKE EXECUTE ON FUNCTION rpc_post_goods_receipt(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_post_goods_receipt(UUID) TO authenticated;

-- ------------------------------------------------------------ rpc_reverse_goods_receipt (REPLACED, manager+)
DROP FUNCTION rpc_reverse_goods_receipt(UUID);
-- Takes the received quantities back out of the branch (sellable) at the current moving
-- average and credits every liability the receipt booked. The receipt row stays exactly
-- as posted; the reversal is recorded next to it. Refused when the goods are no longer
-- there (INSUFFICIENT_STOCK) — then a return or adjustment is the right document.
CREATE OR REPLACE FUNCTION rpc_reverse_goods_receipt(p_goods_receipt_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor UUID := fn_actor(); gr RECORD; it RECORD; e RECORD; pr t_cost_pool_result; v_vids UUID[]; v_removed NUMERIC := 0; v_id UUID;
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id FOR UPDATE;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(gr.business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(gr.business_id);
  IF gr.status <> 'posted' THEN RAISE EXCEPTION 'INVALID_STATE: receipt % is %, only posted receipts reverse', gr.receipt_number, gr.status USING ERRCODE = '55000'; END IF;
  IF EXISTS (SELECT 1 FROM goods_receipt_reversals WHERE goods_receipt_id = gr.id) THEN
    RAISE EXCEPTION 'ALREADY_REVERSED: receipt % was already reversed', gr.receipt_number USING ERRCODE = '55000';
  END IF;
  IF length(trim(COALESCE(p_reason, ''))) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = '22023'; END IF;
  PERFORM fn_assert_branch(gr.business_id, gr.branch_id);

  SELECT array_agg(variant_id ORDER BY variant_id) INTO v_vids FROM goods_receipt_items WHERE goods_receipt_id = gr.id;
  PERFORM fn_lock_pools(gr.business_id, gr.branch_id, v_vids);

  FOR it IN SELECT * FROM goods_receipt_items WHERE goods_receipt_id = gr.id ORDER BY variant_id LOOP
    IF fn_bucket_qty(gr.business_id, gr.branch_id, it.variant_id, 'sellable') < it.quantity THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK: variant % has fewer than % sellable; use a supplier return or an adjustment', it.variant_id, it.quantity USING ERRCODE = '55000';
    END IF;
  END LOOP;

  v_id := gen_random_uuid();
  FOR it IN SELECT * FROM goods_receipt_items WHERE goods_receipt_id = gr.id ORDER BY variant_id LOOP
    pr := fn_post_to_cost_pool(gr.business_id, gr.branch_id, it.variant_id, -it.quantity, NULL, NULL);
    PERFORM fn_ledger_post(gr.business_id, gr.branch_id, it.variant_id, 'sellable', -it.quantity, 'goods_receipt',
                           'goods_receipt_reversal_item', it.id, pr.unit_cost_used, pr.value_delta_base,
                           'Reversal of ' || gr.receipt_number, now(), v_actor);
    v_removed := v_removed - pr.value_delta_base;
  END LOOP;

  -- mirror every liability this receipt created (invoice + separate payees) as credits
  FOR e IN SELECT * FROM supplier_account_entries
           WHERE business_id = gr.business_id AND entry_type = 'liability'
             AND ((reference_type = 'goods_receipt' AND reference_id = gr.id)
               OR (reference_type = 'goods_receipt_charge' AND reference_id IN (SELECT id FROM goods_receipt_charges WHERE goods_receipt_id = gr.id))) LOOP
    INSERT INTO supplier_account_entries (business_id, supplier_id, entry_type, amount_original, currency, exchange_rate,
                                          reference_type, reference_id, note, created_by)
    VALUES (gr.business_id, e.supplier_id, 'credit', -e.amount_original, e.currency, e.exchange_rate,
            'goods_receipt_reversal', v_id, 'Reversal of goods receipt ' || gr.receipt_number, v_actor);
  END LOOP;

  INSERT INTO goods_receipt_reversals (id, business_id, goods_receipt_id, reason, reversed_by, value_removed_base)
  VALUES (v_id, gr.business_id, gr.id, trim(p_reason), v_actor, v_removed);
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_reverse_goods_receipt(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_reverse_goods_receipt(UUID, TEXT) TO authenticated;
