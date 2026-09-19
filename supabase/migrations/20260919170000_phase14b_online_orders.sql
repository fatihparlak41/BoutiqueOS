-- ============================================================
-- Phase 14B — Guest order + checkout foundation (order request → hold → merchant → POS)
--
-- PUBLIC STOREFRONT → CART → GUEST CHECKOUT → ORDER REQUEST → INVENTORY RESERVATION
--   → MERCHANT CONFIRMATION → EXISTING POS SALE → FULFILMENT
--
-- Decisions (docs/09 ADR-22):
--   * An online order is an orchestration document. It never posts stock, COGS, payment or
--     revenue. The Phase 10A reservation engine holds the stock (customer_id NULL, hold_name =
--     guest name, source 'online', linked by reservations.storefront_order_id) and the Phase 9A
--     sale core turns the confirmed order into the one real sale (p_reservation_id fulfilment).
--   * Checkout is one atomic anon RPC: publication, price and availability are re-read on the
--     server; browser prices are ignored; order + items + reservation are created together or
--     not at all; the order number is WEB-YYYY-NNNNNN (fn_next_sequence); idempotent on
--     (storefront, idempotency key). No anon table privilege exists on order tables.
--   * Public access is a tracking token only: the server stores sha256(token); the token is
--     derived from the client's own high-entropy idempotency key so a retry can hand it back,
--     and neither the key nor the token is stored. The order number grants nothing.
--   * Price rule: checkout snapshots the current selling price; a confirmed order's price is
--     honoured at POS as LEAST(order price, current list price) — never more than confirmed,
--     never above list. Below-list prices go through the POS discount authority as today.
--   * The hold length is data (storefronts.order_hold_minutes, seeded 1440); expiry is derived
--     everywhere (fn_reserved_qty already ignores expired holds); rpc_online_orders_sweep only
--     materialises what reads already say. Confirmation refreshes the hold for the same length.
--   * Guest contact is an order snapshot; no CRM customer is created or changed.
--   * Only rpc_pos_complete_online_order may bind a sale (trigger). A retry replays.
-- ============================================================

CREATE TYPE online_order_status AS ENUM ('pending_confirmation','confirmed','ready','completed','cancelled','expired');
CREATE TYPE fulfillment_method  AS ENUM ('store_pickup','local_delivery','shipping');

ALTER TABLE storefronts
  ADD COLUMN orders_enabled     BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN order_hold_minutes INTEGER NOT NULL DEFAULT 1440 CHECK (order_hold_minutes BETWEEN 30 AND 10080),
  ADD COLUMN pickup_note        TEXT CHECK (pickup_note IS NULL OR length(pickup_note) <= 300);

-- ------------------------------------------------------------ orders
CREATE TABLE storefront_orders (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           UUID NOT NULL REFERENCES businesses(id),
  storefront_id         UUID NOT NULL REFERENCES storefronts(id),
  branch_id             UUID NOT NULL,
  order_number          TEXT NOT NULL,
  status                online_order_status NOT NULL DEFAULT 'pending_confirmation',
  customer_name         TEXT NOT NULL CHECK (length(trim(customer_name)) BETWEEN 2 AND 120),
  phone                 TEXT NOT NULL CHECK (length(trim(phone)) BETWEEN 7 AND 32),
  phone_normalized      TEXT NOT NULL,
  email                 TEXT CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  note                  TEXT CHECK (note IS NULL OR length(note) <= 500),
  fulfillment_method    fulfillment_method NOT NULL DEFAULT 'store_pickup',
  currency              iso_currency NOT NULL,
  subtotal              money2 NOT NULL CHECK (subtotal >= 0),
  discount_total        money2 NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
  total                 money2 NOT NULL CHECK (total >= 0),
  item_count            INTEGER NOT NULL CHECK (item_count > 0),
  confirmed_at          TIMESTAMPTZ,
  confirmed_by          UUID REFERENCES profiles(id),
  ready_at              TIMESTAMPTZ,
  ready_by              UUID REFERENCES profiles(id),
  cancelled_at          TIMESTAMPTZ,
  cancelled_by          UUID REFERENCES profiles(id),
  cancelled_by_customer BOOLEAN NOT NULL DEFAULT false,
  cancel_reason         TEXT,
  expired_at            TIMESTAMPTZ,
  completed_at          TIMESTAMPTZ,
  converted_sale_id     UUID,
  tracking_token_hash   TEXT NOT NULL UNIQUE CHECK (tracking_token_hash ~ '^[0-9a-f]{64}$'),
  idempotency_key_hash  TEXT NOT NULL CHECK (idempotency_key_hash ~ '^[0-9a-f]{64}$'),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, order_number),
  UNIQUE (business_id, id),
  UNIQUE (storefront_id, idempotency_key_hash),
  FOREIGN KEY (business_id, branch_id) REFERENCES branches (business_id, id),
  FOREIGN KEY (business_id, converted_sale_id) REFERENCES sales (business_id, id),
  CONSTRAINT chk_online_order_total CHECK (total = subtotal - discount_total),
  CONSTRAINT chk_online_order_sale CHECK ((status = 'completed') = (converted_sale_id IS NOT NULL))
);
CREATE UNIQUE INDEX uix_online_order_sale ON storefront_orders (converted_sale_id) WHERE converted_sale_id IS NOT NULL;
CREATE INDEX idx_online_orders_list ON storefront_orders (business_id, status, created_at DESC);
ALTER TABLE storefront_orders ENABLE ROW LEVEL SECURITY;      -- no policies: every read and write is an RPC
REVOKE ALL ON storefront_orders FROM anon, authenticated;

