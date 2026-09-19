-- Phase 14B follow-up: the current hold of an order is always resolved through
-- fn_online_order_reservation (active first, then newest). Two places still looked at
-- *every* reservation linked to an order, which breaks once an order has been re-reserved
-- (one expired hold + one active hold):
--   * rpc_online_orders_sweep LEFT JOINed all holds, so the stale expired row re-expired an
--     order whose new hold was active (found on the live DEV smoke, WEB-2026-000003);
--   * rpc_shop_create_order's replay branches used a scalar subquery over reservations,
--     which raises 21000 "more than one row" on a re-reserved order (latent).
-- No schema change; both function bodies are replaced, grants unchanged.

CREATE OR REPLACE FUNCTION rpc_online_orders_sweep(p_business_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE o RECORD; r reservations; n INTEGER := 0;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  FOR o IN SELECT so.id, so.business_id FROM storefront_orders so
           WHERE so.business_id = p_business_id AND so.status IN ('pending_confirmation','confirmed')
           ORDER BY so.created_at FOR UPDATE OF so LOOP
    r := fn_online_order_reservation(o.id);   -- the current hold only; older holds are history
    IF r.id IS NULL OR r.status = 'expired' OR (r.status = 'active' AND r.expires_at <= now()) THEN
      IF r.id IS NOT NULL AND r.status = 'active' THEN UPDATE reservations SET status = 'expired' WHERE id = r.id; END IF;
      UPDATE storefront_orders SET status = 'expired', expired_at = now() WHERE id = o.id;
      PERFORM fn_online_event(o.id, o.business_id, 'expired', 'system', NULL, '{}'::jsonb);
      n := n + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('expired', n);
END $$;

-- rpc_shop_create_order: identical to 20260919170000 except the two replay branches read
-- the current hold's expires_at through fn_online_order_reservation.
CREATE OR REPLACE FUNCTION rpc_shop_create_order(p_slug TEXT, p_idempotency_key TEXT, p_items JSONB, p_customer JSONB, p_fulfillment TEXT DEFAULT 'store_pickup')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s storefronts; v_branch UUID; v_cur iso_currency; v_key_hash TEXT; v_token TEXT; v_token_hash TEXT; v_existing storefront_orders;
        v_name TEXT; v_phone TEXT; v_email TEXT; v_note TEXT; v_lines INTEGER; v_units INTEGER; it RECORD; v_line RECORD;
        v_subtotal NUMERIC := 0; v_count INTEGER := 0; v_n INTEGER := 0; v_id UUID := gen_random_uuid(); v_res UUID := gen_random_uuid();
        v_number TEXT; v_exp TIMESTAMPTZ; v_hold JSONB := '[]'::jsonb; v_problems JSONB := '[]'::jsonb;
BEGIN
  s := fn_shop_resolve(p_slug);
  IF s.id IS NULL THEN RAISE EXCEPTION 'STORE_UNAVAILABLE: this store is not open' USING ERRCODE = '55000'; END IF;
  IF NOT s.orders_enabled THEN RAISE EXCEPTION 'ORDERS_DISABLED: this store does not take online orders at the moment' USING ERRCODE = '55000'; END IF;
  IF p_fulfillment IS DISTINCT FROM 'store_pickup' THEN RAISE EXCEPTION 'FULFILLMENT_UNAVAILABLE: only store pickup is offered' USING ERRCODE = '22023'; END IF;
  v_branch := fn_shop_branch(s);
  IF v_branch IS NULL THEN RAISE EXCEPTION 'STORE_UNAVAILABLE: no pickup branch' USING ERRCODE = '55000'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 32 AND 128 THEN RAISE EXCEPTION 'INVALID_INPUT: idempotency key' USING ERRCODE = '22023'; END IF;
  v_key_hash := fn_online_token_hash(p_idempotency_key);
  v_token := encode(sha256(convert_to('token:' || p_idempotency_key || ':' || s.id::text, 'UTF8')), 'hex');
  v_token_hash := fn_online_token_hash(v_token);

  -- idempotency: the same key on the same store returns the first order (and its token, derived from the key)
  SELECT * INTO v_existing FROM storefront_orders WHERE storefront_id = s.id AND idempotency_key_hash = v_key_hash;
  IF v_existing.id IS NOT NULL THEN
    RETURN jsonb_build_object('order_number', v_existing.order_number, 'tracking_token', v_token, 'status', v_existing.status, 'total', v_existing.total, 'currency', v_existing.currency,
                              'reservation_expires_at', (fn_online_order_reservation(v_existing.id)).expires_at, 'replayed', true);
  END IF;

  -- contact
  v_name := trim(COALESCE(p_customer ->> 'name', ''));
  v_phone := trim(COALESCE(p_customer ->> 'phone', ''));
  v_email := NULLIF(lower(trim(COALESCE(p_customer ->> 'email', ''))), '');
  v_note := NULLIF(left(trim(COALESCE(p_customer ->> 'note', '')), 500), '');
  IF length(v_name) NOT BETWEEN 2 AND 120 THEN RAISE EXCEPTION 'INVALID_NAME: name is required' USING ERRCODE = '22023'; END IF;
  IF length(regexp_replace(v_phone, '\D', '', 'g')) NOT BETWEEN 7 AND 15 OR length(v_phone) > 32 THEN RAISE EXCEPTION 'INVALID_PHONE: 7–15 digits' USING ERRCODE = '22023'; END IF;
  IF v_email IS NOT NULL AND v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RAISE EXCEPTION 'INVALID_EMAIL: %', v_email USING ERRCODE = '22023'; END IF;

  -- lines and limits
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'EMPTY_CART: nothing to order' USING ERRCODE = '22023'; END IF;
  SELECT count(*), COALESCE(sum((e ->> 'quantity')::int), 0) INTO v_lines, v_units FROM jsonb_array_elements(p_items) e;
  IF v_lines > 20 THEN RAISE EXCEPTION 'CART_LIMIT: at most 20 lines' USING ERRCODE = '22023'; END IF;
  IF v_units > 30 THEN RAISE EXCEPTION 'CART_LIMIT: at most 30 units per order' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e WHERE (e ->> 'variant_id') IS NULL OR (e ->> 'variant_id') !~ '^[0-9a-f-]{36}$' OR COALESCE((e ->> 'quantity')::int, 0) NOT BETWEEN 1 AND 10) THEN
    RAISE EXCEPTION 'INVALID_QTY: each line needs a variant and 1–10 units' USING ERRCODE = '22023';
  END IF;
  SELECT base_currency INTO v_cur FROM businesses WHERE id = s.business_id;

  -- server truth per line: published product, web-enabled active variant, current price; availability is checked under lock by the hold
  FOR it IN SELECT (e ->> 'variant_id')::uuid AS variant_id, sum((e ->> 'quantity')::int)::int AS qty FROM jsonb_array_elements(p_items) e GROUP BY 1 ORDER BY 1 LOOP
    SELECT pv.id, p.web_slug, COALESCE(p.web_title, p.name) AS name, fn_web_price(pv.id) AS price,
           (SELECT COALESCE(string_agg(ov.value, ' / ' ORDER BY CASE po.kind WHEN 'color' THEN 0 WHEN 'size' THEN 1 ELSE 2 END, po.sort_order), '')
            FROM variant_option_values vov JOIN option_values ov ON ov.id = vov.option_value_id JOIN product_options po ON po.id = vov.product_option_id WHERE vov.variant_id = pv.id) AS labels,
           (SELECT i.public_path FROM product_images i WHERE i.product_id = p.id AND i.public_path IS NOT NULL AND (i.variant_id = pv.id OR i.variant_id IS NULL)
            ORDER BY (i.variant_id = pv.id) DESC, (i.role = 'product_main') DESC, i.sort_order LIMIT 1) AS image_path,
           fn_shop_available(s.business_id, v_branch, pv.id) AS available
    INTO v_line
    FROM product_variants pv JOIN products p ON p.id = pv.product_id
    WHERE pv.id = it.variant_id AND pv.business_id = s.business_id AND pv.status = 'active' AND pv.web_enabled AND p.web_published AND p.status = 'active';
    IF v_line.id IS NULL THEN
      v_problems := v_problems || jsonb_build_object('variant_id', it.variant_id, 'code', 'UNAVAILABLE');
    ELSIF v_line.available < it.qty THEN
      v_problems := v_problems || jsonb_build_object('variant_id', it.variant_id, 'code', 'INSUFFICIENT', 'available', v_line.available, 'name', v_line.name, 'labels', v_line.labels);
    END IF;
  END LOOP;
  IF jsonb_array_length(v_problems) > 0 THEN
    RAISE EXCEPTION 'CART_PROBLEMS: %', v_problems::text USING ERRCODE = '55000';
  END IF;

  v_number := fn_next_sequence(s.business_id, 'WEB');
  v_exp := now() + make_interval(mins => s.order_hold_minutes);
  INSERT INTO storefront_orders (id, business_id, storefront_id, branch_id, order_number, status, customer_name, phone, phone_normalized, email, note, fulfillment_method, currency,
                                 subtotal, discount_total, total, item_count, tracking_token_hash, idempotency_key_hash)
  VALUES (v_id, s.business_id, s.id, v_branch, v_number, 'pending_confirmation', v_name, v_phone, COALESCE(fn_normalize_phone(v_phone), regexp_replace(v_phone, '\D', '', 'g')), v_email, v_note, 'store_pickup', v_cur,
          0, 0, 0, 1, v_token_hash, v_key_hash);
  FOR it IN SELECT (e ->> 'variant_id')::uuid AS variant_id, sum((e ->> 'quantity')::int)::int AS qty FROM jsonb_array_elements(p_items) e GROUP BY 1 ORDER BY 1 LOOP
    SELECT pv.id, p.web_slug, COALESCE(p.web_title, p.name) AS name, fn_web_price(pv.id) AS price,
           (SELECT COALESCE(string_agg(ov.value, ' / ' ORDER BY CASE po.kind WHEN 'color' THEN 0 WHEN 'size' THEN 1 ELSE 2 END, po.sort_order), '')
            FROM variant_option_values vov JOIN option_values ov ON ov.id = vov.option_value_id JOIN product_options po ON po.id = vov.product_option_id WHERE vov.variant_id = pv.id) AS labels,
           (SELECT i.public_path FROM product_images i WHERE i.product_id = p.id AND i.public_path IS NOT NULL AND (i.variant_id = pv.id OR i.variant_id IS NULL)
            ORDER BY (i.variant_id = pv.id) DESC, (i.role = 'product_main') DESC, i.sort_order LIMIT 1) AS image_path
    INTO v_line FROM product_variants pv JOIN products p ON p.id = pv.product_id WHERE pv.id = it.variant_id;
    v_n := v_n + 1;
    INSERT INTO storefront_order_items (order_id, business_id, line_no, variant_id, product_slug, product_name, variant_labels, image_path, quantity, unit_price, line_total)
    VALUES (v_id, s.business_id, v_n, it.variant_id, v_line.web_slug, v_line.name, COALESCE(v_line.labels, ''), v_line.image_path, it.qty, v_line.price, v_line.price * it.qty);
    v_subtotal := v_subtotal + v_line.price * it.qty; v_count := v_count + it.qty;
    v_hold := v_hold || jsonb_build_object('variant_id', it.variant_id, 'quantity', it.qty);
  END LOOP;
  -- the hold: the same engine, locks and availability rule the POS uses (all-or-nothing)
  INSERT INTO reservations (id, business_id, branch_id, reservation_number, customer_id, hold_name, contact_phone, source, status, expires_at, note, storefront_order_id)
  VALUES (v_res, s.business_id, v_branch, fn_next_sequence(s.business_id, 'RV'), NULL, v_name, v_phone, 'online', 'active', v_exp, 'Online sipariş ' || v_number, v_id);
  PERFORM fn_reservation_hold(v_res, s.business_id, v_branch, v_hold);
  -- totals are computed here, never taken from the browser; the guard allows this first write because the snapshot is being set once
  PERFORM set_config('boutiqueos.online_order_snapshot', 'on', true);
  UPDATE storefront_orders SET subtotal = v_subtotal, total = v_subtotal, item_count = v_count WHERE id = v_id;
  PERFORM set_config('boutiqueos.online_order_snapshot', 'off', true);
  PERFORM fn_online_event(v_id, s.business_id, 'created', 'customer', NULL, jsonb_build_object('lines', v_n, 'units', v_count, 'total', v_subtotal, 'hold_until', v_exp));
  RETURN jsonb_build_object('order_number', v_number, 'tracking_token', v_token, 'status', 'pending_confirmation', 'total', v_subtotal, 'currency', v_cur,
                            'reservation_expires_at', v_exp, 'replayed', false);
EXCEPTION WHEN unique_violation THEN
  -- two submissions with the same key raced past the first read: the first order stands
  SELECT * INTO v_existing FROM storefront_orders WHERE storefront_id = s.id AND idempotency_key_hash = v_key_hash;
  IF v_existing.id IS NULL THEN RAISE; END IF;
  RETURN jsonb_build_object('order_number', v_existing.order_number, 'tracking_token', v_token, 'status', v_existing.status, 'total', v_existing.total, 'currency', v_existing.currency,
                            'reservation_expires_at', (fn_online_order_reservation(v_existing.id)).expires_at, 'replayed', true);
END $$;

-- grants restated (CREATE OR REPLACE keeps them; explicit for the lint and for readers)
REVOKE EXECUTE ON FUNCTION rpc_shop_create_order(TEXT, TEXT, JSONB, JSONB, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_create_order(TEXT, TEXT, JSONB, JSONB, TEXT) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION rpc_online_orders_sweep(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_online_orders_sweep(UUID) TO authenticated;
