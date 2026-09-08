-- ============================================================
-- BoutiqueOS  •  Migration 001  •  Core schema
-- Rev 3  •  2026-09-08
-- ============================================================
-- Contents:
--   extensions, numeric domains, enums
--   businesses / branches / profiles / business_members
--   RLS helper functions (defined BEFORE any policy uses them)
--   brands / categories / suppliers
--   supplier ledger: supplier_account_entries, supplier_payments,
--                    supplier_payment_allocations (cross-currency explicit)
--   product model: product_options, option_values, products,
--                  product_variants (option fingerprint), variant_option_values,
--                  barcodes, product_images, product_price_history
--   goods_receipts / goods_receipt_items
--   business_id propagation triggers, cross-tenant composite FKs
--   RLS enable + policies for the tables above
--
-- NUMERIC POLICY (project-wide, see domains below):
--   money2  NUMERIC(12,2)  customer-facing prices/amounts
--   cost6   NUMERIC(14,6)  unit costs, MWA, FX-converted unit costs
--   value6  NUMERIC(18,6)  pool/ledger total values
--   fx6     NUMERIC(14,6)  exchange rates (> 0)
--   Never MONEY / FLOAT / REAL / DOUBLE PRECISION.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "pg_trgm";
-- gen_random_uuid() is in pg_catalog (PG13+); no uuid-ossp dependency.

-- ============================================================
-- DOMAINS
-- ============================================================
CREATE DOMAIN money2 AS NUMERIC(12,2);
CREATE DOMAIN cost6  AS NUMERIC(14,6);
CREATE DOMAIN value6 AS NUMERIC(18,6);
CREATE DOMAIN fx6    AS NUMERIC(14,6) CHECK (VALUE > 0);
CREATE DOMAIN iso_currency AS TEXT CHECK (VALUE IN ('TRY','GBP','EUR','USD'));

-- ============================================================
-- ENUMS
-- ============================================================
CREATE TYPE user_role AS ENUM ('owner','manager','sales_staff','stock_staff');

CREATE TYPE business_status AS ENUM ('active','suspended','cancelled');
CREATE TYPE branch_status   AS ENUM ('active','inactive');
CREATE TYPE supplier_status AS ENUM ('active','inactive');
CREATE TYPE product_status  AS ENUM ('draft','active','archived');
CREATE TYPE variant_status  AS ENUM ('active','archived');

-- Physical branch-held condition buckets. IN_TRANSIT is NOT a bucket.
CREATE TYPE inventory_bucket AS ENUM ('sellable','quarantine','damaged');

-- Ledger movement families (handoff list)
CREATE TYPE movement_reason AS ENUM (
  'goods_receipt',
  'sale',
  'sale_void',
  'customer_return',
  'supplier_return',
  'adjustment',
  'state_change',
  'transfer_ship',
  'transfer_receive',
  'write_off'
);

CREATE TYPE goods_receipt_status AS ENUM ('draft','posted','cancelled');
CREATE TYPE goods_receipt_payment_status AS ENUM ('unpaid','partial','paid');

CREATE TYPE sale_status        AS ENUM ('completed','voided');
CREATE TYPE payment_method     AS ENUM ('cash','card','bank_transfer','other');
CREATE TYPE reservation_status AS ENUM ('active','converted','cancelled','expired');
CREATE TYPE return_type        AS ENUM ('exchange','refund','store_credit');
CREATE TYPE transfer_status    AS ENUM ('draft','shipped','received','cancelled');
CREATE TYPE register_session_status AS ENUM ('open','closed');

CREATE TYPE cash_movement_type AS ENUM (
  'sale_cash',        -- + physical cash received for a sale (per currency)
  'change_out',       -- - change handed back (TRY)
  'void_cash_out',    -- - cash returned on sale void
  'refund_cash_out',  -- - cash refund (only if policy allows)
  'cash_in',          -- + manual cash in
  'cash_out',         -- - manual cash out
  'expense'           -- - petty expense
);

CREATE TYPE supplier_entry_type AS ENUM (
  'liability',   -- + we owe the supplier (posted goods receipt)
  'payment',     -- - we paid the supplier
  'credit',      -- - supplier owes us (supplier return / credit note)
  'adjustment'   -- +/- manual correction (manager+)
);
CREATE TYPE settlement_basis AS ENUM ('same_currency','liability_rate','payment_rate','manual');

CREATE TYPE discount_reason AS ENUM (
  'manager_discount','promotion','seasonal','selected_product',
  'loyalty','damaged_goods','negotiated','other'
);

