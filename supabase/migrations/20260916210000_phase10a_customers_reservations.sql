-- ============================================================
-- Phase 10A — customer CRM + reservation foundation
-- ============================================================
-- Audit (Rev 3): customers are tenant-scoped with caches maintained by the sale RPCs;
-- reservations/reservation_items exist with the lifecycle active → converted | cancelled |
-- expired, an explicit expires_at, RPC-only writes, and — the part that matters — the
-- availability rule is already the authoritative one:
--   available = SELLABLE ledger quantity − ACTIVE, NON-EXPIRED reserved quantity
-- (fn_reserved_qty / v_stock_available), holds never touch inventory_movements, the sale
-- core converts a reservation in the SAME transaction it consumes the stock, and both the
-- sale and the reservation lock the same variant_cost_pools rows (fn_lock_pools), so a
-- reservation and a POS sale cannot both take the last unit. `converted` is the schema's
-- name for FULFILLED (kept: the sale core sets it and is not copied again).
-- What 10A adds:
--   customers: phone optional, no hard uniqueness (duplicates are a warning decided in the
--     app, never a silent merge), server-side normalised phone/email/instagram columns,
--     extensible source (customer_sources), created_by stamp, PII policies: owner / manager /
--     sales_staff only (stock_staff has no CRM), search + duplicate RPCs that never dump the table;
--   reservations: fulfilled_at/by stamped by trigger, immutability of every non-active row,
--     POS-shaped create / update / cancel / expire RPCs (business from the branch, customer
--     required, selling roles), default hold length from settings.reservation_default_hours
--     (48 h when absent), policies restricted to selling roles;
--   rpc_pos_complete_sale gains p_reservation_id (fulfilment = one atomic sale).
-- ============================================================