CREATE TABLE storefront_order_items (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id       UUID NOT NULL REFERENCES storefront_orders(id),
  business_id    UUID NOT NULL REFERENCES businesses(id),
  line_no        INTEGER NOT NULL CHECK (line_no > 0),
  variant_id     UUID NOT NULL,
  product_slug   TEXT NOT NULL,
  product_name   TEXT NOT NULL,
  variant_labels TEXT NOT NULL DEFAULT '',
  image_path     TEXT,
  quantity       INTEGER NOT NULL CHECK (quantity BETWEEN 1 AND 10),
  unit_price     money2 NOT NULL CHECK (unit_price >= 0),
  line_total     money2 NOT NULL CHECK (line_total >= 0),
  UNIQUE (order_id, variant_id),
  UNIQUE (order_id, line_no),
  FOREIGN KEY (business_id, variant_id) REFERENCES product_variants (business_id, id),
  CONSTRAINT chk_online_item_total CHECK (line_total = unit_price * quantity)
);
ALTER TABLE storefront_order_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON storefront_order_items FROM anon, authenticated;

CREATE TABLE storefront_order_events (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id      UUID NOT NULL REFERENCES storefront_orders(id),
  business_id   UUID NOT NULL REFERENCES businesses(id),
  event         TEXT NOT NULL CHECK (event IN ('created','confirmed','ready','cancelled','expired','rereserved','converted','completed')),
  actor_type    TEXT NOT NULL CHECK (actor_type IN ('customer','tenant','system')),
  actor_user_id UUID REFERENCES profiles(id),
  payload       JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_online_order_events ON storefront_order_events (order_id, occurred_at);
ALTER TABLE storefront_order_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON storefront_order_events FROM anon, authenticated;

-- the hold of an order: the existing reservation engine, linked one-to-one
ALTER TABLE reservations ADD COLUMN storefront_order_id UUID REFERENCES storefront_orders(id);
-- an order may have several holds over time (expired, then re-reserved); the current one is the latest active
CREATE INDEX idx_reservation_online_order ON reservations (storefront_order_id) WHERE storefront_order_id IS NOT NULL;

-- ------------------------------------------------------------ guards
-- (guard function defined below, before the trigger)

CREATE OR REPLACE FUNCTION fn_online_order_rows_frozen()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  RAISE EXCEPTION 'ORDER_ROW_FROZEN: % rows are never changed or deleted', TG_TABLE_NAME USING ERRCODE = '55000';
END $$;
CREATE TRIGGER trg_online_items_frozen  BEFORE UPDATE OR DELETE ON storefront_order_items  FOR EACH ROW EXECUTE FUNCTION fn_online_order_rows_frozen();
CREATE TRIGGER trg_online_events_frozen BEFORE UPDATE OR DELETE ON storefront_order_events FOR EACH ROW EXECUTE FUNCTION fn_online_order_rows_frozen();

-- ------------------------------------------------------------ helpers
CREATE OR REPLACE FUNCTION fn_online_event(p_order_id UUID, p_business_id UUID, p_event TEXT, p_actor_type TEXT, p_actor UUID, p_payload JSONB DEFAULT '{}'::jsonb)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  INSERT INTO storefront_order_events (order_id, business_id, event, actor_type, actor_user_id, payload) VALUES (p_order_id, p_business_id, p_event, p_actor_type, p_actor, COALESCE(p_payload, '{}'::jsonb));
$$;
REVOKE EXECUTE ON FUNCTION fn_online_event(UUID, UUID, TEXT, TEXT, UUID, JSONB) FROM PUBLIC, anon, authenticated;

-- The order's reservation (one-to-one).
CREATE OR REPLACE FUNCTION fn_online_order_reservation(p_order_id UUID)
RETURNS reservations LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT r.* FROM reservations r WHERE r.storefront_order_id = p_order_id ORDER BY (r.status = 'active') DESC, r.created_at DESC, r.reservation_number DESC LIMIT 1;
$$;
REVOKE EXECUTE ON FUNCTION fn_online_order_reservation(UUID) FROM PUBLIC, anon, authenticated;

-- Effective public status: a pending order whose hold lapsed reads as expired before any sweep.
CREATE OR REPLACE FUNCTION fn_online_order_public_status(o storefront_orders, r reservations)
RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN o.status IN ('pending_confirmation','confirmed') AND (r.id IS NULL OR r.status = 'expired' OR (r.status = 'active' AND r.expires_at <= now())) THEN 'expired' ELSE o.status::text END;
$$;
REVOKE EXECUTE ON FUNCTION fn_online_order_public_status(storefront_orders, reservations) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_online_token_hash(p_token TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$ SELECT encode(sha256(convert_to(p_token, 'UTF8')), 'hex'); $$;
REVOKE EXECUTE ON FUNCTION fn_online_token_hash(TEXT) FROM PUBLIC, anon, authenticated;

-- Order-safe JSON (what the customer may see). No internal ids, no staff names, no notes of the merchant.
CREATE OR REPLACE FUNCTION fn_online_order_public_json(o storefront_orders)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT jsonb_build_object(
    'order_number', o.order_number,
    'status', fn_online_order_public_status(o, fn_online_order_reservation(o.id)),
    'stored_status', o.status,
    'fulfillment_method', o.fulfillment_method,
    'customer_name', o.customer_name, 'phone', o.phone, 'email', o.email, 'note', o.note,
    'currency', o.currency, 'subtotal', o.subtotal, 'discount_total', o.discount_total, 'total', o.total, 'item_count', o.item_count,
    'reservation_expires_at', (SELECT r.expires_at FROM reservations r WHERE r.storefront_order_id = o.id ORDER BY (r.status = 'active') DESC, r.created_at DESC, r.reservation_number DESC LIMIT 1),
    'reservation_active', (SELECT r.status = 'active' AND r.expires_at > now() FROM reservations r WHERE r.storefront_order_id = o.id ORDER BY (r.status = 'active') DESC, r.created_at DESC, r.reservation_number DESC LIMIT 1),
    'created_at', o.created_at, 'confirmed_at', o.confirmed_at, 'ready_at', o.ready_at, 'completed_at', o.completed_at, 'cancelled_at', o.cancelled_at, 'expired_at', o.expired_at,
    'cancelled_by_customer', o.cancelled_by_customer,
    'can_cancel', (o.status = 'pending_confirmation'),
    'pickup', (SELECT jsonb_build_object('branch', b.name, 'note', s.pickup_note, 'store_name', s.store_name, 'whatsapp', s.whatsapp, 'instagram', s.instagram, 'phone', s.contact_phone)
               FROM branches b JOIN storefronts s ON s.id = o.storefront_id WHERE b.id = o.branch_id),
    'items', (SELECT COALESCE(jsonb_agg(jsonb_build_object('product_slug', i.product_slug, 'name', i.product_name, 'labels', i.variant_labels, 'image_path', i.image_path,
                                                          'quantity', i.quantity, 'unit_price', i.unit_price, 'line_total', i.line_total) ORDER BY i.line_no), '[]'::jsonb)
              FROM storefront_order_items i WHERE i.order_id = o.id),
    'timeline', (SELECT COALESCE(jsonb_agg(jsonb_build_object('event', e.event, 'at', e.occurred_at) ORDER BY e.occurred_at), '[]'::jsonb)
                 FROM storefront_order_events e WHERE e.order_id = o.id AND e.event IN ('created','confirmed','ready','cancelled','expired','rereserved','completed')));
$$;
REVOKE EXECUTE ON FUNCTION fn_online_order_public_json(storefront_orders) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ public checkout (anon)
-- One atomic boundary: resolve store → validate limits/contact → re-read publication, price,
-- availability → totals → order + items → reservation hold (same locks as POS) → number → token.
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
                              'reservation_expires_at', (SELECT expires_at FROM reservations WHERE storefront_order_id = v_existing.id), 'replayed', true);
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
                            'reservation_expires_at', (SELECT expires_at FROM reservations WHERE storefront_order_id = v_existing.id), 'replayed', true);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_shop_create_order(TEXT, TEXT, JSONB, JSONB, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_create_order(TEXT, TEXT, JSONB, JSONB, TEXT) TO anon, authenticated;

-- Orders are never deleted; a sale is bound only by the POS conversion; a final row never moves
-- (an expired order may come back to pending only through rpc_online_order_rereserve); the commercial
-- snapshot is written once by the checkout and then locked.
CREATE OR REPLACE FUNCTION fn_online_order_guard()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'ORDER_RETAINED: online orders are never deleted' USING ERRCODE = '55000'; END IF;
  IF NEW.converted_sale_id IS DISTINCT FROM OLD.converted_sale_id THEN
    IF OLD.converted_sale_id IS NOT NULL THEN RAISE EXCEPTION 'ORDER_SALE_BOUND: order % already has its sale', OLD.order_number USING ERRCODE = '55000'; END IF;
    IF current_setting('boutiqueos.online_order_conversion', true) IS DISTINCT FROM 'on' THEN
      RAISE EXCEPTION 'ORDER_SALE_ONLY_BY_POS: a sale is bound to an online order only by rpc_pos_complete_online_order' USING ERRCODE = '55000';
    END IF;
  END IF;
  IF OLD.status IN ('completed','cancelled') AND NEW.status <> OLD.status THEN
    RAISE EXCEPTION 'ORDER_FINAL: order % is %', OLD.order_number, OLD.status USING ERRCODE = '55000';
  END IF;
  IF OLD.status = 'expired' AND NEW.status <> 'expired' AND current_setting('boutiqueos.online_order_rereserve', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'ORDER_FINAL: order % is expired (re-reserve to reopen)', OLD.order_number USING ERRCODE = '55000';
  END IF;
  IF NEW.business_id <> OLD.business_id OR NEW.storefront_id <> OLD.storefront_id OR NEW.branch_id <> OLD.branch_id OR NEW.order_number <> OLD.order_number
     OR NEW.currency <> OLD.currency OR NEW.tracking_token_hash <> OLD.tracking_token_hash
     OR ((NEW.subtotal <> OLD.subtotal OR NEW.total <> OLD.total OR NEW.item_count <> OLD.item_count)
         AND NOT (OLD.subtotal = 0 AND current_setting('boutiqueos.online_order_snapshot', true) = 'on')) THEN
    RAISE EXCEPTION 'ORDER_SNAPSHOT_LOCKED: the commercial snapshot of % cannot change', OLD.order_number USING ERRCODE = '55000';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER trg_online_order_guard BEFORE UPDATE OR DELETE ON storefront_orders FOR EACH ROW EXECUTE FUNCTION fn_online_order_guard();

-- The customer's own order by token. Unknown token → NULL (never "wrong store" vs "wrong token").
CREATE OR REPLACE FUNCTION rpc_shop_order(p_slug TEXT, p_token TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s storefronts; o storefront_orders;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
  SELECT st.* INTO s FROM storefronts st WHERE st.slug = lower(trim(COALESCE(p_slug, '')));
  IF s.id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO o FROM storefront_orders WHERE storefront_id = s.id AND tracking_token_hash = fn_online_token_hash(p_token);
  IF o.id IS NULL THEN RETURN NULL; END IF;
  RETURN fn_online_order_public_json(o);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_shop_order(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_order(TEXT, TEXT) TO anon, authenticated;

-- Customer cancellation: only while the merchant has not confirmed. Releases the hold, keeps history.
CREATE OR REPLACE FUNCTION rpc_shop_cancel_order(p_slug TEXT, p_token TEXT, p_reason TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s storefronts; o storefront_orders; r reservations;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'NOT_FOUND: order' USING ERRCODE = 'P0002'; END IF;
  SELECT st.* INTO s FROM storefronts st WHERE st.slug = lower(trim(COALESCE(p_slug, '')));
  SELECT * INTO o FROM storefront_orders WHERE storefront_id = s.id AND tracking_token_hash = fn_online_token_hash(p_token) FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: order' USING ERRCODE = 'P0002'; END IF;
  IF o.status = 'cancelled' AND o.cancelled_by_customer THEN RETURN jsonb_build_object('order_number', o.order_number, 'status', 'cancelled', 'replayed', true); END IF;
  IF o.status <> 'pending_confirmation' THEN RAISE EXCEPTION 'CANCEL_NOT_ALLOWED: order is %', o.status USING ERRCODE = '55000'; END IF;
  r := fn_online_order_reservation(o.id);
  IF r.id IS NOT NULL AND r.status = 'active' THEN
    UPDATE reservations SET status = CASE WHEN r.expires_at <= now() THEN 'expired'::reservation_status ELSE 'cancelled'::reservation_status END,
                            cancelled_at = now(), cancel_reason = 'müşteri iptali' WHERE id = r.id;
  END IF;
  UPDATE storefront_orders SET status = 'cancelled', cancelled_at = now(), cancelled_by_customer = true, cancel_reason = NULLIF(left(trim(COALESCE(p_reason, '')), 300), '') WHERE id = o.id;
  PERFORM fn_online_event(o.id, o.business_id, 'cancelled', 'customer', NULL, jsonb_build_object('reason', NULLIF(left(trim(COALESCE(p_reason, '')), 300), '')));
  RETURN jsonb_build_object('order_number', o.order_number, 'status', 'cancelled', 'replayed', false);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_shop_cancel_order(TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_cancel_order(TEXT, TEXT, TEXT) TO anon, authenticated;

-- ------------------------------------------------------------ merchant RPCs
-- Who sees guest PII: the selling roles (owner, manager, sales_staff) — the same people who see CRM.
CREATE OR REPLACE FUNCTION fn_online_order_json(o storefront_orders)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT fn_online_order_public_json(o) || jsonb_build_object(
    'id', o.id, 'phone_normalized', o.phone_normalized, 'branch_id', o.branch_id,
    'reservation', (SELECT jsonb_build_object('id', r.id, 'reservation_number', r.reservation_number, 'status', r.status, 'expires_at', r.expires_at, 'active', (r.status = 'active' AND r.expires_at > now()))
                    FROM reservations r WHERE r.storefront_order_id = o.id ORDER BY (r.status = 'active') DESC, r.created_at DESC, r.reservation_number DESC LIMIT 1),
    'converted_sale', (SELECT jsonb_build_object('id', sa.id, 'sale_number', sa.sale_number, 'total', sa.total, 'occurred_at', sa.occurred_at) FROM sales sa WHERE sa.id = o.converted_sale_id),
    'cancel_reason', o.cancel_reason,
    'actors', jsonb_build_object('confirmed_by', (SELECT full_name FROM profiles WHERE id = o.confirmed_by), 'ready_by', (SELECT full_name FROM profiles WHERE id = o.ready_by), 'cancelled_by', (SELECT full_name FROM profiles WHERE id = o.cancelled_by)),
    'items_live', (SELECT COALESCE(jsonb_agg(jsonb_build_object('variant_id', i.variant_id, 'quantity', i.quantity, 'unit_price', i.unit_price, 'list_price_now', fn_web_price(i.variant_id),
                                                              'available_now', fn_shop_available(o.business_id, o.branch_id, i.variant_id), 'sku', pv.sku) ORDER BY i.line_no), '[]'::jsonb)
                   FROM storefront_order_items i JOIN product_variants pv ON pv.id = i.variant_id WHERE i.order_id = o.id),
    'events', (SELECT COALESCE(jsonb_agg(jsonb_build_object('event', e.event, 'at', e.occurred_at, 'actor_type', e.actor_type, 'actor', (SELECT full_name FROM profiles WHERE id = e.actor_user_id), 'payload', e.payload) ORDER BY e.occurred_at), '[]'::jsonb)
               FROM storefront_order_events e WHERE e.order_id = o.id));
$$;
REVOKE EXECUTE ON FUNCTION fn_online_order_json(storefront_orders) FROM PUBLIC, anon, authenticated;

-- Materialise lapsed holds of pending/confirmed orders as expired (reads already say so). Manager+ or selling roles; idempotent.
CREATE OR REPLACE FUNCTION rpc_online_orders_sweep(p_business_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE o RECORD; n INTEGER := 0;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  FOR o IN SELECT so.id, so.business_id, r.id AS res_id, r.status AS res_status FROM storefront_orders so
           LEFT JOIN reservations r ON r.storefront_order_id = so.id
           WHERE so.business_id = p_business_id AND so.status IN ('pending_confirmation','confirmed')
             AND (r.id IS NULL OR r.status = 'expired' OR (r.status = 'active' AND r.expires_at <= now()))
           ORDER BY so.created_at FOR UPDATE OF so LOOP
    IF o.res_id IS NOT NULL AND o.res_status = 'active' THEN UPDATE reservations SET status = 'expired' WHERE id = o.res_id; END IF;
    UPDATE storefront_orders SET status = 'expired', expired_at = now() WHERE id = o.id;
    PERFORM fn_online_event(o.id, o.business_id, 'expired', 'system', NULL, '{}'::jsonb);
    n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('expired', n);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_online_orders_sweep(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_online_orders_sweep(UUID) TO authenticated;

-- List: p_status = new | confirmed | ready | completed | closed (cancelled + expired) | NULL. Search by number, name, phone.
CREATE OR REPLACE FUNCTION rpc_online_orders(p_business_id UUID, p_status TEXT DEFAULT NULL, p_q TEXT DEFAULT NULL, p_limit INTEGER DEFAULT 50, p_offset INTEGER DEFAULT 0)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200); v_off INTEGER := GREATEST(COALESCE(p_offset, 0), 0); v_q TEXT := NULLIF(trim(COALESCE(p_q, '')), '');
        v_rows JSONB; v_total BIGINT;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  IF p_status IS NOT NULL AND p_status NOT IN ('new','confirmed','ready','completed','closed') THEN RAISE EXCEPTION 'INVALID_STATUS: %', p_status USING ERRCODE = '22023'; END IF;
  RETURN (WITH f AS (
    SELECT o.* FROM storefront_orders o
    WHERE o.business_id = p_business_id
      AND (p_status IS NULL
           OR (p_status = 'new' AND o.status = 'pending_confirmation') OR (p_status = 'confirmed' AND o.status = 'confirmed') OR (p_status = 'ready' AND o.status = 'ready')
           OR (p_status = 'completed' AND o.status = 'completed') OR (p_status = 'closed' AND o.status IN ('cancelled','expired')))
      AND (v_q IS NULL OR o.order_number ILIKE '%' || v_q || '%' OR o.customer_name ILIKE '%' || v_q || '%'
           OR (length(regexp_replace(v_q, '\D', '', 'g')) >= 3 AND o.phone_normalized LIKE '%' || regexp_replace(v_q, '\D', '', 'g') || '%')))
  SELECT jsonb_build_object(
    'rows', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', o.id, 'order_number', o.order_number, 'status', o.status,
              'public_status', fn_online_order_public_status(o, fn_online_order_reservation(o.id)),
              'customer_name', o.customer_name, 'phone', o.phone, 'total', o.total, 'currency', o.currency, 'item_count', o.item_count, 'created_at', o.created_at,
              'reservation_expires_at', (SELECT r.expires_at FROM reservations r WHERE r.storefront_order_id = o.id ORDER BY (r.status = 'active') DESC, r.created_at DESC, r.reservation_number DESC LIMIT 1),
              'converted_sale_number', (SELECT sa.sale_number FROM sales sa WHERE sa.id = o.converted_sale_id)) ORDER BY o.created_at DESC, o.id DESC), '[]'::jsonb)
             FROM (SELECT * FROM f ORDER BY created_at DESC, id DESC LIMIT v_lim OFFSET v_off) o),
    'total', (SELECT count(*) FROM f), 'limit', v_lim, 'offset', v_off,
    'counts', (SELECT jsonb_build_object(
                 'new', count(*) FILTER (WHERE status = 'pending_confirmation'), 'confirmed', count(*) FILTER (WHERE status = 'confirmed'),
                 'ready', count(*) FILTER (WHERE status = 'ready'), 'completed', count(*) FILTER (WHERE status = 'completed'),
                 'closed', count(*) FILTER (WHERE status IN ('cancelled','expired')))
               FROM storefront_orders WHERE business_id = p_business_id)));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_online_orders(UUID, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_online_orders(UUID, TEXT, TEXT, INTEGER, INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_online_order_detail(p_business_id UUID, p_order_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE o storefront_orders;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  SELECT * INTO o FROM storefront_orders WHERE id = p_order_id AND business_id = p_business_id;
  IF o.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: order %', p_order_id USING ERRCODE = 'P0002'; END IF;
  RETURN fn_online_order_json(o);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_online_order_detail(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_online_order_detail(UUID, UUID) TO authenticated;

-- Confirm: owner/manager. Requires a live hold; refreshes it for another order_hold_minutes (explicit rule).
CREATE OR REPLACE FUNCTION rpc_online_order_confirm(p_business_id UUID, p_order_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID; o storefront_orders; r reservations; v_minutes INTEGER; v_exp TIMESTAMPTZ;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  v_actor := fn_actor();
  SELECT * INTO o FROM storefront_orders WHERE id = p_order_id AND business_id = p_business_id FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: order %', p_order_id USING ERRCODE = 'P0002'; END IF;
  IF o.status = 'confirmed' THEN RETURN jsonb_build_object('order_number', o.order_number, 'status', 'confirmed', 'replayed', true); END IF;
  IF o.status <> 'pending_confirmation' THEN RAISE EXCEPTION 'INVALID_STATE: order is %', o.status USING ERRCODE = '55000'; END IF;
  SELECT * INTO r FROM reservations WHERE storefront_order_id = o.id ORDER BY (status = 'active') DESC, created_at DESC, reservation_number DESC LIMIT 1 FOR UPDATE;
  IF r.id IS NULL OR r.status <> 'active' OR r.expires_at <= now() THEN
    RAISE EXCEPTION 'RESERVATION_EXPIRED: the hold of % has lapsed; re-reserve if stock allows' , o.order_number USING ERRCODE = '55000';
  END IF;
  SELECT order_hold_minutes INTO v_minutes FROM storefronts WHERE id = o.storefront_id;
  v_exp := LEAST(now() + make_interval(mins => v_minutes), now() + interval '90 days');
  UPDATE reservations SET expires_at = v_exp WHERE id = r.id;
  UPDATE storefront_orders SET status = 'confirmed', confirmed_at = now(), confirmed_by = v_actor WHERE id = o.id;
  PERFORM fn_online_event(o.id, o.business_id, 'confirmed', 'tenant', v_actor, jsonb_build_object('hold_until', v_exp));
  RETURN jsonb_build_object('order_number', o.order_number, 'status', 'confirmed', 'reservation_expires_at', v_exp, 'replayed', false);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_online_order_confirm(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_online_order_confirm(UUID, UUID) TO authenticated;

-- Re-reserve an expired pending/confirmed order if stock still allows (new hold, same lines). Owner/manager.
CREATE OR REPLACE FUNCTION rpc_online_order_rereserve(p_business_id UUID, p_order_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID; o storefront_orders; r reservations; v_minutes INTEGER; v_exp TIMESTAMPTZ; v_res UUID := gen_random_uuid(); v_hold JSONB;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  v_actor := fn_actor();
  SELECT * INTO o FROM storefront_orders WHERE id = p_order_id AND business_id = p_business_id FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: order %', p_order_id USING ERRCODE = 'P0002'; END IF;
  IF o.status NOT IN ('pending_confirmation','confirmed','expired') THEN RAISE EXCEPTION 'INVALID_STATE: order is %', o.status USING ERRCODE = '55000'; END IF;
  SELECT * INTO r FROM reservations WHERE storefront_order_id = o.id ORDER BY (status = 'active') DESC, created_at DESC, reservation_number DESC LIMIT 1 FOR UPDATE;
  IF r.id IS NOT NULL AND r.status = 'active' AND r.expires_at > now() THEN RAISE EXCEPTION 'HOLD_ACTIVE: the hold is still valid' USING ERRCODE = '55000'; END IF;
  IF r.id IS NOT NULL AND r.status = 'active' THEN UPDATE reservations SET status = 'expired' WHERE id = r.id; END IF;
  SELECT order_hold_minutes INTO v_minutes FROM storefronts WHERE id = o.storefront_id;
  v_exp := now() + make_interval(mins => v_minutes);
  SELECT jsonb_agg(jsonb_build_object('variant_id', i.variant_id, 'quantity', i.quantity)) INTO v_hold FROM storefront_order_items i WHERE i.order_id = o.id;
  INSERT INTO reservations (id, business_id, branch_id, reservation_number, customer_id, hold_name, contact_phone, source, status, expires_at, note, storefront_order_id, created_by)
  VALUES (v_res, o.business_id, o.branch_id, fn_next_sequence(o.business_id, 'RV'), NULL, o.customer_name, o.phone, 'online', 'active', v_exp, 'Online sipariş ' || o.order_number || ' (yeniden)', o.id, v_actor);
  PERFORM fn_reservation_hold(v_res, o.business_id, o.branch_id, v_hold);
  IF o.status = 'expired' THEN
    -- the only way back from expired: an explicit re-reserve by a manager, with stock re-checked under lock above
    PERFORM set_config('boutiqueos.online_order_rereserve', 'on', true);
    UPDATE storefront_orders SET status = 'pending_confirmation', expired_at = NULL WHERE id = o.id;
    PERFORM set_config('boutiqueos.online_order_rereserve', 'off', true);
  END IF;
  PERFORM fn_online_event(o.id, o.business_id, 'rereserved', 'tenant', v_actor, jsonb_build_object('hold_until', v_exp, 'reservation_id', v_res));
  RETURN jsonb_build_object('order_number', o.order_number, 'status', CASE WHEN o.status = 'expired' THEN 'pending_confirmation' ELSE o.status::text END, 'reservation_expires_at', v_exp);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_online_order_rereserve(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_online_order_rereserve(UUID, UUID) TO authenticated;

-- Ready: the selling roles (operational).
CREATE OR REPLACE FUNCTION rpc_online_order_ready(p_business_id UUID, p_order_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID; o storefront_orders; r reservations;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  v_actor := fn_actor();
  SELECT * INTO o FROM storefront_orders WHERE id = p_order_id AND business_id = p_business_id FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: order %', p_order_id USING ERRCODE = 'P0002'; END IF;
  IF o.status = 'ready' THEN RETURN jsonb_build_object('order_number', o.order_number, 'status', 'ready', 'replayed', true); END IF;
  IF o.status <> 'confirmed' THEN RAISE EXCEPTION 'INVALID_STATE: order is %', o.status USING ERRCODE = '55000'; END IF;
  r := fn_online_order_reservation(o.id);
  IF r.id IS NULL OR r.status <> 'active' OR r.expires_at <= now() THEN RAISE EXCEPTION 'RESERVATION_EXPIRED: the hold of % has lapsed', o.order_number USING ERRCODE = '55000'; END IF;
  UPDATE storefront_orders SET status = 'ready', ready_at = now(), ready_by = v_actor WHERE id = o.id;
  PERFORM fn_online_event(o.id, o.business_id, 'ready', 'tenant', v_actor, '{}'::jsonb);
  RETURN jsonb_build_object('order_number', o.order_number, 'status', 'ready', 'replayed', false);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_online_order_ready(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_online_order_ready(UUID, UUID) TO authenticated;

-- Merchant cancellation: owner/manager, reason required, hold released, no movement, history kept.
CREATE OR REPLACE FUNCTION rpc_online_order_cancel(p_business_id UUID, p_order_id UUID, p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID; o storefront_orders; r reservations;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  v_actor := fn_actor();
  IF length(trim(COALESCE(p_reason, ''))) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED: say why the order is cancelled' USING ERRCODE = '22023'; END IF;
  SELECT * INTO o FROM storefront_orders WHERE id = p_order_id AND business_id = p_business_id FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: order %', p_order_id USING ERRCODE = 'P0002'; END IF;
  IF o.status = 'cancelled' THEN RETURN jsonb_build_object('order_number', o.order_number, 'status', 'cancelled', 'replayed', true); END IF;
  IF o.status NOT IN ('pending_confirmation','confirmed','ready') THEN RAISE EXCEPTION 'INVALID_STATE: order is %', o.status USING ERRCODE = '55000'; END IF;
  SELECT * INTO r FROM reservations WHERE storefront_order_id = o.id ORDER BY (status = 'active') DESC, created_at DESC, reservation_number DESC LIMIT 1 FOR UPDATE;
  IF r.id IS NOT NULL AND r.status = 'active' THEN
    UPDATE reservations SET status = CASE WHEN r.expires_at <= now() THEN 'expired'::reservation_status ELSE 'cancelled'::reservation_status END,
                            cancelled_by = v_actor, cancelled_at = now(), cancel_reason = trim(p_reason) WHERE id = r.id;
  END IF;
  UPDATE storefront_orders SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_actor, cancel_reason = trim(p_reason) WHERE id = o.id;
  PERFORM fn_online_event(o.id, o.business_id, 'cancelled', 'tenant', v_actor, jsonb_build_object('reason', trim(p_reason)));
  RETURN jsonb_build_object('order_number', o.order_number, 'status', 'cancelled', 'replayed', false);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_online_order_cancel(UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_online_order_cancel(UUID, UUID, TEXT) TO authenticated;

-- What the POS terminal preloads for an order: verified, reserved lines and the honoured price. Selling roles.
CREATE OR REPLACE FUNCTION rpc_pos_online_order(p_order_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE o storefront_orders; r reservations;
BEGIN
  SELECT * INTO o FROM storefront_orders WHERE id = p_order_id;
  IF o.id IS NULL OR NOT fn_is_member(o.business_id) THEN RAISE EXCEPTION 'NOT_FOUND: order %', p_order_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(o.business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  r := fn_online_order_reservation(o.id);
  RETURN jsonb_build_object(
    'id', o.id, 'order_number', o.order_number, 'status', o.status, 'branch_id', o.branch_id, 'customer_name', o.customer_name, 'phone', o.phone, 'total', o.total, 'currency', o.currency,
    'reservation_active', (r.id IS NOT NULL AND r.status = 'active' AND r.expires_at > now()), 'reservation_expires_at', r.expires_at,
    'lines', (SELECT COALESCE(jsonb_agg(jsonb_build_object('variant_id', i.variant_id, 'quantity', i.quantity, 'order_price', i.unit_price,
                                                          'list_price', fn_web_price(i.variant_id), 'unit_price', LEAST(i.unit_price, fn_web_price(i.variant_id)),
                                                          'name', i.product_name, 'labels', i.variant_labels, 'sku', pv.sku) ORDER BY i.line_no), '[]'::jsonb)
              FROM storefront_order_items i JOIN product_variants pv ON pv.id = i.variant_id WHERE i.order_id = o.id));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_pos_online_order(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_pos_online_order(UUID) TO authenticated;

-- POS conversion: the ONE place a sale is bound to an order. Items and prices come from the order,
-- never from the browser; the sale itself is the existing sale core (session, payments, stock, COGS,
-- reservation fulfilment). A retry with the same client_transaction_id or on a completed order replays.
CREATE OR REPLACE FUNCTION rpc_pos_complete_online_order(
  p_order_id UUID, p_register_session_id UUID, p_payments JSONB, p_client_transaction_id UUID,
  p_salesperson_id UUID DEFAULT NULL, p_note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID; o storefront_orders; r reservations; sess RECORD; v_items JSONB; v_disc BOOLEAN; v_sale JSONB; v_sale_id UUID;
BEGIN
  IF p_client_transaction_id IS NULL THEN RAISE EXCEPTION 'CLIENT_TRANSACTION_REQUIRED: POS sales must carry a client_transaction_id' USING ERRCODE = '22023'; END IF;
  SELECT * INTO o FROM storefront_orders WHERE id = p_order_id FOR UPDATE;
  IF o.id IS NULL OR NOT fn_is_member(o.business_id) THEN RAISE EXCEPTION 'NOT_FOUND: order %', p_order_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(o.business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  v_actor := fn_actor();
  IF o.status = 'completed' THEN
    SELECT jsonb_build_object('sale_id', sa.id, 'sale_number', sa.sale_number, 'total', sa.total, 'change_given', 0, 'replayed', true, 'order_number', o.order_number)
    INTO v_sale FROM sales sa WHERE sa.id = o.converted_sale_id;
    RETURN v_sale;
  END IF;
  IF o.status NOT IN ('confirmed','ready') THEN RAISE EXCEPTION 'INVALID_STATE: order % is % (confirm it first)', o.order_number, o.status USING ERRCODE = '55000'; END IF;
  SELECT business_id, branch_id INTO sess FROM register_sessions WHERE id = p_register_session_id;
  IF sess.business_id IS NULL OR sess.business_id <> o.business_id THEN RAISE EXCEPTION 'INVALID_REGISTER_SESSION: % not found in this business', p_register_session_id USING ERRCODE = '22023'; END IF;
  IF sess.branch_id <> o.branch_id THEN RAISE EXCEPTION 'BRANCH_MISMATCH: the order is picked up at another branch' USING ERRCODE = '22023'; END IF;
  SELECT * INTO r FROM reservations WHERE storefront_order_id = o.id ORDER BY (status = 'active') DESC, created_at DESC, reservation_number DESC LIMIT 1 FOR UPDATE;
  IF r.id IS NULL OR r.status <> 'active' OR r.expires_at <= now() THEN RAISE EXCEPTION 'RESERVATION_EXPIRED: the hold of % has lapsed; re-reserve first', o.order_number USING ERRCODE = '55000'; END IF;
  -- honoured price: never more than the order, never above the current list
  SELECT jsonb_agg(jsonb_build_object('variant_id', i.variant_id, 'quantity', i.quantity, 'unit_price', LEAST(i.unit_price, fn_web_price(i.variant_id))) ORDER BY i.line_no),
         bool_or(LEAST(i.unit_price, fn_web_price(i.variant_id)) < fn_web_price(i.variant_id))
  INTO v_items, v_disc FROM storefront_order_items i WHERE i.order_id = o.id;
  v_sale := fn_sale_core(o.business_id, o.branch_id, p_register_session_id, NULL, r.id,
                         p_client_transaction_id, NULL, NULL, v_items, p_payments,
                         CASE WHEN v_disc THEN 'negotiated'::discount_reason ELSE NULL END,
                         COALESCE(NULLIF(trim(COALESCE(p_note, '')), ''), 'Online sipariş ' || o.order_number),
                         0, NULL, NULL, NULL, p_salesperson_id);
  v_sale_id := (v_sale ->> 'sale_id')::uuid;
  PERFORM set_config('boutiqueos.online_order_conversion', 'on', true);
  UPDATE storefront_orders SET status = 'completed', completed_at = now(), converted_sale_id = v_sale_id WHERE id = o.id;
  PERFORM set_config('boutiqueos.online_order_conversion', 'off', true);
  PERFORM fn_online_event(o.id, o.business_id, 'converted', 'tenant', v_actor, jsonb_build_object('sale_id', v_sale_id, 'sale_number', v_sale ->> 'sale_number', 'total', v_sale ->> 'total'));
  PERFORM fn_online_event(o.id, o.business_id, 'completed', 'tenant', v_actor, '{}'::jsonb);
  RETURN v_sale || jsonb_build_object('order_number', o.order_number);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_pos_complete_online_order(UUID, UUID, JSONB, UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_pos_complete_online_order(UUID, UUID, JSONB, UUID, UUID, TEXT) TO authenticated;

-- Storefront settings gain the order switches (same signature, body only).
CREATE OR REPLACE FUNCTION rpc_storefront_upsert(p_business_id UUID, p_settings JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_slug TEXT; v_name TEXT; v_branch UUID; v_display stock_display; v_id UUID; v_enabled BOOLEAN; v_orders BOOLEAN; v_hold INTEGER;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  v_slug := lower(trim(COALESCE(p_settings ->> 'slug', '')));
  v_name := trim(COALESCE(p_settings ->> 'store_name', ''));
  IF v_slug !~ '^[a-z0-9](?:[a-z0-9-]{1,48}[a-z0-9])$' THEN RAISE EXCEPTION 'INVALID_SLUG: 3–50 characters, a-z 0-9 and hyphens' USING ERRCODE = '22023'; END IF;
  IF length(v_name) < 2 THEN RAISE EXCEPTION 'INVALID_NAME: store name is required' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM storefronts WHERE slug = v_slug AND business_id <> p_business_id) THEN RAISE EXCEPTION 'SLUG_TAKEN: % is used by another store', v_slug USING ERRCODE = '23505'; END IF;
  v_branch := NULLIF(p_settings ->> 'fulfillment_branch_id', '')::uuid;
  IF v_branch IS NOT NULL THEN PERFORM fn_assert_branch(p_business_id, v_branch); END IF;
  BEGIN v_display := COALESCE(p_settings ->> 'stock_display', 'state')::stock_display; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_STOCK_DISPLAY: %', p_settings ->> 'stock_display' USING ERRCODE = '22023'; END;
  v_enabled := COALESCE((p_settings ->> 'enabled')::boolean, false);
  v_orders := COALESCE((p_settings ->> 'orders_enabled')::boolean, true);
  v_hold := LEAST(GREATEST(COALESCE((p_settings ->> 'order_hold_minutes')::int, 1440), 30), 10080);
  INSERT INTO storefronts (business_id, enabled, slug, store_name, tagline, announcement, about, instagram, whatsapp, contact_email, contact_phone, fulfillment_branch_id, stock_display, low_stock_threshold,
                           orders_enabled, order_hold_minutes, pickup_note)
  VALUES (p_business_id, v_enabled, v_slug, v_name,
          NULLIF(trim(COALESCE(p_settings ->> 'tagline', '')), ''), NULLIF(trim(COALESCE(p_settings ->> 'announcement', '')), ''), NULLIF(trim(COALESCE(p_settings ->> 'about', '')), ''),
          NULLIF(ltrim(trim(COALESCE(p_settings ->> 'instagram', '')), '@'), ''), NULLIF(regexp_replace(COALESCE(p_settings ->> 'whatsapp', ''), '[^0-9+]', '', 'g'), ''),
          NULLIF(lower(trim(COALESCE(p_settings ->> 'contact_email', ''))), ''), NULLIF(trim(COALESCE(p_settings ->> 'contact_phone', '')), ''),
          v_branch, v_display, LEAST(GREATEST(COALESCE((p_settings ->> 'low_stock_threshold')::int, 3), 1), 50),
          v_orders, v_hold, NULLIF(left(trim(COALESCE(p_settings ->> 'pickup_note', '')), 300), ''))
  ON CONFLICT (business_id) DO UPDATE SET
    enabled = EXCLUDED.enabled, slug = EXCLUDED.slug, store_name = EXCLUDED.store_name, tagline = EXCLUDED.tagline, announcement = EXCLUDED.announcement,
    about = EXCLUDED.about, instagram = EXCLUDED.instagram, whatsapp = EXCLUDED.whatsapp, contact_email = EXCLUDED.contact_email, contact_phone = EXCLUDED.contact_phone,
    fulfillment_branch_id = EXCLUDED.fulfillment_branch_id, stock_display = EXCLUDED.stock_display, low_stock_threshold = EXCLUDED.low_stock_threshold,
    orders_enabled = EXCLUDED.orders_enabled, order_hold_minutes = EXCLUDED.order_hold_minutes, pickup_note = EXCLUDED.pickup_note, updated_at = now()
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('storefront_id', v_id, 'slug', v_slug, 'enabled', v_enabled);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_storefront_upsert(UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_storefront_upsert(UUID, JSONB) TO authenticated;

-- The public store resolve exposes the order switches and the pickup branch name (same signature, body only).
CREATE OR REPLACE FUNCTION rpc_shop_resolve(p_slug TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s storefronts; v_branch UUID; v JSONB;
BEGIN
  s := fn_shop_resolve(p_slug);
  IF s.id IS NULL THEN RETURN NULL; END IF;
  v_branch := fn_shop_branch(s);
  SELECT jsonb_build_object(
    'slug', s.slug, 'store_name', s.store_name, 'tagline', s.tagline, 'announcement', s.announcement, 'about', s.about,
    'instagram', s.instagram, 'whatsapp', s.whatsapp, 'contact_email', s.contact_email, 'contact_phone', s.contact_phone,
    'logo_path', s.logo_path, 'theme', s.theme, 'stock_display', s.stock_display, 'low_stock_threshold', s.low_stock_threshold,
    'currency', b.base_currency,
    'orders_enabled', (s.orders_enabled AND v_branch IS NOT NULL), 'order_hold_minutes', s.order_hold_minutes, 'pickup_note', s.pickup_note,
    'pickup_branch', (SELECT br.name FROM branches br WHERE br.id = v_branch),
    'categories', (SELECT COALESCE(jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name, 'count', x.n) ORDER BY x.sort_order, x.name), '[]'::jsonb)
                   FROM (SELECT c.slug, c.name, c.sort_order, count(*) AS n FROM categories c JOIN products p ON p.category_id = c.id
                         WHERE c.business_id = s.business_id AND c.is_active AND p.web_published AND p.status = 'active'
                         GROUP BY c.id) x),
    'published_count', (SELECT count(*) FROM products p WHERE p.business_id = s.business_id AND p.web_published AND p.status = 'active'))
  INTO v FROM businesses b WHERE b.id = s.business_id;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_shop_resolve(TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_resolve(TEXT) TO anon, authenticated;

-- ============================================================
-- END phase 14B
-- ============================================================
