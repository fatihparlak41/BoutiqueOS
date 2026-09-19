-- ============================================================
-- Phase 13B — SaaS billing foundation (manual billing only)
--
-- PLAN → SUBSCRIPTION → BILLING PERIOD → SAAS INVOICE → PAYMENT → SUBSCRIPTION STATE
--
-- Decisions (docs/09 ADR-20):
--   * SaaS billing is its own ledger: saas_invoices / saas_invoice_items / saas_payments.
--     Nothing here touches sales, sale_payments, register sessions, cash_movements,
--     supplier liabilities, goods receipts or any tenant inventory/accounting table.
--   * Money is the proven money2 domain (NUMERIC(12,2)); every amount is computed in SQL,
--     never in the browser. Currency is explicit on every row and must match on payment.
--   * An invoice is a SNAPSHOT of the plan at issue time (name, price, currency, interval,
--     period). A later plan-price change never rewrites an issued invoice; the next invoice
--     uses the then-current catalogue price (no grandfathering in 13B).
--   * Tax is explicit: tax_amount is 0 only under the documented policy 'none_unconfigured'
--     (no VAT rate is inferred from the country). The document is a billing statement, not
--     a legally compliant tax invoice.
--   * Exactly one non-void invoice per (subscription, period_start); one OPEN invoice per
--     subscription at a time; issuing is idempotent (a second call replays the open one).
--   * Numbering BOS-YYYY-NNNNNN from a per-year sequence row locked in the transaction.
--     The number is a reference, never an authorisation.
--   * Payments are recorded by a platform admin after the money arrived OUTSIDE the app
--     (bank transfer / cash / other manual). No provider, no card, no checkout, no webhook.
--     Provider columns exist, stay NULL, and cannot be written by anyone in 13B.
--     A payment is idempotent on (invoice, reference): the same reference recorded twice is
--     one payment. Overpayment is refused; a partial payment is recorded and the invoice
--     stays open (no credit balance is invented).
--   * A FULL payment atomically marks the invoice paid and activates / re-activates the
--     subscription for the invoiced period (starts_at from the period, ends_at = period_end).
--     Manual activation of a subscription without a paid invoice is no longer possible.
--   * Overdue is DERIVED in every read (open AND due_at < now()); rpc_platform_billing_sweep
--     may materialise subscription past_due and period-end cancellations when the platform
--     asks for it. Nothing here suspends a business: business.status, subscription.status and
--     invoice.status stay three separate facts (grace policy is data: platform_settings).
--   * Paid and void invoices are immutable (trigger); issued invoices, items and payments are
--     never deleted (trigger). Void keeps the row with actor + reason.
-- ============================================================

CREATE TYPE saas_invoice_status  AS ENUM ('open','paid','void');
CREATE TYPE saas_payment_method  AS ENUM ('bank_transfer','cash_manual','other_manual');
CREATE TYPE saas_payment_status  AS ENUM ('recorded','reversed');   -- 'reversed' reserved; no path writes it in 13B

-- ------------------------------------------------------------ platform settings (data, not code)
CREATE TABLE platform_settings (
  key        TEXT PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]{1,40}$'),
  value      JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID REFERENCES profiles(id)
);
ALTER TABLE platform_settings ENABLE ROW LEVEL SECURITY;      -- no policies: platform RPCs only
REVOKE ALL ON platform_settings FROM anon, authenticated;
INSERT INTO platform_settings (key, value) VALUES
  ('invoice_due_days',   '14'::jsonb),   -- due_at = issued_at + N days
  ('billing_grace_days', '14'::jsonb);   -- shown as "grace ends" after due; NOT enforced in 13B

