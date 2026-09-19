-- ============================================================
-- Phase 15B-0 — opening-stock cost bridge for the stock-count engine
-- ============================================================
-- Additive. The Phase 7A count engine stays the only path that turns a physical count
-- into ledger rows; this migration only closes one gap in it:
--
--   a POSITIVE difference on a variant whose branch pool carries no usable cost basis
--   used to block the whole posting (COST_REQUIRED) with no way to resolve it inside the
--   count. Owner/manager can now record an explicit unit cost for exactly that line, and
--   POST uses it for the newly introduced units. Nothing else in the cost model changes:
--   shortages still leave at the branch moving average, surpluses on a pool with a basis
--   still inherit that average, and a surplus with neither basis nor entered cost still
--   blocks the whole posting. No default, no sale-price-derived cost.
--
--   stock_count_cost_source          ENUM documented_purchase | owner_declared_opening_cost
--   stock_count_line_costs           the manager+ cost side of a count line (RLS manager+,
--                                    no client writes; frozen with the document)
--   stock_count_lines.cost_required  operational flag set at review: "this surplus needs a
--                                    cost"; carries no value and is readable by every
--                                    counting role
--   stock_counts.review_hash         fingerprint of lines + cost rows at review; POST
--                                    refuses a changed document (STALE_REVIEW) and, when the
--                                    client sends the hash it rendered, a document reviewed
--                                    again by someone else since
--   fn_stock_count_hash              the fingerprint (no cost value enters the hash)
--   rpc_stock_count_set_line_cost    owner/manager, draft/counting/review only, NULL clears
--   rpc_stock_count_review           + cost_required + review_hash
--   rpc_stock_count_post             + p_review_hash, STALE_REVIEW, manual cost for a
--                                    surplus without basis, applied_* audit on the cost row
--
-- Money: cost6 in the business base currency, like every pool and movement cost.
-- Rollback: drop rpc_stock_count_set_line_cost, restore the two 7A RPC bodies, drop the
-- hash function, the table, the two columns and the enum. No row is rewritten.
-- ============================================================

CREATE TYPE stock_count_cost_source AS ENUM ('documented_purchase', 'owner_declared_opening_cost');

ALTER TABLE stock_counts      ADD COLUMN review_hash   TEXT;
ALTER TABLE stock_count_lines ADD COLUMN cost_required BOOLEAN NOT NULL DEFAULT false;

-- ------------------------------------------------------------ the cost side of a count line
CREATE TABLE stock_count_line_costs (
  line_id             UUID PRIMARY KEY,
  business_id         UUID NOT NULL REFERENCES businesses(id),
  stock_count_id      UUID NOT NULL,
  unit_cost_base      cost6 NOT NULL CHECK (unit_cost_base > 0),
  cost_source         stock_count_cost_source NOT NULL,
  note                TEXT,
  entered_by          UUID REFERENCES profiles(id),
  entered_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- written by POST: true = this cost priced the surplus; false = the pool already had a
  -- basis and the moving average was used instead (the entry is kept for audit)
  applied             BOOLEAN,
  applied_quantity    INTEGER,
  applied_value_base  value6,
  FOREIGN KEY (business_id, line_id)        REFERENCES stock_count_lines (business_id, id),
  FOREIGN KEY (business_id, stock_count_id) REFERENCES stock_counts      (business_id, id)
);
CREATE INDEX ix_stock_count_line_costs_count ON stock_count_line_costs (stock_count_id);

ALTER TABLE stock_count_line_costs ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_sclc_select ON stock_count_line_costs FOR SELECT USING (fn_is_manager_plus(business_id));
REVOKE ALL ON stock_count_line_costs FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON stock_count_line_costs FROM anon, authenticated;
GRANT SELECT ON stock_count_line_costs TO authenticated;

