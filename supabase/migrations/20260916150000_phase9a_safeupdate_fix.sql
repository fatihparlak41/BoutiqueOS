-- ============================================================
-- Phase 9A — safeupdate fix for the sale and return cores
-- ============================================================
-- Found in the live ZZ POS smoke: every rpc_pos_complete_sale / rpc_process_sale failed with
--   21000  DELETE requires a WHERE clause
-- Supabase runs pg-safeupdate for API sessions, and the setting follows the session into
-- SECURITY DEFINER functions. The Rev 3 cores clear their scratch temp table with a bare
-- `DELETE FROM _sale_lines;` / `DELETE FROM _return_lines;` — legal PostgreSQL, refused on
-- Supabase. The local harness has no safeupdate, so the 911-assertion gate never saw it;
-- tools/lint_sql.py now flags a WHERE-less DELETE/UPDATE in the latest definition of any
-- function. Sales were never exercised live before Phase 9A (Faz 3 smoke covered suppliers,
-- receiving and stock), which is why the bug survived until now.
--
-- Both bodies below are verbatim copies of their latest definitions (fn_sale_core from
-- 20260916140000, fn_return_core from 20260908000004) with `WHERE true` on that one line.
-- ============================================================

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
  DELETE FROM _sale_lines WHERE true;   -- pg-safeupdate: a bare DELETE is refused on Supabase
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

