-- ============================================================
-- BoutiqueOS  •  Migration 003  •  Inventory / sales / returns /
--                                transfers / registers schema
-- Rev 3  •  2026-09-08
-- ============================================================
-- Every table here that carries inventory or accounting facts is
-- append-only and RPC-written (no client INSERT/UPDATE/DELETE policies,
-- plus immutability triggers). Cost-bearing columns live ONLY in
-- manager+ tables:
--   variant_cost_pools, inventory_movement_costs, sale_item_costs,
--   sale_costs, transfer_held_inventory, inventory_adjustments
-- ============================================================

-- ============================================================
-- COMPOSITE RESULT TYPE for fn_post_to_cost_pool
-- ============================================================
CREATE TYPE t_cost_pool_result AS (
  unit_cost_used        cost6,    -- outflow: PRE-movement MWA; inflow: the unit cost booked
  value_delta_base      value6,   -- signed exact change of total_value_base
  new_on_hand_qty       INTEGER,
  new_total_value_base  value6
);

-- ============================================================
-- VARIANT COST POOLS  (business + branch + variant; condition-neutral)
-- ============================================================
CREATE TABLE variant_cost_pools (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  branch_id        UUID NOT NULL,
  variant_id       UUID NOT NULL,
  on_hand_qty      INTEGER NOT NULL DEFAULT 0,
  total_value_base value6  NOT NULL DEFAULT 0,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, branch_id, variant_id),
  CONSTRAINT chk_vcp_qty_nonneg CHECK (on_hand_qty >= 0),
  CONSTRAINT chk_vcp_val_nonneg CHECK (total_value_base >= 0),
  CONSTRAINT chk_vcp_zero_val   CHECK (on_hand_qty <> 0 OR total_value_base = 0),
  FOREIGN KEY (business_id, branch_id)  REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id)
);

-- ============================================================
-- INVENTORY LEDGER  (append-only; no cost columns => readable by all members)
-- ============================================================
CREATE TABLE inventory_movements (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     UUID NOT NULL REFERENCES businesses(id),
  branch_id       UUID NOT NULL,
  variant_id      UUID NOT NULL,
  bucket          inventory_bucket NOT NULL,
  quantity        INTEGER NOT NULL CHECK (quantity <> 0),   -- signed
  reason          movement_reason NOT NULL,
  reference_type  TEXT NOT NULL,   -- goods_receipt_item | sale_item | return_item | transfer_line | adjustment | state_change | write_off | sale_void
  reference_id    UUID NOT NULL,
  note            TEXT,
  created_by      UUID REFERENCES profiles(id),
  occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (business_id, branch_id)  REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id)
);

-- Cost side of each ledger row (manager+ only).
CREATE TABLE inventory_movement_costs (
  movement_id       UUID PRIMARY KEY REFERENCES inventory_movements(id),
  business_id       UUID NOT NULL REFERENCES businesses(id),
  unit_cost_base    cost6  NOT NULL,   -- unit cost used for this movement
  value_delta_base  value6 NOT NULL    -- exact signed pool change (0 for state changes)
);

-- ============================================================
-- TRANSFER-HELD INVENTORY  (in transit; not in any branch bucket)
-- ============================================================
CREATE TABLE stock_transfers (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  from_branch_id   UUID NOT NULL,
  to_branch_id     UUID NOT NULL,
  transfer_number  TEXT NOT NULL,
  status           transfer_status NOT NULL DEFAULT 'draft',
  note             TEXT,
  shipped_by       UUID REFERENCES profiles(id),
  shipped_at       TIMESTAMPTZ,
  received_by      UUID REFERENCES profiles(id),
  received_at      TIMESTAMPTZ,
  created_by       UUID REFERENCES profiles(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, transfer_number),
  UNIQUE (business_id, id),
  CHECK (from_branch_id <> to_branch_id),
  FOREIGN KEY (business_id, from_branch_id) REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, to_branch_id)   REFERENCES branches (business_id, id)
);

CREATE TABLE stock_transfer_lines (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       UUID NOT NULL REFERENCES businesses(id),   -- trigger-populated
  transfer_id       UUID NOT NULL,
  variant_id        UUID NOT NULL,
  quantity_sent     INTEGER NOT NULL CHECK (quantity_sent > 0),
  quantity_received INTEGER CHECK (quantity_received IS NULL OR quantity_received = quantity_sent), -- V1: full receipt only
  note              TEXT,
  UNIQUE (transfer_id, variant_id),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, transfer_id) REFERENCES stock_transfers (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, variant_id)  REFERENCES product_variants (business_id, id)
);

