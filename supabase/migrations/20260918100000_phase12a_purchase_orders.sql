-- ============================================================
-- Phase 12A — Purchase order foundation
--
-- A purchase order is a planning / commercial document. Creating, approving, ordering,
-- cancelling or closing one writes NOTHING to the inventory ledger, the cost pools or the
-- supplier ledger: the only accounting / inventory event stays the POST of a goods
-- receipt (Phase 8A engine, unchanged). A receipt may reference a PO; received quantities
-- are DERIVED from posted, non-reversed linked receipt items — no counters.
--
-- Lifecycle:  draft → approved → ordered → partially_received → received → closed
--             draft / approved / ordered → cancelled (no posted receipt yet)
--             partially_received / received → closed ("close remaining": balance abandoned,
--             nothing is fabricated in the ledger)
--   draft              : header + lines editable (owner / manager)
--   approved / ordered : commercial terms frozen (lines, supplier, currency, order date);
--                        expected_date, supplier_reference and note stay editable
--   partially_received : same; a linked receipt may only carry PO variants and never more
--                        than the remaining quantity (OVER_RECEIPT), enforced at POST under
--                        the PO row lock so concurrent receipts cannot over-receive
--   received / closed / cancelled : immutable (audit), never deleted
-- Roles: create / edit / approve / order / cancel / close = owner + manager; stock_staff
-- reads the operational document (no expected cost) and may create the draft receipt from
-- it; sales_staff has no procurement access. Expected unit cost lives in the PO currency
-- and is NEVER copied into a receipt: the receipt's actual cost is entered there (COST_REQUIRED).
-- ============================================================

CREATE TYPE purchase_order_status AS ENUM ('draft','approved','ordered','partially_received','received','closed','cancelled');

CREATE TABLE purchase_orders (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID NOT NULL REFERENCES businesses(id),
  branch_id          UUID NOT NULL,
  supplier_id        UUID NOT NULL,
  po_number          TEXT NOT NULL,
  status             purchase_order_status NOT NULL DEFAULT 'draft',
  currency           iso_currency NOT NULL DEFAULT 'TRY',
  fx_rate_snapshot   fx6,                       -- informational only, never accounting truth
  order_date         DATE NOT NULL DEFAULT CURRENT_DATE,
  expected_date      DATE,
  supplier_reference TEXT,
  note               TEXT,
  created_by         UUID REFERENCES profiles(id),
  approved_by        UUID REFERENCES profiles(id),
  approved_at        TIMESTAMPTZ,
  ordered_by         UUID REFERENCES profiles(id),
  ordered_at         TIMESTAMPTZ,
  cancelled_by       UUID REFERENCES profiles(id),
  cancelled_at       TIMESTAMPTZ,
  cancel_reason      TEXT,
  closed_by          UUID REFERENCES profiles(id),
  closed_at          TIMESTAMPTZ,
  close_reason       TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, po_number),
  UNIQUE (business_id, id),
  CONSTRAINT chk_po_try_rate CHECK (currency <> 'TRY' OR fx_rate_snapshot IS NULL OR fx_rate_snapshot = 1),
  FOREIGN KEY (business_id, branch_id)   REFERENCES branches  (business_id, id),
  FOREIGN KEY (business_id, supplier_id) REFERENCES suppliers (business_id, id)
);
CREATE INDEX idx_po_business_status ON purchase_orders (business_id, status, order_date DESC);

CREATE TABLE purchase_order_items (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID NOT NULL REFERENCES businesses(id),
  purchase_order_id  UUID NOT NULL,
  variant_id         UUID NOT NULL,
  ordered_quantity   INTEGER NOT NULL CHECK (ordered_quantity > 0),
  expected_unit_cost cost6 CHECK (expected_unit_cost IS NULL OR expected_unit_cost >= 0),   -- PO currency, planning only
  note               TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (purchase_order_id, variant_id),
  FOREIGN KEY (business_id, purchase_order_id) REFERENCES purchase_orders (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, variant_id)        REFERENCES product_variants (business_id, id)
);
CREATE INDEX idx_poi_po ON purchase_order_items (purchase_order_id);

-- the receipt ↔ PO link; the composite FK makes a cross-tenant link impossible
ALTER TABLE goods_receipts ADD COLUMN purchase_order_id UUID;
ALTER TABLE goods_receipts ADD CONSTRAINT goods_receipts_business_id_purchase_order_id_fkey
  FOREIGN KEY (business_id, purchase_order_id) REFERENCES purchase_orders (business_id, id);
CREATE INDEX idx_gr_po ON goods_receipts (purchase_order_id) WHERE purchase_order_id IS NOT NULL;

-- ------------------------------------------------------------ privileges: reads by RLS, writes only through RPCs
ALTER TABLE purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_po_select  ON purchase_orders      FOR SELECT USING (fn_is_procurement(business_id));
CREATE POLICY pol_poi_select ON purchase_order_items FOR SELECT USING (fn_is_procurement(business_id));
REVOKE ALL ON purchase_orders, purchase_order_items FROM anon, authenticated;
GRANT SELECT ON purchase_orders TO authenticated;
GRANT SELECT (id, business_id, purchase_order_id, variant_id, ordered_quantity, note, created_at) ON purchase_order_items TO authenticated;
-- expected_unit_cost: no client SELECT at all (manager+ read it through rpc_po_detail), like the 8A cost columns

