-- ============================================================
-- ButikOS — Things Like Crop
-- Supabase PostgreSQL Schema  •  Migration 002
-- Rev 3 (2026-09-08) — All CRITICAL 1–10, 17 + HIGH 18–20 applied.
-- ============================================================
-- Changes vs Rev 2:
--   CRITICAL  1: Helper functions moved BEFORE any table / policy
--   CRITICAL  2: fn_post_to_cost_pool: RAISE on negative qty; zero-depletion
--                  uses exact total_value_base; removed last_cost_base;
--                  CHECK constraints on variant_cost_pools
--   CRITICAL  3: fn_post_to_cost_pool returns t_cost_pool_result composite;
--                  unit_cost_used = PRE-movement average
--   CRITICAL  4: variant_cost_pools comment corrected: ALL owned inventory
--   CRITICAL  5: rpc_process_sale fetches authoritative price + tax_rate
--                  from DB; rejects stale expected_list_price
--   CRITICAL  6: AVAILABLE = SELLABLE − active_reservations check;
--                  cost pools locked FOR UPDATE in variant_id order
--   CRITICAL  7: idempotency scoped UNIQUE(business_id, client_transaction_id);
--                  idempotency_key_hash; IDEMPOTENCY_CONFLICT on hash mismatch
--   CRITICAL  8: sale_payments FX columns (currency, exchange_rate,
--                  amount_base GENERATED) live here, NOT in 003
--   CRITICAL  9: sale_item_costs + sale_costs split tables (manager+ RLS);
--                  cost columns removed from sale_items / sales
--   CRITICAL 10: pol_returns_write, pol_return_items_write,
--                  pol_cash_mov_insert REMOVED; writes via RPCs only
--   CRITICAL 17: All SECURITY DEFINER functions: SET search_path;
--                  actor = auth.uid() (p_sold_by removed from rpc_process_sale)
--   HIGH     18: register_session_currency_counts: opening_amount,
--                  expected_amount, variance_amount GENERATED;
--                  rpc_open_register_session + rpc_close_register_session
--   HIGH     19: rpc_reverse_goods_receipt: NOT IMPLEMENTED stub in 004
--   HIGH     20: Internal cost snapshots use NUMERIC(12,4)
-- ============================================================
-- DO NOT EXECUTE: managed migrations only.
-- ============================================================


-- ============================================================
-- COMPOSITE TYPES
-- ============================================================
-- t_cost_pool_result is returned by fn_post_to_cost_pool.
-- unit_cost_used     : PRE-movement moving-weighted average (TRY/unit).
--                      This is the COGS rate for deductions. For inflows
--                      it reflects the average BEFORE the new units blended in.
-- value_delta_base   : signed TRY change applied to the pool.
--                      Negative for outflows. For full depletion this equals
--                      the exact old total_value_base (no rounding leakage).
-- new_on_hand_qty    : pool on_hand_qty after posting.
-- new_total_value_base: pool total_value_base after posting.

CREATE TYPE t_cost_pool_result AS (
  unit_cost_used        NUMERIC,
  value_delta_base      NUMERIC,
  new_on_hand_qty       INTEGER,
  new_total_value_base  NUMERIC
);


-- ============================================================
-- HELPER FUNCTIONS  (CRITICAL 1: MUST precede any table or
-- policy that calls them)
-- ============================================================
-- All are SECURITY DEFINER so they run as the function owner
-- and can read business_members safely from any RLS context.
-- search_path is fixed to prevent search-path hijacking.

CREATE OR REPLACE FUNCTION fn_my_business_ids()
RETURNS UUID[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT ARRAY(
    SELECT business_id FROM business_members
    WHERE user_id = auth.uid() AND is_active = true
  );
$$;

CREATE OR REPLACE FUNCTION fn_is_member(p_business_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM business_members
    WHERE user_id     = auth.uid()
      AND business_id = p_business_id
      AND is_active   = true
  );
$$;

-- Single-role overload
CREATE OR REPLACE FUNCTION fn_has_role(p_business_id UUID, p_role user_role)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM business_members
    WHERE user_id     = auth.uid()
      AND business_id = p_business_id
      AND role        = p_role
      AND is_active   = true
  );
$$;

-- Array overload: fn_has_role(business_id, ARRAY['owner','manager'])
CREATE OR REPLACE FUNCTION fn_has_role(p_business_id UUID, p_roles user_role[])
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM business_members
    WHERE user_id     = auth.uid()
      AND business_id = p_business_id
      AND role        = ANY(p_roles)
      AND is_active   = true
  );
$$;

CREATE OR REPLACE FUNCTION fn_is_manager_plus(p_business_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM business_members
    WHERE user_id     = auth.uid()
      AND business_id = p_business_id
      AND role        IN ('owner', 'manager')
      AND is_active   = true
  );
$$;

-- REVOKE from PUBLIC immediately after creation (CRITICAL 17).
-- fn_post_to_cost_pool and all RPCs are REVOKED after their own definitions.
REVOKE EXECUTE ON FUNCTION fn_my_business_ids()              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fn_is_member(UUID)                FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fn_has_role(UUID, user_role)      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fn_has_role(UUID, user_role[])    FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fn_is_manager_plus(UUID)          FROM PUBLIC;

GRANT EXECUTE ON FUNCTION fn_my_business_ids()               TO authenticated;
GRANT EXECUTE ON FUNCTION fn_is_member(UUID)                 TO authenticated;
GRANT EXECUTE ON FUNCTION fn_has_role(UUID, user_role)       TO authenticated;
GRANT EXECUTE ON FUNCTION fn_has_role(UUID, user_role[])     TO authenticated;
GRANT EXECUTE ON FUNCTION fn_is_manager_plus(UUID)           TO authenticated;


-- ============================================================
-- INVENTORY MOVEMENTS  (Immutable Ledger)
-- ============================================================
-- Every quantity change is a new INSERT. Never UPDATE, never DELETE.
-- Signed quantity convention:
--   positive = units entering a bucket
--   negative = units leaving a bucket
-- A bucket-to-bucket move (sellable → quarantine) = two rows:
--   row 1: quantity = -1, bucket = 'sellable'
--   row 2: quantity = +1, bucket = 'quarantine'
-- Simple aggregation: SUM(quantity) WHERE bucket = 'sellable' AND branch_id = ?
-- SECURITY: direct client INSERT is BLOCKED (no INSERT policy).
-- All writes via SECURITY DEFINER posting RPCs.

CREATE TABLE inventory_movements (
  id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id        UUID NOT NULL REFERENCES businesses(id),
  branch_id          UUID NOT NULL REFERENCES branches(id),
  variant_id         UUID NOT NULL REFERENCES product_variants(id),
  bucket             inventory_bucket NOT NULL,
  quantity           INTEGER NOT NULL CHECK (quantity <> 0),
  reason             movement_reason NOT NULL,
  reference_id       UUID,
  reference_type     TEXT,   -- 'goods_receipt_item'|'sale_item'|'return_item'|
                             -- 'transfer_line'|'inventory_count_line'
  -- Cost snapshot (TRY) at moment of movement: the PRE-movement unit avg.
  -- HIGH 20: NUMERIC(12,4) for internal cost precision.
  unit_cost_snapshot NUMERIC(12,4),
  note               TEXT,
  created_by         UUID REFERENCES profiles(id),
  occurred_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- Idempotency key from client device (scoped to table, no tenant scope needed)
  client_id          UUID UNIQUE
);


-- ============================================================
-- VARIANT COST POOLS
-- ============================================================
-- Branch-scoped moving-weighted-average (MWA) cost state.
-- Represents ALL owned inventory regardless of bucket:
--   SELLABLE + QUARANTINE + DAMAGED all contribute to on_hand_qty.
-- Source of truth: on_hand_qty + total_value_base (both in TRY).
-- average_cost_base = total_value_base / on_hand_qty (derived; never stored).
--
-- CRITICAL 2: CHECK constraints prevent invalid states at the DB level.
--   on_hand_qty >= 0: pool can never go negative (enforced also by fn_post_to_cost_pool).
--   total_value_base >= 0: cost pool value is never negative.
--   zero-qty invariant: if on_hand_qty = 0 then total_value_base must = 0.
--
-- Direct client writes are BLOCKED. Use fn_post_to_cost_pool() SECURITY DEFINER.
-- Only manager+ may SELECT (cost data is PostgreSQL-restricted from sales_staff).

CREATE TABLE variant_cost_pools (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  branch_id        UUID NOT NULL REFERENCES branches(id),
  variant_id       UUID NOT NULL REFERENCES product_variants(id),
  on_hand_qty      INTEGER      NOT NULL DEFAULT 0,
  total_value_base NUMERIC(14,4) NOT NULL DEFAULT 0,
  updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, branch_id, variant_id),
  -- CRITICAL 2: structural invariants enforced at the DB level
  CONSTRAINT chk_vcp_qty_nonneg   CHECK (on_hand_qty >= 0),
  CONSTRAINT chk_vcp_val_nonneg   CHECK (total_value_base >= 0),
  CONSTRAINT chk_vcp_zero_val     CHECK (on_hand_qty <> 0 OR total_value_base = 0)
);

-- Only manager+ can read cost pools (PostgreSQL enforces; no app-level filtering)
ALTER TABLE variant_cost_pools ENABLE ROW LEVEL SECURITY;

CREATE POLICY "vcp_select_manager" ON variant_cost_pools
  FOR SELECT USING (fn_is_manager_plus(business_id));

-- No INSERT/UPDATE/DELETE policies: only SECURITY DEFINER functions may write.