CREATE TYPE barcode_type AS ENUM ('internal','supplier');
CREATE TYPE adjustment_cost_source AS ENUM ('current_mwa','last_purchase_cost_confirmed','manual_cost');
CREATE TYPE inventory_count_status AS ENUM ('draft','in_progress','completed','cancelled');

-- ============================================================
-- BUSINESSES / BRANCHES
-- ============================================================
CREATE TABLE businesses (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT NOT NULL,
  code         TEXT NOT NULL UNIQUE,
  sector       TEXT,
  base_currency iso_currency NOT NULL DEFAULT 'TRY',
  tax_number   TEXT,
  address      TEXT,
  phone        TEXT,
  email        TEXT,
  logo_url     TEXT,
  status       business_status NOT NULL DEFAULT 'active',
  -- Policy keys read by RPCs (no defaults invented in code; missing key => RAISE):
  --   money_refund_allowed   bool
  --   store_credit_allowed   bool
  --   exchange_window_days   int
  --   accepted_currencies    text[]
  --   fx_override_roles      text[] (roles allowed to override daily FX at POS)
  settings     JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE branches (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  code         TEXT NOT NULL,
  address      TEXT,
  phone        TEXT,
  is_default   BOOLEAN NOT NULL DEFAULT false,
  status       branch_status NOT NULL DEFAULT 'active',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, code),
  UNIQUE (business_id, id)
);

-- ============================================================
-- PROFILES / MEMBERS
-- ============================================================
CREATE TABLE profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name   TEXT,
  phone       TEXT,
  avatar_url  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Auto-create profile row for each auth user (Supabase pattern)
CREATE OR REPLACE FUNCTION fn_handle_new_auth_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
BEGIN
  INSERT INTO public.profiles (id) VALUES (NEW.id) ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END $$;
REVOKE EXECUTE ON FUNCTION fn_handle_new_auth_user() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION fn_handle_new_auth_user();

CREATE TABLE business_members (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  user_id          UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  role             user_role NOT NULL,
  branch_id        UUID,
  is_active        BOOLEAN NOT NULL DEFAULT true,
  -- J-4: independent manual discount authority. Only consulted for sales_staff.
  -- Owner/manager are not capped by this column. Default 0 = "not configured".
  max_discount_pct NUMERIC(5,2) NOT NULL DEFAULT 0
                   CHECK (max_discount_pct >= 0 AND max_discount_pct <= 100),
  joined_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, user_id),
  FOREIGN KEY (business_id, branch_id) REFERENCES branches (business_id, id)
);

-- ============================================================
-- RLS HELPER FUNCTIONS  (must precede every policy)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_my_business_ids()
RETURNS UUID[] LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(ARRAY(
    SELECT business_id FROM business_members
    WHERE user_id = auth.uid() AND is_active), ARRAY[]::UUID[]);
$$;

