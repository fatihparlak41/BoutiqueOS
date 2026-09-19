-- Verify all four phases.
\set ON_ERROR_STOP on
DO $$
DECLARE biz UUID := (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz'); o1 UUID := (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'o1');
        n_orders INT; n_last INT; st TEXT; n_sales INT; n_res INT; o4_total NUMERIC; o4_item NUMERIC; p_now NUMERIC; ok BOOLEAN;
BEGIN
  SELECT count(*) INTO n_orders FROM storefront_orders WHERE business_id = biz;
  SELECT count(*) INTO n_last FROM storefront_order_items i JOIN storefront_orders o ON o.id = i.order_id WHERE o.business_id = biz AND i.variant_id = (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'v_last');
  SELECT status::text INTO st FROM storefront_orders WHERE id = o1;
  SELECT count(*) INTO n_sales FROM sales WHERE business_id = biz;
  SELECT count(*) INTO n_res FROM reservations WHERE business_id = biz AND source = 'online' AND status IN ('active','converted');
  SELECT o.total, i.unit_price INTO o4_total, o4_item FROM storefront_orders o JOIN storefront_order_items i ON i.order_id = o.id WHERE o.business_id = biz AND o.customer_name = 'Race C';
  SELECT default_sale_price INTO p_now FROM products WHERE id = (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'p_many');
  ok := n_orders = 2 AND n_last = 1 AND st = 'completed' AND n_sales = 1 AND n_res = 2 AND o4_item IN (300, 350) AND o4_total = o4_item * 2 AND p_now = 350;
  IF ok THEN
    RAISE NOTICE '[PASS] order races: one order for the last unit (same key replayed), confirm won over the customer cancel, one sale on double-submit, cancel after conversion refused, price snapshot deterministic (order at % while catalogue is %)', o4_item, p_now;
  ELSE
    RAISE NOTICE '[FAIL] order races: orders=% last_lines=% o1=% sales=% res=% o4_item=% o4_total=% price=%', n_orders, n_last, st, n_sales, n_res, o4_item, o4_total, p_now;
  END IF;
END $$;
