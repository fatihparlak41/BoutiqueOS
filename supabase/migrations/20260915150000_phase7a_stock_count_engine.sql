-- ============================================================
-- Phase 7A — physical stock count engine (branch level)
-- ============================================================
-- Additive. The inventory ledger (inventory_movements) stays authoritative and its
-- primitives are reused unchanged: fn_lock_pools, fn_bucket_qty, fn_post_to_cost_pool,
-- fn_ledger_post. A count is a working document; nothing below POST writes a movement.
--
--   stock_count_status / stock_count_type   enums
--   stock_counts                             header (draft → counting → review → posted | cancelled)
--   stock_count_lines                        one row per variant × bucket; counted NULL = unresolved
--   stock_count_scans                        append-only event log, idempotent by client_transaction_id
--   rpc_stock_count_create / _scan / _set_quantity / _review / _reopen / _cancel / _post
--   uix_movement_stock_count_line            one movement per line, ever — double posting is
--                                            impossible at the database even without the row lock
--
-- Client writes to the three tables are not granted at all; every change goes through the
-- RPCs, which check role, business status, branch, document state and — at POST — that the
-- ledger still matches the review snapshot. Cost never appears on count rows: the value
-- side of each adjustment lives in inventory_movement_costs (manager+), as for any movement.
--
-- The Rev 3 stubs inventory_counts / inventory_count_lines (0 rows, no RPC, no UI) are left
-- untouched and superseded by this engine.
--
-- Rollback: drop the RPCs, triggers, index, the three tables and the two enums in reverse
-- order. No existing row is rewritten.
-- ============================================================

CREATE TYPE stock_count_status AS ENUM ('draft','counting','review','posted','cancelled');
CREATE TYPE stock_count_type   AS ENUM ('full','cycle');

-- ------------------------------------------------------------ tables
CREATE TABLE stock_counts (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id              UUID NOT NULL REFERENCES businesses(id),
  branch_id                UUID NOT NULL,
  count_number             TEXT NOT NULL,
  count_type               stock_count_type   NOT NULL DEFAULT 'full',
  status                   stock_count_status NOT NULL DEFAULT 'draft',
  note                     TEXT,
  created_by               UUID REFERENCES profiles(id),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  counting_started_at      TIMESTAMPTZ,
  reviewed_at              TIMESTAMPTZ,
  reviewed_by              UUID REFERENCES profiles(id),
  -- newest ledger row at the branch when the review snapshot was taken (diagnostic only;
  -- staleness is decided per line by re-reading the ledger at POST)
  review_ledger_watermark  TIMESTAMPTZ,
  posted_at                TIMESTAMPTZ,
  posted_by                UUID REFERENCES profiles(id),
  cancelled_at             TIMESTAMPTZ,
  cancelled_by             UUID REFERENCES profiles(id),
  cancel_reason            TEXT,
  UNIQUE (business_id, count_number),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, branch_id) REFERENCES branches (business_id, id)
);
CREATE INDEX ix_stock_counts_business_status ON stock_counts (business_id, status, created_at DESC);

CREATE TABLE stock_count_lines (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID NOT NULL REFERENCES businesses(id),   -- trigger-populated from the count
  stock_count_id     UUID NOT NULL,
  variant_id         UUID NOT NULL,
  bucket             inventory_bucket NOT NULL DEFAULT 'sellable',
  -- ledger quantity captured when the count entered REVIEW; NULL before that
  expected_quantity  INTEGER CHECK (expected_quantity IS NULL OR expected_quantity >= 0),
  -- NULL = not counted / not resolved. 0 is only ever written by an explicit action.
  counted_quantity   INTEGER CHECK (counted_quantity IS NULL OR counted_quantity >= 0),
  zero_confirmed     BOOLEAN NOT NULL DEFAULT false,
  counted_by         UUID REFERENCES profiles(id),
  counted_at         TIMESTAMPTZ,
  -- filled by POST
  posted_delta       INTEGER,
  movement_id        UUID REFERENCES inventory_movements(id),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (stock_count_id, variant_id, bucket),
  UNIQUE (business_id, id),
  FOREIGN KEY (business_id, stock_count_id) REFERENCES stock_counts     (business_id, id),
  FOREIGN KEY (business_id, variant_id)     REFERENCES product_variants (business_id, id),
  CONSTRAINT stock_count_lines_zero_chk CHECK (NOT zero_confirmed OR counted_quantity = 0)
);