CREATE OR REPLACE FUNCTION fn_is_member(p_business_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (SELECT 1 FROM business_members
    WHERE user_id = auth.uid() AND business_id = p_business_id AND is_active);
$$;

CREATE OR REPLACE FUNCTION fn_my_role(p_business_id UUID)
RETURNS user_role LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT role FROM business_members
  WHERE user_id = auth.uid() AND business_id = p_business_id AND is_active;
$$;

CREATE OR REPLACE FUNCTION fn_has_role(p_business_id UUID, p_roles user_role[])
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (SELECT 1 FROM business_members
    WHERE user_id = auth.uid() AND business_id = p_business_id
      AND is_active AND role = ANY(p_roles));
$$;

-- owner | manager
CREATE OR REPLACE FUNCTION fn_is_manager_plus(p_business_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT fn_has_role(p_business_id, ARRAY['owner','manager']::user_role[]);
$$;

-- J-3: procurement/operational stock role = owner | manager | stock_staff
CREATE OR REPLACE FUNCTION fn_is_procurement(p_business_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT fn_has_role(p_business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
$$;

-- Required setting reader: missing key => error (never invent defaults)
CREATE OR REPLACE FUNCTION fn_setting(p_business_id UUID, p_key TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE v JSONB;
BEGIN
  SELECT settings -> p_key INTO v FROM businesses WHERE id = p_business_id;
  IF v IS NULL THEN
    RAISE EXCEPTION 'SETTING_MISSING: business % has no setting "%"', p_business_id, p_key
      USING ERRCODE = 'P0002';
  END IF;
  RETURN v;
END $$;

REVOKE EXECUTE ON FUNCTION fn_my_business_ids()                FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION fn_is_member(UUID)                  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION fn_my_role(UUID)                    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION fn_has_role(UUID, user_role[])      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION fn_is_manager_plus(UUID)            FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION fn_is_procurement(UUID)             FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION fn_setting(UUID, TEXT)              FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_my_business_ids()                TO authenticated;
GRANT  EXECUTE ON FUNCTION fn_is_member(UUID)                  TO authenticated;
GRANT  EXECUTE ON FUNCTION fn_my_role(UUID)                    TO authenticated;
GRANT  EXECUTE ON FUNCTION fn_has_role(UUID, user_role[])      TO authenticated;
GRANT  EXECUTE ON FUNCTION fn_is_manager_plus(UUID)            TO authenticated;
GRANT  EXECUTE ON FUNCTION fn_is_procurement(UUID)             TO authenticated;
-- fn_setting stays INTERNAL (called only from SECURITY DEFINER RPCs). Clients read
-- their own business settings through businesses.settings, which RLS scopes to members.
-- Exposing it would let any authenticated user probe settings of arbitrary business ids.

-- ============================================================
-- BRANDS / CATEGORIES / SUPPLIERS
-- ============================================================
CREATE TABLE brands (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  is_active    BOOLEAN NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, name),
  UNIQUE (business_id, id)
);

CREATE TABLE categories (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id    UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  parent_id      UUID,
  name           TEXT NOT NULL,
  slug           TEXT NOT NULL,
  sort_order     INTEGER NOT NULL DEFAULT 0,
  is_active      BOOLEAN NOT NULL DEFAULT true,
  -- true => no exchange/return (rpc_process_return enforces). e.g. Bikini / Mayo
  is_final_sale  BOOLEAN NOT NULL DEFAULT false,
  created_by     UUID REFERENCES profiles(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, slug),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, parent_id) REFERENCES categories (business_id, id)
);

CREATE TABLE suppliers (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  currency      iso_currency NOT NULL DEFAULT 'TRY',
  notes         TEXT,
  status        supplier_status NOT NULL DEFAULT 'active',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, name),
  UNIQUE (business_id, id)
);

-- ============================================================
-- SUPPLIER LEDGER  (INSERT-only; RPC writes only)
-- ============================================================
-- amount_original: signed, in entry currency. +liability, -payment, -credit.
-- amount_base:     TRY equivalent at the rate snapshotted on this row.
-- Balance (base):  SUM(amount_base). Per-currency open: SUM(amount_original) by currency.
CREATE TABLE supplier_account_entries (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     UUID NOT NULL REFERENCES businesses(id),
  supplier_id     UUID NOT NULL,
  entry_type      supplier_entry_type NOT NULL,
  amount_original NUMERIC(14,2) NOT NULL CHECK (amount_original <> 0),
  currency        iso_currency NOT NULL,
  exchange_rate   fx6 NOT NULL,
  CONSTRAINT chk_sae_try_rate CHECK (currency <> 'TRY' OR exchange_rate = 1),
  CONSTRAINT chk_sae_sign CHECK (
    (entry_type = 'liability' AND amount_original > 0) OR
    (entry_type IN ('payment','credit') AND amount_original < 0) OR
    (entry_type = 'adjustment')
  ),
  amount_base     value6 GENERATED ALWAYS AS (amount_original * exchange_rate) STORED,
  reference_id    UUID,
  reference_type  TEXT,   -- 'goods_receipt' | 'supplier_payment' | 'supplier_return' | 'manual'
  note            TEXT,
  created_by      UUID REFERENCES profiles(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, supplier_id) REFERENCES suppliers (business_id, id)
);

CREATE TABLE supplier_payments (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     UUID NOT NULL REFERENCES businesses(id),
  supplier_id     UUID NOT NULL,
  payment_number  TEXT NOT NULL,
  amount          NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  currency        iso_currency NOT NULL,
  exchange_rate   fx6 NOT NULL,
  CONSTRAINT chk_sp_try_rate CHECK (currency <> 'TRY' OR exchange_rate = 1),
  amount_base     value6 GENERATED ALWAYS AS (amount * exchange_rate) STORED,
  method          payment_method NOT NULL,
  reference_no    TEXT,
  note            TEXT,
  paid_at         DATE NOT NULL,
  ledger_entry_id UUID NOT NULL REFERENCES supplier_account_entries(id),
  created_by      UUID REFERENCES profiles(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, payment_number),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, supplier_id) REFERENCES suppliers (business_id, id)
);

-- Cross-currency settlement is explicit (handoff): no single ambiguous "amount".
CREATE TABLE supplier_payment_allocations (
  id                               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id                      UUID NOT NULL REFERENCES businesses(id),
  supplier_payment_id              UUID NOT NULL,
  liability_entry_id               UUID NOT NULL,
  liability_currency               iso_currency NOT NULL,
  payment_currency                 iso_currency NOT NULL,
  liability_currency_amount_applied NUMERIC(14,2) NOT NULL CHECK (liability_currency_amount_applied > 0),
  payment_currency_amount_applied   NUMERIC(14,2) NOT NULL CHECK (payment_currency_amount_applied > 0),
  base_amount_applied               value6 NOT NULL CHECK (base_amount_applied > 0),
  settlement_fx_rate                fx6 NOT NULL,   -- liability ccy -> payment ccy basis rate
  settlement_basis                  settlement_basis NOT NULL,
  created_by                        UUID REFERENCES profiles(id),
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (business_id, supplier_payment_id) REFERENCES supplier_payments (business_id, id),
  FOREIGN KEY (business_id, liability_entry_id)  REFERENCES supplier_account_entries (business_id, id)
);

-- ============================================================
-- PRODUCT MODEL
-- ============================================================
CREATE TABLE product_options (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  sort_order   INTEGER NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, name),
  UNIQUE (business_id, id)
);