-- ============================================================
-- TRANSFER HELD INVENTORY
-- ============================================================
-- Models stock floating between branches during a transfer.
-- Created by rpc_ship_transfer; cleared by rpc_receive_transfer.
-- NOT a branch inventory bucket; not visible in v_stock_by_bucket.
-- One row per stock_transfer_line while transfer.status = 'shipped'.
--
-- CRITICAL 12 (Rev 3): carried_total_value_base replaces unit_cost_base.
-- The shipping RPC calls fn_post_to_cost_pool first, which returns the
-- exact TRY value removed from the source pool (value_delta_base).
-- This exact value is stored here and transferred to the destination
-- pool on receipt — no rounding from qty × unit_cost multiplication.
-- V1: no partial receipt. quantity_received must equal quantity or RAISE.

CREATE TABLE transfer_held_inventory (
  id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id             UUID NOT NULL REFERENCES businesses(id),
  stock_transfer_id       UUID NOT NULL,  -- FK added after stock_transfers exists
  from_branch_id          UUID NOT NULL REFERENCES branches(id),
  to_branch_id            UUID NOT NULL REFERENCES branches(id),
  variant_id              UUID NOT NULL REFERENCES product_variants(id),
  quantity                INTEGER NOT NULL CHECK (quantity > 0),
  -- TRY value exactly as removed from source cost pool (fn_post_to_cost_pool.value_delta_base)
  carried_total_value_base NUMERIC(14,4) NOT NULL DEFAULT 0,
  shipped_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  received_at             TIMESTAMPTZ,
  UNIQUE (stock_transfer_id, variant_id)
);

ALTER TABLE transfer_held_inventory ENABLE ROW LEVEL SECURITY;

CREATE POLICY "thi_select" ON transfer_held_inventory
  FOR SELECT USING (fn_is_member(business_id));
-- No client write policies; SECURITY DEFINER RPCs only.


-- ============================================================
-- DOCUMENT SEQUENCES  (Race-safe sequential numbering)
-- ============================================================

CREATE TABLE document_sequences (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  prefix       TEXT NOT NULL,
  year         INTEGER NOT NULL,
  last_value   INTEGER NOT NULL DEFAULT 0,
  UNIQUE (business_id, prefix, year)
);

ALTER TABLE document_sequences ENABLE ROW LEVEL SECURITY;

CREATE POLICY "docseq_select" ON document_sequences
  FOR SELECT USING (fn_is_member(business_id));
-- Writes via fn_next_sequence (SECURITY DEFINER) only.


-- ============================================================
-- INVENTORY COUNTS  (Sayım)
-- ============================================================

CREATE TABLE inventory_counts (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id    UUID NOT NULL REFERENCES businesses(id),
  branch_id      UUID NOT NULL REFERENCES branches(id),
  count_number   TEXT NOT NULL,
  note           TEXT,
  status         inventory_count_status NOT NULL DEFAULT 'draft',
  started_by     UUID REFERENCES profiles(id),
  started_at     TIMESTAMPTZ,
  completed_by   UUID REFERENCES profiles(id),
  completed_at   TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, count_number)
);

CREATE TABLE inventory_count_lines (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  inventory_count_id  UUID NOT NULL REFERENCES inventory_counts(id) ON DELETE CASCADE,
  variant_id          UUID NOT NULL REFERENCES product_variants(id),
  bucket              inventory_bucket NOT NULL DEFAULT 'sellable',
  system_quantity     INTEGER NOT NULL,
  counted_quantity    INTEGER,
  note                TEXT,
  UNIQUE (inventory_count_id, variant_id, bucket)
);


-- ============================================================
-- STOCK TRANSFERS  (Şubeler arası — iki aşamalı)
-- ============================================================

CREATE TABLE stock_transfers (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  from_branch_id   UUID NOT NULL REFERENCES branches(id),
  to_branch_id     UUID NOT NULL REFERENCES branches(id),
  transfer_number  TEXT NOT NULL,
  status           transfer_status NOT NULL DEFAULT 'draft',
  note             TEXT,
  shipped_by       UUID REFERENCES profiles(id),
  shipped_at       TIMESTAMPTZ,
  received_by      UUID REFERENCES profiles(id),
  received_at      TIMESTAMPTZ,
  created_by       UUID REFERENCES profiles(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, transfer_number),
  CHECK (from_branch_id <> to_branch_id)
);

CREATE TABLE stock_transfer_lines (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  transfer_id       UUID NOT NULL REFERENCES stock_transfers(id) ON DELETE CASCADE,
  variant_id        UUID NOT NULL REFERENCES product_variants(id),
  quantity_sent     INTEGER NOT NULL CHECK (quantity_sent > 0),
  -- V1: no partial receipt. quantity_received must equal quantity_sent.
  -- rpc_receive_transfer will RAISE if any line has quantity_received < quantity_sent.
  quantity_received INTEGER,
  note              TEXT
);

-- Resolve deferred FK from transfer_held_inventory
ALTER TABLE transfer_held_inventory
  ADD CONSTRAINT fk_thi_stock_transfer
  FOREIGN KEY (stock_transfer_id) REFERENCES stock_transfers(id);


-- ============================================================
-- RESERVATIONS
-- ============================================================

CREATE TABLE reservations (
  id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id          UUID NOT NULL REFERENCES businesses(id),
  branch_id            UUID NOT NULL REFERENCES branches(id),
  reservation_number   TEXT NOT NULL,
  customer_id          UUID,          -- FK added after customers
  customer_name        TEXT,
  customer_phone       TEXT,
  source               TEXT,          -- 'in_store'|'instagram_dm'|'whatsapp'|'phone'
  status               reservation_status NOT NULL DEFAULT 'active',
  -- REQUIRED: set explicitly per reservation (no default; duration varies per customer)
  expires_at           TIMESTAMPTZ NOT NULL,
  note                 TEXT,
  converted_to_sale_id UUID,          -- FK added after sales
  created_by           UUID REFERENCES profiles(id),
  cancelled_by         UUID REFERENCES profiles(id),
  cancelled_at         TIMESTAMPTZ,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, reservation_number)
);

CREATE TABLE reservation_items (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  reservation_id UUID NOT NULL REFERENCES reservations(id) ON DELETE CASCADE,
  variant_id     UUID NOT NULL REFERENCES product_variants(id),
  quantity       INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0)
);


-- ============================================================
-- CUSTOMERS
-- ============================================================

CREATE TABLE customers (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id      UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  full_name        TEXT,
  phone            TEXT NOT NULL,
  whatsapp         TEXT,
  instagram        TEXT,
  email            TEXT,
  birth_date       DATE,
  notes            TEXT,
  is_active        BOOLEAN NOT NULL DEFAULT true,
  -- Denormalized cache: updated by rpc_process_sale / rpc_process_return
  total_spent      NUMERIC(12,2) NOT NULL DEFAULT 0,
  order_count      INTEGER NOT NULL DEFAULT 0,
  last_purchase_at TIMESTAMPTZ,
  created_by       UUID REFERENCES profiles(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, phone)
);

-- Resolve deferred FK from reservations
ALTER TABLE reservations
  ADD CONSTRAINT fk_reservations_customer
  FOREIGN KEY (customer_id) REFERENCES customers(id);


-- ============================================================
-- CASH REGISTERS
-- ============================================================

CREATE TABLE cash_registers (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id  UUID NOT NULL REFERENCES businesses(id),
  branch_id    UUID NOT NULL REFERENCES branches(id),
  name         TEXT NOT NULL,
  is_active    BOOLEAN NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (branch_id, name)
);

-- One session per working day. Open at start, close at end.
-- Partial unique index below prevents two OPEN sessions per register.
CREATE TABLE register_sessions (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  cash_register_id UUID NOT NULL REFERENCES cash_registers(id),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  branch_id        UUID NOT NULL REFERENCES branches(id),
  session_number   TEXT NOT NULL,
  status           register_session_status NOT NULL DEFAULT 'open',
  opened_by        UUID NOT NULL REFERENCES profiles(id),
  opened_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  opening_cash     NUMERIC(12,2) NOT NULL DEFAULT 0,  -- TRY cash in drawer at open
  closed_by        UUID REFERENCES profiles(id),
  closed_at        TIMESTAMPTZ,
  closing_note     TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, session_number)
);

-- Exactly one open session per cash register at a time
CREATE UNIQUE INDEX uix_one_open_session_per_register
  ON register_sessions (cash_register_id)
  WHERE status = 'open';

-- Every cash-flow event inside a session
CREATE TABLE cash_movements (
  id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  register_session_id  UUID NOT NULL REFERENCES register_sessions(id),
  business_id          UUID NOT NULL REFERENCES businesses(id),
  movement_type        cash_movement_type NOT NULL,
  amount               NUMERIC(12,2) NOT NULL CHECK (amount <> 0),
  -- Currency of this movement (TRY by default; FX for foreign-currency cash receipts)
  currency             TEXT NOT NULL DEFAULT 'TRY',
  exchange_rate        NUMERIC(12,6) NOT NULL DEFAULT 1,
  amount_base          NUMERIC(12,4) GENERATED ALWAYS AS (amount * exchange_rate) STORED,
  reference_id         UUID,
  reference_type       TEXT,
  note                 TEXT,
  created_by           UUID REFERENCES profiles(id),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Per-currency physical cash count at session close.
-- HIGH 18: expanded with opening_amount + expected_amount + variance_amount GENERATED.
-- Rows are created by rpc_close_register_session; never by direct client INSERT.
CREATE TABLE register_session_currency_counts (
  id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  register_session_id  UUID NOT NULL REFERENCES register_sessions(id) ON DELETE CASCADE,
  business_id          UUID NOT NULL REFERENCES businesses(id),
  currency             TEXT NOT NULL,
  -- Amount in this currency present in the drawer when the session was opened
  opening_amount       NUMERIC(12,2) NOT NULL DEFAULT 0,
  -- System-calculated expected amount: opening + net cash_movements for this currency
  expected_amount      NUMERIC(12,2) NOT NULL,
  -- Physically counted by staff at close
  counted_amount       NUMERIC(12,2) NOT NULL,
  -- Variance: positive = overage, negative = shortage
  variance_amount      NUMERIC(12,2) GENERATED ALWAYS AS
                         (counted_amount - expected_amount) STORED,
  -- FX rate used to convert this currency to TRY for the session summary
  exchange_rate        NUMERIC(12,6) NOT NULL DEFAULT 1,
  counted_amount_base  NUMERIC(12,4) GENERATED ALWAYS AS
                         (counted_amount * exchange_rate) STORED,
  note                 TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (register_session_id, currency)
);

ALTER TABLE register_session_currency_counts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "rscc_select" ON register_session_currency_counts
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM register_sessions rs
      WHERE rs.id = register_session_id
        AND fn_is_member(rs.business_id)
    )
  );
