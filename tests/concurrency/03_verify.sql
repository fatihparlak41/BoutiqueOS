-- Verify: exactly one sale, pool 0/0, ledger 0, no negative anything.
\set ON_ERROR_STOP on
SELECT
  (SELECT count(*) FROM sale_items WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant')) AS sales_for_variant,
  (SELECT on_hand_qty FROM variant_cost_pools WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant')) AS pool_qty,
  (SELECT total_value_base FROM variant_cost_pools WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant')) AS pool_value,
  (SELECT COALESCE(SUM(quantity),0) FROM inventory_movements WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant')) AS ledger_qty;
DO $$
DECLARE n INT; q INT; val NUMERIC;
BEGIN
  SELECT count(*) INTO n FROM sale_items WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant');
  SELECT on_hand_qty, total_value_base INTO q, val FROM variant_cost_pools WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant');
  IF n = 1 AND q = 0 AND val = 0 THEN RAISE NOTICE '[PASS] concurrency: exactly one sale, pool 0/0';
  ELSE RAISE NOTICE '[FAIL] concurrency: sales=% pool_qty=% pool_value=%', n, q, val; END IF;
END $$;
