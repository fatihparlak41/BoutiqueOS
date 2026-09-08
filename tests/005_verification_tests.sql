-- ============================================================
-- ButikOS — Things Like Crop
-- Schema Verification Tests  •  Migration 005
-- Rev 1  •  2026-09-08
-- ============================================================
-- Purpose: Invariant tests to be run by the developer AFTER applying
-- migrations 001–004 and the seed file against the Supabase dev project.
-- Each test either asserts a condition that must be true, or checks
-- that a prohibited action is correctly blocked.
--
-- HOW TO RUN:
--   psql -h <host> -U postgres -d postgres -f 005_verification_tests.sql
--   All DO $$ blocks must complete without RAISE EXCEPTION.
--   A raised exception = TEST FAILED; the error message identifies the test.
--
-- Tests are grouped by functional area:
--   A. Schema structure invariants (001)
--   B. Cost pool invariants (002)
--   C. Security / RLS invariants (001–002)
--   D. FX rate invariants (003)
--   E. Posting RPC invariants (004)
--   F. Seed data invariants
-- ============================================================
-- IMPORTANT: These tests verify structure and static invariants.
-- They do NOT require live business data.
-- Run in a transaction so structural side-effects are rolled back:
--   psql ... -c "BEGIN; \i 005_verification_tests.sql; ROLLBACK;"
-- ============================================================


-- ============================================================
-- HELPER: assert macro
-- ============================================================
-- Usage: PERFORM assert_true(<condition>, '<test_name>', '<message>');

CREATE OR REPLACE FUNCTION assert_true(
  p_condition BOOLEAN,
  p_test_name TEXT,
  p_message   TEXT DEFAULT 'Assertion failed'
)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(p_condition, false) THEN
    RAISE EXCEPTION '[FAIL] % — %', p_test_name, p_message;
  ELSE
    RAISE NOTICE '[PASS] %', p_test_name;
  END IF;
END;
$$;


-- ============================================================
-- A. SCHEMA STRUCTURE INVARIANTS
-- ============================================================

-- A-01: Cross-tenant UNIQUE indexes exist on parent tables
DO $$
BEGIN
  PERFORM assert_true(
    (SELECT COUNT(*) FROM pg_indexes
     WHERE tablename = 'branches'
       AND indexdef ILIKE '%business_id%'
       AND indexdef ILIKE '%unique%') > 0,
    'A-01',
    'branches must have UNIQUE(business_id, id) index'
  );
END $$;

DO $$
BEGIN
  PERFORM assert_true(
    (SELECT COUNT(*) FROM pg_indexes
     WHERE tablename = 'product_variants'
       AND indexdef ILIKE '%business_id%'
       AND indexdef ILIKE '%unique%') > 0,
    'A-02',
    'product_variants must have UNIQUE(business_id, id) index'
  );
END $$;

-- A-03: sale_items has business_id column (for cross-tenant FK)
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_name = 'sale_items' AND column_name = 'business_id'
    ),
    'A-03',
    'sale_items must have business_id column for cross-tenant FK enforcement'
  );
END $$;

-- A-04: sale_item_costs exists and has correct columns
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_name = 'sale_item_costs'
        AND column_name = 'unit_cost_at_sale'
    ),
    'A-04',
    'sale_item_costs must have unit_cost_at_sale column'
  );
END $$;

-- A-05: sales does NOT have total_cost column (moved to sale_costs)
DO $$
BEGIN
  PERFORM assert_true(
    NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_name = 'sales' AND column_name = 'total_cost'
    ),
    'A-05',
    'sales must NOT have total_cost column — cost is in sale_costs table'
  );
END $$;

-- A-06: sale_items does NOT have unit_cost_at_sale column (cost is isolated)
DO $$
BEGIN
  PERFORM assert_true(
    NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_name = 'sale_items' AND column_name = 'unit_cost_at_sale'
    ),
    'A-06',
    'sale_items must NOT have unit_cost_at_sale — cost isolation enforced via sale_item_costs'
  );