CREATE TABLE option_values (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE, -- trigger-populated
  product_option_id UUID NOT NULL,
  value             TEXT NOT NULL,
  sort_order        INTEGER NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (product_option_id, value),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, product_option_id) REFERENCES product_options (business_id, id) ON DELETE CASCADE
);

CREATE TABLE products (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  category_id         UUID,
  brand_id            UUID,
  supplier_id         UUID,
  name                TEXT NOT NULL,
  sku_prefix          TEXT NOT NULL,
  collection          TEXT,
  description         TEXT,
  notes               TEXT,
  default_sale_price  money2 NOT NULL CHECK (default_sale_price >= 0),
  tax_rate            NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (tax_rate >= 0),
  is_tax_inclusive    BOOLEAN NOT NULL DEFAULT true,
  min_stock_alert     INTEGER NOT NULL DEFAULT 0,
  status              product_status NOT NULL DEFAULT 'draft',
  show_on_instagram   BOOLEAN NOT NULL DEFAULT false,
  created_by          UUID REFERENCES profiles(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, sku_prefix),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, category_id) REFERENCES categories (business_id, id),
  FOREIGN KEY (business_id, brand_id)    REFERENCES brands     (business_id, id),
  FOREIGN KEY (business_id, supplier_id) REFERENCES suppliers  (business_id, id)
);