-- ------------------------------------------------------------ immutability
CREATE OR REPLACE FUNCTION fn_guard_purchase_order()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'IMMUTABLE: purchase order % is never deleted (cancel it)', OLD.po_number USING ERRCODE = '55000';
  END IF;
  IF OLD.status IN ('closed','cancelled') THEN
    RAISE EXCEPTION 'IMMUTABLE: purchase order % is %', OLD.po_number, OLD.status USING ERRCODE = '55000';
  END IF;
  -- fully received: only closing it, or a reversal moving it back, may change it
  IF OLD.status = 'received' AND NEW.status = 'received' AND (NEW.note IS DISTINCT FROM OLD.note OR NEW.expected_date IS DISTINCT FROM OLD.expected_date
                                                              OR NEW.supplier_reference IS DISTINCT FROM OLD.supplier_reference) THEN
    RAISE EXCEPTION 'IMMUTABLE: purchase order % is received', OLD.po_number USING ERRCODE = '55000';
  END IF;
  IF OLD.status <> 'draft' AND (NEW.supplier_id <> OLD.supplier_id OR NEW.branch_id <> OLD.branch_id OR NEW.currency <> OLD.currency
                                 OR NEW.order_date <> OLD.order_date OR NEW.po_number <> OLD.po_number) THEN
    RAISE EXCEPTION 'IMMUTABLE: commercial terms of purchase order % are frozen after approval', OLD.po_number USING ERRCODE = '55000';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_po BEFORE UPDATE OR DELETE ON purchase_orders
  FOR EACH ROW EXECUTE FUNCTION fn_guard_purchase_order();

CREATE OR REPLACE FUNCTION fn_guard_purchase_order_item()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_status purchase_order_status; v_id UUID := COALESCE(NEW.purchase_order_id, OLD.purchase_order_id);
BEGIN
  SELECT status INTO v_status FROM purchase_orders WHERE id = v_id;
  IF v_status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'IMMUTABLE: lines of a % purchase order cannot change', v_status USING ERRCODE = '55000';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  NEW.business_id := (SELECT business_id FROM purchase_orders WHERE id = NEW.purchase_order_id);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_poi BEFORE INSERT OR UPDATE OR DELETE ON purchase_order_items
  FOR EACH ROW EXECUTE FUNCTION fn_guard_purchase_order_item();

-- ------------------------------------------------------------ derived receiving state
-- received per PO line = Σ quantity of POSTED, non-reversed linked receipt items
CREATE OR REPLACE FUNCTION fn_po_received(p_po_id UUID)
RETURNS TABLE (variant_id UUID, received INTEGER) LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT gi.variant_id, sum(gi.quantity)::integer
  FROM goods_receipts g JOIN goods_receipt_items gi ON gi.goods_receipt_id = g.id
  WHERE g.purchase_order_id = p_po_id AND g.status = 'posted'
    AND NOT EXISTS (SELECT 1 FROM goods_receipt_reversals rv WHERE rv.goods_receipt_id = g.id)
  GROUP BY gi.variant_id;
$$;
REVOKE EXECUTE ON FUNCTION fn_po_received(UUID) FROM PUBLIC, anon, authenticated;

-- Recompute the receiving status from the authoritative tables. Caller holds the PO lock.
CREATE OR REPLACE FUNCTION fn_po_refresh_status(p_po_id UUID)
RETURNS purchase_order_status LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE po RECORD; v_ordered INTEGER; v_received INTEGER; v_all BOOLEAN; v_new purchase_order_status;
BEGIN
  SELECT * INTO po FROM purchase_orders WHERE id = p_po_id;
  IF po.status IN ('draft','approved','closed','cancelled') THEN RETURN po.status; END IF;
  SELECT COALESCE(sum(i.ordered_quantity), 0), COALESCE(sum(LEAST(COALESCE(r.received, 0), i.ordered_quantity)), 0),
         bool_and(COALESCE(r.received, 0) >= i.ordered_quantity)
  INTO v_ordered, v_received, v_all
  FROM purchase_order_items i LEFT JOIN fn_po_received(p_po_id) r ON r.variant_id = i.variant_id
  WHERE i.purchase_order_id = p_po_id;
  v_new := CASE WHEN v_received = 0 THEN 'ordered' WHEN v_all THEN 'received' ELSE 'partially_received' END;
  IF v_new <> po.status THEN
    UPDATE purchase_orders SET status = v_new WHERE id = p_po_id;
  END IF;
  RETURN v_new;
END $$;
REVOKE EXECUTE ON FUNCTION fn_po_refresh_status(UUID) FROM PUBLIC, anon, authenticated;