-- Writes via rpc_close_register_session (SECURITY DEFINER) only.


-- ============================================================
-- SALES
-- ============================================================
-- CRITICAL 9: total_cost REMOVED. Use sale_costs table (manager+ RLS).
-- CRITICAL 7: client_transaction_id scoped to UNIQUE(business_id, ...);
--             idempotency_key_hash detects same-key / different-payload.
-- Sales are immutable once created. Void/refund creates new records.

CREATE TABLE sales (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id           UUID NOT NULL REFERENCES businesses(id),
  branch_id             UUID NOT NULL REFERENCES branches(id),
  register_session_id   UUID REFERENCES register_sessions(id),
  sale_number           TEXT NOT NULL,
  customer_id           UUID REFERENCES customers(id),
  status                sale_status NOT NULL DEFAULT 'completed',
  subtotal              NUMERIC(12,2) NOT NULL,
  discount_amount       NUMERIC(12,2) NOT NULL DEFAULT 0,
  tax_amount            NUMERIC(12,2) NOT NULL DEFAULT 0,
  total                 NUMERIC(12,2) NOT NULL,
  -- total_cost intentionally removed (CRITICAL 9). See sale_costs.
  discount_type         discount_type,
  discount_reason       discount_reason,
  discount_authorized_by UUID REFERENCES profiles(id),
  sold_by               UUID REFERENCES profiles(id),  -- populated by RPC from auth.uid()
  -- CRITICAL 7: scoped per-tenant, not globally unique
  client_transaction_id UUID,
  -- SHA-256 (truncated) of the serialised items+payments payload.
  -- Same key + different hash → IDEMPOTENCY_CONFLICT error.
  idempotency_key_hash  TEXT,
  device_id             TEXT,
  occurred_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, sale_number),
  -- CRITICAL 7: per-tenant idempotency scope
  UNIQUE (business_id, client_transaction_id)
);

-- CRITICAL 9: immutable line items, cost columns removed.
-- unit_cost_at_sale and line_cost now live in sale_item_costs (manager+ RLS).
-- business_id is populated by trigger trg_sale_item_business_id.
-- Cross-tenant FK added at bottom: (business_id, variant_id) → product_variants.
CREATE TABLE sale_items (
  id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sale_id            UUID NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
  -- Trigger-populated from sales.business_id (CRITICAL 16 cross-tenant FK pattern)
  business_id        UUID NOT NULL REFERENCES businesses(id),
  variant_id         UUID NOT NULL REFERENCES product_variants(id),
  quantity           INTEGER NOT NULL CHECK (quantity > 0),
  -- list_price: authoritative price fetched from products/variants by the RPC
  list_price         NUMERIC(12,2) NOT NULL,
  unit_price_at_sale NUMERIC(12,2) NOT NULL,
  discount_amount    NUMERIC(12,2) NOT NULL DEFAULT 0,
  -- tax_rate: fetched from products.tax_rate by the RPC (not client-supplied)
  tax_rate           NUMERIC(5,2)  NOT NULL DEFAULT 0,
  tax_amount         NUMERIC(12,2) NOT NULL DEFAULT 0,
  line_total         NUMERIC(12,2) GENERATED ALWAYS AS
                       (quantity * unit_price_at_sale) STORED
  -- unit_cost_at_sale and line_cost intentionally absent (see sale_item_costs)
);

-- CRITICAL 9: cost data visible only to manager+ (PostgreSQL enforced).
-- HIGH 20: NUMERIC(12,4) for unit_cost precision (avoids TRY 0.01 rounding).
CREATE TABLE sale_item_costs (
  sale_item_id      UUID PRIMARY KEY REFERENCES sale_items(id) ON DELETE CASCADE,
  -- PRE-movement MWA from cost pool (CRITICAL 3)
  unit_cost_at_sale NUMERIC(12,4) NOT NULL,
  -- Exact TRY cost for this line = ABS(fn_post_to_cost_pool.value_delta_base)
  line_cost         NUMERIC(14,4) NOT NULL
);

-- CRITICAL 9: aggregate COGS per sale, manager+ only.
CREATE TABLE sale_costs (
  sale_id    UUID PRIMARY KEY REFERENCES sales(id) ON DELETE CASCADE,
  total_cost NUMERIC(14,4) NOT NULL
);

-- CRITICAL 8: FX columns live here in 002, not added later in 003.
-- Removes the need for ALTER TABLE in migration 003.
-- amount_base: TRY equivalent of this payment leg.
CREATE TABLE sale_payments (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sale_id       UUID NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
  method        payment_method NOT NULL,
  amount        NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  currency      TEXT NOT NULL DEFAULT 'TRY'
                  CONSTRAINT chk_sp_currency CHECK (currency IN ('TRY','GBP','EUR','USD')),
  exchange_rate NUMERIC(12,6) NOT NULL DEFAULT 1
                  CONSTRAINT chk_sp_rate_pos CHECK (exchange_rate > 0),
  CONSTRAINT chk_sp_try_rate CHECK (currency <> 'TRY' OR exchange_rate = 1.000000),
  amount_base   NUMERIC(12,4) GENERATED ALWAYS AS (amount * exchange_rate) STORED,
  reference_no  TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for FX analysis (non-TRY payments only)
CREATE INDEX idx_sale_payments_currency
  ON sale_payments (currency)
  WHERE currency <> 'TRY';

-- Resolve deferred FK from reservations
ALTER TABLE reservations
  ADD CONSTRAINT fk_reservations_sale
  FOREIGN KEY (converted_to_sale_id) REFERENCES sales(id);


-- ============================================================
-- RETURNS  (Müşteri iadesi / Değişim)
-- ============================================================
-- CRITICAL 10: pol_returns_write and pol_return_items_write REMOVED.
-- All return writes go through rpc_process_return (SECURITY DEFINER).
-- refund_per_unit is NOT accepted from client; the RPC reads
-- unit_cost_at_sale from sale_item_costs internally.

CREATE TABLE returns (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id       UUID NOT NULL REFERENCES businesses(id),
  branch_id         UUID NOT NULL REFERENCES branches(id),
  original_sale_id  UUID REFERENCES sales(id),
  return_number     TEXT NOT NULL,
  return_type       return_type NOT NULL,
  customer_id       UUID REFERENCES customers(id),
  exchange_sale_id  UUID REFERENCES sales(id),
  reason            TEXT,
  note              TEXT,
  refund_amount     NUMERIC(12,2) NOT NULL DEFAULT 0,
  refund_method     payment_method,
  processed_by      UUID REFERENCES profiles(id),  -- auth.uid() from RPC
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, return_number)
);

-- All returns default to QUARANTINE bucket (rpc_process_return enforces this).
-- refund_per_unit is set by the RPC from sale_item_costs; not client-supplied.
CREATE TABLE return_items (
  id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  return_id          UUID NOT NULL REFERENCES returns(id) ON DELETE CASCADE,
  sale_item_id       UUID REFERENCES sale_items(id),
  variant_id         UUID NOT NULL REFERENCES product_variants(id),
  quantity           INTEGER NOT NULL CHECK (quantity > 0),
  condition          return_item_condition NOT NULL DEFAULT 'resellable',
  unit_price_at_sale NUMERIC(12,2) NOT NULL,
  -- Cost snapshot from original sale_item_costs (set by RPC; not from client)
  unit_cost_at_sale  NUMERIC(12,4) NOT NULL DEFAULT 0
);


-- ============================================================
-- SUPPLIER RETURNS  (Tedarikçiye iade)
-- ============================================================

CREATE TABLE supplier_returns (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  branch_id        UUID NOT NULL REFERENCES branches(id),
  supplier_id      UUID NOT NULL REFERENCES suppliers(id),
  goods_receipt_id UUID REFERENCES goods_receipts(id),
  return_number    TEXT NOT NULL,
  reason           TEXT,
  note             TEXT,
  total_credit     NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_by       UUID REFERENCES profiles(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, return_number)
);

CREATE TABLE supplier_return_items (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  supplier_return_id  UUID NOT NULL REFERENCES supplier_returns(id) ON DELETE CASCADE,
  variant_id          UUID NOT NULL REFERENCES product_variants(id),
  quantity            INTEGER NOT NULL CHECK (quantity > 0),
  unit_credit         NUMERIC(12,2) NOT NULL,
  from_bucket         inventory_bucket NOT NULL DEFAULT 'sellable'
);


-- ============================================================
-- CROSS-TENANT FK CONSTRAINTS  (CRITICAL 16)
-- ============================================================
-- Applied after all referenced tables exist.
-- These reference the UNIQUE(business_id, id) pairs added in migration 001.
-- They prevent inventory_movements or sale_items from referencing a
-- branch / variant that belongs to a different tenant.

-- inventory_movements: branch must belong to same business
ALTER TABLE inventory_movements
  ADD CONSTRAINT fk_inv_mov_branch_xtenant
  FOREIGN KEY (business_id, branch_id) REFERENCES branches (business_id, id);

