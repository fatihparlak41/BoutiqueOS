-- Verify (reservation vs reservation): exactly one ACTIVE hold, available 0, no movement from the hold.
\set ON_ERROR_STOP on
DO $$
DECLARE n INT; a INT; mv INT;
BEGIN
  SELECT count(*) INTO n FROM reservation_items ri JOIN reservations r ON r.id = ri.reservation_id WHERE ri.variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant') AND r.status = 'active';
  SELECT available_quantity INTO a FROM v_stock_available WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant');
  SELECT count(*) INTO mv FROM inventory_movements WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant') AND reason NOT IN ('goods_receipt');
  RAISE NOTICE 'active_holds=% available=% non_receipt_movements=%', n, a, mv;
  IF n = 1 AND a = 0 AND mv = 0 THEN RAISE NOTICE '[PASS] concurrency: exactly one hold, available 0, no movement';
  ELSE RAISE NOTICE '[FAIL] concurrency: holds=% available=% movements=%', n, a, mv; END IF;
END $$;