-- Receipt POST → PO: under the PO row lock, every receipt line must be a PO line and the
-- posted total (this receipt included) may not exceed the ordered quantity. A failure here
-- rolls the whole POST back — the ledger, pools and liability of that receipt never happen.
CREATE OR REPLACE FUNCTION fn_po_on_receipt_posted()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE po RECORD; bad RECORD;
BEGIN
  SELECT * INTO po FROM purchase_orders WHERE id = NEW.purchase_order_id FOR UPDATE;
  IF po.id IS NULL OR po.business_id <> NEW.business_id THEN
    RAISE EXCEPTION 'INVALID_PO: receipt % is linked to an unknown purchase order', NEW.receipt_number USING ERRCODE = '22023';
  END IF;
  IF po.status NOT IN ('ordered','partially_received') THEN
    RAISE EXCEPTION 'PO_NOT_OPEN: purchase order % is %, receipt % cannot be posted against it', po.po_number, po.status, NEW.receipt_number USING ERRCODE = '55000';
  END IF;
  IF NEW.supplier_id <> po.supplier_id THEN
    RAISE EXCEPTION 'PO_SUPPLIER_MISMATCH: receipt % is from another supplier than purchase order %', NEW.receipt_number, po.po_number USING ERRCODE = '22023';
  END IF;
  SELECT gi.variant_id INTO bad FROM goods_receipt_items gi
  WHERE gi.goods_receipt_id = NEW.id AND NOT EXISTS (SELECT 1 FROM purchase_order_items i WHERE i.purchase_order_id = po.id AND i.variant_id = gi.variant_id)
  LIMIT 1;
  IF bad.variant_id IS NOT NULL THEN
    RAISE EXCEPTION 'NOT_IN_PO: variant % is not on purchase order %', bad.variant_id, po.po_number USING ERRCODE = '22023';
  END IF;
  SELECT i.variant_id, i.ordered_quantity, r.received INTO bad
  FROM purchase_order_items i JOIN fn_po_received(po.id) r ON r.variant_id = i.variant_id
  WHERE i.purchase_order_id = po.id AND r.received > i.ordered_quantity
  LIMIT 1;
  IF bad.variant_id IS NOT NULL THEN
    RAISE EXCEPTION 'OVER_RECEIPT: variant % would reach % received against % ordered on purchase order %',
      bad.variant_id, bad.received, bad.ordered_quantity, po.po_number USING ERRCODE = '55000';
  END IF;
  PERFORM fn_po_refresh_status(po.id);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_po_receipt_posted AFTER UPDATE OF status ON goods_receipts
  FOR EACH ROW WHEN (OLD.status = 'draft' AND NEW.status = 'posted' AND NEW.purchase_order_id IS NOT NULL)
  EXECUTE FUNCTION fn_po_on_receipt_posted();

-- A reversal takes the receipt's units out of the received total; the PO status follows.
CREATE OR REPLACE FUNCTION fn_po_on_receipt_reversed()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_po UUID;
BEGIN
  SELECT purchase_order_id INTO v_po FROM goods_receipts WHERE id = NEW.goods_receipt_id;
  IF v_po IS NOT NULL THEN
    PERFORM 1 FROM purchase_orders WHERE id = v_po FOR UPDATE;
    PERFORM fn_po_refresh_status(v_po);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_po_receipt_reversed AFTER INSERT ON goods_receipt_reversals
  FOR EACH ROW EXECUTE FUNCTION fn_po_on_receipt_reversed();

-- The link itself: set once on a draft, to an open PO of the same tenant; never moved.
CREATE OR REPLACE FUNCTION fn_guard_receipt_po_link()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE po RECORD;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.purchase_order_id IS NOT DISTINCT FROM OLD.purchase_order_id THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.purchase_order_id IS NOT NULL THEN
    RAISE EXCEPTION 'IMMUTABLE: receipt % is already linked to a purchase order', OLD.receipt_number USING ERRCODE = '55000';
  END IF;
  IF NEW.purchase_order_id IS NULL THEN RETURN NEW; END IF;
  IF NEW.status <> 'draft' THEN
    RAISE EXCEPTION 'INVALID_STATE: only a draft receipt can be linked to a purchase order' USING ERRCODE = '55000';
  END IF;
  SELECT * INTO po FROM purchase_orders WHERE id = NEW.purchase_order_id AND business_id = NEW.business_id;
  IF po.id IS NULL THEN RAISE EXCEPTION 'INVALID_PO: purchase order not in this business' USING ERRCODE = '22023'; END IF;
  IF po.status NOT IN ('ordered','partially_received') THEN
    RAISE EXCEPTION 'PO_NOT_OPEN: purchase order % is %', po.po_number, po.status USING ERRCODE = '55000';
  END IF;
  IF po.supplier_id <> NEW.supplier_id THEN
    RAISE EXCEPTION 'PO_SUPPLIER_MISMATCH: purchase order % belongs to another supplier', po.po_number USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_gr_po_link BEFORE INSERT OR UPDATE OF purchase_order_id ON goods_receipts
  FOR EACH ROW EXECUTE FUNCTION fn_guard_receipt_po_link();