-- inventory_movements: variant must belong to same business
ALTER TABLE inventory_movements
  ADD CONSTRAINT fk_inv_mov_variant_xtenant
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id);

-- sale_items: variant must belong to same business as the sale
ALTER TABLE sale_items
  ADD CONSTRAINT fk_sale_item_variant_xtenant
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id);

-- variant_cost_pools: branch must belong to same business
ALTER TABLE variant_cost_pools
  ADD CONSTRAINT fk_vcp_branch_xtenant
  FOREIGN KEY (business_id, branch_id) REFERENCES branches (business_id, id);

-- variant_cost_pools: variant must belong to same business
ALTER TABLE variant_cost_pools
  ADD CONSTRAINT fk_vcp_variant_xtenant
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id);


-- ============================================================
-- CROSS-TENANT TRIGGER: sale_items.business_id
-- ============================================================
-- Populates business_id from parent sales row before INSERT.
-- The RPC also passes p_business_id directly; this trigger acts as
-- a defence-in-depth guard if any other path inserts into sale_items.

CREATE OR REPLACE FUNCTION fn_set_sale_item_business_id()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  SELECT business_id INTO NEW.business_id FROM sales WHERE id = NEW.sale_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_set_sale_item_business_id: sale % not found', NEW.sale_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sale_item_business_id
  BEFORE INSERT ON sale_items
  FOR EACH ROW EXECUTE FUNCTION fn_set_sale_item_business_id();


-- ============================================================
-- INDEXES
-- ============================================================

-- Inventory movements (highest-frequency table)
CREATE INDEX idx_inv_mov_variant_branch   ON inventory_movements (variant_id, branch_id);
CREATE INDEX idx_inv_mov_bucket           ON inventory_movements (business_id, branch_id, bucket);
CREATE INDEX idx_inv_mov_reference        ON inventory_movements (reference_id, reference_type);
CREATE INDEX idx_inv_mov_occurred         ON inventory_movements (business_id, occurred_at DESC);
CREATE INDEX idx_inv_mov_client           ON inventory_movements (client_id) WHERE client_id IS NOT NULL;

-- Cost pools (locked per-sale; composite is the key)
CREATE INDEX idx_vcp_lookup               ON variant_cost_pools (business_id, branch_id, variant_id);

-- Transfer held inventory
CREATE INDEX idx_thi_transfer             ON transfer_held_inventory (stock_transfer_id);
CREATE INDEX idx_thi_variant              ON transfer_held_inventory (business_id, variant_id)
  WHERE received_at IS NULL;

-- Barcodes
CREATE INDEX idx_barcodes_code            ON barcodes (business_id, barcode);
CREATE INDEX idx_barcodes_variant         ON barcodes (variant_id);

-- Products
CREATE INDEX idx_products_business        ON products (business_id, status);
CREATE INDEX idx_products_category        ON products (category_id);
CREATE INDEX idx_products_supplier        ON products (supplier_id);
CREATE INDEX idx_products_name_trgm       ON products USING gin (name gin_trgm_ops);

-- Variants
CREATE INDEX idx_variants_product         ON product_variants (product_id);
CREATE INDEX idx_variants_sku             ON product_variants (sku);

-- Sales
CREATE INDEX idx_sales_business_date      ON sales (business_id, occurred_at DESC);
CREATE INDEX idx_sales_customer           ON sales (customer_id);
CREATE INDEX idx_sales_branch_date        ON sales (branch_id, occurred_at DESC);
CREATE INDEX idx_sales_client_txn         ON sales (business_id, client_transaction_id)
  WHERE client_transaction_id IS NOT NULL;

-- Sale items
CREATE INDEX idx_sale_items_sale          ON sale_items (sale_id);
CREATE INDEX idx_sale_items_variant       ON sale_items (variant_id);

-- Return items (for computing returned_quantity per sale_item)
CREATE INDEX idx_return_items_sale_item   ON return_items (sale_item_id);
CREATE INDEX idx_return_items_variant     ON return_items (variant_id);

-- Reservations
CREATE INDEX idx_reservations_active      ON reservations (business_id, expires_at)
  WHERE status = 'active';
CREATE INDEX idx_reservations_customer    ON reservations (customer_id);

-- Customers
CREATE INDEX idx_customers_phone          ON customers (business_id, phone);
CREATE INDEX idx_customers_name_trgm      ON customers USING gin (full_name gin_trgm_ops);

-- Supplier account
CREATE INDEX idx_sup_account_supplier     ON supplier_account_entries (supplier_id, created_at DESC);

-- Goods receipts
CREATE INDEX idx_gr_supplier              ON goods_receipts (supplier_id);
CREATE INDEX idx_gr_business_date         ON goods_receipts (business_id, received_at DESC);

-- Cash
CREATE INDEX idx_cash_mov_session         ON cash_movements (register_session_id);
CREATE INDEX idx_cash_mov_currency        ON cash_movements (register_session_id, currency);
CREATE INDEX idx_register_session_open    ON register_sessions (cash_register_id)
  WHERE status = 'open';

-- FX rates (defined in 003; index comment kept here for reference)
-- CREATE INDEX idx_fx_rates_lookup ON fx_rates (business_id, rate_date DESC, currency);


-- ============================================================
-- VIEWS  (all WITH security_invoker = true — PostgreSQL 15+)
-- ============================================================

-- Real-time stock per variant / branch / bucket
CREATE VIEW v_stock_by_bucket WITH (security_invoker = true) AS
SELECT
  business_id,
  branch_id,
  variant_id,
  bucket,
  SUM(quantity) AS quantity
FROM inventory_movements
GROUP BY business_id, branch_id, variant_id, bucket;

-- Available stock = sellable bucket minus active (non-expired) reservations
CREATE VIEW v_stock_available WITH (security_invoker = true) AS
SELECT
  s.business_id,
  s.branch_id,
  s.variant_id,
  s.quantity                                AS sellable_quantity,
  COALESCE(r.reserved_qty, 0)              AS reserved_quantity,
  s.quantity - COALESCE(r.reserved_qty, 0) AS available_quantity
FROM v_stock_by_bucket s
LEFT JOIN (
  SELECT
    res.business_id,
    res.branch_id,
    ri.variant_id,
    SUM(ri.quantity) AS reserved_qty
  FROM reservation_items ri
  JOIN reservations res ON res.id = ri.reservation_id
  WHERE res.status  = 'active'
    AND res.expires_at > NOW()
  GROUP BY res.business_id, res.branch_id, ri.variant_id
) r USING (business_id, branch_id, variant_id)
WHERE s.bucket = 'sellable';

-- Supplier running balance — uses amount_base GENERATED column (CRITICAL 14).
-- TRY-equivalent total: SUM(amount_base) WHERE supplier_id = ?
-- Per-currency breakdown: query supplier_account_entries directly.
CREATE VIEW v_supplier_balance WITH (security_invoker = true) AS
SELECT
  s.id           AS supplier_id,
  s.name         AS supplier_name,
  s.business_id,
  s.currency     AS supplier_currency,
  SUM(e.amount_base) AS balance_base   -- TRY equivalent; positive = we owe them
FROM suppliers s
LEFT JOIN supplier_account_entries e ON e.supplier_id = s.id
GROUP BY s.id, s.name, s.business_id, s.currency;

-- sale_items without cost columns — safe for sales_staff role.
-- unit_cost_at_sale and line_cost are in sale_item_costs (manager+ only).
CREATE VIEW v_sale_items_public WITH (security_invoker = true) AS
SELECT
  id,
  sale_id,
  variant_id,
  quantity,
  list_price,
  unit_price_at_sale,
  discount_amount,
  tax_rate,
  tax_amount,
  line_total
  -- unit_cost_at_sale and line_cost intentionally excluded
FROM sale_items;

-- Product sales summary (last 30 days).
-- CRITICAL 9: joins sale_item_costs for gross_profit; manager+ only via RLS.
CREATE VIEW v_product_summary WITH (security_invoker = true) AS
SELECT
  p.id                              AS product_id,
  p.business_id,
  p.name,
  p.default_sale_price,
  p.status,
  COALESCE(SUM(si.quantity) FILTER (
    WHERE s.occurred_at > NOW() - INTERVAL '30 days'), 0) AS units_sold_30d,
  COALESCE(SUM(si.line_total) FILTER (
    WHERE s.occurred_at > NOW() - INTERVAL '30 days'), 0) AS revenue_30d,
  COALESCE(SUM(si.line_total - sic.line_cost) FILTER (
    WHERE s.occurred_at > NOW() - INTERVAL '30 days'), 0) AS gross_profit_30d
FROM products p
LEFT JOIN product_variants pv ON pv.product_id = p.id
LEFT JOIN sale_items si ON si.variant_id = pv.id
LEFT JOIN sale_item_costs sic ON sic.sale_item_id = si.id
LEFT JOIN sales s ON s.id = si.sale_id AND s.status = 'completed'
GROUP BY p.id, p.business_id, p.name, p.default_sale_price, p.status;


-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DO $do$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'businesses','branches','profiles','suppliers',
    'products','product_variants','customers',
    'goods_receipts','stock_transfers','reservations'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_updated_at BEFORE UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at()', t);
  END LOOP;
END;
$do$;


