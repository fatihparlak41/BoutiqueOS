-- ============================================================
-- Phase 9A — POS foundation
-- ============================================================
-- Audit of the Rev 3 sales architecture (003 / 004 / 3.5E):
--   CURRENT   sales (completed on insert, full void only, client_transaction_id +
--             fingerprint idempotency), sale_items (server-resolved list_price,
--             unit_price_at_sale, line discount), sale_item_costs / sale_costs (manager+,
--             pre-movement MWA captured at sale time), sale_payments (cash / card /
--             bank_transfer / other, per-currency FX, split allowed, exact settlement with
--             cash change only), cash_registers, register_sessions (one open per register,
--             closed sessions frozen), register_session_currency_counts, cash_movements,
--             customers (optional), reservations (AVAILABLE = sellable − active
--             reservations), fn_sale_core: membership → idempotency → session/branch →
--             pool locks (variant order) → server price / discount authority
--             (business_members.max_discount_pct, role) → availability under lock →
--             sale + items + ledger + COGS + payments + cash drawer, all in one
--             transaction. Immutability triggers on every sales table; sales visibility
--             scope 'own' | 'branch' | 'business' (3.5E).
--   REQUIRED  cashier ≠ salesperson attribution; stock_staff must not complete sales;
--             a POS entry point that cannot be handed a foreign business/branch; a
--             session an assigned cashier can see even when a manager opened it; a
--             staff-safe member name list for attribution and receipts; an optional
--             device reference on registers.
--   IMPACT    additive. No accounting or inventory primitive is rewritten:
--             fn_post_to_cost_pool, fn_ledger_post, fn_lock_pools, fn_reserved_qty and
--             the sale core's pricing/payment logic are kept verbatim. fn_sale_core gains
--             one parameter (salesperson) and one role rule; the 16-argument signature
--             stays as a wrapper so rpc_process_sale / rpc_process_exchange keep working.
--
-- Not started here: returns / exchanges (Rev 3 RPCs exist, no UI), reservations UI,
-- commissions, fiscal receipts, tenant discount policy beyond max_discount_pct.
-- ============================================================

-- ------------------------------------------------------------ registers: optional device reference
ALTER TABLE cash_registers ADD COLUMN device_ref TEXT;

-- ------------------------------------------------------------ sales: salesperson attribution
-- sold_by stays what it always was: the terminal actor (auth.uid()) who completed the
-- sale — the cashier. salesperson_id is who made the sale; defaults to the cashier.
ALTER TABLE sales ADD COLUMN salesperson_id UUID REFERENCES profiles(id);
UPDATE sales SET salesperson_id = sold_by WHERE salesperson_id IS NULL;
ALTER TABLE sales ALTER COLUMN salesperson_id SET NOT NULL;
CREATE INDEX idx_sales_salesperson ON sales (business_id, salesperson_id, occurred_at DESC);

-- 'own' visibility now covers the salesperson as well as the cashier.
CREATE OR REPLACE FUNCTION fn_can_see_sale_id(p_sale_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM sales s
    WHERE s.id = p_sale_id
      AND (fn_can_see_sale(s.business_id, s.sold_by, s.branch_id) OR (fn_is_member(s.business_id) AND s.salesperson_id = auth.uid())));
$$;
DROP POLICY pol_sales_select ON sales;
CREATE POLICY pol_sales_select ON sales FOR SELECT
  USING (fn_can_see_sale(business_id, sold_by, branch_id) OR (fn_is_member(business_id) AND salesperson_id = auth.uid()));

-- An OPEN drawer is operational information for whoever sells on it: a cashier must be
-- able to pick the session a manager opened. Closed sessions stay opener/closer/manager
-- only; counts and cash movements are untouched (fn_can_see_register_session_id).
DROP POLICY pol_rs_select ON register_sessions;
CREATE POLICY pol_rs_select ON register_sessions FOR SELECT
  USING (fn_is_member(business_id)
     AND (status = 'open' OR fn_is_manager_plus(business_id) OR opened_by = auth.uid() OR closed_by = auth.uid()));

