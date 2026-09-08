-- ============================================================
-- ButikOS — Things Like Crop
-- Supabase PostgreSQL Schema  •  Migration 001
-- Rev 3 (2026-09-08):
--   CRITICAL 14: supplier_account_entries multi-currency structure
--     - amount_original (signed, invoice currency), amount_base GENERATED
--     - Remove ambiguous amount_foreign column
--   CRITICAL 15: goods_receipt_items cost columns
--     - total_cost_original: GENERATED from qty × unit_cost (invoice currency)
--     - unit_cost_base, total_cost_base: nullable; set by rpc_confirm_goods_receipt
--     - Removed GENERATED ALWAYS AS (unit_cost) which was wrong for FX receipts
--   CRITICAL 16: cross-tenant composite FK pattern
--     - UNIQUE(business_id, id) on all major entity tables
--     - business_id added to product_variants (trigger-populated from products)
--     - business_id added to goods_receipt_items (trigger-populated from goods_receipts)
--     - Cross-tenant FK constraints at bottom of migration
-- ============================================================
-- DO NOT EXECUTE: managed migrations only.
-- ============================================================


-- ============================================================
-- EXTENSIONS
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- fuzzy product/customer search


-- ============================================================
-- ENUMS
-- ============================================================

CREATE TYPE user_role AS ENUM (
  'owner',
  'manager',
  'sales_staff',
  'stock_staff'
);

CREATE TYPE business_status AS ENUM ('active', 'suspended', 'cancelled');
CREATE TYPE branch_status   AS ENUM ('active', 'inactive');
CREATE TYPE supplier_status AS ENUM ('active', 'inactive');
CREATE TYPE product_status  AS ENUM ('active', 'draft', 'archived');
CREATE TYPE variant_status  AS ENUM ('active', 'archived');

-- Physical stock buckets a unit can occupy in a branch.
-- in_transit is NOT a bucket: floating stock between branches
-- is modelled via the transfer_held_inventory table (migration 002).
CREATE TYPE inventory_bucket AS ENUM (
  'sellable',
  'damaged',
  'quarantine'
);

-- Every reason a stock movement can occur (immutable ledger)
CREATE TYPE movement_reason AS ENUM (
  'purchase_receipt',       -- mal kabul
  'sale',                   -- satış
  'return_from_customer',   -- müşteri iadesi (tüm koşullar → önce quarantine)
  'damage_from_return',     -- kullanılmayan; return_from_customer ile birleştirildi
  'exchange_in',            -- değişim: eski ürün geri alındı
  'exchange_out',           -- değişim: yeni ürün verildi
  'return_to_supplier',     -- tedarikçiye iade
  'damage_write_off',       -- maliyet havuzundan düşme (hasar silme)
  'damage_recovery',        -- damaged → sellable (tamir vs.)
  'inventory_adjustment',   -- sayım farkı
  'transfer_out',           -- şubeye gönderim (kaynak şube defteri)
  'transfer_in',            -- şubeden alındı (hedef şube defteri)
  'reservation_expired',    -- rezervasyon iptal — stok serbest
  'initial_stock'           -- açılış sayımı
);

CREATE TYPE goods_receipt_status         AS ENUM ('draft', 'confirmed', 'cancelled');
CREATE TYPE goods_receipt_payment_status AS ENUM ('unpaid', 'partial', 'paid');

CREATE TYPE sale_status AS ENUM (
  'completed',
  'voided',
  'refunded',
  'partially_refunded'
);

CREATE TYPE payment_method AS ENUM (
  'cash',
  'card',
  'bank_transfer',
  'mixed',    -- header level only; detail rows are individual methods
  'other'
);

CREATE TYPE reservation_status AS ENUM (
  'active',
  'converted',   -- satışa dönüştü
  'cancelled',
  'expired'
);

CREATE TYPE return_type AS ENUM (
  'refund',
  'exchange',
  'store_credit'
);

CREATE TYPE return_item_condition AS ENUM (
  'resellable',
  'damaged',
  'missing'
);

-- Transfer lifecycle: draft → shipped → received (or cancelled).
-- While status = 'shipped', floating units live in transfer_held_inventory,
-- NOT in any branch's inventory_movements bucket.
CREATE TYPE transfer_status AS ENUM (
  'draft',
  'shipped',    -- units removed from source branch; held in transfer_held_inventory
  'received',   -- units added to destination branch sellable bucket
  'cancelled'
);

