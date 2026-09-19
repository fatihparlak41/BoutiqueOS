-- Scenarios B and C on count2 (single session, sequential):
--   B) cost changed after review → POST refused STALE_REVIEW; also a client posting an older hash is refused
--   C) after re-review, a last-moment ledger movement → POST refused STALE_COUNT; re-review → POST ok; retry ALREADY_POSTED
\set ON_ERROR_STOP on
DO $$
DECLARE c UUID := (SELECT v FROM zz_scc_ctx WHERE k='count2'); v UUID := (SELECT v FROM zz_scc_ctx WHERE k='variant2');
        l UUID; h_old TEXT; r1 TEXT := 'none'; r2 TEXT := 'none'; r3 TEXT := 'none'; r4 TEXT := 'none'; r5 TEXT := 'none';
        n INT; q INT; val NUMERIC; ok BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000003","role":"authenticated"}', true);
  SELECT id INTO l FROM stock_count_lines WHERE stock_count_id = c;
  SELECT review_hash INTO h_old FROM stock_counts WHERE id = c;
  -- B: change the cost after the review
  PERFORM rpc_stock_count_set_line_cost(l, 95, 'owner_declared_opening_cost', 'değişti');
  BEGIN PERFORM * FROM rpc_stock_count_post(c); r1 := 'succeeded'; EXCEPTION WHEN OTHERS THEN r1 := SQLERRM; END;
  PERFORM rpc_stock_count_review(c);
  -- B2: a client that still holds the old hash
  BEGIN PERFORM * FROM rpc_stock_count_post(c, h_old); r2 := 'succeeded'; EXCEPTION WHEN OTHERS THEN r2 := SQLERRM; END;
  -- C: the ledger moves after the review (an opening adjustment gives the variant 1 unit @50)
  PERFORM rpc_post_inventory_adjustment('b0000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', v, 'sellable', 1, 'yarış: son anda hareket', 'manual_cost', 50);
  BEGIN PERFORM * FROM rpc_stock_count_post(c); r3 := 'succeeded'; EXCEPTION WHEN OTHERS THEN r3 := SQLERRM; END;
  PERFORM rpc_stock_count_review(c);
  -- now the pool HAS a basis (1 @50): the surplus (+1) inherits 50, the entered 95 is kept but not applied
  BEGIN PERFORM * FROM rpc_stock_count_post(c, (SELECT review_hash FROM stock_counts WHERE id = c)); r4 := 'succeeded'; EXCEPTION WHEN OTHERS THEN r4 := SQLERRM; END;
  BEGIN PERFORM * FROM rpc_stock_count_post(c); r5 := 'succeeded'; EXCEPTION WHEN OTHERS THEN r5 := SQLERRM; END;
  SELECT count(*) INTO n FROM inventory_movements WHERE reference_type = 'stock_count_line' AND reference_id = l;
  SELECT on_hand_qty, total_value_base INTO q, val FROM variant_cost_pools WHERE variant_id = v;
  SELECT (applied = false) INTO ok FROM stock_count_line_costs WHERE line_id = l;
  IF r1 LIKE 'STALE_REVIEW%' AND r2 LIKE 'STALE_REVIEW%' AND r3 LIKE 'STALE_COUNT%' AND r4 = 'succeeded' AND r5 LIKE 'ALREADY_POSTED%'
     AND n = 1 AND q = 2 AND val = 100 AND ok THEN
    RAISE NOTICE '[PASS] cost-bridge stale: cost change → STALE_REVIEW, old hash → STALE_REVIEW, ledger move → STALE_COUNT, re-review posts once (+1 at MWA 50, entered cost not applied), retry ALREADY_POSTED';
  ELSE
    RAISE NOTICE '[FAIL] cost-bridge stale: r1=% r2=% r3=% r4=% r5=% movements=% pool=%/% not_applied=%', r1, r2, r3, r4, r5, n, q, val, ok;
  END IF;
END $$;