CREATE TABLE stock_count_scans (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id            UUID NOT NULL REFERENCES businesses(id),   -- trigger-populated from the count
  stock_count_id         UUID NOT NULL,
  line_id                UUID NOT NULL,
  variant_id             UUID NOT NULL,
  bucket                 inventory_bucket NOT NULL,
  kind                   TEXT NOT NULL CHECK (kind IN ('scan','undo','set','zero_confirm')),
  delta                  INTEGER NOT NULL,
  quantity_after         INTEGER NOT NULL CHECK (quantity_after >= 0),
  -- offline-ready fields: the client names each event; a replay is a no-op
  client_transaction_id  UUID NOT NULL,
  device_id              TEXT,
  client_at              TIMESTAMPTZ,
  created_by             UUID REFERENCES profiles(id),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (stock_count_id, client_transaction_id),
  FOREIGN KEY (business_id, stock_count_id) REFERENCES stock_counts      (business_id, id),
  FOREIGN KEY (business_id, line_id)        REFERENCES stock_count_lines (business_id, id)
);
CREATE INDEX ix_stock_count_scans_count ON stock_count_scans (stock_count_id, created_at DESC);

CREATE TRIGGER trg_bid_stock_count_lines BEFORE INSERT OR UPDATE ON stock_count_lines
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('stock_counts','stock_count_id');
CREATE TRIGGER trg_bid_stock_count_scans BEFORE INSERT OR UPDATE ON stock_count_scans
  FOR EACH ROW EXECUTE FUNCTION fn_set_business_id_from_parent('stock_counts','stock_count_id');

-- One ledger row per count line, ever. Second line of defence behind the header lock.
CREATE UNIQUE INDEX uix_movement_stock_count_line
  ON inventory_movements (reference_id) WHERE reference_type = 'stock_count_line';

-- ------------------------------------------------------------ immutability guards
-- Posted and cancelled documents cannot change or disappear, whoever is asking.
CREATE OR REPLACE FUNCTION fn_guard_stock_count()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status IN ('posted','cancelled') THEN
      RAISE EXCEPTION 'IMMUTABLE: stock count % is %', OLD.count_number, OLD.status USING ERRCODE = '55000';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status IN ('posted','cancelled') THEN
    RAISE EXCEPTION 'IMMUTABLE: stock count % is %', OLD.count_number, OLD.status USING ERRCODE = '55000';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_stock_count BEFORE UPDATE OR DELETE ON stock_counts
  FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_count();

CREATE OR REPLACE FUNCTION fn_guard_stock_count_line()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_status stock_count_status;
BEGIN
  SELECT status INTO v_status FROM stock_counts WHERE id = COALESCE(NEW.stock_count_id, OLD.stock_count_id);
  -- POST writes posted_delta / movement_id on the lines while the header is still 'review';
  -- once the header is posted or cancelled, lines are frozen too.
  IF v_status IN ('posted','cancelled') THEN
    RAISE EXCEPTION 'IMMUTABLE: stock count is %', v_status USING ERRCODE = '55000';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER trg_guard_stock_count_line BEFORE INSERT OR UPDATE OR DELETE ON stock_count_lines
  FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_count_line();

-- ------------------------------------------------------------ RLS: procurement roles read; no client writes
ALTER TABLE stock_counts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_count_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_count_scans ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_sc_hdr_select   ON stock_counts      FOR SELECT USING (fn_is_procurement(business_id));
CREATE POLICY pol_sc_line_select  ON stock_count_lines FOR SELECT USING (fn_is_procurement(business_id));
CREATE POLICY pol_sc_scan_select  ON stock_count_scans FOR SELECT USING (fn_is_procurement(business_id));
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON stock_counts, stock_count_lines, stock_count_scans FROM anon, authenticated;