CREATE TABLE transfer_held_inventory (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id               UUID NOT NULL REFERENCES businesses(id),
  transfer_id               UUID NOT NULL,
  transfer_line_id          UUID NOT NULL,
  from_branch_id            UUID NOT NULL,
  to_branch_id              UUID NOT NULL,
  variant_id                UUID NOT NULL,
  quantity_held             INTEGER NOT NULL CHECK (quantity_held > 0),
  carried_total_value_base  value6  NOT NULL CHECK (carried_total_value_base >= 0), -- exact value removed from source pool
  shipped_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  received_at               TIMESTAMPTZ,
  UNIQUE (transfer_line_id),
  FOREIGN KEY (business_id, transfer_id)      REFERENCES stock_transfers (business_id, id),
  FOREIGN KEY (business_id, transfer_line_id) REFERENCES stock_transfer_lines (business_id, id),
  FOREIGN KEY (business_id, from_branch_id)   REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, to_branch_id)     REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, variant_id)       REFERENCES product_variants (business_id, id)
);

-- ============================================================
-- DOCUMENT SEQUENCES
-- ============================================================
CREATE TABLE document_sequences (
  business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  prefix       TEXT NOT NULL,
  year         INTEGER NOT NULL,
  last_value   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (business_id, prefix, year)
);

-- ============================================================
-- INVENTORY ADJUSTMENTS  (manager+; each row = one posted adjustment)
-- ============================================================
CREATE TABLE inventory_adjustments (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  branch_id        UUID NOT NULL,
  variant_id       UUID NOT NULL,
  bucket           inventory_bucket NOT NULL,
  quantity_delta   INTEGER NOT NULL CHECK (quantity_delta <> 0),
  reason           TEXT NOT NULL CHECK (length(trim(reason)) >= 3),
  cost_source      adjustment_cost_source NOT NULL,
  unit_cost_base   cost6  NOT NULL,
  value_delta_base value6 NOT NULL,
  posted_by        UUID REFERENCES profiles(id),
  posted_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (business_id, branch_id)  REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id)
);

-- ============================================================
-- INVENTORY COUNTS  (draft working documents; posting = adjustments RPC)
-- ============================================================
CREATE TABLE inventory_counts (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id    UUID NOT NULL REFERENCES businesses(id),
  branch_id      UUID NOT NULL,
  count_number   TEXT NOT NULL,
  note           TEXT,
  status         inventory_count_status NOT NULL DEFAULT 'draft',
  started_by     UUID REFERENCES profiles(id),
  completed_by   UUID REFERENCES profiles(id),
  completed_at   TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, count_number),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, branch_id) REFERENCES branches (business_id, id)
);

CREATE TABLE inventory_count_lines (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id), -- trigger-populated
  inventory_count_id  UUID NOT NULL,
  variant_id          UUID NOT NULL,
  bucket              inventory_bucket NOT NULL DEFAULT 'sellable',
  system_quantity     INTEGER NOT NULL,
  counted_quantity    INTEGER,
  note                TEXT,
  UNIQUE (inventory_count_id, variant_id, bucket),
  FOREIGN KEY (business_id, inventory_count_id) REFERENCES inventory_counts (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, variant_id)         REFERENCES product_variants (business_id, id)
);

-- ============================================================
-- CUSTOMERS
-- ============================================================
CREATE TABLE customers (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  full_name        TEXT,
  phone            TEXT NOT NULL,
  whatsapp         TEXT,
  instagram        TEXT,
  email            TEXT,
  birth_date       DATE,
  notes            TEXT,
  is_active        BOOLEAN NOT NULL DEFAULT true,
  -- denormalised caches maintained by sale / void RPCs (not authoritative)
  total_spent      money2 NOT NULL DEFAULT 0,
  order_count      INTEGER NOT NULL DEFAULT 0,
  last_purchase_at TIMESTAMPTZ,
  created_by       UUID REFERENCES profiles(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, phone),
  UNIQUE (business_id, id)
);