-- frozen with the document, whoever is asking (POST writes applied_* while the header is still 'review')
CREATE OR REPLACE FUNCTION fn_guard_stock_count_line_cost()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_status stock_count_status;
BEGIN
  SELECT status INTO v_status FROM stock_counts WHERE id = COALESCE(NEW.stock_count_id, OLD.stock_count_id);
  IF v_status IN ('posted', 'cancelled') THEN
    RAISE EXCEPTION 'IMMUTABLE: stock count is %', v_status USING ERRCODE = '55000';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    -- the accounting snapshot never moves once POST has written it
    IF OLD.applied IS NOT NULL AND (NEW.unit_cost_base <> OLD.unit_cost_base OR NEW.cost_source <> OLD.cost_source OR NEW.applied IS DISTINCT FROM OLD.applied) THEN
      RAISE EXCEPTION 'IMMUTABLE: applied count cost cannot change' USING ERRCODE = '55000';
    END IF;
    IF NEW.unit_cost_base <> OLD.unit_cost_base OR NEW.cost_source <> OLD.cost_source OR NEW.note IS DISTINCT FROM OLD.note THEN
      NEW.updated_at := clock_timestamp();
    END IF;
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER trg_guard_stock_count_line_cost BEFORE INSERT OR UPDATE OR DELETE ON stock_count_line_costs
  FOR EACH ROW EXECUTE FUNCTION fn_guard_stock_count_line_cost();

-- ------------------------------------------------------------ fingerprint
-- Lines (quantities, resolution) and the cost rows' identity + last change. No cost value
-- enters the hash: the hash is readable by every counting role through the header row.
CREATE OR REPLACE FUNCTION fn_stock_count_hash(p_count_id UUID)
RETURNS TEXT LANGUAGE sql SECURITY DEFINER STABLE SET search_path = pg_catalog, public AS $$
  SELECT md5(
    COALESCE((SELECT string_agg(concat_ws(':', id, variant_id, bucket, expected_quantity, counted_quantity, zero_confirmed), ',' ORDER BY variant_id, bucket)
                FROM stock_count_lines WHERE stock_count_id = p_count_id), '')
    || '#' ||
    COALESCE((SELECT string_agg(concat_ws(':', line_id, updated_at), ',' ORDER BY line_id)
                FROM stock_count_line_costs WHERE stock_count_id = p_count_id), '')
  );