-- Race-safe sequential document numbering using INSERT … ON CONFLICT DO UPDATE.
-- The ON CONFLICT acquires a row-level lock, serialising concurrent calls
-- for the same (business_id, prefix, year). Returns formatted number string.
-- CRITICAL 17: SET search_path; REVOKE from PUBLIC after definition.
CREATE OR REPLACE FUNCTION fn_next_sequence(
  p_business_id UUID,
  p_prefix      TEXT,
  p_year        INT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
  v_year  INT := COALESCE(p_year, EXTRACT(YEAR FROM NOW())::INT);
  v_next  INT;
BEGIN
  INSERT INTO document_sequences (business_id, prefix, year, last_value)
  VALUES (p_business_id, p_prefix, v_year, 1)
  ON CONFLICT (business_id, prefix, year) DO UPDATE
    SET last_value = document_sequences.last_value + 1
  RETURNING last_value INTO v_next;

  RETURN p_prefix || '-' || LPAD(v_next::TEXT, 6, '0');
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_next_sequence(UUID, TEXT, INT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_next_sequence(UUID, TEXT, INT) TO authenticated;


-- ============================================================
-- fn_post_to_cost_pool  (CRITICAL 2, 3, 17)
-- ============================================================
-- Updates branch-scoped MWA cost pool and returns t_cost_pool_result.
--
-- CRITICAL 3: Returns COMPOSITE t_cost_pool_result — NOT a scalar NUMERIC.
--   unit_cost_used   = PRE-movement MWA (the COGS rate for this deduction).
--   value_delta_base = exact TRY value change (negative for outflows).
--                      For full depletion = -(old total_value_base) exactly,
--                      preventing floating-point leakage when pool hits zero.
--
-- CRITICAL 2: RAISE EXCEPTION if post would make on_hand_qty negative.
--   Clamp-to-zero was silently masking oversell bugs. Now the caller gets
--   a hard error with context. The CHECK on variant_cost_pools also guards
--   at the DB level, but the function error fires first with better message.
--
-- p_unit_cost_base = NULL  → use current MWA (for sales / adjustments-out / transfer-out).
-- p_unit_cost_base = value → blend into MWA (for purchases / returns-in / transfer-in).
--
-- Called ONLY from SECURITY DEFINER posting RPCs. Never called directly by clients.
-- CRITICAL 17: SET search_path; no public GRANT.

CREATE OR REPLACE FUNCTION fn_post_to_cost_pool(
  p_business_id    UUID,
  p_branch_id      UUID,
  p_variant_id     UUID,
  p_qty_delta      INTEGER,           -- signed: positive = in, negative = out
  p_unit_cost_base NUMERIC DEFAULT NULL  -- TRY cost/unit; NULL = use current MWA
)
RETURNS t_cost_pool_result
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
  v_on_hand     INTEGER;
  v_total_value NUMERIC;
  v_avg         NUMERIC;
  v_cost        NUMERIC;
  v_new_qty     INTEGER;
  v_new_value   NUMERIC;
  v_delta       NUMERIC;
  v_result      t_cost_pool_result;
BEGIN
  -- Ensure row exists (first receipt for this variant/branch creates it)
  INSERT INTO variant_cost_pools
    (business_id, branch_id, variant_id, on_hand_qty, total_value_base)
  VALUES (p_business_id, p_branch_id, p_variant_id, 0, 0)
  ON CONFLICT (business_id, branch_id, variant_id) DO NOTHING;

  -- Lock the row (serialises concurrent postings for same variant/branch)
  SELECT on_hand_qty, total_value_base
  INTO   v_on_hand, v_total_value
  FROM   variant_cost_pools
  WHERE  business_id = p_business_id
    AND  branch_id   = p_branch_id
    AND  variant_id  = p_variant_id
  FOR UPDATE;

  -- PRE-movement MWA (unit_cost_used is this value per CRITICAL 3)
  v_avg := CASE WHEN v_on_hand > 0
                THEN v_total_value / v_on_hand
                ELSE 0
           END;
  v_result.unit_cost_used := v_avg;

  -- Compute new quantity
  v_new_qty := v_on_hand + p_qty_delta;

  -- CRITICAL 2: negative qty = oversell or accounting error → hard stop
  IF v_new_qty < 0 THEN
    RAISE EXCEPTION
      'cost_pool: negative qty for variant=% branch=% (on_hand=%, delta=%)',
      p_variant_id, p_branch_id, v_on_hand, p_qty_delta;
  END IF;

  -- Unit cost for this posting
  v_cost := COALESCE(p_unit_cost_base, v_avg);

  IF p_qty_delta > 0 THEN
    -- Inflow: blend new units into the pool
    v_delta     := p_qty_delta * v_cost;
    v_new_value := v_total_value + v_delta;
  ELSE
    -- Outflow: deduct at current MWA
    IF v_new_qty = 0 THEN
      -- Full depletion: use exact remaining value (CRITICAL 2/3 — no rounding leak)
      v_delta     := -v_total_value;
      v_new_value := 0;
    ELSE
      v_delta     := p_qty_delta * v_avg;   -- negative
      v_new_value := v_total_value + v_delta;
    END IF;
  END IF;

  UPDATE variant_cost_pools
  SET on_hand_qty      = v_new_qty,
      total_value_base = v_new_value,
      updated_at       = NOW()
  WHERE business_id = p_business_id
    AND branch_id   = p_branch_id
    AND variant_id  = p_variant_id;

  v_result.value_delta_base    := v_delta;
  v_result.new_on_hand_qty     := v_new_qty;
  v_result.new_total_value_base := v_new_value;

  RETURN v_result;
END;
$$;

-- fn_post_to_cost_pool is internal-only: no GRANT to any role.
REVOKE EXECUTE ON FUNCTION
  fn_post_to_cost_pool(UUID, UUID, UUID, INT, NUMERIC)
FROM PUBLIC;


-- ============================================================
-- rpc_process_sale  (CRITICAL 5, 6, 7, 8, 9, 17)
-- ============================================================
-- All-or-nothing atomic sale:
--   sale header + items + inventory movements + cost pool debit
--   + cost snapshots + payments + cash movements + customer stats.
-- Returns the new sale_id (or existing if idempotent replay).
--
-- CRITICAL 5: list_price fetched from products/product_variants by the RPC.
--   Client sends expected_list_price; if stale → PRICE_CHANGED error.
--   tax_rate fetched from products.tax_rate (never from client payload).
--
-- CRITICAL 6: AVAILABLE = SELLABLE − active_reservations checked per item.
--   Cost pool rows locked FOR UPDATE in variant_id order (deterministic)
--   to prevent deadlocks when concurrent sales touch the same variants.
--
-- CRITICAL 7: Idempotency scoped by business_id. Same key + same payload
--   hash → returns existing sale_id. Same key + different hash →
--   IDEMPOTENCY_CONFLICT error.
--
-- CRITICAL 8: Payments include currency + exchange_rate; written to
--   sale_payments. For non-TRY payments, exchange_rate must be provided
--   and validated against today's fx_rates before calling this RPC.
--
-- CRITICAL 9: Cost snapshots written to sale_item_costs + sale_costs.
--   Neither is readable by sales_staff (RLS enforced).
--
-- CRITICAL 17: p_sold_by REMOVED. Actor = auth.uid() always.
--   SET search_path prevents search-path injection.
--
-- p_items JSONB array element schema:
--   {
--     "variant_id":          "<uuid>",
--     "quantity":            <int>,
--     "expected_list_price": <numeric>,   -- staleness check
--     "unit_price":          <numeric>,   -- actual selling price (may be discounted)
--     "discount_amount":     <numeric>    -- optional; computed by RPC if omitted
--   }
--
-- p_payments JSONB array element schema:
--   {
--     "method":        "<cash|card|bank_transfer|other>",
--     "amount":        <numeric>,         -- in the payment currency
--     "currency":      "<TRY|GBP|EUR|USD>",
--     "exchange_rate": <numeric>,         -- 1.0 for TRY; validated FX rate for others
--     "reference_no":  "<string>"         -- optional
--   }

CREATE OR REPLACE FUNCTION rpc_process_sale(
  p_business_id            UUID,
  p_branch_id              UUID,
  p_register_session_id    UUID,
  p_customer_id            UUID,
  p_discount_type          discount_type,
  p_discount_reason        discount_reason,
  p_discount_authorized_by UUID,
  p_client_transaction_id  UUID,
  p_device_id              TEXT,
  p_occurred_at            TIMESTAMPTZ,
  p_items                  JSONB,
  p_payments               JSONB
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor         UUID := auth.uid();
  v_sale_id       UUID;
  v_sale_item_id  UUID;
  v_sale_number   TEXT;
  v_payload_hash  TEXT;
  v_existing_hash TEXT;

  -- Totals
  v_subtotal      NUMERIC := 0;
  v_tax_total     NUMERIC := 0;
  v_cost_total    NUMERIC := 0;
  v_disc_total    NUMERIC := 0;
  v_total         NUMERIC := 0;

  -- Per-item
  v_item          JSONB;
  v_variant_id    UUID;
  v_qty           INTEGER;
  v_exp_price     NUMERIC;
  v_unit_price    NUMERIC;
  v_db_price      NUMERIC;
  v_tax_rate      NUMERIC;
  v_tax_amount    NUMERIC;
  v_disc_amount   NUMERIC;
  v_pool_result   t_cost_pool_result;
  v_line_cost     NUMERIC;

  -- Per-payment
  v_payment       JSONB;
  v_pay_currency  TEXT;
  v_pay_rate      NUMERIC;
  v_pay_amount    NUMERIC;

  -- Stock availability
  v_sellable_qty  INTEGER;
  v_reserved_qty  INTEGER;
  v_available_qty INTEGER;

  v_biz_code      TEXT;
  v_year          INT;
BEGIN
  -- ── Caller must be an active member of this business
  IF NOT fn_is_member(p_business_id) THEN
    RAISE EXCEPTION 'rpc_process_sale: caller is not a member of business %',
      p_business_id;
  END IF;

  -- ── Idempotency check (CRITICAL 7)
  v_payload_hash := md5(
    p_business_id::text || COALESCE(p_client_transaction_id::text,'') ||
    p_items::text || p_payments::text
  );

  IF p_client_transaction_id IS NOT NULL THEN
    SELECT id, idempotency_key_hash
    INTO   v_sale_id, v_existing_hash
    FROM   sales
    WHERE  business_id            = p_business_id
      AND  client_transaction_id  = p_client_transaction_id;

    IF FOUND THEN
      IF v_existing_hash IS DISTINCT FROM v_payload_hash THEN
        RAISE EXCEPTION
          'IDEMPOTENCY_CONFLICT: client_transaction_id % was submitted before with a different payload',
          p_client_transaction_id;
      END IF;
      RETURN v_sale_id;   -- safe replay
    END IF;
  END IF;

  -- ── Lock all cost pool rows in variant_id order (CRITICAL 6: deadlock prevention)
  -- Upsert then lock each pool so a subsequent fn_post_to_cost_pool call in this
  -- same transaction re-uses the already-held lock without blocking.
  PERFORM 1
  FROM (
    SELECT DISTINCT (elem->>'variant_id')::UUID AS vid
    FROM jsonb_array_elements(p_items) elem
    ORDER BY 1
  ) ordered_variants
  JOIN LATERAL (
    INSERT INTO variant_cost_pools
      (business_id, branch_id, variant_id, on_hand_qty, total_value_base)
    VALUES (p_business_id, p_branch_id, ordered_variants.vid, 0, 0)
    ON CONFLICT (business_id, branch_id, variant_id) DO NOTHING
    RETURNING 1
  ) ins ON true
  RIGHT JOIN LATERAL (
    SELECT 1
    FROM variant_cost_pools
    WHERE business_id = p_business_id
      AND branch_id   = p_branch_id
      AND variant_id  = ordered_variants.vid
    FOR UPDATE
  ) lk ON true;

  -- ── Validate stock availability and server-authoritative prices (CRITICAL 5, 6)
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_variant_id := (v_item->>'variant_id')::UUID;
    v_qty        := (v_item->>'quantity')::INTEGER;
    v_exp_price  := (v_item->>'expected_list_price')::NUMERIC;

    -- Server-authoritative list price (CRITICAL 5)
    SELECT COALESCE(pv.sale_price_override, p.default_sale_price),
           p.tax_rate
    INTO   v_db_price, v_tax_rate
    FROM   product_variants pv
    JOIN   products p ON p.id = pv.product_id
    WHERE  pv.id = v_variant_id
      AND  p.business_id = p_business_id;   -- cross-tenant guard

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'rpc_process_sale: variant % not found in business %',
        v_variant_id, p_business_id;
    END IF;

    IF v_exp_price IS NOT NULL
       AND ABS(v_exp_price - v_db_price) > 0.005 THEN
      RAISE EXCEPTION
        'PRICE_CHANGED: variant % expected % but current price is %',
        v_variant_id, v_exp_price, v_db_price;
    END IF;

    -- AVAILABLE = SELLABLE stock − active reservations (CRITICAL 6)
    SELECT COALESCE(SUM(quantity), 0) INTO v_sellable_qty
    FROM   inventory_movements
    WHERE  business_id = p_business_id
      AND  branch_id   = p_branch_id
      AND  variant_id  = v_variant_id
      AND  bucket      = 'sellable';

    SELECT COALESCE(SUM(ri.quantity), 0) INTO v_reserved_qty
    FROM   reservation_items ri
    JOIN   reservations r ON r.id = ri.reservation_id
    WHERE  r.business_id  = p_business_id
      AND  r.branch_id    = p_branch_id
      AND  ri.variant_id  = v_variant_id
      AND  r.status       = 'active'
      AND  r.expires_at   > NOW();

    v_available_qty := v_sellable_qty - v_reserved_qty;

    IF v_available_qty < v_qty THEN
      RAISE EXCEPTION
        'INSUFFICIENT_STOCK: variant % has % available (% sellable − % reserved), requested %',
        v_variant_id, v_available_qty, v_sellable_qty, v_reserved_qty, v_qty;
    END IF;
  END LOOP;

  -- ── Generate sale number (race-safe)
  SELECT code INTO v_biz_code FROM businesses WHERE id = p_business_id;
  v_year        := EXTRACT(YEAR FROM COALESCE(p_occurred_at, NOW()))::INT;
  v_sale_number := fn_next_sequence(p_business_id, v_biz_code || '-' || v_year);

  -- ── Insert sale header with placeholder totals (updated at end)
  INSERT INTO sales (
    business_id, branch_id, register_session_id, sale_number,
    customer_id, sold_by,
    subtotal, discount_amount, tax_amount, total,
    discount_type, discount_reason, discount_authorized_by,
    client_transaction_id, idempotency_key_hash,
    device_id, occurred_at
  ) VALUES (
    p_business_id, p_branch_id, p_register_session_id, v_sale_number,
    p_customer_id, v_actor,
    0, 0, 0, 0,
    p_discount_type, p_discount_reason, p_discount_authorized_by,
    p_client_transaction_id, v_payload_hash,
    p_device_id, COALESCE(p_occurred_at, NOW())
  ) RETURNING id INTO v_sale_id;

  -- ── Process each line: inventory movement + cost pool debit + snapshots
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_variant_id := (v_item->>'variant_id')::UUID;
    v_qty        := (v_item->>'quantity')::INTEGER;
    v_unit_price := (v_item->>'unit_price')::NUMERIC;

    -- Re-fetch authoritative price (already validated in loop above)
    SELECT COALESCE(pv.sale_price_override, p.default_sale_price),
           p.tax_rate
    INTO   v_db_price, v_tax_rate
    FROM   product_variants pv
    JOIN   products p ON p.id = pv.product_id
    WHERE  pv.id = v_variant_id;

    v_disc_amount := (v_db_price - v_unit_price) * v_qty;
    v_tax_amount  := ROUND(v_unit_price * v_qty * (v_tax_rate / 100.0), 2);

    -- Debit cost pool (CRITICAL 3: result carries PRE-movement unit_cost_used)
    v_pool_result := fn_post_to_cost_pool(
      p_business_id, p_branch_id, v_variant_id, -v_qty, NULL
    );
    v_line_cost := ABS(v_pool_result.value_delta_base);

    -- Insert line item (no cost columns — CRITICAL 9)
    INSERT INTO sale_items (
      sale_id, business_id, variant_id, quantity,
      list_price, unit_price_at_sale,
      discount_amount, tax_rate, tax_amount
    ) VALUES (
      v_sale_id, p_business_id, v_variant_id, v_qty,
      v_db_price, v_unit_price,
      v_disc_amount, v_tax_rate, v_tax_amount
    ) RETURNING id INTO v_sale_item_id;

    -- Cost snapshot (manager+ only — CRITICAL 9)
    INSERT INTO sale_item_costs (sale_item_id, unit_cost_at_sale, line_cost)
    VALUES (v_sale_item_id, v_pool_result.unit_cost_used, v_line_cost);

    -- Inventory movement (immutable ledger)
    INSERT INTO inventory_movements (
      business_id, branch_id, variant_id,
      bucket, quantity, reason,
      reference_id, reference_type, unit_cost_snapshot,
      occurred_at, created_by
    ) VALUES (
      p_business_id, p_branch_id, v_variant_id,
      'sellable', -v_qty, 'sale',
      v_sale_item_id, 'sale_item', v_pool_result.unit_cost_used,
      COALESCE(p_occurred_at, NOW()), v_actor
    );

    v_subtotal   := v_subtotal   + v_db_price * v_qty;
    v_disc_total := v_disc_total + v_disc_amount;
    v_tax_total  := v_tax_total  + v_tax_amount;
    v_cost_total := v_cost_total + v_line_cost;
  END LOOP;

  v_total := v_subtotal - v_disc_total + v_tax_total;

  -- ── Update sale header with real totals
  UPDATE sales
  SET subtotal        = v_subtotal,
      discount_amount = v_disc_total,
      tax_amount      = v_tax_total,
      total           = v_total
  WHERE id = v_sale_id;

  -- ── Insert COGS aggregate (CRITICAL 9)
  INSERT INTO sale_costs (sale_id, total_cost)
  VALUES (v_sale_id, v_cost_total);

  -- ── Insert payments + cash movements (CRITICAL 8)
  FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
    v_pay_currency := COALESCE(v_payment->>'currency', 'TRY');
    v_pay_rate     := COALESCE((v_payment->>'exchange_rate')::NUMERIC, 1);
    v_pay_amount   := (v_payment->>'amount')::NUMERIC;

    INSERT INTO sale_payments (
      sale_id, method, amount, currency, exchange_rate, reference_no
    ) VALUES (
      v_sale_id,
      (v_payment->>'method')::payment_method,
      v_pay_amount,
      v_pay_currency,
      v_pay_rate,
      v_payment->>'reference_no'
    );

    IF (v_payment->>'method') = 'cash'
       AND p_register_session_id IS NOT NULL THEN
      INSERT INTO cash_movements (
        register_session_id, business_id, movement_type,
        amount, currency, exchange_rate,
        reference_id, reference_type, created_by
      ) VALUES (
        p_register_session_id, p_business_id, 'sale_cash',
        v_pay_amount, v_pay_currency, v_pay_rate,
        v_sale_id, 'sale', v_actor
      );
    END IF;
  END LOOP;

  -- ── Update customer denormalised stats
  IF p_customer_id IS NOT NULL THEN
    UPDATE customers
    SET total_spent      = total_spent + v_total,
        order_count      = order_count + 1,
        last_purchase_at = COALESCE(p_occurred_at, NOW()),
        updated_at       = NOW()
    WHERE id = p_customer_id;
  END IF;

  RETURN v_sale_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION
  rpc_process_sale(UUID,UUID,UUID,UUID,discount_type,discount_reason,UUID,UUID,TEXT,TIMESTAMPTZ,JSONB,JSONB)
FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION
  rpc_process_sale(UUID,UUID,UUID,UUID,discount_type,discount_reason,UUID,UUID,TEXT,TIMESTAMPTZ,JSONB,JSONB)
TO authenticated;


-- ============================================================
-- rpc_open_register_session  (HIGH 18)
-- ============================================================
-- Opens a new register session. Fails if the register already has an
-- open session (uix_one_open_session_per_register partial unique index).

CREATE OR REPLACE FUNCTION rpc_open_register_session(
  p_cash_register_id UUID,
  p_opening_cash     NUMERIC DEFAULT 0
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor       UUID := auth.uid();
  v_business_id UUID;
  v_branch_id   UUID;
  v_session_id  UUID;
  v_session_num TEXT;
BEGIN
  SELECT cr.business_id, cr.branch_id
  INTO   v_business_id, v_branch_id
  FROM   cash_registers cr
  WHERE  cr.id = p_cash_register_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'rpc_open_register_session: cash register % not found', p_cash_register_id;
  END IF;

  IF NOT fn_is_member(v_business_id) THEN
    RAISE EXCEPTION 'rpc_open_register_session: caller is not a member of business %', v_business_id;
  END IF;

  v_session_num := fn_next_sequence(v_business_id, 'RS');

  INSERT INTO register_sessions (
    cash_register_id, business_id, branch_id, session_number,
    status, opened_by, opening_cash
  ) VALUES (
    p_cash_register_id, v_business_id, v_branch_id, v_session_num,
    'open', v_actor, COALESCE(p_opening_cash, 0)
  ) RETURNING id INTO v_session_id;

  RETURN v_session_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION rpc_open_register_session(UUID, NUMERIC) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rpc_open_register_session(UUID, NUMERIC) TO authenticated;


-- ============================================================
-- rpc_close_register_session  (HIGH 18)
-- ============================================================
-- Closes the session. For each currency in p_currency_counts, the RPC:
--   1. Calculates expected_amount from opening_cash + net cash_movements
--   2. Inserts register_session_currency_counts row
--   3. Updates session to closed
--
-- p_currency_counts JSONB array element schema:
--   {
--     "currency":        "<TRY|GBP|EUR|USD>",
--     "counted_amount":  <numeric>,
--     "exchange_rate":   <numeric>    -- 1.0 for TRY; today's rate for FX
--   }

CREATE OR REPLACE FUNCTION rpc_close_register_session(
  p_register_session_id UUID,
  p_closing_note        TEXT    DEFAULT NULL,
  p_currency_counts     JSONB   DEFAULT '[]'
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor       UUID := auth.uid();
  v_business_id UUID;
  v_opening_cash NUMERIC;
  v_session_status register_session_status;
  v_count       JSONB;
  v_currency    TEXT;
  v_counted     NUMERIC;
  v_rate        NUMERIC;
  v_expected    NUMERIC;
  v_opening_cur NUMERIC;
BEGIN
  SELECT rs.business_id, rs.opening_cash, rs.status
  INTO   v_business_id, v_opening_cash, v_session_status
  FROM   register_sessions rs
  WHERE  rs.id = p_register_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'rpc_close_register_session: session % not found', p_register_session_id;
  END IF;

  IF NOT fn_is_member(v_business_id) THEN
    RAISE EXCEPTION 'rpc_close_register_session: caller is not a member of business %', v_business_id;
  END IF;

  IF v_session_status <> 'open' THEN
    RAISE EXCEPTION 'rpc_close_register_session: session % is already %',
      p_register_session_id, v_session_status;
  END IF;

  -- ── Insert currency counts
  FOR v_count IN SELECT * FROM jsonb_array_elements(p_currency_counts) LOOP
    v_currency := v_count->>'currency';
    v_counted  := (v_count->>'counted_amount')::NUMERIC;
    v_rate     := COALESCE((v_count->>'exchange_rate')::NUMERIC, 1);

    -- Opening amount for this currency (TRY = opening_cash; FX = 0 unless tracked)
    v_opening_cur := CASE WHEN v_currency = 'TRY' THEN v_opening_cash ELSE 0 END;

    -- Expected = opening + net movements in this currency within this session
    SELECT v_opening_cur + COALESCE(SUM(amount), 0)
    INTO   v_expected
    FROM   cash_movements
    WHERE  register_session_id = p_register_session_id
      AND  currency            = v_currency;

    INSERT INTO register_session_currency_counts (
      register_session_id, business_id, currency,
      opening_amount, expected_amount, counted_amount, exchange_rate
    ) VALUES (
      p_register_session_id, v_business_id, v_currency,
      v_opening_cur, v_expected, v_counted, v_rate
    )
    ON CONFLICT (register_session_id, currency) DO UPDATE
      SET opening_amount  = EXCLUDED.opening_amount,
          expected_amount = EXCLUDED.expected_amount,
          counted_amount  = EXCLUDED.counted_amount,
          exchange_rate   = EXCLUDED.exchange_rate;
  END LOOP;

  -- ── Mark session closed
  UPDATE register_sessions
  SET status       = 'closed',
      closed_by    = v_actor,
      closed_at    = NOW(),
      closing_note = p_closing_note
  WHERE id = p_register_session_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION rpc_close_register_session(UUID, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION rpc_close_register_session(UUID, TEXT, JSONB) TO authenticated;


-- ============================================================
-- TRIGGER: Lock confirmed goods receipts
-- ============================================================

CREATE OR REPLACE FUNCTION fn_lock_confirmed_goods_receipt()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'confirmed' THEN
    RAISE EXCEPTION 'Cannot modify a confirmed goods receipt (id: %)', OLD.id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_lock_gr
  BEFORE UPDATE ON goods_receipts
  FOR EACH ROW EXECUTE FUNCTION fn_lock_confirmed_goods_receipt();


-- ============================================================
-- ENABLE ROW LEVEL SECURITY
-- ============================================================

DO $do$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'businesses','branches','profiles','business_members',
    'brands','categories',
    'suppliers','supplier_account_entries','supplier_payments',
    'supplier_payment_allocations',
    'product_options','option_values','products','product_variants',
    'variant_option_values','product_images','product_price_history',
    'barcodes',
    'goods_receipts','goods_receipt_items',
    'inventory_movements','inventory_counts','inventory_count_lines',
    'stock_transfers','stock_transfer_lines',
    'transfer_held_inventory',
    'reservations','reservation_items',
    'customers',
    'cash_registers','register_sessions','cash_movements',
    'sales','sale_items','sale_item_costs','sale_costs','sale_payments',
    'returns','return_items',
    'supplier_returns','supplier_return_items'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END;
$do$;


-- ============================================================
-- ROW LEVEL SECURITY POLICIES
-- ============================================================

-- profiles
CREATE POLICY pol_profiles_select ON profiles FOR SELECT
  USING (id = auth.uid());
CREATE POLICY pol_profiles_update ON profiles FOR UPDATE
  USING (id = auth.uid());

-- businesses
CREATE POLICY pol_businesses_select ON businesses FOR SELECT
  USING (id = ANY(fn_my_business_ids()));

-- branches
CREATE POLICY pol_branches_select ON branches FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_branches_write ON branches FOR ALL
  USING (fn_has_role(business_id, 'owner'));

-- business_members
CREATE POLICY pol_bm_select ON business_members FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_bm_write ON business_members FOR ALL
  USING (fn_has_role(business_id, 'owner'));

-- brands
CREATE POLICY pol_brands_select ON brands FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_brands_write ON brands FOR ALL
  USING (fn_is_manager_plus(business_id));

-- categories
CREATE POLICY pol_categories_select ON categories FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_categories_write ON categories FOR ALL
  USING (fn_is_manager_plus(business_id));

-- product_options / option_values
CREATE POLICY pol_product_options_select ON product_options FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_product_options_write ON product_options FOR ALL
  USING (fn_is_manager_plus(business_id));
CREATE POLICY pol_option_values_select ON option_values FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM product_options po
    WHERE po.id = product_option_id
      AND po.business_id = ANY(fn_my_business_ids())
  ));
CREATE POLICY pol_option_values_write ON option_values FOR ALL
  USING (EXISTS (
    SELECT 1 FROM product_options po
    WHERE po.id = product_option_id
      AND fn_is_manager_plus(po.business_id)
  ));

-- products
CREATE POLICY pol_products_select ON products FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_products_insert ON products FOR INSERT
  WITH CHECK (fn_is_manager_plus(business_id));
CREATE POLICY pol_products_update ON products FOR UPDATE
  USING (fn_is_manager_plus(business_id));

-- product_variants
CREATE POLICY pol_variants_select ON product_variants FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_variants_write ON product_variants FOR ALL
  USING (fn_is_manager_plus(business_id));

-- variant_option_values
CREATE POLICY pol_vov_select ON variant_option_values FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM product_variants pv
    WHERE pv.id = variant_id
      AND pv.business_id = ANY(fn_my_business_ids())
  ));
CREATE POLICY pol_vov_write ON variant_option_values FOR ALL
  USING (EXISTS (
    SELECT 1 FROM product_variants pv
    WHERE pv.id = variant_id
      AND fn_is_manager_plus(pv.business_id)
  ));

-- product_images
CREATE POLICY pol_images_select ON product_images FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM products p
    WHERE p.id = product_id
      AND p.business_id = ANY(fn_my_business_ids())
  ));