-- No cost state here (cost lives in variant_cost_pools, migration 003).
-- option_fingerprint: "optionId:valueId|optionId:valueId" sorted; trigger-maintained.
-- Two ACTIVE variants of one product can never share a fingerprint (DB-enforced).
CREATE TABLE product_variants (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE, -- trigger-populated
  product_id          UUID NOT NULL,
  sku                 TEXT NOT NULL,
  sale_price_override money2 CHECK (sale_price_override IS NULL OR sale_price_override >= 0),
  status              variant_status NOT NULL DEFAULT 'active',
  option_fingerprint  TEXT NOT NULL DEFAULT '',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, sku),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, product_id) REFERENCES products (business_id, id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX uix_variant_active_fingerprint
  ON product_variants (product_id, option_fingerprint) WHERE status = 'active';

CREATE TABLE variant_option_values (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE, -- trigger-populated
  variant_id        UUID NOT NULL,
  product_option_id UUID NOT NULL,
  option_value_id   UUID NOT NULL,
  UNIQUE (variant_id, product_option_id),
  FOREIGN KEY (business_id, variant_id)        REFERENCES product_variants (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, product_option_id) REFERENCES product_options  (business_id, id),
  FOREIGN KEY (business_id, option_value_id)   REFERENCES option_values    (business_id, id)
);

CREATE TABLE barcodes (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE, -- trigger-populated
  variant_id    UUID NOT NULL,
  barcode       TEXT NOT NULL CHECK (length(barcode) BETWEEN 3 AND 64),
  barcode_type  barcode_type NOT NULL DEFAULT 'internal',
  symbology     TEXT NOT NULL DEFAULT 'CODE128',   -- CODE128 | EAN13 | ...; printer-agnostic
  is_primary    BOOLEAN NOT NULL DEFAULT false,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, barcode),
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX uix_barcode_primary ON barcodes (variant_id) WHERE is_primary;

CREATE TABLE product_images (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE, -- trigger-populated
  product_id   UUID NOT NULL,
  variant_id   UUID,
  url          TEXT NOT NULL,
  alt_text     TEXT,
  sort_order   INTEGER NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (business_id, product_id) REFERENCES products (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id) ON DELETE CASCADE
);

CREATE TABLE product_price_history (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  product_id   UUID NOT NULL,
  variant_id   UUID,
  old_price    money2,
  new_price    money2 NOT NULL,
  changed_by   UUID REFERENCES profiles(id),
  reason       TEXT,
  changed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (business_id, product_id) REFERENCES products (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id) ON DELETE CASCADE
);

-- Price history trigger (audit of price changes on products / variants)
CREATE OR REPLACE FUNCTION fn_log_price_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
BEGIN
  -- NOTE: table name test and NEW.<col> reference MUST be separate statements. plpgsql plans an
  -- IF condition as one SQL expression, so "TG_TABLE_NAME = 'products' AND NEW.default_sale_price ..."
  -- fails on product_variants rows ('record "new" has no field') even though AND would short-circuit.
  IF TG_TABLE_NAME = 'products' THEN
    IF NEW.default_sale_price IS DISTINCT FROM OLD.default_sale_price THEN
      INSERT INTO product_price_history (business_id, product_id, old_price, new_price, changed_by)
      VALUES (NEW.business_id, NEW.id, OLD.default_sale_price, NEW.default_sale_price, auth.uid());
    END IF;
  ELSIF TG_TABLE_NAME = 'product_variants' THEN
    IF NEW.sale_price_override IS DISTINCT FROM OLD.sale_price_override AND NEW.sale_price_override IS NOT NULL THEN
      INSERT INTO product_price_history (business_id, product_id, variant_id, old_price, new_price, changed_by)
      VALUES (NEW.business_id, NEW.product_id, NEW.id, OLD.sale_price_override, NEW.sale_price_override, auth.uid());
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE EXECUTE ON FUNCTION fn_log_price_change() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_products_price_history AFTER UPDATE ON products
  FOR EACH ROW EXECUTE FUNCTION fn_log_price_change();
CREATE TRIGGER trg_variants_price_history AFTER UPDATE ON product_variants
  FOR EACH ROW EXECUTE FUNCTION fn_log_price_change();

-- ============================================================
-- GOODS RECEIPTS  (draft editable; posted immutable except payment_status)
-- ============================================================
CREATE TABLE goods_receipts (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      UUID NOT NULL REFERENCES businesses(id),
  branch_id        UUID NOT NULL,
  supplier_id      UUID NOT NULL,
  receipt_number   TEXT NOT NULL,
  document_ref     TEXT,
  received_at      DATE NOT NULL DEFAULT CURRENT_DATE,
  note             TEXT,
  status           goods_receipt_status NOT NULL DEFAULT 'draft',
  payment_status   goods_receipt_payment_status NOT NULL DEFAULT 'unpaid',
  invoice_currency iso_currency NOT NULL DEFAULT 'TRY',
  -- transaction-specific FX (1 unit invoice ccy = N base). Validated at post time.
  exchange_rate    fx6 NOT NULL DEFAULT 1,
  CONSTRAINT chk_gr_try_rate CHECK (invoice_currency <> 'TRY' OR exchange_rate = 1),
  created_by       UUID REFERENCES profiles(id),
  posted_by        UUID REFERENCES profiles(id),
  posted_at        TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, receipt_number),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, branch_id)   REFERENCES branches  (business_id, id),
  FOREIGN KEY (business_id, supplier_id) REFERENCES suppliers (business_id, id)
);

-- Historical acquisition-cost truth. Original currency preserved.
-- unit_cost_base / fx_rate_snapshot / total_cost_base are written by
-- rpc_post_goods_receipt at post time and are immutable afterwards.
CREATE TABLE goods_receipt_items (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id), -- trigger-populated
  goods_receipt_id    UUID NOT NULL,
  variant_id          UUID NOT NULL,
  quantity            INTEGER NOT NULL CHECK (quantity > 0),
  unit_cost           cost6 NOT NULL CHECK (unit_cost >= 0),      -- invoice currency
  total_cost_original value6 GENERATED ALWAYS AS (quantity * unit_cost) STORED,
  fx_rate_snapshot    fx6,                                       -- set at post
  unit_cost_base      cost6,                                     -- set at post
  total_cost_base     value6,                                    -- set at post (exact qty*unit_cost_base)
  labels_printed      BOOLEAN NOT NULL DEFAULT false,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (goods_receipt_id, variant_id),
  FOREIGN KEY (business_id, goods_receipt_id) REFERENCES goods_receipts (business_id, id) ON DELETE CASCADE,
  FOREIGN KEY (business_id, variant_id)       REFERENCES product_variants (business_id, id)
);