-- ------------------------------------------------------------ RPCs
CREATE OR REPLACE FUNCTION rpc_po_create(
  p_branch_id UUID, p_supplier_id UUID, p_currency TEXT DEFAULT 'TRY', p_fx_rate NUMERIC DEFAULT NULL,
  p_order_date DATE DEFAULT CURRENT_DATE, p_expected_date DATE DEFAULT NULL, p_supplier_reference TEXT DEFAULT NULL, p_note TEXT DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); v_biz UUID; v_cur iso_currency; v_id UUID;
BEGIN
  SELECT business_id INTO v_biz FROM branches WHERE id = p_branch_id;
  IF v_biz IS NULL THEN RAISE EXCEPTION 'INVALID_BRANCH: branch % not found', p_branch_id USING ERRCODE = '22023'; END IF;
  PERFORM fn_require_role(v_biz, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(v_biz);
  PERFORM fn_assert_branch(v_biz, p_branch_id);
  IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND business_id = v_biz AND status = 'active') THEN
    RAISE EXCEPTION 'INVALID_SUPPLIER: supplier % not active in business %', p_supplier_id, v_biz USING ERRCODE = '22023';
  END IF;
  BEGIN v_cur := p_currency::iso_currency; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_CURRENCY: %', p_currency USING ERRCODE = '22023'; END;
  IF p_fx_rate IS NOT NULL AND p_fx_rate <= 0 THEN RAISE EXCEPTION 'INVALID_FX: exchange rate must be greater than zero' USING ERRCODE = '22023'; END IF;
  IF v_cur = 'TRY' AND p_fx_rate IS NOT NULL AND p_fx_rate <> 1 THEN RAISE EXCEPTION 'INVALID_FX: TRY order must have exchange_rate = 1' USING ERRCODE = '22023'; END IF;
  IF p_order_date IS NULL THEN RAISE EXCEPTION 'INVALID_DATE: order_date is required' USING ERRCODE = '22023'; END IF;
  IF p_expected_date IS NOT NULL AND p_expected_date < p_order_date THEN RAISE EXCEPTION 'INVALID_DATE: expected_date before order_date' USING ERRCODE = '22023'; END IF;
  INSERT INTO purchase_orders (business_id, branch_id, supplier_id, po_number, currency, fx_rate_snapshot, order_date, expected_date, supplier_reference, note, created_by)
  VALUES (v_biz, p_branch_id, p_supplier_id, fn_next_sequence(v_biz, 'PO'), v_cur, p_fx_rate, p_order_date, p_expected_date,
          NULLIF(trim(p_supplier_reference), ''), NULLIF(trim(p_note), ''), v_actor)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_po_create(UUID,UUID,TEXT,NUMERIC,DATE,DATE,TEXT,TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_po_create(UUID,UUID,TEXT,NUMERIC,DATE,DATE,TEXT,TEXT) TO authenticated;

-- header fields that stay editable after approval: expected date, supplier reference, note
CREATE OR REPLACE FUNCTION rpc_po_update(p_po_id UUID, p_expected_date DATE, p_supplier_reference TEXT, p_note TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE po RECORD;
BEGIN
  SELECT * INTO po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF po.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: purchase order %', p_po_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(po.business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(po.business_id);
  IF po.status IN ('received','closed','cancelled') THEN RAISE EXCEPTION 'INVALID_STATE: purchase order % is %', po.po_number, po.status USING ERRCODE = '55000'; END IF;
  IF p_expected_date IS NOT NULL AND p_expected_date < po.order_date THEN RAISE EXCEPTION 'INVALID_DATE: expected_date before order_date' USING ERRCODE = '22023'; END IF;
  UPDATE purchase_orders SET expected_date = p_expected_date, supplier_reference = NULLIF(trim(p_supplier_reference), ''), note = NULLIF(trim(p_note), '')
  WHERE id = po.id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_po_update(UUID, DATE, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_po_update(UUID, DATE, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_po_upsert_line(p_po_id UUID, p_variant_id UUID, p_quantity INTEGER, p_expected_unit_cost NUMERIC DEFAULT NULL, p_note TEXT DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE po RECORD; v_id UUID;
BEGIN
  SELECT * INTO po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF po.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: purchase order %', p_po_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(po.business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(po.business_id);
  IF po.status <> 'draft' THEN RAISE EXCEPTION 'INVALID_STATE: purchase order % is %, lines are frozen', po.po_number, po.status USING ERRCODE = '55000'; END IF;
  PERFORM fn_assert_variant(po.business_id, p_variant_id);
  IF NOT EXISTS (SELECT 1 FROM product_variants pv JOIN products p ON p.id = pv.product_id WHERE pv.id = p_variant_id AND pv.status = 'active' AND p.status = 'active') THEN
    RAISE EXCEPTION 'INVALID_VARIANT: variant % is not active', p_variant_id USING ERRCODE = '22023';
  END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN RAISE EXCEPTION 'INVALID_QTY: quantity must be positive' USING ERRCODE = '22023'; END IF;
  IF p_expected_unit_cost IS NOT NULL AND p_expected_unit_cost < 0 THEN RAISE EXCEPTION 'INVALID_COST: expected cost must not be negative' USING ERRCODE = '22023'; END IF;
  SELECT id INTO v_id FROM purchase_order_items WHERE purchase_order_id = po.id AND variant_id = p_variant_id;
  IF v_id IS NULL THEN
    INSERT INTO purchase_order_items (business_id, purchase_order_id, variant_id, ordered_quantity, expected_unit_cost, note)
    VALUES (po.business_id, po.id, p_variant_id, p_quantity, p_expected_unit_cost, NULLIF(trim(p_note), '')) RETURNING id INTO v_id;
  ELSE
    UPDATE purchase_order_items SET ordered_quantity = p_quantity, expected_unit_cost = p_expected_unit_cost, note = NULLIF(trim(p_note), '') WHERE id = v_id;
  END IF;
  UPDATE purchase_orders SET updated_at = now() WHERE id = po.id;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_po_upsert_line(UUID, UUID, INTEGER, NUMERIC, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_po_upsert_line(UUID, UUID, INTEGER, NUMERIC, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_po_remove_line(p_po_id UUID, p_variant_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE po RECORD;
BEGIN
  SELECT * INTO po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF po.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: purchase order %', p_po_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(po.business_id, ARRAY['owner','manager']::user_role[]);
  IF po.status <> 'draft' THEN RAISE EXCEPTION 'INVALID_STATE: purchase order % is %, lines are frozen', po.po_number, po.status USING ERRCODE = '55000'; END IF;
  DELETE FROM purchase_order_items WHERE purchase_order_id = po.id AND variant_id = p_variant_id;
  UPDATE purchase_orders SET updated_at = now() WHERE id = po.id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_po_remove_line(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_po_remove_line(UUID, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_po_approve(p_po_id UUID)
RETURNS purchase_order_status LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); po RECORD;
BEGIN
  SELECT * INTO po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF po.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: purchase order %', p_po_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(po.business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(po.business_id);
  IF po.status <> 'draft' THEN RAISE EXCEPTION 'INVALID_STATE: purchase order % is %, only a draft is approved', po.po_number, po.status USING ERRCODE = '55000'; END IF;
  IF NOT EXISTS (SELECT 1 FROM purchase_order_items WHERE purchase_order_id = po.id) THEN
    RAISE EXCEPTION 'EMPTY_DOCUMENT: purchase order % has no lines', po.po_number USING ERRCODE = '22023';
  END IF;
  UPDATE purchase_orders SET status = 'approved', approved_by = v_actor, approved_at = now() WHERE id = po.id;
  RETURN 'approved';
END $$;
REVOKE EXECUTE ON FUNCTION rpc_po_approve(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_po_approve(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_po_mark_ordered(p_po_id UUID)
RETURNS purchase_order_status LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); po RECORD;
BEGIN
  SELECT * INTO po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF po.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: purchase order %', p_po_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(po.business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(po.business_id);
  IF po.status <> 'approved' THEN RAISE EXCEPTION 'INVALID_STATE: purchase order % is %, only an approved order is sent', po.po_number, po.status USING ERRCODE = '55000'; END IF;
  UPDATE purchase_orders SET status = 'ordered', ordered_by = v_actor, ordered_at = now() WHERE id = po.id;
  RETURN 'ordered';
END $$;
REVOKE EXECUTE ON FUNCTION rpc_po_mark_ordered(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_po_mark_ordered(UUID) TO authenticated;

-- Cancel: nothing has been received (no posted, non-reversed receipt) and no draft receipt is still open against it.
CREATE OR REPLACE FUNCTION rpc_po_cancel(p_po_id UUID, p_reason TEXT)
RETURNS purchase_order_status LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); po RECORD;
BEGIN
  SELECT * INTO po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF po.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: purchase order %', p_po_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(po.business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(po.business_id);
  IF po.status NOT IN ('draft','approved','ordered') THEN
    RAISE EXCEPTION 'INVALID_STATE: purchase order % is %; a partly received order is closed, not cancelled', po.po_number, po.status USING ERRCODE = '55000';
  END IF;
  IF length(trim(COALESCE(p_reason, ''))) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED: give a cancellation reason' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM goods_receipts g WHERE g.purchase_order_id = po.id AND g.status = 'draft') THEN
    RAISE EXCEPTION 'OPEN_RECEIPTS: cancel or post the draft receipts linked to % first', po.po_number USING ERRCODE = '55000';
  END IF;
  IF EXISTS (SELECT 1 FROM fn_po_received(po.id) r WHERE r.received > 0) THEN
    RAISE EXCEPTION 'INVALID_STATE: purchase order % has posted receipts', po.po_number USING ERRCODE = '55000';
  END IF;
  UPDATE purchase_orders SET status = 'cancelled', cancelled_by = v_actor, cancelled_at = now(), cancel_reason = trim(p_reason) WHERE id = po.id;
  RETURN 'cancelled';
END $$;
REVOKE EXECUTE ON FUNCTION rpc_po_cancel(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_po_cancel(UUID, TEXT) TO authenticated;

-- Close: the balance of a partly received order is abandoned (shown as unfulfilled), or a fully received order is filed. Nothing is posted.
CREATE OR REPLACE FUNCTION rpc_po_close(p_po_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS purchase_order_status LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); po RECORD;
BEGIN
  SELECT * INTO po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF po.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: purchase order %', p_po_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(po.business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(po.business_id);
  IF po.status NOT IN ('partially_received','received') THEN
    RAISE EXCEPTION 'INVALID_STATE: purchase order % is %; only a (partly) received order is closed', po.po_number, po.status USING ERRCODE = '55000';
  END IF;
  IF po.status = 'partially_received' AND length(trim(COALESCE(p_reason, ''))) < 3 THEN
    RAISE EXCEPTION 'REASON_REQUIRED: say why the remaining quantity is abandoned' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM goods_receipts g WHERE g.purchase_order_id = po.id AND g.status = 'draft') THEN
    RAISE EXCEPTION 'OPEN_RECEIPTS: cancel or post the draft receipts linked to % first', po.po_number USING ERRCODE = '55000';
  END IF;
  UPDATE purchase_orders SET status = 'closed', closed_by = v_actor, closed_at = now(), close_reason = NULLIF(trim(COALESCE(p_reason, '')), '') WHERE id = po.id;
  RETURN 'closed';
END $$;
REVOKE EXECUTE ON FUNCTION rpc_po_close(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_po_close(UUID, TEXT) TO authenticated;

-- "Mal kabul oluştur": a DRAFT receipt through the Phase 8A engine, linked to the PO, prefilled
-- with the remaining quantities and NO cost (the operator records what was delivered; the
-- manager prices it — the PO's expected cost is shown as a reference only).
CREATE OR REPLACE FUNCTION rpc_po_create_receipt(p_po_id UUID, p_received_at DATE DEFAULT CURRENT_DATE, p_document_ref TEXT DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE po RECORD; v_gr UUID; r RECORD; v_any BOOLEAN := false;
BEGIN
  SELECT * INTO po FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
  IF po.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: purchase order %', p_po_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(po.business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
  PERFORM fn_require_active_business(po.business_id);
  IF po.status = 'received' THEN
    RAISE EXCEPTION 'NOTHING_REMAINING: purchase order % is fully received', po.po_number USING ERRCODE = '55000';
  END IF;
  IF po.status NOT IN ('ordered','partially_received') THEN
    RAISE EXCEPTION 'PO_NOT_OPEN: purchase order % is %', po.po_number, po.status USING ERRCODE = '55000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM purchase_order_items i LEFT JOIN fn_po_received(po.id) rc ON rc.variant_id = i.variant_id
                 WHERE i.purchase_order_id = po.id AND i.ordered_quantity - COALESCE(rc.received, 0) > 0) THEN
    RAISE EXCEPTION 'NOTHING_REMAINING: purchase order % is fully received', po.po_number USING ERRCODE = '55000';
  END IF;
  v_gr := rpc_create_goods_receipt(po.branch_id, po.supplier_id, po.currency::text, COALESCE(po.fx_rate_snapshot, 1), p_received_at,
                                   COALESCE(NULLIF(trim(p_document_ref), ''), po.po_number), 'Satın alma siparişi ' || po.po_number);
  UPDATE goods_receipts SET purchase_order_id = po.id WHERE id = v_gr;
  FOR r IN SELECT i.variant_id, i.ordered_quantity - COALESCE(rc.received, 0) AS remaining
           FROM purchase_order_items i LEFT JOIN fn_po_received(po.id) rc ON rc.variant_id = i.variant_id
           WHERE i.purchase_order_id = po.id AND i.ordered_quantity - COALESCE(rc.received, 0) > 0 LOOP
    PERFORM rpc_goods_receipt_upsert_line(v_gr, r.variant_id, r.remaining, NULL);
    v_any := true;
  END LOOP;
  RETURN v_gr;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_po_create_receipt(UUID, DATE, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_po_create_receipt(UUID, DATE, TEXT) TO authenticated;

-- ------------------------------------------------------------ reads (bounded, one call per surface)
CREATE OR REPLACE FUNCTION rpc_po_list(p_business_id UUID, p_status TEXT DEFAULT NULL, p_limit INTEGER DEFAULT 100)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_role user_role; v_fin BOOLEAN; v_rows JSONB; v_sum JSONB;
BEGIN
  v_role := fn_require_role(p_business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
  v_fin := v_role IN ('owner','manager');
  WITH po AS (
    SELECT p.*, s.name AS supplier_name, b.name AS branch_name,
           (SELECT COALESCE(sum(i.ordered_quantity), 0) FROM purchase_order_items i WHERE i.purchase_order_id = p.id) AS ordered,
           (SELECT COALESCE(sum(LEAST(rc.received, i.ordered_quantity)), 0) FROM purchase_order_items i JOIN fn_po_received(p.id) rc ON rc.variant_id = i.variant_id WHERE i.purchase_order_id = p.id) AS received,
           (SELECT count(*) FROM purchase_order_items i WHERE i.purchase_order_id = p.id) AS lines,
           (SELECT COALESCE(sum(i.ordered_quantity * i.expected_unit_cost), 0) FROM purchase_order_items i WHERE i.purchase_order_id = p.id) AS expected_total,
           (SELECT count(*) FROM purchase_order_items i WHERE i.purchase_order_id = p.id AND i.expected_unit_cost IS NULL) AS unpriced
    FROM purchase_orders p JOIN suppliers s ON s.id = p.supplier_id JOIN branches b ON b.id = p.branch_id
    WHERE p.business_id = p_business_id AND (p_status IS NULL OR p.status::text = p_status)
    ORDER BY p.order_date DESC, p.created_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500)),
  rows AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'id', id, 'po_number', po_number, 'status', status, 'supplier', supplier_name, 'branch', branch_name,
             'currency', currency, 'order_date', order_date, 'expected_date', expected_date, 'supplier_reference', supplier_reference,
             'lines', lines, 'ordered', ordered, 'received', received, 'remaining', ordered - received,
             'overdue', expected_date IS NOT NULL AND expected_date < CURRENT_DATE AND status IN ('approved','ordered','partially_received'))
             || CASE WHEN v_fin THEN jsonb_build_object('expected_total', round(expected_total, 2), 'unpriced_lines', unpriced) ELSE '{}'::jsonb END
             ORDER BY order_date DESC, created_at DESC), '[]'::jsonb) AS j FROM po),
  summary AS (
    SELECT jsonb_build_object(
      'open', count(*) FILTER (WHERE status IN ('approved','ordered','partially_received')),
      'draft', count(*) FILTER (WHERE status = 'draft'),
      'expected_units', COALESCE(sum(ordered) FILTER (WHERE status IN ('approved','ordered','partially_received')), 0),
      'received_units', COALESCE(sum(received) FILTER (WHERE status IN ('approved','ordered','partially_received')), 0),
      'remaining_units', COALESCE(sum(ordered - received) FILTER (WHERE status IN ('approved','ordered','partially_received')), 0),
      'overdue', count(*) FILTER (WHERE expected_date IS NOT NULL AND expected_date < CURRENT_DATE AND status IN ('approved','ordered','partially_received'))) AS j
    FROM po)
  SELECT rows.j, summary.j INTO v_rows, v_sum FROM rows, summary;
  RETURN jsonb_build_object('financial', v_fin, 'rows', v_rows, 'summary', v_sum);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_po_list(UUID, TEXT, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_po_list(UUID, TEXT, INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_po_detail(p_po_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE po RECORD; v_role user_role; v_fin BOOLEAN; v_lines JSONB; v_receipts JSONB;
BEGIN
  SELECT p.*, s.name AS supplier_name, b.name AS branch_name,
         pc.full_name AS created_name, pa.full_name AS approved_name, pord.full_name AS ordered_name, pcan.full_name AS cancelled_name, pcl.full_name AS closed_name
  INTO po FROM purchase_orders p
  JOIN suppliers s ON s.id = p.supplier_id JOIN branches b ON b.id = p.branch_id
  LEFT JOIN profiles pc ON pc.id = p.created_by LEFT JOIN profiles pa ON pa.id = p.approved_by LEFT JOIN profiles pord ON pord.id = p.ordered_by
  LEFT JOIN profiles pcan ON pcan.id = p.cancelled_by LEFT JOIN profiles pcl ON pcl.id = p.closed_by
  WHERE p.id = p_po_id;
  IF po.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: purchase order %', p_po_id USING ERRCODE = 'P0002'; END IF;
  v_role := fn_require_role(po.business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
  v_fin := v_role IN ('owner','manager');
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'variant_id', i.variant_id, 'product_id', pv.product_id, 'product', p.name, 'sku', pv.sku,
           'options', (SELECT string_agg(ov.value, ' / ' ORDER BY po2.sort_order, po2.name) FROM variant_option_values vov
                       JOIN product_options po2 ON po2.id = vov.product_option_id JOIN option_values ov ON ov.id = vov.option_value_id WHERE vov.variant_id = i.variant_id),
           'ordered', i.ordered_quantity, 'received', COALESCE(rc.received, 0), 'remaining', GREATEST(i.ordered_quantity - COALESCE(rc.received, 0), 0),
           'note', i.note,
           'available', COALESCE((SELECT sum(m.quantity) FROM inventory_movements m WHERE m.business_id = po.business_id AND m.branch_id = po.branch_id AND m.variant_id = i.variant_id AND m.bucket = 'sellable'), 0)
                        - COALESCE((SELECT sum(ri.quantity) FROM reservation_items ri JOIN reservations r ON r.id = ri.reservation_id
                                    WHERE r.business_id = po.business_id AND r.branch_id = po.branch_id AND ri.variant_id = i.variant_id AND r.status = 'active' AND r.expires_at > now()), 0))
           || CASE WHEN v_fin THEN jsonb_build_object('expected_unit_cost', i.expected_unit_cost,
                                                     'expected_total', CASE WHEN i.expected_unit_cost IS NULL THEN NULL ELSE round(i.ordered_quantity * i.expected_unit_cost, 2) END)
              ELSE '{}'::jsonb END
           ORDER BY p.name, pv.sku), '[]'::jsonb)
  INTO v_lines
  FROM purchase_order_items i JOIN product_variants pv ON pv.id = i.variant_id JOIN products p ON p.id = pv.product_id
  LEFT JOIN fn_po_received(po.id) rc ON rc.variant_id = i.variant_id
  WHERE i.purchase_order_id = po.id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', g.id, 'receipt_number', g.receipt_number, 'status', g.status, 'received_at', g.received_at, 'posted_at', g.posted_at,
           'reversed', EXISTS (SELECT 1 FROM goods_receipt_reversals rv WHERE rv.goods_receipt_id = g.id),
           'units', (SELECT COALESCE(sum(gi.quantity), 0) FROM goods_receipt_items gi WHERE gi.goods_receipt_id = g.id),
           'invoice_currency', g.invoice_currency, 'exchange_rate', g.exchange_rate)
           ORDER BY g.created_at), '[]'::jsonb)
  INTO v_receipts FROM goods_receipts g WHERE g.purchase_order_id = po.id;
  RETURN jsonb_build_object(
    'id', po.id, 'po_number', po.po_number, 'status', po.status, 'financial', v_fin, 'role', v_role,
    'supplier_id', po.supplier_id, 'supplier', po.supplier_name, 'branch_id', po.branch_id, 'branch', po.branch_name,
    'currency', po.currency, 'fx_rate_snapshot', po.fx_rate_snapshot, 'order_date', po.order_date, 'expected_date', po.expected_date,
    'supplier_reference', po.supplier_reference, 'note', po.note,
    'timeline', jsonb_build_object(
      'created', jsonb_build_object('at', po.created_at, 'by', po.created_name),
      'approved', CASE WHEN po.approved_at IS NULL THEN NULL ELSE jsonb_build_object('at', po.approved_at, 'by', po.approved_name) END,
      'ordered', CASE WHEN po.ordered_at IS NULL THEN NULL ELSE jsonb_build_object('at', po.ordered_at, 'by', po.ordered_name) END,
      'cancelled', CASE WHEN po.cancelled_at IS NULL THEN NULL ELSE jsonb_build_object('at', po.cancelled_at, 'by', po.cancelled_name, 'reason', po.cancel_reason) END,
      'closed', CASE WHEN po.closed_at IS NULL THEN NULL ELSE jsonb_build_object('at', po.closed_at, 'by', po.closed_name, 'reason', po.close_reason) END),
    'lines', v_lines,
    'totals', (SELECT jsonb_build_object('ordered', COALESCE(sum((l ->> 'ordered')::int), 0), 'received', COALESCE(sum((l ->> 'received')::int), 0),
                                         'remaining', COALESCE(sum((l ->> 'remaining')::int), 0), 'lines', count(*))
                      || CASE WHEN v_fin THEN jsonb_build_object('expected_total', round(COALESCE(sum((l ->> 'expected_total')::numeric), 0), 2),
                                                                'unpriced_lines', count(*) FILTER (WHERE (l ->> 'expected_unit_cost') IS NULL)) ELSE '{}'::jsonb END
               FROM jsonb_array_elements(v_lines) l),
    'receipts', v_receipts,
    'open_draft_receipts', (SELECT count(*) FROM goods_receipts g WHERE g.purchase_order_id = po.id AND g.status = 'draft'));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_po_detail(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_po_detail(UUID) TO authenticated;

-- PO reference for the receipt editor: expected quantities / costs of the linked PO (cost manager+ only)
CREATE OR REPLACE FUNCTION rpc_receipt_po_reference(p_goods_receipt_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE gr RECORD; v_role user_role; v_fin BOOLEAN; v_lines JSONB;
BEGIN
  SELECT g.*, p.po_number, p.currency AS po_currency, p.status AS po_status INTO gr
  FROM goods_receipts g JOIN purchase_orders p ON p.id = g.purchase_order_id WHERE g.id = p_goods_receipt_id;
  IF gr.id IS NULL THEN RETURN NULL; END IF;
  v_role := fn_require_role(gr.business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
  v_fin := v_role IN ('owner','manager');
  SELECT COALESCE(jsonb_agg(jsonb_build_object('variant_id', i.variant_id, 'ordered', i.ordered_quantity, 'received', COALESCE(rc.received, 0),
                                               'remaining', GREATEST(i.ordered_quantity - COALESCE(rc.received, 0), 0))
                            || CASE WHEN v_fin THEN jsonb_build_object('expected_unit_cost', i.expected_unit_cost) ELSE '{}'::jsonb END), '[]'::jsonb)
  INTO v_lines
  FROM purchase_order_items i LEFT JOIN fn_po_received(gr.purchase_order_id) rc ON rc.variant_id = i.variant_id
  WHERE i.purchase_order_id = gr.purchase_order_id;
  RETURN jsonb_build_object('purchase_order_id', gr.purchase_order_id, 'po_number', gr.po_number, 'po_status', gr.po_status, 'po_currency', gr.po_currency,
                            'financial', v_fin, 'lines', v_lines);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_receipt_po_reference(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_receipt_po_reference(UUID) TO authenticated;

-- ============================================================
-- END phase 12A
-- ============================================================