CREATE POLICY pol_images_write ON product_images FOR ALL
  USING (EXISTS (
    SELECT 1 FROM products p
    WHERE p.id = product_id
      AND fn_is_manager_plus(p.business_id)
  ));

-- product_price_history
CREATE POLICY pol_pph_select ON product_price_history FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM products p
    WHERE p.id = product_id
      AND fn_is_manager_plus(p.business_id)
  ));
CREATE POLICY pol_pph_insert ON product_price_history FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM products p
    WHERE p.id = product_id
      AND fn_is_manager_plus(p.business_id)
  ));

-- barcodes
CREATE POLICY pol_barcodes_select ON barcodes FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_barcodes_insert ON barcodes FOR INSERT
  WITH CHECK (fn_is_member(business_id));

-- suppliers
CREATE POLICY pol_suppliers_select ON suppliers FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_suppliers_write ON suppliers FOR ALL
  USING (fn_is_manager_plus(business_id));

-- supplier_account_entries: manager+ SELECT only; no client write (posting RPCs only)
CREATE POLICY pol_sup_account_select ON supplier_account_entries FOR SELECT
  USING (fn_is_manager_plus(business_id));

-- supplier_payments: manager+ only
CREATE POLICY pol_sup_payments_select ON supplier_payments FOR SELECT
  USING (fn_is_manager_plus(business_id));