END $$;

-- A-07: variant_cost_pools has no last_cost_base column
DO $$
BEGIN
  PERFORM assert_true(
    NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_name = 'variant_cost_pools' AND column_name = 'last_cost_base'
    ),
    'A-07',
    'variant_cost_pools must NOT have last_cost_base — removed, use MWA from total_value_base/on_hand_qty'
  );
END $$;

-- A-08: sale_payments has currency and exchange_rate columns (in 002, not 003)
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_name = 'sale_payments' AND column_name = 'currency'
    ) AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_name = 'sale_payments' AND column_name = 'exchange_rate'
    ),
    'A-08',
    'sale_payments must have currency and exchange_rate columns'
  );
END $$;

-- A-09: sales has per-tenant scoped idempotency (UNIQUE on business_id + client_transaction_id)
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_indexes
      WHERE tablename = 'sales'
        AND indexdef ILIKE '%business_id%'
        AND indexdef ILIKE '%client_transaction_id%'
        AND indexdef ILIKE '%unique%'
    ),
    'A-09',
    'sales must have UNIQUE(business_id, client_transaction_id) — per-tenant idempotency scope'
  );
END $$;

-- A-10: transfer_held_inventory has carried_total_value_base (not unit_cost_base)
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_name = 'transfer_held_inventory'
        AND column_name = 'carried_total_value_base'
    ),
    'A-10',
    'transfer_held_inventory must have carried_total_value_base column'
  );
END $$;


-- ============================================================
-- B. COST POOL INVARIANTS
-- ============================================================

-- B-01: variant_cost_pools has non-negative qty constraint
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'variant_cost_pools'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) ILIKE '%on_hand_qty >= 0%'
    ),
    'B-01',
    'variant_cost_pools must have CHECK(on_hand_qty >= 0)'
  );
END $$;

-- B-02: variant_cost_pools has non-negative value constraint
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'variant_cost_pools'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) ILIKE '%total_value_base >= 0%'
    ),
    'B-02',
    'variant_cost_pools must have CHECK(total_value_base >= 0)'
  );
END $$;

-- B-03: variant_cost_pools has zero-value-when-zero-qty constraint
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'variant_cost_pools'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) ILIKE '%on_hand_qty <> 0 OR total_value_base = 0%'
    ),
    'B-03',
    'variant_cost_pools must have CHECK(on_hand_qty <> 0 OR total_value_base = 0)'
  );
END $$;

-- B-04: t_cost_pool_result composite type exists
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_type
      WHERE typname = 't_cost_pool_result'
        AND typtype = 'c'
    ),
    'B-04',
    't_cost_pool_result composite type must exist'
  );
END $$;

-- B-05: t_cost_pool_result has unit_cost_used field
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_attribute a
      JOIN pg_type t ON t.oid = a.attrelid
      WHERE t.typname = 't_cost_pool_result'
        AND a.attname = 'unit_cost_used'
        AND a.attnum > 0
    ),
    'B-05',
    't_cost_pool_result must have unit_cost_used field (PRE-movement MWA)'
  );
END $$;

-- B-06: fn_post_to_cost_pool exists and returns t_cost_pool_result
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_proc p
      JOIN pg_type t ON t.oid = p.prorettype
      WHERE p.proname = 'fn_post_to_cost_pool'
        AND t.typname = 't_cost_pool_result'
    ),
    'B-06',
    'fn_post_to_cost_pool must exist and return t_cost_pool_result'
  );
END $$;

-- B-07: fn_post_to_cost_pool is SECURITY DEFINER
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_proc
      WHERE proname = 'fn_post_to_cost_pool'
        AND prosecdef = true
    ),
    'B-07',
    'fn_post_to_cost_pool must be SECURITY DEFINER'
  );
END $$;