CREATE TYPE register_session_status AS ENUM ('open', 'closed');

CREATE TYPE cash_movement_type AS ENUM (
  'opening_cash',
  'sale_cash',
  'sale_card',
  'sale_transfer',
  'refund_cash',
  'cash_in',
  'cash_out',
  'expense',
  'closing_count'
);

CREATE TYPE supplier_entry_type AS ENUM (
  'purchase',    -- borç oluştu
  'payment',     -- ödeme yapıldı
  'return',      -- tedarikçiye iade → alacak
  'adjustment'   -- manuel düzeltme
);

CREATE TYPE discount_type   AS ENUM ('percentage', 'fixed');
CREATE TYPE discount_reason AS ENUM (
  'manager_discount',
  'promotion',
  'loyalty',
  'damaged_goods',
  'negotiated',
  'other'
);

CREATE TYPE inventory_count_status AS ENUM ('draft', 'in_progress', 'completed', 'cancelled');


-- ============================================================
-- CORE: BUSINESSES & BRANCHES
-- ============================================================

CREATE TABLE businesses (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name         TEXT NOT NULL,
  code         TEXT NOT NULL,
  sector       TEXT,
  currency     TEXT NOT NULL DEFAULT 'TRY',
  tax_number   TEXT,
  address      TEXT,
  phone        TEXT,
  email        TEXT,
  logo_url     TEXT,
  status       business_status NOT NULL DEFAULT 'active',
  settings     JSONB NOT NULL DEFAULT '{}',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (code)
);

CREATE TABLE branches (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  code         TEXT NOT NULL,
  address      TEXT,
  phone        TEXT,
  is_default   BOOLEAN NOT NULL DEFAULT false,
  status       branch_status NOT NULL DEFAULT 'active',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, code),
  -- CRITICAL 16: enables composite FK in child tables
  UNIQUE (business_id, id)
);


-- ============================================================
-- AUTH / PROFILES / MEMBERS
-- ============================================================

CREATE TABLE profiles (
  id           UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name    TEXT,
  phone        TEXT,
  avatar_url   TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE business_members (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id       UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  user_id           UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  role              user_role NOT NULL,
  branch_id         UUID REFERENCES branches(id),
  is_active         BOOLEAN NOT NULL DEFAULT true,
  max_discount_pct  NUMERIC(5,2) NOT NULL DEFAULT 0,
  joined_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, user_id)
);


-- ============================================================
-- BRANDS & CATEGORIES
-- ============================================================

CREATE TABLE brands (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  is_active    BOOLEAN NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, name),
  UNIQUE (business_id, id)  -- CRITICAL 16
);

CREATE TABLE categories (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id    UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  parent_id      UUID REFERENCES categories(id),
  name           TEXT NOT NULL,
  slug           TEXT NOT NULL,
  sort_order     INTEGER NOT NULL DEFAULT 0,
  is_active      BOOLEAN NOT NULL DEFAULT true,
  -- When true, items in this category cannot be exchanged or refunded.
  -- Enforced by rpc_process_return(). Example: Bikini / Mayo.
  is_final_sale  BOOLEAN NOT NULL DEFAULT false,
  created_by     UUID REFERENCES profiles(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, slug),
  UNIQUE (business_id, id)  -- CRITICAL 16
);


-- ============================================================
-- SUPPLIERS
-- ============================================================

CREATE TABLE suppliers (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id   UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  code          TEXT,
  contact_name  TEXT,
  phone         TEXT,
  whatsapp      TEXT,
  instagram     TEXT,
  email         TEXT,
  city          TEXT,
  country       TEXT NOT NULL DEFAULT 'TR',
  currency      TEXT NOT NULL DEFAULT 'TRY',
  notes         TEXT,
  status        supplier_status NOT NULL DEFAULT 'active',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, name),
  UNIQUE (business_id, id)  -- CRITICAL 16
);