-- ============================================================
-- RESERVATIONS  (RPC-written; affect AVAILABLE, not ON_HAND)
-- ============================================================
CREATE TABLE reservations (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id          UUID NOT NULL REFERENCES businesses(id),
  branch_id            UUID NOT NULL,
  reservation_number   TEXT NOT NULL,
  customer_id          UUID,
  hold_name            TEXT,
  contact_phone        TEXT,
  contact_instagram    TEXT,
  source               TEXT,   -- in_store | instagram_dm | whatsapp | phone
  status               reservation_status NOT NULL DEFAULT 'active',
  expires_at           TIMESTAMPTZ NOT NULL,   -- explicit per reservation; no default
  note                 TEXT,
  converted_to_sale_id UUID,   -- FK added after sales
  created_by           UUID REFERENCES profiles(id),
  cancelled_by         UUID REFERENCES profiles(id),
  cancelled_at         TIMESTAMPTZ,
  cancel_reason        TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, reservation_number),
  UNIQUE (business_id, id),
  CONSTRAINT chk_res_identity CHECK (customer_id IS NOT NULL OR length(trim(COALESCE(hold_name,''))) > 0),
  FOREIGN KEY (business_id, branch_id)   REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, customer_id) REFERENCES customers (business_id, id)
);

CREATE TABLE reservation_items (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id    UUID NOT NULL REFERENCES businesses(id), -- trigger-populated
  reservation_id UUID NOT NULL,
  variant_id     UUID NOT NULL,
  quantity       INTEGER NOT NULL CHECK (quantity > 0),
  UNIQUE (reservation_id, variant_id),
  FOREIGN KEY (business_id, reservation_id) REFERENCES reservations (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, variant_id)     REFERENCES product_variants (business_id, id)
);

-- ============================================================
-- CASH REGISTERS / SESSIONS / MOVEMENTS
-- ============================================================
CREATE TABLE cash_registers (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  UUID NOT NULL REFERENCES businesses(id),
  branch_id    UUID NOT NULL,
  name         TEXT NOT NULL,
  is_active    BOOLEAN NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, name),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, branch_id) REFERENCES branches (business_id, id)
);

CREATE TABLE register_sessions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  branch_id        UUID NOT NULL,
  cash_register_id UUID NOT NULL,
  session_number   TEXT NOT NULL,
  status           register_session_status NOT NULL DEFAULT 'open',
  opened_by        UUID NOT NULL REFERENCES profiles(id),
  opened_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  closed_by        UUID REFERENCES profiles(id),
  closed_at        TIMESTAMPTZ,
  closing_note     TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, session_number),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, branch_id)        REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, cash_register_id) REFERENCES cash_registers (business_id, id)
);
-- at most ONE open session per register
CREATE UNIQUE INDEX uix_one_open_session_per_register
  ON register_sessions (cash_register_id) WHERE status = 'open';

-- Per-currency physical cash: opening at open, expected/counted/variance at close.
CREATE TABLE register_session_currency_counts (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id          UUID NOT NULL REFERENCES businesses(id),
  register_session_id  UUID NOT NULL,
  currency             iso_currency NOT NULL,
  opening_amount       money2 NOT NULL DEFAULT 0 CHECK (opening_amount >= 0),
  expected_amount      money2,             -- set at close
  counted_amount       money2,             -- set at close
  variance_amount      money2 GENERATED ALWAYS AS (counted_amount - expected_amount) STORED,
  exchange_rate        fx6,                -- for base summary (NULL if no rate that day)
  counted_amount_base  value6 GENERATED ALWAYS AS (counted_amount * exchange_rate) STORED,
  note                 TEXT,
  UNIQUE (register_session_id, currency),
  FOREIGN KEY (business_id, register_session_id) REFERENCES register_sessions (business_id, id) ON DELETE CASCADE
);

-- Physical drawer movements only (cash). Card/bank never appear here.
CREATE TABLE cash_movements (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id          UUID NOT NULL REFERENCES businesses(id),
  register_session_id  UUID NOT NULL,
  movement_type        cash_movement_type NOT NULL,
  currency             iso_currency NOT NULL,
  amount               money2 NOT NULL CHECK (amount <> 0),   -- signed in physical currency
  exchange_rate        fx6 NOT NULL,
  amount_base          value6 GENERATED ALWAYS AS (amount * exchange_rate) STORED,
  reference_type       TEXT,
  reference_id         UUID,
  note                 TEXT,
  created_by           UUID REFERENCES profiles(id),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_cm_sign CHECK (
    (movement_type IN ('sale_cash','cash_in') AND amount > 0) OR
    (movement_type IN ('change_out','void_cash_out','refund_cash_out','cash_out','expense') AND amount < 0)
  ),
  FOREIGN KEY (business_id, register_session_id) REFERENCES register_sessions (business_id, id)
);