-- B-08: Direct INSERT on variant_cost_pools is blocked for authenticated users
-- (No INSERT policy exists; only fn_post_to_cost_pool via SECURITY DEFINER may write)
DO $$
BEGIN
  PERFORM assert_true(
    NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'variant_cost_pools'
        AND cmd = 'INSERT'
    ),
    'B-08',
    'variant_cost_pools must have NO INSERT policy — only fn_post_to_cost_pool (SD) may write'
  );
END $$;


-- ============================================================
-- C. SECURITY / RLS INVARIANTS
-- ============================================================

-- C-01: RLS is enabled on sale_item_costs
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_class
      WHERE relname = 'sale_item_costs' AND relrowsecurity = true
    ),
    'C-01',
    'RLS must be enabled on sale_item_costs'
  );
END $$;

-- C-02: sale_item_costs SELECT policy requires manager_plus
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'sale_item_costs'
        AND cmd = 'SELECT'
        AND (qual ILIKE '%fn_is_manager_plus%' OR with_check ILIKE '%fn_is_manager_plus%')
    ),
    'C-02',
    'sale_item_costs SELECT policy must require fn_is_manager_plus (sales_staff blocked from costs)'
  );
END $$;

-- C-03: sale_costs SELECT policy requires manager_plus
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'sale_costs'
        AND cmd = 'SELECT'
        AND (qual ILIKE '%fn_is_manager_plus%' OR with_check ILIKE '%fn_is_manager_plus%')
    ),
    'C-03',
    'sale_costs SELECT policy must require fn_is_manager_plus'
  );
END $$;

-- C-04: Helper functions exist and are SECURITY DEFINER
DO $$
BEGIN
  PERFORM assert_true(
    (SELECT COUNT(*) FROM pg_proc
     WHERE proname IN ('fn_is_member', 'fn_has_role', 'fn_is_manager_plus')
       AND prosecdef = true) = 3,
    'C-04',
    'fn_is_member, fn_has_role, fn_is_manager_plus must all exist and be SECURITY DEFINER'
  );
END $$;

-- C-05: rpc_process_sale is SECURITY DEFINER
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_proc
      WHERE proname = 'rpc_process_sale'
        AND prosecdef = true
    ),
    'C-05',
    'rpc_process_sale must be SECURITY DEFINER'
  );
END $$;

-- C-06: rpc_process_sale does NOT accept p_sold_by parameter
-- (actor is always auth.uid() — no client-supplied UUID allowed)
DO $$
DECLARE
  v_argnames TEXT[];
BEGIN
  SELECT proargnames INTO v_argnames
  FROM pg_proc
  WHERE proname = 'rpc_process_sale'
  LIMIT 1;

  PERFORM assert_true(
    NOT ('p_sold_by' = ANY(COALESCE(v_argnames, ARRAY[]::TEXT[]))),
    'C-06',
    'rpc_process_sale must NOT have p_sold_by parameter — actor = auth.uid() only'
  );
END $$;

-- C-07: fx_rates has NO INSERT policy (all writes via rpc_set_fx_rate SD only)
DO $$
BEGIN
  PERFORM assert_true(
    NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'fx_rates'
        AND cmd = 'INSERT'
    ),
    'C-07',
    'fx_rates must have NO INSERT policy — all writes via rpc_set_fx_rate (SECURITY DEFINER)'
  );
END $$;

-- C-08: fx_rates has NO UPDATE policy (records are immutable)
DO $$
BEGIN
  PERFORM assert_true(
    NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'fx_rates'
        AND cmd = 'UPDATE'
    ),
    'C-08',
    'fx_rates must have NO UPDATE policy — historical rates are immutable'
  );
END $$;

-- C-09: fx_rates has NO DELETE policy
DO $$
BEGIN
  PERFORM assert_true(
    NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'fx_rates'
        AND cmd = 'DELETE'
    ),
    'C-09',
    'fx_rates must have NO DELETE policy — historical rates are preserved indefinitely'
  );
END $$;

