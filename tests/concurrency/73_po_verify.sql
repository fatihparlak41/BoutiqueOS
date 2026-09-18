-- Verify: po_a approved once; po_c PARTIALLY_RECEIVED with exactly 6 (gr_a posted, gr_b still draft); po_d ordered once;
-- the two concurrently created POs carry distinct consecutive numbers; the ledger got exactly one movement (+10).
\set ON_ERROR_STOP on
DO $$
DECLARE sa TEXT; sc TEXT; sd TEXT; ga TEXT; gb TEXT; recv INT; mv INT; nums TEXT[]; ok BOOLEAN;
BEGIN
  SELECT status::text INTO sa FROM purchase_orders WHERE id = (SELECT v FROM zz_po_ctx WHERE k='po_a');
  SELECT status::text INTO sc FROM purchase_orders WHERE id = (SELECT v FROM zz_po_ctx WHERE k='po_c');
  SELECT status::text INTO sd FROM purchase_orders WHERE id = (SELECT v FROM zz_po_ctx WHERE k='po_d');
  SELECT status::text INTO ga FROM goods_receipts WHERE id = (SELECT v FROM zz_po_ctx WHERE k='gr_a');
  SELECT status::text INTO gb FROM goods_receipts WHERE id = (SELECT v FROM zz_po_ctx WHERE k='gr_b');
  SELECT COALESCE(sum(received), 0) INTO recv FROM fn_po_received((SELECT v FROM zz_po_ctx WHERE k='po_c'));
  SELECT count(*) INTO mv FROM inventory_movements WHERE variant_id = (SELECT v FROM zz_po_ctx WHERE k='variant');
  SELECT array_agg(po_number ORDER BY po_number) INTO nums FROM purchase_orders
    WHERE business_id = 'b0000000-0000-4000-8000-000000000001'
      AND supplier_id = (SELECT v FROM zz_po_ctx WHERE k='supplier')
      AND id NOT IN (SELECT v FROM zz_po_ctx WHERE k IN ('po_a','po_c','po_d'));
  ok := array_length(nums, 1) = 2 AND nums[1] <> nums[2]
        AND substr(nums[2], length(nums[2]) - 5)::int = substr(nums[1], length(nums[1]) - 5)::int + 1;
  IF sa = 'approved' AND sc = 'partially_received' AND sd = 'ordered' AND ga = 'posted' AND gb = 'draft' AND recv = 6 AND mv = 1 AND ok THEN
    RAISE NOTICE '[PASS] po races: approved once, received exactly 6 (gr_b refused, left draft), ordered once, numbers % consecutive', nums;
  ELSE
    RAISE NOTICE '[FAIL] po races: po_a=% po_c=% po_d=% gr_a=% gr_b=% received=% movements=% numbers=%', sa, sc, sd, ga, gb, recv, mv, nums;
  END IF;
END $$;
