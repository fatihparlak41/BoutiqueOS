-- Verify (POS vs reservation): the sale took the unit, no hold exists, on_hand 0.
\set ON_ERROR_STOP on
DO $$
DECLARE s INT; n INT; q INT;
BEGIN
  SELECT count(*) INTO s FROM sale_items WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant');
  SELECT count(*) INTO n FROM reservation_items ri JOIN reservations r ON r.id = ri.reservation_id WHERE ri.variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant') AND r.status = 'active';
  SELECT on_hand_qty INTO q FROM variant_cost_pools WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant');
  RAISE NOTICE 'sales=% active_holds=% on_hand=%', s, n, q;
  IF s = 1 AND n = 0 AND q = 0 THEN RAISE NOTICE '[PASS] concurrency: the sale took the last unit, no hold, on_hand 0';
  ELSE RAISE NOTICE '[FAIL] concurrency: sales=% holds=% on_hand=%', s, n, q; END IF;
END $$;