-- supplier_payment_allocations
CREATE POLICY pol_spa_select ON supplier_payment_allocations FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM supplier_payments sp
    WHERE sp.id = supplier_payment_id
      AND fn_is_manager_plus(sp.business_id)
  ));

-- goods_receipts
CREATE POLICY pol_gr_select ON goods_receipts FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_gr_insert ON goods_receipts FOR INSERT
  WITH CHECK (fn_is_member(business_id));
CREATE POLICY pol_gr_update ON goods_receipts FOR UPDATE
  USING (fn_is_member(business_id));

-- goods_receipt_items
CREATE POLICY pol_gri_select ON goods_receipt_items FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_gri_insert ON goods_receipt_items FOR INSERT
  WITH CHECK (business_id = ANY(fn_my_business_ids()));

-- inventory_movements: SELECT for all members; NO client INSERT/UPDATE/DELETE
CREATE POLICY pol_inv_select ON inventory_movements FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));

-- inventory_counts
CREATE POLICY pol_ic_select ON inventory_counts FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_ic_write ON inventory_counts FOR ALL
  USING (fn_is_member(business_id));

-- inventory_count_lines
CREATE POLICY pol_icl_select ON inventory_count_lines FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM inventory_counts ic
    WHERE ic.id = inventory_count_id
      AND fn_is_member(ic.business_id)
  ));
