-- ============================================================
-- BoutiqueOS  •  Migration 004  •  Posting RPCs
-- Rev 3  •  2026-09-08
-- ============================================================
-- ADR-13 standard for EVERY function here:
--   SECURITY DEFINER, SET search_path = pg_catalog, public,
--   actor = auth.uid(), membership + role + tenant checks first,
--   REVOKE FROM PUBLIC, anon, authenticated; GRANT TO authenticated only for rpc_* entry points.
-- fn_* functions are internal (no GRANT) and callable only through rpc_*.
--
-- Lock order (deadlock prevention):
--   1. document header row (sale/return/transfer/receipt/session)
--   2. variant_cost_pools rows, variant_id ASC (fn_lock_pools)
--   3. reservation row / sale_items rows, id ASC
-- Error codes are surfaced as 'CODE: detail' in SQLERRM for the client.
-- ============================================================

-- ============================================================
-- INTERNAL HELPERS
-- ============================================================
CREATE OR REPLACE FUNCTION fn_actor()
RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v UUID := auth.uid();
BEGIN
  IF v IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED: no auth.uid()' USING ERRCODE='42501'; END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION fn_actor() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_require_member(p_business_id UUID)
RETURNS user_role LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v user_role;
BEGIN
  SELECT role INTO v FROM business_members
  WHERE business_id = p_business_id AND user_id = fn_actor() AND is_active;
  IF v IS NULL THEN RAISE EXCEPTION 'FORBIDDEN: not an active member of business %', p_business_id USING ERRCODE='42501'; END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION fn_require_member(UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_require_role(p_business_id UUID, p_roles user_role[])
RETURNS user_role LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v user_role := fn_require_member(p_business_id);
BEGIN
  IF NOT (v = ANY(p_roles)) THEN
    RAISE EXCEPTION 'FORBIDDEN: role % not allowed (requires %)', v, p_roles USING ERRCODE='42501';
  END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION fn_require_role(UUID, user_role[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_assert_branch(p_business_id UUID, p_branch_id UUID)
RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM branches WHERE id = p_branch_id AND business_id = p_business_id AND status = 'active') THEN
    RAISE EXCEPTION 'INVALID_BRANCH: branch % not active in business %', p_branch_id, p_business_id USING ERRCODE='22023';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION fn_assert_branch(UUID, UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_assert_variant(p_business_id UUID, p_variant_id UUID)
RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM product_variants WHERE id = p_variant_id AND business_id = p_business_id) THEN
    RAISE EXCEPTION 'INVALID_VARIANT: variant % not in business %', p_variant_id, p_business_id USING ERRCODE='22023';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION fn_assert_variant(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- Race-safe document numbering: PREFIX-YYYY-000001
CREATE OR REPLACE FUNCTION fn_next_sequence(p_business_id UUID, p_prefix TEXT, p_year INT DEFAULT NULL)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_year INT := COALESCE(p_year, EXTRACT(YEAR FROM now())::INT); v_next INT;
BEGIN
  INSERT INTO document_sequences (business_id, prefix, year, last_value)
  VALUES (p_business_id, p_prefix, v_year, 1)
  ON CONFLICT (business_id, prefix, year) DO UPDATE SET last_value = document_sequences.last_value + 1
  RETURNING last_value INTO v_next;
  RETURN p_prefix || '-' || v_year::TEXT || '-' || lpad(v_next::TEXT, 6, '0');
END $$;
REVOKE EXECUTE ON FUNCTION fn_next_sequence(UUID, TEXT, INT) FROM PUBLIC, anon, authenticated;

-- Upsert + lock cost pool rows in deterministic variant_id order
CREATE OR REPLACE FUNCTION fn_lock_pools(p_business_id UUID, p_branch_id UUID, p_variant_ids UUID[])
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  INSERT INTO variant_cost_pools (business_id, branch_id, variant_id)
  SELECT p_business_id, p_branch_id, v FROM unnest(p_variant_ids) AS v
  ON CONFLICT (business_id, branch_id, variant_id) DO NOTHING;

  PERFORM 1 FROM variant_cost_pools
  WHERE business_id = p_business_id AND branch_id = p_branch_id AND variant_id = ANY(p_variant_ids)
  ORDER BY variant_id
  FOR UPDATE;
END $$;
REVOKE EXECUTE ON FUNCTION fn_lock_pools(UUID, UUID, UUID[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_bucket_qty(p_business_id UUID, p_branch_id UUID, p_variant_id UUID, p_bucket inventory_bucket)
RETURNS INTEGER LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(SUM(quantity), 0)::INTEGER FROM inventory_movements
  WHERE business_id = p_business_id AND branch_id = p_branch_id AND variant_id = p_variant_id AND bucket = p_bucket;
$$;
REVOKE EXECUTE ON FUNCTION fn_bucket_qty(UUID, UUID, UUID, inventory_bucket) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_reserved_qty(p_business_id UUID, p_branch_id UUID, p_variant_id UUID, p_exclude_reservation UUID DEFAULT NULL)
RETURNS INTEGER LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(SUM(ri.quantity), 0)::INTEGER
  FROM reservation_items ri JOIN reservations r ON r.id = ri.reservation_id
  WHERE r.business_id = p_business_id AND r.branch_id = p_branch_id AND ri.variant_id = p_variant_id
    AND r.status = 'active' AND r.expires_at > now()
    AND (p_exclude_reservation IS NULL OR r.id <> p_exclude_reservation);
$$;
REVOKE EXECUTE ON FUNCTION fn_reserved_qty(UUID, UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;

-- Ledger + cost row in one call
CREATE OR REPLACE FUNCTION fn_ledger_post(
  p_business_id UUID, p_branch_id UUID, p_variant_id UUID, p_bucket inventory_bucket,
  p_qty INTEGER, p_reason movement_reason, p_ref_type TEXT, p_ref_id UUID,
  p_unit_cost cost6, p_value_delta value6, p_note TEXT, p_occurred_at TIMESTAMPTZ, p_actor UUID
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO inventory_movements (business_id, branch_id, variant_id, bucket, quantity, reason,
                                   reference_type, reference_id, note, created_by, occurred_at)
  VALUES (p_business_id, p_branch_id, p_variant_id, p_bucket, p_qty, p_reason,
          p_ref_type, p_ref_id, p_note, p_actor, COALESCE(p_occurred_at, now()))
  RETURNING id INTO v_id;
  INSERT INTO inventory_movement_costs (movement_id, business_id, unit_cost_base, value_delta_base)
  VALUES (v_id, p_business_id, p_unit_cost, p_value_delta);
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION fn_ledger_post(UUID,UUID,UUID,inventory_bucket,INTEGER,movement_reason,TEXT,UUID,cost6,value6,TEXT,TIMESTAMPTZ,UUID) FROM PUBLIC, anon, authenticated;

-- ============================================================
-- fn_post_to_cost_pool  (the ONLY writer of variant_cost_pools)
-- ============================================================
-- Caller MUST have locked the pool row via fn_lock_pools (re-lock here is harmless).
-- Inflow  (qty>0): value_in = p_total_value_base if given else qty * p_unit_cost_base.
--                  Missing both => COST_REQUIRED (never silent zero cost).
--                  unit_cost_used = value_in / qty.
-- Outflow (qty<0): unit_cost_used = PRE-movement MWA; full depletion removes exact remaining value.
CREATE OR REPLACE FUNCTION fn_post_to_cost_pool(
  p_business_id UUID, p_branch_id UUID, p_variant_id UUID,
  p_qty_delta INTEGER,
  p_unit_cost_base NUMERIC DEFAULT NULL,
  p_total_value_base NUMERIC DEFAULT NULL
) RETURNS t_cost_pool_result
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_qty INTEGER; v_val NUMERIC; v_avg NUMERIC; v_new_qty INTEGER; v_new_val NUMERIC;
  v_delta NUMERIC; v_in NUMERIC; r t_cost_pool_result;
BEGIN
  IF p_qty_delta = 0 THEN RAISE EXCEPTION 'INVALID_QTY: zero delta' USING ERRCODE='22023'; END IF;

  INSERT INTO variant_cost_pools (business_id, branch_id, variant_id)
  VALUES (p_business_id, p_branch_id, p_variant_id)
  ON CONFLICT (business_id, branch_id, variant_id) DO NOTHING;

  SELECT on_hand_qty, total_value_base INTO v_qty, v_val
  FROM variant_cost_pools
  WHERE business_id = p_business_id AND branch_id = p_branch_id AND variant_id = p_variant_id
  FOR UPDATE;

  v_avg := CASE WHEN v_qty > 0 THEN v_val / v_qty ELSE 0 END;
  v_new_qty := v_qty + p_qty_delta;

  IF v_new_qty < 0 THEN
    RAISE EXCEPTION 'NEGATIVE_POOL: variant % branch % on_hand=% delta=%', p_variant_id, p_branch_id, v_qty, p_qty_delta
      USING ERRCODE='23514';
  END IF;

  IF p_qty_delta > 0 THEN
    v_in := COALESCE(p_total_value_base, p_qty_delta * p_unit_cost_base);
    IF v_in IS NULL OR v_in < 0 THEN
      RAISE EXCEPTION 'COST_REQUIRED: inflow for variant % needs a unit cost or total value', p_variant_id USING ERRCODE='22023';
    END IF;
    v_in := round(v_in, 6);          -- value6 precision, applied identically to pool and ledger
    v_delta := v_in;
    v_new_val := v_val + v_in;
    r.unit_cost_used := (v_in / p_qty_delta)::cost6;
  ELSE
    IF v_new_qty = 0 THEN
      v_delta := -v_val;            -- exact depletion
      v_new_val := 0;
    ELSE
      v_delta := round(p_qty_delta * v_avg, 6);   -- round ONCE; pool and ledger receive the identical delta
      v_new_val := v_val + v_delta;
    END IF;
    r.unit_cost_used := v_avg::cost6;
  END IF;

  UPDATE variant_cost_pools
  SET on_hand_qty = v_new_qty, total_value_base = v_new_val, updated_at = now()
  WHERE business_id = p_business_id AND branch_id = p_branch_id AND variant_id = p_variant_id;

  r.value_delta_base := v_delta::value6;
  r.new_on_hand_qty := v_new_qty;
  r.new_total_value_base := v_new_val::value6;
  RETURN r;
END $$;
REVOKE EXECUTE ON FUNCTION fn_post_to_cost_pool(UUID,UUID,UUID,INTEGER,NUMERIC,NUMERIC) FROM PUBLIC, anon, authenticated;

-- ============================================================
-- rpc_create_variant  (manager+)  atomic variant + options
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_create_variant(
  p_product_id UUID, p_sku TEXT, p_option_value_ids UUID[] DEFAULT '{}', p_sale_price_override NUMERIC DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_biz UUID; v_id UUID; v_fp TEXT; v_n INT;
BEGIN
  SELECT business_id INTO v_biz FROM products WHERE id = p_product_id;
  IF v_biz IS NULL THEN RAISE EXCEPTION 'INVALID_PRODUCT: %', p_product_id USING ERRCODE='22023'; END IF;
  PERFORM fn_require_role(v_biz, ARRAY['owner','manager']::user_role[]);

  -- Resolve the option values FIRST and pre-compute the fingerprint (same formula as
  -- fn_refresh_variant_fingerprint) so the unique index sees the final value on INSERT.
  -- Otherwise a second variant would transiently collide with an option-less sibling ('').
  SELECT count(*),
         COALESCE(string_agg(ov.product_option_id::text || ':' || ov.id::text, '|' ORDER BY ov.product_option_id), '')
  INTO v_n, v_fp
  FROM option_values ov WHERE ov.id = ANY(p_option_value_ids) AND ov.business_id = v_biz;
  IF v_n <> COALESCE(array_length(p_option_value_ids, 1), 0) THEN
    RAISE EXCEPTION 'INVALID_OPTION_VALUE: one or more option values not found in this business' USING ERRCODE='22023';
  END IF;

  INSERT INTO product_variants (product_id, sku, sale_price_override, option_fingerprint)
  VALUES (p_product_id, p_sku, p_sale_price_override, v_fp) RETURNING id INTO v_id;

  IF array_length(p_option_value_ids, 1) > 0 THEN
    INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id)
    SELECT v_id, ov.product_option_id, ov.id
    FROM option_values ov WHERE ov.id = ANY(p_option_value_ids) AND ov.business_id = v_biz;
  END IF;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_create_variant(UUID, TEXT, UUID[], NUMERIC) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_create_variant(UUID, TEXT, UUID[], NUMERIC) TO authenticated;

-- ============================================================
-- rpc_assign_internal_barcode  (procurement)  Code128 numeric, business-scoped
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_assign_internal_barcode(p_variant_id UUID, p_make_primary BOOLEAN DEFAULT true)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_biz UUID; v_code TEXT; v_seq TEXT; v_bc TEXT;
BEGIN
  SELECT pv.business_id, b.code INTO v_biz, v_code
  FROM product_variants pv JOIN businesses b ON b.id = pv.business_id WHERE pv.id = p_variant_id;
  IF v_biz IS NULL THEN RAISE EXCEPTION 'INVALID_VARIANT: %', p_variant_id USING ERRCODE='22023'; END IF;
  PERFORM fn_require_role(v_biz, ARRAY['owner','manager','stock_staff']::user_role[]);

  v_seq := fn_next_sequence(v_biz, 'BC');                 -- BC-2026-000001
  v_bc  := upper(v_code) || regexp_replace(v_seq, '[^0-9]', '', 'g');   -- e.g. TLC2026000001
  IF p_make_primary THEN
    UPDATE barcodes SET is_primary = false WHERE variant_id = p_variant_id AND is_primary;
  END IF;
  INSERT INTO barcodes (variant_id, barcode, barcode_type, symbology, is_primary)
  VALUES (p_variant_id, v_bc, 'internal', 'CODE128', p_make_primary);
  RETURN v_bc;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_assign_internal_barcode(UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_assign_internal_barcode(UUID, BOOLEAN) TO authenticated;

-- ============================================================
-- rpc_post_goods_receipt  (procurement roles, J-3)
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_post_goods_receipt(p_goods_receipt_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor UUID := fn_actor(); gr RECORD; it RECORD; pr t_cost_pool_result;
  v_unit_base NUMERIC; v_total_base NUMERIC; v_liab NUMERIC; v_vids UUID[];
BEGIN
  SELECT * INTO gr FROM goods_receipts WHERE id = p_goods_receipt_id FOR UPDATE;
  IF gr.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: goods receipt %', p_goods_receipt_id USING ERRCODE='P0002'; END IF;
  PERFORM fn_require_role(gr.business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
  IF gr.status <> 'draft' THEN RAISE EXCEPTION 'INVALID_STATE: receipt % is %', gr.id, gr.status USING ERRCODE='55000'; END IF;
  PERFORM fn_assert_branch(gr.business_id, gr.branch_id);
  IF gr.invoice_currency = 'TRY' AND gr.exchange_rate <> 1 THEN
    RAISE EXCEPTION 'INVALID_FX: TRY invoice must have exchange_rate = 1' USING ERRCODE='22023';
  END IF;

  SELECT array_agg(variant_id ORDER BY variant_id) INTO v_vids FROM goods_receipt_items WHERE goods_receipt_id = gr.id;
  IF v_vids IS NULL THEN RAISE EXCEPTION 'EMPTY_DOCUMENT: receipt % has no items', gr.id USING ERRCODE='22023'; END IF;
  PERFORM fn_lock_pools(gr.business_id, gr.branch_id, v_vids);

  v_liab := 0;
  FOR it IN SELECT * FROM goods_receipt_items WHERE goods_receipt_id = gr.id ORDER BY variant_id LOOP
    v_unit_base  := round(it.unit_cost * gr.exchange_rate, 6);
    v_total_base := it.quantity * v_unit_base;

    -- snapshot on the item (still draft => allowed by guard trigger)
    UPDATE goods_receipt_items
    SET fx_rate_snapshot = gr.exchange_rate, unit_cost_base = v_unit_base, total_cost_base = v_total_base
    WHERE id = it.id;

    pr := fn_post_to_cost_pool(gr.business_id, gr.branch_id, it.variant_id, it.quantity, NULL, v_total_base);
    PERFORM fn_ledger_post(gr.business_id, gr.branch_id, it.variant_id, 'sellable', it.quantity, 'goods_receipt',
                           'goods_receipt_item', it.id, pr.unit_cost_used, pr.value_delta_base, NULL, now(), v_actor);
    v_liab := v_liab + it.total_cost_original;
  END LOOP;

  INSERT INTO supplier_account_entries (business_id, supplier_id, entry_type, amount_original, currency, exchange_rate,
                                        reference_type, reference_id, note, created_by)
  VALUES (gr.business_id, gr.supplier_id, 'liability', round(v_liab, 2), gr.invoice_currency, gr.exchange_rate,
          'goods_receipt', gr.id, 'Goods receipt ' || gr.receipt_number, v_actor);

  UPDATE goods_receipts SET status = 'posted', posted_by = v_actor, posted_at = now() WHERE id = gr.id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_post_goods_receipt(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_post_goods_receipt(UUID) TO authenticated;

-- DEFERRED (ADR-10): explicit stub
CREATE OR REPLACE FUNCTION rpc_reverse_goods_receipt(p_goods_receipt_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  RAISE EXCEPTION 'NOT_IMPLEMENTED: goods receipt reversal is deferred (ADR-10). Use an inventory adjustment + supplier credit adjustment. receipt=%', p_goods_receipt_id
    USING ERRCODE='0A000';
END $$;
REVOKE EXECUTE ON FUNCTION rpc_reverse_goods_receipt(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_reverse_goods_receipt(UUID) TO authenticated;

-- ============================================================
-- fn_sale_core  (internal)  used by rpc_process_sale and rpc_process_exchange
-- ============================================================
-- p_items:    [{variant_id, quantity, expected_list_price?, unit_price?}]
-- p_payments: [{method, currency, amount, exchange_rate?, reference_no?}]
-- Returns jsonb {sale_id, sale_number, total, amount_due, change_given, replayed}
CREATE OR REPLACE FUNCTION fn_sale_core(
  p_business_id UUID, p_branch_id UUID, p_register_session_id UUID, p_customer_id UUID,
  p_reservation_id UUID, p_client_transaction_id UUID, p_device_id TEXT, p_occurred_at TIMESTAMPTZ,
  p_items JSONB, p_payments JSONB, p_discount_reason discount_reason, p_note TEXT,
  p_credit_applied_base NUMERIC, p_exchange_group_id UUID, p_sale_id UUID, p_fingerprint TEXT
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
BEGIN
  -- 1. auth / tenant (idempotency replay is checked immediately after membership so a retry
  --    after the register closed still returns the original result)
  v_role := fn_require_member(p_business_id);

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
        'cr', v_credit, 'o', p_occurred_at
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
                     discount_reason, sold_by, exchange_group_id, client_transaction_id, request_fingerprint,
                     device_id, occurred_at, note)
  VALUES (v_sale_id, p_business_id, p_branch_id, p_register_session_id, v_sale_number,
          COALESCE(p_customer_id, v_res_customer), 'completed',
          round(v_subtotal,2), round(v_disc,2), round(v_tax,2), v_total, round(v_credit,2), v_change,
          p_discount_reason, v_actor, p_exchange_group_id, p_client_transaction_id, v_fp, p_device_id, v_occurred, p_note);

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
REVOKE EXECUTE ON FUNCTION fn_sale_core(UUID,UUID,UUID,UUID,UUID,UUID,TEXT,TIMESTAMPTZ,JSONB,JSONB,discount_reason,TEXT,NUMERIC,UUID,UUID,TEXT) FROM PUBLIC, anon, authenticated;

-- ============================================================
-- rpc_process_sale  (member)
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_process_sale(
  p_business_id UUID, p_branch_id UUID, p_register_session_id UUID,
  p_items JSONB, p_payments JSONB,
  p_client_transaction_id UUID DEFAULT NULL, p_device_id TEXT DEFAULT NULL, p_occurred_at TIMESTAMPTZ DEFAULT NULL,
  p_customer_id UUID DEFAULT NULL, p_reservation_id UUID DEFAULT NULL,
  p_discount_reason discount_reason DEFAULT NULL, p_note TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  RETURN fn_sale_core(p_business_id, p_branch_id, p_register_session_id, p_customer_id, p_reservation_id,
                      p_client_transaction_id, p_device_id, p_occurred_at, p_items, p_payments,
                      p_discount_reason, p_note, 0, NULL, NULL, NULL);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_process_sale(UUID,UUID,UUID,JSONB,JSONB,UUID,TEXT,TIMESTAMPTZ,UUID,UUID,discount_reason,TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_process_sale(UUID,UUID,UUID,JSONB,JSONB,UUID,TEXT,TIMESTAMPTZ,UUID,UUID,discount_reason,TEXT) TO authenticated;

-- ============================================================
-- rpc_void_sale  (manager+)  full void only
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_void_sale(p_sale_id UUID, p_reason TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); s RECORD; si RECORD; sic RECORD; pr t_cost_pool_result; v_vids UUID[]; pay RECORD;
BEGIN
  IF length(trim(COALESCE(p_reason,''))) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='22023'; END IF;
  SELECT * INTO s FROM sales WHERE id = p_sale_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: sale %', p_sale_id USING ERRCODE='P0002'; END IF;
  PERFORM fn_require_role(s.business_id, ARRAY['owner','manager']::user_role[]);
  IF s.status <> 'completed' THEN RAISE EXCEPTION 'ALREADY_VOIDED: sale %', p_sale_id USING ERRCODE='55000'; END IF;
  IF EXISTS (SELECT 1 FROM return_items ri JOIN sale_items x ON x.id = ri.sale_item_id WHERE x.sale_id = p_sale_id) THEN
    RAISE EXCEPTION 'VOID_BLOCKED: sale % has completed returns; use return workflow', p_sale_id USING ERRCODE='55000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM register_sessions WHERE id = s.register_session_id AND status = 'open') THEN
    RAISE EXCEPTION 'VOID_BLOCKED: register session of sale % is closed', p_sale_id USING ERRCODE='55000';
  END IF;

  SELECT array_agg(variant_id ORDER BY variant_id) INTO v_vids FROM sale_items WHERE sale_id = p_sale_id;
  PERFORM fn_lock_pools(s.business_id, s.branch_id, v_vids);

  FOR si IN SELECT * FROM sale_items WHERE sale_id = p_sale_id ORDER BY variant_id LOOP
    SELECT * INTO sic FROM sale_item_costs WHERE sale_item_id = si.id;
    -- restore at the original sale cost (exact line value), into sellable
    pr := fn_post_to_cost_pool(s.business_id, s.branch_id, si.variant_id, si.quantity, NULL, sic.line_cost_base);
    PERFORM fn_ledger_post(s.business_id, s.branch_id, si.variant_id, 'sellable', si.quantity, 'sale_void',
                           'sale_item', si.id, pr.unit_cost_used, pr.value_delta_base, p_reason, now(), v_actor);
  END LOOP;

  FOR pay IN SELECT * FROM sale_payments WHERE sale_id = p_sale_id AND method = 'cash' LOOP
    INSERT INTO cash_movements (business_id, register_session_id, movement_type, currency, amount, exchange_rate,
                                reference_type, reference_id, note, created_by)
    VALUES (s.business_id, s.register_session_id, 'void_cash_out', pay.currency, -pay.amount, pay.exchange_rate,
            'sale_void', p_sale_id, p_reason, v_actor);
  END LOOP;
  IF s.change_given_base > 0 THEN
    INSERT INTO cash_movements (business_id, register_session_id, movement_type, currency, amount, exchange_rate,
                                reference_type, reference_id, note, created_by)
    VALUES (s.business_id, s.register_session_id, 'cash_in', 'TRY', s.change_given_base, 1,
            'sale_void', p_sale_id, 'change reversal on void', v_actor);
  END IF;

  IF s.customer_id IS NOT NULL THEN
    UPDATE customers SET total_spent = total_spent - s.total, order_count = greatest(order_count - 1, 0) WHERE id = s.customer_id;
  END IF;

  UPDATE sales SET status = 'voided', voided_by = v_actor, voided_at = now(), void_reason = p_reason WHERE id = p_sale_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_void_sale(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_void_sale(UUID, TEXT) TO authenticated;

-- ============================================================
-- fn_return_core  (internal)  customer return posting
-- ============================================================
-- p_items: [{sale_item_id, quantity, disposition?, reason?}]
-- Returns jsonb {return_id, return_number, credit_value_base}
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
  DELETE FROM _return_lines;

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

-- ============================================================
-- rpc_process_return  (member)  standalone return (refund/store-credit types only)
-- ============================================================
-- Pilot baseline is merchandise exchange => use rpc_process_exchange.
-- A bare 'exchange' return without a replacement sale would leave credit
-- dangling, so it is rejected here.
CREATE OR REPLACE FUNCTION rpc_process_return(
  p_business_id UUID, p_branch_id UUID, p_sale_id UUID, p_items JSONB,
  p_return_type return_type, p_reason TEXT,
  p_register_session_id UUID DEFAULT NULL, p_refund_method payment_method DEFAULT NULL, p_note TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF p_return_type = 'exchange' THEN
    RAISE EXCEPTION 'USE_EXCHANGE_RPC: exchanges must be posted with rpc_process_exchange (return + replacement sale atomically)' USING ERRCODE='22023';
  END IF;
  RETURN fn_return_core(p_business_id, p_branch_id, p_sale_id, p_items, p_return_type, p_reason, p_note,
                        NULL, NULL, p_register_session_id, p_refund_method);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_process_return(UUID,UUID,UUID,JSONB,return_type,TEXT,UUID,payment_method,TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_process_return(UUID,UUID,UUID,JSONB,return_type,TEXT,UUID,payment_method,TEXT) TO authenticated;

-- ============================================================
-- rpc_process_exchange  (member)  J-1: return + replacement sale, one transaction
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_process_exchange(
  p_business_id UUID, p_branch_id UUID, p_register_session_id UUID,
  p_original_sale_id UUID, p_return_items JSONB, p_new_items JSONB, p_payments JSONB,
  p_client_transaction_id UUID DEFAULT NULL, p_device_id TEXT DEFAULT NULL, p_occurred_at TIMESTAMPTZ DEFAULT NULL,
  p_reason TEXT DEFAULT NULL, p_customer_id UUID DEFAULT NULL, p_note TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_group UUID := gen_random_uuid(); v_sale_id UUID := gen_random_uuid(); v_fp TEXT; v_ret JSONB; v_sale JSONB; v_existing RECORD;
BEGIN
  IF p_new_items IS NULL OR jsonb_typeof(p_new_items) <> 'array' OR jsonb_array_length(p_new_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_CART: an exchange needs at least one replacement item' USING ERRCODE='22023';
  END IF;

  -- idempotency over the whole exchange payload (sale core re-checks with this fingerprint)
  IF p_client_transaction_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext(p_business_id::text || ':' || p_client_transaction_id::text));
    v_fp := encode(sha256(convert_to(jsonb_build_object(
              'x', p_original_sale_id, 'ri', p_return_items, 'ni', p_new_items, 'p', p_payments, 'br', p_branch_id,
              's', p_register_session_id, 'o', p_occurred_at)::text, 'UTF8')), 'hex');
    SELECT id, sale_number, total, amount_due_base, change_given_base, request_fingerprint INTO v_existing
    FROM sales WHERE business_id = p_business_id AND client_transaction_id = p_client_transaction_id;
    IF v_existing.id IS NOT NULL THEN
      IF v_existing.request_fingerprint IS DISTINCT FROM v_fp THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: client_transaction_id % was used with a different payload', p_client_transaction_id USING ERRCODE='23505';
      END IF;
      RETURN jsonb_build_object('sale_id', v_existing.id, 'sale_number', v_existing.sale_number, 'total', v_existing.total,
                                'amount_due', v_existing.amount_due_base, 'change_given', v_existing.change_given_base,
                                'return', (SELECT jsonb_build_object('return_id', r.id, 'return_number', r.return_number,
                                                                     'credit_value_base', r.credit_value_base)
                                           FROM returns r WHERE r.replacement_sale_id = v_existing.id),
                                'exchange_group_id', (SELECT exchange_group_id FROM sales WHERE id = v_existing.id),
                                'replayed', true);
    END IF;
  END IF;

  -- 1. return (FK to replacement sale is DEFERRABLE; validated at commit)
  v_ret := fn_return_core(p_business_id, p_branch_id, p_original_sale_id, p_return_items, 'exchange', p_reason, p_note,
                          v_group, v_sale_id, p_register_session_id, NULL);
  -- 2. replacement sale with merchandise credit applied
  v_sale := fn_sale_core(p_business_id, p_branch_id, p_register_session_id, p_customer_id, NULL,
                         p_client_transaction_id, p_device_id, p_occurred_at, p_new_items, p_payments,
                         NULL, p_note, (v_ret->>'credit_value_base')::NUMERIC, v_group, v_sale_id, v_fp);
  RETURN v_sale || jsonb_build_object('return', v_ret, 'exchange_group_id', v_group);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_process_exchange(UUID,UUID,UUID,UUID,JSONB,JSONB,JSONB,UUID,TEXT,TIMESTAMPTZ,TEXT,UUID,TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_process_exchange(UUID,UUID,UUID,UUID,JSONB,JSONB,JSONB,UUID,TEXT,TIMESTAMPTZ,TEXT,UUID,TEXT) TO authenticated;

-- ============================================================
-- RESERVATIONS  (member)
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_create_reservation(
  p_business_id UUID, p_branch_id UUID, p_expires_at TIMESTAMPTZ, p_items JSONB,
  p_customer_id UUID DEFAULT NULL, p_hold_name TEXT DEFAULT NULL, p_contact_phone TEXT DEFAULT NULL,
  p_contact_instagram TEXT DEFAULT NULL, p_source TEXT DEFAULT NULL, p_note TEXT DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); v_id UUID := gen_random_uuid(); it RECORD; v_vids UUID[]; v_avail INT;
BEGIN
  PERFORM fn_require_member(p_business_id);
  PERFORM fn_assert_branch(p_business_id, p_branch_id);
  IF p_expires_at IS NULL OR p_expires_at <= now() THEN RAISE EXCEPTION 'INVALID_EXPIRY: expires_at must be in the future (explicit per reservation)' USING ERRCODE='22023'; END IF;
  IF p_customer_id IS NULL AND length(trim(COALESCE(p_hold_name,''))) = 0 THEN
    RAISE EXCEPTION 'IDENTITY_REQUIRED: customer_id or hold_name required' USING ERRCODE='22023';
  END IF;
  IF p_customer_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND business_id = p_business_id) THEN
    RAISE EXCEPTION 'INVALID_CUSTOMER: %', p_customer_id USING ERRCODE='22023';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_RESERVATION' USING ERRCODE='22023';
  END IF;
  SELECT array_agg(DISTINCT (e->>'variant_id')::UUID ORDER BY (e->>'variant_id')::UUID) INTO v_vids FROM jsonb_array_elements(p_items) e;
  PERFORM fn_lock_pools(p_business_id, p_branch_id, v_vids);

  INSERT INTO reservations (id, business_id, branch_id, reservation_number, customer_id, hold_name, contact_phone, contact_instagram,
                            source, status, expires_at, note, created_by)
  VALUES (v_id, p_business_id, p_branch_id, fn_next_sequence(p_business_id, 'RV'), p_customer_id, p_hold_name, p_contact_phone,
          p_contact_instagram, p_source, 'active', p_expires_at, p_note, v_actor);

  FOR it IN SELECT (e->>'variant_id')::UUID AS variant_id, SUM((e->>'quantity')::INT) AS qty
            FROM jsonb_array_elements(p_items) e GROUP BY 1 ORDER BY 1 LOOP
    PERFORM fn_assert_variant(p_business_id, it.variant_id);
    IF it.qty <= 0 THEN RAISE EXCEPTION 'INVALID_QTY' USING ERRCODE='22023'; END IF;
    v_avail := fn_bucket_qty(p_business_id, p_branch_id, it.variant_id, 'sellable') - fn_reserved_qty(p_business_id, p_branch_id, it.variant_id, NULL);
    IF v_avail < it.qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK: variant % available=% requested=%', it.variant_id, v_avail, it.qty USING ERRCODE='55000';
    END IF;
    INSERT INTO reservation_items (reservation_id, variant_id, quantity) VALUES (v_id, it.variant_id, it.qty);
  END LOOP;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_create_reservation(UUID,UUID,TIMESTAMPTZ,JSONB,UUID,TEXT,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_create_reservation(UUID,UUID,TIMESTAMPTZ,JSONB,UUID,TEXT,TEXT,TEXT,TEXT,TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_cancel_reservation(p_reservation_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); r RECORD;
BEGIN
  SELECT * INTO r FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: reservation %', p_reservation_id USING ERRCODE='P0002'; END IF;
  PERFORM fn_require_member(r.business_id);
  IF r.status <> 'active' THEN RAISE EXCEPTION 'INVALID_STATE: reservation % is %', r.id, r.status USING ERRCODE='55000'; END IF;
  UPDATE reservations SET status = CASE WHEN expires_at <= now() THEN 'expired'::reservation_status ELSE 'cancelled'::reservation_status END,
                          cancelled_by = v_actor, cancelled_at = now(), cancel_reason = p_reason
  WHERE id = p_reservation_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_cancel_reservation(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_cancel_reservation(UUID, TEXT) TO authenticated;

-- ============================================================
-- INVENTORY ADJUSTMENT / STATE CHANGE / WRITE-OFF
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_post_inventory_adjustment(
  p_business_id UUID, p_branch_id UUID, p_variant_id UUID, p_bucket inventory_bucket,
  p_quantity_delta INTEGER, p_reason TEXT, p_cost_source adjustment_cost_source,
  p_unit_cost_base NUMERIC DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); v_id UUID := gen_random_uuid(); pr t_cost_pool_result; v_unit NUMERIC; v_pool RECORD; v_last NUMERIC;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_assert_branch(p_business_id, p_branch_id);
  PERFORM fn_assert_variant(p_business_id, p_variant_id);
  IF p_quantity_delta = 0 THEN RAISE EXCEPTION 'INVALID_QTY: zero delta' USING ERRCODE='22023'; END IF;
  IF length(trim(COALESCE(p_reason,''))) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='22023'; END IF;
  PERFORM fn_lock_pools(p_business_id, p_branch_id, ARRAY[p_variant_id]);
  SELECT * INTO v_pool FROM variant_cost_pools WHERE business_id = p_business_id AND branch_id = p_branch_id AND variant_id = p_variant_id;

  IF p_quantity_delta > 0 THEN
    IF p_cost_source = 'current_mwa' THEN
      IF v_pool.on_hand_qty <= 0 THEN RAISE EXCEPTION 'COST_REQUIRED: pool is empty; provide last_purchase_cost_confirmed or manual_cost' USING ERRCODE='22023'; END IF;
      v_unit := v_pool.total_value_base / v_pool.on_hand_qty;
    ELSIF p_cost_source = 'last_purchase_cost_confirmed' THEN
      SELECT unit_cost_base INTO v_last FROM goods_receipt_items
      WHERE variant_id = p_variant_id AND business_id = p_business_id AND unit_cost_base IS NOT NULL
      ORDER BY created_at DESC LIMIT 1;
      IF v_last IS NULL THEN RAISE EXCEPTION 'NO_PURCHASE_HISTORY: use manual_cost' USING ERRCODE='22023'; END IF;
      IF p_unit_cost_base IS NULL OR p_unit_cost_base <> v_last THEN
        RAISE EXCEPTION 'COST_CONFIRMATION_MISMATCH: last purchase cost is %, confirm it explicitly', v_last USING ERRCODE='22023';
      END IF;
      v_unit := v_last;
    ELSE
      IF p_unit_cost_base IS NULL OR p_unit_cost_base <= 0 THEN RAISE EXCEPTION 'COST_REQUIRED: manual unit cost > 0 required' USING ERRCODE='22023'; END IF;
      v_unit := p_unit_cost_base;
    END IF;
    pr := fn_post_to_cost_pool(p_business_id, p_branch_id, p_variant_id, p_quantity_delta, v_unit, NULL);
  ELSE
    IF p_cost_source <> 'current_mwa' THEN RAISE EXCEPTION 'INVALID_COST_SOURCE: negative adjustments use current_mwa' USING ERRCODE='22023'; END IF;
    IF fn_bucket_qty(p_business_id, p_branch_id, p_variant_id, p_bucket) < -p_quantity_delta THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK: bucket % has less than %', p_bucket, -p_quantity_delta USING ERRCODE='55000';
    END IF;
    pr := fn_post_to_cost_pool(p_business_id, p_branch_id, p_variant_id, p_quantity_delta, NULL, NULL);
  END IF;

  INSERT INTO inventory_adjustments (id, business_id, branch_id, variant_id, bucket, quantity_delta, reason, cost_source,
                                     unit_cost_base, value_delta_base, posted_by)
  VALUES (v_id, p_business_id, p_branch_id, p_variant_id, p_bucket, p_quantity_delta, p_reason, p_cost_source,
          pr.unit_cost_used, pr.value_delta_base, v_actor);
  PERFORM fn_ledger_post(p_business_id, p_branch_id, p_variant_id, p_bucket, p_quantity_delta, 'adjustment',
                         'adjustment', v_id, pr.unit_cost_used, pr.value_delta_base, p_reason, now(), v_actor);
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_post_inventory_adjustment(UUID,UUID,UUID,inventory_bucket,INTEGER,TEXT,adjustment_cost_source,NUMERIC) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_post_inventory_adjustment(UUID,UUID,UUID,inventory_bucket,INTEGER,TEXT,adjustment_cost_source,NUMERIC) TO authenticated;

-- Condition change: no pool value change (two ledger rows, zero delta)
CREATE OR REPLACE FUNCTION rpc_change_stock_condition(
  p_business_id UUID, p_branch_id UUID, p_variant_id UUID,
  p_from_bucket inventory_bucket, p_to_bucket inventory_bucket, p_quantity INTEGER, p_reason TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); v_ref UUID := gen_random_uuid(); v_pool RECORD; v_avg NUMERIC;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
  PERFORM fn_assert_branch(p_business_id, p_branch_id);
  PERFORM fn_assert_variant(p_business_id, p_variant_id);
  IF p_from_bucket = p_to_bucket THEN RAISE EXCEPTION 'INVALID_STATE_CHANGE: same bucket' USING ERRCODE='22023'; END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN RAISE EXCEPTION 'INVALID_QTY' USING ERRCODE='22023'; END IF;
  IF length(trim(COALESCE(p_reason,''))) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='22023'; END IF;
  PERFORM fn_lock_pools(p_business_id, p_branch_id, ARRAY[p_variant_id]);
  IF fn_bucket_qty(p_business_id, p_branch_id, p_variant_id, p_from_bucket) < p_quantity THEN
    RAISE EXCEPTION 'INSUFFICIENT_STOCK: bucket % has less than %', p_from_bucket, p_quantity USING ERRCODE='55000';
  END IF;
  SELECT * INTO v_pool FROM variant_cost_pools WHERE business_id = p_business_id AND branch_id = p_branch_id AND variant_id = p_variant_id;
  v_avg := CASE WHEN v_pool.on_hand_qty > 0 THEN v_pool.total_value_base / v_pool.on_hand_qty ELSE 0 END;
  PERFORM fn_ledger_post(p_business_id, p_branch_id, p_variant_id, p_from_bucket, -p_quantity, 'state_change', 'state_change', v_ref, v_avg, 0, p_reason, now(), v_actor);
  PERFORM fn_ledger_post(p_business_id, p_branch_id, p_variant_id, p_to_bucket,    p_quantity, 'state_change', 'state_change', v_ref, v_avg, 0, p_reason, now(), v_actor);
  RETURN v_ref;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_change_stock_condition(UUID,UUID,UUID,inventory_bucket,inventory_bucket,INTEGER,TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_change_stock_condition(UUID,UUID,UUID,inventory_bucket,inventory_bucket,INTEGER,TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_write_off(
  p_business_id UUID, p_branch_id UUID, p_variant_id UUID, p_bucket inventory_bucket, p_quantity INTEGER, p_reason TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); v_ref UUID := gen_random_uuid(); pr t_cost_pool_result;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_assert_branch(p_business_id, p_branch_id);
  PERFORM fn_assert_variant(p_business_id, p_variant_id);
  IF p_quantity IS NULL OR p_quantity <= 0 THEN RAISE EXCEPTION 'INVALID_QTY' USING ERRCODE='22023'; END IF;
  IF length(trim(COALESCE(p_reason,''))) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='22023'; END IF;
  PERFORM fn_lock_pools(p_business_id, p_branch_id, ARRAY[p_variant_id]);
  IF fn_bucket_qty(p_business_id, p_branch_id, p_variant_id, p_bucket) < p_quantity THEN
    RAISE EXCEPTION 'INSUFFICIENT_STOCK: bucket % has less than %', p_bucket, p_quantity USING ERRCODE='55000';
  END IF;
  pr := fn_post_to_cost_pool(p_business_id, p_branch_id, p_variant_id, -p_quantity, NULL, NULL);
  PERFORM fn_ledger_post(p_business_id, p_branch_id, p_variant_id, p_bucket, -p_quantity, 'write_off', 'write_off', v_ref,
                         pr.unit_cost_used, pr.value_delta_base, p_reason, now(), v_actor);
  RETURN v_ref;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_write_off(UUID,UUID,UUID,inventory_bucket,INTEGER,TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_write_off(UUID,UUID,UUID,inventory_bucket,INTEGER,TEXT) TO authenticated;

-- ============================================================
-- TRANSFERS  (manager+)  ship / receive; V1 full receipt only
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_ship_transfer(p_transfer_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); t RECORD; ln RECORD; pr t_cost_pool_result; v_vids UUID[]; v_avail INT;
BEGIN
  SELECT * INTO t FROM stock_transfers WHERE id = p_transfer_id FOR UPDATE;
  IF t.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: transfer %', p_transfer_id USING ERRCODE='P0002'; END IF;
  PERFORM fn_require_role(t.business_id, ARRAY['owner','manager']::user_role[]);
  IF t.status <> 'draft' THEN RAISE EXCEPTION 'INVALID_STATE: transfer % is %', t.id, t.status USING ERRCODE='55000'; END IF;
  PERFORM fn_assert_branch(t.business_id, t.from_branch_id);
  PERFORM fn_assert_branch(t.business_id, t.to_branch_id);
  SELECT array_agg(variant_id ORDER BY variant_id) INTO v_vids FROM stock_transfer_lines WHERE transfer_id = t.id;
  IF v_vids IS NULL THEN RAISE EXCEPTION 'EMPTY_DOCUMENT: transfer % has no lines', t.id USING ERRCODE='22023'; END IF;
  PERFORM fn_lock_pools(t.business_id, t.from_branch_id, v_vids);

  FOR ln IN SELECT * FROM stock_transfer_lines WHERE transfer_id = t.id ORDER BY variant_id LOOP
    v_avail := fn_bucket_qty(t.business_id, t.from_branch_id, ln.variant_id, 'sellable')
             - fn_reserved_qty(t.business_id, t.from_branch_id, ln.variant_id, NULL);
    IF v_avail < ln.quantity_sent THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK: variant % available=% to ship=%', ln.variant_id, v_avail, ln.quantity_sent USING ERRCODE='55000';
    END IF;
    pr := fn_post_to_cost_pool(t.business_id, t.from_branch_id, ln.variant_id, -ln.quantity_sent, NULL, NULL);
    INSERT INTO transfer_held_inventory (business_id, transfer_id, transfer_line_id, from_branch_id, to_branch_id, variant_id,
                                         quantity_held, carried_total_value_base)
    VALUES (t.business_id, t.id, ln.id, t.from_branch_id, t.to_branch_id, ln.variant_id, ln.quantity_sent, -pr.value_delta_base);
    PERFORM fn_ledger_post(t.business_id, t.from_branch_id, ln.variant_id, 'sellable', -ln.quantity_sent, 'transfer_ship',
                           'transfer_line', ln.id, pr.unit_cost_used, pr.value_delta_base, NULL, now(), v_actor);
  END LOOP;

  UPDATE stock_transfers SET status = 'shipped', shipped_by = v_actor, shipped_at = now() WHERE id = t.id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_ship_transfer(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_ship_transfer(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_receive_transfer(p_transfer_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); t RECORD; h RECORD; pr t_cost_pool_result; v_vids UUID[]; v_lines INT; v_held INT;
BEGIN
  SELECT * INTO t FROM stock_transfers WHERE id = p_transfer_id FOR UPDATE;
  IF t.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: transfer %', p_transfer_id USING ERRCODE='P0002'; END IF;
  PERFORM fn_require_role(t.business_id, ARRAY['owner','manager']::user_role[]);
  IF t.status <> 'shipped' THEN RAISE EXCEPTION 'INVALID_STATE: transfer % is %', t.id, t.status USING ERRCODE='55000'; END IF;

  SELECT count(*) INTO v_lines FROM stock_transfer_lines WHERE transfer_id = t.id;
  SELECT count(*) INTO v_held FROM transfer_held_inventory WHERE transfer_id = t.id AND received_at IS NULL;
  IF v_lines = 0 OR v_held <> v_lines THEN
    RAISE EXCEPTION 'PARTIAL_RECEIPT_NOT_SUPPORTED: transfer % lines=% held=%', t.id, v_lines, v_held USING ERRCODE='55000';
  END IF;

  SELECT array_agg(variant_id ORDER BY variant_id) INTO v_vids FROM transfer_held_inventory WHERE transfer_id = t.id AND received_at IS NULL;
  PERFORM fn_lock_pools(t.business_id, t.to_branch_id, v_vids);

  FOR h IN SELECT * FROM transfer_held_inventory WHERE transfer_id = t.id AND received_at IS NULL ORDER BY variant_id FOR UPDATE LOOP
    -- exact carried value in; never a missing-cost default
    pr := fn_post_to_cost_pool(t.business_id, t.to_branch_id, h.variant_id, h.quantity_held, NULL, h.carried_total_value_base);
    PERFORM fn_ledger_post(t.business_id, t.to_branch_id, h.variant_id, 'sellable', h.quantity_held, 'transfer_receive',
                           'transfer_line', h.transfer_line_id, pr.unit_cost_used, pr.value_delta_base, NULL, now(), v_actor);
    UPDATE transfer_held_inventory SET received_at = now() WHERE id = h.id;
    UPDATE stock_transfer_lines SET quantity_received = h.quantity_held WHERE id = h.transfer_line_id;
  END LOOP;

  UPDATE stock_transfers SET status = 'received', received_by = v_actor, received_at = now() WHERE id = t.id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_receive_transfer(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_receive_transfer(UUID) TO authenticated;

-- ============================================================
-- REGISTER SESSIONS  (member of the branch)
-- ============================================================
-- p_opening_counts: [{currency, amount}]  (TRY row is created even if omitted)
CREATE OR REPLACE FUNCTION rpc_open_register_session(p_cash_register_id UUID, p_opening_counts JSONB DEFAULT '[]')
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); r RECORD; v_id UUID := gen_random_uuid(); v_member_branch UUID; c RECORD; v_accepted TEXT[];
BEGIN
  SELECT * INTO r FROM cash_registers WHERE id = p_cash_register_id;
  IF r.id IS NULL OR NOT r.is_active THEN RAISE EXCEPTION 'INVALID_REGISTER: %', p_cash_register_id USING ERRCODE='22023'; END IF;
  PERFORM fn_require_member(r.business_id);
  SELECT branch_id INTO v_member_branch FROM business_members WHERE business_id = r.business_id AND user_id = v_actor;
  IF v_member_branch IS NOT NULL AND v_member_branch <> r.branch_id THEN
    RAISE EXCEPTION 'FORBIDDEN: member is pinned to another branch' USING ERRCODE='42501';
  END IF;
  IF EXISTS (SELECT 1 FROM register_sessions WHERE cash_register_id = r.id AND status = 'open') THEN
    RAISE EXCEPTION 'REGISTER_ALREADY_OPEN: register % has an open session', r.id USING ERRCODE='55000';
  END IF;
  v_accepted := ARRAY(SELECT jsonb_array_elements_text(fn_setting(r.business_id, 'accepted_currencies')));

  INSERT INTO register_sessions (id, business_id, branch_id, cash_register_id, session_number, status, opened_by)
  VALUES (v_id, r.business_id, r.branch_id, r.id, fn_next_sequence(r.business_id, 'RS'), 'open', v_actor);

  INSERT INTO register_session_currency_counts (business_id, register_session_id, currency, opening_amount)
  VALUES (r.business_id, v_id, 'TRY', 0);
  FOR c IN SELECT e->>'currency' AS currency, (e->>'amount')::NUMERIC AS amount FROM jsonb_array_elements(COALESCE(p_opening_counts,'[]'::jsonb)) e LOOP
    IF NOT (c.currency = ANY(v_accepted)) THEN RAISE EXCEPTION 'CURRENCY_NOT_ACCEPTED: %', c.currency USING ERRCODE='22023'; END IF;
    IF c.amount IS NULL OR c.amount < 0 THEN RAISE EXCEPTION 'INVALID_OPENING_AMOUNT' USING ERRCODE='22023'; END IF;
    INSERT INTO register_session_currency_counts (business_id, register_session_id, currency, opening_amount)
    VALUES (r.business_id, v_id, c.currency, c.amount)
    ON CONFLICT (register_session_id, currency) DO UPDATE SET opening_amount = EXCLUDED.opening_amount;
  END LOOP;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_open_register_session(UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_open_register_session(UUID, JSONB) TO authenticated;

-- p_counts: [{currency, counted_amount}] — every currency with opening or movements must be counted
CREATE OR REPLACE FUNCTION rpc_close_register_session(p_register_session_id UUID, p_counts JSONB, p_closing_note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); s RECORD; cur RECORD; v_counted NUMERIC; v_expected NUMERIC; v_rate NUMERIC; v_fx UUID; v_out JSONB := '[]'::jsonb;
BEGIN
  SELECT * INTO s FROM register_sessions WHERE id = p_register_session_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: session %', p_register_session_id USING ERRCODE='P0002'; END IF;
  PERFORM fn_require_member(s.business_id);
  IF s.status <> 'open' THEN RAISE EXCEPTION 'INVALID_STATE: session already closed' USING ERRCODE='55000'; END IF;

  -- make sure a count row exists for every currency that moved
  INSERT INTO register_session_currency_counts (business_id, register_session_id, currency, opening_amount)
  SELECT DISTINCT s.business_id, s.id, currency, 0 FROM cash_movements WHERE register_session_id = s.id
  ON CONFLICT (register_session_id, currency) DO NOTHING;

  FOR cur IN SELECT * FROM register_session_currency_counts WHERE register_session_id = s.id ORDER BY currency LOOP
    SELECT (e->>'counted_amount')::NUMERIC INTO v_counted
    FROM jsonb_array_elements(COALESCE(p_counts,'[]'::jsonb)) e WHERE e->>'currency' = cur.currency LIMIT 1;
    IF v_counted IS NULL THEN RAISE EXCEPTION 'COUNT_REQUIRED: counted_amount for % missing', cur.currency USING ERRCODE='22023'; END IF;
    IF v_counted < 0 THEN RAISE EXCEPTION 'INVALID_COUNT: % negative', cur.currency USING ERRCODE='22023'; END IF;

    SELECT cur.opening_amount + COALESCE(SUM(amount), 0) INTO v_expected
    FROM cash_movements WHERE register_session_id = s.id AND currency = cur.currency;   -- card/bank never here

    IF cur.currency = 'TRY' THEN v_rate := 1;
    ELSE
      BEGIN
        SELECT f.fx_rate_id, f.rate INTO v_fx, v_rate FROM fn_get_fx_rate(s.business_id, cur.currency, CURRENT_DATE) f;
      EXCEPTION WHEN OTHERS THEN v_rate := NULL;   -- no rate today: base summary left NULL, variance still recorded in currency
      END;
    END IF;

    UPDATE register_session_currency_counts
    SET expected_amount = round(v_expected, 2), counted_amount = round(v_counted, 2), exchange_rate = v_rate
    WHERE id = cur.id;

    v_out := v_out || jsonb_build_object('currency', cur.currency, 'opening', cur.opening_amount, 'expected', round(v_expected,2),
                                         'counted', round(v_counted,2), 'variance', round(v_counted - v_expected, 2));
  END LOOP;

  UPDATE register_sessions SET status = 'closed', closed_by = v_actor, closed_at = now(), closing_note = p_closing_note WHERE id = s.id;
  RETURN jsonb_build_object('session_id', s.id, 'counts', v_out);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_close_register_session(UUID, JSONB, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_close_register_session(UUID, JSONB, TEXT) TO authenticated;

-- ============================================================
-- SUPPLIER PAYMENTS + ALLOCATIONS  (manager+)  J-3 accounting separation
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_record_supplier_payment(
  p_business_id UUID, p_supplier_id UUID, p_amount NUMERIC, p_currency TEXT, p_method payment_method, p_paid_at DATE,
  p_exchange_rate NUMERIC DEFAULT NULL, p_reference_no TEXT DEFAULT NULL, p_note TEXT DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); v_rate NUMERIC; v_fx UUID; v_entry UUID; v_id UUID;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND business_id = p_business_id) THEN
    RAISE EXCEPTION 'INVALID_SUPPLIER: %', p_supplier_id USING ERRCODE='22023';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT' USING ERRCODE='22023'; END IF;
  IF p_currency = 'TRY' THEN v_rate := 1;
  ELSIF p_exchange_rate IS NOT NULL THEN
    IF p_exchange_rate <= 0 THEN RAISE EXCEPTION 'INVALID_FX' USING ERRCODE='22023'; END IF;
    v_rate := p_exchange_rate;
  ELSE
    SELECT f.fx_rate_id, f.rate INTO v_fx, v_rate FROM fn_get_fx_rate(p_business_id, p_currency, p_paid_at) f;
  END IF;

  INSERT INTO supplier_account_entries (business_id, supplier_id, entry_type, amount_original, currency, exchange_rate,
                                        reference_type, note, created_by)
  VALUES (p_business_id, p_supplier_id, 'payment', -p_amount, p_currency, v_rate, 'supplier_payment', p_note, v_actor)
  RETURNING id INTO v_entry;

  INSERT INTO supplier_payments (business_id, supplier_id, payment_number, amount, currency, exchange_rate, method,
                                 reference_no, note, paid_at, ledger_entry_id, created_by)
  VALUES (p_business_id, p_supplier_id, fn_next_sequence(p_business_id, 'SP'), p_amount, p_currency, v_rate, p_method,
          p_reference_no, p_note, p_paid_at, v_entry, v_actor)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_record_supplier_payment(UUID,UUID,NUMERIC,TEXT,payment_method,DATE,NUMERIC,TEXT,TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_record_supplier_payment(UUID,UUID,NUMERIC,TEXT,payment_method,DATE,NUMERIC,TEXT,TEXT) TO authenticated;

-- Allocate a payment to a liability entry. Amount is expressed in the LIABILITY currency.
CREATE OR REPLACE FUNCTION rpc_allocate_supplier_payment(
  p_supplier_payment_id UUID, p_liability_entry_id UUID, p_liability_currency_amount NUMERIC
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor UUID := fn_actor(); pay RECORD; liab RECORD; v_open_liab NUMERIC; v_open_pay NUMERIC;
  v_base NUMERIC; v_pay_amt NUMERIC; v_basis settlement_basis; v_fx NUMERIC; v_id UUID;
BEGIN
  SELECT * INTO pay FROM supplier_payments WHERE id = p_supplier_payment_id FOR UPDATE;
  IF pay.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: payment %', p_supplier_payment_id USING ERRCODE='P0002'; END IF;
  PERFORM fn_require_role(pay.business_id, ARRAY['owner','manager']::user_role[]);
  SELECT * INTO liab FROM supplier_account_entries WHERE id = p_liability_entry_id AND business_id = pay.business_id;
  IF liab.id IS NULL OR liab.entry_type <> 'liability' THEN RAISE EXCEPTION 'INVALID_LIABILITY: %', p_liability_entry_id USING ERRCODE='22023'; END IF;
  IF liab.supplier_id <> pay.supplier_id THEN RAISE EXCEPTION 'SUPPLIER_MISMATCH' USING ERRCODE='22023'; END IF;
  IF p_liability_currency_amount IS NULL OR p_liability_currency_amount <= 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT' USING ERRCODE='22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('liab:' || liab.id::text));

  SELECT liab.amount_original - COALESCE(SUM(liability_currency_amount_applied), 0) INTO v_open_liab
  FROM supplier_payment_allocations WHERE liability_entry_id = liab.id;
  SELECT pay.amount - COALESCE(SUM(payment_currency_amount_applied), 0) INTO v_open_pay
  FROM supplier_payment_allocations WHERE supplier_payment_id = pay.id;

  IF p_liability_currency_amount > v_open_liab + 0.005 THEN
    RAISE EXCEPTION 'OVER_ALLOCATION: liability open % %, requested %', v_open_liab, liab.currency, p_liability_currency_amount USING ERRCODE='55000';
  END IF;

  v_base := round(p_liability_currency_amount * liab.exchange_rate, 6);
  IF liab.currency = pay.currency THEN
    v_pay_amt := p_liability_currency_amount; v_basis := 'same_currency'; v_fx := 1;
  ELSE
    v_pay_amt := round(v_base / pay.exchange_rate, 2); v_basis := 'liability_rate'; v_fx := round(liab.exchange_rate / pay.exchange_rate, 6);
  END IF;
  IF v_pay_amt > v_open_pay + 0.005 THEN
    RAISE EXCEPTION 'OVER_ALLOCATION: payment open % %, needed %', v_open_pay, pay.currency, v_pay_amt USING ERRCODE='55000';
  END IF;

  INSERT INTO supplier_payment_allocations (business_id, supplier_payment_id, liability_entry_id, liability_currency, payment_currency,
    liability_currency_amount_applied, payment_currency_amount_applied, base_amount_applied, settlement_fx_rate, settlement_basis, created_by)
  VALUES (pay.business_id, pay.id, liab.id, liab.currency, pay.currency,
    p_liability_currency_amount, v_pay_amt, v_base, v_fx, v_basis, v_actor)
  RETURNING id INTO v_id;

  -- payment_status on the receipt (informational; derived truth is the allocation table)
  UPDATE goods_receipts g SET payment_status = (CASE WHEN v_open_liab - p_liability_currency_amount <= 0.005 THEN 'paid' ELSE 'partial' END)::goods_receipt_payment_status
  WHERE g.id = liab.reference_id AND liab.reference_type = 'goods_receipt';
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_allocate_supplier_payment(UUID, UUID, NUMERIC) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_allocate_supplier_payment(UUID, UUID, NUMERIC) TO authenticated;

-- ============================================================
-- SUPPLIER RETURN  (J-5 DEFERRED / NOT IMPLEMENTED)
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_post_supplier_return(p_supplier_return_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  RAISE EXCEPTION 'NOT_IMPLEMENTED: supplier return posting is DEFERRED for the pilot (J-5). id=%', p_supplier_return_id USING ERRCODE='0A000';
END $$;
REVOKE EXECUTE ON FUNCTION rpc_post_supplier_return(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_post_supplier_return(UUID) TO authenticated;

-- ============================================================
-- END 004
-- ============================================================
