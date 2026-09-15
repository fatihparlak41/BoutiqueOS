-- Verify: posted once, one movement (+4), one liability (440), pool 4 / 440 (landed 110).
\set ON_ERROR_STOP on
DO $$
DECLARE st TEXT; n INT; liab NUMERIC; nl INT; q INT; val NUMERIC;
BEGIN
  SELECT status::text INTO st FROM goods_receipts WHERE id = (SELECT v FROM zz_gr_ctx WHERE k='gr');
  SELECT count(*) INTO n FROM inventory_movements WHERE reference_type = 'goods_receipt_item'
    AND reference_id IN (SELECT id FROM goods_receipt_items WHERE goods_receipt_id = (SELECT v FROM zz_gr_ctx WHERE k='gr'));
  SELECT count(*), COALESCE(sum(amount_original),0) INTO nl, liab FROM supplier_account_entries WHERE reference_type = 'goods_receipt' AND reference_id = (SELECT v FROM zz_gr_ctx WHERE k='gr');
  SELECT on_hand_qty, total_value_base INTO q, val FROM variant_cost_pools WHERE variant_id = (SELECT v FROM zz_gr_ctx WHERE k='variant');
  IF st = 'posted' AND n = 1 AND nl = 1 AND liab = 440 AND q = 4 AND val = 440 THEN
    RAISE NOTICE '[PASS] receipt double-post: posted once, one movement, one liability 440, pool 4/440';
  ELSE
    RAISE NOTICE '[FAIL] receipt double-post: status=% movements=% liabilities=%/% pool=%/%', st, n, nl, liab, q, val;
  END IF;
END $$;