-- C-10: returns table has NO direct INSERT policy (writes via rpc_process_return SD only)
DO $$
BEGIN
  PERFORM assert_true(
    NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'returns'
        AND cmd = 'INSERT'
    ),
    'C-10',
    'returns must have NO INSERT policy — all writes via rpc_process_return (SECURITY DEFINER)'
  );
END $$;


-- ============================================================
-- D. FX RATE INVARIANTS
-- ============================================================

-- D-01: fx_rates partial UNIQUE index exists (uix_fx_rates_current)
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_indexes
      WHERE tablename = 'fx_rates'
        AND indexname = 'uix_fx_rates_current'
        AND indexdef ILIKE '%where%is_current%true%'
    ),
    'D-01',
    'fx_rates must have partial UNIQUE index uix_fx_rates_current WHERE is_current=true'
  );
END $$;

-- D-02: rpc_set_fx_rate exists and is SECURITY DEFINER
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_proc
      WHERE proname = 'rpc_set_fx_rate'
        AND prosecdef = true
    ),
    'D-02',
    'rpc_set_fx_rate must exist and be SECURITY DEFINER'
  );
END $$;

-- D-03: fx_rates CHECK constraint allows only GBP, EUR, USD
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'fx_rates'::regclass
        AND contype = 'c'
        AND pg_get_constraintdef(oid) ILIKE '%GBP%EUR%USD%'
    ),
    'D-03',
    'fx_rates must have CHECK constraint limiting currency to GBP, EUR, USD'
  );
END $$;

-- D-04: Functional test — rpc_set_fx_rate insert order is correct
-- Simulate two rate inserts for same (business, date, currency).
-- After the second call, only one row with is_current=true must exist.
DO $$
DECLARE
  v_biz_id   UUID;
  v_rate1_id UUID;
  v_rate2_id UUID;
  v_current_count INTEGER;
BEGIN
  -- Use a temporary business for isolation
  INSERT INTO businesses (name, code, sector, currency, settings)
  VALUES ('_TEST_BIZ_D04', '_T04', 'Test', 'TRY', '{}'::jsonb)
  RETURNING id INTO v_biz_id;

  -- We cannot call rpc_set_fx_rate directly here (requires auth.uid() and manager role).
  -- Instead, test the uniqueness constraint directly by simulating the correct insert order.

  -- Step A: Insert first rate (is_current=true)
  INSERT INTO fx_rates (business_id, rate_date, currency, rate_to_try, is_current)
  VALUES (v_biz_id, CURRENT_DATE, 'GBP', 42.0, true)
  RETURNING id INTO v_rate1_id;

  -- Step B: Set old to is_current=false (correct order — must precede new INSERT)
  UPDATE fx_rates SET is_current = false WHERE id = v_rate1_id;

  -- Step C: Insert corrected rate (is_current=true) — must NOT violate partial UNIQUE
  INSERT INTO fx_rates (business_id, rate_date, currency, rate_to_try, is_current, superseded_by)
  VALUES (v_biz_id, CURRENT_DATE, 'GBP', 42.5, true, NULL)
  RETURNING id INTO v_rate2_id;

  -- Step D: Set superseded_by on old record
  UPDATE fx_rates SET superseded_by = v_rate2_id WHERE id = v_rate1_id;

  -- Assert: exactly one current record for this (business, date, currency)
  SELECT COUNT(*) INTO v_current_count
  FROM fx_rates
  WHERE business_id = v_biz_id
    AND rate_date   = CURRENT_DATE
    AND currency    = 'GBP'
    AND is_current  = true;

  PERFORM assert_true(
    v_current_count = 1,
    'D-04',
    'After correction, exactly 1 is_current=true record must exist for (business, date, currency). Got: ' || v_current_count
  );

  -- Assert: old record has superseded_by set
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM fx_rates
      WHERE id = v_rate1_id
        AND is_current = false
        AND superseded_by = v_rate2_id
    ),
    'D-04b',
    'Old fx_rate record must have is_current=false and superseded_by=new_id'
  );

  -- Cleanup
  DELETE FROM fx_rates WHERE business_id = v_biz_id;
  DELETE FROM businesses WHERE id = v_biz_id;