CREATE OR REPLACE FUNCTION fn_saas_setting_int(p_key TEXT, p_default INTEGER)
RETURNS INTEGER LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT COALESCE((SELECT (value #>> '{}')::integer FROM platform_settings WHERE key = p_key), p_default);
$$;
REVOKE EXECUTE ON FUNCTION fn_saas_setting_int(TEXT, INTEGER) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ invoice numbering
CREATE TABLE saas_invoice_sequences (
  year       INTEGER PRIMARY KEY,
  last_value INTEGER NOT NULL DEFAULT 0
);
ALTER TABLE saas_invoice_sequences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON saas_invoice_sequences FROM anon, authenticated;

-- BOS-YYYY-NNNNNN. The per-year row is locked by the upsert, so two issuers serialise here.
CREATE OR REPLACE FUNCTION fn_saas_next_invoice_number()
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_year INTEGER := extract(year FROM now())::integer; v_n INTEGER;
BEGIN
  INSERT INTO saas_invoice_sequences (year, last_value) VALUES (v_year, 1)
  ON CONFLICT (year) DO UPDATE SET last_value = saas_invoice_sequences.last_value + 1
  RETURNING last_value INTO v_n;
  RETURN 'BOS-' || v_year::text || '-' || lpad(v_n::text, 6, '0');
END $$;
REVOKE EXECUTE ON FUNCTION fn_saas_next_invoice_number() FROM PUBLIC, anon, authenticated;

-- Calendar interval of a plan: a month is a month, a year is a year (no 30/365-day arithmetic).
CREATE OR REPLACE FUNCTION fn_saas_plan_interval(p_interval billing_interval)
RETURNS INTERVAL LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_interval WHEN 'monthly' THEN interval '1 month' ELSE interval '1 year' END;
$$;
REVOKE EXECUTE ON FUNCTION fn_saas_plan_interval(billing_interval) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ invoices
CREATE TABLE saas_invoices (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_number        TEXT NOT NULL UNIQUE CHECK (invoice_number ~ '^BOS-[0-9]{4}-[0-9]{6}$'),
  business_id           UUID NOT NULL REFERENCES businesses(id),
  subscription_id       UUID NOT NULL REFERENCES business_subscriptions(id),
  plan_id               UUID NOT NULL REFERENCES saas_plans(id),
  -- snapshot of the plan at issue time (the catalogue may change later; this row never does)
  plan_code             TEXT NOT NULL,
  plan_name             TEXT NOT NULL,
  billing_interval      billing_interval NOT NULL,
  currency              iso_currency NOT NULL,
  subtotal              money2 NOT NULL CHECK (subtotal >= 0),
  tax_amount            money2 NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  tax_policy            TEXT NOT NULL DEFAULT 'none_unconfigured' CHECK (tax_policy IN ('none_unconfigured')),
  total                 money2 NOT NULL CHECK (total >= 0),
  amount_paid           money2 NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  status                saas_invoice_status NOT NULL DEFAULT 'open',
  billing_period_start  TIMESTAMPTZ NOT NULL,
  billing_period_end    TIMESTAMPTZ NOT NULL,
  issued_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  issued_by             UUID NOT NULL REFERENCES profiles(id),
  due_at                TIMESTAMPTZ NOT NULL,
  paid_at               TIMESTAMPTZ,
  voided_at             TIMESTAMPTZ,
  voided_by             UUID REFERENCES profiles(id),
  void_reason           TEXT,
  note                  TEXT,
  -- provider linkage reserved for a later phase: nothing writes these in 13B
  provider              TEXT,
  provider_invoice_id   TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_saas_inv_total   CHECK (total = subtotal + tax_amount),
  CONSTRAINT chk_saas_inv_paid    CHECK (amount_paid <= total),
  CONSTRAINT chk_saas_inv_period  CHECK (billing_period_end > billing_period_start),
  CONSTRAINT chk_saas_inv_paid_st CHECK ((status = 'paid') = (paid_at IS NOT NULL)),
  CONSTRAINT chk_saas_inv_void_st CHECK ((status = 'void') = (voided_at IS NOT NULL)),
  CONSTRAINT chk_saas_inv_no_provider CHECK (provider IS NULL AND provider_invoice_id IS NULL)
);
-- exactly one live invoice per billing period of a subscription
CREATE UNIQUE INDEX uix_saas_invoice_period ON saas_invoices (subscription_id, billing_period_start) WHERE status <> 'void';
-- one open invoice per subscription at a time
CREATE UNIQUE INDEX uix_saas_invoice_open ON saas_invoices (subscription_id) WHERE status = 'open';
CREATE INDEX idx_saas_invoices_business ON saas_invoices (business_id, issued_at DESC);
CREATE INDEX idx_saas_invoices_status   ON saas_invoices (status, due_at);
ALTER TABLE saas_invoices ENABLE ROW LEVEL SECURITY;          -- no policies: reads go through RPCs
REVOKE ALL ON saas_invoices FROM anon, authenticated;

CREATE TABLE saas_invoice_items (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id   UUID NOT NULL REFERENCES saas_invoices(id),
  business_id  UUID NOT NULL REFERENCES businesses(id),
  line_no      INTEGER NOT NULL CHECK (line_no > 0),
  description  TEXT NOT NULL CHECK (length(trim(description)) BETWEEN 1 AND 200),
  quantity     INTEGER NOT NULL CHECK (quantity > 0),
  unit_amount  money2 NOT NULL CHECK (unit_amount >= 0),
  line_total   money2 NOT NULL CHECK (line_total >= 0),
  plan_id      UUID REFERENCES saas_plans(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (invoice_id, line_no),
  CONSTRAINT chk_saas_item_total CHECK (line_total = unit_amount * quantity)
);
ALTER TABLE saas_invoice_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON saas_invoice_items FROM anon, authenticated;

CREATE TABLE saas_payments (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID NOT NULL REFERENCES businesses(id),
  subscription_id     UUID NOT NULL REFERENCES business_subscriptions(id),
  invoice_id          UUID NOT NULL REFERENCES saas_invoices(id),
  amount              money2 NOT NULL CHECK (amount > 0),
  currency            iso_currency NOT NULL,
  status              saas_payment_status NOT NULL DEFAULT 'recorded',
  method              saas_payment_method NOT NULL,
  reference           TEXT NOT NULL CHECK (length(trim(reference)) BETWEEN 2 AND 120),
  paid_at             TIMESTAMPTZ NOT NULL,
  note                TEXT,
  recorded_by         UUID NOT NULL REFERENCES profiles(id),
  -- provider linkage reserved for a later phase: nothing writes these in 13B
  provider            TEXT,
  provider_reference  TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_saas_pay_no_provider CHECK (provider IS NULL AND provider_reference IS NULL)
);
-- the same external reference on the same invoice is one payment (two admins, one bank line)
CREATE UNIQUE INDEX uix_saas_payment_reference ON saas_payments (invoice_id, lower(trim(reference)));
CREATE INDEX idx_saas_payments_business ON saas_payments (business_id, paid_at DESC);
ALTER TABLE saas_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON saas_payments FROM anon, authenticated;

-- subscription: scheduled cancellation (the paid period stays intact; no renewal is issued)
ALTER TABLE business_subscriptions ADD COLUMN cancel_at_period_end BOOLEAN NOT NULL DEFAULT false;

-- ------------------------------------------------------------ immutability
-- An issued invoice is a document. Open: only the settlement columns move. Paid / void: frozen. Never deleted.
CREATE OR REPLACE FUNCTION fn_saas_invoice_guard()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'INVOICE_RETAINED: issued invoices are never deleted' USING ERRCODE = '55000'; END IF;
  IF OLD.status IN ('paid','void') THEN
    RAISE EXCEPTION 'INVOICE_IMMUTABLE: invoice % is %', OLD.invoice_number, OLD.status USING ERRCODE = '55000';
  END IF;
  IF NEW.invoice_number <> OLD.invoice_number OR NEW.business_id <> OLD.business_id OR NEW.subscription_id <> OLD.subscription_id
     OR NEW.plan_id <> OLD.plan_id OR NEW.plan_code <> OLD.plan_code OR NEW.plan_name <> OLD.plan_name OR NEW.billing_interval <> OLD.billing_interval
     OR NEW.currency <> OLD.currency OR NEW.subtotal <> OLD.subtotal OR NEW.tax_amount <> OLD.tax_amount OR NEW.tax_policy <> OLD.tax_policy
     OR NEW.total <> OLD.total OR NEW.billing_period_start <> OLD.billing_period_start OR NEW.billing_period_end <> OLD.billing_period_end
     OR NEW.issued_at <> OLD.issued_at OR NEW.issued_by <> OLD.issued_by OR NEW.due_at <> OLD.due_at
     OR NEW.provider IS DISTINCT FROM OLD.provider OR NEW.provider_invoice_id IS DISTINCT FROM OLD.provider_invoice_id THEN
    RAISE EXCEPTION 'INVOICE_SNAPSHOT_LOCKED: the financial snapshot of % cannot change', OLD.invoice_number USING ERRCODE = '55000';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER trg_saas_invoice_guard BEFORE UPDATE OR DELETE ON saas_invoices FOR EACH ROW EXECUTE FUNCTION fn_saas_invoice_guard();

CREATE OR REPLACE FUNCTION fn_saas_billing_row_frozen()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  RAISE EXCEPTION 'BILLING_ROW_FROZEN: % rows are never changed or deleted', TG_TABLE_NAME USING ERRCODE = '55000';
END $$;
CREATE TRIGGER trg_saas_items_frozen    BEFORE UPDATE OR DELETE ON saas_invoice_items FOR EACH ROW EXECUTE FUNCTION fn_saas_billing_row_frozen();
CREATE TRIGGER trg_saas_payments_frozen BEFORE UPDATE OR DELETE ON saas_payments      FOR EACH ROW EXECUTE FUNCTION fn_saas_billing_row_frozen();

-- ------------------------------------------------------------ read shapes (shared by platform + owner reads)
CREATE OR REPLACE FUNCTION fn_saas_invoice_json(i saas_invoices)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT jsonb_build_object(
    'id', i.id, 'invoice_number', i.invoice_number, 'status', i.status,
    'overdue', (i.status = 'open' AND i.due_at < now()),
    'days_overdue', CASE WHEN i.status = 'open' AND i.due_at < now() THEN floor(extract(epoch FROM now() - i.due_at) / 86400)::int ELSE 0 END,
    'grace_ends_at', i.due_at + make_interval(days => fn_saas_setting_int('billing_grace_days', 0)),
    'plan_code', i.plan_code, 'plan_name', i.plan_name, 'billing_interval', i.billing_interval,
    'currency', i.currency, 'subtotal', i.subtotal, 'tax_amount', i.tax_amount, 'tax_policy', i.tax_policy, 'total', i.total,
    'amount_paid', i.amount_paid, 'balance', i.total - i.amount_paid,
    'billing_period_start', i.billing_period_start, 'billing_period_end', i.billing_period_end,
    'issued_at', i.issued_at, 'due_at', i.due_at, 'paid_at', i.paid_at, 'voided_at', i.voided_at, 'void_reason', i.void_reason, 'note', i.note);
$$;
REVOKE EXECUTE ON FUNCTION fn_saas_invoice_json(saas_invoices) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_saas_subscription_json(s business_subscriptions)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT jsonb_build_object(
    'id', s.id, 'status', s.status, 'starts_at', s.starts_at, 'ends_at', s.ends_at, 'renews_at', s.renews_at,
    'activated_at', s.activated_at, 'cancelled_at', s.cancelled_at, 'cancel_at_period_end', s.cancel_at_period_end,
    'lapsed', (s.status IN ('active','past_due') AND s.ends_at IS NOT NULL AND s.ends_at < now()),
    'plan', (SELECT jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'price_amount', p.price_amount, 'currency', p.currency, 'billing_interval', p.billing_interval)
             FROM saas_plans p WHERE p.id = s.plan_id));
$$;
REVOKE EXECUTE ON FUNCTION fn_saas_subscription_json(business_subscriptions) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ platform writes
-- Issue the invoice of the next billing period of a subscription (first period or renewal).
--   * first period starts at issue time; a renewal starts where the last live invoice ended
--   * refuses cancelled / expired subscriptions and scheduled cancellations
--   * idempotent: while an open invoice exists it is returned (replayed:true)
--   * a renewal is only issued once the previous invoice is paid (no stacked open invoices)
CREATE OR REPLACE FUNCTION rpc_platform_issue_invoice(p_subscription_id UUID, p_note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); s RECORD; p RECORD; last RECORD; v_start TIMESTAMPTZ; v_end TIMESTAMPTZ;
        v_id UUID; v_no TEXT; v_due TIMESTAMPTZ; v_desc TEXT; v_open RECORD;
BEGIN
  SELECT * INTO s FROM business_subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: subscription %', p_subscription_id USING ERRCODE = 'P0002'; END IF;
  IF s.status IN ('cancelled','expired') THEN RAISE EXCEPTION 'INVALID_STATE: subscription is %', s.status USING ERRCODE = '55000'; END IF;
  SELECT * INTO v_open FROM saas_invoices WHERE subscription_id = s.id AND status = 'open';
  IF v_open.id IS NOT NULL THEN
    RETURN jsonb_build_object('invoice_id', v_open.id, 'invoice_number', v_open.invoice_number, 'status', 'open', 'replayed', true);
  END IF;
  IF s.cancel_at_period_end THEN RAISE EXCEPTION 'CANCEL_SCHEDULED: the subscription ends with the current period; no renewal is issued' USING ERRCODE = '55000'; END IF;
  SELECT * INTO p FROM saas_plans WHERE id = s.plan_id;
  SELECT * INTO last FROM saas_invoices WHERE subscription_id = s.id AND status <> 'void' ORDER BY billing_period_start DESC, invoice_number DESC LIMIT 1;
  IF last.id IS NULL THEN
    v_start := now();
  ELSE
    v_start := last.billing_period_end;
  END IF;
  v_end := v_start + fn_saas_plan_interval(p.billing_interval);
  v_no := fn_saas_next_invoice_number();
  v_due := now() + make_interval(days => fn_saas_setting_int('invoice_due_days', 14));
  v_desc := p.name || ' — ' || CASE p.billing_interval WHEN 'monthly' THEN 'aylık abonelik' ELSE 'yıllık abonelik' END
            || ' (' || to_char(v_start, 'DD.MM.YYYY') || ' – ' || to_char(v_end - interval '1 day', 'DD.MM.YYYY') || ')';
  INSERT INTO saas_invoices (invoice_number, business_id, subscription_id, plan_id, plan_code, plan_name, billing_interval, currency,
                             subtotal, tax_amount, tax_policy, total, billing_period_start, billing_period_end, issued_by, due_at, note)
  VALUES (v_no, s.business_id, s.id, p.id, p.code, p.name, p.billing_interval, p.currency,
          p.price_amount, 0, 'none_unconfigured', p.price_amount, v_start, v_end, v_admin, v_due, NULLIF(trim(COALESCE(p_note, '')), ''))
  RETURNING id INTO v_id;
  INSERT INTO saas_invoice_items (invoice_id, business_id, line_no, description, quantity, unit_amount, line_total, plan_id)
  VALUES (v_id, s.business_id, 1, v_desc, 1, p.price_amount, p.price_amount, p.id);
  INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, payload)
  VALUES (v_admin, 'issue_invoice', s.business_id,
          jsonb_build_object('invoice_id', v_id, 'invoice_number', v_no, 'subscription_id', s.id, 'plan', p.code, 'total', p.price_amount, 'currency', p.currency,
                             'period_start', v_start, 'period_end', v_end, 'note', p_note));
  RETURN jsonb_build_object('invoice_id', v_id, 'invoice_number', v_no, 'status', 'open', 'total', p.price_amount, 'currency', p.currency,
                            'billing_period_start', v_start, 'billing_period_end', v_end, 'due_at', v_due, 'replayed', false);
EXCEPTION WHEN unique_violation THEN
  -- two issuers raced past the row lock release: the first invoice stands
  SELECT * INTO v_open FROM saas_invoices WHERE subscription_id = p_subscription_id AND status = 'open';
  IF v_open.id IS NULL THEN RAISE; END IF;
  RETURN jsonb_build_object('invoice_id', v_open.id, 'invoice_number', v_open.invoice_number, 'status', 'open', 'replayed', true);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_issue_invoice(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_issue_invoice(UUID, TEXT) TO authenticated;

-- Record a payment that arrived outside the app. Full payment settles the invoice and activates
-- the subscription for the invoiced period in the same transaction. Same reference → replay.
CREATE OR REPLACE FUNCTION rpc_platform_record_payment(
  p_invoice_id UUID, p_amount NUMERIC, p_currency TEXT, p_method TEXT, p_reference TEXT,
  p_paid_at TIMESTAMPTZ DEFAULT now(), p_note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); i RECORD; s RECORD; v_method saas_payment_method; v_cur iso_currency; v_ref TEXT;
        v_existing RECORD; v_pay UUID; v_paid money2; v_full BOOLEAN := false; v_activated BOOLEAN := false; v_from subscription_status;
BEGIN
  BEGIN v_method := p_method::saas_payment_method; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_METHOD: %', p_method USING ERRCODE = '22023'; END;
  BEGIN v_cur := p_currency::iso_currency; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_CURRENCY: %', p_currency USING ERRCODE = '22023'; END;
  v_ref := trim(COALESCE(p_reference, ''));
  IF length(v_ref) < 2 THEN RAISE EXCEPTION 'REFERENCE_REQUIRED: a bank / receipt reference identifies the payment' USING ERRCODE = '22023'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> round(p_amount, 2) THEN RAISE EXCEPTION 'INVALID_AMOUNT: %', p_amount USING ERRCODE = '22023'; END IF;
  IF p_paid_at IS NULL OR p_paid_at > now() + interval '1 day' THEN RAISE EXCEPTION 'INVALID_DATE: paid_at %', p_paid_at USING ERRCODE = '22023'; END IF;

  SELECT * INTO i FROM saas_invoices WHERE id = p_invoice_id FOR UPDATE;
  IF i.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: invoice %', p_invoice_id USING ERRCODE = 'P0002'; END IF;
  -- the same bank line recorded twice (two admins, a retry): one payment, nothing applied twice
  SELECT * INTO v_existing FROM saas_payments WHERE invoice_id = i.id AND lower(trim(reference)) = lower(v_ref);
  IF v_existing.id IS NOT NULL THEN
    RETURN jsonb_build_object('payment_id', v_existing.id, 'invoice_id', i.id, 'invoice_status', i.status, 'amount_paid', i.amount_paid, 'replayed', true);
  END IF;
  IF i.status <> 'open' THEN RAISE EXCEPTION 'INVALID_STATE: invoice % is %', i.invoice_number, i.status USING ERRCODE = '55000'; END IF;
  IF v_cur <> i.currency THEN RAISE EXCEPTION 'CURRENCY_MISMATCH: invoice is in %, payment in %', i.currency, v_cur USING ERRCODE = '22023'; END IF;
  IF i.amount_paid + p_amount > i.total THEN
    RAISE EXCEPTION 'OVERPAYMENT: % + % exceeds the invoice total % (no credit balance is kept)', i.amount_paid, p_amount, i.total USING ERRCODE = '22023';
  END IF;

  INSERT INTO saas_payments (business_id, subscription_id, invoice_id, amount, currency, method, reference, paid_at, note, recorded_by)
  VALUES (i.business_id, i.subscription_id, i.id, p_amount, v_cur, v_method, v_ref, p_paid_at, NULLIF(trim(COALESCE(p_note, '')), ''), v_admin)
  RETURNING id INTO v_pay;
  v_paid := i.amount_paid + p_amount;
  v_full := (v_paid = i.total);
  UPDATE saas_invoices SET amount_paid = v_paid,
                           status  = CASE WHEN v_full THEN 'paid'::saas_invoice_status ELSE status END,
                           paid_at = CASE WHEN v_full THEN p_paid_at ELSE paid_at END
  WHERE id = i.id;

  IF v_full THEN
    SELECT * INTO s FROM business_subscriptions WHERE id = i.subscription_id FOR UPDATE;
    v_from := s.status;
    IF s.status IN ('pending','active','past_due') THEN
      UPDATE business_subscriptions SET
        status = 'active',
        starts_at = COALESCE(starts_at, i.billing_period_start),
        ends_at = i.billing_period_end,
        renews_at = CASE WHEN cancel_at_period_end THEN NULL ELSE i.billing_period_end END,
        activated_at = COALESCE(activated_at, now()),
        updated_at = now()
      WHERE id = s.id;
      v_activated := true;
    END IF;
  END IF;

  INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, payload)
  VALUES (v_admin, 'record_payment', i.business_id,
          jsonb_build_object('payment_id', v_pay, 'invoice_id', i.id, 'invoice_number', i.invoice_number, 'amount', p_amount, 'currency', v_cur,
                             'method', v_method, 'reference', v_ref, 'paid_at', p_paid_at, 'invoice_paid', v_full,
                             'subscription_id', i.subscription_id, 'from', v_from, 'to', CASE WHEN v_activated THEN 'active' END, 'note', p_note));
  RETURN jsonb_build_object('payment_id', v_pay, 'invoice_id', i.id, 'invoice_status', CASE WHEN v_full THEN 'paid' ELSE 'open' END,
                            'amount_paid', v_paid, 'balance', i.total - v_paid, 'subscription_activated', v_activated, 'replayed', false);
EXCEPTION WHEN unique_violation THEN
  -- two admins recorded the same reference at the same instant: the first record stands
  SELECT * INTO v_existing FROM saas_payments WHERE invoice_id = p_invoice_id AND lower(trim(reference)) = lower(v_ref);
  IF v_existing.id IS NULL THEN RAISE; END IF;
  RETURN jsonb_build_object('payment_id', v_existing.id, 'invoice_id', p_invoice_id, 'replayed', true);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_record_payment(UUID, NUMERIC, TEXT, TEXT, TEXT, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_record_payment(UUID, NUMERIC, TEXT, TEXT, TEXT, TIMESTAMPTZ, TEXT) TO authenticated;

-- Void an open, unpaid invoice (kept with actor + reason). A partially paid invoice is not voided in 13B.
CREATE OR REPLACE FUNCTION rpc_platform_void_invoice(p_invoice_id UUID, p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); i RECORD;
BEGIN
  IF length(trim(COALESCE(p_reason, ''))) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED: say why the invoice is voided' USING ERRCODE = '22023'; END IF;
  SELECT * INTO i FROM saas_invoices WHERE id = p_invoice_id FOR UPDATE;
  IF i.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: invoice %', p_invoice_id USING ERRCODE = 'P0002'; END IF;
  IF i.status = 'void' THEN RETURN jsonb_build_object('invoice_id', i.id, 'status', 'void', 'replayed', true); END IF;
  IF i.status <> 'open' THEN RAISE EXCEPTION 'INVALID_STATE: invoice % is %', i.invoice_number, i.status USING ERRCODE = '55000'; END IF;
  IF i.amount_paid > 0 THEN RAISE EXCEPTION 'HAS_PAYMENTS: invoice % has % recorded; a partially paid invoice cannot be voided', i.invoice_number, i.amount_paid USING ERRCODE = '55000'; END IF;
  UPDATE saas_invoices SET status = 'void', voided_at = now(), voided_by = v_admin, void_reason = trim(p_reason) WHERE id = i.id;
  INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, payload)
  VALUES (v_admin, 'void_invoice', i.business_id, jsonb_build_object('invoice_id', i.id, 'invoice_number', i.invoice_number, 'total', i.total, 'currency', i.currency, 'reason', trim(p_reason)));
  RETURN jsonb_build_object('invoice_id', i.id, 'status', 'void', 'replayed', false);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_void_invoice(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_void_invoice(UUID, TEXT) TO authenticated;

-- Cancellation: 'at_period_end' keeps the paid period and blocks renewals; 'immediate' ends now
-- (refused while an open invoice exists — void it first); 'keep' withdraws a scheduled cancellation.
CREATE OR REPLACE FUNCTION rpc_platform_cancel_subscription(p_subscription_id UUID, p_mode TEXT, p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); s RECORD;
BEGIN
  IF p_mode NOT IN ('at_period_end','immediate','keep') THEN RAISE EXCEPTION 'INVALID_MODE: %', p_mode USING ERRCODE = '22023'; END IF;
  IF length(trim(COALESCE(p_reason, ''))) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED: say why' USING ERRCODE = '22023'; END IF;
  SELECT * INTO s FROM business_subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: subscription %', p_subscription_id USING ERRCODE = 'P0002'; END IF;
  IF s.status IN ('cancelled','expired') THEN RAISE EXCEPTION 'INVALID_STATE: subscription is %', s.status USING ERRCODE = '55000'; END IF;
  IF p_mode = 'immediate' THEN
    IF EXISTS (SELECT 1 FROM saas_invoices WHERE subscription_id = s.id AND status = 'open') THEN
      RAISE EXCEPTION 'OPEN_INVOICE: void the open invoice before cancelling immediately' USING ERRCODE = '55000';
    END IF;
    UPDATE business_subscriptions SET status = 'cancelled', cancelled_at = now(), renews_at = NULL, cancel_at_period_end = false,
                                      note = trim(p_reason), updated_at = now() WHERE id = s.id;
  ELSIF p_mode = 'at_period_end' THEN
    UPDATE business_subscriptions SET cancel_at_period_end = true, renews_at = NULL, note = trim(p_reason), updated_at = now() WHERE id = s.id;
  ELSE
    UPDATE business_subscriptions SET cancel_at_period_end = false, renews_at = ends_at, note = trim(p_reason), updated_at = now() WHERE id = s.id;
  END IF;
  INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, payload)
  VALUES (v_admin, 'cancel_subscription', s.business_id, jsonb_build_object('subscription_id', s.id, 'mode', p_mode, 'from', s.status,
          'to', CASE WHEN p_mode = 'immediate' THEN 'cancelled' ELSE s.status::text END, 'reason', trim(p_reason)));
  RETURN jsonb_build_object('subscription_id', s.id, 'mode', p_mode, 'status', CASE WHEN p_mode = 'immediate' THEN 'cancelled' ELSE s.status::text END,
                            'cancel_at_period_end', (p_mode = 'at_period_end'));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_cancel_subscription(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_cancel_subscription(UUID, TEXT, TEXT) TO authenticated;

-- Manual subscription state, narrowed: activation now happens only by paying the invoice.
CREATE OR REPLACE FUNCTION rpc_platform_set_subscription_status(p_subscription_id UUID, p_status TEXT, p_note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); s RECORD; v_new subscription_status;
BEGIN
  BEGIN v_new := p_status::subscription_status; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_STATUS: %', p_status USING ERRCODE = '22023'; END;
  SELECT * INTO s FROM business_subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: subscription %', p_subscription_id USING ERRCODE = 'P0002'; END IF;
  IF s.status IN ('cancelled','expired') THEN RAISE EXCEPTION 'INVALID_STATE: subscription is %', s.status USING ERRCODE = '55000'; END IF;
  IF v_new = 'active' THEN RAISE EXCEPTION 'USE_PAYMENT: a subscription becomes active when its invoice is paid (rpc_platform_record_payment)' USING ERRCODE = '55000'; END IF;
  IF v_new = 'cancelled' AND EXISTS (SELECT 1 FROM saas_invoices WHERE subscription_id = s.id AND status = 'open') THEN
    RAISE EXCEPTION 'OPEN_INVOICE: void the open invoice before cancelling' USING ERRCODE = '55000';
  END IF;
  UPDATE business_subscriptions SET
    status = v_new,
    cancelled_at = CASE WHEN v_new = 'cancelled' THEN now() ELSE cancelled_at END,
    renews_at = CASE WHEN v_new IN ('cancelled','expired') THEN NULL ELSE renews_at END,
    note = COALESCE(NULLIF(trim(COALESCE(p_note, '')), ''), note), updated_at = now()
  WHERE id = s.id;
  INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, payload)
  VALUES (v_admin, 'set_subscription_status', s.business_id, jsonb_build_object('subscription_id', s.id, 'from', s.status, 'to', v_new, 'note', p_note));
  RETURN jsonb_build_object('subscription_id', s.id, 'status', v_new);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_set_subscription_status(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_set_subscription_status(UUID, TEXT, TEXT) TO authenticated;

-- Materialise what the reads already derive, when the platform asks: active → past_due for an
-- overdue open invoice; scheduled cancellations whose period ended → cancelled. Nothing else.
CREATE OR REPLACE FUNCTION rpc_platform_billing_sweep()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); r RECORD; v_past INTEGER := 0; v_cancel INTEGER := 0;
BEGIN
  FOR r IN SELECT s.id, s.business_id, s.status FROM business_subscriptions s
           WHERE s.status = 'active' AND EXISTS (SELECT 1 FROM saas_invoices i WHERE i.subscription_id = s.id AND i.status = 'open' AND i.due_at < now())
           ORDER BY s.id FOR UPDATE OF s LOOP
    UPDATE business_subscriptions SET status = 'past_due', updated_at = now() WHERE id = r.id;
    INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, payload)
    VALUES (v_admin, 'billing_sweep', r.business_id, jsonb_build_object('subscription_id', r.id, 'from', r.status, 'to', 'past_due', 'reason', 'overdue invoice'));
    v_past := v_past + 1;
  END LOOP;
  FOR r IN SELECT s.id, s.business_id, s.status FROM business_subscriptions s
           WHERE s.status IN ('active','past_due') AND s.cancel_at_period_end AND s.ends_at IS NOT NULL AND s.ends_at <= now()
           ORDER BY s.id FOR UPDATE OF s LOOP
    UPDATE business_subscriptions SET status = 'cancelled', cancelled_at = now(), renews_at = NULL, updated_at = now() WHERE id = r.id;
    INSERT INTO platform_audit_log (admin_user_id, action, target_business_id, payload)
    VALUES (v_admin, 'billing_sweep', r.business_id, jsonb_build_object('subscription_id', r.id, 'from', r.status, 'to', 'cancelled', 'reason', 'period ended after scheduled cancellation'));
    v_cancel := v_cancel + 1;
  END LOOP;
  RETURN jsonb_build_object('marked_past_due', v_past, 'cancelled_at_period_end', v_cancel);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_billing_sweep() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_billing_sweep() TO authenticated;

CREATE OR REPLACE FUNCTION rpc_platform_set_billing_setting(p_key TEXT, p_value INTEGER)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin();
BEGIN
  IF p_key NOT IN ('invoice_due_days','billing_grace_days') THEN RAISE EXCEPTION 'INVALID_SETTING: %', p_key USING ERRCODE = '22023'; END IF;
  IF p_value IS NULL OR p_value < 0 OR p_value > 365 THEN RAISE EXCEPTION 'INVALID_VALUE: % must be 0–365 days', p_key USING ERRCODE = '22023'; END IF;
  INSERT INTO platform_settings (key, value, updated_by) VALUES (p_key, to_jsonb(p_value), v_admin)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by;
  INSERT INTO platform_audit_log (admin_user_id, action, payload) VALUES (v_admin, 'set_billing_setting', jsonb_build_object('key', p_key, 'to', p_value));
  RETURN jsonb_build_object('key', p_key, 'value', p_value);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_set_billing_setting(TEXT, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_set_billing_setting(TEXT, INTEGER) TO authenticated;

-- ------------------------------------------------------------ platform reads (bounded, paginated)
CREATE OR REPLACE FUNCTION rpc_platform_billing_overview()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v JSONB;
BEGIN
  SELECT jsonb_build_object(
    'settings', jsonb_build_object('invoice_due_days', fn_saas_setting_int('invoice_due_days', 14), 'billing_grace_days', fn_saas_setting_int('billing_grace_days', 14)),
    'invoices', jsonb_build_object(
      'open', (SELECT count(*) FROM saas_invoices WHERE status = 'open'),
      'overdue', (SELECT count(*) FROM saas_invoices WHERE status = 'open' AND due_at < now()),
      'paid_30d', (SELECT count(*) FROM saas_invoices WHERE status = 'paid' AND paid_at >= now() - interval '30 days'),
      'void', (SELECT count(*) FROM saas_invoices WHERE status = 'void')),
    'open_totals', (SELECT COALESCE(jsonb_object_agg(currency, t), '{}'::jsonb) FROM (SELECT currency, sum(total - amount_paid) t FROM saas_invoices WHERE status = 'open' GROUP BY currency) x),
    'paid_30d_totals', (SELECT COALESCE(jsonb_object_agg(currency, t), '{}'::jsonb) FROM (SELECT currency, sum(amount) t FROM saas_payments WHERE paid_at >= now() - interval '30 days' GROUP BY currency) x),
    'subscriptions', (SELECT COALESCE(jsonb_object_agg(status, n), '{}'::jsonb) FROM (SELECT status, count(*) n FROM business_subscriptions GROUP BY status) x),
    'awaiting_first_invoice', (SELECT count(*) FROM business_subscriptions s WHERE s.status = 'pending' AND NOT EXISTS (SELECT 1 FROM saas_invoices i WHERE i.subscription_id = s.id AND i.status <> 'void')),
    'renewal_due_30d', (SELECT count(*) FROM business_subscriptions s WHERE s.status = 'active' AND NOT s.cancel_at_period_end AND s.ends_at <= now() + interval '30 days'
                        AND NOT EXISTS (SELECT 1 FROM saas_invoices i WHERE i.subscription_id = s.id AND i.status <> 'void' AND i.billing_period_start >= s.ends_at)),
    'lapsed', (SELECT count(*) FROM business_subscriptions s WHERE s.status IN ('active','past_due') AND s.ends_at < now()),
    'scheduled_cancellations', (SELECT count(*) FROM business_subscriptions WHERE cancel_at_period_end AND status IN ('active','past_due')))
  INTO v;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_billing_overview() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_billing_overview() TO authenticated;

-- Filtered invoice set shared by the count and the page (STABLE, no temp tables).
CREATE OR REPLACE FUNCTION fn_saas_invoices_filtered(p_status TEXT, p_q TEXT)
RETURNS SETOF saas_invoices LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT i.* FROM saas_invoices i JOIN businesses b ON b.id = i.business_id
  WHERE (p_status IS NULL OR (p_status = 'overdue' AND i.status = 'open' AND i.due_at < now()) OR (p_status <> 'overdue' AND i.status::text = p_status))
    AND (p_q IS NULL OR i.invoice_number ILIKE '%' || p_q || '%' OR b.name ILIKE '%' || p_q || '%' OR b.code ILIKE '%' || p_q || '%');
$$;
REVOKE EXECUTE ON FUNCTION fn_saas_invoices_filtered(TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- p_status: open | overdue | paid | void | NULL (all). p_q matches invoice number, business name or code.
CREATE OR REPLACE FUNCTION rpc_platform_invoices(p_status TEXT DEFAULT NULL, p_q TEXT DEFAULT NULL, p_limit INTEGER DEFAULT 50, p_offset INTEGER DEFAULT 0)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v_rows JSONB; v_total BIGINT; v_lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
        v_off INTEGER := GREATEST(COALESCE(p_offset, 0), 0); v_q TEXT := NULLIF(trim(COALESCE(p_q, '')), '');
BEGIN
  IF p_status IS NOT NULL AND p_status NOT IN ('open','overdue','paid','void') THEN RAISE EXCEPTION 'INVALID_STATUS: %', p_status USING ERRCODE = '22023'; END IF;
  SELECT count(*) INTO v_total FROM fn_saas_invoices_filtered(p_status, v_q);
  SELECT COALESCE(jsonb_agg(fn_saas_invoice_json(i) || jsonb_build_object('business', jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code), 'subscription_id', i.subscription_id)
                            ORDER BY i.issued_at DESC, i.invoice_number DESC), '[]'::jsonb)
  INTO v_rows
  FROM (SELECT id FROM fn_saas_invoices_filtered(p_status, v_q) ORDER BY issued_at DESC, invoice_number DESC LIMIT v_lim OFFSET v_off) pg
  JOIN saas_invoices i ON i.id = pg.id JOIN businesses b ON b.id = i.business_id;
  RETURN jsonb_build_object('rows', v_rows, 'total', v_total, 'limit', v_lim, 'offset', v_off);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_invoices(TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_invoices(TEXT, TEXT, INTEGER, INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_platform_invoice_detail(p_invoice_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v JSONB;
BEGIN
  SELECT fn_saas_invoice_json(i) || jsonb_build_object(
           'business', jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code, 'status', b.status),
           'subscription', fn_saas_subscription_json(s),
           'issued_by', (SELECT COALESCE(pr.full_name, u.email) FROM profiles pr LEFT JOIN auth.users u ON u.id = pr.id WHERE pr.id = i.issued_by),
           'voided_by', (SELECT COALESCE(pr.full_name, u.email) FROM profiles pr LEFT JOIN auth.users u ON u.id = pr.id WHERE pr.id = i.voided_by),
           'items', (SELECT COALESCE(jsonb_agg(jsonb_build_object('line_no', it.line_no, 'description', it.description, 'quantity', it.quantity, 'unit_amount', it.unit_amount, 'line_total', it.line_total) ORDER BY it.line_no), '[]'::jsonb)
                     FROM saas_invoice_items it WHERE it.invoice_id = i.id),
           'payments', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', p.id, 'amount', p.amount, 'currency', p.currency, 'method', p.method, 'status', p.status, 'reference', p.reference,
                                                                     'paid_at', p.paid_at, 'note', p.note, 'recorded_at', p.created_at,
                                                                     'recorded_by', (SELECT COALESCE(pr.full_name, u.email) FROM profiles pr LEFT JOIN auth.users u ON u.id = pr.id WHERE pr.id = p.recorded_by))
                                                  ORDER BY p.paid_at, p.created_at), '[]'::jsonb)
                        FROM saas_payments p WHERE p.invoice_id = i.id))
  INTO v
  FROM saas_invoices i JOIN businesses b ON b.id = i.business_id JOIN business_subscriptions s ON s.id = i.subscription_id
  WHERE i.id = p_invoice_id;
  IF v IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: invoice %', p_invoice_id USING ERRCODE = 'P0002'; END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_invoice_detail(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_invoice_detail(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_saas_subscriptions_filtered(p_status TEXT, p_q TEXT)