-- ------------------------------------------------------------ fn_sale_core (+ salesperson, − stock_staff)
-- Verbatim copy of 004 except: (a) stock_staff is refused, (b) p_salesperson_id is
-- validated (active member, may sell) and stored, (c) the salesperson is part of the
-- idempotency fingerprint, (d) a foreign variant is refused before the pool lock (it used
-- to surface as a foreign-key error from fn_lock_pools). Everything about pricing, discounts, stock, COGS, payments,
-- change and the cash drawer is unchanged.
CREATE OR REPLACE FUNCTION fn_sale_core(
  p_business_id UUID, p_branch_id UUID, p_register_session_id UUID, p_customer_id UUID,
  p_reservation_id UUID, p_client_transaction_id UUID, p_device_id TEXT, p_occurred_at TIMESTAMPTZ,
  p_items JSONB, p_payments JSONB, p_discount_reason discount_reason, p_note TEXT,
  p_credit_applied_base NUMERIC, p_exchange_group_id UUID, p_sale_id UUID, p_fingerprint TEXT,
  p_salesperson_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor UUID := fn_actor(); v_role user_role; v_max_disc NUMERIC;
  v_sale_id UUID := COALESCE(p_sale_id, gen_random_uuid());
  v_occurred TIMESTAMPTZ := COALESCE(p_occurred_at, now());
  v_fp TEXT; v_existing RECORD; v_sess RECORD; v_res RECORD;
  v_vids UUID[]; it RECORD; v_line RECORD; pr t_cost_pool_result; v_sale_item_id UUID;
  v_accepted TEXT[];
  v_subtotal NUMERIC := 0; v_disc NUMERIC := 0; v_tax NUMERIC := 0; v_tax_excl NUMERIC := 0;
  v_total NUMERIC; v_due NUMERIC; v_credit NUMERIC := COALESCE(p_credit_applied_base, 0);
  v_cost_total NUMERIC := 0;
  pay RECORD; v_rate NUMERIC; v_fx_id UUID; v_override BOOLEAN; v_paid_base NUMERIC := 0; v_has_cash BOOLEAN := false;
  v_change NUMERIC := 0; v_sale_number TEXT; v_res_customer UUID;
  v_lines JSONB := '[]'::jsonb; v_pays JSONB := '[]'::jsonb;
  v_salesperson UUID := COALESCE(p_salesperson_id, fn_actor()); v_sp_role user_role;
BEGIN
  -- 1. auth / tenant (idempotency replay is checked immediately after membership so a retry
  --    after the register closed still returns the original result)
  v_role := fn_require_member(p_business_id);
  IF v_role = 'stock_staff' THEN
    RAISE EXCEPTION 'FORBIDDEN: role stock_staff cannot complete sales' USING ERRCODE='42501';
  END IF;
  IF v_salesperson <> v_actor THEN
    SELECT role INTO v_sp_role FROM business_members
    WHERE business_id = p_business_id AND user_id = v_salesperson AND is_active;
    IF v_sp_role IS NULL OR v_sp_role = 'stock_staff' THEN
      RAISE EXCEPTION 'INVALID_SALESPERSON: % is not an active selling member of the business', v_salesperson USING ERRCODE='22023';
    END IF;
  END IF;

  -- 2. idempotency (business-scoped, fingerprinted)
  IF p_client_transaction_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext(p_business_id::text || ':' || p_client_transaction_id::text));
    v_fp := COALESCE(p_fingerprint, encode(sha256(convert_to(
      jsonb_build_object(
        'b', p_business_id, 'br', p_branch_id, 's', p_register_session_id, 'c', p_customer_id, 'r', p_reservation_id,
        'i', (SELECT jsonb_agg(jsonb_build_object('v', e->>'variant_id', 'q', (e->>'quantity')::int, 'p', e->>'unit_price')
                              ORDER BY e->>'variant_id') FROM jsonb_array_elements(p_items) e),
        'p', (SELECT jsonb_agg(jsonb_build_object('m', e->>'method', 'cur', e->>'currency', 'a', e->>'amount', 'x', e->>'exchange_rate')
                              ORDER BY e->>'method', e->>'currency', e->>'amount') FROM jsonb_array_elements(COALESCE(p_payments,'[]'::jsonb)) e),
        'cr', v_credit, 'o', p_occurred_at, 'sp', v_salesperson
      )::text, 'UTF8')), 'hex'));
    SELECT id, sale_number, total, amount_due_base, change_given_base, request_fingerprint INTO v_existing
    FROM sales WHERE business_id = p_business_id AND client_transaction_id = p_client_transaction_id;
    IF v_existing.id IS NOT NULL THEN
      IF v_existing.request_fingerprint IS DISTINCT FROM v_fp THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: client_transaction_id % was used with a different payload', p_client_transaction_id
          USING ERRCODE='23505';
      END IF;
      RETURN jsonb_build_object('sale_id', v_existing.id, 'sale_number', v_existing.sale_number, 'total', v_existing.total,
                                'amount_due', v_existing.amount_due_base, 'change_given', v_existing.change_given_base, 'replayed', true);
    END IF;
  END IF;

  PERFORM fn_assert_branch(p_business_id, p_branch_id);
  IF p_register_session_id IS NULL THEN RAISE EXCEPTION 'REGISTER_REQUIRED: open register session required' USING ERRCODE='22023'; END IF;
  SELECT * INTO v_sess FROM register_sessions WHERE id = p_register_session_id AND business_id = p_business_id;
  IF v_sess.id IS NULL OR v_sess.branch_id <> p_branch_id THEN
    RAISE EXCEPTION 'INVALID_REGISTER_SESSION: % not in business/branch', p_register_session_id USING ERRCODE='22023';
  END IF;
  IF v_sess.status <> 'open' THEN RAISE EXCEPTION 'REGISTER_CLOSED: session % is closed', p_register_session_id USING ERRCODE='55000'; END IF;
  IF p_customer_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND business_id = p_business_id) THEN
    RAISE EXCEPTION 'INVALID_CUSTOMER: %', p_customer_id USING ERRCODE='22023';
  END IF;
  IF v_occurred > now() + interval '5 minutes' OR v_occurred < now() - interval '7 days' THEN
    RAISE EXCEPTION 'INVALID_OCCURRED_AT: % outside allowed window', v_occurred USING ERRCODE='22023';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_CART: no items' USING ERRCODE='22023';
  END IF;

  -- 3. normalise + lock pools (variant_id ASC)
  CREATE TEMP TABLE IF NOT EXISTS _sale_lines (
    variant_id UUID, qty INTEGER, exp_price NUMERIC, unit_price NUMERIC,
    list_price NUMERIC, tax_rate NUMERIC, tax_incl BOOLEAN, disc NUMERIC, tax_amt NUMERIC
  ) ON COMMIT DROP;
  DELETE FROM _sale_lines;
  INSERT INTO _sale_lines (variant_id, qty, exp_price, unit_price)
  SELECT (e->>'variant_id')::UUID, (e->>'quantity')::INTEGER, (e->>'expected_list_price')::NUMERIC, (e->>'unit_price')::NUMERIC
  FROM jsonb_array_elements(p_items) e;
  IF EXISTS (SELECT 1 FROM _sale_lines WHERE variant_id IS NULL OR qty IS NULL OR qty <= 0) THEN
    RAISE EXCEPTION 'INVALID_ITEM: variant_id and quantity>0 required' USING ERRCODE='22023';
  END IF;
  IF (SELECT count(*) FROM _sale_lines) <> (SELECT count(DISTINCT variant_id) FROM _sale_lines) THEN
    RAISE EXCEPTION 'DUPLICATE_ITEM: merge duplicate variant lines before submitting' USING ERRCODE='22023';
  END IF;
  -- a variant of another tenant is refused before any pool row could be touched
  IF EXISTS (SELECT 1 FROM _sale_lines l WHERE NOT EXISTS (SELECT 1 FROM product_variants pv WHERE pv.id = l.variant_id AND pv.business_id = p_business_id)) THEN
    RAISE EXCEPTION 'INVALID_VARIANT: cart contains a variant that is not in this business' USING ERRCODE='22023';
  END IF;
  SELECT array_agg(variant_id ORDER BY variant_id) INTO v_vids FROM _sale_lines;
  PERFORM fn_lock_pools(p_business_id, p_branch_id, v_vids);

  -- 4. reservation (lock + validate)
  IF p_reservation_id IS NOT NULL THEN
    SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id AND business_id = p_business_id FOR UPDATE;
    IF v_res.id IS NULL OR v_res.branch_id <> p_branch_id THEN
      RAISE EXCEPTION 'INVALID_RESERVATION: %', p_reservation_id USING ERRCODE='22023';
    END IF;
    IF v_res.status <> 'active' OR v_res.expires_at <= now() THEN
      RAISE EXCEPTION 'RESERVATION_NOT_ACTIVE: % status=% expires=%', p_reservation_id, v_res.status, v_res.expires_at USING ERRCODE='55000';
    END IF;
    IF EXISTS (SELECT 1 FROM reservation_items ri LEFT JOIN _sale_lines l ON l.variant_id = ri.variant_id
               WHERE ri.reservation_id = p_reservation_id AND (l.variant_id IS NULL OR l.qty < ri.quantity)) THEN
      RAISE EXCEPTION 'RESERVATION_MISMATCH: sale must include every reserved item with at least the reserved quantity' USING ERRCODE='22023';
    END IF;
    v_res_customer := v_res.customer_id;
  END IF;

  -- 5. server pricing, discount authority, availability
  SELECT max_discount_pct INTO v_max_disc FROM business_members WHERE business_id = p_business_id AND user_id = v_actor;
  FOR it IN SELECT l.*, pv.status AS vstatus, p.status AS pstatus,
                   COALESCE(pv.sale_price_override, p.default_sale_price) AS db_price, p.tax_rate AS db_tax, p.is_tax_inclusive
            FROM _sale_lines l
            LEFT JOIN product_variants pv ON pv.id = l.variant_id AND pv.business_id = p_business_id
            LEFT JOIN products p ON p.id = pv.product_id
            ORDER BY l.variant_id LOOP
    IF it.db_price IS NULL THEN RAISE EXCEPTION 'INVALID_VARIANT: % not in business', it.variant_id USING ERRCODE='22023'; END IF;
    IF it.vstatus <> 'active' OR it.pstatus <> 'active' THEN
      RAISE EXCEPTION 'VARIANT_NOT_SELLABLE: % (product/variant not active)', it.variant_id USING ERRCODE='55000';
    END IF;
    IF it.exp_price IS NOT NULL AND it.exp_price <> it.db_price THEN
      RAISE EXCEPTION 'PRICE_CHANGED: {"variant_id":"%","client_price":%,"server_price":%}', it.variant_id, it.exp_price, it.db_price
        USING ERRCODE='P0001';
    END IF;
    it.unit_price := COALESCE(it.unit_price, it.db_price);
    IF it.unit_price < 0 OR it.unit_price > it.db_price THEN
      RAISE EXCEPTION 'INVALID_PRICE: unit_price % outside [0, %] for variant %', it.unit_price, it.db_price, it.variant_id USING ERRCODE='22023';
    END IF;
    it.disc := (it.db_price - it.unit_price) * it.qty;
    IF it.disc > 0 THEN
      IF v_role = 'sales_staff' AND it.db_price > 0
         AND ((it.db_price - it.unit_price) / it.db_price * 100) > COALESCE(v_max_disc, 0) + 0.0001 THEN
        RAISE EXCEPTION 'DISCOUNT_NOT_AUTHORIZED: % pct exceeds your limit of % pct',
          round((it.db_price - it.unit_price) / it.db_price * 100, 2), COALESCE(v_max_disc, 0) USING ERRCODE='42501';
      END IF;
      IF v_role = 'stock_staff' THEN
        RAISE EXCEPTION 'DISCOUNT_NOT_AUTHORIZED: stock_staff cannot discount' USING ERRCODE='42501';
      END IF;
    END IF;
    IF it.is_tax_inclusive THEN
      it.tax_amt := round(it.unit_price * it.qty * it.db_tax / (100 + it.db_tax), 2);
    ELSE
      it.tax_amt := round(it.unit_price * it.qty * it.db_tax / 100, 2);
      v_tax_excl := v_tax_excl + it.tax_amt;
    END IF;

    -- AVAILABLE = sellable - active reservations (excluding the one being converted), under pool lock
    IF fn_bucket_qty(p_business_id, p_branch_id, it.variant_id, 'sellable')
       - fn_reserved_qty(p_business_id, p_branch_id, it.variant_id, p_reservation_id) < it.qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK: variant % available=% requested=%', it.variant_id,
        fn_bucket_qty(p_business_id, p_branch_id, it.variant_id, 'sellable') - fn_reserved_qty(p_business_id, p_branch_id, it.variant_id, p_reservation_id),
        it.qty USING ERRCODE='55000';
    END IF;

    UPDATE _sale_lines SET unit_price = it.unit_price, list_price = it.db_price, tax_rate = it.db_tax,
                           tax_incl = it.is_tax_inclusive, disc = it.disc, tax_amt = it.tax_amt
    WHERE variant_id = it.variant_id;
    v_subtotal := v_subtotal + it.db_price * it.qty;
    v_disc := v_disc + it.disc;
    v_tax := v_tax + it.tax_amt;
  END LOOP;

  v_total := round(v_subtotal - v_disc + v_tax_excl, 2);
  v_due := v_total - v_credit;
  IF v_due < 0 THEN
    RAISE EXCEPTION 'CREDIT_EXCEEDS_TOTAL: credit % exceeds sale total % (money refund not allowed)', v_credit, v_total USING ERRCODE='55000';
  END IF;

  -- 6. payments (server-resolved FX; never silent 1:1)
  v_accepted := ARRAY(SELECT jsonb_array_elements_text(fn_setting(p_business_id, 'accepted_currencies')));
  FOR pay IN SELECT (e->>'method')::payment_method AS method, COALESCE(e->>'currency','TRY') AS currency,
                    (e->>'amount')::NUMERIC AS amount, (e->>'exchange_rate')::NUMERIC AS rate_in, e->>'reference_no' AS ref
             FROM jsonb_array_elements(COALESCE(p_payments, '[]'::jsonb)) e LOOP
    IF pay.amount IS NULL OR pay.amount <= 0 THEN RAISE EXCEPTION 'INVALID_PAYMENT: amount must be > 0' USING ERRCODE='22023'; END IF;
    IF NOT (pay.currency = ANY(v_accepted)) THEN RAISE EXCEPTION 'CURRENCY_NOT_ACCEPTED: %', pay.currency USING ERRCODE='22023'; END IF;
    v_override := false; v_fx_id := NULL;
    IF pay.currency = 'TRY' THEN
      v_rate := 1;
    ELSIF pay.rate_in IS NOT NULL THEN
      IF NOT (v_role IN ('owner','manager')) THEN
        RAISE EXCEPTION 'FX_OVERRIDE_NOT_AUTHORIZED: only owner/manager may override the daily rate' USING ERRCODE='42501';
      END IF;
      IF pay.rate_in <= 0 THEN RAISE EXCEPTION 'INVALID_FX: rate must be > 0' USING ERRCODE='22023'; END IF;
      v_rate := pay.rate_in; v_override := true;
    ELSE
      SELECT f.fx_rate_id, f.rate INTO v_fx_id, v_rate FROM fn_get_fx_rate(p_business_id, pay.currency, v_occurred::date) f;
    END IF;
    v_paid_base := v_paid_base + pay.amount * v_rate;
    IF pay.method = 'cash' THEN v_has_cash := true; END IF;
    v_pays := v_pays || jsonb_build_object('method', pay.method, 'currency', pay.currency, 'amount', pay.amount,
                                           'rate', v_rate, 'fx_id', v_fx_id, 'override', v_override, 'ref', pay.ref);
  END LOOP;

  v_paid_base := round(v_paid_base, 2);
  IF v_paid_base < v_due THEN
    RAISE EXCEPTION 'PAYMENT_SHORT: paid % base, due %', v_paid_base, v_due USING ERRCODE='55000';
  ELSIF v_paid_base > v_due THEN
    IF NOT v_has_cash THEN
      RAISE EXCEPTION 'PAYMENT_MISMATCH: overpayment % without cash tender (no change possible)', v_paid_base - v_due USING ERRCODE='55000';
    END IF;
    v_change := v_paid_base - v_due;
  END IF;

  -- 7. persist (header first with final totals; nothing is updated afterwards)
  v_sale_number := fn_next_sequence(p_business_id, 'S', EXTRACT(YEAR FROM v_occurred)::INT);
  INSERT INTO sales (id, business_id, branch_id, register_session_id, sale_number, customer_id, status,
                     subtotal, discount_amount, tax_amount, total, credit_applied_base, change_given_base,
                     discount_reason, sold_by, salesperson_id, exchange_group_id, client_transaction_id, request_fingerprint,
                     device_id, occurred_at, note)
  VALUES (v_sale_id, p_business_id, p_branch_id, p_register_session_id, v_sale_number,
          COALESCE(p_customer_id, v_res_customer), 'completed',
          round(v_subtotal,2), round(v_disc,2), round(v_tax,2), v_total, round(v_credit,2), v_change,
          p_discount_reason, v_actor, v_salesperson, p_exchange_group_id, p_client_transaction_id, v_fp, p_device_id, v_occurred, p_note);

  FOR v_line IN SELECT * FROM _sale_lines ORDER BY variant_id LOOP
    v_sale_item_id := gen_random_uuid();
    INSERT INTO sale_items (id, sale_id, variant_id, quantity, list_price, unit_price_at_sale, discount_amount, tax_rate, tax_amount)
    VALUES (v_sale_item_id, v_sale_id, v_line.variant_id, v_line.qty, v_line.list_price, v_line.unit_price,
            round(v_line.disc,2), v_line.tax_rate, v_line.tax_amt);

    pr := fn_post_to_cost_pool(p_business_id, p_branch_id, v_line.variant_id, -v_line.qty, NULL, NULL);
    INSERT INTO sale_item_costs (sale_item_id, business_id, unit_cost_at_sale, line_cost_base)
    VALUES (v_sale_item_id, p_business_id, pr.unit_cost_used, -pr.value_delta_base);
    v_cost_total := v_cost_total - pr.value_delta_base;

    PERFORM fn_ledger_post(p_business_id, p_branch_id, v_line.variant_id, 'sellable', -v_line.qty, 'sale',
                           'sale_item', v_sale_item_id, pr.unit_cost_used, pr.value_delta_base, NULL, v_occurred, v_actor);
  END LOOP;

  INSERT INTO sale_costs (sale_id, business_id, total_cost_base) VALUES (v_sale_id, p_business_id, v_cost_total);

  FOR pay IN SELECT * FROM jsonb_to_recordset(v_pays)
             AS x(method payment_method, currency TEXT, amount NUMERIC, rate NUMERIC, fx_id UUID, override BOOLEAN, ref TEXT) LOOP
    INSERT INTO sale_payments (business_id, sale_id, method, currency, amount, exchange_rate, fx_rate_id, fx_overridden, reference_no)
    VALUES (p_business_id, v_sale_id, pay.method, pay.currency, pay.amount, pay.rate, pay.fx_id, pay.override, pay.ref);
    IF pay.method = 'cash' THEN
      INSERT INTO cash_movements (business_id, register_session_id, movement_type, currency, amount, exchange_rate,
                                  reference_type, reference_id, created_by)
      VALUES (p_business_id, p_register_session_id, 'sale_cash', pay.currency, pay.amount, pay.rate, 'sale', v_sale_id, v_actor);
    END IF;
  END LOOP;
  IF v_change > 0 THEN
    INSERT INTO cash_movements (business_id, register_session_id, movement_type, currency, amount, exchange_rate,
                                reference_type, reference_id, created_by)
    VALUES (p_business_id, p_register_session_id, 'change_out', 'TRY', -v_change, 1, 'sale', v_sale_id, v_actor);
  END IF;

  IF p_reservation_id IS NOT NULL THEN
    UPDATE reservations SET status = 'converted', converted_to_sale_id = v_sale_id WHERE id = p_reservation_id;
  END IF;

  IF COALESCE(p_customer_id, v_res_customer) IS NOT NULL THEN
    UPDATE customers SET total_spent = total_spent + v_total, order_count = order_count + 1, last_purchase_at = v_occurred
    WHERE id = COALESCE(p_customer_id, v_res_customer);
  END IF;

  RETURN jsonb_build_object('sale_id', v_sale_id, 'sale_number', v_sale_number, 'total', v_total,
                            'amount_due', v_due, 'change_given', v_change, 'replayed', false);