-- ------------------------------------------------------------ helpers
CREATE OR REPLACE FUNCTION fn_is_selling(p_business_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (SELECT 1 FROM business_members
                 WHERE business_id = p_business_id AND user_id = auth.uid() AND is_active
                   AND role IN ('owner','manager','sales_staff'));
$$;
REVOKE EXECUTE ON FUNCTION fn_is_selling(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_is_selling(UUID) TO authenticated;

-- Turkish-first phone normalisation: digits only; 5XXXXXXXXX → 905…, 05… → 905…, 90… kept,
-- 0090… → 90…; anything else keeps its digits. Display form is never touched.
CREATE OR REPLACE FUNCTION fn_normalize_phone(p TEXT)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, public AS $$
DECLARE d TEXT := regexp_replace(COALESCE(p, ''), '\D', '', 'g');
BEGIN
  IF d = '' THEN RETURN NULL; END IF;
  IF length(d) = 10 AND d LIKE '5%' THEN RETURN '90' || d; END IF;
  IF length(d) = 11 AND d LIKE '05%' THEN RETURN '9' || d; END IF;
  IF length(d) = 13 AND d LIKE '0090%' THEN RETURN substr(d, 3); END IF;
  IF length(d) = 14 AND d LIKE '00905%' THEN RETURN substr(d, 3); END IF;
  RETURN d;
END $$;
CREATE OR REPLACE FUNCTION fn_normalize_instagram(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public AS $$
  SELECT NULLIF(lower(regexp_replace(trim(COALESCE(p, '')), '^@+', '')), '');
$$;
-- pure text helpers, harmless to expose; generated columns and the search RPC use them
REVOKE EXECUTE ON FUNCTION fn_normalize_phone(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION fn_normalize_instagram(TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_normalize_phone(TEXT) TO authenticated;
GRANT  EXECUTE ON FUNCTION fn_normalize_instagram(TEXT) TO authenticated;

-- ------------------------------------------------------------ customer sources (platform defaults + tenant rows)
CREATE TABLE customer_sources (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id) ON DELETE CASCADE,   -- NULL = platform default
  code        TEXT NOT NULL CHECK (code ~ '^[a-z0-9_]{2,40}$'),
  label       TEXT NOT NULL CHECK (length(trim(label)) BETWEEN 1 AND 60),
  sort_order  INTEGER NOT NULL DEFAULT 100,
  is_active   BOOLEAN NOT NULL DEFAULT true,
  UNIQUE NULLS NOT DISTINCT (business_id, code)
);
INSERT INTO customer_sources (business_id, code, label, sort_order) VALUES
  (NULL, 'walk_in',   'Mağaza',    10), (NULL, 'instagram', 'Instagram', 20), (NULL, 'whatsapp', 'WhatsApp', 30),
  (NULL, 'website',   'Web sitesi', 40), (NULL, 'referral', 'Tavsiye',   50), (NULL, 'other',    'Diğer',    90);
ALTER TABLE customer_sources ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_cs_select ON customer_sources FOR SELECT USING (business_id IS NULL OR fn_is_member(business_id));
CREATE POLICY pol_cs_write ON customer_sources FOR ALL
  USING (business_id IS NOT NULL AND fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (business_id IS NOT NULL AND fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

-- ------------------------------------------------------------ customers
ALTER TABLE customers DROP CONSTRAINT customers_business_id_phone_key;
ALTER TABLE customers ALTER COLUMN phone DROP NOT NULL;
ALTER TABLE customers
  ADD COLUMN source TEXT,
  ADD COLUMN phone_normalized TEXT GENERATED ALWAYS AS (fn_normalize_phone(phone)) STORED,
  ADD COLUMN email_normalized TEXT GENERATED ALWAYS AS (NULLIF(lower(trim(email)), '')) STORED,
  ADD COLUMN instagram_normalized TEXT GENERATED ALWAYS AS (fn_normalize_instagram(instagram)) STORED,
  ADD CONSTRAINT chk_customer_name CHECK (length(trim(COALESCE(full_name, ''))) BETWEEN 1 AND 120),
  ADD CONSTRAINT chk_customer_email CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');
CREATE INDEX idx_customers_phone_norm ON customers (business_id, phone_normalized) WHERE phone_normalized IS NOT NULL;
CREATE INDEX idx_customers_email_norm ON customers (business_id, email_normalized) WHERE email_normalized IS NOT NULL;
CREATE INDEX idx_customers_instagram_norm ON customers (business_id, instagram_normalized) WHERE instagram_normalized IS NOT NULL;
CREATE TRIGGER trg_created_by_customers BEFORE INSERT ON customers FOR EACH ROW EXECUTE FUNCTION fn_stamp_created_by();

CREATE OR REPLACE FUNCTION fn_validate_customer()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF NEW.source IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM customer_sources s WHERE s.code = NEW.source AND s.is_active AND (s.business_id IS NULL OR s.business_id = NEW.business_id)) THEN
    RAISE EXCEPTION 'INVALID_SOURCE: % is not a customer source of this business', NEW.source USING ERRCODE='22023';
  END IF;
  IF NEW.instagram IS NOT NULL THEN NEW.instagram := NULLIF(regexp_replace(trim(NEW.instagram), '^@+', ''), ''); END IF;
  IF NEW.email IS NOT NULL THEN NEW.email := NULLIF(trim(NEW.email), ''); END IF;
  IF NEW.phone IS NOT NULL THEN NEW.phone := NULLIF(trim(NEW.phone), ''); END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_validate_customer BEFORE INSERT OR UPDATE ON customers FOR EACH ROW EXECUTE FUNCTION fn_validate_customer();

-- PII: owner / manager / sales_staff (the people who serve and sell); stock_staff has no CRM.
DROP POLICY pol_cust_select ON customers;
DROP POLICY pol_cust_insert ON customers;
DROP POLICY pol_cust_update ON customers;
CREATE POLICY pol_cust_select ON customers FOR SELECT USING (fn_is_selling(business_id));
CREATE POLICY pol_cust_insert ON customers FOR INSERT WITH CHECK (fn_is_selling(business_id) AND fn_is_business_active(business_id));
CREATE POLICY pol_cust_update ON customers FOR UPDATE
  USING (fn_is_selling(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_selling(business_id) AND fn_is_business_active(business_id));
REVOKE DELETE, TRUNCATE ON customers FROM anon, authenticated;
-- the sale/void caches are written by the RPCs only: table-level UPDATE goes, the operational
-- columns come back as column grants (RLS still applies on top)
REVOKE UPDATE ON customers FROM anon, authenticated;
GRANT UPDATE (full_name, phone, whatsapp, instagram, email, birth_date, notes, is_active, source) ON customers TO authenticated;

-- Search: name / normalised phone / email / instagram, limited, never the whole table.
CREATE OR REPLACE FUNCTION rpc_customer_search(p_business_id UUID, p_query TEXT, p_limit INT DEFAULT 20)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_q TEXT := trim(COALESCE(p_query, '')); v_phone TEXT; v_ig TEXT; v_out JSONB;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  IF length(v_q) < 2 OR length(v_q) > 80 THEN RETURN '[]'::jsonb; END IF;
  v_phone := fn_normalize_phone(v_q); v_ig := fn_normalize_instagram(v_q);
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', c.id, 'full_name', c.full_name, 'phone', c.phone, 'email', c.email, 'instagram', c.instagram,
           'source', c.source, 'is_active', c.is_active, 'order_count', c.order_count, 'last_purchase_at', c.last_purchase_at)
           ORDER BY c.is_active DESC, c.last_purchase_at DESC NULLS LAST, c.full_name), '[]'::jsonb)
  INTO v_out
  FROM (SELECT * FROM customers c
        WHERE c.business_id = p_business_id AND (
              c.full_name ILIKE '%' || v_q || '%'
           OR (v_phone IS NOT NULL AND length(v_phone) >= 4 AND c.phone_normalized LIKE '%' || v_phone || '%')
           OR (c.email_normalized IS NOT NULL AND c.email_normalized LIKE '%' || lower(v_q) || '%')
           OR (v_ig IS NOT NULL AND c.instagram_normalized LIKE '%' || v_ig || '%'))
        ORDER BY c.is_active DESC, c.last_purchase_at DESC NULLS LAST, c.full_name
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50)) c;
  RETURN v_out;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_customer_search(UUID, TEXT, INT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_customer_search(UUID, TEXT, INT) TO authenticated;

-- Duplicate probe: exact normalised phone / email / instagram within the tenant → a warning
-- for the operator (the app decides whether a manager may confirm an intentional duplicate).
CREATE OR REPLACE FUNCTION rpc_customer_duplicates(p_business_id UUID, p_phone TEXT DEFAULT NULL, p_email TEXT DEFAULT NULL, p_instagram TEXT DEFAULT NULL, p_exclude_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_phone TEXT := fn_normalize_phone(p_phone); v_email TEXT := NULLIF(lower(trim(COALESCE(p_email,''))), ''); v_ig TEXT := fn_normalize_instagram(p_instagram);
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'full_name', c.full_name, 'phone', c.phone, 'email', c.email, 'instagram', c.instagram,
                     'match', CASE WHEN v_phone IS NOT NULL AND c.phone_normalized = v_phone THEN 'phone'
                                   WHEN v_email IS NOT NULL AND c.email_normalized = v_email THEN 'email' ELSE 'instagram' END) ORDER BY c.full_name)
                   FROM customers c
                   WHERE c.business_id = p_business_id AND (p_exclude_id IS NULL OR c.id <> p_exclude_id)
                     AND ((v_phone IS NOT NULL AND c.phone_normalized = v_phone)
                       OR (v_email IS NOT NULL AND c.email_normalized = v_email)
                       OR (v_ig IS NOT NULL AND c.instagram_normalized = v_ig))), '[]'::jsonb);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_customer_duplicates(UUID, TEXT, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_customer_duplicates(UUID, TEXT, TEXT, TEXT, UUID) TO authenticated;

-- ------------------------------------------------------------ reservations
ALTER TABLE reservations
  ADD COLUMN fulfilled_at TIMESTAMPTZ,
  ADD COLUMN fulfilled_by UUID REFERENCES profiles(id),
  ADD COLUMN updated_by   UUID REFERENCES profiles(id);
CREATE INDEX idx_reservations_open ON reservations (business_id, branch_id, expires_at) WHERE status = 'active';

-- Every non-active row is history. The only legal transitions are active → converted
-- (the sale core, which links the sale), active → cancelled, active → expired.
CREATE OR REPLACE FUNCTION fn_guard_reservation()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'IMMUTABLE: reservations cannot be deleted (id=%)', OLD.id USING ERRCODE='55000'; END IF;
  IF OLD.status <> 'active' THEN RAISE EXCEPTION 'IMMUTABLE: reservation % is % and frozen', OLD.id, OLD.status USING ERRCODE='55000'; END IF;
  IF NEW.status = 'converted' THEN
    IF NEW.converted_to_sale_id IS NULL THEN RAISE EXCEPTION 'INTEGRITY: a fulfilled reservation must link its sale' USING ERRCODE='23000'; END IF;
    NEW.fulfilled_at := COALESCE(NEW.fulfilled_at, now()); NEW.fulfilled_by := COALESCE(NEW.fulfilled_by, auth.uid());
  ELSIF NEW.converted_to_sale_id IS NOT NULL THEN
    RAISE EXCEPTION 'INTEGRITY: only a fulfilled reservation carries a sale' USING ERRCODE='23000';
  END IF;
  IF NEW.status = 'active' THEN NEW.updated_by := COALESCE(auth.uid(), NEW.updated_by); END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_reservation BEFORE UPDATE OR DELETE ON reservations FOR EACH ROW EXECUTE FUNCTION fn_guard_reservation();
CREATE OR REPLACE FUNCTION fn_guard_reservation_items()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_status reservation_status;
BEGIN
  SELECT status INTO v_status FROM reservations WHERE id = COALESCE(NEW.reservation_id, OLD.reservation_id);
  IF v_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'IMMUTABLE: items of a % reservation are frozen', v_status USING ERRCODE='55000';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER trg_guard_reservation_items BEFORE INSERT OR UPDATE OR DELETE ON reservation_items FOR EACH ROW EXECUTE FUNCTION fn_guard_reservation_items();

DROP POLICY pol_res_select ON reservations;
DROP POLICY pol_resi_select ON reservation_items;
CREATE POLICY pol_res_select  ON reservations      FOR SELECT USING (fn_is_selling(business_id));
CREATE POLICY pol_resi_select ON reservation_items FOR SELECT USING (fn_is_selling(business_id));
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON reservations, reservation_items FROM anon, authenticated;

CREATE OR REPLACE FUNCTION fn_reservation_default_expiry(p_business_id UUID)
RETURNS TIMESTAMPTZ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT now() + make_interval(hours => COALESCE((settings ->> 'reservation_default_hours')::int, 48)) FROM businesses WHERE id = p_business_id;
$$;
REVOKE EXECUTE ON FUNCTION fn_reservation_default_expiry(UUID) FROM PUBLIC, anon, authenticated;

-- Shared item validation + hold under pool locks (create and update).
CREATE OR REPLACE FUNCTION fn_reservation_hold(p_reservation_id UUID, p_business_id UUID, p_branch_id UUID, p_items JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE it RECORD; v_vids UUID[]; v_avail INT; v_lines JSONB := '[]'::jsonb; v_status product_status; v_pstatus product_status;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'EMPTY_RESERVATION: at least one item is required' USING ERRCODE='22023';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e WHERE (e->>'variant_id') IS NULL OR COALESCE((e->>'quantity')::int, 0) <= 0) THEN
    RAISE EXCEPTION 'INVALID_QTY: variant_id and quantity > 0 required' USING ERRCODE='22023';
  END IF;
  -- lock the union of the old and the new variants (edit) so nothing slips between the check and the write
  SELECT array_agg(DISTINCT v ORDER BY v) INTO v_vids FROM (
    SELECT (e->>'variant_id')::UUID AS v FROM jsonb_array_elements(p_items) e
    UNION SELECT variant_id FROM reservation_items WHERE reservation_id = p_reservation_id) x;
  IF EXISTS (SELECT 1 FROM unnest(v_vids) v WHERE NOT EXISTS (SELECT 1 FROM product_variants pv WHERE pv.id = v AND pv.business_id = p_business_id)) THEN
    RAISE EXCEPTION 'INVALID_VARIANT: reservation contains a variant that is not in this business' USING ERRCODE='22023';
  END IF;
  PERFORM fn_lock_pools(p_business_id, p_branch_id, v_vids);
  DELETE FROM reservation_items WHERE reservation_id = p_reservation_id;
  FOR it IN SELECT (e->>'variant_id')::UUID AS variant_id, SUM((e->>'quantity')::INT) AS qty
            FROM jsonb_array_elements(p_items) e GROUP BY 1 ORDER BY 1 LOOP
    SELECT pv.status, p.status INTO v_status, v_pstatus FROM product_variants pv JOIN products p ON p.id = pv.product_id WHERE pv.id = it.variant_id;
    IF v_status <> 'active' OR v_pstatus <> 'active' THEN
      RAISE EXCEPTION 'VARIANT_NOT_SELLABLE: % (product/variant not active)', it.variant_id USING ERRCODE='55000';
    END IF;
    v_avail := fn_bucket_qty(p_business_id, p_branch_id, it.variant_id, 'sellable') - fn_reserved_qty(p_business_id, p_branch_id, it.variant_id, p_reservation_id);
    IF v_avail < it.qty THEN
      RAISE EXCEPTION 'INSUFFICIENT_AVAILABLE_STOCK: variant % available=% requested=%', it.variant_id, v_avail, it.qty USING ERRCODE='55000';
    END IF;
    INSERT INTO reservation_items (reservation_id, variant_id, quantity) VALUES (p_reservation_id, it.variant_id, it.qty);
    v_lines := v_lines || jsonb_build_object('variant_id', it.variant_id, 'quantity', it.qty, 'available_before', v_avail);
  END LOOP;
  RETURN v_lines;
END $$;
REVOKE EXECUTE ON FUNCTION fn_reservation_hold(UUID, UUID, UUID, JSONB) FROM PUBLIC, anon, authenticated;

-- Create: business from the branch, customer required, selling roles, all or nothing.
CREATE OR REPLACE FUNCTION rpc_pos_reservation_create(
  p_branch_id UUID, p_customer_id UUID, p_items JSONB,
  p_expires_at TIMESTAMPTZ DEFAULT NULL, p_note TEXT DEFAULT NULL, p_source TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); v_biz UUID; v_id UUID := gen_random_uuid(); v_exp TIMESTAMPTZ; v_num TEXT; v_lines JSONB;
BEGIN
  SELECT business_id INTO v_biz FROM branches WHERE id = p_branch_id;
  IF v_biz IS NULL OR NOT fn_is_member(v_biz) THEN RAISE EXCEPTION 'INVALID_BRANCH: %', p_branch_id USING ERRCODE='22023'; END IF;
  PERFORM fn_require_role(v_biz, ARRAY['owner','manager','sales_staff']::user_role[]);
  PERFORM fn_assert_branch(v_biz, p_branch_id);
  IF p_customer_id IS NULL OR NOT EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND business_id = v_biz AND is_active) THEN
    RAISE EXCEPTION 'INVALID_CUSTOMER: %', p_customer_id USING ERRCODE='22023';
  END IF;
  v_exp := COALESCE(p_expires_at, fn_reservation_default_expiry(v_biz));
  IF v_exp <= now() THEN RAISE EXCEPTION 'INVALID_EXPIRY: expires_at must be in the future' USING ERRCODE='22023'; END IF;
  IF v_exp > now() + interval '90 days' THEN RAISE EXCEPTION 'INVALID_EXPIRY: a hold cannot exceed 90 days' USING ERRCODE='22023'; END IF;
  v_num := fn_next_sequence(v_biz, 'RV');
  INSERT INTO reservations (id, business_id, branch_id, reservation_number, customer_id, source, status, expires_at, note, created_by)
  VALUES (v_id, v_biz, p_branch_id, v_num, p_customer_id, NULLIF(trim(COALESCE(p_source,'')), ''), 'active', v_exp, NULLIF(trim(COALESCE(p_note,'')), ''), v_actor);
  v_lines := fn_reservation_hold(v_id, v_biz, p_branch_id, p_items);
  RETURN jsonb_build_object('reservation_id', v_id, 'reservation_number', v_num, 'expires_at', v_exp, 'lines', v_lines);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_pos_reservation_create(UUID, UUID, JSONB, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_pos_reservation_create(UUID, UUID, JSONB, TIMESTAMPTZ, TEXT, TEXT) TO authenticated;

-- Edit an ACTIVE reservation: items are replaced atomically under the same locks.
CREATE OR REPLACE FUNCTION rpc_reservation_update(p_reservation_id UUID, p_items JSONB, p_expires_at TIMESTAMPTZ DEFAULT NULL, p_note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE r RECORD; v_lines JSONB; v_exp TIMESTAMPTZ;
BEGIN
  SELECT * INTO r FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF r.id IS NULL OR NOT fn_is_member(r.business_id) THEN RAISE EXCEPTION 'NOT_FOUND: reservation %', p_reservation_id USING ERRCODE='P0002'; END IF;
  PERFORM fn_require_role(r.business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  IF r.status <> 'active' THEN RAISE EXCEPTION 'INVALID_STATE: reservation % is %', r.id, r.status USING ERRCODE='55000'; END IF;
  IF r.expires_at <= now() THEN RAISE EXCEPTION 'RESERVATION_EXPIRED: reservation % expired at %', r.id, r.expires_at USING ERRCODE='55000'; END IF;
  v_exp := COALESCE(p_expires_at, r.expires_at);
  IF v_exp <= now() THEN RAISE EXCEPTION 'INVALID_EXPIRY: expires_at must be in the future' USING ERRCODE='22023'; END IF;
  IF v_exp > now() + interval '90 days' THEN RAISE EXCEPTION 'INVALID_EXPIRY: a hold cannot exceed 90 days' USING ERRCODE='22023'; END IF;
  v_lines := fn_reservation_hold(r.id, r.business_id, r.branch_id, p_items);
  UPDATE reservations SET expires_at = v_exp, note = COALESCE(NULLIF(trim(COALESCE(p_note,'')), ''), note) WHERE id = r.id;
  RETURN jsonb_build_object('reservation_id', r.id, 'reservation_number', r.reservation_number, 'expires_at', v_exp, 'lines', v_lines);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_reservation_update(UUID, JSONB, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_reservation_update(UUID, JSONB, TIMESTAMPTZ, TEXT) TO authenticated;

-- Cancel: no movement, availability released at once, history kept. Only ACTIVE can be
-- cancelled; an active row past its expiry is recorded as expired instead.
CREATE OR REPLACE FUNCTION rpc_reservation_cancel(p_reservation_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); r RECORD; v_new reservation_status;
BEGIN
  SELECT * INTO r FROM reservations WHERE id = p_reservation_id FOR UPDATE;
  IF r.id IS NULL OR NOT fn_is_member(r.business_id) THEN RAISE EXCEPTION 'NOT_FOUND: reservation %', p_reservation_id USING ERRCODE='P0002'; END IF;
  PERFORM fn_require_role(r.business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  IF r.status <> 'active' THEN RAISE EXCEPTION 'INVALID_STATE: reservation % is %', r.id, r.status USING ERRCODE='55000'; END IF;
  v_new := CASE WHEN r.expires_at <= now() THEN 'expired'::reservation_status ELSE 'cancelled'::reservation_status END;
  UPDATE reservations SET status = v_new, cancelled_by = v_actor, cancelled_at = now(), cancel_reason = NULLIF(trim(COALESCE(p_reason,'')), '')
  WHERE id = r.id;
  RETURN jsonb_build_object('reservation_id', r.id, 'status', v_new);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_reservation_cancel(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_reservation_cancel(UUID, TEXT) TO authenticated;

-- Cleanup only: availability never depends on it (fn_reserved_qty already ignores expired
-- active rows). Marks past-due ACTIVE rows EXPIRED so lists and history read right.
CREATE OR REPLACE FUNCTION rpc_reservations_expire(p_business_id UUID)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE n INT;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager','sales_staff']::user_role[]);
  UPDATE reservations SET status = 'expired' WHERE business_id = p_business_id AND status = 'active' AND expires_at <= now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_reservations_expire(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_reservations_expire(UUID) TO authenticated;

-- ------------------------------------------------------------ POS: fulfil a reservation in the sale itself
-- Same body as 20260916140000 plus p_reservation_id handed to the sale core, which
-- validates the hold (active, not expired, same branch, every held item in the cart with at
-- least the held quantity), consumes the stock and converts the reservation in ONE transaction.
DROP FUNCTION rpc_pos_complete_sale(UUID, JSONB, JSONB, UUID, UUID, UUID, discount_reason, TEXT, TEXT);
CREATE OR REPLACE FUNCTION rpc_pos_complete_sale(
  p_register_session_id UUID, p_items JSONB, p_payments JSONB, p_client_transaction_id UUID,
  p_customer_id UUID DEFAULT NULL, p_salesperson_id UUID DEFAULT NULL,
  p_discount_reason discount_reason DEFAULT NULL, p_note TEXT DEFAULT NULL, p_device_id TEXT DEFAULT NULL,
  p_reservation_id UUID DEFAULT NULL
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
  RETURN fn_sale_core(s.business_id, s.branch_id, p_register_session_id, p_customer_id, p_reservation_id,
                      p_client_transaction_id, p_device_id, NULL, p_items, p_payments, p_discount_reason, p_note,
                      0, NULL, NULL, NULL, p_salesperson_id);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_pos_complete_sale(UUID, JSONB, JSONB, UUID, UUID, UUID, discount_reason, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_pos_complete_sale(UUID, JSONB, JSONB, UUID, UUID, UUID, discount_reason, TEXT, TEXT, UUID) TO authenticated;