CREATE POLICY pol_icl_write ON inventory_count_lines FOR ALL
  USING (EXISTS (
    SELECT 1 FROM inventory_counts ic
    WHERE ic.id = inventory_count_id
      AND fn_is_member(ic.business_id)
  ));

-- stock_transfers
CREATE POLICY pol_transfers_select ON stock_transfers FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_transfers_write ON stock_transfers FOR ALL
  USING (fn_is_member(business_id));

-- stock_transfer_lines
CREATE POLICY pol_stl_select ON stock_transfer_lines FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM stock_transfers st
    WHERE st.id = transfer_id
      AND fn_is_member(st.business_id)
  ));
CREATE POLICY pol_stl_write ON stock_transfer_lines FOR ALL
  USING (EXISTS (
    SELECT 1 FROM stock_transfers st
    WHERE st.id = transfer_id
      AND fn_is_member(st.business_id)
  ));

-- transfer_held_inventory: SELECT policy defined above; no client write.

-- reservations
CREATE POLICY pol_reservations_select ON reservations FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_reservations_write ON reservations FOR ALL
  USING (fn_is_member(business_id));

-- reservation_items
CREATE POLICY pol_ri_select ON reservation_items FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.id = reservation_id
      AND fn_is_member(r.business_id)
  ));
CREATE POLICY pol_ri_write ON reservation_items FOR ALL
  USING (EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.id = reservation_id
      AND fn_is_member(r.business_id)
  ));

-- customers
CREATE POLICY pol_customers_select ON customers FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_customers_write ON customers FOR ALL
  USING (fn_is_member(business_id));

-- cash_registers
CREATE POLICY pol_registers_select ON cash_registers FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
CREATE POLICY pol_registers_write ON cash_registers FOR ALL
  USING (fn_is_manager_plus(business_id));

-- register_sessions
CREATE POLICY pol_sessions_select ON register_sessions FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
-- No client write: only rpc_open/close_register_session (SECURITY DEFINER).

-- cash_movements: SELECT for all members; NO client INSERT (CRITICAL 10)
CREATE POLICY pol_cash_mov_select ON cash_movements FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
-- pol_cash_mov_insert intentionally absent: all writes via SECURITY DEFINER RPCs.

-- sales: SELECT for all members; INSERT via rpc_process_sale (SD) only
CREATE POLICY pol_sales_select ON sales FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));

-- sale_items: SELECT for all members (cost cols absent; use v_sale_items_public for staff)
CREATE POLICY pol_sale_items_select ON sale_items FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM sales s
    WHERE s.id = sale_id
      AND fn_is_member(s.business_id)
  ));

-- sale_item_costs: CRITICAL 9 — PostgreSQL-enforced; sales_staff cannot access
CREATE POLICY pol_sale_item_costs_select ON sale_item_costs FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM sale_items si
    JOIN sales s ON s.id = si.sale_id
    WHERE si.id = sale_item_id
      AND fn_is_manager_plus(s.business_id)
  ));
-- No INSERT policy: written only by rpc_process_sale (SECURITY DEFINER).

-- sale_costs: CRITICAL 9 — PostgreSQL-enforced; sales_staff cannot access
CREATE POLICY pol_sale_costs_select ON sale_costs FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM sales s
    WHERE s.id = sale_id
      AND fn_is_manager_plus(s.business_id)
  ));
-- No INSERT policy: written only by rpc_process_sale (SECURITY DEFINER).

-- sale_payments
CREATE POLICY pol_sale_payments_select ON sale_payments FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM sales s
    WHERE s.id = sale_id
      AND fn_is_member(s.business_id)
  ));

-- returns: SELECT for all members; NO direct client write (CRITICAL 10)
CREATE POLICY pol_returns_select ON returns FOR SELECT
  USING (business_id = ANY(fn_my_business_ids()));
-- pol_returns_write intentionally absent: all writes via rpc_process_return (SD).

-- return_items: SELECT for all members; NO direct client write (CRITICAL 10)
CREATE POLICY pol_return_items_select ON return_items FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM returns r
    WHERE r.id = return_id
      AND fn_is_member(r.business_id)
  ));
-- pol_return_items_write intentionally absent: all writes via rpc_process_return (SD).

-- supplier_returns: manager+ only
CREATE POLICY pol_sr_select ON supplier_returns FOR SELECT
  USING (fn_is_manager_plus(business_id));
CREATE POLICY pol_sr_write ON supplier_returns FOR ALL
  USING (fn_is_manager_plus(business_id));

-- supplier_return_items
CREATE POLICY pol_sri_select ON supplier_return_items FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM supplier_returns sr
    WHERE sr.id = supplier_return_id
      AND fn_is_manager_plus(sr.business_id)
  ));


-- ============================================================
-- END OF MIGRATION 002
-- ============================================================
-- Summary of what this migration creates:
--   ✓ t_cost_pool_result composite type
--   ✓ Helper functions at TOP (CRITICAL 1): fn_my_business_ids,
--       fn_is_member, fn_has_role (×2), fn_is_manager_plus
--   ✓ inventory_movements (immutable ledger; no client INSERT policy)
--   ✓ variant_cost_pools (CRITICAL 2: CHECK constraints; no last_cost_base)
--   ✓ transfer_held_inventory (CRITICAL 12: carried_total_value_base)
--   ✓ document_sequences + fn_next_sequence
--   ✓ inventory_counts + inventory_count_lines
--   ✓ stock_transfers + stock_transfer_lines
--   ✓ reservations + reservation_items + customers
--   ✓ cash_registers + register_sessions + cash_movements
--   ✓ register_session_currency_counts (HIGH 18: expanded columns + GENERATED)
--   ✓ sales (CRITICAL 7: scoped idempotency; CRITICAL 9: no total_cost)
--   ✓ sale_items (CRITICAL 9: no cost cols; has business_id for cross-tenant FK)
--   ✓ sale_item_costs (CRITICAL 9: manager+ RLS; NUMERIC(12,4) — HIGH 20)
--   ✓ sale_costs (CRITICAL 9: manager+ RLS)
--   ✓ sale_payments (CRITICAL 8: FX cols here; CHECK constraints)
--   ✓ returns + return_items (CRITICAL 10: no client write policies)
--   ✓ supplier_returns + supplier_return_items
--   ✓ Cross-tenant FK constraints (CRITICAL 16): inventory_movements,
--       variant_cost_pools, sale_items
--   ✓ fn_post_to_cost_pool (CRITICAL 2,3,17): RAISES on negative qty;
--       returns t_cost_pool_result; exact full-depletion value; SET search_path
--   ✓ rpc_process_sale (CRITICAL 5,6,7,8,9,17): server-authoritative price,
--       AVAILABLE check, scoped idempotency + hash, FX payments, cost tables,
--       auth.uid() actor, SET search_path
--   ✓ rpc_open_register_session (HIGH 18)
--   ✓ rpc_close_register_session (HIGH 18)
--   ✓ RLS: pol_cash_mov_insert, pol_returns_write, pol_return_items_write
--       intentionally ABSENT (CRITICAL 10)
--   ✓ RLS: sale_item_costs + sale_costs: manager+ SELECT only (CRITICAL 9)
-- ============================================================
-- NOT in this migration:
--   ✗ fx_rates table → migration 003
--   ✗ rpc_confirm_goods_receipt → migration 004
--   ✗ rpc_process_return → migration 004
--   ✗ rpc_ship_transfer / rpc_receive_transfer → migration 004
--   ✗ rpc_reverse_goods_receipt → NOT IMPLEMENTED (see 004 stub)
--   ✗ accounting role → deferred (awaiting pilot confirmation)
-- ============================================================