-- ============================================================
-- SALES  (no server-side draft; completed on insert; full void only)
-- ============================================================
CREATE TABLE sales (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           UUID NOT NULL REFERENCES businesses(id),
  branch_id             UUID NOT NULL,
  register_session_id   UUID NOT NULL,
  sale_number           TEXT NOT NULL,
  customer_id           UUID,
  status                sale_status NOT NULL DEFAULT 'completed',
  subtotal              money2 NOT NULL,            -- sum(list_price * qty)
  discount_amount       money2 NOT NULL DEFAULT 0,  -- sum(line discounts)
  tax_amount            money2 NOT NULL DEFAULT 0,
  total                 money2 NOT NULL,            -- amount owed by the customer for goods
  credit_applied_base   money2 NOT NULL DEFAULT 0,  -- exchange: merchandise credit from the linked return
  amount_due_base       money2 GENERATED ALWAYS AS (total - credit_applied_base) STORED,
  change_given_base     money2 NOT NULL DEFAULT 0 CHECK (change_given_base >= 0),
  discount_reason       discount_reason,
  sold_by               UUID NOT NULL REFERENCES profiles(id),   -- auth.uid()
  exchange_group_id     UUID,                                    -- J-1 linkage
  client_transaction_id UUID,
  request_fingerprint   TEXT,      -- sha256 of canonical payload
  device_id             TEXT,
  occurred_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  note                  TEXT,
  voided_by             UUID REFERENCES profiles(id),
  voided_at             TIMESTAMPTZ,
  void_reason           TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, sale_number),
  UNIQUE (business_id, client_transaction_id),
  UNIQUE (business_id, id),
  CONSTRAINT chk_sale_void_fields CHECK (
    (status = 'completed' AND voided_at IS NULL) OR
    (status = 'voided' AND voided_at IS NOT NULL AND voided_by IS NOT NULL AND length(trim(COALESCE(void_reason,''))) > 0)
  ),
  FOREIGN KEY (business_id, branch_id)           REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, register_session_id) REFERENCES register_sessions (business_id, id),
  FOREIGN KEY (business_id, customer_id)         REFERENCES customers (business_id, id)
);

CREATE TABLE sale_items (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID NOT NULL REFERENCES businesses(id),
  sale_id            UUID NOT NULL,
  variant_id         UUID NOT NULL,
  quantity           INTEGER NOT NULL CHECK (quantity > 0),
  list_price         money2 NOT NULL,       -- server-resolved
  unit_price_at_sale money2 NOT NULL CHECK (unit_price_at_sale >= 0),
  discount_amount    money2 NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  tax_rate           NUMERIC(5,2) NOT NULL DEFAULT 0,
  tax_amount         money2 NOT NULL DEFAULT 0,
  line_total         money2 GENERATED ALWAYS AS (quantity * unit_price_at_sale) STORED,
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, sale_id)    REFERENCES sales (business_id, id),
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id)
);

-- manager+ only
CREATE TABLE sale_item_costs (
  sale_item_id      UUID PRIMARY KEY REFERENCES sale_items(id),
  business_id       UUID NOT NULL REFERENCES businesses(id),
  unit_cost_at_sale cost6  NOT NULL,   -- PRE-movement MWA (locked pool)
  line_cost_base    value6 NOT NULL    -- exact value removed from pool
);

-- manager+ only
CREATE TABLE sale_costs (
  sale_id          UUID PRIMARY KEY REFERENCES sales(id),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  total_cost_base  value6 NOT NULL
);

CREATE TABLE sale_payments (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES businesses(id),
  sale_id       UUID NOT NULL,
  method        payment_method NOT NULL,
  currency      iso_currency NOT NULL,
  amount        money2 NOT NULL CHECK (amount > 0),   -- in tendered currency
  exchange_rate fx6 NOT NULL,
  CONSTRAINT chk_sp_try_rate CHECK (currency <> 'TRY' OR exchange_rate = 1),
  fx_rate_id    UUID,                                  -- NULL for TRY or authorised override
  fx_overridden BOOLEAN NOT NULL DEFAULT false,
  amount_base   value6 GENERATED ALWAYS AS (amount * exchange_rate) STORED,
  reference_no  TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (business_id, sale_id)    REFERENCES sales (business_id, id),
  FOREIGN KEY (business_id, fx_rate_id) REFERENCES fx_rates (business_id, id)
);

ALTER TABLE reservations ADD CONSTRAINT fk_res_converted_sale
  FOREIGN KEY (business_id, converted_to_sale_id) REFERENCES sales (business_id, id);