CREATE OR REPLACE FUNCTION fn_return_core(
  p_business_id UUID, p_branch_id UUID, p_sale_id UUID, p_items JSONB,
  p_return_type return_type, p_reason TEXT, p_note TEXT,
  p_exchange_group_id UUID, p_replacement_sale_id UUID,
  p_register_session_id UUID, p_refund_method payment_method
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor UUID := fn_actor(); v_role user_role; s RECORD; it RECORD; si RECORD; sic RECORD; pr t_cost_pool_result;
  v_window INT; v_money BOOLEAN; v_store BOOLEAN; v_ret_id UUID := gen_random_uuid(); v_num TEXT;
  v_credit NUMERIC := 0; v_returned INT; v_disp inventory_bucket; v_final BOOLEAN; v_vids UUID[]; v_ri_id UUID;
  v_refund NUMERIC := 0;
BEGIN
  v_role := fn_require_member(p_business_id);
  PERFORM fn_assert_branch(p_business_id, p_branch_id);

  v_window := (fn_setting(p_business_id, 'exchange_window_days'))::TEXT::INT;
  v_money  := (fn_setting(p_business_id, 'money_refund_allowed'))::TEXT::BOOLEAN;
  v_store  := (fn_setting(p_business_id, 'store_credit_allowed'))::TEXT::BOOLEAN;

  IF p_return_type = 'refund' AND NOT v_money THEN
    RAISE EXCEPTION 'REFUND_NOT_ALLOWED: money refunds are disabled for this business (any method)' USING ERRCODE='55000';
  END IF;
  IF p_return_type = 'store_credit' THEN
    IF NOT v_store THEN RAISE EXCEPTION 'STORE_CREDIT_NOT_ALLOWED: store credit is disabled for this business' USING ERRCODE='55000'; END IF;
    RAISE EXCEPTION 'NOT_IMPLEMENTED: store credit ledger is not part of V1' USING ERRCODE='0A000';
  END IF;

  SELECT * INTO s FROM sales WHERE id = p_sale_id AND business_id = p_business_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: sale %', p_sale_id USING ERRCODE='P0002'; END IF;
  IF s.branch_id <> p_branch_id THEN RAISE EXCEPTION 'BRANCH_MISMATCH: sale % belongs to another branch', p_sale_id USING ERRCODE='22023'; END IF;
  IF s.status <> 'completed' THEN RAISE EXCEPTION 'INVALID_STATE: sale % is %', p_sale_id, s.status USING ERRCODE='55000'; END IF;
  IF now() > s.occurred_at + make_interval(days => v_window) THEN
    RAISE EXCEPTION 'EXCHANGE_WINDOW_EXPIRED: sale % sold at %, window % days', p_sale_id, s.occurred_at, v_window USING ERRCODE='55000';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_RETURN: no items' USING ERRCODE='22023';
  END IF;

  SELECT array_agg(DISTINCT x.variant_id ORDER BY x.variant_id) INTO v_vids
  FROM jsonb_array_elements(p_items) e JOIN sale_items x ON x.id = (e->>'sale_item_id')::UUID AND x.sale_id = p_sale_id;
  IF v_vids IS NULL THEN RAISE EXCEPTION 'INVALID_ITEM: sale_item not on sale %', p_sale_id USING ERRCODE='22023'; END IF;
  PERFORM fn_lock_pools(p_business_id, p_branch_id, v_vids);

  -- PASS 1: validate every line under sale_item locks and accumulate (no writes yet)
  CREATE TEMP TABLE IF NOT EXISTS _return_lines (
    sale_item_id UUID, variant_id UUID, qty INT, disp inventory_bucket, unit_price NUMERIC, unit_cost NUMERIC, reason TEXT
  ) ON COMMIT DROP;
  DELETE FROM _return_lines WHERE true;   -- pg-safeupdate: a bare DELETE is refused on Supabase

  FOR it IN SELECT (e->>'sale_item_id')::UUID AS sale_item_id, (e->>'quantity')::INT AS qty,
                   (e->>'disposition')::inventory_bucket AS disp, e->>'reason' AS reason
            FROM jsonb_array_elements(p_items) e ORDER BY (e->>'sale_item_id')::UUID LOOP
    IF it.qty IS NULL OR it.qty <= 0 THEN RAISE EXCEPTION 'INVALID_QTY: quantity must be > 0' USING ERRCODE='22023'; END IF;
    IF EXISTS (SELECT 1 FROM _return_lines WHERE sale_item_id = it.sale_item_id) THEN
      RAISE EXCEPTION 'DUPLICATE_ITEM: sale_item % listed twice', it.sale_item_id USING ERRCODE='22023';
    END IF;

    SELECT * INTO si FROM sale_items WHERE id = it.sale_item_id AND sale_id = p_sale_id FOR UPDATE;   -- serialises returns per line
    IF si.id IS NULL THEN RAISE EXCEPTION 'INVALID_ITEM: sale_item % not on sale %', it.sale_item_id, p_sale_id USING ERRCODE='22023'; END IF;

    SELECT COALESCE(c.is_final_sale, false) INTO v_final
    FROM product_variants pv JOIN products p ON p.id = pv.product_id LEFT JOIN categories c ON c.id = p.category_id
    WHERE pv.id = si.variant_id;
    IF v_final THEN RAISE EXCEPTION 'FINAL_SALE: variant % cannot be returned or exchanged', si.variant_id USING ERRCODE='55000'; END IF;

    SELECT COALESCE(SUM(quantity), 0) INTO v_returned FROM return_items WHERE sale_item_id = si.id;
    IF v_returned + it.qty > si.quantity THEN
      RAISE EXCEPTION 'OVER_RETURN: sale_item % sold=% already_returned=% requested=%', si.id, si.quantity, v_returned, it.qty USING ERRCODE='55000';
    END IF;

    -- J-1 disposition: default quarantine; sellable/damaged only for owner/manager
    v_disp := COALESCE(it.disp, 'quarantine');
    IF v_disp <> 'quarantine' AND NOT (v_role IN ('owner','manager')) THEN
      RAISE EXCEPTION 'DISPOSITION_NOT_AUTHORIZED: % may only return to quarantine', v_role USING ERRCODE='42501';
    END IF;

    SELECT * INTO sic FROM sale_item_costs WHERE sale_item_id = si.id;
    IF sic.sale_item_id IS NULL THEN RAISE EXCEPTION 'INTEGRITY: missing cost snapshot for sale_item %', si.id USING ERRCODE='23000'; END IF;

    INSERT INTO _return_lines VALUES (si.id, si.variant_id, it.qty, v_disp, si.unit_price_at_sale, sic.unit_cost_at_sale, it.reason);
    v_credit := v_credit + si.unit_price_at_sale * it.qty;
  END LOOP;
  v_credit := round(v_credit, 2);

  IF p_return_type = 'refund' THEN
    -- only reachable when money_refund_allowed = true
    IF p_refund_method IS NULL THEN RAISE EXCEPTION 'REFUND_METHOD_REQUIRED' USING ERRCODE='22023'; END IF;
    v_refund := v_credit;
    IF p_refund_method = 'cash' AND (p_register_session_id IS NULL OR NOT EXISTS (
         SELECT 1 FROM register_sessions WHERE id = p_register_session_id AND business_id = p_business_id
           AND branch_id = p_branch_id AND status = 'open')) THEN
      RAISE EXCEPTION 'REGISTER_REQUIRED: cash refund needs an open register session' USING ERRCODE='22023';
    END IF;
  END IF;

  -- PASS 2: header written ONCE with final values (returns are immutable)
  v_num := fn_next_sequence(p_business_id, 'R');
  INSERT INTO returns (id, business_id, branch_id, original_sale_id, return_number, return_type, customer_id,
                       credit_value_base, refund_amount_base, refund_method, exchange_group_id, replacement_sale_id,
                       reason, note, processed_by)
  VALUES (v_ret_id, p_business_id, p_branch_id, p_sale_id, v_num, p_return_type, s.customer_id,
          v_credit, v_refund, CASE WHEN p_return_type = 'refund' THEN p_refund_method END,
          p_exchange_group_id, p_replacement_sale_id, p_reason, p_note, v_actor);

  -- PASS 3: items, pool re-entry at ORIGINAL unit_cost_at_sale, ledger
  FOR it IN SELECT * FROM _return_lines ORDER BY variant_id, sale_item_id LOOP
    v_ri_id := gen_random_uuid();
    INSERT INTO return_items (id, return_id, sale_item_id, variant_id, quantity, disposition, unit_price_at_sale, reason)
    VALUES (v_ri_id, v_ret_id, it.sale_item_id, it.variant_id, it.qty, it.disp, it.unit_price, it.reason);
    pr := fn_post_to_cost_pool(p_business_id, p_branch_id, it.variant_id, it.qty, it.unit_cost, NULL);
    PERFORM fn_ledger_post(p_business_id, p_branch_id, it.variant_id, it.disp, it.qty, 'customer_return',
                           'return_item', v_ri_id, pr.unit_cost_used, pr.value_delta_base, it.reason, now(), v_actor);
  END LOOP;

  IF p_return_type = 'refund' AND p_refund_method = 'cash' THEN
    INSERT INTO cash_movements (business_id, register_session_id, movement_type, currency, amount, exchange_rate,
                                reference_type, reference_id, note, created_by)
    VALUES (p_business_id, p_register_session_id, 'refund_cash_out', 'TRY', -v_refund, 1, 'return', v_ret_id, p_reason, v_actor);
  END IF;

  RETURN jsonb_build_object('return_id', v_ret_id, 'return_number', v_num, 'credit_value_base', v_credit, 'refund_amount_base', v_refund);
END $$;
REVOKE EXECUTE ON FUNCTION fn_return_core(UUID,UUID,UUID,JSONB,return_type,TEXT,TEXT,UUID,UUID,UUID,payment_method) FROM PUBLIC, anon, authenticated;