-- ──────────────────────────────────────────────────────────────────────
-- Supplier current account (immutable ledger — INSERT only)
--
-- CRITICAL 14 (Rev 3): column structure clarified for multi-currency.
-- amount_original : the amount in the transaction currency (signed)
--                   positive = we owe the supplier (purchase/debit)
--                   negative = supplier owes us (payment/credit/return)
-- currency        : ISO 4217 code of the original transaction
-- exchange_rate   : 1 unit of currency = N TRY at time of entry (1.0 for TRY)
-- amount_base     : TRY equivalent, GENERATED (source of truth for TRY balance)
--
-- TRY running balance: SUM(amount_base) WHERE supplier_id = ? AND business_id = ?
-- Original-currency balances: query per-currency with SUM(amount_original) WHERE currency = ?
--
-- Direct client INSERT is BLOCKED by RLS. Use posting RPCs (rpc_confirm_goods_receipt etc.).
-- ──────────────────────────────────────────────────────────────────────
CREATE TABLE supplier_account_entries (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id     UUID NOT NULL REFERENCES businesses(id),
  supplier_id     UUID NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
  entry_type      supplier_entry_type NOT NULL,
  -- Signed amount in the transaction currency
  amount_original NUMERIC(12,2) NOT NULL,
  -- ISO 4217 transaction currency ('TRY' for domestic; 'GBP'/'EUR'/'USD' for foreign)
  currency        TEXT NOT NULL DEFAULT 'TRY',
  -- 1 unit of currency = N TRY at time of entry; always 1.000000 for TRY entries
  exchange_rate   NUMERIC(12,6) NOT NULL DEFAULT 1,
  CONSTRAINT chk_sae_exchange_rate CHECK (exchange_rate > 0),
  CONSTRAINT chk_sae_try_rate CHECK (currency <> 'TRY' OR exchange_rate = 1.000000),
  -- TRY equivalent (authoritative base-currency amount for balance reporting)
  amount_base     NUMERIC(12,4) GENERATED ALWAYS AS (amount_original * exchange_rate) STORED,
  reference_id    UUID,
  reference_type  TEXT,   -- 'goods_receipt' | 'payment' | 'supplier_return'
  note            TEXT,
  created_by      UUID REFERENCES profiles(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE supplier_payments (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id     UUID NOT NULL REFERENCES businesses(id),
  supplier_id     UUID NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
  payment_number  TEXT NOT NULL,
  amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  currency        TEXT NOT NULL DEFAULT 'TRY',
  exchange_rate   NUMERIC(12,6) NOT NULL DEFAULT 1,
  amount_base     NUMERIC(12,2) GENERATED ALWAYS AS (amount * exchange_rate) STORED,
  method          payment_method NOT NULL,
  reference_no    TEXT,
  note            TEXT,
  paid_at         DATE NOT NULL,
  created_by      UUID REFERENCES profiles(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, payment_number)
);

CREATE TABLE supplier_payment_allocations (
  id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  supplier_payment_id  UUID NOT NULL REFERENCES supplier_payments(id) ON DELETE CASCADE,
  goods_receipt_id     UUID NOT NULL,   -- FK added after goods_receipts is created
  amount               NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- PRODUCTS
-- ============================================================

CREATE TABLE product_options (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  sort_order   INTEGER NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, name),
  UNIQUE (business_id, id)  -- CRITICAL 16
);

CREATE TABLE option_values (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  product_option_id UUID NOT NULL REFERENCES product_options(id) ON DELETE CASCADE,
  value             TEXT NOT NULL,
  sort_order        INTEGER NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (product_option_id, value)
);

CREATE TABLE products (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  category_id         UUID REFERENCES categories(id),
  brand_id            UUID REFERENCES brands(id),
  supplier_id         UUID REFERENCES suppliers(id),
  name                TEXT NOT NULL,
  sku_prefix          TEXT NOT NULL,
  collection          TEXT,
  description         TEXT,
  notes               TEXT,
  default_sale_price  NUMERIC(12,2) NOT NULL CHECK (default_sale_price >= 0),
  tax_rate            NUMERIC(5,2) NOT NULL DEFAULT 0,
  is_tax_inclusive    BOOLEAN NOT NULL DEFAULT true,
  min_stock_alert     INTEGER NOT NULL DEFAULT 2,
  status              product_status NOT NULL DEFAULT 'draft',
  show_on_instagram   BOOLEAN NOT NULL DEFAULT false,
  is_featured         BOOLEAN NOT NULL DEFAULT false,
  is_new_arrival      BOOLEAN NOT NULL DEFAULT false,
  in_campaign         BOOLEAN NOT NULL DEFAULT false,
  created_by          UUID REFERENCES profiles(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, sku_prefix),
  UNIQUE (business_id, id)  -- CRITICAL 16
);

-- CRITICAL 16: business_id is added here so child tables can enforce
-- (business_id, variant_id) composite FK → prevents cross-tenant variant references.
-- business_id is populated automatically by trg_variant_business_id (trigger below).
-- Cost state is NOT stored here; it lives in variant_cost_pools (migration 002).
CREATE TABLE product_variants (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  -- Populated by trigger from products.business_id; never set by caller.
  business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  product_id          UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  sku                 TEXT NOT NULL,
  sale_price_override NUMERIC(12,2),
  status              variant_status NOT NULL DEFAULT 'active',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (sku),
  UNIQUE (business_id, id)  -- CRITICAL 16: enables composite FK in child tables
);

CREATE TABLE variant_option_values (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  variant_id        UUID NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,
  product_option_id UUID NOT NULL REFERENCES product_options(id),
  option_value_id   UUID NOT NULL REFERENCES option_values(id),
  UNIQUE (variant_id, product_option_id)
);

CREATE TABLE product_images (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  product_id   UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  variant_id   UUID REFERENCES product_variants(id),
  url          TEXT NOT NULL,
  alt_text     TEXT,
  image_type   TEXT,
  sort_order   INTEGER NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE product_price_history (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  product_id   UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  variant_id   UUID REFERENCES product_variants(id),
  old_price    NUMERIC(12,2),
  new_price    NUMERIC(12,2) NOT NULL,
  changed_by   UUID REFERENCES profiles(id),
  reason       TEXT,
  changed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- BARCODES
-- ============================================================

CREATE TABLE barcodes (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id         UUID NOT NULL REFERENCES businesses(id),
  variant_id          UUID NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,
  barcode             TEXT NOT NULL,
  barcode_type        TEXT NOT NULL DEFAULT 'CODE128',
  is_primary          BOOLEAN NOT NULL DEFAULT true,
  is_supplier_barcode BOOLEAN NOT NULL DEFAULT false,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, barcode)
);


-- ============================================================
-- GOODS RECEIPTS  (Mal Kabul)
-- ============================================================

-- invoice_currency / exchange_rate: currency of the supplier invoice.
-- unit_cost on receipt items is in invoice_currency.
-- rpc_confirm_goods_receipt converts to TRY and populates
-- goods_receipt_items.unit_cost_base and total_cost_base (CRITICAL 15).
CREATE TABLE goods_receipts (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  branch_id        UUID NOT NULL REFERENCES branches(id),
  supplier_id      UUID REFERENCES suppliers(id),
  receipt_number   TEXT NOT NULL,
  document_ref     TEXT,
  received_at      DATE NOT NULL,
  note             TEXT,
  status           goods_receipt_status NOT NULL DEFAULT 'draft',
  payment_status   goods_receipt_payment_status NOT NULL DEFAULT 'unpaid',
  total_cost       NUMERIC(12,2) NOT NULL DEFAULT 0,
  invoice_currency TEXT NOT NULL DEFAULT 'TRY',
  exchange_rate    NUMERIC(12,6) NOT NULL DEFAULT 1,
  CONSTRAINT chk_gr_exchange_rate CHECK (exchange_rate > 0),
  created_by       UUID REFERENCES profiles(id),
  confirmed_by     UUID REFERENCES profiles(id),
  confirmed_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, receipt_number)
);

-- CRITICAL 15: cost columns redesigned.
-- unit_cost         : cost in invoice_currency (from supplier invoice — authoritative)
-- total_cost_original: qty × unit_cost in invoice_currency (GENERATED — always available)
-- unit_cost_base    : TRY-equivalent per unit; NULL until rpc_confirm_goods_receipt runs
-- total_cost_base   : TRY-equivalent total; NULL until rpc_confirm_goods_receipt runs
-- Cannot use GENERATED ALWAYS AS for unit_cost_base because the exchange_rate lives
-- on goods_receipts (different table) — no cross-table GENERATED columns in PostgreSQL.
--
-- CRITICAL 16: business_id added; populated by trigger trg_gri_business_id.
-- Enables composite FK (business_id, variant_id) → product_variants(business_id, id).
CREATE TABLE goods_receipt_items (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  goods_receipt_id    UUID NOT NULL REFERENCES goods_receipts(id) ON DELETE CASCADE,
  -- CRITICAL 16: populated by trigger from goods_receipts.business_id
  business_id         UUID NOT NULL REFERENCES businesses(id),
  variant_id          UUID NOT NULL REFERENCES product_variants(id),
  quantity            INTEGER NOT NULL CHECK (quantity > 0),
  -- Cost in invoice_currency (as stated on the supplier invoice)
  unit_cost           NUMERIC(12,2) NOT NULL CHECK (unit_cost >= 0),
  -- Total in invoice_currency (computed, always available)
  total_cost_original NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_cost) STORED,
  -- TRY-equivalent cost per unit; set by rpc_confirm_goods_receipt (NULL until then)
  unit_cost_base      NUMERIC(12,4),
  -- TRY-equivalent total; set by rpc_confirm_goods_receipt (NULL until then)
  total_cost_base     NUMERIC(12,4),
  labels_printed      BOOLEAN NOT NULL DEFAULT false,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Deferred FK from supplier_payment_allocations
ALTER TABLE supplier_payment_allocations
  ADD CONSTRAINT fk_spa_goods_receipt
  FOREIGN KEY (goods_receipt_id) REFERENCES goods_receipts(id);


-- ============================================================
-- CROSS-TENANT TRIGGERS  (business_id propagation)
-- ============================================================

-- Ensures product_variants.business_id always matches products.business_id.
-- Called before every INSERT; business_id from caller is ignored.
CREATE OR REPLACE FUNCTION fn_set_variant_business_id()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  SELECT business_id INTO NEW.business_id
  FROM products WHERE id = NEW.product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_set_variant_business_id: product % not found', NEW.product_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_variant_business_id
  BEFORE INSERT ON product_variants
  FOR EACH ROW EXECUTE FUNCTION fn_set_variant_business_id();

-- Ensures goods_receipt_items.business_id always matches goods_receipts.business_id.
CREATE OR REPLACE FUNCTION fn_set_gri_business_id()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  SELECT business_id INTO NEW.business_id
  FROM goods_receipts WHERE id = NEW.goods_receipt_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_set_gri_business_id: goods_receipt % not found', NEW.goods_receipt_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_gri_business_id
  BEFORE INSERT ON goods_receipt_items
  FOR EACH ROW EXECUTE FUNCTION fn_set_gri_business_id();


-- ============================================================
-- CROSS-TENANT FK CONSTRAINTS
-- ============================================================
-- These prevent a row from referencing an entity that belongs to a different
-- business. PostgreSQL enforces this at the DB level — no application code needed.

-- goods_receipts.branch_id must belong to the same business as the receipt
ALTER TABLE goods_receipts
  ADD CONSTRAINT fk_gr_branch_xtenant
  FOREIGN KEY (business_id, branch_id) REFERENCES branches (business_id, id);

-- goods_receipt_items.variant_id must belong to the same business as the item
ALTER TABLE goods_receipt_items
  ADD CONSTRAINT fk_gri_variant_xtenant
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id);

-- Note: products → category/brand/supplier cross-tenant FK deferred.
-- To implement: add UNIQUE(business_id, id) to categories, brands, suppliers (done above),
-- then add business_id to products for those columns and alter products.category_id,
-- products.brand_id, products.supplier_id to composite FKs.
-- Deferred because products.category_id is currently a simple FK (no business_id stored).
-- Enforcement for now: application layer + RPC membership validation.


-- ============================================================
-- END OF MIGRATION 001
-- ============================================================
-- Rev 3 summary:
--   ✓ CRITICAL 14: supplier_account_entries redesigned
--       amount_original (signed, in transaction currency)
--       amount_base GENERATED (TRY equivalent, source of truth)
--       exchange_rate CHECK constraints (positive, TRY=1)
--   ✓ CRITICAL 15: goods_receipt_items cost columns corrected
--       total_cost_original GENERATED (invoice currency total)
--       unit_cost_base: NULL until rpc_confirm_goods_receipt
--       total_cost_base: NULL until rpc_confirm_goods_receipt
--   ✓ CRITICAL 16 (partial): composite FK pattern implemented
--       UNIQUE(business_id, id) on: branches, brands, categories,
--         suppliers, product_options, products, product_variants
--       business_id added to product_variants (trigger-populated)
--       business_id added to goods_receipt_items (trigger-populated)
--       Cross-tenant FKs: goods_receipts.branch_id, gri.variant_id
--       Products → category/brand/supplier cross-tenant: DEFERRED
-- ============================================================