RETURNS SETOF business_subscriptions LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT s.* FROM business_subscriptions s JOIN businesses b ON b.id = s.business_id
  WHERE (p_status IS NULL OR (p_status = 'lapsed' AND s.status IN ('active','past_due') AND s.ends_at < now()) OR (p_status <> 'lapsed' AND s.status::text = p_status))
    AND (p_q IS NULL OR b.name ILIKE '%' || p_q || '%' OR b.code ILIKE '%' || p_q || '%');
$$;
REVOKE EXECUTE ON FUNCTION fn_saas_subscriptions_filtered(TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- p_status: pending | active | past_due | cancelled | expired | lapsed | NULL. p_q matches business name / code.
CREATE OR REPLACE FUNCTION rpc_platform_subscriptions(p_status TEXT DEFAULT NULL, p_q TEXT DEFAULT NULL, p_limit INTEGER DEFAULT 50, p_offset INTEGER DEFAULT 0)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v_rows JSONB; v_total BIGINT; v_lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
        v_off INTEGER := GREATEST(COALESCE(p_offset, 0), 0); v_q TEXT := NULLIF(trim(COALESCE(p_q, '')), '');
BEGIN
  IF p_status IS NOT NULL AND p_status NOT IN ('pending','active','past_due','cancelled','expired','lapsed') THEN RAISE EXCEPTION 'INVALID_STATUS: %', p_status USING ERRCODE = '22023'; END IF;
  SELECT count(*) INTO v_total FROM fn_saas_subscriptions_filtered(p_status, v_q);
  SELECT COALESCE(jsonb_agg(fn_saas_subscription_json(s) || jsonb_build_object(
           'business', jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code, 'status', b.status),
           'latest_invoice', (SELECT jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'status', i.status, 'total', i.total, 'currency', i.currency,
                                                        'amount_paid', i.amount_paid, 'due_at', i.due_at, 'overdue', (i.status = 'open' AND i.due_at < now()))
                              FROM saas_invoices i WHERE i.subscription_id = s.id AND i.status <> 'void' ORDER BY i.billing_period_start DESC, i.invoice_number DESC LIMIT 1),
           'invoice_count', (SELECT count(*) FROM saas_invoices i WHERE i.subscription_id = s.id AND i.status <> 'void'))
           ORDER BY s.created_at DESC, s.id DESC), '[]'::jsonb)
  INTO v_rows
  FROM (SELECT id FROM fn_saas_subscriptions_filtered(p_status, v_q) ORDER BY created_at DESC, id DESC LIMIT v_lim OFFSET v_off) pg
  JOIN business_subscriptions s ON s.id = pg.id JOIN businesses b ON b.id = s.business_id;
  RETURN jsonb_build_object('rows', v_rows, 'total', v_total, 'limit', v_lim, 'offset', v_off);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_subscriptions(TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_subscriptions(TEXT, TEXT, INTEGER, INTEGER) TO authenticated;

-- Business detail gains the billing facts of each subscription (same signature, body only).
CREATE OR REPLACE FUNCTION rpc_platform_business_detail(p_business_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_admin UUID := fn_require_platform_admin(); v JSONB;
BEGIN
  SELECT jsonb_build_object(
           'id', b.id, 'name', b.name, 'code', b.code, 'status', b.status, 'base_currency', b.base_currency, 'created_at', b.created_at,
           'timezone', b.settings ->> 'timezone',
           'owners', (SELECT COALESCE(jsonb_agg(jsonb_build_object('name', pr.full_name, 'email', u.email) ORDER BY u.email), '[]'::jsonb)
                      FROM business_members m LEFT JOIN profiles pr ON pr.id = m.user_id LEFT JOIN auth.users u ON u.id = m.user_id
                      WHERE m.business_id = b.id AND m.is_active AND m.role = 'owner'),
           'members', (SELECT count(*) FROM business_members m WHERE m.business_id = b.id AND m.is_active),
           'branches', (SELECT count(*) FROM branches br WHERE br.business_id = b.id AND br.status = 'active'),
           'subscriptions', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', s.id, 'status', s.status, 'plan', p.name, 'plan_code', p.code, 'price_amount', p.price_amount, 'currency', p.currency,
                                                                          'billing_interval', p.billing_interval, 'starts_at', s.starts_at, 'ends_at', s.ends_at, 'renews_at', s.renews_at, 'activated_at', s.activated_at, 'cancelled_at', s.cancelled_at, 'source', s.source, 'note', s.note,
                                                                          'cancel_at_period_end', s.cancel_at_period_end,
                                                                          'lapsed', (s.status IN ('active','past_due') AND s.ends_at IS NOT NULL AND s.ends_at < now()),
                                                                          'latest_invoice', (SELECT jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'status', i.status, 'total', i.total, 'currency', i.currency,
                                                                                                                       'amount_paid', i.amount_paid, 'due_at', i.due_at, 'overdue', (i.status = 'open' AND i.due_at < now()),
                                                                                                                       'billing_period_start', i.billing_period_start, 'billing_period_end', i.billing_period_end)
                                                                                             FROM saas_invoices i WHERE i.subscription_id = s.id AND i.status <> 'void' ORDER BY i.billing_period_start DESC, i.invoice_number DESC LIMIT 1),
                                                                          'invoice_count', (SELECT count(*) FROM saas_invoices i WHERE i.subscription_id = s.id AND i.status <> 'void'))
                                                       ORDER BY s.created_at DESC), '[]'::jsonb)
                             FROM business_subscriptions s JOIN saas_plans p ON p.id = s.plan_id WHERE s.business_id = b.id),
           'application', (SELECT jsonb_build_object('id', a.id, 'status', a.status, 'submitted_at', a.submitted_at) FROM business_applications a WHERE a.business_id = b.id ORDER BY a.submitted_at DESC LIMIT 1),
           'audit', (SELECT COALESCE(jsonb_agg(jsonb_build_object('at', l.occurred_at, 'action', l.action, 'admin', COALESCE(pa.full_name, ua.email), 'payload', l.payload) ORDER BY l.occurred_at DESC), '[]'::jsonb)
                     FROM (SELECT * FROM platform_audit_log WHERE target_business_id = b.id ORDER BY occurred_at DESC LIMIT 50) l
                     LEFT JOIN profiles pa ON pa.id = l.admin_user_id LEFT JOIN auth.users ua ON ua.id = l.admin_user_id))
  INTO v FROM businesses b WHERE b.id = p_business_id;
  IF v IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: business %', p_business_id USING ERRCODE = 'P0002'; END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_platform_business_detail(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_platform_business_detail(UUID) TO authenticated;