-- ============================================================
-- business_id PROPAGATION TRIGGERS  (caller value is ignored)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_set_business_id_from_parent()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_biz UUID;
BEGIN
  -- TG_ARGV[0] = parent table, TG_ARGV[1] = FK column on child
  EXECUTE format('SELECT business_id FROM %I WHERE id = $1', TG_ARGV[0])
    INTO v_biz USING (to_jsonb(NEW) ->> TG_ARGV[1])::UUID;
  IF v_biz IS NULL THEN
    RAISE EXCEPTION '%: parent % not found for %', TG_TABLE_NAME, TG_ARGV[0], TG_ARGV[1];
  END IF;
  NEW.business_id := v_biz;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_bid_option_values BEFORE INSERT OR UPDATE ON option_values
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('product_options','product_option_id');
CREATE TRIGGER trg_bid_variants BEFORE INSERT OR UPDATE ON product_variants
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('products','product_id');
CREATE TRIGGER trg_bid_vov BEFORE INSERT OR UPDATE ON variant_option_values
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('product_variants','variant_id');
CREATE TRIGGER trg_bid_barcodes BEFORE INSERT OR UPDATE ON barcodes
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('product_variants','variant_id');
CREATE TRIGGER trg_bid_images BEFORE INSERT OR UPDATE ON product_images
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('products','product_id');
CREATE TRIGGER trg_bid_gri BEFORE INSERT OR UPDATE ON goods_receipt_items
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('goods_receipts','goods_receipt_id');

-- ============================================================
-- VARIANT OPTION FINGERPRINT  (duplicate-combination prevention)
-- ============================================================
-- Statement-level triggers with transition tables so that a multi-row
-- INSERT (rpc_create_variant) yields ONE recomputation per variant and
-- never a transient partial fingerprint collision.
CREATE OR REPLACE FUNCTION fn_refresh_variant_fingerprint()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_ids UUID[];
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT array_agg(DISTINCT variant_id) INTO v_ids FROM new_rows;
  ELSIF TG_OP = 'DELETE' THEN
    SELECT array_agg(DISTINCT variant_id) INTO v_ids FROM old_rows;
  ELSE
    SELECT array_agg(DISTINCT variant_id) INTO v_ids
    FROM (SELECT variant_id FROM new_rows UNION SELECT variant_id FROM old_rows) u;
  END IF;
  IF v_ids IS NULL THEN RETURN NULL; END IF;

  UPDATE product_variants pv
  SET option_fingerprint = COALESCE((
        SELECT string_agg(v.product_option_id::text || ':' || v.option_value_id::text, '|'
                          ORDER BY v.product_option_id)
        FROM variant_option_values v WHERE v.variant_id = pv.id), '')
  WHERE pv.id = ANY(v_ids);
  RETURN NULL;
END $$;

CREATE TRIGGER trg_vov_fp_ins AFTER INSERT ON variant_option_values
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION fn_refresh_variant_fingerprint();
CREATE TRIGGER trg_vov_fp_del AFTER DELETE ON variant_option_values
  REFERENCING OLD TABLE AS old_rows
  FOR EACH STATEMENT EXECUTE FUNCTION fn_refresh_variant_fingerprint();
CREATE TRIGGER trg_vov_fp_upd AFTER UPDATE ON variant_option_values
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION fn_refresh_variant_fingerprint();

-- Option value must belong to the option it is attached to
CREATE OR REPLACE FUNCTION fn_check_vov_consistency()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM option_values ov
                 WHERE ov.id = NEW.option_value_id AND ov.product_option_id = NEW.product_option_id) THEN
    RAISE EXCEPTION 'variant_option_values: option_value % does not belong to option %',
      NEW.option_value_id, NEW.product_option_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_vov_consistency BEFORE INSERT OR UPDATE ON variant_option_values
  FOR EACH ROW EXECUTE FUNCTION fn_check_vov_consistency();

-- ============================================================
-- IMMUTABILITY  (generic trigger; used here and in migration 003)
-- ============================================================
-- Forbids UPDATE/DELETE on append-only tables for EVERY role
-- (including service_role). Posting RPCs never update these rows.
-- Row-comparison helper for immutability guards.
-- In a BEFORE ROW trigger PostgreSQL has not computed GENERATED columns yet, so they read as NULL in
-- NEW while OLD carries the stored value. Comparing to_jsonb(NEW) with to_jsonb(OLD) directly would
-- therefore report a difference for every generated column and block legitimate updates
-- (e.g. sales.amount_due_base during a void). Strip generated columns from both sides.
CREATE OR REPLACE FUNCTION fn_row_comparable(p_row JSONB, p_table TEXT)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT p_row - COALESCE(
    (SELECT array_agg(a.attname::text)
     FROM pg_attribute a
     WHERE a.attrelid = ('public.' || quote_ident(p_table))::regclass
       AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated <> ''), '{}'::text[]);