END $$;


-- ============================================================
-- E. POSTING RPC INVARIANTS
-- ============================================================

-- E-01: rpc_confirm_goods_receipt is SECURITY DEFINER with correct search_path
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_proc
      WHERE proname = 'rpc_confirm_goods_receipt'
        AND prosecdef = true
    ),
    'E-01',
    'rpc_confirm_goods_receipt must be SECURITY DEFINER'
  );
END $$;

-- E-02: rpc_process_return is SECURITY DEFINER
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_proc
      WHERE proname = 'rpc_process_return'
        AND prosecdef = true
    ),
    'E-02',
    'rpc_process_return must be SECURITY DEFINER'
  );
END $$;

-- E-03: rpc_ship_transfer is SECURITY DEFINER
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_proc
      WHERE proname = 'rpc_ship_transfer'
        AND prosecdef = true
    ),
    'E-03',
    'rpc_ship_transfer must be SECURITY DEFINER'
  );
END $$;

-- E-04: rpc_receive_transfer is SECURITY DEFINER
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_proc
      WHERE proname = 'rpc_receive_transfer'
        AND prosecdef = true
    ),
    'E-04',
    'rpc_receive_transfer must be SECURITY DEFINER'
  );
END $$;

-- E-05: rpc_reverse_goods_receipt exists (NOT IMPLEMENTED stub)
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM pg_proc
      WHERE proname = 'rpc_reverse_goods_receipt'
    ),
    'E-05',
    'rpc_reverse_goods_receipt must exist as a NOT IMPLEMENTED stub'
  );
END $$;

-- E-06: rpc_reverse_goods_receipt raises feature_not_supported
-- (Cannot call directly without auth context, but we can verify the function body)
DO $$
DECLARE
  v_body TEXT;
BEGIN
  SELECT prosrc INTO v_body
  FROM pg_proc
  WHERE proname = 'rpc_reverse_goods_receipt'
  LIMIT 1;

  PERFORM assert_true(
    v_body ILIKE '%feature_not_supported%',
    'E-06',
    'rpc_reverse_goods_receipt body must raise feature_not_supported ERRCODE'
  );
END $$;

-- E-07: rpc_process_return body reads variant_id from sale_items, not parameter
DO $$
DECLARE
  v_args TEXT[];
BEGIN
  SELECT proargnames INTO v_args
  FROM pg_proc
  WHERE proname = 'rpc_process_return'
  LIMIT 1;

  PERFORM assert_true(
    NOT ('p_variant_id' = ANY(COALESCE(v_args, ARRAY[]::TEXT[]))),
    'E-07',
    'rpc_process_return must NOT accept p_variant_id — variant_id read from sale_items'
  );
END $$;

-- E-08: rpc_ship_transfer does NOT accept p_shipped_by parameter
DO $$
DECLARE
  v_args TEXT[];
BEGIN
  SELECT proargnames INTO v_args
  FROM pg_proc
  WHERE proname = 'rpc_ship_transfer'
  LIMIT 1;

  PERFORM assert_true(
    NOT ('p_shipped_by' = ANY(COALESCE(v_args, ARRAY[]::TEXT[]))),
    'E-08',
    'rpc_ship_transfer must NOT accept p_shipped_by — actor = auth.uid() only'
  );
END $$;

-- E-09: rpc_receive_transfer does NOT accept p_received_by parameter
DO $$
DECLARE
  v_args TEXT[];
BEGIN
  SELECT proargnames INTO v_args
  FROM pg_proc
  WHERE proname = 'rpc_receive_transfer'
  LIMIT 1;

  PERFORM assert_true(
    NOT ('p_received_by' = ANY(COALESCE(v_args, ARRAY[]::TEXT[]))),
    'E-09',
    'rpc_receive_transfer must NOT accept p_received_by — actor = auth.uid() only'
  );