-- ------------------------------------------------------------ tenant read (owner only)
-- The owner's own commercial record: subscription, invoices (bounded), payments. No provider
-- references, no platform actors. Managers and staff have no SaaS billing surface.
CREATE OR REPLACE FUNCTION rpc_my_billing(p_business_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v JSONB;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner']::user_role[]);
  SELECT jsonb_build_object(
    'subscription', (SELECT fn_saas_subscription_json(s) FROM business_subscriptions s WHERE s.business_id = p_business_id ORDER BY s.created_at DESC LIMIT 1),
    'invoices', (SELECT COALESCE(jsonb_agg(fn_saas_invoice_json(i) || jsonb_build_object(
                   'payments', (SELECT COALESCE(jsonb_agg(jsonb_build_object('amount', p.amount, 'currency', p.currency, 'method', p.method, 'paid_at', p.paid_at, 'reference', p.reference) ORDER BY p.paid_at), '[]'::jsonb)
                                FROM saas_payments p WHERE p.invoice_id = i.id))
                   ORDER BY i.issued_at DESC, i.invoice_number DESC), '[]'::jsonb)
                 FROM (SELECT id FROM saas_invoices WHERE business_id = p_business_id ORDER BY issued_at DESC, invoice_number DESC LIMIT 24) pg JOIN saas_invoices i ON i.id = pg.id),
    'settings', jsonb_build_object('billing_grace_days', fn_saas_setting_int('billing_grace_days', 14)))
  INTO v;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_my_billing(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_my_billing(UUID) TO authenticated;

-- ============================================================
-- END phase 13B
-- ============================================================