-- ------------------------------------------------------------ helpers
-- Header lookup + membership in one place. Locks the row when asked (POST / state changes).
CREATE OR REPLACE FUNCTION fn_stock_count_load(p_count_id UUID, p_roles user_role[], p_lock BOOLEAN DEFAULT false)
RETURNS stock_counts LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE c stock_counts;
BEGIN
  IF p_lock THEN
    SELECT * INTO c FROM stock_counts WHERE id = p_count_id FOR UPDATE;
  ELSE
    SELECT * INTO c FROM stock_counts WHERE id = p_count_id;
  END IF;
  IF c.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: stock count %', p_count_id USING ERRCODE = 'P0002'; END IF;
  PERFORM fn_require_role(c.business_id, p_roles);
  PERFORM fn_require_active_business(c.business_id);
  RETURN c;
END $$;
REVOKE EXECUTE ON FUNCTION fn_stock_count_load(UUID, user_role[], BOOLEAN) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ rpc_stock_count_create (procurement)
CREATE OR REPLACE FUNCTION rpc_stock_count_create(
  p_business_id UUID, p_branch_id UUID, p_count_type stock_count_type DEFAULT 'full', p_note TEXT DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); v_id UUID;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager','stock_staff']::user_role[]);
  PERFORM fn_require_active_business(p_business_id);
  PERFORM fn_assert_branch(p_business_id, p_branch_id);
  INSERT INTO stock_counts (business_id, branch_id, count_number, count_type, note, created_by)
  VALUES (p_business_id, p_branch_id, fn_next_sequence(p_business_id, 'SC'), COALESCE(p_count_type, 'full'),
          NULLIF(left(trim(p_note), 500), ''), v_actor)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_stock_count_create(UUID, UUID, stock_count_type, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_stock_count_create(UUID, UUID, stock_count_type, TEXT) TO authenticated;

-- ------------------------------------------------------------ line event core (private)
-- Applies one counting event to a line. `p_set` NULL → relative delta (scan / undo);
-- otherwise the line is set to that exact quantity (manual entry; 0 = explicit zero).
-- Idempotent: an event whose client_transaction_id was already applied returns the current
-- line without applying anything again.
CREATE OR REPLACE FUNCTION fn_stock_count_apply(
  p_count_id UUID, p_variant_id UUID, p_bucket inventory_bucket,
  p_delta INTEGER, p_set INTEGER,
  p_client_tx UUID, p_device_id TEXT, p_client_at TIMESTAMPTZ
) RETURNS stock_count_lines LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor UUID := fn_actor(); c stock_counts; l stock_count_lines; v_before INTEGER; v_after INTEGER; v_kind TEXT;
BEGIN
  c := fn_stock_count_load(p_count_id, ARRAY['owner','manager','stock_staff']::user_role[], true);
  IF c.status NOT IN ('draft','counting') THEN
    RAISE EXCEPTION 'INVALID_STATE: stock count % is %, counting is closed', c.count_number, c.status USING ERRCODE = '55000';
  END IF;
  IF p_client_tx IS NULL THEN RAISE EXCEPTION 'INVALID_EVENT: client_transaction_id required' USING ERRCODE = '22023'; END IF;
  PERFORM fn_assert_variant(c.business_id, p_variant_id);

  -- replay of an already-applied event: answer with the line as it is
  IF EXISTS (SELECT 1 FROM stock_count_scans WHERE stock_count_id = c.id AND client_transaction_id = p_client_tx) THEN
    SELECT * INTO l FROM stock_count_lines WHERE stock_count_id = c.id AND variant_id = p_variant_id AND bucket = p_bucket;
    RETURN l;
  END IF;

  IF c.status = 'draft' THEN
    UPDATE stock_counts SET status = 'counting', counting_started_at = now() WHERE id = c.id;
  END IF;

  INSERT INTO stock_count_lines (stock_count_id, variant_id, bucket)
  VALUES (c.id, p_variant_id, p_bucket)
  ON CONFLICT (stock_count_id, variant_id, bucket) DO NOTHING;
  SELECT * INTO l FROM stock_count_lines
  WHERE stock_count_id = c.id AND variant_id = p_variant_id AND bucket = p_bucket FOR UPDATE;

  v_before := COALESCE(l.counted_quantity, 0);
  IF p_set IS NOT NULL THEN
    IF p_set < 0 THEN RAISE EXCEPTION 'INVALID_QTY: quantity must be 0 or more' USING ERRCODE = '22023'; END IF;
    v_after := p_set;
    v_kind := CASE WHEN p_set = 0 THEN 'zero_confirm' ELSE 'set' END;
  ELSE
    IF p_delta IS NULL OR p_delta = 0 THEN RAISE EXCEPTION 'INVALID_QTY: zero delta' USING ERRCODE = '22023'; END IF;
    v_after := v_before + p_delta;
    IF v_after < 0 THEN RAISE EXCEPTION 'INVALID_QTY: count cannot go below zero' USING ERRCODE = '22023'; END IF;
    v_kind := CASE WHEN p_delta > 0 THEN 'scan' ELSE 'undo' END;
  END IF;

  UPDATE stock_count_lines
  SET counted_quantity = v_after,
      -- zero stays "confirmed" only when it was asked for explicitly; an undo down to zero
      -- is not a statement that the shelf is empty
      zero_confirmed = (v_kind = 'zero_confirm'),
      counted_by = v_actor, counted_at = now()
  WHERE id = l.id
  RETURNING * INTO l;

  INSERT INTO stock_count_scans (stock_count_id, line_id, variant_id, bucket, kind, delta, quantity_after,
                                 client_transaction_id, device_id, client_at, created_by)
  VALUES (c.id, l.id, p_variant_id, p_bucket, v_kind, v_after - v_before, v_after,
          p_client_tx, NULLIF(left(p_device_id, 120), ''), p_client_at, v_actor);
  RETURN l;
END $$;
REVOKE EXECUTE ON FUNCTION fn_stock_count_apply(UUID, UUID, inventory_bucket, INTEGER, INTEGER, UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

-- scan (+n) or undo (−n)
CREATE OR REPLACE FUNCTION rpc_stock_count_scan(
  p_count_id UUID, p_variant_id UUID, p_bucket inventory_bucket, p_delta INTEGER,
  p_client_tx UUID, p_device_id TEXT DEFAULT NULL, p_client_at TIMESTAMPTZ DEFAULT NULL
) RETURNS stock_count_lines LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT fn_stock_count_apply(p_count_id, p_variant_id, p_bucket, p_delta, NULL, p_client_tx, p_device_id, p_client_at);
$$;
REVOKE EXECUTE ON FUNCTION rpc_stock_count_scan(UUID, UUID, inventory_bucket, INTEGER, UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_stock_count_scan(UUID, UUID, inventory_bucket, INTEGER, UUID, TEXT, TIMESTAMPTZ) TO authenticated;

-- exact quantity (manual entry); 0 is the explicit "0 adet olarak doğrula"
CREATE OR REPLACE FUNCTION rpc_stock_count_set_quantity(
  p_count_id UUID, p_variant_id UUID, p_bucket inventory_bucket, p_quantity INTEGER,
  p_client_tx UUID, p_device_id TEXT DEFAULT NULL, p_client_at TIMESTAMPTZ DEFAULT NULL
) RETURNS stock_count_lines LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT fn_stock_count_apply(p_count_id, p_variant_id, p_bucket, NULL, p_quantity, p_client_tx, p_device_id, p_client_at);
$$;
REVOKE EXECUTE ON FUNCTION rpc_stock_count_set_quantity(UUID, UUID, inventory_bucket, INTEGER, UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_stock_count_set_quantity(UUID, UUID, inventory_bucket, INTEGER, UUID, TEXT, TIMESTAMPTZ) TO authenticated;

-- ------------------------------------------------------------ rpc_stock_count_review (procurement)
-- Freezes the count for review: every line gets its expected quantity from the ledger. A
-- FULL count additionally gets one unresolved line (counted NULL) for every variant × bucket
-- that the ledger says is on the shelf but nobody scanned — "not scanned" is never zero.
-- Calling it again from review recomputes the snapshot (the "refresh" after a conflict).
CREATE OR REPLACE FUNCTION rpc_stock_count_review(p_count_id UUID)
RETURNS stock_counts LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); c stock_counts;
BEGIN
  c := fn_stock_count_load(p_count_id, ARRAY['owner','manager','stock_staff']::user_role[], true);
  IF c.status NOT IN ('draft','counting','review') THEN
    RAISE EXCEPTION 'INVALID_STATE: stock count % is %', c.count_number, c.status USING ERRCODE = '55000';
  END IF;

  IF c.count_type = 'full' THEN
    INSERT INTO stock_count_lines (stock_count_id, variant_id, bucket)
    SELECT c.id, s.variant_id, s.bucket
    FROM (
      SELECT variant_id, bucket, SUM(quantity) AS qty FROM inventory_movements
      WHERE business_id = c.business_id AND branch_id = c.branch_id
      GROUP BY variant_id, bucket
    ) s
    WHERE s.qty <> 0
    ON CONFLICT (stock_count_id, variant_id, bucket) DO NOTHING;
  END IF;

  UPDATE stock_count_lines l
  SET expected_quantity = fn_bucket_qty(c.business_id, c.branch_id, l.variant_id, l.bucket)
  WHERE l.stock_count_id = c.id;

  UPDATE stock_counts
  SET status = 'review', reviewed_at = now(), reviewed_by = v_actor,
      counting_started_at = COALESCE(counting_started_at, now()),
      review_ledger_watermark = (SELECT max(created_at) FROM inventory_movements
                                 WHERE business_id = c.business_id AND branch_id = c.branch_id)
  WHERE id = c.id
  RETURNING * INTO c;
  RETURN c;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_stock_count_review(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_stock_count_review(UUID) TO authenticated;

-- back to counting (procurement)
CREATE OR REPLACE FUNCTION rpc_stock_count_reopen(p_count_id UUID)
RETURNS stock_counts LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE c stock_counts;
BEGIN
  c := fn_stock_count_load(p_count_id, ARRAY['owner','manager','stock_staff']::user_role[], true);
  IF c.status <> 'review' THEN
    RAISE EXCEPTION 'INVALID_STATE: stock count % is %', c.count_number, c.status USING ERRCODE = '55000';
  END IF;
  UPDATE stock_counts SET status = 'counting' WHERE id = c.id RETURNING * INTO c;
  RETURN c;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_stock_count_reopen(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_stock_count_reopen(UUID) TO authenticated;

-- cancel (manager+); the document and its scans stay for audit
CREATE OR REPLACE FUNCTION rpc_stock_count_cancel(p_count_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS stock_counts LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); c stock_counts;
BEGIN
  c := fn_stock_count_load(p_count_id, ARRAY['owner','manager']::user_role[], true);
  IF c.status IN ('posted','cancelled') THEN
    RAISE EXCEPTION 'INVALID_STATE: stock count % is %', c.count_number, c.status USING ERRCODE = '55000';
  END IF;
  UPDATE stock_counts
  SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_actor, cancel_reason = NULLIF(left(trim(p_reason), 500), '')
  WHERE id = c.id RETURNING * INTO c;
  RETURN c;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_stock_count_cancel(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_stock_count_cancel(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------ rpc_stock_count_post (manager+)
-- One transaction: role → business → branch → state → every line resolved → pools locked →
-- ledger re-read per line (stale check) → one adjustment movement per non-zero difference →
-- header posted. Shortage leaves at the branch moving average (fn_post_to_cost_pool outflow).
-- Surplus inherits the current branch moving average; a surplus on a pool with nothing on
-- hand has no cost to inherit and blocks the whole posting (COST_REQUIRED) — never a silent
-- zero-cost inflow. Stock counts are not purchases: no supplier entry is written.
CREATE OR REPLACE FUNCTION rpc_stock_count_post(p_count_id UUID)
RETURNS TABLE (count_id UUID, count_number TEXT, lines INTEGER, adjustments INTEGER, shortage_units INTEGER, surplus_units INTEGER)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor UUID := fn_actor(); c stock_counts; l RECORD; v_now INTEGER; v_delta INTEGER; v_unit NUMERIC;
  pr t_cost_pool_result; v_mid UUID; v_pool RECORD; v_sku TEXT;
  v_lines INTEGER := 0; v_adj INTEGER := 0; v_short INTEGER := 0; v_surplus INTEGER := 0; v_unresolved INTEGER;
BEGIN
  -- 1–2. role and business (the header lock serialises concurrent posts of the same count)
  c := fn_stock_count_load(p_count_id, ARRAY['owner','manager']::user_role[], true);
  -- 3. branch
  PERFORM fn_assert_branch(c.business_id, c.branch_id);
  -- 4. state
  IF c.status = 'posted' THEN
    RAISE EXCEPTION 'ALREADY_POSTED: stock count % was posted at %', c.count_number, c.posted_at USING ERRCODE = '55000';
  END IF;
  IF c.status <> 'review' THEN
    RAISE EXCEPTION 'INVALID_STATE: stock count % is %, review it first', c.count_number, c.status USING ERRCODE = '55000';
  END IF;
  -- 5. every line resolved
  SELECT count(*) INTO v_unresolved FROM stock_count_lines WHERE stock_count_id = c.id AND counted_quantity IS NULL;
  IF v_unresolved > 0 THEN
    RAISE EXCEPTION 'UNRESOLVED_LINES: % line(s) not counted; confirm them (0 adet olarak doğrula) or count them', v_unresolved USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM stock_count_lines WHERE stock_count_id = c.id) THEN
    RAISE EXCEPTION 'EMPTY_DOCUMENT: stock count % has no lines', c.count_number USING ERRCODE = '22023';
  END IF;

  -- pools locked in variant order, like every other posting RPC
  PERFORM fn_lock_pools(c.business_id, c.branch_id,
    (SELECT array_agg(DISTINCT variant_id ORDER BY variant_id) FROM stock_count_lines WHERE stock_count_id = c.id));

  -- 6. stale check across all lines before anything is written
  FOR l IN SELECT * FROM stock_count_lines WHERE stock_count_id = c.id ORDER BY variant_id, bucket LOOP
    v_now := fn_bucket_qty(c.business_id, c.branch_id, l.variant_id, l.bucket);
    IF v_now <> COALESCE(l.expected_quantity, -1) THEN
      RAISE EXCEPTION 'STALE_COUNT: Stok sayım sırasında değişti. Farkları yeniden hesaplayın.' USING ERRCODE = '55000';
    END IF;
  END LOOP;

  -- 7–8. differences → movements
  FOR l IN SELECT * FROM stock_count_lines WHERE stock_count_id = c.id ORDER BY variant_id, bucket LOOP
    v_lines := v_lines + 1;
    v_delta := l.counted_quantity - l.expected_quantity;
    IF v_delta = 0 THEN
      UPDATE stock_count_lines SET posted_delta = 0 WHERE id = l.id;
      CONTINUE;
    END IF;

    IF v_delta > 0 THEN
      SELECT on_hand_qty, total_value_base INTO v_pool FROM variant_cost_pools
      WHERE business_id = c.business_id AND branch_id = c.branch_id AND variant_id = l.variant_id;
      IF v_pool.on_hand_qty IS NULL OR v_pool.on_hand_qty <= 0 OR v_pool.total_value_base <= 0 THEN
        SELECT sku INTO v_sku FROM product_variants WHERE id = l.variant_id;
        RAISE EXCEPTION 'COST_REQUIRED: surplus for % has no moving-average cost to inherit; resolve its cost before posting', v_sku USING ERRCODE = '22023';
      END IF;
      v_unit := v_pool.total_value_base / v_pool.on_hand_qty;
      pr := fn_post_to_cost_pool(c.business_id, c.branch_id, l.variant_id, v_delta, v_unit, NULL);
      v_surplus := v_surplus + v_delta;
    ELSE
      pr := fn_post_to_cost_pool(c.business_id, c.branch_id, l.variant_id, v_delta, NULL, NULL);
      v_short := v_short - v_delta;
    END IF;

    v_mid := fn_ledger_post(c.business_id, c.branch_id, l.variant_id, l.bucket, v_delta, 'adjustment',
                            'stock_count_line', l.id, pr.unit_cost_used, pr.value_delta_base,
                            'Stok sayımı ' || c.count_number, now(), v_actor);
    UPDATE stock_count_lines SET posted_delta = v_delta, movement_id = v_mid WHERE id = l.id;
    v_adj := v_adj + 1;
  END LOOP;

  -- 9–10. header
  UPDATE stock_counts SET status = 'posted', posted_at = now(), posted_by = v_actor WHERE id = c.id;

  count_id := c.id; count_number := c.count_number; lines := v_lines; adjustments := v_adj;
  shortage_units := v_short; surplus_units := v_surplus;
  RETURN NEXT;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_stock_count_post(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_stock_count_post(UUID) TO authenticated;