END $$;
REVOKE EXECUTE ON FUNCTION fn_sale_core(UUID,UUID,UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ,JSONB,JSONB,discount_reason,TEXT,NUMERIC,UUID,UUID,TEXT,UUID) FROM PUBLIC, anon, authenticated;

-- The 004 signature stays as a wrapper (salesperson = cashier) so rpc_process_sale and
-- rpc_process_exchange are untouched.
CREATE OR REPLACE FUNCTION fn_sale_core(
  p_business_id UUID, p_branch_id UUID, p_register_session_id UUID, p_customer_id UUID,
  p_reservation_id UUID, p_client_transaction_id UUID, p_device_id TEXT, p_occurred_at TIMESTAMPTZ,
  p_items JSONB, p_payments JSONB, p_discount_reason discount_reason, p_note TEXT,
  p_credit_applied_base NUMERIC, p_exchange_group_id UUID, p_sale_id UUID, p_fingerprint TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  RETURN fn_sale_core(p_business_id, p_branch_id, p_register_session_id, p_customer_id, p_reservation_id,
                      p_client_transaction_id, p_device_id, p_occurred_at, p_items, p_payments, p_discount_reason, p_note,
                      p_credit_applied_base, p_exchange_group_id, p_sale_id, p_fingerprint, NULL);
END $$;
REVOKE EXECUTE ON FUNCTION fn_sale_core(UUID,UUID,UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ,JSONB,JSONB,discount_reason,TEXT,NUMERIC,UUID,UUID,TEXT) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ rpc_pos_complete_sale (owner | manager | sales_staff)
-- The POS entry point. It takes no business_id and no branch_id: both come from the
-- register session, so a client cannot aim a sale at another tenant or branch — a
-- session it may not use ends in FORBIDDEN / INVALID_REGISTER_SESSION inside the core.
-- p_client_transaction_id is mandatory: a double submit replays the first result.
CREATE OR REPLACE FUNCTION rpc_pos_complete_sale(
  p_register_session_id UUID, p_items JSONB, p_payments JSONB, p_client_transaction_id UUID,
  p_customer_id UUID DEFAULT NULL, p_salesperson_id UUID DEFAULT NULL,
  p_discount_reason discount_reason DEFAULT NULL, p_note TEXT DEFAULT NULL, p_device_id TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s RECORD;
BEGIN
  IF p_client_transaction_id IS NULL THEN
    RAISE EXCEPTION 'CLIENT_TRANSACTION_REQUIRED: POS sales must carry a client_transaction_id' USING ERRCODE='22023';
  END IF;
  SELECT business_id, branch_id INTO s FROM register_sessions WHERE id = p_register_session_id;
  IF s.business_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_REGISTER_SESSION: % not found', p_register_session_id USING ERRCODE='22023';
  END IF;
  RETURN fn_sale_core(s.business_id, s.branch_id, p_register_session_id, p_customer_id, NULL,
                      p_client_transaction_id, p_device_id, NULL, p_items, p_payments, p_discount_reason, p_note,
                      0, NULL, NULL, NULL, p_salesperson_id);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_pos_complete_sale(UUID, JSONB, JSONB, UUID, UUID, UUID, discount_reason, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_pos_complete_sale(UUID, JSONB, JSONB, UUID, UUID, UUID, discount_reason, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------ rpc_pos_members (any member)
-- Name-only directory for salesperson attribution and receipts. Never role, never
-- max_discount_pct (3.5C keeps those manager+). Members who may be credited with a
-- sale: owner, manager, sales_staff.
CREATE OR REPLACE FUNCTION rpc_pos_members(p_business_id UUID)
RETURNS TABLE (user_id UUID, full_name TEXT, can_sell BOOLEAN, is_self BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, public AS $$
BEGIN
  PERFORM fn_require_member(p_business_id);
  RETURN QUERY
    SELECT m.user_id, p.full_name, (m.role IN ('owner','manager','sales_staff')) AS can_sell, (m.user_id = auth.uid()) AS is_self
    FROM business_members m JOIN profiles p ON p.id = m.user_id
    WHERE m.business_id = p_business_id AND m.is_active
    ORDER BY (m.user_id = auth.uid()) DESC, p.full_name;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_pos_members(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_pos_members(UUID) TO authenticated;

-- CREATE OR REPLACE keeps the 3.5E grants; restated so the privilege set is explicit here.
REVOKE EXECUTE ON FUNCTION fn_can_see_sale_id(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_can_see_sale_id(UUID) TO authenticated;