-- ============================================================
-- CUSTOMER RETURNS  (completed on insert; merchandise exchange baseline)
-- ============================================================
CREATE TABLE returns (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id),
  branch_id           UUID NOT NULL,
  original_sale_id    UUID NOT NULL,
  return_number       TEXT NOT NULL,
  return_type         return_type NOT NULL,
  customer_id         UUID,
  credit_value_base   money2 NOT NULL DEFAULT 0,   -- merchandise value returned (sum unit_price_at_sale*qty)
  refund_amount_base  money2 NOT NULL DEFAULT 0,   -- money actually refunded (0 for exchange)
  refund_method       payment_method,
  exchange_group_id   UUID,                        -- J-1
  replacement_sale_id UUID,                        -- J-1
  reason              TEXT,
  note                TEXT,
  processed_by        UUID NOT NULL REFERENCES profiles(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, return_number),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, branch_id)           REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, original_sale_id)    REFERENCES sales (business_id, id),
  -- exchange inserts the return BEFORE the replacement sale in the same transaction
  FOREIGN KEY (business_id, replacement_sale_id) REFERENCES sales (business_id, id) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (business_id, customer_id)         REFERENCES customers (business_id, id)
);

-- No cost column: cost truth is sale_item_costs (manager+).
CREATE TABLE return_items (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID NOT NULL REFERENCES businesses(id),
  return_id          UUID NOT NULL,
  sale_item_id       UUID NOT NULL,
  variant_id         UUID NOT NULL,   -- copied from sale_item by RPC
  quantity           INTEGER NOT NULL CHECK (quantity > 0),
  disposition        inventory_bucket NOT NULL DEFAULT 'quarantine',
  unit_price_at_sale money2 NOT NULL,
  reason             TEXT,
  FOREIGN KEY (business_id, return_id)    REFERENCES returns (business_id, id),
  FOREIGN KEY (business_id, sale_item_id) REFERENCES sale_items (business_id, id),
  FOREIGN KEY (business_id, variant_id)   REFERENCES product_variants (business_id, id)
);

-- ============================================================
-- SUPPLIER RETURNS  (J-5: schema kept, posting DEFERRED / NOT IMPLEMENTED)
-- ============================================================
CREATE TABLE supplier_returns (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  branch_id        UUID NOT NULL,
  supplier_id      UUID NOT NULL,
  goods_receipt_id UUID,
  return_number    TEXT NOT NULL,
  reason           TEXT,
  note             TEXT,
  created_by       UUID REFERENCES profiles(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, return_number),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, branch_id)        REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, supplier_id)      REFERENCES suppliers (business_id, id),
  FOREIGN KEY (business_id, goods_receipt_id) REFERENCES goods_receipts (business_id, id)
);

CREATE TABLE supplier_return_items (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           UUID NOT NULL REFERENCES businesses(id),
  supplier_return_id    UUID NOT NULL,
  variant_id            UUID NOT NULL,
  goods_receipt_item_id UUID,
  quantity              INTEGER NOT NULL CHECK (quantity > 0),
  from_bucket           inventory_bucket NOT NULL DEFAULT 'sellable',
  -- accounting (supplier credit) and inventory value are different facts (ADR):
  credit_unit_original  NUMERIC(14,2),
  credit_currency       iso_currency,
  FOREIGN KEY (business_id, supplier_return_id) REFERENCES supplier_returns (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, variant_id)         REFERENCES product_variants (business_id, id)
);

-- ============================================================
-- business_id PROPAGATION (children)
-- ============================================================
CREATE TRIGGER trg_bid_stl BEFORE INSERT OR UPDATE ON stock_transfer_lines
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('stock_transfers','transfer_id');
CREATE TRIGGER trg_bid_icl BEFORE INSERT OR UPDATE ON inventory_count_lines
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('inventory_counts','inventory_count_id');
CREATE TRIGGER trg_bid_ri BEFORE INSERT OR UPDATE ON reservation_items
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('reservations','reservation_id');
CREATE TRIGGER trg_bid_sale_items BEFORE INSERT OR UPDATE ON sale_items
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('sales','sale_id');
CREATE TRIGGER trg_bid_return_items BEFORE INSERT OR UPDATE ON return_items
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('returns','return_id');
CREATE TRIGGER trg_bid_sri BEFORE INSERT OR UPDATE ON supplier_return_items
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('supplier_returns','supplier_return_id');