$$;
REVOKE EXECUTE ON FUNCTION fn_row_comparable(JSONB, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_forbid_update_delete()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'IMMUTABLE: % rows cannot be %', TG_TABLE_NAME, TG_OP
    USING ERRCODE = '55000';
END $$;

CREATE TRIGGER trg_imm_sae BEFORE UPDATE OR DELETE ON supplier_account_entries
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_update_delete();
CREATE TRIGGER trg_imm_spa BEFORE UPDATE OR DELETE ON supplier_payment_allocations
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_update_delete();
CREATE TRIGGER trg_imm_sp  BEFORE UPDATE OR DELETE ON supplier_payments
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_update_delete();

-- Posted goods receipt: only payment_status may change (and only that).
CREATE OR REPLACE FUNCTION fn_guard_posted_goods_receipt()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'posted' THEN
      RAISE EXCEPTION 'IMMUTABLE: posted goods receipt % cannot be deleted', OLD.id USING ERRCODE='55000';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status = 'posted' THEN
    IF fn_row_comparable(to_jsonb(NEW), TG_TABLE_NAME) - 'payment_status' - 'updated_at' IS DISTINCT FROM
       fn_row_comparable(to_jsonb(OLD), TG_TABLE_NAME) - 'payment_status' - 'updated_at' THEN
      RAISE EXCEPTION 'IMMUTABLE: posted goods receipt % (only payment_status may change)', OLD.id
        USING ERRCODE='55000';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_posted_gr BEFORE UPDATE OR DELETE ON goods_receipts
  FOR EACH ROW EXECUTE FUNCTION fn_guard_posted_goods_receipt();

-- Items of a posted receipt are frozen.
CREATE OR REPLACE FUNCTION fn_guard_posted_gri()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_status goods_receipt_status;
BEGIN
  SELECT status INTO v_status FROM goods_receipts WHERE id = COALESCE(NEW.goods_receipt_id, OLD.goods_receipt_id);
  IF v_status = 'posted' THEN
    RAISE EXCEPTION 'IMMUTABLE: items of posted goods receipt cannot be %', TG_OP USING ERRCODE='55000';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_posted_gri BEFORE INSERT OR UPDATE OR DELETE ON goods_receipt_items
  FOR EACH ROW EXECUTE FUNCTION fn_guard_posted_gri();

-- updated_at maintenance
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

DO $do$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['businesses','branches','profiles','suppliers','products',
                           'product_variants','goods_receipts'] LOOP
    EXECUTE format('CREATE TRIGGER trg_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at()', t);
  END LOOP;
END $do$;

-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX idx_members_user        ON business_members (user_id) WHERE is_active;
CREATE INDEX idx_products_business   ON products (business_id, status);
CREATE INDEX idx_products_category   ON products (category_id);
CREATE INDEX idx_products_name_trgm  ON products USING gin (name gin_trgm_ops);
CREATE INDEX idx_variants_product    ON product_variants (product_id);
CREATE INDEX idx_barcodes_variant    ON barcodes (variant_id);
CREATE INDEX idx_gr_business_date    ON goods_receipts (business_id, received_at DESC);
CREATE INDEX idx_gri_receipt         ON goods_receipt_items (goods_receipt_id);
CREATE INDEX idx_gri_variant_posted  ON goods_receipt_items (variant_id, created_at DESC) WHERE unit_cost_base IS NOT NULL;
CREATE INDEX idx_sae_supplier        ON supplier_account_entries (supplier_id, created_at DESC);
CREATE INDEX idx_spa_liability       ON supplier_payment_allocations (liability_entry_id);
CREATE INDEX idx_spa_payment         ON supplier_payment_allocations (supplier_payment_id);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
DO $do$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'businesses','branches','profiles','business_members','brands','categories','suppliers',
    'supplier_account_entries','supplier_payments','supplier_payment_allocations',
    'product_options','option_values','products','product_variants','variant_option_values',
    'barcodes','product_images','product_price_history','goods_receipts','goods_receipt_items'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $do$;
-- NOTE: RLS is NOT forced for the table owner. SECURITY DEFINER posting RPCs run as the
-- migration owner (postgres) and therefore bypass RLS by design; they enforce
-- membership/role/tenant checks explicitly in their bodies (ADR-13).

-- profiles: self only
CREATE POLICY pol_profiles_select ON profiles FOR SELECT USING (id = auth.uid());
CREATE POLICY pol_profiles_update ON profiles FOR UPDATE USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- businesses: members read; owner updates (settings etc). No client INSERT/DELETE (tenant onboarding is out-of-band).
CREATE POLICY pol_businesses_select ON businesses FOR SELECT USING (fn_is_member(id));
CREATE POLICY pol_businesses_update ON businesses FOR UPDATE
  USING (fn_has_role(id, ARRAY['owner']::user_role[])) WITH CHECK (fn_has_role(id, ARRAY['owner']::user_role[]));

-- branches: members read; owner writes
CREATE POLICY pol_branches_select ON branches FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_branches_write  ON branches FOR ALL
  USING (fn_has_role(business_id, ARRAY['owner']::user_role[]))
  WITH CHECK (fn_has_role(business_id, ARRAY['owner']::user_role[]));

-- business_members: members read; owner writes
CREATE POLICY pol_bm_select ON business_members FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_bm_write  ON business_members FOR ALL
  USING (fn_has_role(business_id, ARRAY['owner']::user_role[]))
  WITH CHECK (fn_has_role(business_id, ARRAY['owner']::user_role[]));

-- master data: members read; manager+ write
CREATE POLICY pol_brands_select ON brands FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_brands_write  ON brands FOR ALL USING (fn_is_manager_plus(business_id)) WITH CHECK (fn_is_manager_plus(business_id));
CREATE POLICY pol_categories_select ON categories FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_categories_write  ON categories FOR ALL USING (fn_is_manager_plus(business_id)) WITH CHECK (fn_is_manager_plus(business_id));
CREATE POLICY pol_suppliers_select ON suppliers FOR SELECT USING (fn_is_procurement(business_id));
CREATE POLICY pol_suppliers_write  ON suppliers FOR ALL USING (fn_is_manager_plus(business_id)) WITH CHECK (fn_is_manager_plus(business_id));

-- supplier accounting: manager+ read only; no client writes (RPC only)  (J-3)
CREATE POLICY pol_sae_select ON supplier_account_entries FOR SELECT USING (fn_is_manager_plus(business_id));
CREATE POLICY pol_sp_select  ON supplier_payments FOR SELECT USING (fn_is_manager_plus(business_id));
CREATE POLICY pol_spa_select ON supplier_payment_allocations FOR SELECT USING (fn_is_manager_plus(business_id));

-- product model: members read; manager+ write
CREATE POLICY pol_po_select  ON product_options FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_po_write   ON product_options FOR ALL USING (fn_is_manager_plus(business_id)) WITH CHECK (fn_is_manager_plus(business_id));
CREATE POLICY pol_ov_select  ON option_values FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_ov_write   ON option_values FOR ALL USING (fn_is_manager_plus(business_id)) WITH CHECK (fn_is_manager_plus(business_id));
CREATE POLICY pol_products_select ON products FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_products_write  ON products FOR ALL USING (fn_is_manager_plus(business_id)) WITH CHECK (fn_is_manager_plus(business_id));
CREATE POLICY pol_variants_select ON product_variants FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_variants_write  ON product_variants FOR ALL USING (fn_is_manager_plus(business_id)) WITH CHECK (fn_is_manager_plus(business_id));
CREATE POLICY pol_vov_select ON variant_option_values FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_vov_write  ON variant_option_values FOR ALL USING (fn_is_manager_plus(business_id)) WITH CHECK (fn_is_manager_plus(business_id));
CREATE POLICY pol_barcodes_select ON barcodes FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_barcodes_write  ON barcodes FOR ALL USING (fn_is_procurement(business_id)) WITH CHECK (fn_is_procurement(business_id));
CREATE POLICY pol_images_select ON product_images FOR SELECT USING (fn_is_member(business_id));
CREATE POLICY pol_images_write  ON product_images FOR ALL USING (fn_is_manager_plus(business_id)) WITH CHECK (fn_is_manager_plus(business_id));
CREATE POLICY pol_pph_select ON product_price_history FOR SELECT USING (fn_is_manager_plus(business_id));

-- goods receipts (J-3): procurement roles create/edit drafts and read costs; sales_staff nothing.
CREATE POLICY pol_gr_select  ON goods_receipts FOR SELECT USING (fn_is_procurement(business_id));
CREATE POLICY pol_gr_insert  ON goods_receipts FOR INSERT WITH CHECK (fn_is_procurement(business_id) AND status = 'draft');
CREATE POLICY pol_gr_update  ON goods_receipts FOR UPDATE
  USING (fn_is_procurement(business_id) AND status = 'draft')
  WITH CHECK (fn_is_procurement(business_id) AND status IN ('draft','cancelled'));
CREATE POLICY pol_gr_delete  ON goods_receipts FOR DELETE USING (fn_is_procurement(business_id) AND status = 'draft');
CREATE POLICY pol_gri_select ON goods_receipt_items FOR SELECT USING (fn_is_procurement(business_id));
CREATE POLICY pol_gri_write  ON goods_receipt_items FOR ALL
  USING (fn_is_procurement(business_id)) WITH CHECK (fn_is_procurement(business_id));
-- (posted receipts/items are additionally frozen by triggers regardless of role)

-- ============================================================
-- END 001
-- ============================================================