$$;
REVOKE EXECUTE ON FUNCTION fn_stock_count_hash(UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ rpc_stock_count_set_line_cost (owner/manager)
-- Records — or with a NULL cost removes — the explicit unit cost of one count line. Allowed
-- while the document can still change (draft / counting / review). It does not refresh the
-- review fingerprint on purpose: a cost entered after the review is a change to the
-- document, and POST asks for the review to be repeated (the app does that in one step).
CREATE OR REPLACE FUNCTION rpc_stock_count_set_line_cost(
  p_line_id UUID, p_unit_cost NUMERIC, p_source stock_count_cost_source DEFAULT NULL, p_note TEXT DEFAULT NULL
) RETURNS stock_count_line_costs LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor UUID := fn_actor(); l stock_count_lines; c stock_counts; r stock_count_line_costs;
BEGIN
  SELECT * INTO l FROM stock_count_lines WHERE id = p_line_id;
  IF l.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: stock count line %', p_line_id USING ERRCODE = 'P0002'; END IF;
  c := fn_stock_count_load(l.stock_count_id, ARRAY['owner','manager']::user_role[], true);
  IF c.status NOT IN ('draft', 'counting', 'review') THEN
    RAISE EXCEPTION 'INVALID_STATE: stock count % is %', c.count_number, c.status USING ERRCODE = '55000';
  END IF;

  IF p_unit_cost IS NULL THEN
    DELETE FROM stock_count_line_costs WHERE line_id = l.id;
    RETURN NULL;
  END IF;
  IF p_unit_cost <= 0 THEN RAISE EXCEPTION 'INVALID_COST: unit cost must be above zero' USING ERRCODE = '22023'; END IF;
  IF p_source IS NULL THEN RAISE EXCEPTION 'COST_SOURCE_REQUIRED: say where the cost comes from' USING ERRCODE = '22023'; END IF;

  INSERT INTO stock_count_line_costs (line_id, business_id, stock_count_id, unit_cost_base, cost_source, note, entered_by)
  VALUES (l.id, c.business_id, c.id, round(p_unit_cost, 6), p_source, NULLIF(left(trim(p_note), 500), ''), v_actor)
  ON CONFLICT (line_id) DO UPDATE
    SET unit_cost_base = EXCLUDED.unit_cost_base, cost_source = EXCLUDED.cost_source, note = EXCLUDED.note,
        entered_by = EXCLUDED.entered_by, entered_at = now()
  RETURNING * INTO r;
  RETURN r;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_stock_count_set_line_cost(UUID, NUMERIC, stock_count_cost_source, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_stock_count_set_line_cost(UUID, NUMERIC, stock_count_cost_source, TEXT) TO authenticated;

-- ------------------------------------------------------------ rpc_stock_count_review (procurement) — body replaced
-- As in 7A, plus: cost_required per line (counted above expected and the branch pool has
-- no usable basis) and the review fingerprint.
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

  -- a surplus whose pool cannot price it: an operational fact, no value attached
  UPDATE stock_count_lines l
  SET cost_required = (
    l.counted_quantity IS NOT NULL AND l.counted_quantity > l.expected_quantity
    AND NOT EXISTS (SELECT 1 FROM variant_cost_pools p
                    WHERE p.business_id = c.business_id AND p.branch_id = c.branch_id AND p.variant_id = l.variant_id
                      AND p.on_hand_qty > 0 AND p.total_value_base > 0))
  WHERE l.stock_count_id = c.id;

  UPDATE stock_counts
  SET status = 'review', reviewed_at = now(), reviewed_by = v_actor,
      counting_started_at = COALESCE(counting_started_at, now()),
      review_ledger_watermark = (SELECT max(created_at) FROM inventory_movements
                                 WHERE business_id = c.business_id AND branch_id = c.branch_id),
      review_hash = fn_stock_count_hash(c.id)
  WHERE id = c.id
  RETURNING * INTO c;
  RETURN c;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_stock_count_review(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_stock_count_review(UUID) TO authenticated;

-- ------------------------------------------------------------ rpc_stock_count_post (manager+) — new signature
-- The 7A body with three additions: (a) the review fingerprint must still match the
-- document (STALE_REVIEW), and when the client sends the hash it rendered that hash must be
-- the current review; (b) a surplus on a pool without basis is priced by the line's
-- entered cost, else COST_REQUIRED as before; (c) the cost row records what POST did.
DROP FUNCTION rpc_stock_count_post(UUID);
CREATE OR REPLACE FUNCTION rpc_stock_count_post(p_count_id UUID, p_review_hash TEXT DEFAULT NULL)
RETURNS TABLE (count_id UUID, count_number TEXT, lines INTEGER, adjustments INTEGER, shortage_units INTEGER, surplus_units INTEGER)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor UUID := fn_actor(); c stock_counts; l RECORD; v_now INTEGER; v_delta INTEGER; v_unit NUMERIC;
  pr t_cost_pool_result; v_mid UUID; v_pool RECORD; v_sku TEXT; v_cost stock_count_line_costs;
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
  -- 4b. the reviewed document is the document being posted
  IF c.review_hash IS NULL OR c.review_hash <> fn_stock_count_hash(c.id)
     OR (p_review_hash IS NOT NULL AND p_review_hash <> c.review_hash) THEN
    RAISE EXCEPTION 'STALE_REVIEW: Sayım incelemeden sonra değişti. Farkları yeniden hesaplayın.' USING ERRCODE = '55000';
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
      SELECT * INTO v_cost FROM stock_count_line_costs WHERE line_id = l.id;
      IF v_pool.on_hand_qty IS NOT NULL AND v_pool.on_hand_qty > 0 AND v_pool.total_value_base > 0 THEN
        -- existing rule: the surplus inherits the branch moving average; an entered cost is kept for audit, unused
        v_unit := v_pool.total_value_base / v_pool.on_hand_qty;
        IF v_cost.line_id IS NOT NULL THEN
          UPDATE stock_count_line_costs SET applied = false, applied_quantity = 0, applied_value_base = 0 WHERE line_id = l.id;
        END IF;
      ELSIF v_cost.line_id IS NOT NULL THEN
        -- the bridge: explicit owner/manager cost prices exactly these new units
        v_unit := v_cost.unit_cost_base;
        UPDATE stock_count_line_costs
        SET applied = true, applied_quantity = v_delta, applied_value_base = round(v_delta * v_cost.unit_cost_base, 6)
        WHERE line_id = l.id;
      ELSE
        SELECT sku INTO v_sku FROM product_variants WHERE id = l.variant_id;
        RAISE EXCEPTION 'COST_REQUIRED: surplus for % has no moving-average cost to inherit; enter its unit cost before posting', v_sku USING ERRCODE = '22023';
      END IF;
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
REVOKE EXECUTE ON FUNCTION rpc_stock_count_post(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_stock_count_post(UUID, TEXT) TO authenticated;
