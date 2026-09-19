-- Verify A/D: count posted once, one movement (+3 @120), ledger 3, pool 3/360, cost row applied 3/360; a retry is ALREADY_POSTED.
\set ON_ERROR_STOP on
DO $$
DECLARE st TEXT; n INT; led INT; q INT; val NUMERIC; ap TEXT; retry TEXT := 'none';
BEGIN
  SELECT status::text INTO st FROM stock_counts WHERE id = (SELECT v FROM zz_scc_ctx WHERE k='count');
  SELECT count(*) INTO n FROM inventory_movements WHERE reference_type = 'stock_count_line'
    AND reference_id IN (SELECT id FROM stock_count_lines WHERE stock_count_id = (SELECT v FROM zz_scc_ctx WHERE k='count'));
  SELECT COALESCE(SUM(quantity),0) INTO led FROM inventory_movements WHERE variant_id = (SELECT v FROM zz_scc_ctx WHERE k='variant');
  SELECT on_hand_qty, total_value_base INTO q, val FROM variant_cost_pools WHERE variant_id = (SELECT v FROM zz_scc_ctx WHERE k='variant');
  SELECT applied::text || '/' || applied_quantity || '/' || applied_value_base::numeric(12,2) INTO ap
    FROM stock_count_line_costs WHERE stock_count_id = (SELECT v FROM zz_scc_ctx WHERE k='count');
  PERFORM set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000003","role":"authenticated"}', true);
  BEGIN
    PERFORM * FROM rpc_stock_count_post((SELECT v FROM zz_scc_ctx WHERE k='count'));
    retry := 'succeeded';
  EXCEPTION WHEN OTHERS THEN retry := SQLERRM;
  END;
  IF st = 'posted' AND n = 1 AND led = 3 AND q = 3 AND val = 360 AND ap = 'true/3/360.00' AND retry LIKE 'ALREADY_POSTED%' THEN
    RAISE NOTICE '[PASS] cost-bridge double-post: posted once, one movement, ledger 3, pool 3/360, cost applied 3/360, retry ALREADY_POSTED';
  ELSE
    RAISE NOTICE '[FAIL] cost-bridge double-post: status=% movements=% ledger=% pool=%/% applied=% retry=%', st, n, led, q, val, ap, retry;
  END IF;
END $$;
