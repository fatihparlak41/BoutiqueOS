-- Verify: count posted once, exactly one adjustment movement (−2), ledger 3, pool 3/300.
\set ON_ERROR_STOP on
DO $$
DECLARE st TEXT; n INT; led INT; q INT; val NUMERIC;
BEGIN
  SELECT status::text INTO st FROM stock_counts WHERE id = (SELECT v FROM zz_sc_ctx WHERE k='count');
  SELECT count(*) INTO n FROM inventory_movements WHERE reference_type = 'stock_count_line'
    AND reference_id IN (SELECT id FROM stock_count_lines WHERE stock_count_id = (SELECT v FROM zz_sc_ctx WHERE k='count'));
  SELECT COALESCE(SUM(quantity),0) INTO led FROM inventory_movements WHERE variant_id = (SELECT v FROM zz_sc_ctx WHERE k='variant');
  SELECT on_hand_qty, total_value_base INTO q, val FROM variant_cost_pools WHERE variant_id = (SELECT v FROM zz_sc_ctx WHERE k='variant');
  IF st = 'posted' AND n = 1 AND led = 3 AND q = 3 AND val = 300 THEN
    RAISE NOTICE '[PASS] double-post: posted once, one movement, ledger 3, pool 3/300';
  ELSE
    RAISE NOTICE '[FAIL] double-post: status=% movements=% ledger=% pool=%/%', st, n, led, q, val;
  END IF;
END $$;