-- ============================================================
-- IMMUTABILITY TRIGGERS
-- ============================================================
DO $do$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'inventory_movements','inventory_movement_costs','inventory_adjustments',
    'sale_items','sale_item_costs','sale_costs','sale_payments',
    'returns','return_items','cash_movements','supplier_return_items'
  ] LOOP
    EXECUTE format('CREATE TRIGGER trg_imm_%s BEFORE UPDATE OR DELETE ON %I
                    FOR EACH ROW EXECUTE FUNCTION fn_forbid_update_delete()', t, t);
  END LOOP;
END $do$;

-- sales: only the completed -> voided transition (void fields) may change
CREATE OR REPLACE FUNCTION fn_guard_sale_update()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'IMMUTABLE: sales cannot be deleted (id=%)', OLD.id USING ERRCODE='55000';
  END IF;
  IF NOT (OLD.status = 'completed' AND NEW.status = 'voided'
          AND fn_row_comparable(to_jsonb(NEW), TG_TABLE_NAME) - 'status' - 'voided_by' - 'voided_at' - 'void_reason'
            = fn_row_comparable(to_jsonb(OLD), TG_TABLE_NAME) - 'status' - 'voided_by' - 'voided_at' - 'void_reason') THEN
    RAISE EXCEPTION 'IMMUTABLE: completed sale % may only be voided', OLD.id USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_sales BEFORE UPDATE OR DELETE ON sales
  FOR EACH ROW EXECUTE FUNCTION fn_guard_sale_update();

-- transfer_held_inventory: only received_at may be set, once
CREATE OR REPLACE FUNCTION fn_guard_thi_update()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'IMMUTABLE: transfer_held_inventory cannot be deleted' USING ERRCODE='55000';
  END IF;
  IF NOT (OLD.received_at IS NULL AND NEW.received_at IS NOT NULL
          AND fn_row_comparable(to_jsonb(NEW), TG_TABLE_NAME) - 'received_at' = fn_row_comparable(to_jsonb(OLD), TG_TABLE_NAME) - 'received_at') THEN
    RAISE EXCEPTION 'IMMUTABLE: transfer_held_inventory % may only be marked received', OLD.id USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_thi BEFORE UPDATE OR DELETE ON transfer_held_inventory
  FOR EACH ROW EXECUTE FUNCTION fn_guard_thi_update();

-- stock transfers: lines frozen once shipped; header frozen once received
CREATE OR REPLACE FUNCTION fn_guard_transfer_lines()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_status transfer_status;
BEGIN
  SELECT status INTO v_status FROM stock_transfers WHERE id = COALESCE(NEW.transfer_id, OLD.transfer_id);
  IF v_status IN ('shipped','received') THEN
    -- only quantity_received may be set by the receive RPC
    IF TG_OP = 'UPDATE' AND v_status = 'shipped'
       AND fn_row_comparable(to_jsonb(NEW), TG_TABLE_NAME) - 'quantity_received' = fn_row_comparable(to_jsonb(OLD), TG_TABLE_NAME) - 'quantity_received' THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'IMMUTABLE: transfer lines frozen after shipment' USING ERRCODE='55000';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_stl BEFORE INSERT OR UPDATE OR DELETE ON stock_transfer_lines
  FOR EACH ROW EXECUTE FUNCTION fn_guard_transfer_lines();

CREATE OR REPLACE FUNCTION fn_guard_transfer_header()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION 'IMMUTABLE: only draft transfers can be deleted' USING ERRCODE='55000';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status = 'received' THEN
    RAISE EXCEPTION 'IMMUTABLE: received transfer % is frozen', OLD.id USING ERRCODE='55000';
  END IF;
  IF OLD.status = 'shipped' AND NEW.status NOT IN ('shipped','received') THEN
    RAISE EXCEPTION 'INVALID_TRANSITION: shipped transfer cannot go to %', NEW.status USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_st BEFORE UPDATE OR DELETE ON stock_transfers
  FOR EACH ROW EXECUTE FUNCTION fn_guard_transfer_header();

-- register sessions: closed sessions frozen
CREATE OR REPLACE FUNCTION fn_guard_register_session()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'IMMUTABLE: register sessions cannot be deleted' USING ERRCODE='55000';
  END IF;
  IF OLD.status = 'closed' THEN
    RAISE EXCEPTION 'IMMUTABLE: closed register session % is frozen', OLD.id USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_rs BEFORE UPDATE OR DELETE ON register_sessions
  FOR EACH ROW EXECUTE FUNCTION fn_guard_register_session();

DO $do$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['customers','stock_transfers','reservations'] LOOP
    EXECUTE format('CREATE TRIGGER trg_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at()', t);
  END LOOP;
END $do$;

-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX idx_inv_mov_bvb        ON inventory_movements (business_id, branch_id, variant_id, bucket);
CREATE INDEX idx_inv_mov_reference  ON inventory_movements (reference_type, reference_id);
CREATE INDEX idx_inv_mov_occurred   ON inventory_movements (business_id, occurred_at DESC);
CREATE INDEX idx_thi_open           ON transfer_held_inventory (business_id, variant_id) WHERE received_at IS NULL;
CREATE INDEX idx_res_active         ON reservations (business_id, branch_id, expires_at) WHERE status = 'active';
CREATE INDEX idx_ri_variant         ON reservation_items (variant_id);
CREATE INDEX idx_customers_name_trgm ON customers USING gin (full_name gin_trgm_ops);
CREATE INDEX idx_sales_business_date ON sales (business_id, occurred_at DESC);
CREATE INDEX idx_sales_session      ON sales (register_session_id);
CREATE INDEX idx_sales_customer     ON sales (customer_id);
CREATE INDEX idx_sale_items_sale    ON sale_items (sale_id);
CREATE INDEX idx_sale_items_variant ON sale_items (variant_id);
CREATE INDEX idx_sale_payments_sale ON sale_payments (sale_id);
CREATE INDEX idx_return_items_si    ON return_items (sale_item_id);
CREATE INDEX idx_returns_sale       ON returns (original_sale_id);
CREATE INDEX idx_cash_mov_session   ON cash_movements (register_session_id, currency);

-- ============================================================
-- VIEWS (security_invoker: caller's RLS applies)
-- ============================================================
CREATE VIEW v_stock_by_bucket WITH (security_invoker = true) AS
SELECT business_id, branch_id, variant_id, bucket, SUM(quantity)::INTEGER AS quantity
FROM inventory_movements
GROUP BY business_id, branch_id, variant_id, bucket;

-- Active unexpired reservations per variant/branch
CREATE VIEW v_reserved_qty WITH (security_invoker = true) AS
SELECT r.business_id, r.branch_id, ri.variant_id, SUM(ri.quantity)::INTEGER AS reserved_quantity
FROM reservation_items ri
JOIN reservations r ON r.id = ri.reservation_id
WHERE r.status = 'active' AND r.expires_at > now()
GROUP BY r.business_id, r.branch_id, ri.variant_id;

-- AVAILABLE = sellable - active unexpired reservations (display only; RPCs re-check under locks)
CREATE VIEW v_stock_available WITH (security_invoker = true) AS
SELECT s.business_id, s.branch_id, s.variant_id,
       s.quantity AS sellable_quantity,
       COALESCE(r.reserved_quantity, 0) AS reserved_quantity,
       s.quantity - COALESCE(r.reserved_quantity, 0) AS available_quantity
FROM v_stock_by_bucket s
LEFT JOIN v_reserved_qty r USING (business_id, branch_id, variant_id)
WHERE s.bucket = 'sellable';

-- Returned quantity truth per sale item
CREATE VIEW v_sale_item_returned WITH (security_invoker = true) AS
SELECT sale_item_id, SUM(quantity)::INTEGER AS returned_quantity
FROM return_items GROUP BY sale_item_id;

-- Supplier balance (manager+ via RLS on entries): base total and per-currency open amounts
CREATE VIEW v_supplier_balance WITH (security_invoker = true) AS
SELECT s.business_id, s.id AS supplier_id, s.name AS supplier_name,
       COALESCE(SUM(e.amount_base), 0) AS balance_base
FROM suppliers s
LEFT JOIN supplier_account_entries e ON e.supplier_id = s.id
GROUP BY s.business_id, s.id, s.name;

CREATE VIEW v_supplier_balance_by_currency WITH (security_invoker = true) AS
SELECT business_id, supplier_id, currency,
       SUM(amount_original) AS balance_original,
       SUM(amount_base)     AS balance_base
FROM supplier_account_entries
GROUP BY business_id, supplier_id, currency;

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
DO $do$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'variant_cost_pools','inventory_movements','inventory_movement_costs',
    'stock_transfers','stock_transfer_lines','transfer_held_inventory',
    'document_sequences','inventory_adjustments','inventory_counts','inventory_count_lines',
    'customers','reservations','reservation_items',
    'cash_registers','register_sessions','register_session_currency_counts','cash_movements',
    'sales','sale_items','sale_item_costs','sale_costs','sale_payments',
    'returns','return_items','supplier_returns','supplier_return_items'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $do$;

-- Cost-bearing: manager+ SELECT only; never client-writable
CREATE POLICY pol_vcp_select ON variant_cost_pools FOR SELECT USING (fn_is_manager_plus(business_id));
CREATE POLICY pol_imc_select ON inventory_movement_costs FOR SELECT USING (fn_is_manager_plus(business_id));
CREATE POLICY pol_thi_select ON transfer_held_inventory FOR SELECT USING (fn_is_manager_plus(business_id));
CREATE POLICY pol_adj_select ON inventory_adjustments FOR SELECT USING (fn_is_manager_plus(business_id));
CREATE POLICY pol_sic_select ON sale_item_costs FOR SELECT USING (fn_is_manager_plus(business_id));
CREATE POLICY pol_sc_select  ON sale_costs FOR SELECT USING (fn_is_manager_plus(business_id));

-- Ledger & posted documents: members read; RPC-only writes
CREATE POLICY pol_inv_select   ON inventory_movements FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_sales_select ON sales FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_si_select    ON sale_items FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_sp_select    ON sale_payments FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_ret_select   ON returns FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_ri_select    ON return_items FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_cm_select    ON cash_movements FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_rs_select    ON register_sessions FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_rscc_select  ON register_session_currency_counts FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_docseq_select ON document_sequences FOR SELECT USING (fn_is_manager_plus(business_id));

-- Reservations: members read; writes RPC-only (status/expiry cannot be hand-edited)
CREATE POLICY pol_res_select ON reservations FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_resi_select ON reservation_items FOR SELECT USING (fn_is_member(business_id));

-- Customers: members read/write (operational master data)
CREATE POLICY pol_cust_select ON customers FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_cust_insert ON customers FOR INSERT WITH CHECK (fn_is_member(business_id));
CREATE POLICY pol_cust_update ON customers FOR UPDATE USING (fn_is_member(business_id)) WITH CHECK (fn_is_member(business_id));

-- Cash registers: members read; manager+ write
CREATE POLICY pol_cr_select ON cash_registers FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_cr_write  ON cash_registers FOR ALL USING (fn_is_manager_plus(business_id)) WITH CHECK (fn_is_manager_plus(business_id));

-- Transfers: procurement roles read/write DRAFT header+lines; ship/receive via RPC
CREATE POLICY pol_st_select ON stock_transfers FOR SELECT USING (fn_is_procurement(business_id));
CREATE POLICY pol_st_insert ON stock_transfers FOR INSERT WITH CHECK (fn_is_procurement(business_id) AND status = 'draft');
CREATE POLICY pol_st_update ON stock_transfers FOR UPDATE
  USING (fn_is_procurement(business_id) AND status = 'draft')
  WITH CHECK (fn_is_procurement(business_id) AND status IN ('draft','cancelled'));
CREATE POLICY pol_st_delete ON stock_transfers FOR DELETE USING (fn_is_procurement(business_id) AND status = 'draft');
CREATE POLICY pol_stl_select ON stock_transfer_lines FOR SELECT USING (fn_is_procurement(business_id));
CREATE POLICY pol_stl_write  ON stock_transfer_lines FOR ALL USING (fn_is_procurement(business_id)) WITH CHECK (fn_is_procurement(business_id));

-- Inventory counts: procurement roles (draft documents)
CREATE POLICY pol_ic_select ON inventory_counts FOR SELECT USING (fn_is_procurement(business_id));
CREATE POLICY pol_ic_write  ON inventory_counts FOR ALL USING (fn_is_procurement(business_id)) WITH CHECK (fn_is_procurement(business_id));
CREATE POLICY pol_icl_select ON inventory_count_lines FOR SELECT USING (fn_is_procurement(business_id));
CREATE POLICY pol_icl_write  ON inventory_count_lines FOR ALL USING (fn_is_procurement(business_id)) WITH CHECK (fn_is_procurement(business_id));

-- Supplier returns (J-5 DEFERRED): manager+ read only; NO client writes
CREATE POLICY pol_sr_select  ON supplier_returns FOR SELECT USING (fn_is_manager_plus(business_id));
CREATE POLICY pol_sri_select ON supplier_return_items FOR SELECT USING (fn_is_manager_plus(business_id));

-- ============================================================
-- END 003
-- ============================================================
