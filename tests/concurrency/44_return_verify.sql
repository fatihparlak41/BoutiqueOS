-- Verify: exactly one return / return_item / customer_return movement / replacement sale / cost record.
\set ON_ERROR_STOP on
DO $$
DECLARE r INT; ri INT; mv INT; s INT; c INT; q INT;
BEGIN
  SELECT count(*) INTO r FROM returns WHERE original_sale_id = (SELECT v FROM zz_cc_ctx WHERE k='sale');
  SELECT count(*) INTO ri FROM return_items WHERE sale_item_id = (SELECT v FROM zz_cc_ctx WHERE k='sale_item');
  SELECT count(*) INTO mv FROM inventory_movements WHERE reason = 'customer_return' AND variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant');
  SELECT count(*) INTO s FROM sales WHERE exchange_group_id IN (SELECT exchange_group_id FROM returns WHERE original_sale_id = (SELECT v FROM zz_cc_ctx WHERE k='sale'));
  SELECT count(*) INTO c FROM return_item_costs x JOIN return_items y ON y.id = x.return_item_id WHERE y.sale_item_id = (SELECT v FROM zz_cc_ctx WHERE k='sale_item');
  SELECT on_hand_qty INTO q FROM variant_cost_pools WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant2');
  RAISE NOTICE 'returns=% items=% movements=% replacement_sales=% cost_records=% replacement_pool=%', r, ri, mv, s, c, q;
  IF r = 1 AND ri = 1 AND mv = 1 AND s = 1 AND c = 1 AND q = 1 THEN RAISE NOTICE '[PASS] concurrency: exactly one return, one replacement sale, replacement pool 1';
  ELSE RAISE NOTICE '[FAIL] concurrency: returns=% items=% movements=% sales=% costs=% pool2=%', r, ri, mv, s, c, q; END IF;
END $$;