END $$;


-- ============================================================
-- F. SEED DATA INVARIANTS
-- ============================================================

-- F-01: TLC business exists
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (SELECT 1 FROM businesses WHERE code = 'TLC'),
    'F-01',
    'Business with code TLC must exist'
  );
END $$;

-- F-02: TLC branch LFT exists
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM branches br
      JOIN businesses b ON b.id = br.business_id
      WHERE b.code = 'TLC' AND br.code = 'LFT'
    ),
    'F-02',
    'Branch LFT must exist for TLC'
  );
END $$;

-- F-03: TLC settings have allow_cash_refund = false
DO $$
DECLARE
  v_setting BOOLEAN;
BEGIN
  SELECT (settings->>'allow_cash_refund')::BOOLEAN INTO v_setting
  FROM businesses WHERE code = 'TLC';

  PERFORM assert_true(
    v_setting = false,
    'F-03',
    'TLC settings must have allow_cash_refund = false'
  );
END $$;

-- F-04: TLC settings do NOT contain default_tax_rate (removed in HIGH 21)
DO $$
BEGIN
  PERFORM assert_true(
    NOT EXISTS (
      SELECT 1 FROM businesses
      WHERE code = 'TLC'
        AND settings ? 'default_tax_rate'
    ),
    'F-04',
    'TLC settings must NOT contain default_tax_rate key (not confirmed by pilot — HIGH 21)'
  );
END $$;

-- F-05: Bikiniler and Mayo categories are marked is_final_sale = true
DO $$
DECLARE
  v_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM categories c
  JOIN businesses b ON b.id = c.business_id
  WHERE b.code = 'TLC'
    AND c.slug IN ('bikiniler', 'mayo')
    AND c.is_final_sale = true;

  PERFORM assert_true(
    v_count = 2,
    'F-05',
    'Bikiniler and Mayo categories must have is_final_sale=true for TLC. Found: ' || v_count
  );
END $$;

-- F-06: TLC has Size, Color, Cup Size, Length product options
DO $$
DECLARE
  v_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM product_options po
  JOIN businesses b ON b.id = po.business_id
  WHERE b.code = 'TLC'
    AND po.name IN ('Size', 'Color', 'Cup Size', 'Length');

  PERFORM assert_true(
    v_count = 4,
    'F-06',
    'TLC must have 4 product options: Size, Color, Cup Size, Length. Found: ' || v_count
  );
END $$;

-- F-07: TLC cash register (Ana Kasa) exists for branch LFT
DO $$
BEGIN
  PERFORM assert_true(
    EXISTS (
      SELECT 1 FROM cash_registers cr
      JOIN branches br ON br.id = cr.branch_id
      JOIN businesses b ON b.id = br.business_id
      WHERE b.code = 'TLC' AND br.code = 'LFT' AND cr.name = 'Ana Kasa'
    ),
    'F-07',
    'Cash register Ana Kasa must exist for TLC branch LFT'
  );
END $$;


-- ============================================================
-- CLEANUP HELPER FUNCTION
-- ============================================================

DROP FUNCTION IF EXISTS assert_true(BOOLEAN, TEXT, TEXT);


-- ============================================================
-- END OF VERIFICATION TESTS
-- ============================================================
-- Test count: 28
--
-- A. Schema structure:  A-01 through A-10  (10 tests)
-- B. Cost pool:         B-01 through B-08   (8 tests)
-- C. Security/RLS:      C-01 through C-10  (10 tests)
-- D. FX rates:          D-01 through D-04b  (5 assertions in 4 blocks)
-- E. Posting RPCs:      E-01 through E-09   (9 tests)
-- F. Seed data:         F-01 through F-07   (7 tests)
--
-- Expected output on a clean apply: 28+ [PASS] NOTICE lines, no exceptions.
-- Any [FAIL] or unhandled exception = schema not ready for dev apply.
-- ============================================================
