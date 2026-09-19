-- ============================================================
-- BoutiqueOS  •  Verification tests  •  Rev 3
-- Runs in BOTH modes (plain PostgreSQL via 000_test_harness, and Supabase local).
-- Everything runs inside ONE transaction and is ROLLED BACK at the end.
-- Exit code: non-zero (RAISE EXCEPTION) if any test FAILs.
-- Fixed test UUIDs: users aaaaaaaa-0000-4000-8000-00000000000N
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- ------------------------------------------------------------
-- helpers
-- ------------------------------------------------------------
CREATE TABLE _tr (n SERIAL PRIMARY KEY, name TEXT, ok BOOLEAN, detail TEXT);
CREATE TABLE _tk (k TEXT PRIMARY KEY, v UUID);

CREATE FUNCTION t_set(p_k TEXT, p_v UUID) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN INSERT INTO _tk (k, v) VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v; RETURN p_v; END $$;
CREATE FUNCTION t_get(p_k TEXT) RETURNS UUID LANGUAGE sql SECURITY DEFINER STABLE AS $$ SELECT v FROM _tk WHERE _tk.k = p_k $$;
CREATE FUNCTION t_res(name TEXT, ok BOOLEAN, detail TEXT DEFAULT NULL) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO _tr (name, ok, detail) VALUES (name, ok, detail);
  RAISE NOTICE '[%] % %', CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END, name, COALESCE('- ' || detail, '');
END $$;
CREATE FUNCTION t_check(name TEXT, cond BOOLEAN, detail TEXT DEFAULT NULL) RETURNS VOID LANGUAGE sql AS $$ SELECT t_res(name, COALESCE(cond,false), detail) $$;
-- expect success
CREATE FUNCTION t_ok(name TEXT, sql TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE sql; PERFORM t_res(name, true);
  EXCEPTION WHEN OTHERS THEN PERFORM t_res(name, false, SQLSTATE || ' ' || SQLERRM); END;
END $$;
-- expect an error whose SQLSTATE = expect OR SQLERRM contains expect
CREATE FUNCTION t_err(name TEXT, sql TEXT, expect TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE sql; PERFORM t_res(name, false, 'expected error ' || expect || ' but succeeded');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = expect OR SQLERRM LIKE '%' || expect || '%' THEN PERFORM t_res(name, true, expect);
    ELSE PERFORM t_res(name, false, 'expected ' || expect || ' got ' || SQLSTATE || ' ' || SQLERRM); END IF;
  END;
END $$;
CREATE FUNCTION t_count(sql TEXT) RETURNS BIGINT LANGUAGE plpgsql AS $$ DECLARE n BIGINT; BEGIN EXECUTE sql INTO n; RETURN n; END $$;
CREATE FUNCTION t_num(sql TEXT) RETURNS NUMERIC LANGUAGE plpgsql AS $$ DECLARE n NUMERIC; BEGIN EXECUTE sql INTO n; RETURN n; END $$;
-- act as a user: JWT claims + authenticated role (RLS applies; RPCs are SECURITY DEFINER)
CREATE FUNCTION t_login(k TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE u UUID := t_get(k);
BEGIN
  PERFORM set_config('request.jwt.claim.sub', u::text, false);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, false);
  EXECUTE 'SET ROLE authenticated';
END $$;
CREATE FUNCTION t_logout() RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub', '', false);
  PERFORM set_config('request.jwt.claims', '', false);
END $$;
CREATE FUNCTION t_json_items(VARIADIC kv TEXT[]) RETURNS JSONB LANGUAGE plpgsql AS $$
-- t_json_items('v1','2','1000', 'v2','1',NULL) => [{variant_id,quantity,unit_price?}]
DECLARE out JSONB := '[]'; i INT := 1; o JSONB;
BEGIN
  WHILE i <= array_length(kv,1) LOOP
    o := jsonb_build_object('variant_id', t_get(kv[i]), 'quantity', kv[i+1]::int);
    IF kv[i+2] IS NOT NULL THEN o := o || jsonb_build_object('unit_price', kv[i+2]::numeric); END IF;
    out := out || o; i := i + 3;
  END LOOP;
  RETURN out;
END $$;
CREATE FUNCTION t_pay(method TEXT, cur TEXT, amt NUMERIC, rate NUMERIC DEFAULT NULL) RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('method', method, 'currency', cur, 'amount', amt) || CASE WHEN rate IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('exchange_rate', rate) END) $$;
CREATE FUNCTION t_pool(k TEXT, br TEXT DEFAULT 'br1') RETURNS variant_cost_pools LANGUAGE sql SECURITY DEFINER AS $$
  SELECT * FROM variant_cost_pools WHERE variant_id = t_get(k) AND branch_id = t_get(br) $$;
CREATE FUNCTION t_bucket(k TEXT, b inventory_bucket, br TEXT DEFAULT 'br1') RETURNS INTEGER LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(SUM(quantity),0)::int FROM inventory_movements WHERE variant_id = t_get(k) AND branch_id = t_get(br) AND bucket = b $$;

-- ------------------------------------------------------------
-- fixtures (as postgres)
-- ------------------------------------------------------------
SELECT t_set('biz',  'b0000000-0000-4000-8000-000000000001');
SELECT t_set('br1',  'b1000000-0000-4000-8000-000000000001');
SELECT t_set('reg',  'e0000000-0000-4000-8000-000000000001');
SELECT t_set('cat_elbise', 'd0000000-0000-4000-8000-000000000001');
SELECT t_set('cat_bikini', 'd0000000-0000-4000-8000-000000000006');
SELECT t_set('opt_size', 'c0000000-0000-4000-8000-000000000001');
SELECT t_set('val_s', 'c1000000-0000-4000-8000-000000000002');
SELECT t_set('val_m', 'c1000000-0000-4000-8000-000000000003');
SELECT t_set('u1', 'aaaaaaaa-0000-4000-8000-000000000001');  -- owner
SELECT t_set('u2', 'aaaaaaaa-0000-4000-8000-000000000002');  -- manager
SELECT t_set('u3', 'aaaaaaaa-0000-4000-8000-000000000003');  -- sales_staff
SELECT t_set('u4', 'aaaaaaaa-0000-4000-8000-000000000004');  -- stock_staff
SELECT t_set('u5', 'aaaaaaaa-0000-4000-8000-000000000005');  -- owner of business B
SELECT t_set('bizB', 'b0000000-0000-4000-8000-0000000000b2');
SELECT t_set('brB',  'b1000000-0000-4000-8000-0000000000b2');

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
  (t_get('u1'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner@tlc.test'),
  (t_get('u2'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'manager@tlc.test'),
  (t_get('u3'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sales@tlc.test'),
  (t_get('u4'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'stock@tlc.test'),
  (t_get('u5'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner@other.test')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) SELECT t_get(k) FROM unnest(ARRAY['u1','u2','u3','u4','u5']) k ON CONFLICT DO NOTHING;

INSERT INTO business_members (business_id, user_id, role) VALUES
  (t_get('biz'), t_get('u1'), 'owner'), (t_get('biz'), t_get('u2'), 'manager'),
  (t_get('biz'), t_get('u3'), 'sales_staff'), (t_get('biz'), t_get('u4'), 'stock_staff');

-- second tenant
INSERT INTO businesses (id, name, code, settings) VALUES (t_get('bizB'), 'Other Boutique', 'OTH', '{}'::jsonb);
INSERT INTO branches (id, business_id, name, code) VALUES (t_get('brB'), t_get('bizB'), 'Main', 'MAIN');
INSERT INTO business_members (business_id, user_id, role) VALUES (t_get('bizB'), t_get('u5'), 'owner');

-- second TLC branch (transfers)
WITH x AS (INSERT INTO branches (business_id, name, code) VALUES (t_get('biz'), 'Girne', 'GRN') RETURNING id) SELECT t_set('br2', id) FROM x;

-- suppliers
WITH x AS (INSERT INTO suppliers (business_id, name, currency) VALUES (t_get('biz'), 'Yerli Tedarikçi', 'TRY') RETURNING id) SELECT t_set('sup1', id) FROM x;
WITH x AS (INSERT INTO suppliers (business_id, name, currency, country) VALUES (t_get('biz'), 'UK Supplier', 'GBP', 'GB') RETURNING id) SELECT t_set('sup2', id) FROM x;

-- products
WITH x AS (INSERT INTO products (business_id, category_id, supplier_id, name, sku_prefix, default_sale_price, status)
  VALUES (t_get('biz'), t_get('cat_elbise'), t_get('sup1'), 'Keten Elbise', 'KE-01', 1000, 'active') RETURNING id) SELECT t_set('p1', id) FROM x;
WITH x AS (INSERT INTO products (business_id, category_id, supplier_id, name, sku_prefix, default_sale_price, status)
  VALUES (t_get('biz'), t_get('cat_bikini'), t_get('sup1'), 'Tropik Bikini', 'TB-01', 500, 'active') RETURNING id) SELECT t_set('p2', id) FROM x;
-- raw fixture inserts (bypass rpc_create_variant): attach options immediately after each variant so the
-- active-fingerprint unique index never sees two '' siblings on the same product
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p1'), 'KE-01-S') RETURNING id) SELECT t_set('v1', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v1'), t_get('opt_size'), t_get('val_s'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p1'), 'KE-01-M') RETURNING id) SELECT t_set('v2', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v2'), t_get('opt_size'), t_get('val_m'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p2'), 'TB-01-STD') RETURNING id) SELECT t_set('v3', id) FROM x;
SELECT t_check('T34k trigger-maintained fingerprint for v1 = size:S', (SELECT option_fingerprint FROM product_variants WHERE id = t_get('v1')) = t_get('opt_size')::text || ':' || t_get('val_s')::text);
-- product in tenant B
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status)
  VALUES (t_get('bizB'), 'Other Product', 'OP-01', 10, 'active') RETURNING id) SELECT t_set('pB', id) FROM x;

-- ============================================================
-- T01–T04  structural
-- ============================================================
SELECT t_check('T01 all 72 domain tables present',
  (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename NOT LIKE '\_%') = 72,
  (SELECT count(*)::text FROM pg_tables WHERE schemaname='public' AND tablename NOT LIKE '\_%'));
SELECT t_check('T02 RLS enabled on every public table',
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind='r' AND c.relname NOT LIKE '\_%' AND NOT c.relrowsecurity) = 0);
SELECT t_check('T03 every SECURITY DEFINER function pins search_path',
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prosecdef AND p.proname NOT LIKE 't\_%'
     AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig,'{}')) c WHERE c LIKE 'search_path=%')) = 0);
SELECT t_check('T04a internal fn_post_to_cost_pool not executable by authenticated',
  NOT has_function_privilege('authenticated', 'fn_post_to_cost_pool(uuid,uuid,uuid,integer,numeric,numeric)', 'EXECUTE'));
SELECT t_check('T04b internal fn_sale_core not executable by authenticated',
  NOT has_function_privilege('authenticated', 'fn_sale_core(uuid,uuid,uuid,uuid,uuid,uuid,text,timestamptz,jsonb,jsonb,discount_reason,text,numeric,uuid,uuid,text)', 'EXECUTE'));
SELECT t_check('T04c rpc_process_sale executable by authenticated',
  has_function_privilege('authenticated', 'rpc_process_sale(uuid,uuid,uuid,jsonb,jsonb,uuid,text,timestamptz,uuid,uuid,discount_reason,text)', 'EXECUTE'));
SELECT t_check('T04d anon cannot execute rpc_process_sale',
  NOT has_function_privilege('anon', 'rpc_process_sale(uuid,uuid,uuid,jsonb,jsonb,uuid,text,timestamptz,uuid,uuid,discount_reason,text)', 'EXECUTE'));

-- ============================================================
-- T05–T10  tenant isolation, cost visibility, RLS writes, immutability
-- ============================================================
SELECT t_login('u5');
SELECT t_check('T05a tenant B sees 0 TLC products', t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('biz') $q$) = 0);
SELECT t_check('T05b tenant B sees own product', t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('bizB') $q$) = 1);
SELECT t_err('T05c tenant B cannot insert product into TLC', $q$ INSERT INTO products (business_id, name, sku_prefix, default_sale_price) VALUES (t_get('biz'), 'x', 'X-1', 1) $q$, '42501');
SELECT t_err('T05d tenant B cannot post sale in TLC (RPC membership check)', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), gen_random_uuid(), '[]'::jsonb, '[]'::jsonb) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_err('T05e composite FK rejects cross-tenant category (postgres)', $q$ INSERT INTO products (business_id, category_id, name, sku_prefix, default_sale_price) VALUES (t_get('bizB'), t_get('cat_elbise'), 'x', 'X-2', 1) $q$, '23503');

SELECT t_login('u3');
SELECT t_err('T09a sales_staff cannot insert inventory_movements directly', $q$ INSERT INTO inventory_movements (business_id, branch_id, variant_id, bucket, quantity, reason, reference_type, reference_id) VALUES (t_get('biz'), t_get('br1'), t_get('v1'), 'sellable', 5, 'adjustment', 'x', gen_random_uuid()) $q$, '42501');
SELECT t_err('T09b sales_staff cannot insert reservations directly', $q$ INSERT INTO reservations (business_id, branch_id, reservation_number, hold_name, expires_at) VALUES (t_get('biz'), t_get('br1'), 'X', 'x', now()+interval '1 day') $q$, '42501');
SELECT t_err('T07a sales_staff cannot create goods receipt', $q$ INSERT INTO goods_receipts (business_id, branch_id, supplier_id, receipt_number) VALUES (t_get('biz'), t_get('br1'), t_get('sup1'), 'GR-X') $q$, '42501');
SELECT t_check('T07b sales_staff sees 0 suppliers', t_count($q$ SELECT count(*) FROM suppliers $q$) = 0);
SELECT t_logout();

-- ============================================================
-- T11–T13  goods receipt posting (stock_staff, J-3), FX cost, MWA
-- ============================================================
SELECT t_login('u4');
WITH x AS (INSERT INTO goods_receipts (business_id, branch_id, supplier_id, receipt_number, invoice_currency, exchange_rate)
  VALUES (t_get('biz'), t_get('br1'), t_get('sup1'), 'GR-2026-0001', 'TRY', 1) RETURNING id) SELECT t_set('gr1', id) FROM x;
-- stock_staff records what arrived; the price is not its business (cost visibility hardening)
SELECT t_ok('T08s0 stock_staff records quantities without a price', $q$
  SELECT rpc_goods_receipt_upsert_line(t_get('gr1'), t_get('v1'), 10);
  SELECT rpc_goods_receipt_upsert_line(t_get('gr1'), t_get('v2'), 5);
  SELECT rpc_goods_receipt_upsert_line(t_get('gr1'), t_get('v3'), 3) $q$);
SELECT t_err('T08s1 stock_staff cannot enter a purchase cost through the RPC', $q$ SELECT rpc_goods_receipt_upsert_line(t_get('gr1'), t_get('v1'), 10, 100) $q$, '42501');
SELECT t_err('T08s2 …nor through a direct write (trigger guard)', $q$ UPDATE goods_receipt_items SET unit_cost = 100 WHERE goods_receipt_id = t_get('gr1') $q$, '42501');
SELECT t_err('T08s3 …nor insert a priced line directly', $q$ INSERT INTO goods_receipt_items (goods_receipt_id, variant_id, quantity, unit_cost) VALUES (t_get('gr1'), t_get('v3'), 1, 5) $q$, '42501');
SELECT t_err('T08s4 stock_staff cannot read unit_cost (column privilege)', $q$ SELECT unit_cost FROM goods_receipt_items WHERE goods_receipt_id = t_get('gr1') $q$, '42501');
SELECT t_err('T08s5 stock_staff cannot review', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr1')) $q$, '42501');
SELECT t_err('T08s6 stock_staff cannot post', $q$ SELECT rpc_post_goods_receipt(t_get('gr1')) $q$, '42501');
SELECT t_check('T08s7 stock_staff still sees the operational line (variant, quantity)', t_count($q$ SELECT count(*) FROM goods_receipt_items WHERE goods_receipt_id = t_get('gr1') AND quantity > 0 $q$) = 3);
SELECT t_logout();
SELECT t_login('u2');
SELECT t_err('T08m0 review of unpriced lines refused (no silent zero cost)', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr1')) $q$, 'COST_REQUIRED');
SELECT t_ok('T08m1 manager prices the lines (quantity kept)', $q$
  SELECT rpc_goods_receipt_upsert_line(t_get('gr1'), t_get('v1'), 10, 100);
  SELECT rpc_goods_receipt_upsert_line(t_get('gr1'), t_get('v2'), 5, 100);
  SELECT rpc_goods_receipt_upsert_line(t_get('gr1'), t_get('v3'), 3, 200) $q$);
SELECT t_err('T08a0 posting without a review is refused (Phase 8A)', $q$ SELECT rpc_post_goods_receipt(t_get('gr1')) $q$, 'NOT_REVIEWED');
SELECT t_ok('T08a1 manager reviews TRY goods receipt', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr1')) $q$);
SELECT t_ok('T08a manager posts TRY goods receipt', $q$ SELECT rpc_post_goods_receipt(t_get('gr1')) $q$);
SELECT t_check('T08b manager reads acquisition cost through the financial RPC', (SELECT count(*) FROM jsonb_array_elements(rpc_goods_receipt_financial(t_get('gr1')) -> 'items') i WHERE (i ->> 'unit_cost_base') IS NOT NULL) = 3);
SELECT t_logout();
SELECT t_login('u4');
SELECT t_err('T08b2 stock_staff cannot read the posted cost columns either', $q$ SELECT unit_cost_base FROM goods_receipt_items WHERE goods_receipt_id = t_get('gr1') $q$, '42501');
SELECT t_err('T08b3 stock_staff cannot call the financial RPC', $q$ SELECT rpc_goods_receipt_financial(t_get('gr1')) $q$, '42501');
SELECT t_check('T08c stock_staff cannot read supplier ledger', t_count($q$ SELECT count(*) FROM supplier_account_entries $q$) = 0);
SELECT t_check('T08d stock_staff cannot read cost pools', t_count($q$ SELECT count(*) FROM variant_cost_pools $q$) = 0);
-- Posted receipts are protected by TWO layers. As a member, RLS (pol_gr_update USING status='draft')
-- filters the row out, so the UPDATE is a silent no-op (0 rows) rather than an error. The trigger
-- fires for RLS-bypassing roles; that half is asserted as postgres in T11d2 below.
SELECT t_check('T11d1 posted receipt not updatable by member (RLS: 0 rows)',
  t_count($q$ WITH u AS (UPDATE goods_receipts SET note = 'x' WHERE id = t_get('gr1') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_err('T11e posted receipt items frozen', $q$ INSERT INTO goods_receipt_items (goods_receipt_id, variant_id, quantity) VALUES (t_get('gr1'), t_get('v1'), 1) $q$, 'IMMUTABLE');
SELECT t_err('T11f posting twice rejected (stock_staff: role first)', $q$ SELECT rpc_post_goods_receipt(t_get('gr1')) $q$, '42501');

WITH x AS (INSERT INTO goods_receipts (business_id, branch_id, supplier_id, receipt_number, invoice_currency, exchange_rate)
  VALUES (t_get('biz'), t_get('br1'), t_get('sup2'), 'GR-2026-0002', 'GBP', 40) RETURNING id) SELECT t_set('gr2', id) FROM x;
SELECT t_ok('T12s stock_staff records the GBP quantity', $q$ SELECT rpc_goods_receipt_upsert_line(t_get('gr2'), t_get('v1'), 10) $q$);
SELECT t_logout();
SELECT t_login('u2');
SELECT t_err('T11f2 posting twice rejected (manager)', $q$ SELECT rpc_post_goods_receipt(t_get('gr1')) $q$, 'INVALID_STATE');
SELECT t_ok('T12m manager prices the GBP line', $q$ SELECT rpc_goods_receipt_upsert_line(t_get('gr2'), t_get('v1'), 10, 4) $q$);
SELECT t_ok('T12a0 review GBP receipt', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr2')) $q$);
SELECT t_ok('T12a manager posts GBP goods receipt @40', $q$ SELECT rpc_post_goods_receipt(t_get('gr2')) $q$);
SELECT t_logout();
SELECT t_err('T11d2 posted receipt frozen by trigger (RLS-bypassing role)', $q$ UPDATE goods_receipts SET note = 'x' WHERE id = t_get('gr1') $q$, 'IMMUTABLE');
SELECT t_check('T11d3 posted receipt note unchanged', (SELECT note IS NULL FROM goods_receipts WHERE id = t_get('gr1')));

SELECT t_check('T11a pool v1 qty 20 / value 2600 (1000 + 10x4x40)', (t_pool('v1')).on_hand_qty = 20 AND (t_pool('v1')).total_value_base = 2600,
  (t_pool('v1')).on_hand_qty || '/' || (t_pool('v1')).total_value_base);
SELECT t_check('T11b ledger sellable v1 = 20', t_bucket('v1','sellable') = 20);
SELECT t_check('T11c liability entries: TRY 2100 and GBP 40 (base 1600)',
  (SELECT count(*) FROM supplier_account_entries WHERE entry_type='liability' AND ((currency='TRY' AND amount_original=2100) OR (currency='GBP' AND amount_original=40 AND amount_base=1600))) = 2);
SELECT t_check('T12b GBP item unit_cost_base = 160 exact', (SELECT unit_cost_base FROM goods_receipt_items WHERE goods_receipt_id = t_get('gr2')) = 160);
SELECT t_check('T13 MWA v1 = 130 exact', (t_pool('v1')).total_value_base / (t_pool('v1')).on_hand_qty = 130);

-- ============================================================
-- T22  register sessions
-- ============================================================
SELECT t_login('u2');   -- drawer open/close is owner/manager (20260916170000); u3 sells on it below
SELECT t_err('T22a sale without open register rejected', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), gen_random_uuid(), t_json_items('v1','1',NULL), t_pay('cash','TRY',1000)) $q$, 'INVALID_REGISTER_SESSION');
SELECT t_set('sess1', rpc_open_register_session(t_get('reg'), '[{"currency":"TRY","amount":500}]'::jsonb));
SELECT t_err('T22b second open session on same register rejected', $q$ SELECT rpc_open_register_session(t_get('reg'), '[]'::jsonb) $q$, 'REGISTER_ALREADY_OPEN');
SELECT t_logout();
SELECT t_login('u3');
SELECT t_err('T22b sales_staff cannot open a drawer', $q$ SELECT rpc_open_register_session(t_get('reg'), '[]'::jsonb) $q$, 'FORBIDDEN');
SELECT t_logout();

-- ============================================================
-- T14–T17  sale: cost snapshot, price authority, oversell
-- ============================================================
SELECT t_login('u3');
SELECT t_set('sale1', (rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','2',NULL), t_pay('cash','TRY',2000)) ->> 'sale_id')::uuid);
SELECT t_logout();
SELECT t_set('si1', (SELECT id FROM sale_items WHERE sale_id = t_get('sale1')));
SELECT t_check('T14a sale item cost snapshot = pre-sale MWA 130', (SELECT unit_cost_at_sale FROM sale_item_costs WHERE sale_item_id = t_get('si1')) = 130);
SELECT t_check('T14b sale line_cost_base = 260', (SELECT line_cost_base FROM sale_item_costs WHERE sale_item_id = t_get('si1')) = 260);
SELECT t_check('T14c pool v1 after sale = 18 / 2340', (t_pool('v1')).on_hand_qty = 18 AND (t_pool('v1')).total_value_base = 2340);
SELECT t_check('T14d sale header totals server-computed (2000) and cash movement recorded',
  (SELECT total FROM sales WHERE id = t_get('sale1')) = 2000 AND (SELECT count(*) FROM cash_movements WHERE reference_id = t_get('sale1') AND movement_type='sale_cash' AND amount=2000) = 1);
SELECT t_check('T14e sale_costs total 260', (SELECT total_cost_base FROM sale_costs WHERE sale_id = t_get('sale1')) = 260);

SELECT t_login('u3');
SELECT t_check('T06a sales_staff cannot see sale_item_costs (0 rows)', t_count($q$ SELECT count(*) FROM sale_item_costs $q$) = 0);
SELECT t_check('T06b sales_staff cannot see inventory_movement_costs (0 rows)', t_count($q$ SELECT count(*) FROM inventory_movement_costs $q$) = 0);
SELECT t_check('T06c sales_staff CAN see ledger quantities', t_count($q$ SELECT count(*) FROM inventory_movements $q$) > 0);
SELECT t_check('T06d sales_staff CAN see own sale', t_count($q$ SELECT count(*) FROM sales WHERE id = t_get('sale1') $q$) = 1);
SELECT t_err('T17 PRICE_CHANGED when client price differs', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), jsonb_build_array(jsonb_build_object('variant_id', t_get('v1'), 'quantity', 1, 'expected_list_price', 900)), t_pay('cash','TRY',900)) $q$, 'PRICE_CHANGED');
SELECT t_err('T18a sales_staff manual discount rejected (0% authority)', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','1','900'), t_pay('cash','TRY',900)) $q$, 'DISCOUNT_NOT_AUTHORIZED');
SELECT t_err('T18b price above list rejected', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','1','1500'), t_pay('cash','TRY',1500)) $q$, 'INVALID_PRICE');
SELECT t_err('T16 oversell rejected (v2 has 5)', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v2','6',NULL), t_pay('cash','TRY',6000)) $q$, 'INSUFFICIENT_STOCK');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_set('sale3', (rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v2','1','900'), t_pay('cash','TRY',900), NULL, NULL, NULL, NULL, NULL, 'manager_discount') ->> 'sale_id')::uuid);
SELECT t_check('T18c manager discount accepted, discount_amount 100', (SELECT discount_amount FROM sales WHERE id = t_get('sale3')) = 100);
SELECT t_check('T06e manager sees sale_item_costs', t_count($q$ SELECT count(*) FROM sale_item_costs $q$) >= 2);
SELECT t_logout();

-- ============================================================
-- T19  idempotency
-- ============================================================
SELECT t_set('ctid1', gen_random_uuid());
SELECT t_login('u3');
SELECT t_set('sale4', (rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','1',NULL), t_pay('cash','TRY',1000), t_get('ctid1'), 'dev-1', date_trunc('hour', now())) ->> 'sale_id')::uuid);
SELECT t_check('T19a replay same payload returns same sale (replayed=true)',
  (SELECT r->>'replayed' = 'true' AND (r->>'sale_id')::uuid = t_get('sale4')
   FROM rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','1',NULL), t_pay('cash','TRY',1000), t_get('ctid1'), 'dev-1', date_trunc('hour', now())) r));
SELECT t_check('T19b replay did not create a second sale / movement', (SELECT count(*) FROM sales WHERE client_transaction_id = t_get('ctid1')) = 1 AND t_bucket('v1','sellable') = 17);
SELECT t_err('T19c same client_transaction_id with different payload rejected', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','2',NULL), t_pay('cash','TRY',2000), t_get('ctid1'), 'dev-1', date_trunc('hour', now())) $q$, 'IDEMPOTENCY_CONFLICT');

-- ============================================================
-- T20–T21  FX and payment reconciliation
-- ============================================================
SELECT t_err('T20a foreign payment without daily rate rejected', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v2','1',NULL), t_pay('card','GBP',25)) $q$, 'FX_RATE_MISSING');
SELECT t_err('T20b sales_staff cannot override FX', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v2','1',NULL), t_pay('card','GBP',25,40)) $q$, 'FX_OVERRIDE_NOT_AUTHORIZED');
SELECT t_err('T20c sales_staff cannot set FX rate', $q$ SELECT rpc_set_fx_rate(t_get('biz'), 'GBP', 40) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_set('fx1', rpc_set_fx_rate(t_get('biz'), 'GBP', 39));
SELECT t_set('fx2', rpc_set_fx_rate(t_get('biz'), 'GBP', 40));
SELECT t_check('T20d FX correction supersedes (v1 not current, v2 current)',
  (SELECT NOT is_current AND superseded_by = t_get('fx2') FROM fx_rates WHERE id = t_get('fx1')) AND (SELECT is_current AND version = 2 FROM fx_rates WHERE id = t_get('fx2')));
-- fx_rates has SELECT-only RLS, so a member's UPDATE/DELETE silently matches 0 rows (T20e1/f1);
-- the supersession-only trigger is what protects RLS-bypassing roles (T20e2/f2 as postgres).
SELECT t_check('T20e1 member UPDATE on fx_rates affects 0 rows (RLS)',
  t_count($q$ WITH u AS (UPDATE fx_rates SET rate_to_base = 99 WHERE id = t_get('fx2') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_check('T20f1 member DELETE on fx_rates affects 0 rows (RLS)',
  t_count($q$ WITH d AS (DELETE FROM fx_rates WHERE id = t_get('fx1') RETURNING 1) SELECT count(*) FROM d $q$) = 0);
SELECT t_logout();
SELECT t_err('T20e2 fx_rates rate edit blocked by trigger (RLS-bypassing role)', $q$ UPDATE fx_rates SET rate_to_base = 99 WHERE id = t_get('fx2') $q$, 'IMMUTABLE');
SELECT t_err('T20f2 fx_rates delete blocked by trigger (RLS-bypassing role)', $q$ DELETE FROM fx_rates WHERE id = t_get('fx1') $q$, 'IMMUTABLE');
SELECT t_check('T20e3 rates unchanged after both attempts',
  (SELECT rate_to_base FROM fx_rates WHERE id = t_get('fx2')) = 40 AND (SELECT count(*) FROM fx_rates WHERE id = t_get('fx1')) = 1);
SELECT t_login('u3');
SELECT t_set('sale2', (rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v2','1',NULL), t_pay('card','GBP',25)) ->> 'sale_id')::uuid);
SELECT t_check('T20g GBP 25 @40 => amount_base 1000 exact, fx_rate_id linked, not overridden',
  (SELECT amount_base = 1000 AND fx_rate_id = t_get('fx2') AND NOT fx_overridden FROM sale_payments WHERE sale_id = t_get('sale2')));
SELECT t_logout();

SELECT t_login('u3');
SELECT t_err('T21a underpayment rejected', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','1',NULL), t_pay('cash','TRY',500)) $q$, 'PAYMENT_SHORT');
SELECT t_err('T21b card overpayment rejected (no change possible)', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','1',NULL), t_pay('card','TRY',1200)) $q$, 'PAYMENT_MISMATCH');
SELECT t_err('T21c unaccepted currency rejected', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','1',NULL), t_pay('cash','JPY',1000)) $q$, '22023');
SELECT t_set('sale5', (rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','1',NULL), t_pay('cash','TRY',1200)) ->> 'sale_id')::uuid);
SELECT t_logout();   -- cash_movements belong to the manager's drawer (35e); the row is checked outside RLS
SELECT t_check('T21d cash overpayment => change 200 recorded and change_out movement',
  (SELECT change_given_base FROM sales WHERE id = t_get('sale5')) = 200
  AND (SELECT count(*) FROM cash_movements WHERE reference_id = t_get('sale5') AND movement_type = 'change_out' AND amount = -200) = 1);
-- v1 now 16

-- ============================================================
-- T23  reservations (AVAILABLE vs ON_HAND, explicit expiry, conversion)
-- ============================================================
SELECT t_login('u3');
SELECT t_err('T23a reservation without explicit expiry rejected', $q$ SELECT rpc_create_reservation(t_get('biz'), t_get('br1'), NULL, t_json_items('v2','1',NULL), NULL, 'Ayşe') $q$, 'INVALID_EXPIRY');
SELECT t_err('T23b reservation needs customer or hold name', $q$ SELECT rpc_create_reservation(t_get('biz'), t_get('br1'), now()+interval '1 day', t_json_items('v2','1',NULL)) $q$, 'IDENTITY_REQUIRED');
SELECT t_set('res1', rpc_create_reservation(t_get('biz'), t_get('br1'), now()+interval '1 day', t_json_items('v2','3',NULL), NULL, 'Ayşe', '05330000000', NULL, 'instagram_dm'));
SELECT t_check('T23c on_hand v2 still 3 but available 0', t_bucket('v2','sellable') = 3
  AND (SELECT available_quantity FROM v_stock_available WHERE variant_id = t_get('v2') AND branch_id = t_get('br1')) = 0);
SELECT t_err('T23d selling a reserved unit to someone else rejected', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v2','1',NULL), t_pay('cash','TRY',1000)) $q$, 'INSUFFICIENT_STOCK');
SELECT t_err('T23e reserving beyond available rejected', $q$ SELECT rpc_create_reservation(t_get('biz'), t_get('br1'), now()+interval '1 day', t_json_items('v2','1',NULL), NULL, 'Zeynep') $q$, 'INSUFFICIENT_STOCK');
SELECT t_err('T23f converting with fewer units than reserved rejected', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v2','1',NULL), t_pay('cash','TRY',1000), NULL, NULL, NULL, NULL, t_get('res1')) $q$, 'RESERVATION_MISMATCH');
SELECT t_set('sale6', (rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v2','3',NULL), t_pay('cash','TRY',3000), NULL, NULL, NULL, NULL, t_get('res1')) ->> 'sale_id')::uuid);
SELECT t_check('T23g reservation converted and linked', (SELECT status = 'converted' AND converted_to_sale_id = t_get('sale6') FROM reservations WHERE id = t_get('res1')));
SELECT t_err('T23h converted reservation cannot be cancelled', $q$ SELECT rpc_cancel_reservation(t_get('res1'), 'x') $q$, 'INVALID_STATE');
SELECT t_logout();
SELECT t_check('T15 full depletion => pool v2 qty 0 AND value exactly 0', (t_pool('v2')).on_hand_qty = 0 AND (t_pool('v2')).total_value_base = 0,
  (t_pool('v2')).total_value_base::text);

-- ============================================================
-- T24–T29  returns / exchanges
-- ============================================================
SELECT t_login('u3');
SELECT t_err('T24z sales_staff cannot complete a return (9B: owner/manager)', $q$ SELECT rpc_process_exchange(t_get('biz'), t_get('br1'), t_get('sess1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1)), t_json_items('v1','1',NULL), '[]'::jsonb, gen_random_uuid()) $q$, 'FORBIDDEN');
SELECT t_err('T24z …nor a plain return', $q$ SELECT rpc_process_return(t_get('biz'), t_get('br1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1)), 'refund', 'x', t_get('sess1'), 'cash') $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_err('T28a refund rejected by policy', $q$ SELECT rpc_process_return(t_get('biz'), t_get('br1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1)), 'refund', 'x', t_get('sess1'), 'cash') $q$, 'REFUND_NOT_ALLOWED');
SELECT t_err('T28b store credit rejected by policy', $q$ SELECT rpc_process_return(t_get('biz'), t_get('br1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1)), 'store_credit', 'x') $q$, 'STORE_CREDIT_NOT_ALLOWED');
SELECT t_err('T28c bare exchange return must use rpc_process_exchange', $q$ SELECT rpc_process_return(t_get('biz'), t_get('br1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1)), 'exchange', 'x') $q$, 'USE_EXCHANGE_RPC');
-- (T24a "sales_staff cannot choose sellable disposition" is subsumed by T24z: sales_staff cannot post a return at all)
SELECT t_set('ctid2', gen_random_uuid());
SELECT t_set('xch1', (rpc_process_exchange(t_get('biz'), t_get('br1'), t_get('sess1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1)), t_json_items('v1','1',NULL), '[]'::jsonb, t_get('ctid2'), 'dev-1', date_trunc('hour', now()), 'beden değişimi') ->> 'sale_id')::uuid);
SELECT t_logout();
SELECT t_set('ret1', (SELECT id FROM returns WHERE replacement_sale_id = t_get('xch1')));
SELECT t_check('T24b default disposition quarantine (ledger +1 quarantine)', t_bucket('v1','quarantine') = 1 AND (SELECT disposition FROM return_items WHERE return_id = t_get('ret1')) = 'quarantine');
SELECT t_check('T24c re-entry at ORIGINAL unit_cost_at_sale 130', (SELECT c.unit_cost_base FROM inventory_movement_costs c JOIN inventory_movements m ON m.id = c.movement_id WHERE m.reason='customer_return' AND m.variant_id=t_get('v1')) = 130);
SELECT t_check('T29a exchange linked: group id shared, replacement sale credited 1000, due 0',
  (SELECT r.exchange_group_id = s.exchange_group_id AND s.credit_applied_base = 1000 AND s.amount_due_base = 0 FROM returns r JOIN sales s ON s.id = r.replacement_sale_id WHERE r.id = t_get('ret1')));
SELECT t_check('T29b original sale immutable (still completed, 2 units)', (SELECT status = 'completed' FROM sales WHERE id = t_get('sale1')) AND (SELECT quantity FROM sale_items WHERE id = t_get('si1')) = 2);
SELECT t_check('T29c pool v1 unchanged in value by equal exchange (16 x 130 = 2080)', (t_pool('v1')).on_hand_qty = 16 AND (t_pool('v1')).total_value_base = 2080, (t_pool('v1')).total_value_base::text);
SELECT t_login('u2');
SELECT t_check('T29d exchange replay returns same sale', (SELECT (r->>'replayed')='true' AND (r->>'sale_id')::uuid = t_get('xch1') FROM rpc_process_exchange(t_get('biz'), t_get('br1'), t_get('sess1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1)), t_json_items('v1','1',NULL), '[]'::jsonb, t_get('ctid2'), 'dev-1', date_trunc('hour', now()), 'beden değişimi') r));
SELECT t_logout();
SELECT t_check('T29e exchange replay did not duplicate the return', (SELECT count(*) FROM returns WHERE original_sale_id = t_get('sale1')) = 1);

-- atomicity: replacement oversell must roll back the return too
SELECT t_login('u2');
SELECT t_err('T29f exchange with unavailable replacement fails atomically', $q$ SELECT rpc_process_exchange(t_get('biz'), t_get('br1'), t_get('sess1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1, 'disposition', 'sellable')), t_json_items('v2','1',NULL), '[]'::jsonb) $q$, 'INSUFFICIENT_STOCK');
SELECT t_check('T29g no partial return persisted after failed exchange', (SELECT count(*) FROM returns WHERE original_sale_id = t_get('sale1')) = 1 AND t_bucket('v1','sellable') = 15);
-- manager may return straight to sellable; price difference collected in cash
SELECT t_set('xch2', (rpc_process_exchange(t_get('biz'), t_get('br1'), t_get('sess1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1, 'disposition', 'sellable')), t_json_items('v1','1',NULL,'v3','1',NULL), t_pay('cash','TRY',500), NULL, NULL, NULL, 'renk değişimi') ->> 'sale_id')::uuid);
SELECT t_logout();
SELECT t_set('ret2', (SELECT id FROM returns WHERE replacement_sale_id = t_get('xch2')));
SELECT t_check('T24d manager disposition sellable honoured; price difference 500 collected',
  (SELECT disposition FROM return_items WHERE return_id = t_get('ret2')) = 'sellable'
  AND (SELECT total = 1500 AND credit_applied_base = 1000 AND amount_due_base = 500 FROM sales WHERE id = t_get('xch2'))
  AND (SELECT count(*) FROM cash_movements WHERE reference_id = t_get('xch2') AND amount = 500) = 1);
SELECT t_check('T25a returned quantity truth = 2 of 2', (SELECT returned_quantity FROM v_sale_item_returned WHERE sale_item_id = t_get('si1')) = 2);
SELECT t_login('u2');
SELECT t_err('T25b over-return rejected (SUM across returns)', $q$ SELECT rpc_process_exchange(t_get('biz'), t_get('br1'), t_get('sess1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1)), t_json_items('v1','1',NULL), '[]'::jsonb) $q$, 'OVER_RETURN');
-- final sale: the bikini bought on xch2 cannot come back
SELECT t_set('si_bikini', (SELECT id FROM sale_items WHERE sale_id = t_get('xch2') AND variant_id = t_get('v3')));
SELECT t_err('T26 final-sale category rejected', $q$ SELECT rpc_process_exchange(t_get('biz'), t_get('br1'), t_get('sess1'), t_get('xch2'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si_bikini'), 'quantity', 1)), t_json_items('v1','1',NULL), t_pay('cash','TRY',500)) $q$, 'FINAL_SALE');
-- exchange window: sale dated 4 days ago
SELECT t_set('sale_old', (rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','1',NULL), t_pay('cash','TRY',1000), NULL, NULL, now() - interval '4 days') ->> 'sale_id')::uuid);
SELECT t_set('si_old', (SELECT id FROM sale_items WHERE sale_id = t_get('sale_old')));
SELECT t_err('T27 exchange window (3 days) expired', $q$ SELECT rpc_process_exchange(t_get('biz'), t_get('br1'), t_get('sess1'), t_get('sale_old'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si_old'), 'quantity', 1)), t_json_items('v1','1',NULL), '[]'::jsonb) $q$, 'EXCHANGE_WINDOW_EXPIRED');
SELECT t_err('T34c occurred_at outside window rejected', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','1',NULL), t_pay('cash','TRY',1000), NULL, NULL, now() - interval '30 days') $q$, 'INVALID_OCCURRED_AT');
SELECT t_logout();
-- v1: 16 -1 (sale_old) = 15

-- ============================================================
-- T30  void
-- ============================================================
SELECT t_login('u3');
SELECT t_err('T30a sales_staff cannot void', $q$ SELECT rpc_void_sale(t_get('sale5'), 'yanlış satış') $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_err('T30b sale with returns cannot be voided', $q$ SELECT rpc_void_sale(t_get('sale1'), 'x reason') $q$, 'VOID_BLOCKED');
SELECT t_ok('T30c manager voids sale5 (cash 1200, change 200)', $q$ SELECT rpc_void_sale(t_get('sale5'), 'yanlış satış') $q$);
SELECT t_err('T30d double void rejected', $q$ SELECT rpc_void_sale(t_get('sale5'), 'again') $q$, 'ALREADY_VOIDED');
SELECT t_logout();
SELECT t_check('T30e void restores stock at original cost: v1 16 / 2080', (t_pool('v1')).on_hand_qty = 16 AND (t_pool('v1')).total_value_base = 2080, (t_pool('v1')).on_hand_qty || '/' || (t_pool('v1')).total_value_base);
SELECT t_check('T30f void cash movements: -1200 out and +200 change reversal', (SELECT count(*) FROM cash_movements WHERE reference_id = t_get('sale5') AND reference_type='sale_void' AND ((movement_type='void_cash_out' AND amount=-1200) OR (movement_type='cash_in' AND amount=200))) = 2);
SELECT t_check('T30g sale status voided with reason', (SELECT status='voided' AND void_reason='yanlış satış' FROM sales WHERE id = t_get('sale5')));
SELECT t_err('T10a voided sale cannot be edited further', $q$ UPDATE sales SET note = 'x' WHERE id = t_get('sale5') $q$, 'IMMUTABLE');
SELECT t_err('T10b sale_items immutable (even for postgres)', $q$ UPDATE sale_items SET quantity = 99 WHERE id = t_get('si1') $q$, 'IMMUTABLE');
SELECT t_err('T10c inventory_movements immutable', $q$ DELETE FROM inventory_movements WHERE variant_id = t_get('v1') $q$, 'IMMUTABLE');
SELECT t_err('T10d supplier ledger immutable', $q$ UPDATE supplier_account_entries SET amount_original = 1 $q$, 'IMMUTABLE');

-- ============================================================
-- T31  adjustments / state change / write-off   (v3: 3 - 1 sold = 2 @200)
-- ============================================================
SELECT t_login('u3');
SELECT t_err('T31a sales_staff cannot adjust', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br1'), t_get('v3'), 'sellable', 1, 'sayım farkı', 'current_mwa') $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_ok('T31b negative adjustment at MWA', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br1'), t_get('v3'), 'sellable', -1, 'sayım farkı', 'current_mwa') $q$);
SELECT t_check('T31c pool v3 1 / 200', (t_pool('v3')).on_hand_qty = 1 AND (t_pool('v3')).total_value_base = 200);
SELECT t_err('T31d negative beyond bucket rejected', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br1'), t_get('v3'), 'sellable', -5, 'sayım farkı', 'current_mwa') $q$, 'INSUFFICIENT_STOCK');
SELECT t_err('T31e manual positive adjustment without cost rejected', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br1'), t_get('v3'), 'sellable', 2, 'bulundu', 'manual_cost') $q$, 'COST_REQUIRED');
SELECT t_err('T31f last-purchase confirmation mismatch rejected', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br1'), t_get('v3'), 'sellable', 2, 'bulundu', 'last_purchase_cost_confirmed', 123) $q$, 'COST_CONFIRMATION_MISMATCH');
SELECT t_ok('T31g last-purchase confirmed (200) accepted', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br1'), t_get('v3'), 'sellable', 2, 'bulundu', 'last_purchase_cost_confirmed', 200) $q$);
SELECT t_ok('T31h manual cost 150 x 1', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br1'), t_get('v3'), 'sellable', 1, 'bulundu', 'manual_cost', 150) $q$);
SELECT t_check('T31i pool v3 4 / 750 (200+400+150)', (t_pool('v3')).on_hand_qty = 4 AND (t_pool('v3')).total_value_base = 750, (t_pool('v3')).total_value_base::text);
SELECT t_logout();
SELECT t_login('u4');
SELECT t_ok('T31j stock_staff moves 1 sellable -> damaged', $q$ SELECT rpc_change_stock_condition(t_get('biz'), t_get('br1'), t_get('v3'), 'sellable', 'damaged', 1, 'yırtık') $q$);
SELECT t_err('T31k stock_staff cannot write off', $q$ SELECT rpc_write_off(t_get('biz'), t_get('br1'), t_get('v3'), 'damaged', 1, 'imha') $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_check('T31l state change: buckets 3/1, pool value unchanged 750', t_bucket('v3','sellable') = 3 AND t_bucket('v3','damaged') = 1 AND (t_pool('v3')).total_value_base = 750 AND (t_pool('v3')).on_hand_qty = 4);
SELECT t_login('u2');
SELECT t_ok('T31m write off damaged unit', $q$ SELECT rpc_write_off(t_get('biz'), t_get('br1'), t_get('v3'), 'damaged', 1, 'imha') $q$);
SELECT t_logout();
SELECT t_check('T31n write-off at MWA 187.5: pool 3 / 562.5', (t_pool('v3')).on_hand_qty = 3 AND (t_pool('v3')).total_value_base = 562.5, (t_pool('v3')).total_value_base::text);
SELECT t_check('T31o pool invariants hold on every row', (SELECT count(*) FROM variant_cost_pools WHERE on_hand_qty < 0 OR total_value_base < 0 OR (on_hand_qty = 0 AND total_value_base <> 0)) = 0);
SELECT t_check('T31p ledger on_hand == pool on_hand for every pool', (SELECT count(*) FROM variant_cost_pools p WHERE p.on_hand_qty <> (SELECT COALESCE(SUM(quantity),0) FROM inventory_movements m WHERE m.business_id=p.business_id AND m.branch_id=p.branch_id AND m.variant_id=p.variant_id)) = 0);
SELECT t_check('T31q pool value == SUM(movement value deltas)', (SELECT count(*) FROM variant_cost_pools p WHERE p.total_value_base <> (SELECT COALESCE(SUM(c.value_delta_base),0) FROM inventory_movements m JOIN inventory_movement_costs c ON c.movement_id=m.id WHERE m.business_id=p.business_id AND m.branch_id=p.branch_id AND m.variant_id=p.variant_id)) = 0);

-- ============================================================
-- T32  transfers (v1 16 @130 -> ship 4 to br2)
-- ============================================================
WITH x AS (INSERT INTO stock_transfers (business_id, from_branch_id, to_branch_id, transfer_number) VALUES (t_get('biz'), t_get('br1'), t_get('br2'), 'TR-0001') RETURNING id) SELECT t_set('tr1', id) FROM x;
INSERT INTO stock_transfer_lines (transfer_id, variant_id, quantity_sent) VALUES (t_get('tr1'), t_get('v1'), 4);
SELECT t_login('u2');
SELECT t_err('T32a receive before ship rejected', $q$ SELECT rpc_receive_transfer(t_get('tr1')) $q$, 'INVALID_STATE');
SELECT t_ok('T32b ship transfer', $q$ SELECT rpc_ship_transfer(t_get('tr1')) $q$);
SELECT t_logout();
SELECT t_check('T32c source pool 12 / 1560; THI carries exactly 520; not in any bucket', (t_pool('v1')).on_hand_qty = 12 AND (t_pool('v1')).total_value_base = 1560
  AND (SELECT carried_total_value_base = 520 AND received_at IS NULL FROM transfer_held_inventory WHERE transfer_id = t_get('tr1'))
  AND t_bucket('v1','sellable') = 11 AND t_bucket('v1','quarantine') = 1 AND t_bucket('v1','sellable','br2') = 0);
SELECT t_err('T32d shipped lines frozen', $q$ UPDATE stock_transfer_lines SET quantity_sent = 9 WHERE transfer_id = t_get('tr1') $q$, 'IMMUTABLE');
SELECT t_login('u2');
SELECT t_ok('T32e receive transfer', $q$ SELECT rpc_receive_transfer(t_get('tr1')) $q$);
SELECT t_err('T32f receive twice rejected', $q$ SELECT rpc_receive_transfer(t_get('tr1')) $q$, 'INVALID_STATE');
SELECT t_logout();
SELECT t_check('T32g destination pool 4 / 520 exact, THI closed', (t_pool('v1','br2')).on_hand_qty = 4 AND (t_pool('v1','br2')).total_value_base = 520
  AND (SELECT received_at IS NOT NULL FROM transfer_held_inventory WHERE transfer_id = t_get('tr1')) AND t_bucket('v1','sellable','br2') = 4);

-- ============================================================
-- T33  supplier payments (manager+) with cross-currency allocation
-- ============================================================
SELECT t_login('u4');
SELECT t_err('T33a stock_staff cannot record supplier payment', $q$ SELECT rpc_record_supplier_payment(t_get('biz'), t_get('sup2'), 100, 'TRY', 'bank_transfer', CURRENT_DATE) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_set('sp1', rpc_record_supplier_payment(t_get('biz'), t_get('sup2'), 1600, 'TRY', 'bank_transfer', CURRENT_DATE));
SELECT t_set('liab_gbp', (SELECT id FROM supplier_account_entries WHERE supplier_id = t_get('sup2') AND entry_type = 'liability'));
SELECT t_ok('T33b allocate 40 GBP liability against 1600 TRY payment', $q$ SELECT rpc_allocate_supplier_payment(t_get('sp1'), t_get('liab_gbp'), 40) $q$);
SELECT t_check('T33c allocation explicit: liability 40 GBP, payment 1600 TRY, base 1600, basis liability_rate',
  (SELECT liability_currency_amount_applied = 40 AND payment_currency_amount_applied = 1600 AND base_amount_applied = 1600 AND settlement_basis = 'liability_rate' FROM supplier_payment_allocations WHERE supplier_payment_id = t_get('sp1')));
SELECT t_err('T33d over-allocation rejected', $q$ SELECT rpc_allocate_supplier_payment(t_get('sp1'), t_get('liab_gbp'), 1) $q$, 'OVER_ALLOCATION');
SELECT t_check('T33e supplier balance sup2 = 0 base, receipt paid', (SELECT balance_base FROM v_supplier_balance WHERE supplier_id = t_get('sup2')) = 0 AND (SELECT payment_status FROM goods_receipts WHERE id = t_get('gr2')) = 'paid');
SELECT t_check('T33f supplier balance sup1 = 2100 (unpaid TRY receipt)', (SELECT balance_base FROM v_supplier_balance WHERE supplier_id = t_get('sup1')) = 2100);
SELECT t_logout();

-- ============================================================
-- T22 (cont.)  register close, per-currency expected, sale after close
-- ============================================================
SELECT t_login('u3');
SELECT t_err('T22c sales_staff cannot close the drawer it sells on', $q$ SELECT rpc_close_register_session(t_get('sess1'), '[{"currency":"TRY","counted_amount":0},{"currency":"GBP","counted_amount":0}]'::jsonb) $q$, 'FORBIDDEN');
SELECT t_check('T22c …and the session is still open', (SELECT status::text FROM register_sessions WHERE id = t_get('sess1')) = 'open');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_err('T22c close requires every drawer currency counted', $q$ SELECT rpc_close_register_session(t_get('sess1'), '[]'::jsonb) $q$, 'COUNT_REQUIRED');
SELECT t_ok('T22d close with TRY + GBP counts', $q$ SELECT rpc_close_register_session(t_get('sess1'), jsonb_build_array(
   jsonb_build_object('currency','TRY','counted_amount', (SELECT 500 + COALESCE(SUM(amount),0) FROM cash_movements WHERE register_session_id = t_get('sess1') AND currency='TRY')),
   jsonb_build_object('currency','GBP','counted_amount', 0)), 'gün sonu') $q$);
SELECT t_err('T22e sale after close rejected', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), t_get('sess1'), t_json_items('v1','1',NULL), t_pay('cash','TRY',1000)) $q$, 'REGISTER_CLOSED');
SELECT t_logout();
SELECT t_check('T22f TRY expected = opening + physical cash movements, variance 0; card GBP never in drawer (GBP expected 0)',
  (SELECT expected_amount = 500 + (SELECT COALESCE(SUM(amount),0) FROM cash_movements WHERE register_session_id = t_get('sess1') AND currency='TRY') AND variance_amount = 0
   FROM register_session_currency_counts WHERE register_session_id = t_get('sess1') AND currency = 'TRY')
  AND (SELECT count(*) FROM register_session_currency_counts WHERE register_session_id = t_get('sess1') AND currency = 'GBP') = 0);
SELECT t_err('T22g closed session frozen', $q$ UPDATE register_sessions SET closing_note = 'x' WHERE id = t_get('sess1') $q$, 'IMMUTABLE');

-- ============================================================
-- T34  misc: fingerprint duplicates, missing settings, deferred features
-- ============================================================
SELECT t_login('u1');
SELECT t_err('T34a duplicate active variant combination rejected (Size=S exists)', $q$ SELECT rpc_create_variant(t_get('p1'), 'KE-01-S2', ARRAY[t_get('val_s')]) $q$, '23505');
SELECT t_ok('T34b new distinct combination accepted', $q$ SELECT rpc_create_variant(t_get('p1'), 'KE-01-XS', ARRAY['c1000000-0000-4000-8000-000000000001'::uuid]) $q$);
SELECT t_ok('T34d internal barcode assigned (Code128, business-prefixed)', $q$ SELECT rpc_assign_internal_barcode(t_get('v1')) $q$);
SELECT t_check('T34e barcode format TLC + digits', (SELECT barcode ~ '^TLC[0-9]+$' FROM barcodes WHERE variant_id = t_get('v1') AND is_primary));
SELECT t_err('T34f supplier return posting is DEFERRED', $q$ SELECT rpc_post_supplier_return(gen_random_uuid()) $q$, 'NOT_IMPLEMENTED');
SELECT t_err('T34g goods receipt reversal needs a reason (Phase 8A replaced the stub)', $q$ SELECT rpc_reverse_goods_receipt(t_get('gr1'), '') $q$, 'REASON_REQUIRED');
SELECT t_err('T34h owner cannot write supplier_returns directly', $q$ INSERT INTO supplier_returns (business_id, branch_id, supplier_id, return_number) VALUES (t_get('biz'), t_get('br1'), t_get('sup1'), 'SR-1') $q$, '42501');
SELECT t_logout();
SELECT t_err('T34i missing policy setting raises (no invented defaults)', $q$ SELECT fn_setting(t_get('bizB'), 'exchange_window_days') $q$, 'SETTING_MISSING');
SELECT t_check('T34j no unit_cost anywhere in member-readable tables',
  (SELECT count(*) FROM information_schema.columns WHERE table_schema='public'
     AND table_name IN ('inventory_movements','sale_items','return_items','sales','returns','reservations','reservation_items','stock_transfer_lines')
     AND column_name ILIKE '%cost%') = 0);

-- ============================================================
-- T35  rpc_create_goods_receipt  (Phase 3 GAP-1)
-- ============================================================
-- extra fixtures (as postgres)
WITH x AS (INSERT INTO branches (business_id, name, code, status) VALUES (t_get('biz'), 'Kapali Sube', 'CLS', 'inactive') RETURNING id) SELECT t_set('brOff', id) FROM x;
WITH x AS (INSERT INTO suppliers (business_id, name, currency) VALUES (t_get('bizB'), 'Other Supplier', 'TRY') RETURNING id) SELECT t_set('supB', id) FROM x;
WITH x AS (INSERT INTO suppliers (business_id, name, currency, status) VALUES (t_get('biz'), 'Pasif Tedarikci', 'TRY', 'inactive') RETURNING id) SELECT t_set('supOff', id) FROM x;

SELECT t_login('u1');
SELECT t_ok ('T35a owner creates draft goods receipt', $q$ SELECT t_set('gr3', rpc_create_goods_receipt(t_get('br1'), t_get('sup1'))) $q$);
SELECT t_err('T35b cross-tenant branch rejected (no membership)', $q$ SELECT rpc_create_goods_receipt(t_get('brB'), t_get('sup1')) $q$, 'FORBIDDEN');
SELECT t_err('T35c cross-tenant supplier rejected', $q$ SELECT rpc_create_goods_receipt(t_get('br1'), t_get('supB')) $q$, 'INVALID_SUPPLIER');
SELECT t_err('T35d inactive supplier rejected', $q$ SELECT rpc_create_goods_receipt(t_get('br1'), t_get('supOff')) $q$, 'INVALID_SUPPLIER');
SELECT t_err('T35e inactive branch rejected', $q$ SELECT rpc_create_goods_receipt(t_get('brOff'), t_get('sup1')) $q$, 'INVALID_BRANCH');
SELECT t_err('T35f unknown branch rejected', $q$ SELECT rpc_create_goods_receipt(gen_random_uuid(), t_get('sup1')) $q$, 'INVALID_BRANCH');
SELECT t_err('T35g TRY invoice with rate <> 1 rejected', $q$ SELECT rpc_create_goods_receipt(t_get('br1'), t_get('sup1'), 'TRY', 40) $q$, 'INVALID_FX');
SELECT t_err('T35h non-positive rate rejected', $q$ SELECT rpc_create_goods_receipt(t_get('br1'), t_get('sup2'), 'GBP', 0) $q$, 'INVALID_FX');
SELECT t_err('T35i unsupported currency rejected', $q$ SELECT rpc_create_goods_receipt(t_get('br1'), t_get('sup1'), 'XXX', 1) $q$, 'INVALID_CURRENCY');
SELECT t_ok ('T35j non-TRY draft with valid rate', $q$ SELECT t_set('gr5', rpc_create_goods_receipt(t_get('br1'), t_get('sup2'), 'GBP', 42.5)) $q$);

SELECT t_login('u2');
SELECT t_ok ('T35k manager creates draft goods receipt', $q$ SELECT t_set('gr4', rpc_create_goods_receipt(t_get('br1'), t_get('sup1'), 'TRY', 1, CURRENT_DATE, 'FTR-99', 'manager notu')) $q$);

SELECT t_login('u4');
SELECT t_ok ('T35l stock_staff creates draft goods receipt', $q$ SELECT t_set('gr6', rpc_create_goods_receipt(t_get('br2'), t_get('sup1'))) $q$);

SELECT t_login('u3');
SELECT t_err('T35m sales_staff cannot create draft goods receipt', $q$ SELECT rpc_create_goods_receipt(t_get('br1'), t_get('sup1')) $q$, '42501');
SELECT t_err('T35n sales_staff still cannot call fn_next_sequence', $q$ SELECT fn_next_sequence(t_get('biz'), 'GR') $q$, '42501');
SELECT t_err('T35o document_sequences still not client-writable', $q$ INSERT INTO document_sequences (business_id, prefix, year, last_value) VALUES (t_get('biz'), 'GR', 2026, 999) $q$, '42501');
SELECT t_logout();

SELECT t_check('T35p generated receipt_number is not null',
  (SELECT bool_and(receipt_number IS NOT NULL AND length(receipt_number) > 0) FROM goods_receipts WHERE id IN (t_get('gr3'), t_get('gr4'), t_get('gr5'), t_get('gr6'))));
SELECT t_check('T35q receipt_number format GR-YYYY-NNNNNN',
  (SELECT bool_and(receipt_number ~ '^GR-[0-9]{4}-[0-9]{6}$') FROM goods_receipts WHERE id IN (t_get('gr3'), t_get('gr4'), t_get('gr5'), t_get('gr6'))));
SELECT t_check('T35r four distinct receipt numbers',
  (SELECT count(DISTINCT receipt_number) FROM goods_receipts WHERE id IN (t_get('gr3'), t_get('gr4'), t_get('gr5'), t_get('gr6'))) = 4);
SELECT t_check('T35s numbers strictly increasing in creation order',
  (SELECT (regexp_replace(receipt_number, '\D', '', 'g'))::BIGINT FROM goods_receipts WHERE id = t_get('gr4'))
  > (SELECT (regexp_replace(receipt_number, '\D', '', 'g'))::BIGINT FROM goods_receipts WHERE id = t_get('gr3')));
SELECT t_check('T35t every created receipt is draft',
  (SELECT bool_and(status = 'draft') FROM goods_receipts WHERE id IN (t_get('gr3'), t_get('gr4'), t_get('gr5'), t_get('gr6'))));
SELECT t_check('T35u created_by is the acting user', (SELECT created_by FROM goods_receipts WHERE id = t_get('gr3')) = t_get('u1'));
SELECT t_check('T35v TRY draft stored with exchange_rate 1',
  (SELECT invoice_currency = 'TRY' AND exchange_rate = 1 FROM goods_receipts WHERE id = t_get('gr3')));
SELECT t_check('T35w non-TRY draft keeps the supplied rate',
  (SELECT invoice_currency = 'GBP' AND exchange_rate = 42.5 FROM goods_receipts WHERE id = t_get('gr5')));
SELECT t_check('T35x optional fields stored verbatim',
  (SELECT document_ref = 'FTR-99' AND note = 'manager notu' FROM goods_receipts WHERE id = t_get('gr4')));
SELECT t_check('T35y rpc exposes no status/business_id parameter',
  (SELECT pg_get_function_arguments(oid) !~ 'status' AND pg_get_function_arguments(oid) !~ 'business_id'
   FROM pg_proc WHERE proname = 'rpc_create_goods_receipt'));
SELECT t_check('T35z execute granted to authenticated only',
  (SELECT has_function_privilege('authenticated', oid, 'EXECUTE')
      AND NOT has_function_privilege('anon', oid, 'EXECUTE')
   FROM pg_proc WHERE proname = 'rpc_create_goods_receipt'));

-- the created draft must flow through the UNCHANGED posting RPC
SELECT t_login('u4');
SELECT t_ok ('T35aa00 stock_staff records the quantity on the rpc-created draft', $q$ SELECT rpc_goods_receipt_upsert_line(t_get('gr3'), t_get('v1'), 4) $q$);
SELECT t_logout();
SELECT t_login('u2');
SELECT t_ok ('T35aa01 manager prices it', $q$ SELECT rpc_goods_receipt_upsert_line(t_get('gr3'), t_get('v1'), 4, 120) $q$);
SELECT t_ok ('T35aa0 rpc-created draft reviews', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr3')) $q$);
SELECT t_ok ('T35aa rpc-created draft posts via existing rpc_post_goods_receipt', $q$ SELECT rpc_post_goods_receipt(t_get('gr3')) $q$);
SELECT t_err('T35ab second post of the same receipt rejected', $q$ SELECT rpc_post_goods_receipt(t_get('gr3')) $q$, 'INVALID_STATE');
SELECT t_err('T35ac empty rpc-created draft cannot be reviewed', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr6')) $q$, 'EMPTY_DOCUMENT');
SELECT t_err('T35ac2 …nor posted', $q$ SELECT rpc_post_goods_receipt(t_get('gr6')) $q$, 'NOT_REVIEWED');
SELECT t_logout();
SELECT t_check('T35ad posting produced a sellable ledger row for the new receipt',
  t_count($q$ SELECT count(*) FROM inventory_movements m JOIN goods_receipt_items i ON i.id = m.reference_id
              WHERE i.goods_receipt_id = t_get('gr3') AND m.bucket = 'sellable' AND m.quantity = 4 $q$) = 1);
SELECT t_check('T35ae posting produced exactly one supplier liability entry',
  t_count($q$ SELECT count(*) FROM supplier_account_entries WHERE reference_type = 'goods_receipt' AND reference_id = t_get('gr3') AND entry_type = 'liability' $q$) = 1);

-- ============================================================
-- T36  business lifecycle enforcement  (Phase 3.5A)
-- ============================================================
SELECT t_check('T36a fn_is_business_active true for active TLC', (SELECT fn_is_business_active(t_get('biz'))));
SELECT t_check('T36b fn_is_business_active callable by authenticated (policies need it)',
  has_function_privilege('authenticated', 'fn_is_business_active(uuid)', 'EXECUTE'));
SELECT t_check('T36c fn_require_active_business stays internal',
  NOT has_function_privilege('authenticated', 'fn_require_active_business(uuid)', 'EXECUTE'));

-- structural: an omitted policy is a silent hole, so completeness is asserted, not assumed
SELECT t_check('T36d every business-scoped write policy enforces lifecycle',
  (SELECT count(*) FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.cmd IN ('ALL','INSERT','UPDATE','DELETE')
      AND p.tablename <> 'businesses'
      AND EXISTS (SELECT 1 FROM information_schema.columns c
                  WHERE c.table_schema = 'public' AND c.table_name = p.tablename AND c.column_name = 'business_id')
      AND COALESCE(p.qual,'') || COALESCE(p.with_check,'') NOT LIKE '%fn_is_business_active%') = 0,
  (SELECT COALESCE(string_agg(p.policyname, ', '), 'none') FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.cmd IN ('ALL','INSERT','UPDATE','DELETE')
      AND p.tablename <> 'businesses'
      AND EXISTS (SELECT 1 FROM information_schema.columns c
                  WHERE c.table_schema = 'public' AND c.table_name = p.tablename AND c.column_name = 'business_id')
      AND COALESCE(p.qual,'') || COALESCE(p.with_check,'') NOT LIKE '%fn_is_business_active%'));
-- businesses is exempt from the lifecycle rule on purpose: the owner keeps editing name,
-- address, phone, email, logo and settings. The one field that must not move -- status --
-- is taken away from them by the 3.5G trigger, not by this policy.
SELECT t_check('T36e businesses UPDATE stays exempt from the lifecycle rule (metadata edits)',
  (SELECT COALESCE(qual,'') NOT LIKE '%fn_is_business_active%' FROM pg_policies WHERE policyname = 'pol_businesses_update'));
SELECT t_check('T36f no SELECT policy was narrowed by the lifecycle rule',
  (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND cmd = 'SELECT'
     AND COALESCE(qual,'') LIKE '%fn_is_business_active%') = 0);

-- fixture: tenant B needs a supplier so the receipt RPC gets past its own lookups
WITH x AS (INSERT INTO suppliers (business_id, name, currency) VALUES (t_get('bizB'), 'B Supplier', 'TRY') RETURNING id)
SELECT t_set('supB', id) FROM x;
WITH x AS (INSERT INTO cash_registers (business_id, branch_id, name) VALUES (t_get('bizB'), t_get('brB'), 'B Kasa') RETURNING id)
SELECT t_set('regB', id) FROM x;

-- ---------------- suspended ----------------
UPDATE businesses SET status = 'suspended' WHERE id = t_get('bizB');
SELECT t_login('u5');
SELECT t_check('T36g suspended tenant still SELECTs its own history',
  t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('bizB') $q$) = 1);
SELECT t_check('T36h suspended tenant still SELECTs its own business row',
  t_count($q$ SELECT count(*) FROM businesses WHERE id = t_get('bizB') $q$) = 1);
SELECT t_err('T36i suspended tenant cannot INSERT a product',
  $q$ INSERT INTO products (business_id, name, sku_prefix, default_sale_price) VALUES (t_get('bizB'), 'blocked', 'BLK-1', 1) $q$, '42501');
SELECT t_check('T36j suspended tenant UPDATE is filtered to 0 rows',
  t_count($q$ WITH u AS (UPDATE products SET name = 'x' WHERE business_id = t_get('bizB') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_err('T36k suspended tenant cannot INSERT a supplier',
  $q$ INSERT INTO suppliers (business_id, name) VALUES (t_get('bizB'), 'blocked') $q$, '42501');
SELECT t_err('T36l suspended tenant blocked in rpc_create_goods_receipt',
  $q$ SELECT rpc_create_goods_receipt(t_get('brB'), t_get('supB')) $q$, 'BUSINESS_SUSPENDED');
SELECT t_err('T36m suspended tenant blocked in rpc_process_sale',
  $q$ SELECT rpc_process_sale(t_get('bizB'), t_get('brB'), gen_random_uuid(), '[]'::jsonb, '[]'::jsonb) $q$, 'BUSINESS_SUSPENDED');
SELECT t_err('T36n suspended tenant blocked in rpc_set_fx_rate',
  $q$ SELECT rpc_set_fx_rate(t_get('bizB'), 'GBP', 40) $q$, 'BUSINESS_SUSPENDED');
SELECT t_err('T36o suspended tenant blocked in rpc_open_register_session',
  $q$ SELECT rpc_open_register_session(t_get('regB')) $q$, 'BUSINESS_SUSPENDED');
SELECT t_logout();

-- ---------------- cancelled behaves the same ----------------
UPDATE businesses SET status = 'cancelled' WHERE id = t_get('bizB');
SELECT t_login('u5');
SELECT t_check('T36p cancelled tenant still SELECTs its own history',
  t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('bizB') $q$) = 1);
SELECT t_err('T36q cancelled tenant cannot INSERT a product',
  $q$ INSERT INTO products (business_id, name, sku_prefix, default_sale_price) VALUES (t_get('bizB'), 'blocked', 'BLK-2', 1) $q$, '42501');
SELECT t_err('T36r cancelled tenant blocked in RPC',
  $q$ SELECT rpc_create_goods_receipt(t_get('brB'), t_get('supB')) $q$, 'BUSINESS_SUSPENDED');

-- ---------------- reactivation is NOT a tenant privilege (3.5G) ----------------
SELECT t_err('T36s owner of a cancelled tenant cannot reactivate it themselves',
  $q$ UPDATE businesses SET status = 'active' WHERE id = t_get('bizB') $q$, 'PLATFORM_MANAGED_FIELD');
SELECT t_logout();
-- brought back through the break-glass maintenance path (postgres, no marker).
-- The audited platform RPC path is exercised in T41 and T43.
UPDATE businesses SET status = 'active' WHERE id = t_get('bizB');
SELECT t_login('u5');
SELECT t_ok('T36t writes work again after reactivation',
  $q$ INSERT INTO products (business_id, name, sku_prefix, default_sale_price) VALUES (t_get('bizB'), 'after', 'AFT-1', 1) $q$);
SELECT t_ok('T36u RPC works again after reactivation',
  $q$ SELECT rpc_create_goods_receipt(t_get('brB'), t_get('supB')) $q$);
SELECT t_logout();

-- ---------------- the active tenant is untouched ----------------
SELECT t_login('u1');
SELECT t_ok('T36v active tenant owner still writes master data',
  $q$ INSERT INTO brands (business_id, name) VALUES (t_get('biz'), 'Lifecycle Test Brand') $q$);
SELECT t_logout();
SELECT t_login('u4');
SELECT t_ok('T36w active tenant stock_staff still creates a draft receipt',
  $q$ SELECT rpc_create_goods_receipt(t_get('br1'), t_get('sup1')) $q$);
SELECT t_logout();

-- ============================================================
-- T37  last owner protection  (Phase 3.5B)
-- ============================================================
-- The rule is a DEFERRED constraint trigger, so it only fires at COMMIT. This whole
-- file is one transaction that ends in ROLLBACK, so the check has to be forced with
-- SET CONSTRAINTS ALL IMMEDIATE inside a subtransaction.
CREATE FUNCTION t_err_deferred(name TEXT, sql TEXT, expect TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE sql;
    SET CONSTRAINTS ALL IMMEDIATE;
    PERFORM t_res(name, false, 'expected error ' || expect || ' but succeeded');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = expect OR SQLERRM LIKE '%' || expect || '%' THEN PERFORM t_res(name, true, expect);
    ELSE PERFORM t_res(name, false, 'expected ' || expect || ' got ' || SQLSTATE || ' ' || SQLERRM); END IF;
  END;
  SET CONSTRAINTS ALL DEFERRED;
END $$;

CREATE FUNCTION t_ok_deferred(name TEXT, sql TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE sql;
    SET CONSTRAINTS ALL IMMEDIATE;
    PERFORM t_res(name, true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM t_res(name, false, SQLSTATE || ' ' || SQLERRM);
  END;
  SET CONSTRAINTS ALL DEFERRED;
END $$;

SELECT t_check('T37a last-owner rule is a deferred constraint trigger',
  (SELECT tgconstraint <> 0 AND tgdeferrable AND tginitdeferred
   FROM pg_trigger WHERE tgname = 'trg_bm_last_owner'));
SELECT t_check('T37b trigger fires on UPDATE and DELETE only',
  (SELECT (tgtype & 4) = 0 AND (tgtype & 8) > 0 AND (tgtype & 16) > 0
   FROM pg_trigger WHERE tgname = 'trg_bm_last_owner'));
SELECT t_check('T37c fn_assert_last_owner stays internal',
  NOT has_function_privilege('authenticated', 'fn_assert_last_owner()', 'EXECUTE'));

-- TLC has exactly one owner (u1) at this point; so does tenant B (u5).
SELECT t_check('T37d TLC starts with exactly one active owner',
  (SELECT count(*) FROM business_members WHERE business_id = t_get('biz') AND role = 'owner' AND is_active) = 1);

-- ---------------- the invariant holds for an RLS-bypassing writer (postgres) ----------------
SELECT t_err_deferred('T37e postgres cannot demote the only owner',
  $q$ UPDATE business_members SET role = 'sales_staff' WHERE business_id = t_get('biz') AND user_id = t_get('u1') $q$, 'LAST_OWNER');
SELECT t_err_deferred('T37f postgres cannot deactivate the only owner',
  $q$ UPDATE business_members SET is_active = false WHERE business_id = t_get('biz') AND user_id = t_get('u1') $q$, 'LAST_OWNER');
SELECT t_err_deferred('T37g postgres cannot delete the only owner membership',
  $q$ DELETE FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u1') $q$, 'LAST_OWNER');
SELECT t_err_deferred('T37h the rule applies to tenant B as well',
  $q$ DELETE FROM business_members WHERE business_id = t_get('bizB') AND user_id = t_get('u5') $q$, 'LAST_OWNER');

-- ---------------- and for the owner acting through RLS ----------------
SELECT t_login('u1');
SELECT t_err_deferred('T37i owner cannot demote themselves through RLS',
  $q$ UPDATE business_members SET role = 'sales_staff' WHERE business_id = t_get('biz') AND user_id = t_get('u1') $q$, 'LAST_OWNER');
SELECT t_err_deferred('T37j owner cannot deactivate themselves through RLS',
  $q$ UPDATE business_members SET is_active = false WHERE business_id = t_get('biz') AND user_id = t_get('u1') $q$, 'LAST_OWNER');
SELECT t_logout();

-- ---------------- with a second owner the first one is free to go ----------------
SELECT t_ok_deferred('T37k a second owner can be promoted',
  $q$ UPDATE business_members SET role = 'owner' WHERE business_id = t_get('biz') AND user_id = t_get('u2') $q$);
SELECT t_ok_deferred('T37l with two owners the first can be demoted',
  $q$ UPDATE business_members SET role = 'sales_staff' WHERE business_id = t_get('biz') AND user_id = t_get('u1') $q$);
SELECT t_check('T37m TLC still has one active owner after the demotion',
  (SELECT count(*) FROM business_members WHERE business_id = t_get('biz') AND role = 'owner' AND is_active) = 1);

-- restore u1=owner, u2=manager (deferred, so the intermediate zero-owner state is fine)
UPDATE business_members SET role = 'owner'   WHERE business_id = t_get('biz') AND user_id = t_get('u1');
UPDATE business_members SET role = 'manager' WHERE business_id = t_get('biz') AND user_id = t_get('u2');

-- ---------------- the point of DEFERRED: demote first, promote second ----------------
DO $$
BEGIN
  BEGIN
    -- after this statement the business has zero active owners; an IMMEDIATE trigger
    -- would already have rejected it
    UPDATE business_members SET role = 'sales_staff' WHERE business_id = t_get('biz') AND user_id = t_get('u1');
    UPDATE business_members SET role = 'owner'       WHERE business_id = t_get('biz') AND user_id = t_get('u2');
    SET CONSTRAINTS ALL IMMEDIATE;
    PERFORM t_res('T37n demote-then-promote ownership transfer allowed in one transaction', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM t_res('T37n demote-then-promote ownership transfer allowed in one transaction', false, SQLSTATE || ' ' || SQLERRM);
  END;
  SET CONSTRAINTS ALL DEFERRED;
END $$;

-- restore again
UPDATE business_members SET role = 'owner'   WHERE business_id = t_get('biz') AND user_id = t_get('u1');
UPDATE business_members SET role = 'manager' WHERE business_id = t_get('biz') AND user_id = t_get('u2');

-- ---------------- an inactive owner does not count as an owner ----------------
SELECT t_err_deferred('T37o an inactive owner does not satisfy the invariant',
  $q$ UPDATE business_members SET is_active = false WHERE business_id = t_get('biz') AND user_id = t_get('u1') $q$, 'LAST_OWNER');

-- ---------------- a tenant that has no owner YET must stay editable ----------------
-- This is the onboarding shape (the pilot seed creates the business and no members) and
-- also the shape the concurrency fixture builds. The rule guards the transition that
-- removes the last owner, not the mere absence of one.
SELECT t_set('bizC', 'b0000000-0000-4000-8000-0000000000c3');
INSERT INTO businesses (id, name, code, settings) VALUES (t_get('bizC'), 'Onboarding Boutique', 'ONB', '{}'::jsonb);
SELECT t_set('u9', 'aaaaaaaa-0000-4000-8000-000000000009');
INSERT INTO auth.users (id, instance_id, aud, role, email)
VALUES (t_get('u9'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'onboarding@tlc.test')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES (t_get('u9')) ON CONFLICT DO NOTHING;
INSERT INTO business_members (business_id, user_id, role) VALUES (t_get('bizC'), t_get('u9'), 'sales_staff');
SELECT t_check('T37q the new business has no active owner',
  (SELECT count(*) FROM business_members WHERE business_id = t_get('bizC') AND role = 'owner' AND is_active) = 0);
SELECT t_ok_deferred('T37r a member of an ownerless business can still be edited',
  $q$ UPDATE business_members SET role = 'stock_staff' WHERE business_id = t_get('bizC') AND user_id = t_get('u9') $q$);
SELECT t_ok_deferred('T37s a member of an ownerless business can still be removed',
  $q$ DELETE FROM business_members WHERE business_id = t_get('bizC') AND user_id = t_get('u9') $q$);
INSERT INTO business_members (business_id, user_id, role) VALUES (t_get('bizC'), t_get('u9'), 'owner');
SELECT t_err_deferred('T37t once the business has an owner the rule engages',
  $q$ DELETE FROM business_members WHERE business_id = t_get('bizC') AND user_id = t_get('u9') $q$, 'LAST_OWNER');
SELECT t_ok_deferred('T37u a non-owner row in a business WITH an owner is unaffected',
  $q$ UPDATE business_members SET max_discount_pct = 5 WHERE business_id = t_get('biz') AND user_id = t_get('u3') $q$);

SELECT t_check('T37p fixture restored: u1 owner, u2 manager, both active',
  (SELECT count(*) FROM business_members
    WHERE business_id = t_get('biz')
      AND ((user_id = t_get('u1') AND role = 'owner'   AND is_active)
        OR (user_id = t_get('u2') AND role = 'manager' AND is_active))) = 2);

-- ============================================================
-- T38  business_members read minimisation  (Phase 3.5C)
-- ============================================================
-- give the sales_staff row a discount ceiling so "can a colleague read it" is a real question
UPDATE business_members SET max_discount_pct = 15 WHERE business_id = t_get('biz') AND user_id = t_get('u3');
UPDATE business_members SET max_discount_pct = 40 WHERE business_id = t_get('biz') AND user_id = t_get('u2');

SELECT t_check('T38a TLC has four members in total',
  (SELECT count(*) FROM business_members WHERE business_id = t_get('biz')) = 4);

-- ---------------- sales_staff ----------------
SELECT t_login('u3');
SELECT t_check('T38b sales_staff sees exactly one membership row',
  t_count($q$ SELECT count(*) FROM business_members $q$) = 1);
SELECT t_check('T38c the row sales_staff sees is their own',
  t_count($q$ SELECT count(*) FROM business_members WHERE user_id = t_get('u3') $q$) = 1);
SELECT t_check('T38d sales_staff cannot read a colleague''s role',
  t_count($q$ SELECT count(*) FROM business_members WHERE user_id = t_get('u2') $q$) = 0);
SELECT t_check('T38e sales_staff cannot read anyone else''s discount ceiling',
  t_count($q$ SELECT count(*) FROM business_members WHERE max_discount_pct = 40 $q$) = 0);
SELECT t_check('T38f sales_staff still reads their own discount ceiling',
  t_num($q$ SELECT max_discount_pct FROM business_members WHERE user_id = t_get('u3') $q$) = 15);
-- authorisation must not depend on what the client can SELECT
SELECT t_check('T38g fn_is_member still true for sales_staff', (SELECT fn_is_member(t_get('biz'))));
SELECT t_check('T38h fn_my_role still resolves for sales_staff', (SELECT fn_my_role(t_get('biz'))) = 'sales_staff');
SELECT t_check('T38i fn_is_manager_plus still false for sales_staff', NOT (SELECT fn_is_manager_plus(t_get('biz'))));
SELECT t_check('T38j fn_my_business_ids still returns the tenant', t_get('biz') = ANY(SELECT unnest(fn_my_business_ids())));
-- the tenant-resolution query the application actually runs
SELECT t_check('T38k tenant resolution query still returns the membership',
  t_count($q$ SELECT count(*) FROM business_members WHERE user_id = t_get('u3') AND is_active $q$) = 1);
-- reads that were already allowed stay allowed
SELECT t_check('T38l sales_staff still reads products', t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_logout();

-- ---------------- stock_staff ----------------
SELECT t_login('u4');
SELECT t_check('T38m stock_staff sees exactly one membership row',
  t_count($q$ SELECT count(*) FROM business_members $q$) = 1);
SELECT t_check('T38n stock_staff still passes the procurement helper', (SELECT fn_is_procurement(t_get('biz'))));
SELECT t_logout();

-- ---------------- manager / owner keep team visibility ----------------
SELECT t_login('u2');
SELECT t_check('T38o manager sees all four members',
  t_count($q$ SELECT count(*) FROM business_members WHERE business_id = t_get('biz') $q$) = 4);
SELECT t_check('T38p manager reads a subordinate discount ceiling',
  t_num($q$ SELECT max_discount_pct FROM business_members WHERE user_id = t_get('u3') $q$) = 15);
SELECT t_logout();
SELECT t_login('u1');
SELECT t_check('T38q owner sees all four members',
  t_count($q$ SELECT count(*) FROM business_members WHERE business_id = t_get('biz') $q$) = 4);
SELECT t_logout();

-- ---------------- cross-tenant is unchanged ----------------
SELECT t_login('u5');
SELECT t_check('T38r tenant B owner sees no TLC membership row',
  t_count($q$ SELECT count(*) FROM business_members WHERE business_id = t_get('biz') $q$) = 0);
SELECT t_check('T38s tenant B owner still sees their own membership',
  t_count($q$ SELECT count(*) FROM business_members WHERE business_id = t_get('bizB') $q$) = 1);
SELECT t_logout();

-- ---------------- an RPC that reads business_members internally still works ----------------
SELECT t_login('u4');
SELECT t_ok('T38t procurement RPC still resolves the caller''s membership',
  $q$ SELECT rpc_create_goods_receipt(t_get('br1'), t_get('sup1')) $q$);
SELECT t_logout();

-- ============================================================
-- T39  manager subordinate role management  (Phase 3.5D)
-- ============================================================
-- extra identities to be managed (u2 = manager with a 40% ceiling from T38)
SELECT t_set('u6', 'aaaaaaaa-0000-4000-8000-000000000006');
SELECT t_set('u7', 'aaaaaaaa-0000-4000-8000-000000000007');
INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
  (t_get('u6'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'new.sales@tlc.test'),
  (t_get('u7'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'new.stock@tlc.test')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) SELECT t_get(k) FROM unnest(ARRAY['u6','u7']) k ON CONFLICT DO NOTHING;

SELECT t_check('T39a fn_my_max_discount callable by authenticated (policy needs it)',
  has_function_privilege('authenticated', 'fn_my_max_discount(uuid)', 'EXECUTE'));

SELECT t_login('u2');
SELECT t_check('T39b manager ceiling is the one the owner configured',
  (SELECT fn_my_max_discount(t_get('biz'))) = 40);

-- ---------------- what a manager MAY do ----------------
SELECT t_ok('T39c manager creates a sales_staff member',
  $q$ INSERT INTO business_members (business_id, user_id, role) VALUES (t_get('biz'), t_get('u6'), 'sales_staff') $q$);
SELECT t_ok('T39d manager creates a stock_staff member',
  $q$ INSERT INTO business_members (business_id, user_id, role) VALUES (t_get('biz'), t_get('u7'), 'stock_staff') $q$);
SELECT t_ok('T39e manager grants a ceiling at their own limit',
  $q$ UPDATE business_members SET max_discount_pct = 40 WHERE business_id = t_get('biz') AND user_id = t_get('u6') $q$);
SELECT t_ok('T39f manager grants a ceiling below their own limit',
  $q$ UPDATE business_members SET max_discount_pct = 10 WHERE business_id = t_get('biz') AND user_id = t_get('u6') $q$);
SELECT t_ok('T39g manager moves a subordinate between the two junior roles',
  $q$ UPDATE business_members SET role = 'stock_staff' WHERE business_id = t_get('biz') AND user_id = t_get('u6') $q$);
SELECT t_ok('T39h manager deactivates a subordinate',
  $q$ UPDATE business_members SET is_active = false WHERE business_id = t_get('biz') AND user_id = t_get('u7') $q$);
SELECT t_ok('T39i manager removes a subordinate membership',
  $q$ DELETE FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u7') $q$);

-- ---------------- escalation attempts ----------------
SELECT t_err('T39j manager cannot create an owner',
  $q$ INSERT INTO business_members (business_id, user_id, role) VALUES (t_get('biz'), t_get('u7'), 'owner') $q$, '42501');
SELECT t_err('T39k manager cannot create another manager',
  $q$ INSERT INTO business_members (business_id, user_id, role) VALUES (t_get('biz'), t_get('u7'), 'manager') $q$, '42501');
SELECT t_err('T39l manager cannot promote a subordinate to manager',
  $q$ UPDATE business_members SET role = 'manager' WHERE business_id = t_get('biz') AND user_id = t_get('u6') $q$, '42501');
SELECT t_err('T39m manager cannot promote a subordinate to owner',
  $q$ UPDATE business_members SET role = 'owner' WHERE business_id = t_get('biz') AND user_id = t_get('u6') $q$, '42501');
SELECT t_check('T39n manager cannot edit the owner row (filtered to 0 rows)',
  t_count($q$ WITH u AS (UPDATE business_members SET is_active = false WHERE business_id = t_get('biz') AND user_id = t_get('u1') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_check('T39o manager cannot delete the owner row (filtered to 0 rows)',
  t_count($q$ WITH u AS (DELETE FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u1') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_check('T39p manager cannot change their own row (filtered to 0 rows)',
  t_count($q$ WITH u AS (UPDATE business_members SET max_discount_pct = 100 WHERE business_id = t_get('biz') AND user_id = t_get('u2') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_check('T39q manager cannot delete their own row (filtered to 0 rows)',
  t_count($q$ WITH u AS (DELETE FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u2') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_err('T39r manager cannot grant a ceiling above their own',
  $q$ UPDATE business_members SET max_discount_pct = 41 WHERE business_id = t_get('biz') AND user_id = t_get('u6') $q$, '42501');
SELECT t_err('T39s manager cannot create a subordinate with a ceiling above their own',
  $q$ INSERT INTO business_members (business_id, user_id, role, max_discount_pct) VALUES (t_get('biz'), t_get('u7'), 'sales_staff', 90) $q$, '42501');
SELECT t_err('T39t manager cannot add a member to another tenant',
  $q$ INSERT INTO business_members (business_id, user_id, role) VALUES (t_get('bizB'), t_get('u7'), 'sales_staff') $q$, '42501');
SELECT t_check('T39u the manager row still says manager with an unchanged ceiling',
  (SELECT role = 'manager' AND max_discount_pct = 40 FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u2')));
SELECT t_logout();

-- ---------------- sales_staff gets nothing ----------------
SELECT t_login('u3');
SELECT t_err('T39v sales_staff still cannot create a member',
  $q$ INSERT INTO business_members (business_id, user_id, role) VALUES (t_get('biz'), t_get('u7'), 'sales_staff') $q$, '42501');
SELECT t_check('T39w sales_staff cannot edit their own ceiling (filtered to 0 rows)',
  t_count($q$ WITH u AS (UPDATE business_members SET max_discount_pct = 99 WHERE user_id = t_get('u3') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_logout();

-- ---------------- the owner keeps full authority ----------------
SELECT t_login('u1');
SELECT t_ok('T39x owner creates a manager',
  $q$ INSERT INTO business_members (business_id, user_id, role) VALUES (t_get('biz'), t_get('u7'), 'manager') $q$);
SELECT t_ok('T39y owner sets any ceiling',
  $q$ UPDATE business_members SET max_discount_pct = 100 WHERE business_id = t_get('biz') AND user_id = t_get('u6') $q$);
SELECT t_ok('T39z owner removes the manager again',
  $q$ DELETE FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u7') $q$);
SELECT t_logout();

-- ---------------- 3.5B still binds the owner ----------------
SELECT t_err_deferred('T39aa last-owner rule still applies after 3.5D',
  $q$ DELETE FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u1') $q$, 'LAST_OWNER');

-- clean up the extra identity so later blocks see the original four members
DELETE FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u6');
SELECT t_check('T39ab TLC is back to its four original members',
  (SELECT count(*) FROM business_members WHERE business_id = t_get('biz')) = 4);

-- ============================================================
-- T40  sales visibility hardening  (Phase 3.5E)
-- ============================================================
-- Fixture recap: sale1/sale2/sale4/sale5/sale6 were sold by u3 (sales_staff),
-- sale3 by u2 (manager). sess1 was opened by u3. u4 (stock_staff) sold nothing.

-- ---------------- settings ----------------
SELECT t_check('T40a TLC carries an explicit sales_visibility_scope',
  (SELECT settings ->> 'sales_visibility_scope' FROM businesses WHERE id = t_get('biz')) = 'own');
SELECT t_check('T40b TLC carries the landed-cost allocation policy',
  (SELECT settings ->> 'default_charge_allocation_method' FROM businesses WHERE id = t_get('biz')) = 'invoice_value_proportional');
SELECT t_check('T40c the merge did not overwrite existing policy keys',
  (SELECT settings ->> 'money_refund_allowed' = 'false'
      AND settings ->> 'exchange_window_days' = '3'
      AND jsonb_array_length(settings -> 'accepted_currencies') = 4
   FROM businesses WHERE id = t_get('biz')));
-- tenant B is created by these fixtures, i.e. AFTER the 3.5E merge ran, so it has no
-- explicit key. That is the shape every business created from now on will have until
-- onboarding writes one, and it must still resolve to the tightest scope.
SELECT t_check('T40d a business created after the merge carries no explicit scope',
  (SELECT settings ? 'sales_visibility_scope' FROM businesses WHERE id = t_get('bizB')) = false);
SELECT t_check('T40d2 and still resolves fail-closed to own',
  (SELECT fn_sales_visibility_scope(t_get('bizB'))) = 'own');
SELECT t_check('T40e scope helper resolves the configured value',
  (SELECT fn_sales_visibility_scope(t_get('biz'))) = 'own');
SELECT t_check('T40f scope helper stays internal',
  NOT has_function_privilege('authenticated', 'fn_sales_visibility_scope(uuid)', 'EXECUTE'));
SELECT t_check('T40g fn_my_branch stays internal',
  NOT has_function_privilege('authenticated', 'fn_my_branch(uuid)', 'EXECUTE'));
SELECT t_check('T40h the sale predicate is callable by authenticated (policies need it)',
  has_function_privilege('authenticated', 'fn_can_see_sale(uuid,uuid,uuid)', 'EXECUTE'));

-- ---------------- scope = own ----------------
SELECT t_login('u2');
SELECT t_check('T40i manager sees every sale in the business',
  t_count($q$ SELECT count(*) FROM sales WHERE business_id = t_get('biz') $q$) >= 6);
SELECT t_logout();

SELECT t_login('u3');
SELECT t_check('T40j sales_staff sees their own sales',
  t_count($q$ SELECT count(*) FROM sales WHERE id = t_get('sale1') $q$) = 1);
SELECT t_check('T40k sales_staff does NOT see the manager''s sale',
  t_count($q$ SELECT count(*) FROM sales WHERE id = t_get('sale3') $q$) = 0);
SELECT t_check('T40l every sale sales_staff can see was sold by them',
  t_count($q$ SELECT count(*) FROM sales WHERE sold_by <> t_get('u3') $q$) = 0);
-- side doors
SELECT t_check('T40m sale_items of an invisible sale are hidden',
  t_count($q$ SELECT count(*) FROM sale_items WHERE sale_id = t_get('sale3') $q$) = 0);
SELECT t_check('T40n sale_items of their own sale stay visible',
  t_count($q$ SELECT count(*) FROM sale_items WHERE sale_id = t_get('sale1') $q$) >= 1);
SELECT t_check('T40o sale_payments of an invisible sale are hidden',
  t_count($q$ SELECT count(*) FROM sale_payments WHERE sale_id = t_get('sale3') $q$) = 0);
SELECT t_check('T40p sale_payments of their own sale stay visible',
  t_count($q$ SELECT count(*) FROM sale_payments WHERE sale_id = t_get('sale1') $q$) >= 1);
SELECT t_check('T40q no sale_item row leaks from a sale they cannot see',
  t_count($q$ SELECT count(*) FROM sale_items si WHERE NOT EXISTS (SELECT 1 FROM sales s WHERE s.id = si.sale_id) $q$) = 0);
SELECT t_check('T40r every visible return is theirs or belongs to a visible sale',
  t_count($q$ SELECT count(*) FROM returns r
             WHERE r.processed_by <> t_get('u3')
               AND NOT EXISTS (SELECT 1 FROM sales s WHERE s.id = r.original_sale_id) $q$) = 0);
SELECT t_check('T40s no return_item leaks from an invisible return',
  t_count($q$ SELECT count(*) FROM return_items ri WHERE NOT EXISTS (SELECT 1 FROM returns r WHERE r.id = ri.return_id) $q$) = 0);
-- cost protection is unchanged
SELECT t_check('T40t sale_item_costs still invisible to sales_staff', t_count($q$ SELECT count(*) FROM sale_item_costs $q$) = 0);
SELECT t_check('T40u sale_costs still invisible to sales_staff', t_count($q$ SELECT count(*) FROM sale_costs $q$) = 0);
SELECT t_check('T40v variant_cost_pools still invisible to sales_staff', t_count($q$ SELECT count(*) FROM variant_cost_pools $q$) = 0);
-- drawer reconciliation is the manager's: the cashier sees neither the closed drawer nor its cash (20260916170000)
SELECT t_check('T40w cashier does not see the manager''s closed drawer',
  t_count($q$ SELECT count(*) FROM register_sessions WHERE id = t_get('sess1') $q$) = 0);
SELECT t_check('T40x cashier does not see the cash movements of that drawer',
  t_count($q$ SELECT count(*) FROM cash_movements WHERE register_session_id = t_get('sess1') $q$) = 0);
SELECT t_logout();
SELECT t_login('u2');
SELECT t_check('T40x …the manager who opened it does', t_count($q$ SELECT count(*) FROM register_sessions WHERE id = t_get('sess1') $q$) = 1
  AND t_count($q$ SELECT count(*) FROM cash_movements WHERE register_session_id = t_get('sess1') $q$) > 0);
SELECT t_logout();

-- a member who sold nothing sees nothing
SELECT t_login('u4');
SELECT t_check('T40y stock_staff sees no sales at all', t_count($q$ SELECT count(*) FROM sales $q$) = 0);
SELECT t_check('T40z stock_staff sees no sale_items', t_count($q$ SELECT count(*) FROM sale_items $q$) = 0);
SELECT t_check('T40aa stock_staff sees no cash movements', t_count($q$ SELECT count(*) FROM cash_movements $q$) = 0);
SELECT t_check('T40ab stock_staff sees no register session they did not open',
  t_count($q$ SELECT count(*) FROM register_sessions $q$) = 0);
SELECT t_check('T40ac stock_staff still reads stock (unchanged)',
  t_count($q$ SELECT count(*) FROM inventory_movements $q$) > 0);
SELECT t_logout();

-- ---------------- scope = business ----------------
UPDATE businesses SET settings = settings || jsonb_build_object('sales_visibility_scope', 'business') WHERE id = t_get('biz');
SELECT t_login('u4');
SELECT t_check('T40ad scope=business lets any member see every sale',
  t_count($q$ SELECT count(*) FROM sales WHERE business_id = t_get('biz') $q$) >= 6);
SELECT t_check('T40ae scope=business does NOT open the cost tables',
  t_count($q$ SELECT count(*) FROM sale_item_costs $q$) = 0);
SELECT t_logout();

-- ---------------- scope = branch ----------------
UPDATE businesses SET settings = settings || jsonb_build_object('sales_visibility_scope', 'branch') WHERE id = t_get('biz');
SELECT t_login('u4');
SELECT t_check('T40af scope=branch with no pinned branch falls back to own (0 sales)',
  t_count($q$ SELECT count(*) FROM sales $q$) = 0);
SELECT t_logout();
UPDATE business_members SET branch_id = t_get('br1') WHERE business_id = t_get('biz') AND user_id = t_get('u4');
SELECT t_login('u4');
SELECT t_check('T40ag scope=branch with a pinned branch shows that branch''s sales',
  t_count($q$ SELECT count(*) FROM sales WHERE branch_id = t_get('br1') $q$) >= 6);
SELECT t_logout();
UPDATE business_members SET branch_id = t_get('br2') WHERE business_id = t_get('biz') AND user_id = t_get('u4');
SELECT t_login('u4');
SELECT t_check('T40ah scope=branch hides another branch''s sales',
  t_count($q$ SELECT count(*) FROM sales $q$) = 0);
SELECT t_logout();

-- ---------------- unknown value must not open anything ----------------
UPDATE businesses SET settings = settings || jsonb_build_object('sales_visibility_scope', 'everything') WHERE id = t_get('biz');
SELECT t_check('T40ai an unrecognised scope resolves to own',
  (SELECT fn_sales_visibility_scope(t_get('biz'))) = 'own');
SELECT t_login('u4');
SELECT t_check('T40aj an unrecognised scope shows no foreign sales', t_count($q$ SELECT count(*) FROM sales $q$) = 0);
SELECT t_logout();
UPDATE businesses SET settings = settings - 'sales_visibility_scope' WHERE id = t_get('biz');
SELECT t_check('T40ak a missing scope key resolves to own',
  (SELECT fn_sales_visibility_scope(t_get('biz'))) = 'own');

-- restore the pilot configuration
UPDATE businesses SET settings = settings || jsonb_build_object('sales_visibility_scope', 'own') WHERE id = t_get('biz');
UPDATE business_members SET branch_id = NULL WHERE business_id = t_get('biz') AND user_id = t_get('u4');
SELECT t_check('T40al pilot configuration restored to own',
  (SELECT settings ->> 'sales_visibility_scope' FROM businesses WHERE id = t_get('biz')) = 'own');

-- ---------------- cross-tenant is still absolute ----------------
SELECT t_login('u5');
SELECT t_check('T40am tenant B sees no TLC sale', t_count($q$ SELECT count(*) FROM sales WHERE business_id = t_get('biz') $q$) = 0);
SELECT t_check('T40an tenant B sees no TLC sale_item', t_count($q$ SELECT count(*) FROM sale_items $q$) = 0);
SELECT t_check('T40ao tenant B sees no TLC cash movement', t_count($q$ SELECT count(*) FROM cash_movements $q$) = 0);
SELECT t_logout();

-- ---------------- owner keeps everything ----------------
SELECT t_login('u1');
SELECT t_check('T40ap owner sees every sale', t_count($q$ SELECT count(*) FROM sales WHERE business_id = t_get('biz') $q$) >= 6);
SELECT t_check('T40aq owner sees the cost tables', t_count($q$ SELECT count(*) FROM sale_costs $q$) > 0);
SELECT t_logout();

-- ============================================================
-- T41  platform admin foundation  (Phase 3.5F)
-- ============================================================
SELECT t_check('T41a super_admin was NOT added to the tenant role enum',
  (SELECT count(*) FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'user_role' AND e.enumlabel = 'super_admin') = 0);
SELECT t_check('T41b user_role still has exactly the four tenant roles',
  (SELECT count(*) FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'user_role') = 4);
SELECT t_check('T41c platform tables have RLS enabled',
  (SELECT count(*) FROM pg_class WHERE relname IN ('platform_admins','platform_audit_log') AND relrowsecurity) = 2);
SELECT t_check('T41d platform tables have zero policies',
  (SELECT count(*) FROM pg_policies WHERE tablename IN ('platform_admins','platform_audit_log')) = 0);
SELECT t_check('T41e platform tables are not granted to authenticated',
  NOT has_table_privilege('authenticated', 'platform_admins', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'platform_audit_log', 'SELECT'));
-- fn_is_platform_admin became callable by authenticated in 3.5G: the status guard runs
-- SECURITY INVOKER and has to ask the question from the caller's side. It answers only
-- about the current user; the table behind it stays unreadable (T41e, T41q).
SELECT t_check('T41f the raising platform helper stays internal',
  NOT has_function_privilege('authenticated', 'fn_require_platform_admin()', 'EXECUTE'));
SELECT t_check('T41f2 fn_is_platform_admin is callable but tells a tenant only about itself',
  has_function_privilege('authenticated', 'fn_is_platform_admin()', 'EXECUTE'));
SELECT t_check('T41g the platform RPC is reachable by authenticated (it guards itself)',
  has_function_privilege('authenticated', 'rpc_platform_set_business_status(uuid,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_platform_set_business_status(uuid,text,text)', 'EXECUTE'));
-- the design rule: platform authority must not be an OR-branch in tenant RLS
SELECT t_check('T41h no tenant policy grants access via fn_is_platform_admin',
  (SELECT count(*) FROM pg_policies
    WHERE schemaname = 'public'
      AND COALESCE(qual,'') || COALESCE(with_check,'') LIKE '%platform_admin%') = 0);

-- ---------------- a tenant owner is not a platform admin ----------------
SELECT t_login('u1');
SELECT t_err('T41i owner cannot select platform_admins at all',
  $q$ SELECT count(*) FROM platform_admins $q$, '42501');
SELECT t_err('T41j owner cannot select platform_audit_log at all',
  $q$ SELECT count(*) FROM platform_audit_log $q$, '42501');
SELECT t_err('T41k owner cannot make themselves a platform admin',
  $q$ INSERT INTO platform_admins (user_id) VALUES (t_get('u1')) $q$, '42501');
SELECT t_err('T41l owner cannot call the platform RPC',
  $q$ SELECT rpc_platform_set_business_status(t_get('biz'), 'suspended') $q$, 'FORBIDDEN');
SELECT t_logout();

-- ---------------- an appointed platform admin, who belongs to no tenant ----------------
SELECT t_set('u8', 'aaaaaaaa-0000-4000-8000-000000000008');
INSERT INTO auth.users (id, instance_id, aud, role, email)
VALUES (t_get('u8'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'platform@boutiqueos.test')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES (t_get('u8')) ON CONFLICT DO NOTHING;
INSERT INTO platform_admins (user_id, note) VALUES (t_get('u8'), 'phase 3.5F test');

SELECT t_login('u8');
SELECT t_check('T41m the platform admin is a member of no business',
  t_count($q$ SELECT count(*) FROM business_members $q$) = 0);
SELECT t_check('T41n the platform admin gets no blanket read on tenant products',
  t_count($q$ SELECT count(*) FROM products $q$) = 0);
SELECT t_check('T41o the platform admin gets no blanket read on tenant sales',
  t_count($q$ SELECT count(*) FROM sales $q$) = 0);
SELECT t_check('T41p the platform admin cannot even read the businesses table directly',
  t_count($q$ SELECT count(*) FROM businesses $q$) = 0);
SELECT t_err('T41q the platform admin cannot read the audit log directly either',
  $q$ SELECT count(*) FROM platform_audit_log $q$, '42501');
SELECT t_err('T41r invalid status rejected',
  $q$ SELECT rpc_platform_set_business_status(t_get('bizB'), 'deleted') $q$, 'INVALID_STATUS');
SELECT t_err('T41s unknown business rejected',
  $q$ SELECT rpc_platform_set_business_status(gen_random_uuid(), 'suspended') $q$, 'NOT_FOUND');
SELECT t_ok('T41t the platform admin can suspend a tenant through the RPC',
  $q$ SELECT rpc_platform_set_business_status(t_get('bizB'), 'suspended', 'unpaid subscription') $q$);
SELECT t_logout();

SELECT t_check('T41u the tenant is now suspended',
  (SELECT status FROM businesses WHERE id = t_get('bizB')) = 'suspended');
SELECT t_check('T41v the operation was written to the audit log',
  (SELECT count(*) FROM platform_audit_log
    WHERE admin_user_id = t_get('u8') AND action = 'set_business_status'
      AND target_business_id = t_get('bizB')
      AND payload ->> 'from' = 'active' AND payload ->> 'to' = 'suspended'
      AND payload ->> 'reason' = 'unpaid subscription') = 1);

-- 3.5A and 3.5F meet here: a platform suspension really stops tenant writes
SELECT t_login('u5');
SELECT t_err('T41w platform-suspended tenant cannot write',
  $q$ INSERT INTO products (business_id, name, sku_prefix, default_sale_price) VALUES (t_get('bizB'), 'blocked', 'BLK-9', 1) $q$, '42501');
SELECT t_check('T41x platform-suspended tenant still reads its history',
  t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('bizB') $q$) > 0);
SELECT t_logout();

SELECT t_login('u8');
SELECT t_ok('T41y the platform admin can reactivate the tenant',
  $q$ SELECT rpc_platform_set_business_status(t_get('bizB'), 'active', 'payment received') $q$);
SELECT t_logout();
SELECT t_check('T41z the tenant is active again',
  (SELECT status FROM businesses WHERE id = t_get('bizB')) = 'active');
SELECT t_check('T41aa both operations are in the audit log',
  (SELECT count(*) FROM platform_audit_log WHERE admin_user_id = t_get('u8')) = 2);

-- a deactivated platform admin loses the authority
UPDATE platform_admins SET is_active = false WHERE user_id = t_get('u8');
SELECT t_login('u8');
SELECT t_err('T41ab a deactivated platform admin is rejected',
  $q$ SELECT rpc_platform_set_business_status(t_get('bizB'), 'suspended') $q$, 'FORBIDDEN');
SELECT t_logout();

-- ============================================================
-- T42  owner regression  (Phase 3.5, all sub-steps together)
-- ============================================================
-- Mirrors the reads the shipped application actually performs, table for table, so a
-- policy narrowed in 3.5A-F cannot break the pilot without failing here first.
-- lib/tenant.ts, lib/catalog/queries.ts, lib/receiving/queries.ts, lib/stock/queries.ts.

SELECT t_login('u1');

-- lib/tenant.ts :: loadMemberships
SELECT t_check('T42a tenant resolution: own membership row',
  t_count($q$ SELECT count(*) FROM business_members WHERE user_id = t_get('u1') AND is_active $q$) = 1);
SELECT t_check('T42b tenant resolution: active business row',
  t_count($q$ SELECT count(*) FROM businesses WHERE id = t_get('biz') AND status = 'active' $q$) = 1);
SELECT t_check('T42c tenant resolution: active branches',
  t_count($q$ SELECT count(*) FROM branches WHERE business_id = t_get('biz') AND status = 'active' $q$) >= 1);
SELECT t_check('T42d tenant resolution: own profile row',
  t_count($q$ SELECT count(*) FROM profiles WHERE id = t_get('u1') $q$) = 1);
SELECT t_check('T42e tenant resolution: business settings readable by the owner',
  t_count($q$ SELECT count(*) FROM businesses WHERE id = t_get('biz') AND settings ? 'sales_visibility_scope' $q$) = 1);

-- /app/urunler
SELECT t_check('T42f catalog: products', t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('biz') $q$) >= 2);
SELECT t_check('T42g catalog: variants', t_count($q$ SELECT count(*) FROM product_variants WHERE business_id = t_get('biz') $q$) >= 3);
SELECT t_check('T42h catalog: barcodes', t_count($q$ SELECT count(*) FROM barcodes WHERE business_id = t_get('biz') $q$) >= 0);
SELECT t_check('T42i catalog: brands', t_count($q$ SELECT count(*) FROM brands WHERE business_id = t_get('biz') $q$) >= 0);
SELECT t_check('T42j catalog: categories', t_count($q$ SELECT count(*) FROM categories WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_check('T42k catalog: options and values',
  t_count($q$ SELECT count(*) FROM product_options WHERE business_id = t_get('biz') $q$) > 0
  AND t_count($q$ SELECT count(*) FROM option_values WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_check('T42l catalog: variant option values',
  t_count($q$ SELECT count(*) FROM variant_option_values WHERE business_id = t_get('biz') $q$) > 0);

-- /app/tedarikciler
SELECT t_check('T42m suppliers list', t_count($q$ SELECT count(*) FROM suppliers WHERE business_id = t_get('biz') $q$) >= 2);

-- /app/mal-kabul
SELECT t_check('T42n goods receipts list', t_count($q$ SELECT count(*) FROM goods_receipts WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_check('T42o goods receipt lines', t_count($q$ SELECT count(*) FROM goods_receipt_items WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_check('T42p branches picker', t_count($q$ SELECT count(*) FROM branches WHERE business_id = t_get('biz') $q$) >= 1);

-- /app/stok
SELECT t_check('T42q stock by bucket view', t_count($q$ SELECT count(*) FROM v_stock_by_bucket WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_check('T42r stock available view', t_count($q$ SELECT count(*) FROM v_stock_available WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_check('T42s inventory movements', t_count($q$ SELECT count(*) FROM inventory_movements WHERE business_id = t_get('biz') $q$) > 0);

-- owner-only surfaces still open to the owner
SELECT t_check('T42t owner still reads cost pools', t_count($q$ SELECT count(*) FROM variant_cost_pools $q$) > 0);
SELECT t_check('T42u owner still reads the supplier ledger', t_count($q$ SELECT count(*) FROM supplier_account_entries $q$) > 0);
SELECT t_check('T42v owner still reads the team', t_count($q$ SELECT count(*) FROM business_members WHERE business_id = t_get('biz') $q$) = 4);

-- the owner can still write through the paths the app uses
SELECT t_ok('T42w owner creates a supplier',
  $q$ INSERT INTO suppliers (business_id, name) VALUES (t_get('biz'), 'Regression Supplier') $q$);
SELECT t_ok('T42x owner creates a draft goods receipt through the RPC',
  $q$ SELECT rpc_create_goods_receipt(t_get('br1'), t_get('sup1'), 'TRY', 1, CURRENT_DATE, 'REG-1', 'regression') $q$);
SELECT t_ok('T42y owner updates business settings',
  $q$ UPDATE businesses SET settings = settings || jsonb_build_object('sales_visibility_scope','own') WHERE id = t_get('biz') $q$);
SELECT t_logout();

-- the two staff roles the pilot will actually use
SELECT t_login('u4');
SELECT t_check('T42z stock_staff still reads the stock screen',
  t_count($q$ SELECT count(*) FROM v_stock_available WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_check('T42aa stock_staff still reads goods receipts',
  t_count($q$ SELECT count(*) FROM goods_receipts WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_check('T42ab stock_staff still reads suppliers',
  t_count($q$ SELECT count(*) FROM suppliers WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_logout();
SELECT t_login('u3');
SELECT t_check('T42ac sales_staff still reads the catalog',
  t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_check('T42ad sales_staff still reads stock quantities',
  t_count($q$ SELECT count(*) FROM v_stock_available WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_check('T42ae sales_staff still sees no supplier and no cost',
  t_count($q$ SELECT count(*) FROM suppliers $q$) = 0 AND t_count($q$ SELECT count(*) FROM variant_cost_pools $q$) = 0);
SELECT t_logout();

-- ============================================================
-- T43  businesses.status is platform controlled  (Phase 3.5G)
-- ============================================================
-- T41 left u8 deactivated; bring the platform admin back for these tests.
UPDATE platform_admins SET is_active = true WHERE user_id = t_get('u8');

SELECT t_check('T43a the guard is a BEFORE UPDATE row trigger on businesses',
  (SELECT pg_get_triggerdef(oid) LIKE '%BEFORE UPDATE OF status ON public.businesses%'
      AND pg_get_triggerdef(oid) LIKE '%FOR EACH ROW%'
   FROM pg_trigger WHERE tgname = 'trg_businesses_status_guard'),
  (SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgname = 'trg_businesses_status_guard'));
SELECT t_check('T43b exactly one status guard trigger exists',
  (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_businesses_status_guard') = 1);
SELECT t_check('T43c the guard function stays internal',
  NOT has_function_privilege('authenticated', 'fn_guard_business_status()', 'EXECUTE'));

-- ---------------- 1-3. the tenant owner cannot move status in any direction ----------------
SELECT t_check('T43d TLC starts active', (SELECT status FROM businesses WHERE id = t_get('biz')) = 'active');
SELECT t_login('u1');
SELECT t_err('T43e owner cannot suspend their own business',
  $q$ UPDATE businesses SET status = 'suspended' WHERE id = t_get('biz') $q$, 'PLATFORM_MANAGED_FIELD');
SELECT t_err('T43f owner cannot cancel their own business',
  $q$ UPDATE businesses SET status = 'cancelled' WHERE id = t_get('biz') $q$, 'PLATFORM_MANAGED_FIELD');
SELECT t_logout();
SELECT t_check('T43g TLC is still active after the refused attempts',
  (SELECT status FROM businesses WHERE id = t_get('biz')) = 'active');

-- put TLC into each non-active state through the maintenance path and try to escape
UPDATE businesses SET status = 'suspended' WHERE id = t_get('biz');
SELECT t_login('u1');
SELECT t_err('T43h owner cannot lift a suspension',
  $q$ UPDATE businesses SET status = 'active' WHERE id = t_get('biz') $q$, 'PLATFORM_MANAGED_FIELD');
SELECT t_logout();
UPDATE businesses SET status = 'cancelled' WHERE id = t_get('biz');
SELECT t_login('u1');
SELECT t_err('T43i owner cannot reverse a cancellation',
  $q$ UPDATE businesses SET status = 'active' WHERE id = t_get('biz') $q$, 'PLATFORM_MANAGED_FIELD');
SELECT t_logout();
UPDATE businesses SET status = 'active' WHERE id = t_get('biz');

-- ---------------- 4-5. tenant-owned fields stay editable ----------------
SELECT t_login('u1');
SELECT t_ok('T43j owner still edits business settings',
  $q$ UPDATE businesses SET settings = settings || jsonb_build_object('sales_visibility_scope','own') WHERE id = t_get('biz') $q$);
SELECT t_ok('T43k owner still edits business name and metadata',
  $q$ UPDATE businesses SET name = 'Things Like Crop', address = 'Lefkoşa, KKTC', phone = '+90 533 000 00 00', email = 'info@tlc.test' WHERE id = t_get('biz') $q$);
SELECT t_ok('T43l mentioning status without changing it is not a status change',
  $q$ UPDATE businesses SET status = status, name = 'Things Like Crop' WHERE id = t_get('biz') $q$);
SELECT t_check('T43m the metadata edit really landed',
  (SELECT phone = '+90 533 000 00 00' AND email = 'info@tlc.test' FROM businesses WHERE id = t_get('biz')));
SELECT t_logout();

-- ---------------- 6-7. manager and sales_staff have no path at all ----------------
SELECT t_login('u2');
SELECT t_check('T43n manager UPDATE on businesses is filtered to 0 rows',
  t_count($q$ WITH u AS (UPDATE businesses SET status = 'suspended' WHERE id = t_get('biz') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_logout();
SELECT t_login('u3');
SELECT t_check('T43o sales_staff UPDATE on businesses is filtered to 0 rows',
  t_count($q$ WITH u AS (UPDATE businesses SET status = 'suspended' WHERE id = t_get('biz') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_logout();
SELECT t_check('T43p TLC is still active after manager and sales_staff attempts',
  (SELECT status FROM businesses WHERE id = t_get('biz')) = 'active');

-- ---------------- 11. the marker alone is not authority ----------------
SELECT t_login('u1');
-- set_config is not a privileged operation, so the marker is forgeable by anyone. It is
-- only ever half of the platform path: the other half is being a platform admin.
SELECT set_config('boutiqueos.platform_status_change', t_get('biz')::text, false);
SELECT t_err('T43q owner cannot forge the platform marker to bypass the guard',
  $q$ UPDATE businesses SET status = 'suspended' WHERE id = t_get('biz') $q$, 'PLATFORM_MANAGED_FIELD');
SELECT set_config('boutiqueos.platform_status_change', '', false);
SELECT t_logout();
SELECT t_check('T43r TLC survived the forged-marker attempt',
  (SELECT status FROM businesses WHERE id = t_get('biz')) = 'active');

-- ---------------- 8-10. the audited platform path ----------------
SELECT t_check('T43s audit log baseline is two rows from T41',
  (SELECT count(*) FROM platform_audit_log) = 2);
SELECT t_login('u8');
SELECT t_ok('T43t platform admin suspends a tenant through the RPC',
  $q$ SELECT rpc_platform_set_business_status(t_get('biz'), 'suspended', 'subscription lapsed') $q$);
SELECT t_logout();
SELECT t_check('T43u the tenant is suspended', (SELECT status FROM businesses WHERE id = t_get('biz')) = 'suspended');
SELECT t_check('T43v the suspension was audited',
  (SELECT count(*) FROM platform_audit_log
    WHERE target_business_id = t_get('biz') AND payload ->> 'from' = 'active'
      AND payload ->> 'to' = 'suspended' AND payload ->> 'reason' = 'subscription lapsed') = 1);

-- and the owner still cannot undo it
SELECT t_login('u1');
SELECT t_err('T43w the suspended owner still cannot reactivate',
  $q$ UPDATE businesses SET status = 'active' WHERE id = t_get('biz') $q$, 'PLATFORM_MANAGED_FIELD');
SELECT t_logout();

SELECT t_login('u8');
SELECT t_ok('T43x platform admin reactivates the tenant through the RPC',
  $q$ SELECT rpc_platform_set_business_status(t_get('biz'), 'active', 'payment cleared') $q$);
SELECT t_logout();

-- The sharpest case for "the audit row cannot be skipped": someone wearing BOTH hats, so
-- RLS lets the UPDATE reach the row (they are the tenant owner) and the platform-admin
-- half of the guard is satisfied too. Only the missing RPC marker refuses them.
-- u8 alone could not prove this: not being a member of any business, RLS filters the row
-- out and the direct UPDATE touches 0 rows instead of being rejected.
INSERT INTO platform_admins (user_id, note) VALUES (t_get('u1'), 'dual-hat test')
ON CONFLICT (user_id) DO UPDATE SET is_active = true;
SELECT t_login('u1');
SELECT t_check('T43y the dual-hat user really is both owner and platform admin',
  (SELECT fn_is_platform_admin()) AND (SELECT fn_my_role(t_get('biz'))) = 'owner');
SELECT t_err('T43y2 owner+platform-admin still cannot change status outside the audited RPC',
  $q$ UPDATE businesses SET status = 'suspended' WHERE id = t_get('biz') $q$, 'PLATFORM_MANAGED_FIELD');
SELECT t_ok('T43y3 the same person succeeds through the RPC',
  $q$ SELECT rpc_platform_set_business_status(t_get('biz'), 'suspended', 'dual hat via rpc') $q$);
SELECT t_ok('T43y4 and brings it back the same way',
  $q$ SELECT rpc_platform_set_business_status(t_get('biz'), 'active', 'dual hat restore') $q$);
SELECT t_logout();
UPDATE platform_admins SET is_active = false WHERE user_id = t_get('u1');

SELECT t_check('T43z the tenant is active again', (SELECT status FROM businesses WHERE id = t_get('biz')) = 'active');
SELECT t_check('T43aa every RPC status change left an audit row (2 on tenant B in T41 + 4 on TLC here)',
  (SELECT count(*) FROM platform_audit_log WHERE action = 'set_business_status') = 6);
SELECT t_check('T43ab each RPC call on TLC produced exactly one audit row',
  (SELECT count(*) FROM platform_audit_log WHERE target_business_id = t_get('biz')) = 4);
SELECT t_check('T43ab2 the refused direct update wrote no audit row',
  (SELECT count(*) FROM platform_audit_log
    WHERE target_business_id = t_get('biz') AND payload ->> 'reason' IS NULL) = 0);

-- ---------------- the break-glass path is database-level only ----------------
SELECT set_config('boutiqueos.platform_status_change', '', false);
SELECT t_check('T43ac maintenance path works for postgres (bootstrap / recovery)',
  t_count($q$ WITH u AS (UPDATE businesses SET status = 'suspended' WHERE id = t_get('biz') RETURNING 1) SELECT count(*) FROM u $q$) = 1);
UPDATE businesses SET status = 'active' WHERE id = t_get('biz');
SELECT t_check('T43ad authenticated is neither superuser nor BYPASSRLS',
  (SELECT NOT (rolsuper OR rolbypassrls) FROM pg_roles WHERE rolname = 'authenticated'));
SELECT t_check('T43ae TLC left active for the remaining blocks',
  (SELECT status FROM businesses WHERE id = t_get('biz')) = 'active');

-- restore T41's fixture state
UPDATE platform_admins SET is_active = false WHERE user_id = t_get('u8');

-- ============================================================
-- T44-T48  Phase 4  Team & Identity
-- ============================================================
-- text-valued fixture store (invite tokens are text, _tk only holds uuids)
CREATE TABLE _tkt (k TEXT PRIMARY KEY, v TEXT);
CREATE FUNCTION t_sett(p_k TEXT, p_v TEXT) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN INSERT INTO _tkt (k, v) VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v; RETURN p_v; END $$;
CREATE FUNCTION t_gett(p_k TEXT) RETURNS TEXT LANGUAGE sql SECURITY DEFINER STABLE AS $$ SELECT v FROM _tkt WHERE _tkt.k = p_k $$;

-- ============================================================
-- T44  team audit log  (4A)
-- ============================================================
SELECT t_check('T44a team_audit_log has RLS and no write policy',
  (SELECT relrowsecurity FROM pg_class WHERE relname = 'team_audit_log')
  AND (SELECT count(*) FROM pg_policies WHERE tablename = 'team_audit_log' AND cmd <> 'SELECT') = 0);
SELECT t_check('T44b fn_team_audit stays internal',
  NOT has_function_privilege('authenticated', 'fn_team_audit(uuid,team_audit_action,uuid,uuid,jsonb,jsonb)', 'EXECUTE'));

-- single-field change -> specific action
SELECT t_login('u1');
UPDATE business_members SET max_discount_pct = 20 WHERE business_id = t_get('biz') AND user_id = t_get('u3');
SELECT t_logout();
SELECT t_check('T44c single-field change records the specific action',
  (SELECT count(*) FROM team_audit_log
    WHERE business_id = t_get('biz') AND target_user_id = t_get('u3')
      AND action = 'discount_limit_changed'
      AND old_values ->> 'max_discount_pct' = '15.00'
      AND new_values ->> 'max_discount_pct' = '20.00') = 1,
  'earlier blocks also move this ceiling, so the assertion names this exact transition');
-- occurred_at is now(), which is transaction-stable, so every row written by this test
-- file shares one timestamp. The row is named by its transition, not by ordering.
SELECT t_check('T44d the actor is the user who made the change',
  (SELECT actor_user_id FROM team_audit_log
    WHERE target_user_id = t_get('u3') AND action = 'discount_limit_changed'
      AND old_values ->> 'max_discount_pct' = '15.00'
      AND new_values ->> 'max_discount_pct' = '20.00') = t_get('u1'));

-- multi-field change in ONE statement -> one row, nothing lost
SELECT t_login('u1');
UPDATE business_members
SET role = 'stock_staff', branch_id = t_get('br1'), max_discount_pct = 5, is_active = false
WHERE business_id = t_get('biz') AND user_id = t_get('u3');
SELECT t_logout();
SELECT t_check('T44e a four-field update writes exactly one audit row',
  (SELECT count(*) FROM team_audit_log
    WHERE target_user_id = t_get('u3') AND action = 'member_updated') = 1);
SELECT t_check('T44f that row keeps every changed field on both sides',
  (SELECT old_values ?& ARRAY['role','branch_id','max_discount_pct','is_active']
      AND new_values ?& ARRAY['role','branch_id','max_discount_pct','is_active']
      AND old_values ->> 'role' = 'sales_staff' AND new_values ->> 'role' = 'stock_staff'
      AND old_values ->> 'is_active' = 'true'  AND new_values ->> 'is_active' = 'false'
      AND new_values ->> 'max_discount_pct' = '5.00'
   FROM team_audit_log WHERE target_user_id = t_get('u3') AND action = 'member_updated'));

-- restore u3 and check the reactivation verb
SELECT t_login('u1');
UPDATE business_members SET is_active = true WHERE business_id = t_get('biz') AND user_id = t_get('u3');
UPDATE business_members SET role = 'sales_staff', branch_id = NULL, max_discount_pct = 15
WHERE business_id = t_get('biz') AND user_id = t_get('u3');
SELECT t_logout();
SELECT t_check('T44g flipping is_active back records member_reactivated',
  (SELECT count(*) FROM team_audit_log
    WHERE target_user_id = t_get('u3') AND action = 'member_reactivated') = 1);
SELECT t_sett('u3_audit_before', (SELECT count(*)::text FROM team_audit_log WHERE target_user_id = t_get('u3')));
SELECT t_login('u1');
UPDATE business_members SET role = role, is_active = is_active WHERE business_id = t_get('biz') AND user_id = t_get('u3');
SELECT t_logout();
SELECT t_check('T44h2 an update that changes nothing adds no audit row',
  (SELECT count(*)::text FROM team_audit_log WHERE target_user_id = t_get('u3')) = t_gett('u3_audit_before'),
  (SELECT count(*)::text FROM team_audit_log WHERE target_user_id = t_get('u3')) || ' vs ' || t_gett('u3_audit_before'));

SELECT t_check('T44i no audit payload carries a secret-looking key',
  (SELECT count(*) FROM team_audit_log
    WHERE (old_values || new_values) ?| ARRAY['password','token','token_hash','encrypted_password']) = 0);

-- who may read it
SELECT t_login('u3');
SELECT t_check('T44j sales_staff cannot read the team audit log',
  t_count($q$ SELECT count(*) FROM team_audit_log $q$) = 0);
SELECT t_logout();
SELECT t_login('u4');
SELECT t_check('T44k stock_staff cannot read the team audit log',
  t_count($q$ SELECT count(*) FROM team_audit_log $q$) = 0);
SELECT t_logout();
SELECT t_login('u2');
SELECT t_check('T44l manager reads the team audit log',
  t_count($q$ SELECT count(*) FROM team_audit_log WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_logout();
SELECT t_login('u5');
SELECT t_check('T44m tenant B sees no TLC team audit row',
  t_count($q$ SELECT count(*) FROM team_audit_log WHERE business_id = t_get('biz') $q$) = 0);
SELECT t_logout();

-- ============================================================
-- T45  invitation creation  (4B)
-- ============================================================
SELECT t_check('T45a business_invites has RLS and no write policy',
  (SELECT relrowsecurity FROM pg_class WHERE relname = 'business_invites')
  AND (SELECT count(*) FROM pg_policies WHERE tablename = 'business_invites' AND cmd <> 'SELECT') = 0);
SELECT t_check('T45b invite_status has no stored expired value (expiry is derived)',
  (SELECT string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder) FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'invite_status') = 'pending,accepted,revoked');
-- there is no separate invite secret at all: the row id is the identifier and the
-- confirmed-address match is the authorisation
SELECT t_check('T45b2 business_invites stores no token or secret column',
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'business_invites'
      AND (column_name LIKE '%token%' OR column_name LIKE '%secret%' OR column_name LIKE '%hash%')) = 0,
  (SELECT COALESCE(string_agg(column_name, ', '), 'none') FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'business_invites'
      AND (column_name LIKE '%token%' OR column_name LIKE '%secret%' OR column_name LIKE '%hash%')));
SELECT t_check('T45b3 no invite token generator survives anywhere in the schema',
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN ('fn_new_invite_token','fn_invite_token_hash')) = 0);

-- explicit business context: a TLC manager may not invite into tenant B
SELECT t_login('u2');
SELECT t_err('T45c manager cannot invite into a business they do not belong to',
  $q$ SELECT rpc_create_invite(t_get('bizB'), 'x@tlc.test', 'X', 'sales_staff') $q$, 'FORBIDDEN');
SELECT t_err('T45d manager cannot create an owner invitation',
  $q$ SELECT rpc_create_invite(t_get('biz'), 'owner.try@tlc.test', 'X', 'owner') $q$, 'FORBIDDEN');
SELECT t_err('T45e manager cannot create a manager invitation',
  $q$ SELECT rpc_create_invite(t_get('biz'), 'mgr.try@tlc.test', 'X', 'manager') $q$, 'FORBIDDEN');
SELECT t_err('T45f manager cannot grant a ceiling above their own',
  $q$ SELECT rpc_create_invite(t_get('biz'), 'high@tlc.test', 'X', 'sales_staff', NULL, 41) $q$, 'FORBIDDEN');
SELECT t_err('T45g rejects a malformed address',
  $q$ SELECT rpc_create_invite(t_get('biz'), 'not-an-email', 'X', 'sales_staff') $q$, 'INVALID_EMAIL');
SELECT t_err('T45h rejects a branch from another tenant',
  $q$ SELECT rpc_create_invite(t_get('biz'), 'br@tlc.test', 'X', 'sales_staff', t_get('brB')) $q$, 'INVALID_BRANCH');
-- what the manager MAY do
SELECT t_set('inv_stock', rpc_create_invite(t_get('biz'), 'NEW.Stock@TLC.test', 'Yeni Depo', 'stock_staff', t_get('br1'), 0));
SELECT t_check('T45i manager creates a stock_staff invitation', t_get('inv_stock') IS NOT NULL);
SELECT t_check('T45j the address is normalised in the database',
  (SELECT count(*) FROM business_invites WHERE business_id = t_get('biz') AND email_normalized = 'new.stock@tlc.test') = 1);
SELECT t_err('T45k a second pending invitation for the same address is refused',
  $q$ SELECT rpc_create_invite(t_get('biz'), 'new.stock@tlc.test', 'X', 'sales_staff') $q$, 'INVITE_ALREADY_PENDING');
-- the delivery address is resolved by the database, never supplied by the client
SELECT t_check('T45k2 delivery target is server-resolved from the invitation row',
  (SELECT email FROM rpc_invite_delivery_target(t_get('inv_stock'))) = 'new.stock@tlc.test');
SELECT t_logout();

-- sales_staff has no invitation power at all
SELECT t_login('u3');
SELECT t_err('T45l sales_staff cannot invite',
  $q$ SELECT rpc_create_invite(t_get('biz'), 'nope@tlc.test', 'X', 'sales_staff') $q$, 'FORBIDDEN');
SELECT t_err('T45l2 sales_staff cannot resolve a delivery address',
  $q$ SELECT email FROM rpc_invite_delivery_target(t_get('inv_stock')) $q$, 'FORBIDDEN');
SELECT t_logout();

-- owner may invite every role
SELECT t_login('u1');
SELECT t_set('inv_sales', rpc_create_invite(t_get('biz'), 'new.sales@tlc.test', 'Yeni Satis', 'sales_staff', NULL, 10));
SELECT t_ok('T45m owner may create a manager invitation',
  $q$ SELECT rpc_create_invite(t_get('biz'), 'mgr@tlc.test', 'Yeni Yonetici', 'manager') $q$);
SELECT t_set('inv_owner', rpc_create_invite(t_get('biz'), 'owner2@tlc.test', 'Ikinci Sahip', 'owner'));
SELECT t_check('T45n owner may create an owner invitation', t_get('inv_owner') IS NOT NULL);
-- an invitation is never a second way onto an existing member
SELECT t_err('T45o inviting an active member is refused',
  $q$ SELECT rpc_create_invite(t_get('biz'), 'sales@tlc.test', 'X', 'owner') $q$, 'ALREADY_MEMBER');
SELECT t_logout();

-- a manager may not touch an invitation they could not have created
SELECT t_login('u2');
SELECT t_err('T45o2 manager cannot resolve the delivery address of an owner invitation',
  $q$ SELECT email FROM rpc_invite_delivery_target(t_get('inv_owner')) $q$, 'FORBIDDEN');
SELECT t_err('T45o3 manager cannot revoke an owner invitation',
  $q$ SELECT rpc_revoke_invite(t_get('inv_owner')) $q$, 'FORBIDDEN');
SELECT t_logout();

-- an inactive member must be reactivated, not re-invited
SELECT t_login('u1');
UPDATE business_members SET is_active = false WHERE business_id = t_get('biz') AND user_id = t_get('u4');
SELECT t_err('T45p inviting an inactive member points to reactivation',
  $q$ SELECT rpc_create_invite(t_get('biz'), 'stock@tlc.test', 'X', 'stock_staff') $q$, 'MEMBER_INACTIVE_USE_REACTIVATE');
UPDATE business_members SET is_active = true WHERE business_id = t_get('biz') AND user_id = t_get('u4');
SELECT t_logout();

-- the same address may be invited by a different tenant at the same time
SELECT t_login('u5');
SELECT t_set('inv_b_stock', rpc_create_invite(t_get('bizB'), 'new.stock@tlc.test', 'X', 'sales_staff'));
SELECT t_check('T45q another tenant may invite the same address', t_get('inv_b_stock') IS NOT NULL);
SELECT t_logout();

-- a suspended tenant cannot invite
UPDATE businesses SET status = 'suspended' WHERE id = t_get('bizC');
SELECT t_login('u9');
SELECT t_err('T45r a suspended tenant cannot invite',
  $q$ SELECT rpc_create_invite(t_get('bizC'), 'x@onb.test', 'X', 'sales_staff') $q$, 'BUSINESS_SUSPENDED');
SELECT t_logout();
UPDATE businesses SET status = 'active' WHERE id = t_get('bizC');

-- nothing about the invitation leaks into the Auth account's metadata
SELECT t_check('T45s no invite secret reaches auth user metadata',
  (SELECT count(*) FROM auth.users
    WHERE raw_user_meta_data::text ILIKE '%invite%' OR raw_app_meta_data::text ILIKE '%invite%') = 0);
SELECT t_check('T45s2 no invitation id was copied into auth user metadata',
  (SELECT count(*) FROM auth.users u JOIN business_invites i ON true
    WHERE u.raw_user_meta_data::text LIKE '%' || i.id::text || '%') = 0);
SELECT t_check('T45t creating an invitation writes an audit row without the address',
  (SELECT count(*) FROM team_audit_log
    WHERE action = 'invite_created' AND target_invite_id = t_get('inv_sales')
      AND NOT ((old_values || new_values) ?| ARRAY['email','email_normalized','token'])) = 1);

-- ============================================================
-- T46  invitation acceptance  (4B)
-- ============================================================
-- u6 is new.sales@tlc.test and is not a member of TLC
SELECT t_check('T46a the invited person is not a member yet',
  (SELECT count(*) FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u6')) = 0);

-- knowing the id is not enough: the confirmed address has to match
SELECT t_login('u7');
SELECT t_err('T46b the invitation id alone does not let another account claim it',
  $q$ SELECT * FROM rpc_accept_invite(t_get('inv_sales')) $q$, 'INVITE_EMAIL_MISMATCH');
SELECT t_logout();

SELECT t_login('u6');
SELECT t_err('T46c an unknown invitation id is rejected',
  $q$ SELECT * FROM rpc_accept_invite(gen_random_uuid()) $q$, 'INVITE_NOT_FOUND');
SELECT t_check('T46d the right person accepts',
  (SELECT already_member FROM rpc_accept_invite(t_get('inv_sales'))) = false);
SELECT t_logout();
SELECT t_check('T46e membership was created from the invitation, not from the client',
  (SELECT role = 'sales_staff' AND max_discount_pct = 10 AND is_active
   FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u6')));
SELECT t_check('T46f the invitation is now accepted and attributed',
  (SELECT status = 'accepted' AND accepted_by = t_get('u6') AND accepted_at IS NOT NULL
   FROM business_invites WHERE id = t_get('inv_sales')));
SELECT t_check('T46g a blank display name was filled from the invitation',
  (SELECT full_name FROM profiles WHERE id = t_get('u6')) = 'Yeni Satis');
SELECT t_check('T46h acceptance was audited',
  (SELECT count(*) FROM team_audit_log WHERE action = 'invite_accepted' AND target_invite_id = t_get('inv_sales')) = 1);

-- true idempotency: the same link, the same person, twice
SELECT t_login('u6');
SELECT t_check('T46i opening the same link again succeeds as a no-op',
  (SELECT already_member FROM rpc_accept_invite(t_get('inv_sales'))) = true);
SELECT t_logout();
SELECT t_check('T46j and produces no second membership',
  (SELECT count(*) FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u6')) = 1);
SELECT t_check('T46k and no second acceptance audit row',
  (SELECT count(*) FROM team_audit_log WHERE action = 'invite_accepted' AND target_invite_id = t_get('inv_sales')) = 1);

-- somebody else cannot reuse an accepted invitation
SELECT t_login('u7');
SELECT t_err('T46l a different person cannot reuse an accepted invitation',
  $q$ SELECT * FROM rpc_accept_invite(t_get('inv_sales')) $q$, 'INVITE_EMAIL_MISMATCH');
SELECT t_logout();

-- revoked
SELECT t_login('u2');
SELECT t_ok('T46m manager revokes the invitation they created',
  $q$ SELECT rpc_revoke_invite(t_get('inv_stock')) $q$);
SELECT t_logout();
SELECT t_login('u7');
SELECT t_err('T46n a revoked invitation cannot be accepted',
  $q$ SELECT * FROM rpc_accept_invite(t_get('inv_stock')) $q$, 'INVITE_REVOKED');
SELECT t_logout();

-- expired
SELECT t_login('u1');
SELECT t_set('inv_exp', rpc_create_invite(t_get('biz'), 'expired@tlc.test', 'Suresi Dolan', 'sales_staff'));
SELECT t_logout();
UPDATE business_invites SET expires_at = now() - interval '1 day' WHERE id = t_get('inv_exp');
SELECT t_check('T46o an out-of-date pending invitation reads as expired',
  (SELECT fn_invite_effective_status(status, expires_at) FROM business_invites WHERE id = t_get('inv_exp')) = 'expired');
SELECT t_check('T46p but is still stored as pending (no scheduler needed)',
  (SELECT status FROM business_invites WHERE id = t_get('inv_exp')) = 'pending');

-- unconfirmed address cannot claim a seat
UPDATE auth.users SET email_confirmed_at = NULL WHERE id = t_get('u7');
SELECT t_login('u1');
SELECT t_set('inv_u7', rpc_create_invite(t_get('biz'), 'new.stock@tlc.test', 'Depo', 'stock_staff'));
SELECT t_logout();
SELECT t_login('u7');
SELECT t_err('T46q an unconfirmed address cannot accept',
  $q$ SELECT * FROM rpc_accept_invite(t_get('inv_u7')) $q$, 'EMAIL_NOT_CONFIRMED');
SELECT t_logout();
UPDATE auth.users SET email_confirmed_at = now() WHERE id = t_get('u7');

-- an existing Auth user joining a SECOND tenant
SELECT t_login('u5');
SELECT t_set('inv_second', rpc_create_invite(t_get('bizB'), 'new.sales@tlc.test', 'Ikinci Tenant', 'manager'));
SELECT t_logout();
SELECT t_login('u6');
SELECT t_check('T46r an existing account joins a second tenant',
  (SELECT business_id FROM rpc_accept_invite(t_get('inv_second'))) = t_get('bizB'));
SELECT t_logout();
SELECT t_check('T46s the person now holds two memberships',
  (SELECT count(*) FROM business_members WHERE user_id = t_get('u6')) = 2);
SELECT t_check('T46t the existing display name was not overwritten',
  (SELECT full_name FROM profiles WHERE id = t_get('u6')) = 'Yeni Satis');

-- accepting into a suspended tenant is refused
UPDATE businesses SET status = 'suspended' WHERE id = t_get('bizB');
SELECT t_login('u7');
SELECT t_err('T46u a suspended tenant cannot take on a new member',
  $q$ SELECT * FROM rpc_accept_invite(t_get('inv_b_stock')) $q$, 'BUSINESS_SUSPENDED');
SELECT t_logout();
UPDATE businesses SET status = 'active' WHERE id = t_get('bizB');
SELECT t_login('u7');
SELECT t_check('T46v and works once the tenant is active again',
  (SELECT business_id FROM rpc_accept_invite(t_get('inv_b_stock'))) = t_get('bizB'));
SELECT t_logout();

-- ============================================================
-- T47  deactivation removes access  (4A/3.5 interaction)
-- ============================================================
SELECT t_login('u6');
SELECT t_check('T47a the new member can read the catalogue',
  t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('biz') $q$) > 0);
SELECT t_logout();

SELECT t_login('u1');
UPDATE business_members SET is_active = false WHERE business_id = t_get('biz') AND user_id = t_get('u6');
SELECT t_logout();

SELECT t_login('u6');
SELECT t_check('T47b a deactivated member is no longer a member',
  NOT (SELECT fn_is_member(t_get('biz'))));
SELECT t_check('T47c a deactivated member reads no tenant data',
  t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('biz') $q$) = 0);
SELECT t_check('T47d and the tenant is gone from their business list',
  NOT (t_get('biz') = ANY(SELECT unnest(fn_my_business_ids()))));
SELECT t_err('T47e a deactivated member cannot use a tenant RPC',
  $q$ SELECT rpc_create_goods_receipt(t_get('br1'), t_get('sup1')) $q$, 'FORBIDDEN');
SELECT t_check('T47f but their other tenant still works',
  (SELECT fn_is_member(t_get('bizB'))));
SELECT t_logout();

SELECT t_login('u1');
UPDATE business_members SET is_active = true WHERE business_id = t_get('biz') AND user_id = t_get('u6');
SELECT t_logout();
SELECT t_login('u6');
SELECT t_check('T47g reactivation restores access', (SELECT fn_is_member(t_get('biz'))));
SELECT t_logout();

-- 3.5 invariants still hold after the Phase 4 trigger was added
SELECT t_err_deferred('T47h the last-owner rule still holds',
  $q$ DELETE FROM business_members WHERE business_id = t_get('biz') AND user_id = t_get('u1') $q$, 'LAST_OWNER');
SELECT t_login('u2');
SELECT t_check('T47i manager still cannot escalate themselves',
  t_count($q$ WITH u AS (UPDATE business_members SET role = 'owner' WHERE business_id = t_get('biz') AND user_id = t_get('u2') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_logout();

-- ============================================================
-- T48  team directory and manage-authority  (4C)
-- ============================================================
SELECT t_login('u1');
SELECT t_check('T48a owner reads the directory with addresses',
  t_count($q$ SELECT count(*) FROM rpc_list_team(t_get('biz')) WHERE email IS NOT NULL $q$) =
  t_count($q$ SELECT count(*) FROM business_members WHERE business_id = t_get('biz') $q$));
SELECT t_check('T48b the directory returns only this tenant',
  t_count($q$ SELECT count(*) FROM rpc_list_team(t_get('biz')) d
             WHERE NOT EXISTS (SELECT 1 FROM business_members m
                               WHERE m.business_id = t_get('biz') AND m.user_id = d.user_id) $q$) = 0);
SELECT t_check('T48c the caller is flagged in their own row',
  t_count($q$ SELECT count(*) FROM rpc_list_team(t_get('biz')) WHERE is_self $q$) = 1);
SELECT t_check('T48d the invitation list resolves derived status',
  t_count($q$ SELECT count(*) FROM rpc_list_invites(t_get('biz')) WHERE status = 'expired' $q$) = 1);
SELECT t_logout();

SELECT t_login('u2');
SELECT t_check('T48e manager reads the directory',
  t_count($q$ SELECT count(*) FROM rpc_list_team(t_get('biz')) $q$) > 0);
SELECT t_check('T48f manager sees an owner invitation but gets no actions on it',
  t_count($q$ SELECT count(*) FROM rpc_list_invites(t_get('biz')) WHERE role = 'owner' AND NOT can_manage $q$) = 1);
SELECT t_logout();

SELECT t_login('u3');
SELECT t_err('T48g sales_staff cannot read the team directory',
  $q$ SELECT count(*) FROM rpc_list_team(t_get('biz')) $q$, 'FORBIDDEN');
SELECT t_err('T48h sales_staff cannot read the invitation list',
  $q$ SELECT count(*) FROM rpc_list_invites(t_get('biz')) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u4');
SELECT t_err('T48i stock_staff cannot read the team directory',
  $q$ SELECT count(*) FROM rpc_list_team(t_get('biz')) $q$, 'FORBIDDEN');
SELECT t_logout();

SELECT t_login('u5');
SELECT t_err('T48j another tenant cannot read this directory',
  $q$ SELECT count(*) FROM rpc_list_team(t_get('biz')) $q$, 'FORBIDDEN');
SELECT t_logout();

-- manage authority (drives the password-reset action, not UI hiding)
SELECT t_login('u1');
SELECT t_check('T48k owner may act on a sales_staff member', (SELECT fn_can_manage_member(t_get('biz'), t_get('u3'))));
SELECT t_check('T48l owner may act on a manager', (SELECT fn_can_manage_member(t_get('biz'), t_get('u2'))));
SELECT t_check('T48m owner may not act on a non-member', NOT (SELECT fn_can_manage_member(t_get('biz'), t_get('u5'))));
SELECT t_check('T48n owner may not act across tenants', NOT (SELECT fn_can_manage_member(t_get('bizB'), t_get('u5'))));
SELECT t_logout();
SELECT t_login('u2');
SELECT t_check('T48o manager may act on a sales_staff member', (SELECT fn_can_manage_member(t_get('biz'), t_get('u3'))));
SELECT t_check('T48p manager may act on a stock_staff member', (SELECT fn_can_manage_member(t_get('biz'), t_get('u4'))));
SELECT t_check('T48q manager may NOT act on the owner', NOT (SELECT fn_can_manage_member(t_get('biz'), t_get('u1'))));
SELECT t_check('T48r manager may NOT act on another manager', NOT (SELECT fn_can_manage_member(t_get('biz'), t_get('u2'))));
SELECT t_logout();
SELECT t_login('u3');
SELECT t_check('T48s sales_staff may act on nobody', NOT (SELECT fn_can_manage_member(t_get('biz'), t_get('u4'))));
SELECT t_logout();

-- the reset action resolves its target address in the database, never from the client
SELECT t_login('u1');
SELECT t_check('T48t owner resolves a reset address for their own member',
  (SELECT rpc_reset_target_email(t_get('biz'), t_get('u3'))) = 'sales@tlc.test');
SELECT t_err('T48u owner cannot resolve an address across tenants',
  $q$ SELECT rpc_reset_target_email(t_get('bizB'), t_get('u5')) $q$, 'FORBIDDEN');
SELECT t_err('T48v owner cannot resolve an address for a non-member',
  $q$ SELECT rpc_reset_target_email(t_get('biz'), t_get('u5')) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_check('T48w manager resolves a subordinate address',
  (SELECT rpc_reset_target_email(t_get('biz'), t_get('u3'))) = 'sales@tlc.test');
SELECT t_err('T48x manager cannot resolve the owner address',
  $q$ SELECT rpc_reset_target_email(t_get('biz'), t_get('u1')) $q$, 'FORBIDDEN');
SELECT t_err('T48y manager cannot resolve another manager address',
  $q$ SELECT rpc_reset_target_email(t_get('biz'), t_get('u2')) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u3');
SELECT t_err('T48z sales_staff cannot resolve any reset address',
  $q$ SELECT rpc_reset_target_email(t_get('biz'), t_get('u4')) $q$, 'FORBIDDEN');
SELECT t_logout();

-- ============================================================
-- T60 — Phase 6A: product master, variant matrix, images, storage RLS
-- ============================================================
-- Fixtures: biz (owner u1, manager u2, sales u3, stock u4), bizB (owner u5),
-- p1 'Keten Elbise' with v1 (S) / v2 (M) that carry sales + receipt history, pB in bizB.

-- ---------- options: kind + colour metadata
SELECT t_logout();
WITH x AS (INSERT INTO product_options (business_id, name, kind, sort_order) VALUES (t_get('biz'), 'Renk', 'color', 5) RETURNING id)
  SELECT t_set('opt_color', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, color_hex, sort_order) VALUES (t_get('opt_color'), 'Siyah', 'SYH', '#111111', 1) RETURNING id)
  SELECT t_set('val_black', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('opt_color'), 'Leopar', 'LEO', 2) RETURNING id)
  SELECT t_set('val_leo', id) FROM x;
-- 'L' is seeded (c1000000-…-0004); attach its code rather than inserting a duplicate value
SELECT t_set('val_l', 'c1000000-0000-4000-8000-000000000004');
UPDATE option_values SET code = 'L' WHERE id = t_get('val_l');
SELECT t_check('T60a option kind stored', (SELECT kind::text FROM product_options WHERE id = t_get('opt_color')) = 'color');
SELECT t_check('T60b colour value has hex + code', (SELECT color_hex || '/' || code FROM option_values WHERE id = t_get('val_black')) = '#111111/SYH');
SELECT t_check('T60c colour value may have no hex (Leopar)', (SELECT color_hex IS NULL FROM option_values WHERE id = t_get('val_leo')));
SELECT t_err('T60d invalid hex rejected', $q$ UPDATE option_values SET color_hex = 'black' WHERE id = t_get('val_leo') $q$, '23514');
SELECT t_ok('T60e size option kind set', $q$ UPDATE product_options SET kind = 'size' WHERE id = t_get('opt_size') $q$);

-- ---------- style code: optional, tenant-scoped duplicate is a warning, not a constraint
SELECT t_ok('T60f style_code optional and settable', $q$ UPDATE products SET style_code = 'KE-2026' WHERE id = t_get('p1') $q$);
SELECT t_ok('T60g duplicate style_code allowed (warning is a UI concern)',
  $q$ UPDATE products SET style_code = 'KE-2026' WHERE id = t_get('p2') $q$);
SELECT t_check('T60h duplicate style_code lookup finds both', t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('biz') AND lower(style_code) = 'ke-2026' $q$) = 2);

-- ---------- variant matrix: manager+, atomic, idempotent
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), 'Saten Midi Elbise', 'SME', 2500, 'active') RETURNING id)
  SELECT t_set('p6', id) FROM x;
CREATE FUNCTION t_combo(sku TEXT, VARIADIC vals TEXT[]) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE ids JSONB := '[]'; k TEXT;
BEGIN
  FOREACH k IN ARRAY vals LOOP ids := ids || to_jsonb(t_get(k)::text); END LOOP;
  RETURN jsonb_build_object('sku', sku, 'option_value_ids', ids);
END $$;

SELECT t_login('u3');
SELECT t_err('T60i sales_staff cannot generate a matrix',
  $q$ SELECT * FROM rpc_generate_variants(t_get('p6'), jsonb_build_array(t_combo('SME-SYH-S','val_black','val_s'))) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T60j other tenant owner cannot generate a matrix here',
  $q$ SELECT * FROM rpc_generate_variants(t_get('p6'), jsonb_build_array(t_combo('SME-SYH-S','val_black','val_s'))) $q$, 'FORBIDDEN');
SELECT t_logout();

SELECT t_login('u2');
CREATE TEMP TABLE _m1 AS
  SELECT * FROM rpc_generate_variants(t_get('p6'), jsonb_build_array(
    t_combo('SME-SYH-S','val_black','val_s'), t_combo('SME-SYH-M','val_black','val_m'), t_combo('SME-SYH-L','val_black','val_l'),
    t_combo('SME-LEO-S','val_leo','val_s'),   t_combo('SME-LEO-M','val_leo','val_m'),   t_combo('SME-LEO-L','val_leo','val_l')));
SELECT t_check('T60k 2 colours x 3 sizes = 6 variants created', (SELECT count(*) FILTER (WHERE created) FROM _m1) = 6);
SELECT t_check('T60l every variant carries two option rows',
  t_count($q$ SELECT count(*) FROM variant_option_values vov JOIN product_variants pv ON pv.id = vov.variant_id WHERE pv.product_id = t_get('p6') $q$) = 12);
SELECT t_check('T60m fingerprints distinct',
  t_count($q$ SELECT count(DISTINCT option_fingerprint) FROM product_variants WHERE product_id = t_get('p6') $q$) = 6);

-- re-run the same matrix plus one new combination: nothing duplicates, only the new one is created
CREATE TEMP TABLE _m2 AS
  SELECT * FROM rpc_generate_variants(t_get('p6'), jsonb_build_array(
    t_combo('SME-SYH-S-DUP','val_black','val_s'), t_combo('SME-LEO-M-DUP','val_leo','val_m')));
SELECT t_check('T60n re-run is idempotent (0 created)', (SELECT count(*) FILTER (WHERE created) FROM _m2) = 0);
SELECT t_check('T60o re-run reports the existing variant ids',
  (SELECT count(*) FROM _m2 m JOIN product_variants pv ON pv.id = m.variant_id WHERE pv.product_id = t_get('p6')) = 2);
SELECT t_check('T60p still 6 variants after re-run', t_count($q$ SELECT count(*) FROM product_variants WHERE product_id = t_get('p6') $q$) = 6);

-- a combination may not carry two values of the same option
SELECT t_err('T60q two sizes in one combination rejected',
  $q$ SELECT * FROM rpc_generate_variants(t_get('p6'), jsonb_build_array(t_combo('SME-BAD','val_s','val_m'))) $q$, 'INVALID_COMBINATION');
-- another tenant's option value is refused
SELECT t_logout();
WITH x AS (INSERT INTO product_options (business_id, name, kind) VALUES (t_get('bizB'), 'Renk', 'color') RETURNING id) SELECT t_set('optB_color', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value) VALUES (t_get('optB_color'), 'Kırmızı') RETURNING id) SELECT t_set('valB_red', id) FROM x;
SELECT t_login('u2');
SELECT t_err('T60r option value of another tenant refused',
  $q$ SELECT * FROM rpc_generate_variants(t_get('p6'), jsonb_build_array(t_combo('SME-X','valB_red'))) $q$, 'INVALID_OPTION_VALUE');
-- one-size / no-option product: a single variant with an empty fingerprint
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), 'Tek Beden Şal', 'TBS', 400, 'active') RETURNING id)
  SELECT t_set('p7', id) FROM x;
CREATE TEMP TABLE _m3 AS SELECT * FROM rpc_generate_variants(t_get('p7'), jsonb_build_array(jsonb_build_object('sku', 'TBS-STD', 'option_value_ids', '[]'::jsonb)));
SELECT t_check('T60s one-size product creates a single option-less variant',
  (SELECT count(*) FILTER (WHERE created) FROM _m3) = 1
  AND t_count($q$ SELECT count(*) FROM variant_option_values vov JOIN product_variants pv ON pv.id = vov.variant_id WHERE pv.product_id = t_get('p7') $q$) = 0);
CREATE TEMP TABLE _m4 AS SELECT * FROM rpc_generate_variants(t_get('p7'), jsonb_build_array(jsonb_build_object('sku', 'TBS-STD2', 'option_value_ids', '[]'::jsonb)));
SELECT t_check('T60t second option-less combination is the same variant', (SELECT bool_and(NOT created) FROM _m4));
SELECT t_err('T60u empty matrix rejected', $q$ SELECT * FROM rpc_generate_variants(t_get('p7'), '[]'::jsonb) $q$, 'EMPTY_MATRIX');
SELECT t_logout();

-- ---------- barcode resolution: tenant-safe, exactly one
SELECT t_set('v6a', (SELECT variant_id FROM _m1 WHERE sku = 'SME-SYH-S'));
INSERT INTO barcodes (variant_id, barcode, barcode_type, symbology, is_primary) VALUES (t_get('v6a'), '8690000000999', 'supplier', 'EAN13', true);
INSERT INTO barcodes (variant_id, barcode, barcode_type, symbology) VALUES (t_get('v6a'), 'OLD-LABEL-7', 'supplier', 'CODE128');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pB'), 'OP-01-STD') RETURNING id) SELECT t_set('vB', id) FROM x;
SELECT t_err('T60v same barcode twice in one business rejected', $q$ INSERT INTO barcodes (variant_id, barcode) VALUES (t_get('v2'), '8690000000999') $q$, '23505');
SELECT t_ok('T60w same code may exist in ANOTHER business',
  $q$ INSERT INTO barcodes (variant_id, barcode) VALUES (t_get('vB'), '8690000000999') $q$);
SELECT t_login('u3');
SELECT t_check('T60x sales_staff resolves a barcode to exactly one variant',
  (SELECT count(*) FROM rpc_resolve_barcode(t_get('biz'), '8690000000999')) = 1
  AND (SELECT variant_id FROM rpc_resolve_barcode(t_get('biz'), '8690000000999')) = t_get('v6a'));
SELECT t_check('T60y an alternate / historical code resolves to the same variant',
  (SELECT variant_id FROM rpc_resolve_barcode(t_get('biz'), 'OLD-LABEL-7')) = t_get('v6a'));
SELECT t_check('T60z SKU is a keyboard fallback', (SELECT matched_by FROM rpc_resolve_barcode(t_get('biz'), 'SME-LEO-M')) = 'sku');
SELECT t_check('T60aa unknown code resolves to nothing', (SELECT count(*) FROM rpc_resolve_barcode(t_get('biz'), 'NOPE')) = 0);
SELECT t_err('T60ab resolving in another tenant is refused', $q$ SELECT * FROM rpc_resolve_barcode(t_get('bizB'), '8690000000999') $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_check('T60ac the same code in business B resolves to B''s own variant',
  (SELECT product_id FROM rpc_resolve_barcode(t_get('bizB'), '8690000000999')) = t_get('pB'));
SELECT t_logout();

-- ---------- images: roles, constraints, main-image uniqueness
SELECT t_login('u2');
WITH x AS (INSERT INTO product_images (product_id, role, storage_path, mime_type, byte_size)
  VALUES (t_get('p6'), 'product_main', 'business/' || t_get('biz') || '/products/' || t_get('p6') || '/a.jpg', 'image/jpeg', 1000) RETURNING id)
  SELECT t_set('img_main', id) FROM x;
WITH x AS (INSERT INTO product_images (product_id, role, storage_path, mime_type, byte_size)
  VALUES (t_get('p6'), 'product_gallery', 'business/' || t_get('biz') || '/products/' || t_get('p6') || '/b.jpg', 'image/jpeg', 1000) RETURNING id)
  SELECT t_set('img_gal', id) FROM x;
SELECT t_check('T60ad image business_id derived from product', (SELECT business_id FROM product_images WHERE id = t_get('img_main')) = t_get('biz'));
SELECT t_err('T60ae second product_main rejected by index',
  $q$ INSERT INTO product_images (product_id, role, storage_path) VALUES (t_get('p6'), 'product_main', 'business/' || t_get('biz') || '/products/' || t_get('p6') || '/c.jpg') $q$, '23505');
SELECT t_ok('T60af rpc_set_main_image swaps main atomically', $q$ SELECT rpc_set_main_image(t_get('img_gal')) $q$);
SELECT t_check('T60ag exactly one main after swap and it is the gallery image',
  t_count($q$ SELECT count(*) FROM product_images WHERE product_id = t_get('p6') AND role = 'product_main' $q$) = 1
  AND (SELECT role::text FROM product_images WHERE id = t_get('img_gal')) = 'product_main'
  AND (SELECT role::text FROM product_images WHERE id = t_get('img_main')) = 'product_gallery');
SELECT t_err('T60ah variant image needs a variant', $q$ INSERT INTO product_images (product_id, role, storage_path) VALUES (t_get('p6'), 'variant', 'business/x/v.jpg') $q$, '23514');
SELECT t_ok('T60ai variant image accepted', $q$ INSERT INTO product_images (product_id, variant_id, role, storage_path) VALUES (t_get('p6'), t_get('v6a'), 'variant', 'business/' || t_get('biz') || '/products/' || t_get('p6') || '/v.jpg') $q$);
SELECT t_err('T60aj image needs a source (url or storage_path)', $q$ INSERT INTO product_images (product_id, role) VALUES (t_get('p6'), 'product_gallery') $q$, '23514');
SELECT t_err('T60ak unsupported mime rejected', $q$ INSERT INTO product_images (product_id, role, storage_path, mime_type) VALUES (t_get('p6'), 'product_gallery', 'business/x/d.gif', 'image/gif') $q$, '23514');
SELECT t_err('T60al receiving proof needs a goods receipt', $q$ INSERT INTO product_images (product_id, role, storage_path) VALUES (t_get('p6'), 'receiving_proof', 'business/x/r.jpg') $q$, '23514');
SELECT t_ok('T60am receiving proof attaches to a goods receipt without a product',
  $q$ INSERT INTO product_images (goods_receipt_id, role, storage_path) VALUES (t_get('gr1'), 'receiving_proof', 'business/' || t_get('biz') || '/receipts/' || t_get('gr1') || '/proof.jpg') $q$);
SELECT t_check('T60an receiving proof business_id derived from the receipt',
  (SELECT business_id FROM product_images WHERE goods_receipt_id = t_get('gr1')) = t_get('biz'));
SELECT t_logout();

-- image RLS: members read, manager+ write, other tenant sees nothing
SELECT t_login('u3');
SELECT t_check('T60ao sales_staff reads product images of own tenant', t_count($q$ SELECT count(*) FROM product_images WHERE product_id = t_get('p6') $q$) = 3);
SELECT t_err('T60aq sales_staff insert refused by RLS',
  $q$ INSERT INTO product_images (product_id, role, storage_path) VALUES (t_get('p6'), 'product_gallery', 'business/' || t_get('biz') || '/products/' || t_get('p6') || '/z.jpg') $q$, '42501');
SELECT t_err('T60ar sales_staff cannot promote a main image', $q$ SELECT rpc_set_main_image(t_get('img_main')) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_check('T60as other tenant sees no images of p6', t_count($q$ SELECT count(*) FROM product_images WHERE product_id = t_get('p6') $q$) = 0);
-- the owner-resolving trigger reads products under RLS, so the foreign product is simply not there
SELECT t_err('T60at other tenant cannot attach an image to p6', $q$ INSERT INTO product_images (product_id, role, storage_path) VALUES (t_get('p6'), 'product_gallery', 'business/' || t_get('bizB') || '/products/x/z.jpg') $q$, 'not found');
SELECT t_err('T60au other tenant cannot promote p6 image', $q$ SELECT rpc_set_main_image(t_get('img_main')) $q$, 'FORBIDDEN');
SELECT t_logout();

-- ---------- storage objects RLS (bucket product-images, path business/<id>/...)
SELECT t_check('T60av bucket exists and is private',
  (SELECT NOT public AND file_size_limit = 5242880 FROM storage.buckets WHERE id = 'product-images'));
SELECT t_check('T60aw path helper extracts the tenant',
  fn_storage_business_id('business/' || t_get('biz') || '/products/p/a.jpg') = t_get('biz')
  AND fn_storage_business_id('other/' || t_get('biz') || '/a.jpg') IS NULL
  AND fn_storage_business_id('business/not-a-uuid/a.jpg') IS NULL);
SELECT t_login('u2');
SELECT t_ok('T60ax manager uploads into own tenant path',
  $q$ INSERT INTO storage.objects (bucket_id, name, owner) VALUES ('product-images', 'business/' || t_get('biz') || '/products/' || t_get('p6') || '/a.jpg', auth.uid()) $q$);
SELECT t_err('T60ay manager cannot upload into another tenant path',
  $q$ INSERT INTO storage.objects (bucket_id, name, owner) VALUES ('product-images', 'business/' || t_get('bizB') || '/products/x/a.jpg', auth.uid()) $q$, '42501');
SELECT t_err('T60az manager cannot upload outside the business/ prefix',
  $q$ INSERT INTO storage.objects (bucket_id, name, owner) VALUES ('product-images', 'loose/a.jpg', auth.uid()) $q$, '42501');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_ok('T60ba tenant B uploads into its own path',
  $q$ INSERT INTO storage.objects (bucket_id, name, owner) VALUES ('product-images', 'business/' || t_get('bizB') || '/products/' || t_get('pB') || '/b.jpg', auth.uid()) $q$);
SELECT t_check('T60bb tenant B cannot read tenant A objects',
  t_count($q$ SELECT count(*) FROM storage.objects WHERE name LIKE 'business/' || t_get('biz') || '/%' $q$) = 0);
SELECT t_check('T60bc tenant B reads its own object', t_count($q$ SELECT count(*) FROM storage.objects WHERE name LIKE 'business/' || t_get('bizB') || '/%' $q$) = 1);
SELECT t_check('T60bd tenant B cannot delete tenant A objects (0 rows)',
  t_count($q$ WITH d AS (DELETE FROM storage.objects WHERE name LIKE 'business/' || t_get('biz') || '/%' RETURNING id) SELECT count(*) FROM d $q$) = 0);
SELECT t_logout();
SELECT t_login('u3');
SELECT t_check('T60be sales_staff reads own tenant object (signed URLs work)', t_count($q$ SELECT count(*) FROM storage.objects WHERE name LIKE 'business/' || t_get('biz') || '/%' $q$) = 1);
SELECT t_err('T60bf sales_staff cannot upload', $q$ INSERT INTO storage.objects (bucket_id, name, owner) VALUES ('product-images', 'business/' || t_get('biz') || '/products/x/s.jpg', auth.uid()) $q$, '42501');
SELECT t_logout();
SELECT t_login('u4');
SELECT t_err('T60bg stock_staff cannot upload either (manager+ only in 6A)', $q$ INSERT INTO storage.objects (bucket_id, name, owner) VALUES ('product-images', 'business/' || t_get('biz') || '/products/x/s.jpg', auth.uid()) $q$, '42501');
SELECT t_logout();

-- ---------- staff cannot escalate by rewriting business_id
SELECT t_login('u2');
SELECT t_err('T60bh manager cannot move a product to another tenant',
  $q$ UPDATE products SET business_id = t_get('bizB') WHERE id = t_get('p6') $q$, '42501');
-- the image trigger re-derives business_id from the product on every write, so the rewrite is neutralised
SELECT t_ok('T60bi image business_id rewrite is accepted…', $q$ UPDATE product_images SET business_id = t_get('bizB') WHERE id = t_get('img_main') $q$);
SELECT t_check('T60bi2 …but neutralised: image still belongs to tenant A', (SELECT business_id FROM product_images WHERE id = t_get('img_main')) = t_get('biz'));
SELECT t_logout();

-- ---------- archive instead of delete: history protects the variant
SELECT t_err('T60bj variant with sales/receipt history cannot be deleted', $q$ DELETE FROM product_variants WHERE id = t_get('v1') $q$, '23503');
SELECT t_err('T60bk product with variant history cannot be deleted', $q$ DELETE FROM products WHERE id = t_get('p1') $q$, '23503');
SELECT t_login('u2');
SELECT t_ok('T60bl variant is archived instead', $q$ UPDATE product_variants SET status = 'archived' WHERE id = t_get('v6a') $q$);
SELECT t_check('T60bm archived variant frees its combination for a new active one',
  (SELECT created FROM rpc_generate_variants(t_get('p6'), jsonb_build_array(t_combo('SME-SYH-S-2','val_black','val_s')))) = true);
SELECT t_ok('T60bn product archived, not deleted', $q$ UPDATE products SET status = 'archived' WHERE id = t_get('p7') $q$);
SELECT t_check('T60bo archived product keeps its variants', t_count($q$ SELECT count(*) FROM product_variants WHERE product_id = t_get('p7') $q$) = 1);
SELECT t_logout();

-- ---------- tenant isolation of the product master queries
SELECT t_login('u5');
SELECT t_check('T60bp tenant B sees none of tenant A products / variants / values',
  t_count($q$ SELECT count(*) FROM products WHERE business_id = t_get('biz') $q$) = 0
  AND t_count($q$ SELECT count(*) FROM product_variants WHERE product_id = t_get('p6') $q$) = 0
  AND t_count($q$ SELECT count(*) FROM option_values WHERE id = t_get('val_black') $q$) = 0);
SELECT t_logout();

-- ============================================================
-- T61 — archive-only lifecycle: tenant roles cannot DELETE products / variants
-- ============================================================
-- fresh, history-less fixtures in tenant A
SELECT t_logout();
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), 'Silinemez Elbise', 'SLN', 900, 'active') RETURNING id)
  SELECT t_set('p61', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p61'), 'SLN-STD') RETURNING id) SELECT t_set('v61', id) FROM x;

SELECT t_check('T61 privilege: authenticated has no DELETE on products / product_variants',
  NOT has_table_privilege('authenticated', 'products', 'DELETE') AND NOT has_table_privilege('authenticated', 'product_variants', 'DELETE')
  AND NOT has_table_privilege('anon', 'products', 'DELETE'));
SELECT t_check('T61 no DELETE policy exists on products / product_variants',
  t_count($q$ SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('products','product_variants') AND cmd IN ('DELETE','ALL') $q$) = 0);

SELECT t_login('u1');
SELECT t_err('T61a owner cannot DELETE a history-less product', $q$ DELETE FROM products WHERE id = t_get('p61') $q$, '42501');
SELECT t_err('T61e owner cannot DELETE a history-less variant', $q$ DELETE FROM product_variants WHERE id = t_get('v61') $q$, '42501');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_err('T61b manager cannot DELETE a history-less product', $q$ DELETE FROM products WHERE id = t_get('p61') $q$, '42501');
SELECT t_err('T61f manager cannot DELETE a variant', $q$ DELETE FROM product_variants WHERE id = t_get('v61') $q$, '42501');
SELECT t_logout();
SELECT t_login('u4');
SELECT t_err('T61c stock_staff cannot DELETE a product', $q$ DELETE FROM products WHERE id = t_get('p61') $q$, '42501');
SELECT t_logout();
SELECT t_login('u3');
SELECT t_err('T61d sales_staff cannot DELETE a product', $q$ DELETE FROM products WHERE id = t_get('p61') $q$, '42501');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T61 other tenant cannot DELETE either', $q$ DELETE FROM products WHERE id = t_get('p61') $q$, '42501');
SELECT t_check('T61 other tenant still cannot read it', t_count($q$ SELECT count(*) FROM products WHERE id = t_get('p61') $q$) = 0);
SELECT t_logout();
SELECT t_check('T61 rows survived every attempt',
  t_count($q$ SELECT count(*) FROM products WHERE id = t_get('p61') $q$) = 1 AND t_count($q$ SELECT count(*) FROM product_variants WHERE id = t_get('v61') $q$) = 1);

-- lifecycle still works
SELECT t_login('u1');
SELECT t_ok('T61g archive product', $q$ UPDATE products SET status = 'archived' WHERE id = t_get('p61') $q$);
SELECT t_check('T61g archived', (SELECT status::text FROM products WHERE id = t_get('p61')) = 'archived');
SELECT t_ok('T61h restore archived product', $q$ UPDATE products SET status = 'active' WHERE id = t_get('p61') $q$);
SELECT t_check('T61h active again', (SELECT status::text FROM products WHERE id = t_get('p61')) = 'active');
SELECT t_ok('T61i deactivate (archive) variant', $q$ UPDATE product_variants SET status = 'archived' WHERE id = t_get('v61') $q$);
SELECT t_check('T61i variant archived', (SELECT status::text FROM product_variants WHERE id = t_get('v61')) = 'archived');
SELECT t_ok('T61 manager+ can still insert products', $q$ INSERT INTO products (business_id, name, sku_prefix, default_sale_price) VALUES (t_get('biz'), 'Yeni Model', 'YNM', 100) $q$);
SELECT t_logout();
SELECT t_login('u3');
SELECT t_check('T61 sales_staff still cannot update a product (0 rows)',
  t_count($q$ WITH u AS (UPDATE products SET name = 'x' WHERE id = t_get('p61') RETURNING id) SELECT count(*) FROM u $q$) = 0
  AND (SELECT name FROM products WHERE id = t_get('p61')) = 'Silinemez Elbise');
SELECT t_logout();

-- child objects keep their intended semantics
SELECT t_login('u4');
SELECT t_ok('T61 stock_staff may still remove a wrong barcode label', $q$ INSERT INTO barcodes (variant_id, barcode) VALUES (t_get('v61'), 'WRONG-LABEL-61') $q$);
SELECT t_check('T61 …and the delete actually removes it',
  t_count($q$ WITH d AS (DELETE FROM barcodes WHERE barcode = 'WRONG-LABEL-61' RETURNING id) SELECT count(*) FROM d $q$) = 1);
SELECT t_logout();
SELECT t_login('u2');
SELECT t_ok('T61 manager may still remove a product image', $q$ INSERT INTO product_images (product_id, role, storage_path) VALUES (t_get('p61'), 'product_gallery', 'business/' || t_get('biz') || '/products/' || t_get('p61') || '/g.jpg') $q$);
SELECT t_check('T61 …and the image delete removes it',
  t_count($q$ WITH d AS (DELETE FROM product_images WHERE product_id = t_get('p61') RETURNING id) SELECT count(*) FROM d $q$) = 1);
SELECT t_logout();

-- J) history protections intact (FK RESTRICT still guards maintenance deletes too)
SELECT t_err('T61j history-bearing variant still undeletable even for maintenance', $q$ DELETE FROM product_variants WHERE id = t_get('v1') $q$, '23503');
SELECT t_err('T61j history-bearing product still undeletable even for maintenance', $q$ DELETE FROM products WHERE id = t_get('p1') $q$, '23503');

-- ============================================================
-- T62 — Phase 6B catalogue onboarding: atomic product+variants+barcodes,
--        creator stamping, duplicate barcode rollback, existing-product
--        variant add, cross-tenant refusal, zero stock / cost / receipt effect
-- ============================================================
SELECT t_logout();
-- baseline of everything the onboarding RPCs must never touch
CREATE TEMP TABLE _t62_base AS
SELECT (SELECT count(*) FROM inventory_movements)                                AS movements,
       (SELECT count(*) FROM variant_cost_pools)                                 AS pools,
       (SELECT COALESCE(sum(on_hand_qty), 0) FROM variant_cost_pools)           AS on_hand,
       (SELECT COALESCE(sum(total_value_base), 0) FROM variant_cost_pools)      AS pool_value,
       (SELECT count(*) FROM supplier_account_entries)                           AS liab_rows,
       (SELECT COALESCE(sum(amount_base), 0) FROM supplier_account_entries)     AS liab_sum,
       (SELECT count(*) FROM goods_receipts)                                     AS receipts,
       (SELECT count(*) FROM goods_receipt_items)                                AS receipt_items,
       (SELECT count(*) FROM products)                                           AS products,
       (SELECT count(*) FROM product_variants)                                   AS variants,
       (SELECT count(*) FROM barcodes)                                           AS barcodes;

SELECT t_check('T62 privilege: onboarding RPCs are authenticated-only',
  has_function_privilege('authenticated', 'rpc_onboard_product(uuid, jsonb, jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_onboard_product(uuid, jsonb, jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_onboard_variants(uuid, jsonb)', 'EXECUTE'));

-- A) owner onboards a colour+size model with label barcodes, one call
SELECT t_login('u1');
SELECT t_ok('T62a owner onboards a new model with 2 variants and 3 barcodes', $q$
  CREATE TEMP TABLE _t62a AS
  SELECT * FROM rpc_onboard_product(t_get('biz'),
    jsonb_build_object('name', 'Keten Gömlek', 'sku_prefix', 'KTG-62', 'style_code', 'SS26-062',
                       'category_id', t_get('cat_elbise')::text, 'default_sale_price', '1450'),
    jsonb_build_array(
      jsonb_build_object('sku', 'KTG-62-SYH-L', 'option_value_ids', jsonb_build_array(t_get('val_black')::text, t_get('val_l')::text),
                         'barcodes', jsonb_build_array('8690000000620', '0062-OLD')),
      jsonb_build_object('sku', 'KTG-62-LEO-L', 'option_value_ids', jsonb_build_array(t_get('val_leo')::text, t_get('val_l')::text),
                         'barcodes', jsonb_build_array('8690000000621'))))
$q$);
SELECT t_set('p62', (SELECT product_id FROM _t62a LIMIT 1));
SELECT t_set('v62a', (SELECT variant_id FROM _t62a WHERE sku = 'KTG-62-SYH-L'));
SELECT t_set('v62b', (SELECT variant_id FROM _t62a WHERE sku = 'KTG-62-LEO-L'));
SELECT t_check('T62a two variants created', (SELECT count(*) FROM _t62a WHERE created) = 2 AND (SELECT sum(barcodes_added) FROM _t62a) = 3);
SELECT t_check('T62a product active, in tenant, with style code and category',
  (SELECT status::text || '/' || style_code || '/' || (category_id = t_get('cat_elbise'))::text FROM products WHERE id = t_get('p62') AND business_id = t_get('biz')) = 'active/SS26-062/true');
SELECT t_check('T62a variants carry their option values',
  t_count($q$ SELECT count(*) FROM variant_option_values WHERE variant_id IN (t_get('v62a'), t_get('v62b')) $q$) = 4);
SELECT t_check('T62a barcodes stored exactly, EAN13 detected, first one primary, others alternate',
  (SELECT string_agg(barcode || ':' || symbology || ':' || barcode_type::text || ':' || is_primary::text, ',' ORDER BY barcode)
   FROM barcodes WHERE variant_id = t_get('v62a')) = '0062-OLD:CODE128:supplier:false,8690000000620:EAN13:supplier:true');
SELECT t_check('T62a barcode with leading zeros preserved verbatim',
  t_count($q$ SELECT count(*) FROM barcodes WHERE barcode = '0062-OLD' $q$) = 1);
SELECT t_check('T62a barcode resolves to the new variant',
  (SELECT variant_id FROM rpc_resolve_barcode(t_get('biz'), '8690000000621')) = t_get('v62b'));
SELECT t_check('T62a created_by stamped on product and variants',
  (SELECT created_by FROM products WHERE id = t_get('p62')) = t_get('u1')
  AND t_count($q$ SELECT count(*) FROM product_variants WHERE product_id = t_get('p62') AND created_by = t_get('u1') $q$) = 2);
SELECT t_ok('T62a image insert stamps creator', $q$ INSERT INTO product_images (product_id, role, storage_path) VALUES (t_get('p62'), 'product_main', 'business/' || t_get('biz') || '/products/' || t_get('p62') || '/m.jpg') $q$);
SELECT t_check('T62a image created_by = uploader', t_count($q$ SELECT count(*) FROM product_images WHERE product_id = t_get('p62') AND created_by = t_get('u1') $q$) = 1);

-- B) duplicate barcode: whole call rolls back, no orphan product
SELECT t_err('T62b duplicate label barcode refuses the whole product', $q$
  SELECT * FROM rpc_onboard_product(t_get('biz'),
    jsonb_build_object('name', 'Kopya Gömlek', 'sku_prefix', 'KTG-62X'),
    jsonb_build_array(jsonb_build_object('sku', 'KTG-62X-STD', 'option_value_ids', '[]'::jsonb, 'barcodes', jsonb_build_array('8690000000620'))))
$q$, '23505');
SELECT t_check('T62b nothing of the refused product remains',
  t_count($q$ SELECT count(*) FROM products WHERE sku_prefix = 'KTG-62X' $q$) = 0
  AND t_count($q$ SELECT count(*) FROM product_variants WHERE sku = 'KTG-62X-STD' $q$) = 0);
SELECT t_err('T62b duplicate barcode inside one call also rolls back',
  $q$ SELECT * FROM rpc_onboard_product(t_get('biz'), jsonb_build_object('name', 'Çift Barkod', 'sku_prefix', 'KTG-62Y'),
        jsonb_build_array(jsonb_build_object('sku', 'KTG-62Y-A', 'option_value_ids', jsonb_build_array(t_get('val_black')::text), 'barcodes', jsonb_build_array('DUP-62')),
                          jsonb_build_object('sku', 'KTG-62Y-B', 'option_value_ids', jsonb_build_array(t_get('val_leo')::text),   'barcodes', jsonb_build_array('DUP-62')))) $q$, '23505');
SELECT t_check('T62b no half product from the in-call duplicate', t_count($q$ SELECT count(*) FROM products WHERE sku_prefix = 'KTG-62Y' $q$) = 0);

-- C) existing product: add only the missing variant (Leopar / L exists → skipped, Siyah / Leopar + new size)
SELECT t_ok('T62c add a missing variant to the existing model', $q$
  CREATE TEMP TABLE _t62c AS
  SELECT * FROM rpc_onboard_variants(t_get('p62'), jsonb_build_array(
    jsonb_build_object('sku', 'KTG-62-LEO-L', 'option_value_ids', jsonb_build_array(t_get('val_leo')::text, t_get('val_l')::text), 'barcodes', jsonb_build_array('8690000000622')),
    jsonb_build_object('sku', 'KTG-62-SYH-STD', 'option_value_ids', jsonb_build_array(t_get('val_black')::text), 'barcodes', '[]'::jsonb)))
$q$);
SELECT t_check('T62c existing combination skipped, new one created',
  (SELECT created FROM _t62c WHERE sku = 'KTG-62-LEO-L') = false AND (SELECT created FROM _t62c WHERE sku = 'KTG-62-SYH-STD') = true);
SELECT t_check('T62c extra barcode attached to the existing variant as alternate',
  (SELECT is_primary FROM barcodes WHERE barcode = '8690000000622') = false
  AND (SELECT variant_id FROM barcodes WHERE barcode = '8690000000622') = t_get('v62b'));
SELECT t_check('T62c variant without barcode is allowed',
  t_count($q$ SELECT count(*) FROM barcodes b JOIN product_variants pv ON pv.id = b.variant_id WHERE pv.sku = 'KTG-62-SYH-STD' $q$) = 0);
SELECT t_check('T62c original variants and barcodes untouched',
  t_count($q$ SELECT count(*) FROM barcodes WHERE variant_id = t_get('v62a') $q$) = 2
  AND t_count($q$ SELECT count(*) FROM product_variants WHERE product_id = t_get('p62') AND status = 'active' $q$) = 3);
SELECT t_logout();

-- D) roles: manager may, stock_staff / sales_staff may not, other tenant may not
SELECT t_login('u2');
SELECT t_ok('T62d manager onboards a single-variant model without barcode', $q$
  SELECT * FROM rpc_onboard_product(t_get('biz'), jsonb_build_object('name', 'Tek Beden Şal', 'sku_prefix', 'SAL-62'),
    jsonb_build_array(jsonb_build_object('sku', 'SAL-62-STD', 'option_value_ids', '[]'::jsonb))) $q$);
SELECT t_check('T62d manager stamped as creator', (SELECT created_by FROM products WHERE sku_prefix = 'SAL-62') = t_get('u2'));
SELECT t_logout();
SELECT t_login('u4');
SELECT t_err('T62d stock_staff cannot onboard a product', $q$ SELECT * FROM rpc_onboard_product(t_get('biz'), jsonb_build_object('name', 'Yasak', 'sku_prefix', 'YSK-62'), jsonb_build_array(jsonb_build_object('sku', 'YSK-62-STD', 'option_value_ids', '[]'::jsonb))) $q$, '42501');
SELECT t_err('T62d stock_staff cannot add variants through the RPC', $q$ SELECT * FROM rpc_onboard_variants(t_get('p62'), jsonb_build_array(jsonb_build_object('sku', 'KTG-62-X', 'option_value_ids', '[]'::jsonb))) $q$, '42501');
SELECT t_logout();
SELECT t_login('u3');
SELECT t_err('T62d sales_staff cannot onboard a product', $q$ SELECT * FROM rpc_onboard_product(t_get('biz'), jsonb_build_object('name', 'Yasak', 'sku_prefix', 'YSK-62'), jsonb_build_array(jsonb_build_object('sku', 'YSK-62-STD', 'option_value_ids', '[]'::jsonb))) $q$, '42501');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T62d other tenant cannot write into business A', $q$ SELECT * FROM rpc_onboard_product(t_get('biz'), jsonb_build_object('name', 'Sızma', 'sku_prefix', 'SIZ-62'), jsonb_build_array(jsonb_build_object('sku', 'SIZ-62-STD', 'option_value_ids', '[]'::jsonb))) $q$, '42501');
SELECT t_err('T62d other tenant cannot add variants to product A', $q$ SELECT * FROM rpc_onboard_variants(t_get('p62'), jsonb_build_array(jsonb_build_object('sku', 'KTG-62-Z', 'option_value_ids', '[]'::jsonb))) $q$, '42501');
SELECT t_err('T62d other tenant cannot borrow business A option values', $q$ SELECT * FROM rpc_onboard_product(t_get('bizB'), jsonb_build_object('name', 'Sızma', 'sku_prefix', 'SIZ-62B'), jsonb_build_array(jsonb_build_object('sku', 'SIZ-62B-A', 'option_value_ids', jsonb_build_array(t_get('val_black')::text)))) $q$, '22023');
SELECT t_err('T62d other tenant cannot reference business A category', $q$ SELECT * FROM rpc_onboard_product(t_get('bizB'), jsonb_build_object('name', 'Sızma', 'sku_prefix', 'SIZ-62C', 'category_id', t_get('cat_elbise')::text), jsonb_build_array(jsonb_build_object('sku', 'SIZ-62C-A', 'option_value_ids', '[]'::jsonb))) $q$, '23503');
SELECT t_check('T62d no cross-tenant product was created',
  t_count($q$ SELECT count(*) FROM products WHERE sku_prefix LIKE 'SIZ-62%' OR sku_prefix = 'YSK-62' $q$) = 0);
SELECT t_logout();

-- E) validation
SELECT t_login('u1');
SELECT t_err('T62e empty matrix refused', $q$ SELECT * FROM rpc_onboard_product(t_get('biz'), jsonb_build_object('name', 'Boş', 'sku_prefix', 'BOS-62'), '[]'::jsonb) $q$, '22023');
SELECT t_err('T62e name too short refused', $q$ SELECT * FROM rpc_onboard_product(t_get('biz'), jsonb_build_object('name', 'X', 'sku_prefix', 'X-62'), jsonb_build_array(jsonb_build_object('sku', 'X-62-STD', 'option_value_ids', '[]'::jsonb))) $q$, '22023');
SELECT t_err('T62e barcode too short refused', $q$ SELECT * FROM rpc_onboard_product(t_get('biz'), jsonb_build_object('name', 'Kısa Barkod', 'sku_prefix', 'KB-62'), jsonb_build_array(jsonb_build_object('sku', 'KB-62-STD', 'option_value_ids', '[]'::jsonb, 'barcodes', jsonb_build_array('12')))) $q$, '22023');
SELECT t_check('T62e refused product left nothing behind', t_count($q$ SELECT count(*) FROM products WHERE sku_prefix IN ('BOS-62','X-62','KB-62') $q$) = 0);
SELECT t_logout();

-- F) zero side effects: stock, cost, liability and receipts are byte-for-byte unchanged
SELECT t_check('T62f no inventory movement from onboarding', (SELECT count(*) FROM inventory_movements) = (SELECT movements FROM _t62_base));
SELECT t_check('T62f no cost pool created or changed',
  (SELECT count(*) FROM variant_cost_pools) = (SELECT pools FROM _t62_base)
  AND (SELECT COALESCE(sum(on_hand_qty), 0) FROM variant_cost_pools) = (SELECT on_hand FROM _t62_base)
  AND (SELECT COALESCE(sum(total_value_base), 0) FROM variant_cost_pools) = (SELECT pool_value FROM _t62_base));
SELECT t_check('T62f supplier liability unchanged',
  (SELECT count(*) FROM supplier_account_entries) = (SELECT liab_rows FROM _t62_base)
  AND (SELECT COALESCE(sum(amount_base), 0) FROM supplier_account_entries) = (SELECT liab_sum FROM _t62_base));
SELECT t_check('T62f goods receipts and items unchanged',
  (SELECT count(*) FROM goods_receipts) = (SELECT receipts FROM _t62_base)
  AND (SELECT count(*) FROM goods_receipt_items) = (SELECT receipt_items FROM _t62_base));
SELECT t_check('T62f new variants have no cost pool row at all',
  t_count($q$ SELECT count(*) FROM variant_cost_pools WHERE variant_id IN (SELECT id FROM product_variants WHERE product_id = t_get('p62')) $q$) = 0);
SELECT t_check('T62f exactly the expected catalogue rows were added (2 products, 4 variants, 4 barcodes)',
  (SELECT count(*) FROM products) = (SELECT products FROM _t62_base) + 2
  AND (SELECT count(*) FROM product_variants) = (SELECT variants FROM _t62_base) + 4
  AND (SELECT count(*) FROM barcodes) = (SELECT barcodes FROM _t62_base) + 4);

-- G) image rows cannot point at another tenant's object path (Phase 6B synthetic pilot finding)
SELECT t_login('u1');
SELECT t_err('T62g image row with a foreign tenant storage path refused', $q$ INSERT INTO product_images (product_id, role, storage_path) VALUES (t_get('p62'), 'product_gallery', 'business/' || t_get('bizB') || '/products/' || t_get('p62') || '/x.jpg') $q$, '23514');
SELECT t_err('T62g image row with a loose path refused', $q$ INSERT INTO product_images (product_id, role, storage_path) VALUES (t_get('p62'), 'product_gallery', 'products/' || t_get('p62') || '/x.jpg') $q$, '23514');
SELECT t_ok('T62g image row under its own tenant prefix accepted', $q$ INSERT INTO product_images (product_id, role, storage_path) VALUES (t_get('p62'), 'product_gallery', 'business/' || t_get('biz') || '/products/' || t_get('p62') || '/g.jpg') $q$);
SELECT t_logout();

-- ============================================================
-- T63 — Phase 7A stock count engine: lifecycle, zero side effects before POST,
--        missing-item rule, stale snapshot, atomic posting, idempotency, cost, RLS
-- ============================================================
-- Fresh product with four variants in tenant A, branch br1. Opening stock through the
-- existing adjustment RPC (manual cost), so pools carry a known moving average.
SELECT t_logout();
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), 'Sayım Elbise', 'SAY-63', 900, 'active') RETURNING id)
  SELECT t_set('p63', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p63'), 'SAY-63-A') RETURNING id) SELECT t_set('v63a', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v63a'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000001');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p63'), 'SAY-63-B') RETURNING id) SELECT t_set('v63b', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v63b'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000002');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p63'), 'SAY-63-C') RETURNING id) SELECT t_set('v63c', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v63c'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000003');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p63'), 'SAY-63-D') RETURNING id) SELECT t_set('v63d', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v63d'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000004');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p63'), 'SAY-63-E') RETURNING id) SELECT t_set('v63e', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v63e'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000005');
WITH x AS (INSERT INTO barcodes (variant_id, barcode, barcode_type) VALUES (t_get('v63a'), '2009000063001', 'supplier') RETURNING id) SELECT t_set('bc63a', id) FROM x;
-- a branch of its own, so the FULL count sees exactly this fixture's stock
WITH x AS (INSERT INTO branches (business_id, name, code) VALUES (t_get('biz'), 'Sayım Şubesi', 'SAY') RETURNING id) SELECT t_set('br63', id) FROM x;

SELECT t_login('u1');
SELECT t_ok('T63 opening stock A=5 @100', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br63'), t_get('v63a'), 'sellable', 5, 'sayım fixture', 'manual_cost', 100) $q$);
SELECT t_ok('T63 opening stock B=3 @200', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br63'), t_get('v63b'), 'sellable', 3, 'sayım fixture', 'manual_cost', 200) $q$);
SELECT t_ok('T63 opening stock D sellable=2 @50', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br63'), t_get('v63d'), 'sellable', 2, 'sayım fixture', 'manual_cost', 50) $q$);
SELECT t_ok('T63 opening stock D damaged=1 @50', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br63'), t_get('v63d'), 'damaged', 1, 'sayım fixture', 'manual_cost', 50) $q$);
SELECT t_ok('T63 opening stock E=1 @30 (will not be scanned)', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br63'), t_get('v63e'), 'sellable', 1, 'sayım fixture', 'manual_cost', 30) $q$);
SELECT t_logout();

CREATE TEMP TABLE _t63_base AS
SELECT (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('biz')) AS movements,
       (SELECT count(*) FROM inventory_movement_costs WHERE business_id = t_get('biz')) AS movement_costs,
       (SELECT count(*) FROM supplier_account_entries) AS liab_rows,
       (SELECT count(*) FROM goods_receipts) AS receipts,
       (SELECT count(*) FROM inventory_adjustments) AS adjustments,
       (SELECT string_agg(variant_id::text || ':' || on_hand_qty || ':' || total_value_base, ',' ORDER BY variant_id)
          FROM variant_cost_pools WHERE business_id = t_get('biz') AND branch_id = t_get('br63')) AS pools;
GRANT SELECT ON _t63_base TO authenticated;

SELECT t_check('T63 privilege: count tables have no client writes and RPCs are authenticated-only',
  NOT has_table_privilege('authenticated', 'stock_counts', 'INSERT') AND NOT has_table_privilege('authenticated', 'stock_counts', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'stock_count_lines', 'UPDATE') AND NOT has_table_privilege('authenticated', 'stock_count_lines', 'DELETE')
  AND NOT has_table_privilege('authenticated', 'stock_count_scans', 'INSERT')
  AND has_function_privilege('authenticated', 'rpc_stock_count_post(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_stock_count_post(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_stock_count_apply(uuid, uuid, inventory_bucket, integer, integer, uuid, text, timestamptz)', 'EXECUTE'));

-- A) create (stock_staff may), scan, duplicate scan, idempotent replay, undo, conditions
SELECT t_login('u4');
SELECT t_set('sc63', rpc_stock_count_create(t_get('biz'), t_get('br63'), 'full', 'T63 tam sayım'));
SELECT t_check('T63a count created as draft with a document number',
  (SELECT status::text || '/' || count_number FROM stock_counts WHERE id = t_get('sc63')) LIKE 'draft/SC-%');
SELECT t_ok('T63a first scan A', $q$ SELECT rpc_stock_count_scan(t_get('sc63'), t_get('v63a'), 'sellable', 1, '11111111-0000-4000-8000-000000000001', 'test-device', now()) $q$);
SELECT t_check('T63a first scan moves the count to counting', (SELECT status::text FROM stock_counts WHERE id = t_get('sc63')) = 'counting');
SELECT t_ok('T63a duplicate scan A (new event)', $q$ SELECT rpc_stock_count_scan(t_get('sc63'), t_get('v63a'), 'sellable', 1, '11111111-0000-4000-8000-000000000002') $q$);
SELECT t_ok('T63a replay of the first event is a no-op', $q$ SELECT rpc_stock_count_scan(t_get('sc63'), t_get('v63a'), 'sellable', 1, '11111111-0000-4000-8000-000000000001') $q$);
SELECT t_check('T63a repeated scans increment one line, replay ignored',
  t_count($q$ SELECT count(*) FROM stock_count_lines WHERE stock_count_id = t_get('sc63') $q$) = 1
  AND (SELECT counted_quantity FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND variant_id = t_get('v63a')) = 2
  AND t_count($q$ SELECT count(*) FROM stock_count_scans WHERE stock_count_id = t_get('sc63') $q$) = 2);
SELECT t_ok('T63a scan A twice more', $q$ SELECT rpc_stock_count_scan(t_get('sc63'), t_get('v63a'), 'sellable', 2, '11111111-0000-4000-8000-000000000003') $q$);
SELECT t_ok('T63a undo last scan (−1)', $q$ SELECT rpc_stock_count_scan(t_get('sc63'), t_get('v63a'), 'sellable', -1, '11111111-0000-4000-8000-000000000004') $q$);
SELECT t_err('T63a undo below zero refused', $q$ SELECT rpc_stock_count_scan(t_get('sc63'), t_get('v63a'), 'sellable', -9, '11111111-0000-4000-8000-000000000005') $q$, 'INVALID_QTY');
SELECT t_check('T63a A counted = 3 after scans and undo', (SELECT counted_quantity FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND variant_id = t_get('v63a')) = 3);
SELECT t_ok('T63a A manual set to 4', $q$ SELECT rpc_stock_count_set_quantity(t_get('sc63'), t_get('v63a'), 'sellable', 4, '11111111-0000-4000-8000-000000000006') $q$);
SELECT t_ok('T63a B = 3', $q$ SELECT rpc_stock_count_set_quantity(t_get('sc63'), t_get('v63b'), 'sellable', 3, '11111111-0000-4000-8000-000000000007') $q$);
SELECT t_ok('T63a C = 2 (surplus on an empty pool)', $q$ SELECT rpc_stock_count_set_quantity(t_get('sc63'), t_get('v63c'), 'sellable', 2, '11111111-0000-4000-8000-000000000008') $q$);
SELECT t_ok('T63a D sellable = 1', $q$ SELECT rpc_stock_count_set_quantity(t_get('sc63'), t_get('v63d'), 'sellable', 1, '11111111-0000-4000-8000-000000000009') $q$);
SELECT t_ok('T63a D damaged = 2 (same variant, other condition = own line)', $q$ SELECT rpc_stock_count_set_quantity(t_get('sc63'), t_get('v63d'), 'damaged', 2, '11111111-0000-4000-8000-00000000000a') $q$);
SELECT t_check('T63a two distinct lines for D', t_count($q$ SELECT count(*) FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND variant_id = t_get('v63d') $q$) = 2);
SELECT t_err('T63a foreign variant refused', $q$ SELECT rpc_stock_count_scan(t_get('sc63'), t_get('vB'), 'sellable', 1, '11111111-0000-4000-8000-00000000000b') $q$, 'INVALID_VARIANT');
SELECT t_err('T63a event without client id refused', $q$ SELECT rpc_stock_count_scan(t_get('sc63'), t_get('v63a'), 'sellable', 1, NULL) $q$, 'INVALID_EVENT');
SELECT t_logout();

-- B) zero side effect in draft / counting
SELECT t_check('T63b counting wrote no movement, cost, adjustment, receipt or liability',
  (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('biz')) = (SELECT movements FROM _t63_base)
  AND (SELECT count(*) FROM inventory_movement_costs WHERE business_id = t_get('biz')) = (SELECT movement_costs FROM _t63_base)
  AND (SELECT count(*) FROM inventory_adjustments) = (SELECT adjustments FROM _t63_base)
  AND (SELECT count(*) FROM goods_receipts) = (SELECT receipts FROM _t63_base)
  AND (SELECT count(*) FROM supplier_account_entries) = (SELECT liab_rows FROM _t63_base)
  AND (SELECT string_agg(variant_id::text || ':' || on_hand_qty || ':' || total_value_base, ',' ORDER BY variant_id)
         FROM variant_cost_pools WHERE business_id = t_get('biz') AND branch_id = t_get('br63')) = (SELECT pools FROM _t63_base));

-- C) posting requires review; stock_staff may review but not post; sales_staff nothing
SELECT t_login('u2');
SELECT t_err('T63c post before review refused', $q$ SELECT * FROM rpc_stock_count_post(t_get('sc63')) $q$, 'INVALID_STATE');
SELECT t_logout();
SELECT t_login('u4');
SELECT t_ok('T63c stock_staff enters review', $q$ SELECT rpc_stock_count_review(t_get('sc63')) $q$);
SELECT t_check('T63c expected quantities snapshotted (A 5, B 3, C 0, D sell 2, D dmg 1)',
  (SELECT string_agg(pv.sku || '/' || l.bucket::text || '=' || l.expected_quantity, ',' ORDER BY pv.sku, l.bucket)
   FROM stock_count_lines l JOIN product_variants pv ON pv.id = l.variant_id WHERE l.stock_count_id = t_get('sc63'))
  = 'SAY-63-A/sellable=5,SAY-63-B/sellable=3,SAY-63-C/sellable=0,SAY-63-D/sellable=2,SAY-63-D/damaged=1,SAY-63-E/sellable=1',
  (SELECT string_agg(pv.sku || '/' || l.bucket::text || '=' || COALESCE(l.expected_quantity::text, 'null'), ',' ORDER BY pv.sku, l.bucket)
   FROM stock_count_lines l JOIN product_variants pv ON pv.id = l.variant_id WHERE l.stock_count_id = t_get('sc63')));
SELECT t_check('T63c E (on the shelf per ledger, never scanned) became the one unresolved line — not zero',
  t_count($q$ SELECT count(*) FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND counted_quantity IS NULL $q$) = 1
  AND (SELECT variant_id FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND counted_quantity IS NULL) = t_get('v63e'));
SELECT t_err('T63c stock_staff cannot post', $q$ SELECT * FROM rpc_stock_count_post(t_get('sc63')) $q$, '42501');
SELECT t_err('T63c scanning in review is closed', $q$ SELECT rpc_stock_count_scan(t_get('sc63'), t_get('v63a'), 'sellable', 1, '11111111-0000-4000-8000-00000000000c') $q$, 'INVALID_STATE');
SELECT t_logout();
SELECT t_login('u3');
SELECT t_check('T63c sales_staff sees no count', t_count($q$ SELECT count(*) FROM stock_counts $q$) = 0);
SELECT t_err('T63c sales_staff cannot create a count', $q$ SELECT rpc_stock_count_create(t_get('biz'), t_get('br63'), 'full', NULL) $q$, '42501');
SELECT t_err('T63c sales_staff cannot post', $q$ SELECT * FROM rpc_stock_count_post(t_get('sc63')) $q$, '42501');
SELECT t_logout();
SELECT t_check('T63c review wrote no movement',
  (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('biz')) = (SELECT movements FROM _t63_base));

-- D) missing-item rule: unresolved lines block POST; explicit zero resolves them
SELECT t_login('u2');
SELECT t_err('T63d unresolved lines block posting', $q$ SELECT * FROM rpc_stock_count_post(t_get('sc63')) $q$, 'UNRESOLVED_LINES');
SELECT t_ok('T63d back to counting', $q$ SELECT rpc_stock_count_reopen(t_get('sc63')) $q$);
-- confirm every unresolved line as an explicit zero (0 adet olarak doğrula)
DO $$
DECLARE r RECORD; n INT := 0;
BEGIN
  FOR r IN SELECT variant_id, bucket FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND counted_quantity IS NULL LOOP
    n := n + 1;
    PERFORM rpc_stock_count_set_quantity(t_get('sc63'), r.variant_id, r.bucket, 0, ('22222222-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid);
  END LOOP;
END $$;
SELECT t_check('T63d explicit zeros are flagged and no line is unresolved',
  t_count($q$ SELECT count(*) FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND counted_quantity IS NULL $q$) = 0
  AND t_count($q$ SELECT count(*) FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND zero_confirmed AND counted_quantity = 0 $q$) >= 1);
SELECT t_ok('T63d review again', $q$ SELECT rpc_stock_count_review(t_get('sc63')) $q$);

-- E) surplus on an empty pool blocks the whole posting (no silent zero cost), nothing written
SELECT t_err('T63e surplus for C (empty pool) blocks posting', $q$ SELECT * FROM rpc_stock_count_post(t_get('sc63')) $q$, 'COST_REQUIRED');
SELECT t_check('T63e blocked posting wrote nothing and left the count in review',
  (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('biz')) = (SELECT movements FROM _t63_base)
  AND (SELECT status::text FROM stock_counts WHERE id = t_get('sc63')) = 'review');
-- give C a cost the legitimate way (an adjustment with manual cost), then the count is stale
SELECT t_ok('T63e C gets 1 unit @70 through an adjustment', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br63'), t_get('v63c'), 'sellable', 1, 'sayım fixture', 'manual_cost', 70) $q$);
SELECT t_logout();
CREATE TEMP TABLE _t63_base2 AS SELECT (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('biz')) AS movements;
GRANT SELECT ON _t63_base2 TO authenticated;

-- F) stale snapshot: the ledger moved after review → posting refused, nothing written
SELECT t_login('u2');
SELECT t_err('T63f stale count refused after intervening movement', $q$ SELECT * FROM rpc_stock_count_post(t_get('sc63')) $q$, 'STALE_COUNT');
SELECT t_check('T63f stale refusal wrote nothing', (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('biz')) = (SELECT movements FROM _t63_base2));
SELECT t_ok('T63f re-review recomputes the snapshot', $q$ SELECT rpc_stock_count_review(t_get('sc63')) $q$);
SELECT t_check('T63f C expected is now 1', (SELECT expected_quantity FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND variant_id = t_get('v63c')) = 1);

-- G) atomic post: A 4 (−1), B 3 (0), C 2 (+1 at MWA 70), D sellable 1 (−1), D damaged 2 (+1 at MWA 50), E 0 confirmed (−1)
CREATE TEMP TABLE _t63_post AS SELECT * FROM rpc_stock_count_post(t_get('sc63'));
GRANT SELECT ON _t63_post TO authenticated;
SELECT t_logout();
SELECT t_check('T63g post summary: adjustments and units',
  (SELECT adjustments FROM _t63_post) = 5 AND (SELECT shortage_units FROM _t63_post) = 3 AND (SELECT surplus_units FROM _t63_post) = 2);
SELECT t_check('T63g header posted with actor and time',
  (SELECT status::text FROM stock_counts WHERE id = t_get('sc63')) = 'posted'
  AND (SELECT posted_by FROM stock_counts WHERE id = t_get('sc63')) = t_get('u2')
  AND (SELECT posted_at FROM stock_counts WHERE id = t_get('sc63')) IS NOT NULL);
SELECT t_check('T63g ledger quantities after post: A 4, B 3, C 2, D sell 1, D dmg 2',
  fn_bucket_qty(t_get('biz'), t_get('br63'), t_get('v63a'), 'sellable') = 4
  AND fn_bucket_qty(t_get('biz'), t_get('br63'), t_get('v63b'), 'sellable') = 3
  AND fn_bucket_qty(t_get('biz'), t_get('br63'), t_get('v63c'), 'sellable') = 2
  AND fn_bucket_qty(t_get('biz'), t_get('br63'), t_get('v63d'), 'sellable') = 1
  AND fn_bucket_qty(t_get('biz'), t_get('br63'), t_get('v63d'), 'damaged') = 2
  AND fn_bucket_qty(t_get('biz'), t_get('br63'), t_get('v63e'), 'sellable') = 0);
SELECT t_check('T63g exactly five movements, reason adjustment, referencing the lines',
  t_count($q$ SELECT count(*) FROM inventory_movements m JOIN stock_count_lines l ON l.id = m.reference_id AND m.reference_type = 'stock_count_line' WHERE l.stock_count_id = t_get('sc63') AND m.reason = 'adjustment' $q$) = 5
  AND (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('biz')) = (SELECT movements FROM _t63_base2) + 5);
SELECT t_check('T63g lines carry posted_delta and movement_id; zero-difference line has delta 0 and no movement',
  (SELECT posted_delta FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND variant_id = t_get('v63a')) = -1
  AND (SELECT movement_id IS NOT NULL FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND variant_id = t_get('v63a'))
  AND (SELECT posted_delta FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND variant_id = t_get('v63b')) = 0
  AND (SELECT movement_id IS NULL FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND variant_id = t_get('v63b')));
-- cost behaviour: shortage at MWA, surplus at MWA, no supplier entry, no adjustment document
SELECT t_check('T63g A shortage left at MWA 100 → pool 4 / 400',
  (SELECT on_hand_qty || '/' || total_value_base::numeric(12,2) FROM variant_cost_pools WHERE variant_id = t_get('v63a') AND branch_id = t_get('br63')) = '4/400.00');
SELECT t_check('T63g C surplus inherited MWA 70 → pool 2 / 140',
  (SELECT on_hand_qty || '/' || total_value_base::numeric(12,2) FROM variant_cost_pools WHERE variant_id = t_get('v63c') AND branch_id = t_get('br63')) = '2/140.00');
SELECT t_check('T63g E zero-confirmed → pool 0 / 0 (exact depletion)',
  (SELECT on_hand_qty || '/' || total_value_base::numeric(12,2) FROM variant_cost_pools WHERE variant_id = t_get('v63e') AND branch_id = t_get('br63')) = '0/0.00');
SELECT t_check('T63g D −1 sellable +1 damaged at MWA 50 → pool 3 / 150 (net quantity unchanged, value unchanged)',
  (SELECT on_hand_qty || '/' || total_value_base::numeric(12,2) FROM variant_cost_pools WHERE variant_id = t_get('v63d') AND branch_id = t_get('br63')) = '3/150.00');
SELECT t_check('T63g movement cost rows written for the five movements, unit cost = MWA',
  t_count($q$ SELECT count(*) FROM inventory_movement_costs mc JOIN inventory_movements m ON m.id = mc.movement_id WHERE m.reference_type = 'stock_count_line' AND m.reference_id IN (SELECT id FROM stock_count_lines WHERE stock_count_id = t_get('sc63')) $q$) = 5
  AND (SELECT mc.unit_cost_base FROM inventory_movement_costs mc JOIN inventory_movements m ON m.id = mc.movement_id JOIN stock_count_lines l ON l.id = m.reference_id WHERE l.stock_count_id = t_get('sc63') AND l.variant_id = t_get('v63c')) = 70);
SELECT t_check('T63g no supplier entry, receipt or adjustment document from the count',
  (SELECT count(*) FROM supplier_account_entries) = (SELECT liab_rows FROM _t63_base)
  AND (SELECT count(*) FROM goods_receipts) = (SELECT receipts FROM _t63_base)
  AND (SELECT count(*) FROM inventory_adjustments) = (SELECT adjustments FROM _t63_base) + 1);

-- H) idempotency / immutability
SELECT t_login('u2');
SELECT t_err('T63h second post refused as ALREADY_POSTED', $q$ SELECT * FROM rpc_stock_count_post(t_get('sc63')) $q$, 'ALREADY_POSTED');
SELECT t_check('T63h still exactly five count movements', t_count($q$ SELECT count(*) FROM inventory_movements WHERE reference_type = 'stock_count_line' AND reference_id IN (SELECT id FROM stock_count_lines WHERE stock_count_id = t_get('sc63')) $q$) = 5);
SELECT t_err('T63h posted count cannot be reopened', $q$ SELECT rpc_stock_count_reopen(t_get('sc63')) $q$, 'INVALID_STATE');
SELECT t_err('T63h posted count cannot be cancelled', $q$ SELECT rpc_stock_count_cancel(t_get('sc63'), 'x') $q$, 'INVALID_STATE');
SELECT t_err('T63h posted count cannot be scanned', $q$ SELECT rpc_stock_count_scan(t_get('sc63'), t_get('v63a'), 'sellable', 1, '11111111-0000-4000-8000-00000000000d') $q$, 'INVALID_STATE');
SELECT t_logout();
SELECT t_err('T63h posted header immutable even for maintenance', $q$ UPDATE stock_counts SET note = 'x' WHERE id = t_get('sc63') $q$, 'IMMUTABLE');
SELECT t_err('T63h posted line immutable even for maintenance', $q$ UPDATE stock_count_lines SET counted_quantity = 99 WHERE stock_count_id = t_get('sc63') $q$, 'IMMUTABLE');
SELECT t_err('T63h posted line undeletable', $q$ DELETE FROM stock_count_lines WHERE stock_count_id = t_get('sc63') $q$, 'IMMUTABLE');
SELECT t_err('T63h posted header undeletable', $q$ DELETE FROM stock_counts WHERE id = t_get('sc63') $q$, 'IMMUTABLE');
SELECT t_err('T63h a second movement for a posted line is impossible (unique index)',
  $q$ INSERT INTO inventory_movements (business_id, branch_id, variant_id, bucket, quantity, reason, reference_type, reference_id)
      SELECT business_id, t_get('br63'), variant_id, bucket, 1, 'adjustment', 'stock_count_line', id FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND variant_id = t_get('v63a') $q$, '23505');
SELECT t_login('u2');
SELECT t_check('T63h manager cannot update a posted line through the API (no grant)', NOT has_table_privilege('authenticated', 'stock_count_lines', 'UPDATE'));
SELECT t_logout();

-- I) cycle count reconciles only included variants; cancel keeps the document
SELECT t_login('u2');
SELECT t_set('sc63c', rpc_stock_count_create(t_get('biz'), t_get('br63'), 'cycle', 'T63 kısmi sayım'));
SELECT t_ok('T63i cycle: count only B = 2', $q$ SELECT rpc_stock_count_set_quantity(t_get('sc63c'), t_get('v63b'), 'sellable', 2, '33333333-0000-4000-8000-000000000001') $q$);
SELECT t_ok('T63i cycle review', $q$ SELECT rpc_stock_count_review(t_get('sc63c')) $q$);
SELECT t_check('T63i cycle review adds no lines for uncounted stock', t_count($q$ SELECT count(*) FROM stock_count_lines WHERE stock_count_id = t_get('sc63c') $q$) = 1);
CREATE TEMP TABLE _t63_base3 AS SELECT (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('biz')) AS movements;
GRANT SELECT ON _t63_base3 TO authenticated;
SELECT t_ok('T63i cycle post', $q$ SELECT * FROM rpc_stock_count_post(t_get('sc63c')) $q$);
SELECT t_logout();
SELECT t_check('T63i cycle post touched only B (−1), A untouched at 4',
  (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('biz')) = (SELECT movements FROM _t63_base3) + 1
  AND fn_bucket_qty(t_get('biz'), t_get('br63'), t_get('v63b'), 'sellable') = 2
  AND fn_bucket_qty(t_get('biz'), t_get('br63'), t_get('v63a'), 'sellable') = 4);
SELECT t_login('u2');
SELECT t_set('sc63x', rpc_stock_count_create(t_get('biz'), t_get('br63'), 'full', 'T63 iptal'));
SELECT t_ok('T63i scan then cancel', $q$ SELECT rpc_stock_count_scan(t_get('sc63x'), t_get('v63a'), 'sellable', 1, '44444444-0000-4000-8000-000000000001') $q$);
SELECT t_ok('T63i cancel', $q$ SELECT rpc_stock_count_cancel(t_get('sc63x'), 'test iptali') $q$);
SELECT t_check('T63i cancelled count retained with reason and scans, no movement',
  (SELECT status::text || '/' || cancel_reason FROM stock_counts WHERE id = t_get('sc63x')) = 'cancelled/test iptali'
  AND t_count($q$ SELECT count(*) FROM stock_count_scans WHERE stock_count_id = t_get('sc63x') $q$) = 1
  AND (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('biz')) = (SELECT movements FROM _t63_base3) + 1);
SELECT t_err('T63i cancelled count cannot be posted', $q$ SELECT * FROM rpc_stock_count_post(t_get('sc63x')) $q$, 'INVALID_STATE');
SELECT t_err('T63i cancelled count cannot be scanned', $q$ SELECT rpc_stock_count_scan(t_get('sc63x'), t_get('v63a'), 'sellable', 1, '44444444-0000-4000-8000-000000000002') $q$, 'INVALID_STATE');
SELECT t_err('T63i inactive branch refused', $q$ SELECT rpc_stock_count_create(t_get('biz'), t_get('brOff'), 'full', NULL) $q$, 'INVALID_BRANCH');
SELECT t_logout();

-- J) cross-tenant
SELECT t_login('u5');
SELECT t_check('T63j other tenant sees no count of A', t_count($q$ SELECT count(*) FROM stock_counts WHERE business_id = t_get('biz') $q$) = 0
  AND t_count($q$ SELECT count(*) FROM stock_count_lines WHERE business_id = t_get('biz') $q$) = 0);
SELECT t_err('T63j other tenant cannot create a count in A', $q$ SELECT rpc_stock_count_create(t_get('biz'), t_get('br63'), 'full', NULL) $q$, '42501');
SELECT t_err('T63j other tenant cannot use A''s branch with its own business', $q$ SELECT rpc_stock_count_create(t_get('bizB'), t_get('br63'), 'full', NULL) $q$, 'INVALID_BRANCH');
SELECT t_err('T63j other tenant cannot scan / post A''s count', $q$ SELECT rpc_stock_count_scan(t_get('sc63c'), t_get('v63b'), 'sellable', 1, '55555555-0000-4000-8000-000000000001') $q$, '42501');
SELECT t_err('T63j other tenant cannot post A''s count', $q$ SELECT * FROM rpc_stock_count_post(t_get('sc63c')) $q$, '42501');
SELECT t_set('sc63B', rpc_stock_count_create(t_get('bizB'), t_get('brB'), 'cycle', NULL));
SELECT t_err('T63j B cannot count A''s variant in its own count', $q$ SELECT rpc_stock_count_scan(t_get('sc63B'), t_get('v63a'), 'sellable', 1, '55555555-0000-4000-8000-000000000002') $q$, 'INVALID_VARIANT');
SELECT t_logout();
SELECT t_err('T63j business_id of a line cannot point at another tenant (parent trigger)',
  $q$ INSERT INTO stock_count_lines (business_id, stock_count_id, variant_id, bucket) VALUES (t_get('bizB'), t_get('sc63B'), t_get('v63a'), 'sellable') $q$, '23503');
SELECT t_err('T63j a count movement cannot be forged for another tenant''s line',
  $q$ INSERT INTO inventory_movements (business_id, branch_id, variant_id, bucket, quantity, reason, reference_type, reference_id)
      SELECT t_get('bizB'), t_get('brB'), t_get('vB'), 'sellable', 1, 'adjustment', 'stock_count_line', id FROM stock_count_lines WHERE stock_count_id = t_get('sc63') AND variant_id = t_get('v63a') $q$, '23505');

-- ============================================================
-- T64 — Phase 8A goods receiving + landed cost: charges, allocation, review/stale,
--        atomic idempotent POST, liabilities per charge mode, reversal, RLS
-- ============================================================
SELECT t_logout();
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), 'Landed Elbise', 'LND-64', 900, 'active') RETURNING id)
  SELECT t_set('p64', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p64'), 'LND-64-A') RETURNING id) SELECT t_set('v64a', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v64a'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000001');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p64'), 'LND-64-B') RETURNING id) SELECT t_set('v64b', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v64b'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000002');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p64'), 'LND-64-C') RETURNING id) SELECT t_set('v64c', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v64c'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000003');
WITH x AS (INSERT INTO branches (business_id, name, code) VALUES (t_get('biz'), 'Landed Şubesi', 'LND') RETURNING id) SELECT t_set('br64', id) FROM x;
WITH x AS (INSERT INTO suppliers (business_id, name) VALUES (t_get('biz'), 'Kargo Firması 64') RETURNING id) SELECT t_set('sup64k', id) FROM x;

CREATE TEMP TABLE _t64_base AS
SELECT (SELECT count(*) FROM inventory_movements) AS movements,
       (SELECT count(*) FROM supplier_account_entries) AS liab_rows,
       (SELECT COALESCE(sum(amount_base), 0) FROM supplier_account_entries) AS liab_sum,
       (SELECT count(*) FROM variant_cost_pools WHERE branch_id = t_get('br64')) AS pools;
GRANT SELECT ON _t64_base TO authenticated;

SELECT t_check('T64 privilege: charges table-writable (RLS: manager+), reversals RPC-only, internals hidden',
  has_table_privilege('authenticated', 'goods_receipt_charges', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'goods_receipt_reversals', 'INSERT')
  AND NOT has_function_privilege('authenticated', 'fn_goods_receipt_allocation(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_goods_receipt_hash(uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_goods_receipt_review(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_reverse_goods_receipt(uuid, text)', 'EXECUTE'));

-- A) multi-item, multi-charge, value-proportional allocation, TRY
--    stock_staff opens the draft and records the quantities; the manager prices and books
SELECT t_login('u4');
SELECT t_set('gr64', rpc_create_goods_receipt(t_get('br64'), t_get('sup1'), 'TRY', 1, CURRENT_DATE, 'INV-64', 'landed test'));
SELECT t_ok('T64a stock_staff records three quantities', $q$
  SELECT rpc_goods_receipt_upsert_line(t_get('gr64'), t_get('v64a'), 10);
  SELECT rpc_goods_receipt_upsert_line(t_get('gr64'), t_get('v64b'), 5);
  SELECT rpc_goods_receipt_upsert_line(t_get('gr64'), t_get('v64c'), 1) $q$);
SELECT t_err('T64a stock_staff cannot add a charge (manager+ table)', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount) VALUES (t_get('gr64'), 'freight', 1) $q$, '42501');
SELECT t_err('T64a stock_staff cannot change the allocation method', $q$ UPDATE goods_receipts SET allocation_method = 'equal_per_line' WHERE id = t_get('gr64') $q$, '42501');
SELECT t_err('T64a stock_staff gets no preview', $q$ SELECT rpc_goods_receipt_preview(t_get('gr64')) $q$, '42501');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_ok('T64a manager prices the lines', $q$
  SELECT rpc_goods_receipt_upsert_line(t_get('gr64'), t_get('v64a'), 10, 100);   -- 1000
  SELECT rpc_goods_receipt_upsert_line(t_get('gr64'), t_get('v64b'), 5, 200);    -- 1000
  SELECT rpc_goods_receipt_upsert_line(t_get('gr64'), t_get('v64c'), 1, 500) $q$); --  500  → invoice 2500
SELECT t_ok('T64a freight charge, billed on the invoice, landed', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, description, amount, currency, exchange_rate, include_in_landed, liability_mode) VALUES (t_get('gr64'), 'freight', 'nakliye', 250, 'TRY', 1, true, 'add_to_invoice') $q$);
SELECT t_ok('T64a customs charge, billed by another supplier, landed', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, description, amount, currency, exchange_rate, include_in_landed, liability_mode, payee_supplier_id) VALUES (t_get('gr64'), 'customs', 'gümrük', 100, 'TRY', 1, true, 'separate_supplier', t_get('sup64k')) $q$);
SELECT t_ok('T64a bank fee, not landed, no liability', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, description, amount, currency, exchange_rate, include_in_landed, liability_mode) VALUES (t_get('gr64'), 'other', 'banka masrafı', 30, 'TRY', 1, false, 'no_liability') $q$);
SELECT t_err('T64a zero charge refused', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount) VALUES (t_get('gr64'), 'other', 0) $q$, '23514');
SELECT t_err('T64a negative charge refused', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount) VALUES (t_get('gr64'), 'other', -5) $q$, '23514');
SELECT t_err('T64a separate_supplier without payee refused', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount, liability_mode) VALUES (t_get('gr64'), 'other', 5, 'separate_supplier') $q$, '23514');
SELECT t_err('T64a payee from another tenant refused', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount, liability_mode, payee_supplier_id) VALUES (t_get('gr64'), 'other', 5, 'separate_supplier', t_get('supB')) $q$, '23503');
SELECT t_ok('T64a charge with a foreign business_id is accepted…', $q$ INSERT INTO goods_receipt_charges (business_id, goods_receipt_id, kind, amount, liability_mode) VALUES (t_get('bizB'), t_get('gr64'), 'other', 5, 'no_liability') $q$);
SELECT t_check('T64a …but the parent trigger rewrote business_id to the receipt''s tenant', t_count($q$ SELECT count(*) FROM goods_receipt_charges WHERE goods_receipt_id = t_get('gr64') AND business_id <> t_get('biz') $q$) = 0);
DELETE FROM goods_receipt_charges WHERE goods_receipt_id = t_get('gr64') AND amount = 5;

SELECT t_err('T64b post before review refused', $q$ SELECT rpc_post_goods_receipt(t_get('gr64')) $q$, 'NOT_REVIEWED');
SELECT t_check('T64b preview before review: lines computed, review not current',
  (SELECT jsonb_array_length(rpc_goods_receipt_preview(t_get('gr64')) -> 'lines')) = 3
  AND (SELECT (rpc_goods_receipt_preview(t_get('gr64')) ->> 'review_current')::boolean) = false);
CREATE TEMP TABLE _t64_review AS SELECT * FROM rpc_goods_receipt_review(t_get('gr64'));
GRANT SELECT ON _t64_review TO authenticated;
SELECT t_check('T64b review allocates 350 eligible charges by invoice value: A 140, B 140, C 70',
  (SELECT string_agg(pv.sku || '=' || r.allocated_charge_base::numeric(12,2), ',' ORDER BY pv.sku) FROM _t64_review r JOIN product_variants pv ON pv.id = r.variant_id)
  = 'LND-64-A=140.00,LND-64-B=140.00,LND-64-C=70.00');
SELECT t_check('T64b landed unit costs: A 114, B 228, C 570',
  (SELECT string_agg(pv.sku || '=' || r.landed_unit_cost_base::numeric(12,2), ',' ORDER BY pv.sku) FROM _t64_review r JOIN product_variants pv ON pv.id = r.variant_id)
  = 'LND-64-A=114.00,LND-64-B=228.00,LND-64-C=570.00');
SELECT t_check('T64b shares add up to the eligible charge total exactly', (SELECT sum(allocated_charge_base) FROM _t64_review) = 350);
SELECT t_check('T64b preview after review reports the review as current and the same numbers',
  (SELECT (rpc_goods_receipt_preview(t_get('gr64')) ->> 'review_current')::boolean) = true
  AND (SELECT sum((l ->> 'allocated_charge_base')::numeric) FROM jsonb_array_elements(rpc_goods_receipt_preview(t_get('gr64')) -> 'lines') l) = 350);
SELECT t_check('T64b review stamped, nothing posted', (SELECT reviewed_at IS NOT NULL AND review_hash IS NOT NULL AND status = 'draft' FROM goods_receipts WHERE id = t_get('gr64'))
  AND (SELECT count(*) FROM inventory_movements) = (SELECT movements FROM _t64_base)
);

-- C) stale draft: an edit after review invalidates it
SELECT t_ok('T64c edit a line after review', $q$ UPDATE goods_receipt_items SET quantity = 11 WHERE goods_receipt_id = t_get('gr64') AND variant_id = t_get('v64a') $q$);
SELECT t_check('T64c preview flags the review as no longer current', (SELECT (rpc_goods_receipt_preview(t_get('gr64')) ->> 'review_current')::boolean) = false);
SELECT t_err('T64c posting an edited draft on the old review refused', $q$ SELECT rpc_post_goods_receipt(t_get('gr64')) $q$, 'STALE_DRAFT');
SELECT t_ok('T64c undo the edit', $q$ UPDATE goods_receipt_items SET quantity = 10 WHERE goods_receipt_id = t_get('gr64') AND variant_id = t_get('v64a') $q$);
SELECT t_ok('T64c review again', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr64')) $q$);
SELECT t_ok('T64c a charge edit also invalidates', $q$ UPDATE goods_receipt_charges SET amount = 260 WHERE goods_receipt_id = t_get('gr64') AND kind = 'freight' $q$);
SELECT t_err('T64c stale after charge edit', $q$ SELECT rpc_post_goods_receipt(t_get('gr64')) $q$, 'STALE_DRAFT');
SELECT t_ok('T64c restore charge and review', $q$ UPDATE goods_receipt_charges SET amount = 250 WHERE goods_receipt_id = t_get('gr64') AND kind = 'freight'; SELECT * FROM rpc_goods_receipt_review(t_get('gr64')) $q$);
SELECT t_check('T64c nothing posted through all of that', (SELECT count(*) FROM inventory_movements) = (SELECT movements FROM _t64_base));

-- D) POST: landed cost into items, pools, ledger; liabilities per mode; idempotent
SELECT t_ok('T64d post', $q$ SELECT rpc_post_goods_receipt(t_get('gr64')) $q$);
SELECT t_err('T64d second post refused', $q$ SELECT rpc_post_goods_receipt(t_get('gr64')) $q$, 'INVALID_STATE');
SELECT t_err('T64d review of a posted receipt refused', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr64')) $q$, 'INVALID_STATE');
SELECT t_err('T64d charges of a posted receipt frozen', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount) VALUES (t_get('gr64'), 'other', 5) $q$, 'IMMUTABLE');
SELECT t_check('T64d manager reads the posted financials through the RPC: landed 2850, 3 priced items',
  (SELECT (f ->> 'posted_landed_total_base')::numeric = 2850 AND (f ->> 'missing_cost_lines')::int = 0 AND jsonb_array_length(f -> 'items') = 3
   FROM rpc_goods_receipt_financial(t_get('gr64')) f));
SELECT t_check('T64d list totals RPC: invoice 2500',
  (SELECT total_original FROM rpc_goods_receipt_list_totals(ARRAY[t_get('gr64')])) = 2500);
SELECT t_logout();
SELECT t_check('T64d items carry landed values',
  (SELECT string_agg(pv.sku || '=' || i.allocated_charge_base::numeric(12,2) || '/' || i.landed_unit_cost_base::numeric(12,2) || '/' || i.landed_total_cost_base::numeric(12,2), ',' ORDER BY pv.sku)
   FROM goods_receipt_items i JOIN product_variants pv ON pv.id = i.variant_id WHERE i.goods_receipt_id = t_get('gr64'))
  = 'LND-64-A=140.00/114.00/1140.00,LND-64-B=140.00/228.00/1140.00,LND-64-C=70.00/570.00/570.00');
SELECT t_check('T64d header totals: invoice 2500, charges 350, landed 2850',
  (SELECT posted_invoice_total_original || '/' || posted_charges_base::numeric(12,2) || '/' || posted_landed_total_base::numeric(12,2) FROM goods_receipts WHERE id = t_get('gr64')) = '2500.00/350.00/2850.00');
SELECT t_check('T64d pools hold landed value (MWA = landed unit cost)',
  (SELECT string_agg(pv.sku || '=' || p.on_hand_qty || '@' || (p.total_value_base / p.on_hand_qty)::numeric(12,2), ',' ORDER BY pv.sku)
   FROM variant_cost_pools p JOIN product_variants pv ON pv.id = p.variant_id WHERE p.branch_id = t_get('br64'))
  = 'LND-64-A=10@114.00,LND-64-B=5@228.00,LND-64-C=1@570.00');
SELECT t_check('T64d ledger rows carry the landed unit cost',
  (SELECT string_agg(pv.sku || '=' || mc.unit_cost_base::numeric(12,2), ',' ORDER BY pv.sku)
   FROM inventory_movements m JOIN inventory_movement_costs mc ON mc.movement_id = m.id JOIN goods_receipt_items i ON i.id = m.reference_id AND m.reference_type = 'goods_receipt_item'
   JOIN product_variants pv ON pv.id = m.variant_id WHERE i.goods_receipt_id = t_get('gr64'))
  = 'LND-64-A=114.00,LND-64-B=228.00,LND-64-C=570.00');
SELECT t_check('T64d supplier liability = invoice 2500 + freight 250 = 2750 (one entry), customs 100 to the carrier, bank fee nowhere',
  (SELECT amount_original FROM supplier_account_entries WHERE reference_type = 'goods_receipt' AND reference_id = t_get('gr64')) = 2750
  AND t_count($q$ SELECT count(*) FROM supplier_account_entries WHERE reference_type = 'goods_receipt' AND reference_id = t_get('gr64') $q$) = 1
  AND (SELECT amount_original || '/' || supplier_id::text FROM supplier_account_entries WHERE reference_type = 'goods_receipt_charge') = '100.00/' || t_get('sup64k')::text
  AND (SELECT count(*) FROM supplier_account_entries) = (SELECT liab_rows FROM _t64_base) + 2);
SELECT t_check('T64d inventory value (2850) ≠ supplier liability (2750 + 100): valuation and debt are separate',
  (SELECT sum(total_value_base) FROM variant_cost_pools WHERE branch_id = t_get('br64')) = 2850
  AND (SELECT sum(amount_base) FROM supplier_account_entries) = (SELECT liab_sum FROM _t64_base) + 2850);

-- E) other allocation methods, FX, zero-cost basis, rounding remainder
SELECT t_login('u2');
SELECT t_set('gr64q', rpc_create_goods_receipt(t_get('br64'), t_get('sup2'), 'GBP', 40, CURRENT_DATE, 'INV-64Q', NULL));
INSERT INTO goods_receipt_items (goods_receipt_id, variant_id, quantity, unit_cost) VALUES (t_get('gr64q'), t_get('v64a'), 3, 10), (t_get('gr64q'), t_get('v64b'), 1, 10);
SELECT t_check('T64e manager may still write a priced line directly (trigger guard passes)', t_count($q$ SELECT count(*) FROM goods_receipt_items WHERE goods_receipt_id = t_get('gr64q') $q$) = 2);
SELECT t_err('T64e even a manager cannot SELECT the cost column directly (column privilege)', $q$ SELECT unit_cost FROM goods_receipt_items WHERE goods_receipt_id = t_get('gr64q') $q$, '42501');
SELECT t_ok('T64e charge in TRY on a GBP invoice must not be billed on the invoice', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount, currency, exchange_rate, liability_mode) VALUES (t_get('gr64q'), 'freight', 1000, 'TRY', 1, 'no_liability') $q$);
SELECT t_ok('T64e quantity allocation', $q$ UPDATE goods_receipts SET allocation_method = 'quantity_proportional' WHERE id = t_get('gr64q') $q$);
CREATE TEMP TABLE _t64_q AS SELECT * FROM rpc_goods_receipt_review(t_get('gr64q'));
GRANT SELECT ON _t64_q TO authenticated;
SELECT t_check('T64e quantity-proportional: 3/4 and 1/4 of 1000 → 750 / 250; landed unit 650 / 650 (GBP 10 @40 = 400 + 250)',
  (SELECT string_agg(pv.sku || '=' || r.allocated_charge_base::numeric(12,2) || '/' || r.landed_unit_cost_base::numeric(12,2), ',' ORDER BY pv.sku) FROM _t64_q r JOIN product_variants pv ON pv.id = r.variant_id)
  = 'LND-64-A=750.00/650.00,LND-64-B=250.00/650.00');
SELECT t_ok('T64e equal allocation', $q$ UPDATE goods_receipts SET allocation_method = 'equal_per_line' WHERE id = t_get('gr64q') $q$);
SELECT t_check('T64e equal per line: 500 / 500',
  (SELECT string_agg(r.allocated_charge_base::numeric(12,2)::text, ',' ORDER BY r.variant_id) FROM rpc_goods_receipt_review(t_get('gr64q')) r) = '500.00,500.00');
SELECT t_err('T64e manual allocation is architected but refused', $q$ UPDATE goods_receipts SET allocation_method = 'manual' WHERE id = t_get('gr64q'); SELECT * FROM rpc_goods_receipt_review(t_get('gr64q')) $q$, 'NOT_IMPLEMENTED');
SELECT t_ok('T64e back to value allocation', $q$ UPDATE goods_receipts SET allocation_method = 'invoice_value_proportional' WHERE id = t_get('gr64q') $q$);
SELECT t_ok('T64e a charge billed on a GBP invoice in TRY is refused at review', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount, currency, exchange_rate, liability_mode) VALUES (t_get('gr64q'), 'handling', 5, 'TRY', 1, 'add_to_invoice') $q$);
SELECT t_err('T64e …CHARGE_CURRENCY', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr64q')) $q$, 'CHARGE_CURRENCY');
DELETE FROM goods_receipt_charges WHERE goods_receipt_id = t_get('gr64q') AND kind = 'handling';
-- rounding remainder: 1000 over 3 equal lines
SELECT t_set('gr64r', rpc_create_goods_receipt(t_get('br64'), t_get('sup1'), 'TRY', 1, CURRENT_DATE, 'INV-64R', NULL));
INSERT INTO goods_receipt_items (goods_receipt_id, variant_id, quantity, unit_cost) VALUES (t_get('gr64r'), t_get('v64a'), 1, 10), (t_get('gr64r'), t_get('v64b'), 1, 10), (t_get('gr64r'), t_get('v64c'), 1, 10);
INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount, liability_mode) VALUES (t_get('gr64r'), 'freight', 1000, 'no_liability');
SELECT t_check('T64e remainder folded: three shares sum to exactly 1000',
  (SELECT sum(allocated_charge_base) FROM rpc_goods_receipt_review(t_get('gr64r'))) = 1000
  AND (SELECT max(allocated_charge_base) - min(allocated_charge_base) FROM rpc_goods_receipt_review(t_get('gr64r'))) < 0.000002);
-- zero-cost lines with value allocation
SELECT t_set('gr64z', rpc_create_goods_receipt(t_get('br64'), t_get('sup1'), 'TRY', 1, CURRENT_DATE, 'INV-64Z', NULL));
INSERT INTO goods_receipt_items (goods_receipt_id, variant_id, quantity, unit_cost) VALUES (t_get('gr64z'), t_get('v64a'), 2, 0);
INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount, liability_mode) VALUES (t_get('gr64z'), 'freight', 50, 'no_liability');
SELECT t_err('T64e value allocation over zero-cost lines refused (no silent basis)', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr64z')) $q$, 'ALLOCATION_BASIS');
SELECT t_ok('T64e quantity allocation carries the charge onto the free goods', $q$ UPDATE goods_receipts SET allocation_method = 'quantity_proportional' WHERE id = t_get('gr64z'); SELECT * FROM rpc_goods_receipt_review(t_get('gr64z')) $q$);
SELECT t_check('T64e free goods land at 25 each', (SELECT landed_unit_cost_base FROM rpc_goods_receipt_review(t_get('gr64z'))) = 25);
SELECT t_logout();

-- F) roles / cross-tenant
SELECT t_login('u3');
SELECT t_check('T64f sales_staff sees no charges', t_count($q$ SELECT count(*) FROM goods_receipt_charges $q$) = 0);
SELECT t_err('T64f sales_staff cannot review', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr64q')) $q$, '42501');
SELECT t_err('T64f sales_staff cannot reverse', $q$ SELECT rpc_reverse_goods_receipt(t_get('gr64'), 'test') $q$, '42501');
SELECT t_logout();
SELECT t_login('u4');
SELECT t_err('T64f stock_staff cannot reverse (manager+)', $q$ SELECT rpc_reverse_goods_receipt(t_get('gr64'), 'test') $q$, '42501');
SELECT t_check('T64f stock_staff sees no charges at all', t_count($q$ SELECT count(*) FROM goods_receipt_charges $q$) = 0);
SELECT t_err('T64f stock_staff cannot read posted totals', $q$ SELECT posted_landed_total_base FROM goods_receipts WHERE id = t_get('gr64') $q$, '42501');
SELECT t_err('T64f stock_staff cannot read landed cost', $q$ SELECT landed_unit_cost_base FROM goods_receipt_items WHERE goods_receipt_id = t_get('gr64') $q$, '42501');
SELECT t_err('T64f stock_staff cannot read the list totals', $q$ SELECT * FROM rpc_goods_receipt_list_totals(ARRAY[t_get('gr64')]) $q$, '42501');
SELECT t_check('T64f stock_staff still sees the operational document (number, status, lines, quantities)',
  (SELECT status = 'posted' FROM goods_receipts WHERE id = t_get('gr64'))
  AND t_count($q$ SELECT sum(quantity) FROM goods_receipt_items WHERE goods_receipt_id = t_get('gr64') $q$) = 16);
SELECT t_logout();
SELECT t_login('u5');
SELECT t_check('T64f other tenant sees nothing of the receipt', t_count($q$ SELECT count(*) FROM goods_receipt_charges WHERE goods_receipt_id = t_get('gr64') $q$) = 0
  AND t_count($q$ SELECT count(*) FROM goods_receipt_reversals $q$) = 0);
SELECT t_err('T64f other tenant cannot review A''s draft', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr64q')) $q$, '42501');
SELECT t_err('T64f other tenant cannot post A''s draft', $q$ SELECT rpc_post_goods_receipt(t_get('gr64q')) $q$, '42501');
SELECT t_err('T64f other tenant cannot reverse A''s receipt', $q$ SELECT rpc_reverse_goods_receipt(t_get('gr64'), 'test') $q$, '42501');
SELECT t_err('T64f other tenant insert on A''s draft refused (parent invisible under RLS)', $q$ INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount) VALUES (t_get('gr64q'), 'other', 5) $q$, 'not found');
SELECT t_logout();

-- G) reversal: goods out at MWA, liabilities credited, once
SELECT t_login('u2');
CREATE TEMP TABLE _t64_pre AS SELECT (SELECT count(*) FROM inventory_movements) AS movements, (SELECT count(*) FROM supplier_account_entries) AS liab_rows;
GRANT SELECT ON _t64_pre TO authenticated;
SELECT t_err('T64g reversal needs a reason', $q$ SELECT rpc_reverse_goods_receipt(t_get('gr64'), NULL) $q$, 'REASON_REQUIRED');
SELECT t_err('T64g a draft cannot be reversed', $q$ SELECT rpc_reverse_goods_receipt(t_get('gr64q'), 'yanlış') $q$, 'INVALID_STATE');
SELECT t_set('rev64', rpc_reverse_goods_receipt(t_get('gr64'), 'fatura iptal edildi'));
SELECT t_err('T64g second reversal refused', $q$ SELECT rpc_reverse_goods_receipt(t_get('gr64'), 'tekrar') $q$, 'ALREADY_REVERSED');
SELECT t_logout();
SELECT t_check('T64g receipt row untouched (still posted, same totals)',
  (SELECT status::text || '/' || posted_landed_total_base::numeric(12,2) FROM goods_receipts WHERE id = t_get('gr64')) = 'posted/2850.00');
SELECT t_check('T64g reversal row recorded with the value removed',
  (SELECT reason || '/' || value_removed_base::numeric(12,2) || '/' || (reversed_by = t_get('u2'))::text FROM goods_receipt_reversals WHERE goods_receipt_id = t_get('gr64')) = 'fatura iptal edildi/2850.00/true');
SELECT t_check('T64g pools back to zero, exact depletion',
  (SELECT sum(on_hand_qty) || '/' || sum(total_value_base)::numeric(12,2) FROM variant_cost_pools WHERE branch_id = t_get('br64')) = '0/0.00');
SELECT t_check('T64g three reversal movements, one per item, negative, referencing the items',
  t_count($q$ SELECT count(*) FROM inventory_movements m JOIN goods_receipt_items i ON i.id = m.reference_id AND m.reference_type = 'goods_receipt_reversal_item' WHERE i.goods_receipt_id = t_get('gr64') AND m.quantity < 0 $q$) = 3
  AND (SELECT count(*) FROM inventory_movements) = (SELECT movements FROM _t64_pre) + 3);
SELECT t_check('T64g liabilities credited: −2750 to the invoice supplier, −100 to the carrier',
  (SELECT string_agg(amount_original::text, ',' ORDER BY amount_original) FROM supplier_account_entries WHERE reference_type = 'goods_receipt_reversal' AND reference_id = t_get('rev64')) = '-2750.00,-100.00'
  AND (SELECT count(*) FROM supplier_account_entries) = (SELECT liab_rows FROM _t64_pre) + 2
  AND (SELECT sum(amount_base) FROM supplier_account_entries) = (SELECT liab_sum FROM _t64_base));
SELECT t_err('T64g reversal rows immutable', $q$ DELETE FROM goods_receipt_reversals WHERE goods_receipt_id = t_get('gr64') $q$, 'IMMUTABLE');
SELECT t_err('T64g a second reversal movement for an item is impossible (unique index)',
  $q$ INSERT INTO inventory_movements (business_id, branch_id, variant_id, bucket, quantity, reason, reference_type, reference_id)
      SELECT business_id, t_get('br64'), variant_id, 'sellable', -1, 'goods_receipt', 'goods_receipt_reversal_item', id FROM goods_receipt_items WHERE goods_receipt_id = t_get('gr64') AND variant_id = t_get('v64a') $q$, '23505');
-- reversal refused when the goods are gone
SELECT t_login('u2');
SELECT t_ok('T64g post the GBP receipt', $q$ SELECT * FROM rpc_goods_receipt_review(t_get('gr64q')); SELECT rpc_post_goods_receipt(t_get('gr64q')) $q$);
SELECT t_ok('T64g sell/adjust the goods away', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br64'), t_get('v64a'), 'sellable', -3, 'test tüketimi', 'current_mwa') $q$);
SELECT t_err('T64g reversal refused once the goods left', $q$ SELECT rpc_reverse_goods_receipt(t_get('gr64q'), 'çok geç') $q$, 'INSUFFICIENT_STOCK');
SELECT t_check('T64g refused reversal wrote nothing', t_count($q$ SELECT count(*) FROM goods_receipt_reversals WHERE goods_receipt_id = t_get('gr64q') $q$) = 0);
SELECT t_logout();

-- H) cost visibility after the reversal: the value removed is manager+ only, the fact is operational
SELECT t_login('u4');
SELECT t_check('T64h stock_staff sees that the receipt was reversed (reason, when) …', (SELECT reason = 'fatura iptal edildi' AND reversed_at IS NOT NULL FROM goods_receipt_reversals WHERE goods_receipt_id = t_get('gr64')));
SELECT t_err('T64h …but not the value removed', $q$ SELECT value_removed_base FROM goods_receipt_reversals WHERE goods_receipt_id = t_get('gr64') $q$, '42501');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_check('T64h manager reads the value removed through the financial RPC', (SELECT (rpc_goods_receipt_financial(t_get('gr64')) ->> 'reversal_value_removed_base')::numeric) = 2850);
SELECT t_logout();
SELECT t_login('u3');
SELECT t_err('T64h sales_staff: no lines, no RPCs', $q$ SELECT rpc_goods_receipt_upsert_line(t_get('gr64q'), t_get('v64a'), 1) $q$, '42501');
SELECT t_err('T64h sales_staff cannot read financials', $q$ SELECT rpc_goods_receipt_financial(t_get('gr64')) $q$, '42501');
SELECT t_check('T64h sales_staff sees no receipts or lines', t_count($q$ SELECT count(*) FROM goods_receipts $q$) = 0 AND t_count($q$ SELECT count(*) FROM goods_receipt_items $q$) = 0);
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T64h other tenant cannot read A''s financials', $q$ SELECT rpc_goods_receipt_financial(t_get('gr64')) $q$, '42501');
SELECT t_err('T64h other tenant cannot add a line to A''s draft', $q$ SELECT rpc_goods_receipt_upsert_line(t_get('gr64q'), t_get('v64a'), 1) $q$, '42501');
SELECT t_err('T64h other tenant gets no list totals for A', $q$ SELECT * FROM rpc_goods_receipt_list_totals(ARRAY[t_get('gr64')]) $q$, '42501');
SELECT t_logout();

-- ============================================================
-- T66 — Phase 9A POS foundation: register/session, cashier vs salesperson, role model,
--        atomic sale via rpc_pos_complete_sale, stock buckets, COGS history, payments,
--        double submit, zero side effects, immutability, visibility
-- ============================================================
SELECT t_logout();
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), 'POS Elbise', 'POS-66', 250, 'active') RETURNING id)
  SELECT t_set('p66', id) FROM x;
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), 'POS Etek', 'POS-66E', 400, 'active') RETURNING id)
  SELECT t_set('p66e', id) FROM x;
-- A 5 @100 · B 2 · C 1 · D 0 · E damaged only (option values keep the variant fingerprints distinct)
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p66'), 'POS-66-A') RETURNING id) SELECT t_set('v66a', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v66a'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000001');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p66'), 'POS-66-B') RETURNING id) SELECT t_set('v66b', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v66b'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000002');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p66'), 'POS-66-C') RETURNING id) SELECT t_set('v66c', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v66c'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000003');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p66e'), 'POS-66E-D') RETURNING id) SELECT t_set('v66d', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v66d'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000001');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p66e'), 'POS-66E-E') RETURNING id) SELECT t_set('v66e', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v66e'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000002');
INSERT INTO barcodes (variant_id, barcode, barcode_type, symbology, is_primary) VALUES (t_get('v66a'), '0066000000019', 'supplier', 'EAN13', true);
WITH x AS (INSERT INTO branches (business_id, name, code) VALUES (t_get('biz'), 'POS Şubesi', 'POS') RETURNING id) SELECT t_set('br66', id) FROM x;
WITH x AS (INSERT INTO cash_registers (business_id, branch_id, name, device_ref) VALUES (t_get('biz'), t_get('br66'), 'Kasa 66', 'tablet-66') RETURNING id) SELECT t_set('reg66', id) FROM x;
WITH x AS (INSERT INTO cash_registers (business_id, branch_id, name) VALUES (t_get('biz'), t_get('br1'), 'Kasa 66 diğer şube') RETURNING id) SELECT t_set('reg66b', id) FROM x;
WITH x AS (INSERT INTO customers (business_id, full_name, phone) VALUES (t_get('biz'), 'POS Müşteri', '+90 555 066 0066') RETURNING id) SELECT t_set('cust66', id) FROM x;
WITH x AS (INSERT INTO customers (business_id, full_name, phone) VALUES (t_get('bizB'), 'B Müşteri', '+90 555 066 0099') RETURNING id) SELECT t_set('custB', id) FROM x;

SELECT t_login('u2');
SELECT t_ok('T66 fixture stock: A 5@100, B 2@80, C 1@60, E damaged 3', $q$
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br66'), t_get('v66a'), 'sellable', 5, 'pos fixture', 'manual_cost', 100);
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br66'), t_get('v66b'), 'sellable', 2, 'pos fixture', 'manual_cost', 80);
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br66'), t_get('v66c'), 'sellable', 1, 'pos fixture', 'manual_cost', 60);
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br66'), t_get('v66e'), 'damaged', 3, 'pos fixture', 'manual_cost', 50) $q$);
-- session opened by the MANAGER; the cashier below is sales_staff
SELECT t_set('sess66', rpc_open_register_session(t_get('reg66'), '[{"currency":"TRY","amount":300}]'::jsonb));
SELECT t_set('sess66b', rpc_open_register_session(t_get('reg66b'), '[]'::jsonb));
SELECT t_logout();

CREATE TEMP TABLE _t66_base AS
SELECT (SELECT count(*) FROM sales) AS sales, (SELECT count(*) FROM sale_items) AS items, (SELECT count(*) FROM sale_payments) AS pays,
       (SELECT count(*) FROM inventory_movements) AS movements, (SELECT count(*) FROM inventory_movement_costs) AS mcosts,
       (SELECT count(*) FROM cash_movements) AS cash, (SELECT count(*) FROM sale_item_costs) AS sic,
       (SELECT COALESCE(sum(on_hand_qty),0) FROM variant_cost_pools WHERE branch_id = t_get('br66')) AS on_hand;
GRANT SELECT ON _t66_base TO authenticated;
CREATE FUNCTION t66_unchanged() RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER AS $$
  SELECT (SELECT count(*) FROM sales) = (SELECT sales FROM _t66_base)
     AND (SELECT count(*) FROM sale_items) = (SELECT items FROM _t66_base)
     AND (SELECT count(*) FROM sale_payments) = (SELECT pays FROM _t66_base)
     AND (SELECT count(*) FROM inventory_movements) = (SELECT movements FROM _t66_base)
     AND (SELECT count(*) FROM inventory_movement_costs) = (SELECT mcosts FROM _t66_base)
     AND (SELECT count(*) FROM cash_movements) = (SELECT cash FROM _t66_base)
     AND (SELECT count(*) FROM sale_item_costs) = (SELECT sic FROM _t66_base)
     AND (SELECT COALESCE(sum(on_hand_qty),0) FROM variant_cost_pools WHERE branch_id = t_get('br66')) = (SELECT on_hand FROM _t66_base) $$;

-- A) privileges + role model
SELECT t_check('T66a privileges: POS RPCs to authenticated only, cores hidden',
  has_function_privilege('authenticated', 'rpc_pos_complete_sale(uuid,jsonb,jsonb,uuid,uuid,uuid,discount_reason,text,text,uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_pos_complete_sale(uuid,jsonb,jsonb,uuid,uuid,uuid,discount_reason,text,text,uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_pos_members(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_sale_core(uuid,uuid,uuid,uuid,uuid,uuid,text,timestamptz,jsonb,jsonb,discount_reason,text,numeric,uuid,uuid,text,uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_sale_core(uuid,uuid,uuid,uuid,uuid,uuid,text,timestamptz,jsonb,jsonb,discount_reason,text,numeric,uuid,uuid,text)', 'EXECUTE'));
SELECT t_login('u4');
SELECT t_check('T66a stock_staff sees the open session (operational) …', t_count($q$ SELECT count(*) FROM register_sessions WHERE id = t_get('sess66') $q$) = 1);
SELECT t_err('T66a …but cannot complete a sale', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) $q$, 'stock_staff cannot complete sales');
SELECT t_err('T66a …nor through the older rpc_process_sale', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br66'), t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250)) $q$, 'stock_staff cannot complete sales');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T66a other tenant cannot sell on A''s session', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) $q$, 'FORBIDDEN');
SELECT t_check('T66a other tenant sees no registers/sessions of A', t_count($q$ SELECT count(*) FROM cash_registers WHERE business_id = t_get('biz') $q$) = 0
  AND t_count($q$ SELECT count(*) FROM register_sessions WHERE business_id = t_get('biz') $q$) = 0);
SELECT t_logout();
SELECT t_check('T66a nothing written by the refused attempts', t66_unchanged());

-- B) sales_staff cashier: session visibility, member directory, validation failures (all zero side effect)
SELECT t_login('u3');
SELECT t_check('T66b cashier sees the session the manager opened', t_count($q$ SELECT count(*) FROM register_sessions WHERE id = t_get('sess66') AND status = 'open' $q$) = 1);
SELECT t_check('T66b …but not the manager''s drawer counts', t_count($q$ SELECT count(*) FROM register_session_currency_counts WHERE register_session_id = t_get('sess66') $q$) = 0);
SELECT t_check('T66b member directory: names + can_sell only (stock_staff cannot be credited)',
  (SELECT count(*) FILTER (WHERE can_sell) >= 3 AND count(*) FILTER (WHERE NOT can_sell AND user_id = t_get('u4')) = 1 FROM rpc_pos_members(t_get('biz')))
  AND t_count($q$ SELECT count(*) FROM business_members WHERE business_id = t_get('biz') $q$) = 1);
SELECT t_err('T66b client_transaction_id is mandatory on the POS entry point', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250), NULL) $q$, 'CLIENT_TRANSACTION_REQUIRED');
SELECT t_err('T66b unknown session', $q$ SELECT rpc_pos_complete_sale(gen_random_uuid(), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) $q$, 'INVALID_REGISTER_SESSION');
SELECT t_err('T66b variant of another tenant', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('vB','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) $q$, 'INVALID_VARIANT');
SELECT t_err('T66b out of stock (D has 0)', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66d','1',NULL), t_pay('cash','TRY',400), gen_random_uuid()) $q$, 'INSUFFICIENT_STOCK');
SELECT t_err('T66b damaged-only stock is not sellable (E)', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66e','1',NULL), t_pay('cash','TRY',400), gen_random_uuid()) $q$, 'INSUFFICIENT_STOCK');
SELECT t_err('T66b more than available (A has 5)', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','6',NULL), t_pay('cash','TRY',1500), gen_random_uuid()) $q$, 'INSUFFICIENT_STOCK');
SELECT t_err('T66b payment short', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',200), gen_random_uuid()) $q$, 'PAYMENT_SHORT');
SELECT t_err('T66b card overpayment has no change', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('card','TRY',300), gen_random_uuid()) $q$, 'PAYMENT_MISMATCH');
SELECT t_err('T66b zero-amount payment', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',0), gen_random_uuid()) $q$, 'INVALID_PAYMENT');
SELECT t_err('T66b client cannot lower the price (0% discount authority)', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1','200'), t_pay('cash','TRY',200), gen_random_uuid()) $q$, 'DISCOUNT_NOT_AUTHORIZED');
SELECT t_err('T66b client cannot raise the price', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1','300'), t_pay('cash','TRY',300), gen_random_uuid()) $q$, 'INVALID_PRICE');
SELECT t_err('T66b stale client price refused', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), jsonb_build_array(jsonb_build_object('variant_id', t_get('v66a'), 'quantity', 1, 'expected_list_price', 240)), t_pay('cash','TRY',240), gen_random_uuid()) $q$, 'PRICE_CHANGED');
SELECT t_err('T66b empty cart', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), '[]'::jsonb, t_pay('cash','TRY',1), gen_random_uuid()) $q$, 'EMPTY_CART');
SELECT t_err('T66b duplicate lines must be merged', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL) || t_json_items('v66a','1',NULL), t_pay('cash','TRY',500), gen_random_uuid()) $q$, 'DUPLICATE_ITEM');
SELECT t_err('T66b salesperson must be a selling member (stock_staff refused)', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250), gen_random_uuid(), NULL, t_get('u4')) $q$, 'INVALID_SALESPERSON');
SELECT t_err('T66b salesperson from another tenant refused', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250), gen_random_uuid(), NULL, t_get('u5')) $q$, 'INVALID_SALESPERSON');
SELECT t_err('T66b customer of another tenant refused', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250), gen_random_uuid(), t_get('custB')) $q$, 'INVALID_CUSTOMER');
SELECT t_err('T66b sales_staff cannot insert a sale directly', $q$ INSERT INTO sales (business_id, branch_id, register_session_id, sale_number, subtotal, total, sold_by, salesperson_id) VALUES (t_get('biz'), t_get('br66'), t_get('sess66'), 'S-X', 1, 1, t_get('u3'), t_get('u3')) $q$, '42501');
SELECT t_check('T66b every refused sale left nothing behind (atomicity)', t66_unchanged());

-- C) cash sale, cashier ≠ salesperson, COGS at MWA 100
SELECT t_set('ct66a', gen_random_uuid());
CREATE TEMP TABLE _t66_r1 AS SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','2',NULL), t_pay('cash','TRY',500), t_get('ct66a'), t_get('cust66'), t_get('u2')) AS r;
GRANT SELECT ON _t66_r1 TO authenticated;
SELECT t_set('sale66a', (SELECT (r ->> 'sale_id')::uuid FROM _t66_r1));
SELECT t_check('T66c cash sale completed: total 500, no change, not replayed', (SELECT (r ->> 'total')::numeric = 500 AND (r ->> 'change_given')::numeric = 0 AND (r ->> 'replayed')::boolean = false FROM _t66_r1));
SELECT t_check('T66c cashier = sales_staff actor, salesperson = the manager chosen',
  (SELECT sold_by = t_get('u3') AND salesperson_id = t_get('u2') AND customer_id = t_get('cust66') AND status = 'completed' FROM sales WHERE id = t_get('sale66a')));
SELECT t_check('T66c sales_staff sees no cost of its own sale', t_count($q$ SELECT count(*) FROM sale_item_costs $q$) = 0 AND t_count($q$ SELECT count(*) FROM sale_costs $q$) = 0
  AND t_count($q$ SELECT count(*) FROM inventory_movement_costs $q$) = 0 AND t_count($q$ SELECT count(*) FROM variant_cost_pools $q$) = 0);
-- N) double submit: same client_transaction_id + same payload replays, nothing new written
CREATE TEMP TABLE _t66_pre_dup AS SELECT (SELECT count(*) FROM sales) AS sales, (SELECT count(*) FROM inventory_movements) AS movements;
GRANT SELECT ON _t66_pre_dup TO authenticated;
CREATE TEMP TABLE _t66_dup AS SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','2',NULL), t_pay('cash','TRY',500), t_get('ct66a'), t_get('cust66'), t_get('u2')) AS r;
GRANT SELECT ON _t66_dup TO authenticated;
SELECT t_check('T66n double submit replays the first result', (SELECT (r ->> 'replayed')::boolean AND (r ->> 'sale_id')::uuid = t_get('sale66a') FROM _t66_dup));
SELECT t_check('T66n …and wrote nothing', (SELECT count(*) FROM sales) = (SELECT sales FROM _t66_pre_dup) AND (SELECT count(*) FROM inventory_movements) = (SELECT movements FROM _t66_pre_dup));
SELECT t_err('T66n same client_transaction_id with a different cart refused', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250), t_get('ct66a'), t_get('cust66'), t_get('u2')) $q$, 'IDEMPOTENCY_CONFLICT');
-- split payment 600 cash + 400 card on B ×1 (250 → no: B is 250 list; use A ×4? A has 3 left) → B ×2 = 500 + A ×2 = 500 → 1000
SELECT t_set('ct66s', gen_random_uuid());
CREATE TEMP TABLE _t66_r2 AS SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','2',NULL,'v66b','2',NULL), t_pay('cash','TRY',600) || t_pay('card','TRY',400), t_get('ct66s')) AS r;
GRANT SELECT ON _t66_r2 TO authenticated;
SELECT t_set('sale66s', (SELECT (r ->> 'sale_id')::uuid FROM _t66_r2));
SELECT t_check('T66c split payment 600 cash + 400 card on a 1000 sale', (SELECT (r ->> 'total')::numeric = 1000 FROM _t66_r2)
  AND (SELECT string_agg(method::text || '=' || amount::text, ',' ORDER BY amount) FROM sale_payments WHERE sale_id = t_get('sale66s')) = 'card=400.00,cash=600.00');
SELECT t_check('T66c salesperson defaults to the cashier', (SELECT sold_by = t_get('u3') AND salesperson_id = t_get('u3') FROM sales WHERE id = t_get('sale66s')));
-- I) exact last unit, then out of stock; cash change
SELECT t_set('ct66c', gen_random_uuid());
CREATE TEMP TABLE _t66_r3 AS SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66c','1',NULL), t_pay('cash','TRY',300), t_get('ct66c')) AS r;
GRANT SELECT ON _t66_r3 TO authenticated;
SELECT t_check('T66i last unit of C sold, 50 change', (SELECT (r ->> 'total')::numeric = 250 AND (r ->> 'change_given')::numeric = 50 FROM _t66_r3));
SELECT t_err('T66i C is now out of stock', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66c','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) $q$, 'INSUFFICIENT_STOCK');
SELECT t_err('T66i A: 1 left, 2 requested', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','2',NULL), t_pay('cash','TRY',500), gen_random_uuid()) $q$, 'INSUFFICIENT_STOCK');
-- O) completed sale mutation attempts by sales_staff (RLS: no write policy → 0 rows / 42501)
SELECT t_check('T66o sales_staff cannot change a completed sale (RLS 0 rows)',
  t_count($q$ WITH u AS (UPDATE sales SET note = 'x' WHERE id = t_get('sale66a') RETURNING 1) SELECT count(*) FROM u $q$) = 0
  AND t_count($q$ WITH u AS (UPDATE sale_items SET quantity = 9 WHERE sale_id = t_get('sale66a') RETURNING 1) SELECT count(*) FROM u $q$) = 0
  AND t_count($q$ WITH u AS (UPDATE sale_payments SET amount = 1 WHERE sale_id = t_get('sale66a') RETURNING 1) SELECT count(*) FROM u $q$) = 0
  AND t_count($q$ WITH u AS (DELETE FROM sale_items WHERE sale_id = t_get('sale66a') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_err('T66o sales_staff cannot void', $q$ SELECT rpc_void_sale(t_get('sale66a'), 'deneme') $q$, '42501');
SELECT t_check('T66o sale visible to its cashier', t_count($q$ SELECT count(*) FROM sales WHERE id = t_get('sale66a') $q$) = 1);
SELECT t_logout();

-- D) manager side: COGS captured at sale-time MWA; visibility for the salesperson
SELECT t_login('u2');
SELECT t_check('T66d revenue 500, COGS 200 (2 × MWA 100) on the first sale',
  (SELECT total FROM sales WHERE id = t_get('sale66a')) = 500
  AND (SELECT unit_cost_at_sale || '/' || line_cost_base FROM sale_item_costs c JOIN sale_items i ON i.id = c.sale_item_id WHERE i.sale_id = t_get('sale66a')) = '100.000000/200.000000'
  AND (SELECT total_cost_base FROM sale_costs WHERE sale_id = t_get('sale66a')) = 200);
SELECT t_check('T66d the manager sees the sale it was credited with (salesperson visibility)', t_count($q$ SELECT count(*) FROM sales WHERE salesperson_id = t_get('u2') AND id = t_get('sale66a') $q$) = 1);
SELECT t_check('T66d pools after sales: A 1@100, B 0, C 0', (SELECT string_agg(pv.sku || '=' || p.on_hand_qty || '@' || COALESCE(round(p.total_value_base / nullif(p.on_hand_qty,0), 2)::text, '-'), ',' ORDER BY pv.sku)
  FROM variant_cost_pools p JOIN product_variants pv ON pv.id = p.variant_id WHERE p.branch_id = t_get('br66') AND pv.sku LIKE 'POS-66-%') = 'POS-66-A=1@100.00,POS-66-B=0@-,POS-66-C=0@-');
-- later receipt moves A's MWA (1@100 + 4@300 → 5@260); the sale's COGS must not move
SELECT t_set('gr66', rpc_create_goods_receipt(t_get('br66'), t_get('sup1'), 'TRY', 1, CURRENT_DATE, 'INV-66', NULL));
SELECT t_ok('T66d later receipt raises the MWA', $q$ SELECT rpc_goods_receipt_upsert_line(t_get('gr66'), t_get('v66a'), 4, 300); SELECT * FROM rpc_goods_receipt_review(t_get('gr66')); SELECT rpc_post_goods_receipt(t_get('gr66')) $q$);
SELECT t_check('T66d A now 5 @ 260', (SELECT on_hand_qty || '@' || round(total_value_base / on_hand_qty, 2)::text FROM variant_cost_pools WHERE branch_id = t_get('br66') AND variant_id = t_get('v66a')) = '5@260.00');
SELECT t_check('T66d historical COGS unchanged: still 100 / 200', (SELECT unit_cost_at_sale || '/' || line_cost_base FROM sale_item_costs c JOIN sale_items i ON i.id = c.sale_item_id WHERE i.sale_id = t_get('sale66a')) = '100.000000/200.000000');
SELECT t_set('ct66m', gen_random_uuid());
SELECT t_set('sale66m', (rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('card','TRY',250), t_get('ct66m')) ->> 'sale_id')::uuid);
SELECT t_check('T66d a new sale of A carries the new MWA 260', (SELECT unit_cost_at_sale FROM sale_item_costs c JOIN sale_items i ON i.id = c.sale_item_id WHERE i.sale_id = t_get('sale66m')) = 260);
-- discounts: manager may discount within limit; sale-level reason recorded
SELECT t_set('ct66d', gen_random_uuid());
SELECT t_set('sale66d', (rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1','200'), t_pay('cash','TRY',200), t_get('ct66d'), NULL, NULL, 'manager_discount') ->> 'sale_id')::uuid);
SELECT t_check('T66d manager discount 250 → 200 recorded as line discount with reason', (SELECT discount_amount || '/' || discount_reason::text FROM sales WHERE id = t_get('sale66d')) = '50.00/manager_discount'
  AND (SELECT list_price || '/' || unit_price_at_sale || '/' || discount_amount FROM sale_items WHERE sale_id = t_get('sale66d')) = '250.00/200.00/50.00');
SELECT t_set('ct66v', gen_random_uuid());
SELECT t_set('sale66v', (rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250), t_get('ct66v'), NULL, t_get('u3')) ->> 'sale_id')::uuid);
SELECT t_logout();
SELECT t_login('u3');
SELECT t_check('T66d a sale the manager rang up for the salesperson is visible to that salesperson (own scope)',
  (SELECT sold_by = t_get('u2') AND salesperson_id = t_get('u3') FROM sales WHERE id = t_get('sale66v'))
  AND t_count($q$ SELECT count(*) FROM sale_items WHERE sale_id = t_get('sale66v') $q$) = 1
  AND t_count($q$ SELECT count(*) FROM sale_payments WHERE sale_id = t_get('sale66v') $q$) = 1);
SELECT t_check('T66d …and a sale by others for others stays hidden from sales_staff', t_count($q$ SELECT count(*) FROM sales WHERE id = t_get('sale66a') AND salesperson_id = t_get('u2') AND sold_by = t_get('u3') $q$) = 1
  AND t_count($q$ SELECT count(*) FROM sales WHERE sold_by = t_get('u2') AND salesperson_id = t_get('u2') AND branch_id = t_get('br66') $q$) = 0);
SELECT t_logout();

-- E) closed session / other-branch session / immutability as postgres
SELECT t_login('u2');
SELECT t_ok('T66e manager closes the drawer', $q$ SELECT rpc_close_register_session(t_get('sess66'), '[{"currency":"TRY","counted_amount":1600}]'::jsonb, 'pos test') $q$);
SELECT t_err('T66e sale on a closed session refused', $q$ SELECT rpc_pos_complete_sale(t_get('sess66'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) $q$, 'REGISTER_CLOSED');
SELECT t_err('T66e sale on another branch''s session cannot reach this branch''s stock (br1 session, POS-66 stock lives in br66)', $q$ SELECT rpc_pos_complete_sale(t_get('sess66b'), t_json_items('v66a','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) $q$, 'INSUFFICIENT_STOCK');
SELECT t_logout();
SELECT t_login('u3');
SELECT t_check('T66e closed session no longer visible to the cashier who did not open it', t_count($q$ SELECT count(*) FROM register_sessions WHERE id = t_get('sess66') $q$) = 0);
SELECT t_logout();
SELECT t_err('T66e completed sale immutable even for an RLS-bypassing role', $q$ UPDATE sale_items SET quantity = 9 WHERE sale_id = t_get('sale66a') $q$, 'IMMUTABLE');
SELECT t_err('T66e sale header frozen except void', $q$ UPDATE sales SET total = 1 WHERE id = t_get('sale66a') $q$, 'IMMUTABLE');
SELECT t_err('T66e payments frozen', $q$ DELETE FROM sale_payments WHERE sale_id = t_get('sale66a') $q$, 'IMMUTABLE');
SELECT t_check('T66e ledger: sale movements are sellable −qty referencing sale_items', t_count($q$ SELECT count(*) FROM inventory_movements m JOIN sale_items i ON i.id = m.reference_id AND m.reference_type = 'sale_item' WHERE i.sale_id IN (t_get('sale66a'), t_get('sale66s')) AND m.bucket = 'sellable' AND m.quantity < 0 $q$) = 3);
SELECT t_check('T66e cash drawer: cash tenders in, 50 change out', (SELECT string_agg(movement_type::text || '=' || amount::text, ',' ORDER BY amount) FROM cash_movements WHERE register_session_id = t_get('sess66') AND reference_type = 'sale') LIKE '%change_out=-50.00%sale_cash=600.00%');


-- ============================================================
-- T67 — Phase 9A register session hardening (20260916170000): drawer open/close is owner/manager;
--       sales_staff sells on an open session but cannot open/close; stock_staff nothing; cross-tenant nothing.
-- ============================================================
SELECT t_logout();
WITH x AS (INSERT INTO cash_registers (business_id, branch_id, name) VALUES (t_get('biz'), t_get('br66'), 'Kasa 67') RETURNING id) SELECT t_set('reg67', id) FROM x;
SELECT t_login('u2');
SELECT t_ok('T67 fixture: B restocked 3@80 for the sales below', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br66'), t_get('v66b'), 'sellable', 3, 'T67 fixture', 'manual_cost', 80) $q$);
SELECT t_logout();
CREATE TEMP TABLE _t67_base AS
SELECT (SELECT count(*) FROM register_sessions) AS sessions, (SELECT count(*) FROM register_session_currency_counts) AS counts,
       (SELECT count(*) FROM cash_movements) AS cash, (SELECT count(*) FROM sales) AS sales;
GRANT SELECT ON _t67_base TO authenticated;
CREATE FUNCTION t67_unchanged() RETURNS BOOLEAN LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM register_sessions) = (SELECT sessions FROM _t67_base)
     AND (SELECT count(*) FROM register_session_currency_counts) = (SELECT counts FROM _t67_base)
     AND (SELECT count(*) FROM cash_movements) = (SELECT cash FROM _t67_base)
     AND (SELECT count(*) FROM sales) = (SELECT sales FROM _t67_base) $$;

-- sales_staff / stock_staff / other tenant: no open, nothing written
SELECT t_login('u3');
SELECT t_err('T67a sales_staff cannot open a drawer', $q$ SELECT rpc_open_register_session(t_get('reg67'), '[{"currency":"TRY","amount":100}]'::jsonb) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u4');
SELECT t_err('T67a stock_staff cannot open a drawer', $q$ SELECT rpc_open_register_session(t_get('reg67'), '[]'::jsonb) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T67a other tenant''s owner cannot open A''s register', $q$ SELECT rpc_open_register_session(t_get('reg67'), '[]'::jsonb) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_check('T67a refused opens wrote nothing', t67_unchanged());

-- owner opens, sales_staff sells on it, sales_staff/stock_staff/other tenant cannot close, owner closes
SELECT t_login('u1');
SELECT t_set('sess67', rpc_open_register_session(t_get('reg67'), '[{"currency":"TRY","amount":100}]'::jsonb));
SELECT t_check('T67b owner opened the drawer (opening 100, opened_by owner)',
  (SELECT status::text || '/' || opened_by::text FROM register_sessions WHERE id = t_get('sess67')) = 'open/' || t_get('u1')::text
  AND (SELECT opening_amount FROM register_session_currency_counts WHERE register_session_id = t_get('sess67') AND currency = 'TRY') = 100);
SELECT t_err('T67b one open session per register: owner cannot open it twice', $q$ SELECT rpc_open_register_session(t_get('reg67'), '[]'::jsonb) $q$, 'REGISTER_ALREADY_OPEN');
SELECT t_logout();
SELECT t_login('u3');
SELECT t_check('T67c sales_staff sees the open drawer', t_count($q$ SELECT count(*) FROM register_sessions WHERE id = t_get('sess67') $q$) = 1);
SELECT t_set('sale67', (rpc_pos_complete_sale(t_get('sess67'), t_json_items('v66b','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) ->> 'sale_id')::uuid);
SELECT t_check('T67c sales_staff completed a sale on the owner''s session (cashier = u3)',
  (SELECT sold_by = t_get('u3') AND status = 'completed' AND total = 250 FROM sales WHERE id = t_get('sale67')));
SELECT t_check('T67c …but does not see the owner''s drawer cash', t_count($q$ SELECT count(*) FROM cash_movements WHERE register_session_id = t_get('sess67') $q$) = 0);
SELECT t_err('T67c sales_staff cannot close the drawer', $q$ SELECT rpc_close_register_session(t_get('sess67'), '[{"currency":"TRY","counted_amount":350}]'::jsonb) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u4');
SELECT t_err('T67c stock_staff cannot close the drawer', $q$ SELECT rpc_close_register_session(t_get('sess67'), '[{"currency":"TRY","counted_amount":350}]'::jsonb) $q$, 'FORBIDDEN');
SELECT t_err('T67c stock_staff cannot sell on it either', $q$ SELECT rpc_pos_complete_sale(t_get('sess67'), t_json_items('v66b','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T67c other tenant cannot close A''s session', $q$ SELECT rpc_close_register_session(t_get('sess67'), '[{"currency":"TRY","counted_amount":350}]'::jsonb) $q$, 'FORBIDDEN');
SELECT t_err('T67c other tenant cannot sell on A''s session', $q$ SELECT rpc_pos_complete_sale(t_get('sess67'), t_json_items('v66b','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_check('T67c the cashier''s cash landed in the owner''s drawer',
  (SELECT count(*) FROM cash_movements WHERE register_session_id = t_get('sess67') AND movement_type = 'sale_cash' AND amount = 250) = 1);
SELECT t_check('T67c refused closes/sales left the session open and the counts untouched',
  (SELECT status::text FROM register_sessions WHERE id = t_get('sess67')) = 'open'
  AND (SELECT counted_amount IS NULL FROM register_session_currency_counts WHERE register_session_id = t_get('sess67') AND currency = 'TRY')
  AND (SELECT count(*) FROM sales) = (SELECT sales FROM _t67_base) + 1);
SELECT t_login('u1');
SELECT t_ok('T67d owner closes the drawer (expected 350, counted 340)', $q$ SELECT rpc_close_register_session(t_get('sess67'), '[{"currency":"TRY","counted_amount":340}]'::jsonb, 'T67 kapanış') $q$);
SELECT t_check('T67d closed by owner, expected 350 / counted 340 / variance -10',
  (SELECT status::text || '/' || closed_by::text FROM register_sessions WHERE id = t_get('sess67')) = 'closed/' || t_get('u1')::text
  AND (SELECT expected_amount || '/' || counted_amount || '/' || variance_amount FROM register_session_currency_counts WHERE register_session_id = t_get('sess67') AND currency = 'TRY') = '350.00/340.00/-10.00');
SELECT t_logout();
SELECT t_login('u3');
SELECT t_err('T67d sale on the closed session refused', $q$ SELECT rpc_pos_complete_sale(t_get('sess67'), t_json_items('v66b','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) $q$, 'REGISTER_CLOSED');
SELECT t_logout();

-- manager opens and closes; stock_staff sale on the manager's session refused
SELECT t_login('u2');
SELECT t_set('sess67b', rpc_open_register_session(t_get('reg67'), '[]'::jsonb));
SELECT t_check('T67e manager reopened the register with a new session', (SELECT status::text || '/' || opened_by::text FROM register_sessions WHERE id = t_get('sess67b')) = 'open/' || t_get('u2')::text);
SELECT t_logout();
SELECT t_login('u4');
SELECT t_err('T67e stock_staff sale on the manager''s session refused', $q$ SELECT rpc_pos_complete_sale(t_get('sess67b'), t_json_items('v66b','1',NULL), t_pay('cash','TRY',250), gen_random_uuid()) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_ok('T67e manager closes it', $q$ SELECT rpc_close_register_session(t_get('sess67b'), '[{"currency":"TRY","counted_amount":0}]'::jsonb) $q$);
SELECT t_err('T67e closing twice refused', $q$ SELECT rpc_close_register_session(t_get('sess67b'), '[{"currency":"TRY","counted_amount":0}]'::jsonb) $q$, 'INVALID_STATE');
SELECT t_logout();
SELECT t_check('T67e no client write path: register_sessions / currency counts / cash_movements have no INSERT/UPDATE/DELETE policy',
  (SELECT count(*) FROM pg_policies WHERE tablename IN ('register_sessions','register_session_currency_counts','cash_movements') AND cmd <> 'SELECT') = 0);
SELECT t_check('T67e the two session RPCs are the only register/session/cash RPCs',
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname LIKE 'rpc_%' AND (p.proname LIKE '%register%' OR p.proname LIKE '%session%' OR p.proname LIKE '%drawer%' OR p.proname LIKE '%cash%')) = 2);


-- ============================================================
-- T68 — Phase 9B returns / exchange foundation: tenant policy, eligibility, partial returns,
--       conditions, historical COGS, exchange (upgrade / downgrade), refunds, reasons,
--       idempotency, permissions, cross-tenant, immutability.
--   Tenant A (biz): legacy keys → exchange-only, 3-day window, downgrade blocked.
--   Tenant B (bizB): explicit return_policy → cash refunds, 14 days, reason required, downgrade → cash refund.
-- ============================================================
SELECT t_logout();
-- fixture A: branch, register, products (regular / product-excluded / category-excluded / dearer / cheaper)
WITH x AS (INSERT INTO branches (business_id, name, code) VALUES (t_get('biz'), 'İade Şubesi', 'RET') RETURNING id) SELECT t_set('br68', id) FROM x;
WITH x AS (INSERT INTO cash_registers (business_id, branch_id, name) VALUES (t_get('biz'), t_get('br68'), 'Kasa 68') RETURNING id) SELECT t_set('reg68', id) FROM x;
WITH x AS (INSERT INTO products (business_id, category_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), t_get('cat_elbise'), 'İade Elbise', 'RET-68', 250, 'active') RETURNING id) SELECT t_set('p68', id) FROM x;
WITH x AS (INSERT INTO products (business_id, category_id, name, sku_prefix, default_sale_price, status, is_final_sale) VALUES (t_get('biz'), t_get('cat_elbise'), 'Kesin Satış Ürün', 'RET-68X', 400, 'active', true) RETURNING id) SELECT t_set('p68x', id) FROM x;
WITH x AS (INSERT INTO products (business_id, category_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), t_get('cat_bikini'), 'Kesin Satış Kategori', 'RET-68C', 300, 'active') RETURNING id) SELECT t_set('p68c', id) FROM x;
WITH x AS (INSERT INTO products (business_id, category_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), t_get('cat_elbise'), 'Pahalı Elbise', 'RET-68P', 400, 'active') RETURNING id) SELECT t_set('p68p', id) FROM x;
WITH x AS (INSERT INTO products (business_id, category_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), t_get('cat_elbise'), 'Ucuz Elbise', 'RET-68U', 150, 'active') RETURNING id) SELECT t_set('p68u', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p68'), 'RET-68-A') RETURNING id) SELECT t_set('v68a', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v68a'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000001');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p68'), 'RET-68-B') RETURNING id) SELECT t_set('v68b', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v68b'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000002');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p68x'), 'RET-68X-A') RETURNING id) SELECT t_set('v68x', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p68c'), 'RET-68C-A') RETURNING id) SELECT t_set('v68c', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p68p'), 'RET-68P-A') RETURNING id) SELECT t_set('v68p', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p68u'), 'RET-68U-A') RETURNING id) SELECT t_set('v68u', id) FROM x;
INSERT INTO barcodes (variant_id, barcode, barcode_type, symbology, is_primary) VALUES (t_get('v68a'), '0068000000018', 'supplier', 'EAN13', true);
WITH x AS (INSERT INTO customers (business_id, full_name, phone) VALUES (t_get('biz'), 'İade Müşterisi', '+90 555 068 0068') RETURNING id) SELECT t_set('cust68', id) FROM x;
SELECT t_login('u2');
SELECT t_ok('T68 fixture stock (br68): A 10@100, B 5@120, X 3@150, C 3@90, P 5@150, U 5@60', $q$
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br68'), t_get('v68a'), 'sellable', 10, 'ret fixture', 'manual_cost', 100);
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br68'), t_get('v68b'), 'sellable', 5, 'ret fixture', 'manual_cost', 120);
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br68'), t_get('v68x'), 'sellable', 3, 'ret fixture', 'manual_cost', 150);
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br68'), t_get('v68c'), 'sellable', 3, 'ret fixture', 'manual_cost', 90);
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br68'), t_get('v68p'), 'sellable', 5, 'ret fixture', 'manual_cost', 150);
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br68'), t_get('v68u'), 'sellable', 5, 'ret fixture', 'manual_cost', 60) $q$);
SELECT t_set('sess68', rpc_open_register_session(t_get('reg68'), '[{"currency":"TRY","amount":100}]'::jsonb));
-- an old sale (4 days ago) through the Rev 3 entry point (POS never backdates)
SELECT t_set('s68old', (rpc_process_sale(t_get('biz'), t_get('br68'), t_get('sess68'), t_json_items('v68a','1',NULL), t_pay('cash','TRY',250), NULL, NULL, now() - interval '4 days') ->> 'sale_id')::uuid);
SELECT t_logout();
-- the cashier (sales_staff) rings up the sales that will come back
SELECT t_login('u3');
SELECT t_set('s68', (rpc_pos_complete_sale(t_get('sess68'), t_json_items('v68a','3',NULL), t_pay('cash','TRY',750), gen_random_uuid(), t_get('cust68')) ->> 'sale_id')::uuid);
SELECT t_set('s68x', (rpc_pos_complete_sale(t_get('sess68'), t_json_items('v68x','1',NULL), t_pay('cash','TRY',400), gen_random_uuid()) ->> 'sale_id')::uuid);
SELECT t_set('s68c', (rpc_pos_complete_sale(t_get('sess68'), t_json_items('v68c','1',NULL), t_pay('cash','TRY',300), gen_random_uuid()) ->> 'sale_id')::uuid);
SELECT t_set('s68b', (rpc_pos_complete_sale(t_get('sess68'), t_json_items('v68b','2',NULL), t_pay('card','TRY',500), gen_random_uuid()) ->> 'sale_id')::uuid);
SELECT t_logout();
SELECT t_set('si68', (SELECT id FROM sale_items WHERE sale_id = t_get('s68')));
SELECT t_set('si68x', (SELECT id FROM sale_items WHERE sale_id = t_get('s68x')));
SELECT t_set('si68c', (SELECT id FROM sale_items WHERE sale_id = t_get('s68c')));
SELECT t_set('si68b', (SELECT id FROM sale_items WHERE sale_id = t_get('s68b')));
SELECT t_set('si68old', (SELECT id FROM sale_items WHERE sale_id = t_get('s68old')));
CREATE TEMP TABLE _t68_base AS
SELECT (SELECT count(*) FROM returns) AS returns, (SELECT count(*) FROM return_items) AS items, (SELECT count(*) FROM return_item_costs) AS costs,
       (SELECT count(*) FROM inventory_movements) AS movements, (SELECT count(*) FROM cash_movements) AS cash, (SELECT count(*) FROM sales) AS sales;
GRANT SELECT ON _t68_base TO authenticated;
CREATE FUNCTION t68_unchanged() RETURNS BOOLEAN LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM returns) = (SELECT returns FROM _t68_base) AND (SELECT count(*) FROM return_items) = (SELECT items FROM _t68_base)
     AND (SELECT count(*) FROM return_item_costs) = (SELECT costs FROM _t68_base) AND (SELECT count(*) FROM inventory_movements) = (SELECT movements FROM _t68_base)
     AND (SELECT count(*) FROM cash_movements) = (SELECT cash FROM _t68_base) AND (SELECT count(*) FROM sales) = (SELECT sales FROM _t68_base) $$;
CREATE FUNCTION t68_ret_item(k TEXT, qty INT, disp TEXT DEFAULT NULL) RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('sale_item_id', t_get(k), 'quantity', qty) || CASE WHEN disp IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('disposition', disp) END) $$;

-- ---------------------------------------------------------------- policy
SELECT t_check('T68a tenant A policy resolves from legacy keys: exchange-only, 3 days, downgrade blocked',
  (SELECT p ->> 'allow_exchange' = 'true' AND p ->> 'allow_cash_refund' = 'false' AND p ->> 'allow_store_credit' = 'false'
      AND p ->> 'exchange_window_days' = '3' AND p ->> 'receipt_required' = 'true' AND p ->> 'reason_required' = 'false' AND p ->> 'downgrade_treatment' = 'block'
   FROM fn_return_policy(t_get('biz')) p));
UPDATE businesses SET settings = settings || jsonb_build_object(
  'accepted_currencies', jsonb_build_array('TRY'),
  'return_policy', jsonb_build_object('allow_exchange', true, 'allow_cash_refund', true, 'allow_store_credit', false,
                                      'exchange_window_days', 14, 'receipt_required', true, 'reason_required', true, 'downgrade_treatment', 'cash_refund'))
WHERE id = t_get('bizB');
SELECT t_check('T68a tenant B policy is explicit: cash refunds, 14 days, reason required, downgrade → cash refund',
  (SELECT p ->> 'allow_cash_refund' = 'true' AND p ->> 'exchange_window_days' = '14' AND p ->> 'reason_required' = 'true' AND p ->> 'downgrade_treatment' = 'cash_refund'
   FROM fn_return_policy(t_get('bizB')) p));
SELECT t_check('T68a policy helper is internal', (SELECT NOT has_function_privilege('authenticated', 'fn_return_policy(uuid)', 'EXECUTE')));
SELECT t_check('T68a default reasons seeded (6, platform-wide)', (SELECT count(*) FROM return_reasons WHERE business_id IS NULL AND is_active) = 6);

-- ---------------------------------------------------------------- eligibility + lookup (sales_staff prepares)
SELECT t_login('u3');
SELECT t_check('T68b eligibility: regular sale → 1 line ELIGIBLE, 3 returnable, policy flags exposed',
  (SELECT e -> 'lines' -> 0 ->> 'status' = 'ELIGIBLE' AND (e -> 'lines' -> 0 ->> 'returnable_quantity')::int = 3
      AND (e -> 'lines' -> 0 ->> 'returned_quantity')::int = 0 AND e -> 'policy' ->> 'allow_cash_refund' = 'false'
      AND e -> 'policy' ->> 'window_expired' = 'false' AND jsonb_array_length(e -> 'reasons') = 6
      AND e -> 'sale' ->> 'customer_name' = 'İade Müşterisi'
   FROM rpc_return_eligibility(t_get('s68')) e));
SELECT t_check('T68b eligibility: product-level final sale → EXCLUDED (product), 0 returnable',
  (SELECT e -> 'lines' -> 0 ->> 'status' = 'EXCLUDED' AND e -> 'lines' -> 0 ->> 'excluded_by' = 'product' AND (e -> 'lines' -> 0 ->> 'returnable_quantity')::int = 0
   FROM rpc_return_eligibility(t_get('s68x')) e));
SELECT t_check('T68b eligibility: category final sale → EXCLUDED (category)',
  (SELECT e -> 'lines' -> 0 ->> 'status' = 'EXCLUDED' AND e -> 'lines' -> 0 ->> 'excluded_by' = 'category' FROM rpc_return_eligibility(t_get('s68c')) e));
SELECT t_check('T68b eligibility: 4-day-old sale → WINDOW_EXPIRED, days_left 0',
  (SELECT e -> 'lines' -> 0 ->> 'status' = 'WINDOW_EXPIRED' AND e -> 'policy' ->> 'window_expired' = 'true' AND (e -> 'policy' ->> 'days_left')::int = 0
   FROM rpc_return_eligibility(t_get('s68old')) e));
SELECT t_check('T68b eligibility carries no cost key', (SELECT NOT (e::text ~ 'cost') FROM rpc_return_eligibility(t_get('s68')) e));
SELECT t_check('T68b lookup by receipt number', (SELECT jsonb_array_length(r) = 1 AND r -> 0 ->> 'sale_number' = (SELECT sale_number FROM sales WHERE id = t_get('s68'))
  FROM rpc_pos_find_sales(t_get('biz'), 'sale_number', lower((SELECT sale_number FROM sales WHERE id = t_get('s68')))) r));
SELECT t_check('T68b lookup by barcode (recent sales containing it, across the own scope)', (SELECT jsonb_array_length(r) >= 1 AND EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE (x ->> 'id')::uuid = t_get('s68'))
  FROM rpc_pos_find_sales(t_get('biz'), 'barcode', '0068000000018') r));
SELECT t_check('T68b lookup by customer', (SELECT jsonb_array_length(r) = 1 AND r -> 0 ->> 'customer_name' = 'İade Müşterisi' AND (r -> 0 ->> 'item_count')::int = 3
  FROM rpc_pos_find_sales(t_get('biz'), 'customer', '068 0068') r));
SELECT t_check('T68b lookup: too short → nothing', (SELECT jsonb_array_length(r) = 0 FROM rpc_pos_find_sales(t_get('biz'), 'customer', 'a') r));
SELECT t_check('T68b lookup carries no cost key', (SELECT NOT (r::text ~ 'cost') FROM rpc_pos_find_sales(t_get('biz'), 'sale_number', (SELECT sale_number FROM sales WHERE id = t_get('s68'))) r));
SELECT t_logout();
SELECT t_login('u4');
SELECT t_err('T68b stock_staff cannot read eligibility', $q$ SELECT rpc_return_eligibility(t_get('s68')) $q$, 'FORBIDDEN');
SELECT t_err('T68b stock_staff cannot look up sales', $q$ SELECT rpc_pos_find_sales(t_get('biz'), 'sale_number', 'S-2026-000001') $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T68b other tenant: eligibility of A''s sale → NOT_FOUND', $q$ SELECT rpc_return_eligibility(t_get('s68')) $q$, 'NOT_FOUND');
SELECT t_err('T68b other tenant: lookup with A''s business_id → FORBIDDEN', $q$ SELECT rpc_pos_find_sales(t_get('biz'), 'customer', 'İade') $q$, 'FORBIDDEN');
SELECT t_logout();

-- ---------------------------------------------------------------- posting authority
SELECT t_login('u3');
SELECT t_err('T68c sales_staff cannot complete an exchange', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), gen_random_uuid()) $q$, 'FORBIDDEN');
SELECT t_err('T68c sales_staff cannot complete a return', $q$ SELECT rpc_pos_return(t_get('s68'), t68_ret_item('si68', 1), 'refund', gen_random_uuid(), NULL, NULL, t_get('sess68'), 'cash') $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u4');
SELECT t_err('T68c stock_staff cannot complete an exchange', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), gen_random_uuid()) $q$, 'FORBIDDEN');
SELECT t_err('T68c stock_staff cannot complete a return', $q$ SELECT rpc_pos_return(t_get('s68'), t68_ret_item('si68', 1), 'refund', gen_random_uuid()) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T68c other tenant cannot return A''s sale', $q$ SELECT rpc_pos_return(t_get('s68'), t68_ret_item('si68', 1), 'refund', gen_random_uuid()) $q$, 'NOT_FOUND');
SELECT t_err('T68c other tenant cannot exchange on A''s session', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), gen_random_uuid()) $q$, 'INVALID_REGISTER_SESSION');
SELECT t_logout();
SELECT t_check('T68c refused attempts wrote nothing', t68_unchanged());

-- ---------------------------------------------------------------- manager: policy refusals on tenant A
SELECT t_login('u2');
SELECT t_err('T68d exchange-only tenant: cash refund refused', $q$ SELECT rpc_pos_return(t_get('s68'), t68_ret_item('si68', 1), 'refund', gen_random_uuid(), NULL, NULL, t_get('sess68'), 'cash') $q$, 'REFUND_NOT_ALLOWED');
SELECT t_err('T68d store credit disabled', $q$ SELECT rpc_pos_return(t_get('s68'), t68_ret_item('si68', 1), 'store_credit', gen_random_uuid()) $q$, 'STORE_CREDIT_NOT_ALLOWED');
SELECT t_err('T68d exchange must go through rpc_pos_exchange', $q$ SELECT rpc_pos_return(t_get('s68'), t68_ret_item('si68', 1), 'exchange', gen_random_uuid()) $q$, 'USE_EXCHANGE_RPC');
SELECT t_err('T68d client_transaction_id is mandatory (return)', $q$ SELECT rpc_pos_return(t_get('s68'), t68_ret_item('si68', 1), 'refund', NULL) $q$, 'CLIENT_TRANSACTION_REQUIRED');
SELECT t_err('T68d client_transaction_id is mandatory (exchange)', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), NULL) $q$, 'CLIENT_TRANSACTION_REQUIRED');
SELECT t_err('T68d expired window', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68old'), t68_ret_item('si68old', 1), t_json_items('v68b','1',NULL), '[]'::jsonb, gen_random_uuid()) $q$, 'EXCHANGE_WINDOW_EXPIRED');
SELECT t_err('T68d product-level final sale', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68x'), t68_ret_item('si68x', 1), t_json_items('v68p','1',NULL), '[]'::jsonb, gen_random_uuid()) $q$, 'FINAL_SALE');
SELECT t_err('T68d category-level final sale', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68c'), t68_ret_item('si68c', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',100), gen_random_uuid()) $q$, 'FINAL_SALE');
SELECT t_err('T68d downgrade blocked by policy (credit 250 > replacement 150)', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68u','1',NULL), '[]'::jsonb, gen_random_uuid()) $q$, 'EXCHANGE_DOWNGRADE_BLOCKED');
SELECT t_err('T68d invalid reason code', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), gen_random_uuid(), 'yok_boyle') $q$, 'INVALID_REASON');
SELECT t_err('T68d sale item of another sale injected', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68b', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), gen_random_uuid()) $q$, 'INVALID_ITEM');
SELECT t_err('T68d replacement variant of another tenant', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('vB','1',NULL), t_pay('cash','TRY',150), gen_random_uuid()) $q$, 'INVALID_VARIANT');
SELECT t_err('T68d foreign customer on the replacement sale', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), gen_random_uuid(), NULL, NULL, t_get('custB')) $q$, 'INVALID_CUSTOMER');
SELECT t_err('T68d session of another branch', $q$ SELECT rpc_pos_exchange(t_get('sess66b'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), gen_random_uuid()) $q$, 'BRANCH_MISMATCH');
SELECT t_err('T68d over-return (4 of 3)', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 4), t_json_items('v68p','4',NULL), t_pay('cash','TRY',600), gen_random_uuid()) $q$, 'OVER_RETURN');
SELECT t_err('T68d payment short on the difference', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',100), gen_random_uuid()) $q$, 'PAYMENT_SHORT');
SELECT t_logout();
SELECT t_check('T68d every refusal was side-effect free', t68_unchanged());

-- ---------------------------------------------------------------- J: exchange to a dearer item (1 of 3, default quarantine)
SELECT t_login('u2');
SELECT t_set('ct68j', gen_random_uuid());
CREATE TEMP TABLE _t68_j AS SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), t_get('ct68j'), 'beden_olmadi', 'ilk değişim') AS r;
SELECT t_logout();
SELECT t_set('xs68j', (SELECT (r ->> 'sale_id')::uuid FROM _t68_j));
SELECT t_set('ret68j', (SELECT (r -> 'return' ->> 'return_id')::uuid FROM _t68_j));
SELECT t_check('T68e exchange result: credit 250 applied, replacement 400, due 150, no refund',
  (SELECT (r ->> 'total')::numeric = 400 AND (r ->> 'amount_due')::numeric = 150 AND (r ->> 'credit_applied')::numeric = 250
      AND (r ->> 'refund_amount_base')::numeric = 0 AND (r ->> 'replayed')::boolean = false FROM _t68_j));
SELECT t_check('T68e return document: exchange, credit 250, refund 0, linked to the replacement sale, reason recorded',
  (SELECT return_type = 'exchange' AND credit_value_base = 250 AND refund_amount_base = 0 AND refund_method IS NULL
      AND replacement_sale_id = t_get('xs68j') AND exchange_group_id = (SELECT exchange_group_id FROM sales WHERE id = t_get('xs68j'))
      AND reason_code = 'beden_olmadi' AND note = 'ilk değişim' AND customer_id = t_get('cust68') AND processed_by = t_get('u2')
   FROM returns WHERE id = t_get('ret68j')));
SELECT t_check('T68e return item: 1 × A at the original 250, default condition quarantine, reason on the line',
  (SELECT quantity = 1 AND unit_price_at_sale = 250 AND disposition = 'quarantine' AND reason_code = 'beden_olmadi' AND sale_item_id = t_get('si68') AND variant_id = t_get('v68a')
   FROM return_items WHERE return_id = t_get('ret68j')));
SELECT t_check('T68e ledger: +1 A quarantine at branch br68 referencing the return item',
  (SELECT m.quantity = 1 AND m.bucket = 'quarantine' AND m.branch_id = t_get('br68') AND m.reference_type = 'return_item'
   FROM inventory_movements m WHERE m.reference_id = (SELECT id FROM return_items WHERE return_id = t_get('ret68j')) AND m.reason = 'customer_return'));
SELECT t_check('T68e replacement sale: total 400, credit 250, cash 150 in the drawer, same exchange group, original sale untouched',
  (SELECT total = 400 AND credit_applied_base = 250 AND amount_due_base = 150 AND status = 'completed' FROM sales WHERE id = t_get('xs68j'))
  AND (SELECT count(*) FROM cash_movements WHERE reference_id = t_get('xs68j') AND movement_type = 'sale_cash' AND amount = 150) = 1
  AND (SELECT status = 'completed' AND total = 750 FROM sales WHERE id = t_get('s68')) AND (SELECT quantity FROM sale_items WHERE id = t_get('si68')) = 3);
SELECT t_login('u3');
SELECT t_check('T68e eligibility now: returned 1, returnable 2', (SELECT (e -> 'lines' -> 0 ->> 'returned_quantity')::int = 1 AND (e -> 'lines' -> 0 ->> 'returnable_quantity')::int = 2 AND jsonb_array_length(e -> 'returns') = 1
  FROM rpc_return_eligibility(t_get('s68')) e));
SELECT t_logout();
SELECT t_login('u2');
SELECT t_check('T68e return document RPC resolves names and lines',
  (SELECT d ->> 'return_number' = (SELECT return_number FROM returns WHERE id = t_get('ret68j')) AND d ->> 'reason_label' = 'Beden olmadı'
      AND d ->> 'replacement_sale_number' = (SELECT sale_number FROM sales WHERE id = t_get('xs68j')) AND jsonb_array_length(d -> 'items') = 1
   FROM rpc_return_document(t_get('ret68j')) d));
SELECT t_logout();

-- ---------------------------------------------------------------- historical COGS: the MWA moves, the return still reverses 100
SELECT t_login('u2');
SELECT t_ok('T68f later receipt moves A''s MWA (adjustment +5 @ 200)', $q$ SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br68'), t_get('v68a'), 'sellable', 5, 'mwa shift', 'manual_cost', 200) $q$);
SELECT t_logout();
SELECT t_check('T68f A''s MWA is now above 100', (SELECT total_value_base / on_hand_qty > 100 FROM variant_cost_pools WHERE variant_id = t_get('v68a') AND branch_id = t_get('br68')));
CREATE TEMP TABLE _t68_pool AS SELECT on_hand_qty, total_value_base FROM variant_cost_pools WHERE variant_id = t_get('v68a') AND branch_id = t_get('br68');
SELECT t_login('u2');
SELECT t_set('ct68j2', gen_random_uuid());
CREATE TEMP TABLE _t68_j2 AS SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1, 'sellable'), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), t_get('ct68j2'), 'musteri_tercihi') AS r;
SELECT t_logout();
SELECT t_set('ret68j2', (SELECT (r -> 'return' ->> 'return_id')::uuid FROM _t68_j2));
SELECT t_check('T68f second partial return re-enters at the historical 100, not the current MWA',
  (SELECT c.unit_cost_at_sale = 100 AND c.line_cost_base = 100 FROM return_item_costs c JOIN return_items ri ON ri.id = c.return_item_id WHERE ri.return_id = t_get('ret68j2'))
  AND (SELECT mc.unit_cost_base = 100 FROM inventory_movements m JOIN inventory_movement_costs mc ON mc.movement_id = m.id
       WHERE m.reference_id = (SELECT id FROM return_items WHERE return_id = t_get('ret68j2')) AND m.reason = 'customer_return'));
SELECT t_check('T68f pool: +1 unit, value +100 exactly (cost-pool model consistent with the reversed COGS)',
  (SELECT p.on_hand_qty = b.on_hand_qty + 1 AND p.total_value_base = b.total_value_base + 100
   FROM variant_cost_pools p, _t68_pool b WHERE p.variant_id = t_get('v68a') AND p.branch_id = t_get('br68')));
SELECT t_check('T68f condition sellable honoured (manager) → ledger sellable bucket', (SELECT bucket = 'sellable' FROM inventory_movements WHERE reference_id = (SELECT id FROM return_items WHERE return_id = t_get('ret68j2'))));
SELECT t_check('T68f original sale COGS record unchanged (3 × 100)', (SELECT line_cost_base = 300 AND unit_cost_at_sale = 100 FROM sale_item_costs WHERE sale_item_id = t_get('si68')));

-- ---------------------------------------------------------------- idempotency + last unit + over-return + damaged condition
SELECT t_login('u2');
SELECT t_check('T68g exchange double submit replays (same id, same payload)',
  (SELECT (r ->> 'replayed')::boolean AND (r ->> 'sale_id')::uuid = t_get('xs68j') AND (r -> 'return' ->> 'return_id')::uuid = t_get('ret68j')
   FROM rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), t_get('ct68j'), 'beden_olmadi', 'ilk değişim') r));
SELECT t_err('T68g same id with a different payload refused', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), t_get('ct68j'), 'diger') $q$, 'IDEMPOTENCY_CONFLICT');
SELECT t_set('ct68j3', gen_random_uuid());
CREATE TEMP TABLE _t68_j3 AS SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1, 'damaged'), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), t_get('ct68j3'), 'kusurlu_urun') AS r;
SELECT t_set('ret68j3', (SELECT (r -> 'return' ->> 'return_id')::uuid FROM _t68_j3));
SELECT t_err('T68g nothing left: fourth unit refused', $q$ SELECT rpc_pos_exchange(t_get('sess68'), t_get('s68'), t68_ret_item('si68', 1), t_json_items('v68p','1',NULL), t_pay('cash','TRY',150), gen_random_uuid()) $q$, 'OVER_RETURN');
SELECT t_logout();
SELECT t_check('T68g replay wrote nothing: exactly 3 returns / 3 items / 3 cost rows / 3 replacement sales for the sale',
  (SELECT count(*) FROM returns WHERE original_sale_id = t_get('s68')) = 3 AND (SELECT count(*) FROM return_items WHERE sale_item_id = t_get('si68')) = 3
  AND (SELECT count(*) FROM return_item_costs c JOIN return_items ri ON ri.id = c.return_item_id WHERE ri.sale_item_id = t_get('si68')) = 3
  AND (SELECT count(*) FROM sales WHERE exchange_group_id IN (SELECT exchange_group_id FROM returns WHERE original_sale_id = t_get('s68'))) = 3
  AND (SELECT returned_quantity FROM v_sale_item_returned WHERE sale_item_id = t_get('si68')) = 3);
SELECT t_check('T68g damaged condition → ledger damaged bucket', (SELECT bucket = 'damaged' FROM inventory_movements WHERE reference_id = (SELECT id FROM return_items WHERE return_id = t_get('ret68j3'))));
SELECT t_login('u3');
SELECT t_check('T68g eligibility: NOTHING_LEFT', (SELECT e -> 'lines' -> 0 ->> 'status' = 'NOTHING_LEFT' FROM rpc_return_eligibility(t_get('s68')) e));
SELECT t_logout();
SELECT t_check('T68g buckets: A quarantine 1 / sellable +1 / damaged 1 from the three returns',
  t_bucket('v68a', 'quarantine', 'br68') = 1 AND t_bucket('v68a', 'damaged', 'br68') = 1);
SELECT t_login('u2');
SELECT t_err('T68g original sale can no longer be voided (has returns)', $q$ SELECT rpc_void_sale(t_get('s68'), 'deneme iptal') $q$, 'VOID_BLOCKED');
SELECT t_logout();

-- ---------------------------------------------------------------- tenant-extensible reasons
SELECT t_login('u2');
SELECT t_ok('T68h manager adds a tenant reason', $q$ INSERT INTO return_reasons (business_id, code, label, sort_order) VALUES (t_get('biz'), 'etiket_hatasi', 'Etiket hatası', 60) $q$);
SELECT t_check('T68h tenant reason is offered together with the defaults (7)', (SELECT jsonb_array_length(e -> 'reasons') = 7 FROM rpc_return_eligibility(t_get('s68b')) e));
SELECT t_set('ct68h', gen_random_uuid());
SELECT t_set('si68b_ret', (SELECT (r -> 'return' ->> 'return_id')::uuid FROM rpc_pos_exchange(t_get('sess68'), t_get('s68b'), t68_ret_item('si68b', 1), t_json_items('v68a','1',NULL), '[]'::jsonb, t_get('ct68h'), 'etiket_hatasi') r));
SELECT t_check('T68h tenant reason accepted on a return (equal exchange, no payment)', (SELECT reason_code = 'etiket_hatasi' AND credit_value_base = 250 FROM returns WHERE id = t_get('si68b_ret')));
SELECT t_err('T68h a reason of another tenant is refused', $q$ INSERT INTO return_reasons (business_id, code, label) VALUES (t_get('bizB'), 'hile', 'x') $q$, '42501');
SELECT t_logout();
SELECT t_login('u3');
SELECT t_err('T68h sales_staff cannot add reasons', $q$ INSERT INTO return_reasons (business_id, code, label) VALUES (t_get('biz'), 'staff_reason', 'x') $q$, '42501');
SELECT t_check('T68h …but reads them', t_count($q$ SELECT count(*) FROM return_reasons $q$) = 7);
SELECT t_logout();

-- ---------------------------------------------------------------- tenant B: cash refunds, partial returns, reason required, downgrade → cash refund
SELECT t_login('u5');
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('bizB'), 'Other Dear', 'OP-02', 25, 'active') RETURNING id) SELECT t_set('pB2', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pB2'), 'OP-02-STD') RETURNING id) SELECT t_set('vB2', id) FROM x;
SELECT t_ok('T68i tenant B stock: vB 10@4, vB2 3@12', $q$
  SELECT rpc_post_inventory_adjustment(t_get('bizB'), t_get('brB'), t_get('vB'), 'sellable', 10, 'ret fixture', 'manual_cost', 4);
  SELECT rpc_post_inventory_adjustment(t_get('bizB'), t_get('brB'), t_get('vB2'), 'sellable', 3, 'ret fixture', 'manual_cost', 12) $q$);
SELECT t_set('sessB68', rpc_open_register_session(t_get('regB'), '[{"currency":"TRY","amount":50}]'::jsonb));
SELECT t_set('sB1', (rpc_pos_complete_sale(t_get('sessB68'), t_json_items('vB','3',NULL), t_pay('cash','TRY',30), gen_random_uuid()) ->> 'sale_id')::uuid);
SELECT t_set('sB2', (rpc_pos_complete_sale(t_get('sessB68'), t_json_items('vB2','1',NULL), t_pay('card','TRY',25), gen_random_uuid()) ->> 'sale_id')::uuid);
SELECT t_set('siB1', (SELECT id FROM sale_items WHERE sale_id = t_get('sB1')));
SELECT t_set('siB2', (SELECT id FROM sale_items WHERE sale_id = t_get('sB2')));
SELECT t_err('T68i reason required by policy', $q$ SELECT rpc_pos_return(t_get('sB1'), t68_ret_item('siB1', 1), 'refund', gen_random_uuid(), NULL, NULL, t_get('sessB68'), 'cash') $q$, 'REASON_REQUIRED');
SELECT t_err('T68i cash refund needs the refund method', $q$ SELECT rpc_pos_return(t_get('sB1'), t68_ret_item('siB1', 1), 'refund', gen_random_uuid(), 'diger', NULL, t_get('sessB68'), NULL) $q$, 'REFUND_METHOD_REQUIRED');
SELECT t_err('T68i cash refund needs an open session', $q$ SELECT rpc_pos_return(t_get('sB1'), t68_ret_item('siB1', 1), 'refund', gen_random_uuid(), 'diger', NULL, NULL, 'cash') $q$, 'REGISTER_REQUIRED');
SELECT t_err('T68i cash refund on a session of another tenant', $q$ SELECT rpc_pos_return(t_get('sB1'), t68_ret_item('siB1', 1), 'refund', gen_random_uuid(), 'diger', NULL, t_get('sess68'), 'cash') $q$, 'REGISTER_REQUIRED');
SELECT t_err('T68i store credit disabled on B too', $q$ SELECT rpc_pos_return(t_get('sB1'), t68_ret_item('siB1', 1), 'store_credit', gen_random_uuid(), 'diger') $q$, 'STORE_CREDIT_NOT_ALLOWED');
SELECT t_set('ctB1', gen_random_uuid());
CREATE TEMP TABLE _t68_b1 AS SELECT rpc_pos_return(t_get('sB1'), t68_ret_item('siB1', 1), 'refund', t_get('ctB1'), 'diger', 'para iadesi', t_get('sessB68'), 'cash') AS r;
SELECT t_set('retB1', (SELECT (r ->> 'return_id')::uuid FROM _t68_b1));
SELECT t_check('T68i A. partial cash refund: 1 of 3, refund 10, cash out −10 referencing the return',
  (SELECT (r ->> 'credit_value_base')::numeric = 10 AND (r ->> 'refund_amount_base')::numeric = 10 AND NOT (r ->> 'replayed')::boolean FROM _t68_b1)
  AND (SELECT return_type = 'refund' AND refund_method = 'cash' AND refund_amount_base = 10 AND reason_code = 'diger' FROM returns WHERE id = t_get('retB1'))
  AND (SELECT count(*) FROM cash_movements WHERE reference_type = 'return' AND reference_id = t_get('retB1') AND movement_type = 'refund_cash_out' AND amount = -10 AND register_session_id = t_get('sessB68')) = 1
  AND (SELECT returned_quantity FROM v_sale_item_returned WHERE sale_item_id = t_get('siB1')) = 1);
SELECT t_check('T68i plain return double submit replays', (SELECT (r ->> 'replayed')::boolean AND (r ->> 'return_id')::uuid = t_get('retB1')
  FROM rpc_pos_return(t_get('sB1'), t68_ret_item('siB1', 1), 'refund', t_get('ctB1'), 'diger', 'para iadesi', t_get('sessB68'), 'cash') r));
SELECT t_err('T68i plain return: same id, different quantity refused', $q$ SELECT rpc_pos_return(t_get('sB1'), t68_ret_item('siB1', 2), 'refund', t_get('ctB1'), 'diger', NULL, t_get('sessB68'), 'cash') $q$, 'IDEMPOTENCY_CONFLICT');
SELECT t_check('T68i replay left one return / one refund movement', (SELECT count(*) FROM returns WHERE original_sale_id = t_get('sB1')) = 1 AND (SELECT count(*) FROM cash_movements WHERE reference_id = t_get('retB1')) = 1);
SELECT t_set('retB2', (SELECT (r ->> 'return_id')::uuid FROM rpc_pos_return(t_get('sB1'), t68_ret_item('siB1', 1), 'refund', gen_random_uuid(), 'diger', NULL, NULL, 'card') r));
SELECT t_check('T68i B. second partial refund to the original card: recorded, no cash movement, returned 2 of 3',
  (SELECT refund_method = 'card' AND refund_amount_base = 10 FROM returns WHERE id = t_get('retB2'))
  AND (SELECT count(*) FROM cash_movements WHERE reference_id = t_get('retB2')) = 0
  AND (SELECT returned_quantity FROM v_sale_item_returned WHERE sale_item_id = t_get('siB1')) = 2);
SELECT t_err('T68i C. over-return: 2 requested, 1 left', $q$ SELECT rpc_pos_return(t_get('sB1'), t68_ret_item('siB1', 2), 'refund', gen_random_uuid(), 'diger', NULL, t_get('sessB68'), 'cash') $q$, 'OVER_RETURN');
SELECT t_set('ctB3', gen_random_uuid());
CREATE TEMP TABLE _t68_b3 AS SELECT rpc_pos_exchange(t_get('sessB68'), t_get('sB2'), t68_ret_item('siB2', 1, 'sellable'), t_json_items('vB','1',NULL), '[]'::jsonb, t_get('ctB3'), 'renk_degisimi') AS r;
SELECT t_set('retB3', (SELECT (r -> 'return' ->> 'return_id')::uuid FROM _t68_b3));
SELECT t_check('T68i D. downgrade under cash_refund policy: credit 25, replacement 10 → applied 10, refund 15 in cash, due 0',
  (SELECT (r ->> 'total')::numeric = 10 AND (r ->> 'amount_due')::numeric = 0 AND (r ->> 'credit_applied')::numeric = 10 AND (r ->> 'refund_amount_base')::numeric = 15 FROM _t68_b3)
  AND (SELECT return_type = 'exchange' AND credit_value_base = 25 AND refund_amount_base = 15 AND refund_method = 'cash' FROM returns WHERE id = t_get('retB3'))
  AND (SELECT count(*) FROM cash_movements WHERE reference_id = t_get('retB3') AND movement_type = 'refund_cash_out' AND amount = -15) = 1
  AND (SELECT credit_applied_base = 10 AND total = 10 AND amount_due_base = 0 FROM sales WHERE id = (SELECT replacement_sale_id FROM returns WHERE id = t_get('retB3'))));
SELECT t_check('T68i drawer arithmetic: 50 open + 30 sale − 10 refund − 15 refund = 55 expected',
  (SELECT 50 + COALESCE(SUM(amount), 0) FROM cash_movements WHERE register_session_id = t_get('sessB68') AND currency = 'TRY') = 55);
SELECT t_ok('T68i owner closes B''s drawer', $q$ SELECT rpc_close_register_session(t_get('sessB68'), '[{"currency":"TRY","counted_amount":55}]'::jsonb) $q$);
SELECT t_err('T68i cash refund after close refused', $q$ SELECT rpc_pos_return(t_get('sB1'), t68_ret_item('siB1', 1), 'refund', gen_random_uuid(), 'diger', NULL, t_get('sessB68'), 'cash') $q$, 'REGISTER_REQUIRED');
SELECT t_err('T68i exchange on the closed session refused', $q$ SELECT rpc_pos_exchange(t_get('sessB68'), t_get('sB1'), t68_ret_item('siB1', 1), t_json_items('vB','1',NULL), '[]'::jsonb, gen_random_uuid(), 'diger') $q$, 'REGISTER_CLOSED');
SELECT t_logout();

-- ---------------------------------------------------------------- visibility + immutability
SELECT t_login('u3');
SELECT t_check('T68j cashier sees the returns of their own sale but no COGS reversal',
  t_count($q$ SELECT count(*) FROM returns WHERE original_sale_id = t_get('s68') $q$) = 3 AND t_count($q$ SELECT count(*) FROM return_item_costs $q$) = 0
  AND t_count($q$ SELECT count(*) FROM return_items WHERE sale_item_id = t_get('si68') $q$) = 3);
SELECT t_check('T68j cashier reads the return document (no cost inside)', (SELECT d IS NOT NULL AND NOT (d::text ~ 'cost') FROM rpc_return_document(t_get('ret68j')) d));
SELECT t_err('T68j cashier cannot insert a return', $q$ INSERT INTO returns (business_id, branch_id, original_sale_id, return_number, return_type, processed_by) VALUES (t_get('biz'), t_get('br68'), t_get('s68'), 'R-HACK', 'refund', t_get('u3')) $q$, '42501');
SELECT t_logout();
SELECT t_login('u4');
SELECT t_check('T68j stock_staff sees no return document', (SELECT d IS NULL FROM rpc_return_document(t_get('ret68j')) d) AND t_count($q$ SELECT count(*) FROM return_item_costs $q$) = 0);
SELECT t_logout();
SELECT t_login('u5');
SELECT t_check('T68j other tenant sees nothing of A''s returns', t_count($q$ SELECT count(*) FROM returns WHERE business_id = t_get('biz') $q$) = 0 AND (SELECT d IS NULL FROM rpc_return_document(t_get('ret68j')) d));
SELECT t_logout();
SELECT t_login('u2');
SELECT t_check('T68j manager reads the COGS reversal rows', t_count($q$ SELECT count(*) FROM return_item_costs WHERE business_id = t_get('biz') $q$) >= 4);
SELECT t_logout();
SELECT t_err('T68j return header immutable', $q$ UPDATE returns SET credit_value_base = 1 WHERE id = t_get('ret68j') $q$, 'IMMUTABLE');
SELECT t_err('T68j return items immutable', $q$ DELETE FROM return_items WHERE return_id = t_get('ret68j') $q$, 'IMMUTABLE');
SELECT t_err('T68j COGS reversal record immutable', $q$ UPDATE return_item_costs SET line_cost_base = 0 WHERE business_id = t_get('biz') $q$, 'IMMUTABLE');
SELECT t_err('T68j replacement sale immutable', $q$ UPDATE sales SET total = 1 WHERE id = t_get('xs68j') $q$, 'IMMUTABLE');
SELECT t_check('T68j privileges: POS return RPCs to authenticated, cores hidden',
  has_function_privilege('authenticated', 'rpc_pos_return(uuid,jsonb,return_type,uuid,text,text,uuid,payment_method)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_pos_exchange(uuid,uuid,jsonb,jsonb,jsonb,uuid,text,text,uuid,uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_return_core_ext(uuid,uuid,uuid,jsonb,return_type,text,text,uuid,uuid,uuid,payment_method,text,uuid,text,numeric)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_sale_quote(uuid,jsonb)', 'EXECUTE'));


-- ============================================================
-- T69 — Phase 10A customers + reservations: normalisation, duplicates as warnings, search,
--       PII roles, reservation hold/availability (no movement), create/edit/cancel/expire,
--       POS fulfilment in one transaction, immutability, cross-tenant.
-- ============================================================
SELECT t_logout();
WITH x AS (INSERT INTO branches (business_id, name, code) VALUES (t_get('biz'), 'Rezervasyon Şubesi', 'RSV') RETURNING id) SELECT t_set('br69', id) FROM x;
WITH x AS (INSERT INTO cash_registers (business_id, branch_id, name) VALUES (t_get('biz'), t_get('br69'), 'Kasa 69') RETURNING id) SELECT t_set('reg69', id) FROM x;
WITH x AS (INSERT INTO products (business_id, category_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('biz'), t_get('cat_elbise'), 'Rezervasyon Elbise', 'RSV-69', 300, 'active') RETURNING id) SELECT t_set('p69', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p69'), 'RSV-69-S') RETURNING id) SELECT t_set('v69s', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v69s'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000001');
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('p69'), 'RSV-69-M') RETURNING id) SELECT t_set('v69m', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v69m'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000002');
WITH x AS (INSERT INTO product_variants (product_id, sku, status) VALUES (t_get('p69'), 'RSV-69-L', 'archived') RETURNING id) SELECT t_set('v69l', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('v69l'), t_get('opt_size'), 'c1000000-0000-4000-8000-000000000003');
SELECT t_login('u2');
SELECT t_ok('T69 fixture stock (br69): S 3@100, M 1@100', $q$
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br69'), t_get('v69s'), 'sellable', 3, 'rsv fixture', 'manual_cost', 100);
  SELECT rpc_post_inventory_adjustment(t_get('biz'), t_get('br69'), t_get('v69m'), 'sellable', 1, 'rsv fixture', 'manual_cost', 100) $q$);
SELECT t_set('sess69', rpc_open_register_session(t_get('reg69'), '[]'::jsonb));
SELECT t_logout();
CREATE TEMP TABLE _t69_base AS SELECT (SELECT count(*) FROM inventory_movements) AS movements, (SELECT on_hand_qty FROM variant_cost_pools WHERE variant_id = t_get('v69s') AND branch_id = t_get('br69')) AS s_on_hand;
GRANT SELECT ON _t69_base TO authenticated;

-- ---------------------------------------------------------------- customers: create (sales_staff), normalisation, source
SELECT t_login('u3');
WITH x AS (INSERT INTO customers (business_id, full_name, phone, email, instagram, source, notes) VALUES (t_get('biz'), 'Ayşe Rezerve', '0555 123 45 67', ' Ayse@Test.COM ', '@Ayse_T', 'instagram', 'DM ile ulaştı') RETURNING id) SELECT t_set('c69a', id) FROM x;
SELECT t_check('T69a sales_staff created a customer: phone/email/instagram normalised, display kept, created_by stamped',
  (SELECT phone = '0555 123 45 67' AND phone_normalized = '905551234567' AND email = 'Ayse@Test.COM' AND email_normalized = 'ayse@test.com'
      AND instagram = 'Ayse_T' AND instagram_normalized = 'ayse_t' AND source = 'instagram' AND created_by = t_get('u3') AND is_active
   FROM customers WHERE id = t_get('c69a')));
WITH x AS (INSERT INTO customers (business_id, full_name, source) VALUES (t_get('biz'), 'Elif Telefonsuz', 'walk_in') RETURNING id) SELECT t_set('c69b', id) FROM x;
SELECT t_check('T69a phone and email are optional', (SELECT phone IS NULL AND phone_normalized IS NULL AND email IS NULL FROM customers WHERE id = t_get('c69b')));
SELECT t_err('T69a unknown source refused', $q$ INSERT INTO customers (business_id, full_name, source) VALUES (t_get('biz'), 'X', 'tiktok') $q$, 'INVALID_SOURCE');
SELECT t_err('T69a malformed email refused', $q$ INSERT INTO customers (business_id, full_name, email) VALUES (t_get('biz'), 'X', 'not-an-email') $q$, 'chk_customer_email');
SELECT t_err('T69a empty name refused', $q$ INSERT INTO customers (business_id, full_name, phone) VALUES (t_get('biz'), '  ', '0555') $q$, 'chk_customer_name');
SELECT t_check('T69a phone normalisation cases',
  fn_normalize_phone('+90 (555) 123 45 67') = '905551234567' AND fn_normalize_phone('5551234567') = '905551234567' AND fn_normalize_phone('05551234567') = '905551234567'
  AND fn_normalize_phone('00905551234567') = '905551234567' AND fn_normalize_phone('+44 20 7946 0958') = '442079460958' AND fn_normalize_phone('   ') IS NULL
  AND fn_normalize_instagram('@@Ayse_T ') = 'ayse_t' AND fn_normalize_instagram('') IS NULL);
-- duplicates are a warning, never a constraint: the same normalised phone may be stored twice
WITH x AS (INSERT INTO customers (business_id, full_name, phone) VALUES (t_get('biz'), 'Ayşe İkinci', '+90 555 123 45 67') RETURNING id) SELECT t_set('c69dup', id) FROM x;
SELECT t_check('T69b same normalised phone stored (intentional duplicate possible), probe reports it',
  (SELECT phone_normalized FROM customers WHERE id = t_get('c69dup')) = '905551234567'
  AND (SELECT jsonb_array_length(d) = 2 AND (SELECT bool_and(x ->> 'match' = 'phone') FROM jsonb_array_elements(d) x) FROM rpc_customer_duplicates(t_get('biz'), '5551234567') d));
SELECT t_check('T69b probe by email / instagram / exclude self',
  (SELECT jsonb_array_length(d) = 1 AND d -> 0 ->> 'match' = 'email' FROM rpc_customer_duplicates(t_get('biz'), NULL, 'AYSE@test.com') d)
  AND (SELECT jsonb_array_length(d) = 1 AND d -> 0 ->> 'match' = 'instagram' FROM rpc_customer_duplicates(t_get('biz'), NULL, NULL, '@AYSE_t') d)
  AND (SELECT jsonb_array_length(d) = 1 FROM rpc_customer_duplicates(t_get('biz'), '0555 123 45 67', NULL, NULL, t_get('c69a')) d)
  AND (SELECT jsonb_array_length(d) = 0 FROM rpc_customer_duplicates(t_get('biz'), '0555 999 99 99') d));
SELECT t_check('T69c search by name / phone fragment / email / instagram, limited, short query empty',
  (SELECT jsonb_array_length(r) >= 1 AND r -> 0 ->> 'full_name' LIKE 'Ayşe%' FROM rpc_customer_search(t_get('biz'), 'ayşe') r)
  AND (SELECT jsonb_array_length(r) = 2 FROM rpc_customer_search(t_get('biz'), '555 123') r)
  AND (SELECT jsonb_array_length(r) = 1 AND (r -> 0 ->> 'id')::uuid = t_get('c69a') FROM rpc_customer_search(t_get('biz'), 'ayse@test') r)
  AND (SELECT jsonb_array_length(r) = 1 FROM rpc_customer_search(t_get('biz'), '@ayse_t') r)
  AND (SELECT jsonb_array_length(r) = 0 FROM rpc_customer_search(t_get('biz'), 'a') r)
  AND (SELECT jsonb_array_length(r) = 1 FROM rpc_customer_search(t_get('biz'), 'ayşe', 1) r));
SELECT t_check('T69c search results carry no cost / cache-of-money beyond order_count', (SELECT NOT (r::text ~ 'cost|total_spent') FROM rpc_customer_search(t_get('biz'), 'ayşe') r));
SELECT t_ok('T69c sales_staff edits operational fields', $q$ UPDATE customers SET notes = 'beden M', instagram = '@ayse_yeni' WHERE id = t_get('c69a') $q$);
SELECT t_check('T69c edit normalised again', (SELECT instagram = 'ayse_yeni' AND instagram_normalized = 'ayse_yeni' FROM customers WHERE id = t_get('c69a')));
SELECT t_err('T69c sales_staff cannot touch the sale caches', $q$ UPDATE customers SET total_spent = 999 WHERE id = t_get('c69a') $q$, '42501');
SELECT t_err('T69c customers are never deleted', $q$ DELETE FROM customers WHERE id = t_get('c69dup') $q$, '42501');
SELECT t_err('T69c sales_staff cannot archive a customer (20260916220000)', $q$ UPDATE customers SET is_active = false WHERE id = t_get('c69dup') $q$, 'archive or restore');
SELECT t_err('T69c sales_staff cannot add a tenant source', $q$ INSERT INTO customer_sources (business_id, code, label) VALUES (t_get('biz'), 'fuar', 'Fuar') $q$, '42501');
SELECT t_logout();
SELECT t_login('u2');
SELECT t_ok('T69c manager adds a tenant source', $q$ INSERT INTO customer_sources (business_id, code, label) VALUES (t_get('biz'), 'fuar', 'Fuar') $q$);
SELECT t_ok('T69c …and a customer may use it', $q$ UPDATE customers SET source = 'fuar' WHERE id = t_get('c69b') $q$);
SELECT t_ok('T69c manager archives and restores a customer', $q$ UPDATE customers SET is_active = false WHERE id = t_get('c69dup'); UPDATE customers SET is_active = true WHERE id = t_get('c69dup') $q$);
SELECT t_logout();
SELECT t_login('u4');
SELECT t_check('T69d stock_staff has no CRM: 0 customers, 0 sources of the tenant beyond defaults', t_count($q$ SELECT count(*) FROM customers $q$) = 0);
SELECT t_err('T69d stock_staff cannot create a customer', $q$ INSERT INTO customers (business_id, full_name) VALUES (t_get('biz'), 'Depo') $q$, '42501');
SELECT t_err('T69d stock_staff cannot search', $q$ SELECT rpc_customer_search(t_get('biz'), 'ayşe') $q$, 'FORBIDDEN');
SELECT t_err('T69d stock_staff cannot probe duplicates', $q$ SELECT rpc_customer_duplicates(t_get('biz'), '0555') $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u5');
SELECT t_check('T69d other tenant reads nothing', t_count($q$ SELECT count(*) FROM customers WHERE business_id = t_get('biz') $q$) = 0);
SELECT t_err('T69d other tenant cannot search A (business_id tampering)', $q$ SELECT rpc_customer_search(t_get('biz'), 'ayşe') $q$, 'FORBIDDEN');
SELECT t_err('T69d other tenant cannot insert into A', $q$ INSERT INTO customers (business_id, full_name) VALUES (t_get('biz'), 'Hile') $q$, '42501');
SELECT t_logout();

-- ---------------------------------------------------------------- reservations: hold without movement
SELECT t_login('u3');
CREATE TEMP TABLE _t69_r1 AS SELECT rpc_pos_reservation_create(t_get('br69'), t_get('c69a'), t_json_items('v69s','1',NULL,'v69s','1',NULL,'v69m','1',NULL), NULL, 'akşam gelecek', 'whatsapp') AS r;
SELECT t_set('rv1', (SELECT (r ->> 'reservation_id')::uuid FROM _t69_r1));
SELECT t_check('T69e reservation created by sales_staff: RV number, default expiry ≈ 48 h, lines merged (S×2, M×1)',
  (SELECT (r ->> 'reservation_number') LIKE 'RV-%' AND (r ->> 'expires_at')::timestamptz BETWEEN now() + interval '47 hours' AND now() + interval '49 hours' AND jsonb_array_length(r -> 'lines') = 2 FROM _t69_r1)
  AND (SELECT status = 'active' AND customer_id = t_get('c69a') AND source = 'whatsapp' AND note = 'akşam gelecek' AND created_by = t_get('u3') FROM reservations WHERE id = t_get('rv1'))
  AND (SELECT quantity FROM reservation_items WHERE reservation_id = t_get('rv1') AND variant_id = t_get('v69s')) = 2);
SELECT t_check('T69e availability: S 3 on hand → 1 available, M 1 → 0; on_hand and the ledger untouched',
  (SELECT sellable_quantity = 3 AND reserved_quantity = 2 AND available_quantity = 1 FROM v_stock_available WHERE variant_id = t_get('v69s') AND branch_id = t_get('br69'))
  AND (SELECT available_quantity = 0 FROM v_stock_available WHERE variant_id = t_get('v69m') AND branch_id = t_get('br69')));
SELECT t_logout();
SELECT t_check('T69e no inventory movement, pool unchanged', (SELECT count(*) FROM inventory_movements) = (SELECT movements FROM _t69_base) AND (SELECT on_hand_qty FROM variant_cost_pools WHERE variant_id = t_get('v69s') AND branch_id = t_get('br69')) = (SELECT s_on_hand FROM _t69_base));
SELECT t_login('u3');
SELECT t_err('T69f second hold beyond availability (S 2 requested, 1 available)', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), t_get('c69b'), t_json_items('v69s','2',NULL)) $q$, 'INSUFFICIENT_AVAILABLE_STOCK');
SELECT t_err('T69f held-out variant (M available 0)', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), t_get('c69b'), t_json_items('v69m','1',NULL)) $q$, 'INSUFFICIENT_AVAILABLE_STOCK');
SELECT t_err('T69f foreign customer', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), t_get('custB'), t_json_items('v69s','1',NULL)) $q$, 'INVALID_CUSTOMER');
SELECT t_err('T69f customer required', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), NULL, t_json_items('v69s','1',NULL)) $q$, 'INVALID_CUSTOMER');
SELECT t_err('T69f foreign branch', $q$ SELECT rpc_pos_reservation_create(t_get('brB'), t_get('c69a'), t_json_items('v69s','1',NULL)) $q$, 'INVALID_BRANCH');
SELECT t_err('T69f foreign variant', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), t_get('c69a'), t_json_items('vB','1',NULL)) $q$, 'INVALID_VARIANT');
SELECT t_err('T69f archived variant', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), t_get('c69a'), t_json_items('v69l','1',NULL)) $q$, 'VARIANT_NOT_SELLABLE');
SELECT t_err('T69f expiry in the past', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), t_get('c69a'), t_json_items('v69s','1',NULL), now() - interval '1 hour') $q$, 'INVALID_EXPIRY');
SELECT t_err('T69f expiry beyond 90 days', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), t_get('c69a'), t_json_items('v69s','1',NULL), now() + interval '91 days') $q$, 'INVALID_EXPIRY');
SELECT t_err('T69f empty items', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), t_get('c69a'), '[]'::jsonb) $q$, 'EMPTY_RESERVATION');
SELECT t_err('T69f zero quantity', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), t_get('c69a'), t_json_items('v69s','0',NULL)) $q$, 'INVALID_QTY');
SELECT t_err('T69f direct insert refused', $q$ INSERT INTO reservations (business_id, branch_id, reservation_number, customer_id, expires_at) VALUES (t_get('biz'), t_get('br69'), 'RV-HACK', t_get('c69a'), now() + interval '1 day') $q$, '42501');
SELECT t_logout();
SELECT t_check('T69f refused holds wrote nothing', (SELECT count(*) FROM reservations WHERE business_id = t_get('biz') AND branch_id = t_get('br69')) = 1);
SELECT t_login('u4');
SELECT t_err('T69f stock_staff cannot reserve', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), t_get('c69a'), t_json_items('v69s','1',NULL)) $q$, 'FORBIDDEN');
SELECT t_check('T69f stock_staff sees no reservations', t_count($q$ SELECT count(*) FROM reservations $q$) = 0 AND t_count($q$ SELECT count(*) FROM reservation_items $q$) = 0);
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T69f other tenant cannot reserve on A''s branch', $q$ SELECT rpc_pos_reservation_create(t_get('br69'), t_get('custB'), t_json_items('v69s','1',NULL)) $q$, 'INVALID_BRANCH');
SELECT t_err('T69f other tenant cannot cancel A''s reservation', $q$ SELECT rpc_reservation_cancel(t_get('rv1'), 'x') $q$, 'NOT_FOUND');
SELECT t_err('T69f other tenant cannot edit A''s reservation', $q$ SELECT rpc_reservation_update(t_get('rv1'), t_json_items('v69s','1',NULL)) $q$, 'NOT_FOUND');
SELECT t_check('T69f other tenant sees none of A''s reservations', t_count($q$ SELECT count(*) FROM reservations WHERE business_id = t_get('biz') $q$) = 0);
SELECT t_logout();

-- POS respects other customers' holds
SELECT t_login('u3');
SELECT t_err('T69g plain POS sale cannot take held stock (S: 3 on hand, 1 available, 2 requested)', $q$ SELECT rpc_pos_complete_sale(t_get('sess69'), t_json_items('v69s','2',NULL), t_pay('cash','TRY',600), gen_random_uuid()) $q$, 'INSUFFICIENT_STOCK');
SELECT t_set('s69free', (rpc_pos_complete_sale(t_get('sess69'), t_json_items('v69s','1',NULL), t_pay('cash','TRY',300), gen_random_uuid()) ->> 'sale_id')::uuid);
SELECT t_check('T69g …the free unit sells; available now 0, hold intact', (SELECT available_quantity = 0 AND reserved_quantity = 2 AND sellable_quantity = 2 FROM v_stock_available WHERE variant_id = t_get('v69s') AND branch_id = t_get('br69')));

-- edit
SELECT t_err('T69h edit beyond availability (S 3 requested, 2 sellable) rejected', $q$ SELECT rpc_reservation_update(t_get('rv1'), t_json_items('v69s','3',NULL,'v69m','1',NULL)) $q$, 'INSUFFICIENT_AVAILABLE_STOCK');
SELECT t_check('T69h rejected edit left the items untouched (atomic)', (SELECT quantity FROM reservation_items WHERE reservation_id = t_get('rv1') AND variant_id = t_get('v69s')) = 2 AND (SELECT count(*) FROM reservation_items WHERE reservation_id = t_get('rv1')) = 2);
CREATE TEMP TABLE _t69_upd AS SELECT rpc_reservation_update(t_get('rv1'), t_json_items('v69s','1',NULL), now() + interval '3 days', 'yarın alacak') AS r;
SELECT t_check('T69h edit down to S×1, drop M, new expiry + note',
  (SELECT jsonb_array_length(r -> 'lines') = 1 FROM _t69_upd)
  AND (SELECT count(*) FROM reservation_items WHERE reservation_id = t_get('rv1')) = 1
  AND (SELECT note = 'yarın alacak' AND expires_at BETWEEN now() + interval '71 hours' AND now() + interval '73 hours' AND updated_by = t_get('u3') FROM reservations WHERE id = t_get('rv1'))
  AND (SELECT available_quantity = 1 FROM v_stock_available WHERE variant_id = t_get('v69s') AND branch_id = t_get('br69'))
  AND (SELECT available_quantity = 1 FROM v_stock_available WHERE variant_id = t_get('v69m') AND branch_id = t_get('br69')),
  (SELECT 'items=' || (SELECT count(*) FROM reservation_items WHERE reservation_id = t_get('rv1')) || ' note=' || coalesce(note,'-') || ' exp=' || expires_at || ' ub=' || coalesce(updated_by::text,'-') || ' availS=' || (SELECT available_quantity FROM v_stock_available WHERE variant_id = t_get('v69s') AND branch_id = t_get('br69')) || ' availM=' || (SELECT available_quantity FROM v_stock_available WHERE variant_id = t_get('v69m') AND branch_id = t_get('br69')) FROM reservations WHERE id = t_get('rv1')));
SELECT t_err('T69h edit with a foreign variant', $q$ SELECT rpc_reservation_update(t_get('rv1'), t_json_items('vB','1',NULL)) $q$, 'INVALID_VARIANT');
SELECT t_logout();

-- ---------------------------------------------------------------- cancel releases; expiry releases without cleanup
SELECT t_login('u3');
SELECT t_set('rv2', (rpc_pos_reservation_create(t_get('br69'), t_get('c69b'), t_json_items('v69m','1',NULL), now() + interval '2 hours', NULL, 'instagram') ->> 'reservation_id')::uuid);
SELECT t_check('T69i second hold takes M', (SELECT available_quantity = 0 FROM v_stock_available WHERE variant_id = t_get('v69m') AND branch_id = t_get('br69')));
CREATE TEMP TABLE _t69_cnl AS SELECT rpc_reservation_cancel(t_get('rv2'), 'müşteri vazgeçti') AS r;
SELECT t_check('T69i cancel releases at once, records actor/time/reason',
  (SELECT r ->> 'status' = 'cancelled' FROM _t69_cnl)
  AND (SELECT status = 'cancelled' AND cancelled_by = t_get('u3') AND cancelled_at IS NOT NULL AND cancel_reason = 'müşteri vazgeçti' FROM reservations WHERE id = t_get('rv2'))
  AND (SELECT available_quantity = 1 FROM v_stock_available WHERE variant_id = t_get('v69m') AND branch_id = t_get('br69')),
  (SELECT status::text || ' cb=' || coalesce(cancelled_by::text,'-') || ' reason=' || coalesce(cancel_reason,'-') || ' availM=' || (SELECT available_quantity FROM v_stock_available WHERE variant_id = t_get('v69m') AND branch_id = t_get('br69')) FROM reservations WHERE id = t_get('rv2')));
SELECT t_err('T69i cancelled cannot be cancelled again', $q$ SELECT rpc_reservation_cancel(t_get('rv2'), 'x') $q$, 'INVALID_STATE');
SELECT t_err('T69i cancelled cannot be edited', $q$ SELECT rpc_reservation_update(t_get('rv2'), t_json_items('v69m','1',NULL)) $q$, 'INVALID_STATE');
SELECT t_logout();
SELECT t_check('T69i no movement from hold + cancel', (SELECT count(*) FROM inventory_movements) = (SELECT movements FROM _t69_base) + 1);
SELECT t_err('T69i cancelled reservation frozen (maintenance role too)', $q$ UPDATE reservations SET note = 'x' WHERE id = t_get('rv2') $q$, 'IMMUTABLE');
SELECT t_err('T69i items of a cancelled reservation frozen', $q$ DELETE FROM reservation_items WHERE reservation_id = t_get('rv2') $q$, 'IMMUTABLE');
SELECT t_err('T69i reservations are never deleted', $q$ DELETE FROM reservations WHERE id = t_get('rv2') $q$, 'IMMUTABLE');
-- expiry: the row stays ACTIVE (no cleanup ran) but no longer holds stock
SELECT t_login('u3');
SELECT t_set('rv3', (rpc_pos_reservation_create(t_get('br69'), t_get('c69b'), t_json_items('v69m','1',NULL), now() + interval '1 hour') ->> 'reservation_id')::uuid);
SELECT t_logout();
UPDATE reservations SET expires_at = now() - interval '1 minute' WHERE id = t_get('rv3');   -- simulate the clock
SELECT t_check('T69j an expired ACTIVE row no longer reduces availability (no cleanup dependency)',
  (SELECT status = 'active' FROM reservations WHERE id = t_get('rv3')) AND (SELECT available_quantity = 1 AND reserved_quantity = 0 FROM v_stock_available WHERE variant_id = t_get('v69m') AND branch_id = t_get('br69')));
SELECT t_login('u3');
SELECT t_err('T69j expired hold cannot be fulfilled', $q$ SELECT rpc_pos_complete_sale(t_get('sess69'), t_json_items('v69m','1',NULL), t_pay('cash','TRY',300), gen_random_uuid(), NULL, NULL, NULL, NULL, NULL, t_get('rv3')) $q$, 'RESERVATION_NOT_ACTIVE');
SELECT t_err('T69j expired hold cannot be edited', $q$ SELECT rpc_reservation_update(t_get('rv3'), t_json_items('v69m','1',NULL)) $q$, 'RESERVATION_EXPIRED');
CREATE TEMP TABLE _t69_exp AS SELECT rpc_reservations_expire(t_get('biz')) AS n;
SELECT t_check('T69j cleanup marks it EXPIRED (1 row)', (SELECT n = 1 FROM _t69_exp) AND (SELECT status = 'expired' FROM reservations WHERE id = t_get('rv3')), (SELECT status::text || ' exp=' || expires_at FROM reservations WHERE id = t_get('rv3')));
SELECT t_err('T69j expired cannot be cancelled', $q$ SELECT rpc_reservation_cancel(t_get('rv3'), 'x') $q$, 'INVALID_STATE');
SELECT t_check('T69j cleanup is idempotent', rpc_reservations_expire(t_get('biz')) = 0);
SELECT t_logout();

-- ---------------------------------------------------------------- fulfil through the POS in one transaction
SELECT t_login('u3');
SELECT t_err('T69k cart missing the held item → RESERVATION_MISMATCH', $q$ SELECT rpc_pos_complete_sale(t_get('sess69'), t_json_items('v69m','1',NULL), t_pay('cash','TRY',300), gen_random_uuid(), NULL, NULL, NULL, NULL, NULL, t_get('rv1')) $q$, 'RESERVATION_MISMATCH');
SELECT t_err('T69k session of another branch → INVALID_RESERVATION', $q$ SELECT rpc_pos_complete_sale(t_get('sess66b'), t_json_items('v69s','1',NULL), t_pay('cash','TRY',300), gen_random_uuid(), NULL, NULL, NULL, NULL, NULL, t_get('rv1')) $q$, 'INVALID_RESERVATION');
SELECT t_err('T69k reservation of another tenant → INVALID_RESERVATION', $q$ SELECT rpc_pos_complete_sale(t_get('sess69'), t_json_items('v69s','1',NULL), t_pay('cash','TRY',300), gen_random_uuid(), NULL, NULL, NULL, NULL, NULL, gen_random_uuid()) $q$, 'INVALID_RESERVATION');
SELECT t_check('T69k refused fulfilments left the hold active', (SELECT status = 'active' FROM reservations WHERE id = t_get('rv1')));
CREATE TEMP TABLE _t69_sale AS SELECT rpc_pos_complete_sale(t_get('sess69'), t_json_items('v69s','1',NULL,'v69m','1',NULL), t_pay('cash','TRY',600), gen_random_uuid(), NULL, NULL, NULL, 'rezervasyon teslim', NULL, t_get('rv1')) AS r;
SELECT t_set('s69rv', (SELECT (r ->> 'sale_id')::uuid FROM _t69_sale));
SELECT t_logout();
SELECT t_check('T69k fulfilled: sale completed with the held item + an extra, customer taken from the hold, reservation converted and linked in the same transaction',
  (SELECT status = 'completed' AND total = 600 AND customer_id = t_get('c69a') AND sold_by = t_get('u3') FROM sales WHERE id = t_get('s69rv'))
  AND (SELECT status = 'converted' AND converted_to_sale_id = t_get('s69rv') AND fulfilled_at IS NOT NULL AND fulfilled_by = t_get('u3') FROM reservations WHERE id = t_get('rv1'))
  AND (SELECT count(*) FROM inventory_movements WHERE reference_type = 'sale_item' AND reference_id IN (SELECT id FROM sale_items WHERE sale_id = t_get('s69rv'))) = 2
  AND (SELECT sellable_quantity = 1 AND reserved_quantity = 0 AND available_quantity = 1 FROM v_stock_available WHERE variant_id = t_get('v69s') AND branch_id = t_get('br69')));
SELECT t_check('T69k customer history: 1 order / 600 spent from the fulfilled sale', (SELECT order_count = 1 AND total_spent = 600 AND last_purchase_at IS NOT NULL FROM customers WHERE id = t_get('c69a')), (SELECT order_count || '/' || total_spent FROM customers WHERE id = t_get('c69a')));
SELECT t_login('u3');
SELECT t_err('T69l fulfilled reservation cannot be cancelled', $q$ SELECT rpc_reservation_cancel(t_get('rv1'), 'x') $q$, 'INVALID_STATE');
SELECT t_err('T69l fulfilled reservation cannot be edited', $q$ SELECT rpc_reservation_update(t_get('rv1'), t_json_items('v69s','1',NULL)) $q$, 'INVALID_STATE');
SELECT t_err('T69l fulfilled reservation cannot be fulfilled twice', $q$ SELECT rpc_pos_complete_sale(t_get('sess69'), t_json_items('v69s','1',NULL), t_pay('cash','TRY',300), gen_random_uuid(), NULL, NULL, NULL, NULL, NULL, t_get('rv1')) $q$, 'RESERVATION_NOT_ACTIVE');
SELECT t_logout();
SELECT t_err('T69l fulfilled reservation frozen', $q$ UPDATE reservations SET note = 'x' WHERE id = t_get('rv1') $q$, 'IMMUTABLE');
SELECT t_login('u3');
SELECT t_set('rv4', (rpc_pos_reservation_create(t_get('br69'), t_get('c69b'), t_json_items('v69s','1',NULL)) ->> 'reservation_id')::uuid);
SELECT t_logout();
SELECT t_err('T69l a linked sale cannot be faked onto an active reservation', $q$ UPDATE reservations SET converted_to_sale_id = t_get('s69free') WHERE id = t_get('rv4') $q$, 'INTEGRITY');
SELECT t_err('T69l fulfilled status without a sale refused', $q$ UPDATE reservations SET status = 'converted' WHERE id = t_get('rv4') $q$, 'INTEGRITY');
SELECT t_check('T69l privileges: new POS signature to authenticated, old one gone, cores internal',
  has_function_privilege('authenticated', 'rpc_pos_complete_sale(uuid,jsonb,jsonb,uuid,uuid,uuid,discount_reason,text,text,uuid)', 'EXECUTE')
  AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'rpc_pos_complete_sale' AND pronargs = 9)
  AND NOT has_function_privilege('authenticated', 'fn_reservation_hold(uuid,uuid,uuid,jsonb)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_pos_reservation_create(uuid,uuid,jsonb,timestamptz,text,text)', 'EXECUTE'));
SELECT t_login('u2');
SELECT t_check('T69m manager sees customers, reservations and the sale of the hold', t_count($q$ SELECT count(*) FROM customers WHERE business_id = t_get('biz') $q$) >= 3
  AND t_count($q$ SELECT count(*) FROM reservations WHERE business_id = t_get('biz') AND branch_id = t_get('br69') $q$) = 4
  AND t_count($q$ SELECT count(*) FROM sales WHERE id = t_get('s69rv') $q$) = 1);
SELECT t_logout();

-- ============================================================
-- T70 — Phase 10B reporting foundation: tenant timezone, window semantics, one-RPC-per-
--        surface aggregates proven against independently computed expectations, historical
--        COGS through returns/exchanges, payment vs drawer semantics, role model (financial
--        keys absent for sales_staff, stock_staff refused, other tenant refused).
-- Fixture: an isolated tenant (bizR) so every number is known in advance.
-- ============================================================
SELECT t_logout();
SELECT t_set('bizR', 'b0000000-0000-4000-8000-00000000000c');
INSERT INTO businesses (id, name, code, settings) VALUES (t_get('bizR'), 'Rapor Butik', 'RPT', jsonb_build_object(
  'accepted_currencies', jsonb_build_array('TRY'), 'sales_visibility_scope', 'own',
  'money_refund_allowed', true, 'store_credit_allowed', false, 'exchange_window_days', 14));
WITH x AS (INSERT INTO branches (business_id, name, code, is_default) VALUES (t_get('bizR'), 'Rapor Merkez', 'RM', true) RETURNING id) SELECT t_set('brR', id) FROM x;
INSERT INTO business_members (business_id, user_id, role) VALUES
  (t_get('bizR'), t_get('u1'), 'owner'), (t_get('bizR'), t_get('u2'), 'manager'),
  (t_get('bizR'), t_get('u3'), 'sales_staff'), (t_get('bizR'), t_get('u4'), 'stock_staff');
WITH x AS (INSERT INTO categories (business_id, name, slug) VALUES (t_get('bizR'), 'Elbise', 'elbise') RETURNING id) SELECT t_set('catR1', id) FROM x;
WITH x AS (INSERT INTO categories (business_id, name, slug) VALUES (t_get('bizR'), 'Çanta', 'canta') RETURNING id) SELECT t_set('catR2', id) FROM x;
WITH x AS (INSERT INTO product_options (business_id, name, kind, sort_order) VALUES (t_get('bizR'), 'Beden', 'size', 10) RETURNING id) SELECT t_set('optR_size', id) FROM x;
WITH x AS (INSERT INTO product_options (business_id, name, kind, sort_order) VALUES (t_get('bizR'), 'Renk', 'color', 5) RETURNING id) SELECT t_set('optR_color', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optR_size'), 'S', 'S', 1) RETURNING id) SELECT t_set('ovR_s', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optR_size'), 'M', 'M', 2) RETURNING id) SELECT t_set('ovR_m', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optR_color'), 'Siyah', 'SYH', 1) RETURNING id) SELECT t_set('ovR_syh', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optR_color'), 'Kırmızı', 'KRM', 2) RETURNING id) SELECT t_set('ovR_krm', id) FROM x;
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, category_id, status) VALUES (t_get('bizR'), 'Rapor Elbise', 'RP1', 500, t_get('catR1'), 'active') RETURNING id) SELECT t_set('pR1', id) FROM x;
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, category_id, status) VALUES (t_get('bizR'), 'Rapor Çanta', 'RP2', 200, t_get('catR2'), 'active') RETURNING id) SELECT t_set('pR2', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pR1'), 'RP1-S-SYH') RETURNING id) SELECT t_set('vR1s', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vR1s'), t_get('optR_size'), t_get('ovR_s')), (t_get('vR1s'), t_get('optR_color'), t_get('ovR_syh'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pR1'), 'RP1-M-SYH') RETURNING id) SELECT t_set('vR1m', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vR1m'), t_get('optR_size'), t_get('ovR_m')), (t_get('vR1m'), t_get('optR_color'), t_get('ovR_syh'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pR1'), 'RP1-M-KRM') RETURNING id) SELECT t_set('vR1k', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vR1k'), t_get('optR_size'), t_get('ovR_m')), (t_get('vR1k'), t_get('optR_color'), t_get('ovR_krm'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pR2'), 'RP2-STD') RETURNING id) SELECT t_set('vR2', id) FROM x;
WITH x AS (INSERT INTO cash_registers (business_id, branch_id, name) VALUES (t_get('bizR'), t_get('brR'), 'Rapor Kasa') RETURNING id) SELECT t_set('regR', id) FROM x;
WITH x AS (INSERT INTO customers (business_id, full_name, phone) VALUES (t_get('bizR'), 'Rapor Müşteri A', '+90 555 070 0001') RETURNING id) SELECT t_set('cR1', id) FROM x;
WITH x AS (INSERT INTO customers (business_id, full_name, phone) VALUES (t_get('bizR'), 'Rapor Müşteri B', '+90 555 070 0002') RETURNING id) SELECT t_set('cR2', id) FROM x;
WITH x AS (INSERT INTO suppliers (business_id, name, currency) VALUES (t_get('bizR'), 'Rapor Tedarikçi', 'TRY') RETURNING id) SELECT t_set('supR', id) FROM x;

-- A) privileges + timezone setting
SELECT t_check('T70a privileges: report RPCs to authenticated only, line sources and helpers internal',
  has_function_privilege('authenticated', 'rpc_report_overview(uuid,date,date,uuid,date,date)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_report_overview(uuid,date,date,uuid,date,date)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_report_sales(uuid,date,date,uuid,uuid,uuid,uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_report_products(uuid,date,date,uuid,text,uuid,integer)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_report_staff(uuid,date,date,uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_report_payments(uuid,date,date,uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_report_stock(uuid,uuid,integer)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_report_receiving(uuid,date,date,uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_report_customers(uuid,date,date,uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_report_returns(uuid,date,date,uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_business_set_timezone(uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_report_sale_lines(uuid,timestamptz,timestamptz,uuid,uuid,uuid,uuid,boolean,uuid,text,uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_report_return_lines(uuid,timestamptz,timestamptz,uuid,uuid,uuid,uuid,boolean,uuid,text,uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_report_access(uuid,boolean)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_report_window(uuid,date,date)', 'EXECUTE'));
SELECT t_check('T70a timezone default when the key is absent: Europe/Istanbul', fn_business_timezone(t_get('bizR')) = 'Europe/Istanbul');
SELECT t_err('T70a settings guard: an invalid timezone is refused on direct write',
  $q$ UPDATE businesses SET settings = settings || '{"timezone":"Mars/Olympus"}'::jsonb WHERE id = t_get('bizR') $q$, 'INVALID_TIMEZONE');
SELECT t_login('u3');
SELECT t_err('T70a sales_staff cannot set the timezone', $q$ SELECT rpc_business_set_timezone(t_get('bizR'), 'Asia/Nicosia') $q$, 'FORBIDDEN');
SELECT t_login('u5');
SELECT t_err('T70a other tenant cannot set the timezone', $q$ SELECT rpc_business_set_timezone(t_get('bizR'), 'Asia/Nicosia') $q$, 'FORBIDDEN');
SELECT t_login('u1');
SELECT t_err('T70a owner: invalid zone refused', $q$ SELECT rpc_business_set_timezone(t_get('bizR'), 'Europe/Lefkosa') $q$, 'INVALID_TIMEZONE');
SELECT t_ok('T70a owner sets Asia/Nicosia', $q$ SELECT rpc_business_set_timezone(t_get('bizR'), 'Asia/Nicosia') $q$);
SELECT t_logout();
SELECT t_check('T70a timezone stored and read back', fn_business_timezone(t_get('bizR')) = 'Asia/Nicosia'
  AND (SELECT settings ->> 'timezone' FROM businesses WHERE id = t_get('bizR')) = 'Asia/Nicosia');
SELECT t_check('T70a window: local calendar days in the tenant zone, [from, to+1) half-open',
  (SELECT ts_from = '2026-03-29 00:00 Asia/Nicosia'::timestamptz AND ts_to = '2026-03-31 00:00 Asia/Nicosia'::timestamptz AND tz = 'Asia/Nicosia'
   FROM fn_report_window(t_get('bizR'), '2026-03-29', '2026-03-30')));
SELECT t_check('T70a window crosses DST correctly (29 March 2026: 23-hour day)',
  (SELECT ts_to - ts_from = interval '23 hours' FROM fn_report_window(t_get('bizR'), '2026-03-29', '2026-03-29')));
SELECT t_err('T70a window: reversed range refused', $q$ SELECT * FROM fn_report_window(t_get('bizR'), '2026-03-30', '2026-03-29') $q$, 'INVALID_RANGE');
SELECT t_err('T70a window: > 366 days refused', $q$ SELECT * FROM fn_report_window(t_get('bizR'), '2025-01-01', '2026-06-01') $q$, 'RANGE_TOO_LONG');

-- B) fixture through the legitimate flows (stock with known costs, sales, hold, returns, exchange)
SELECT t_login('u2');
SELECT t_ok('T70b stock: RP1-S 5@200, RP1-M-SYH 5@220, RP1-M-KRM 3@210, RP2 4@80', $q$
  SELECT rpc_post_inventory_adjustment(t_get('bizR'), t_get('brR'), t_get('vR1s'), 'sellable', 5, 'rapor fixture', 'manual_cost', 200);
  SELECT rpc_post_inventory_adjustment(t_get('bizR'), t_get('brR'), t_get('vR1m'), 'sellable', 5, 'rapor fixture', 'manual_cost', 220);
  SELECT rpc_post_inventory_adjustment(t_get('bizR'), t_get('brR'), t_get('vR1k'), 'sellable', 3, 'rapor fixture', 'manual_cost', 210);
  SELECT rpc_post_inventory_adjustment(t_get('bizR'), t_get('brR'), t_get('vR2'),  'sellable', 4, 'rapor fixture', 'manual_cost', 80) $q$);
SELECT t_set('sessR', rpc_open_register_session(t_get('regR'), '[{"currency":"TRY","amount":1000}]'::jsonb));
-- S1: manager cashier, salesperson u3, customer A, 2 × RP1-S @500 cash
SELECT t_set('sR1', (rpc_pos_complete_sale(t_get('sessR'), t_json_items('vR1s','2',NULL), t_pay('cash','TRY',1000), gen_random_uuid(), t_get('cR1'), t_get('u3')) ->> 'sale_id')::uuid);
SELECT t_logout();
SELECT t_login('u3');
-- S2: sales_staff sells (cashier = salesperson = u3), walk-in, RP1-M-SYH @500 + RP2 @200, card 700
SELECT t_set('sR2', (rpc_pos_complete_sale(t_get('sessR'), t_json_items('vR1m','1',NULL, 'vR2','1',NULL), t_pay('card','TRY',700), gen_random_uuid()) ->> 'sale_id')::uuid);
SELECT t_logout();
SELECT t_login('u2');
-- S3: customer B, RP1-M-KRM discounted to 450 (list 500), split cash 300 + card 150, salesperson u2
SELECT t_set('sR3', (rpc_pos_complete_sale(t_get('sessR'), t_json_items('vR1k','1','450'), t_pay('cash','TRY',300) || t_pay('card','TRY',150), gen_random_uuid(), t_get('cR2'), t_get('u2'), 'loyalty') ->> 'sale_id')::uuid);
-- S4: customer A again, RP2 @200, cash 250 → change 50
SELECT t_set('sR4', (rpc_pos_complete_sale(t_get('sessR'), t_json_items('vR2','1',NULL), t_pay('cash','TRY',250), gen_random_uuid(), t_get('cR1'), t_get('u2')) ->> 'sale_id')::uuid);
-- reservation for customer B on RP1-S, fulfilled as S5 (salesperson u3)
SELECT t_set('rvR', (rpc_pos_reservation_create(t_get('brR'), t_get('cR2'), t_json_items('vR1s','1',NULL)) ->> 'reservation_id')::uuid);
SELECT t_set('sR5', (rpc_pos_complete_sale(t_get('sessR'), t_json_items('vR1s','1',NULL), t_pay('cash','TRY',500), gen_random_uuid(), t_get('cR2'), t_get('u3'), NULL, NULL, NULL, t_get('rvR')) ->> 'sale_id')::uuid);
SELECT t_check('T70b five sales through the POS, hold fulfilled', (SELECT count(*) FROM sales WHERE business_id = t_get('bizR') AND status = 'completed') = 5
  AND (SELECT status = 'converted' FROM reservations WHERE id = t_get('rvR')));
-- R1: refund 1 × RP1-S from S1, back to SELLABLE, reason beden_olmadi, cash
SELECT t_set('siR1', (SELECT id FROM sale_items WHERE sale_id = t_get('sR1')));
SELECT t_set('rR1', (rpc_pos_return(t_get('sR1'), t68_ret_item('siR1', 1, 'sellable'), 'refund', gen_random_uuid(), 'beden_olmadi', NULL, t_get('sessR'), 'cash') ->> 'return_id')::uuid);
-- R2: exchange from S2: RP1-M-SYH (500) comes back DAMAGED, RP1-M-KRM @500 + RP2 @200 go out, cash 200 for the difference (S6, salesperson u2)
SELECT t_set('siR2m', (SELECT id FROM sale_items WHERE sale_id = t_get('sR2') AND variant_id = t_get('vR1m')));
SELECT t_set('siR4', (SELECT id FROM sale_items WHERE sale_id = t_get('sR4')));
CREATE TEMP TABLE _t70_x AS SELECT rpc_pos_exchange(t_get('sessR'), t_get('sR2'), t68_ret_item('siR2m', 1, 'damaged'), t_json_items('vR1k','1',NULL, 'vR2','1',NULL), t_pay('cash','TRY',200), gen_random_uuid(), 'renk_degisimi', NULL, NULL, t_get('u2')) AS j;
SELECT t_set('rR2', (SELECT (j ->> 'return_id')::uuid FROM _t70_x));
SELECT t_set('sR6', (SELECT (j ->> 'sale_id')::uuid FROM _t70_x));
-- R3: refund RP2 from S4 into QUARANTINE, card, reason kusurlu_urun
SELECT t_set('rR3', (rpc_pos_return(t_get('sR4'), t68_ret_item('siR4', 1, 'quarantine'), 'refund', gen_random_uuid(), 'kusurlu_urun', NULL, t_get('sessR'), 'card') ->> 'return_id')::uuid);
SELECT t_logout();
SELECT t_check('T70b three returns (1 exchange with its replacement sale)', (SELECT count(*) FROM returns WHERE business_id = t_get('bizR')) = 3
  AND (SELECT count(*) FROM sales WHERE business_id = t_get('bizR') AND status = 'completed') = 6
  AND (SELECT credit_applied_base = 500 AND total = 700 FROM sales WHERE id = t_get('sR6')));
-- posted receipt for the purchasing report: 2 × RP2 @ 90 + 10 TRY charge
SELECT t_login('u2');
SELECT t_set('grR', rpc_create_goods_receipt(t_get('brR'), t_get('supR'), 'TRY', 1, CURRENT_DATE, 'RPT-INV-1', NULL));
SELECT t_ok('T70b receipt posted', $q$
  SELECT rpc_goods_receipt_upsert_line(t_get('grR'), t_get('vR2'), 2, 90);
  INSERT INTO goods_receipt_charges (goods_receipt_id, kind, description, amount, currency, exchange_rate, include_in_landed, liability_mode) VALUES (t_get('grR'), 'freight', 'nakliye', 10, 'TRY', 1, true, 'add_to_invoice');
  SELECT * FROM rpc_goods_receipt_review(t_get('grR'));
  SELECT rpc_post_goods_receipt(t_get('grR')) $q$);
SELECT t_logout();

-- the report day, in the tenant zone
CREATE FUNCTION t70_today() RETURNS DATE LANGUAGE sql STABLE AS $$ SELECT (now() AT TIME ZONE 'Asia/Nicosia')::date $$;

-- C) manager overview: every figure against the hand-computed expectation AND an independent SQL sum
SELECT t_login('u2');
CREATE TEMP TABLE _t70_ov AS SELECT rpc_report_overview(t_get('bizR'), t70_today(), t70_today(), NULL, t70_today() - 1, t70_today() - 1) AS j;
GRANT SELECT ON _t70_ov TO authenticated;
SELECT t_check('T70c overview counts: 6 transactions, 9 units, 3 returns (1 exchange), 3 returned units',
  (SELECT (j -> 'current' ->> 'transactions')::int = 6 AND (j -> 'current' ->> 'units')::int = 9 AND (j -> 'current' ->> 'returns_count')::int = 3
      AND (j -> 'current' ->> 'exchanges_count')::int = 1 AND (j -> 'current' ->> 'returned_units')::int = 3 FROM _t70_ov),
  (SELECT j -> 'current' FROM _t70_ov)::text);
SELECT t_check('T70c overview money: gross 3600, discounts 50, net 3550, returns 1200, net after returns 2350, basket 591.67',
  (SELECT (j -> 'current' ->> 'gross_sales')::numeric = 3600 AND (j -> 'current' ->> 'discounts')::numeric = 50 AND (j -> 'current' ->> 'net_sales')::numeric = 3550
      AND (j -> 'current' ->> 'returns_value')::numeric = 1200 AND (j -> 'current' ->> 'net_sales_after_returns')::numeric = 2350
      AND (j -> 'current' ->> 'avg_basket')::numeric = 591.67 FROM _t70_ov),
  (SELECT j -> 'current' FROM _t70_ov)::text);
SELECT t_check('T70c overview profit: COGS 1480 (historical), returned COGS 500, gross profit 1370, margin 58.30 %',
  (SELECT (j -> 'current' ->> 'cogs')::numeric = 1480 AND (j -> 'current' ->> 'returned_cogs')::numeric = 500
      AND (j -> 'current' ->> 'gross_profit')::numeric = 1370 AND (j -> 'current' ->> 'gross_margin_pct')::numeric = 58.30 FROM _t70_ov),
  (SELECT j -> 'current' FROM _t70_ov)::text);
SELECT t_logout();
SELECT t_check('T70c independent cross-check: report equals raw sums over sales / sale_items / sale_costs / returns / return_item_costs',
  (SELECT (j -> 'current' ->> 'net_sales')::numeric = (SELECT sum(total) FROM sales WHERE business_id = t_get('bizR') AND status = 'completed')
      AND (j -> 'current' ->> 'gross_sales')::numeric = (SELECT sum(list_price * quantity) FROM sale_items WHERE business_id = t_get('bizR'))
      AND (j -> 'current' ->> 'discounts')::numeric = (SELECT sum(discount_amount) FROM sale_items WHERE business_id = t_get('bizR'))
      AND (j -> 'current' ->> 'cogs')::numeric = (SELECT round(sum(total_cost_base), 2) FROM sale_costs WHERE business_id = t_get('bizR'))
      AND (j -> 'current' ->> 'returns_value')::numeric = (SELECT sum(credit_value_base) FROM returns WHERE business_id = t_get('bizR'))
      AND (j -> 'current' ->> 'returned_cogs')::numeric = (SELECT round(sum(line_cost_base), 2) FROM return_item_costs WHERE business_id = t_get('bizR'))
   FROM _t70_ov));
SELECT t_check('T70c overview: previous period exists but is empty (no fabricated comparison), timezone reported, daily has exactly one day',
  (SELECT (j -> 'previous' ->> 'transactions')::int = 0 AND (j -> 'previous' ->> 'net_sales')::numeric = 0
      AND j -> 'period' ->> 'timezone' = 'Asia/Nicosia' AND (j -> 'period' ->> 'timezone_set')::boolean
      AND jsonb_array_length(j -> 'daily') = 1 AND (j -> 'daily' -> 0 ->> 'date')::date = t70_today()
      AND (j -> 'daily' -> 0 ->> 'net_sales')::numeric = 3550 AND (j -> 'daily' -> 0 ->> 'gross_profit')::numeric = 1370
      AND (j ->> 'financial')::boolean AND j ->> 'scope' = 'business' FROM _t70_ov));

-- D) timezone semantics: the same instants land on the tenant's local day, not the server's
SELECT t_login('u1');
SELECT t_ok('T70d owner moves the tenant to UTC-12', $q$ SELECT rpc_business_set_timezone(t_get('bizR'), 'Etc/GMT+12') $q$);
SELECT t_check('T70d reports follow the tenant day at UTC-12 (today there holds the 6 sales; the next day none)',
  (rpc_report_overview(t_get('bizR'), (now() AT TIME ZONE 'Etc/GMT+12')::date, (now() AT TIME ZONE 'Etc/GMT+12')::date) -> 'current' ->> 'transactions')::int = 6
  AND (rpc_report_overview(t_get('bizR'), (now() AT TIME ZONE 'Etc/GMT+12')::date + 1, (now() AT TIME ZONE 'Etc/GMT+12')::date + 1) -> 'current' ->> 'transactions')::int = 0);
SELECT t_ok('T70d owner moves the tenant to UTC+14', $q$ SELECT rpc_business_set_timezone(t_get('bizR'), 'Etc/GMT-14') $q$);
SELECT t_check('T70d reports follow the tenant day at UTC+14 as well (and the previous day is empty)',
  (rpc_report_overview(t_get('bizR'), (now() AT TIME ZONE 'Etc/GMT-14')::date, (now() AT TIME ZONE 'Etc/GMT-14')::date) -> 'current' ->> 'transactions')::int = 6
  AND (rpc_report_overview(t_get('bizR'), (now() AT TIME ZONE 'Etc/GMT-14')::date - 1, (now() AT TIME ZONE 'Etc/GMT-14')::date - 1) -> 'current' ->> 'transactions')::int = 0);
SELECT t_ok('T70d back to Asia/Nicosia', $q$ SELECT rpc_business_set_timezone(t_get('bizR'), 'Asia/Nicosia') $q$);
SELECT t_logout();

-- E) sales report filters
SELECT t_login('u2');
SELECT t_check('T70e sales by salesperson u3: 3 sales (S1, S2, S5), 5 units, net 2200, returns 1000 (R1 + R2 come from their sales)',
  (SELECT (j -> 'totals' ->> 'transactions')::int = 3 AND (j -> 'totals' ->> 'units')::int = 5 AND (j -> 'totals' ->> 'net_sales')::numeric = 2200
      AND (j -> 'totals' ->> 'returns_value')::numeric = 1000 AND (j -> 'totals' ->> 'discounts')::numeric = 0
   FROM (SELECT rpc_report_sales(t_get('bizR'), t70_today(), t70_today(), NULL, t_get('u3')) AS j) x));
SELECT t_check('T70e sales by category Çanta: 3 units, net 600, returns 200; by product RP1: 6 units, net 2950, COGS 1240',
  (SELECT (j -> 'totals' ->> 'units')::int = 3 AND (j -> 'totals' ->> 'net_sales')::numeric = 600 AND (j -> 'totals' ->> 'returns_value')::numeric = 200
   FROM (SELECT rpc_report_sales(t_get('bizR'), t70_today(), t70_today(), NULL, NULL, t_get('catR2')) AS j) x)
  AND (SELECT (j -> 'totals' ->> 'units')::int = 6 AND (j -> 'totals' ->> 'net_sales')::numeric = 2950 AND (j -> 'totals' ->> 'cogs')::numeric = 1240
       FROM (SELECT rpc_report_sales(t_get('bizR'), t70_today(), t70_today(), NULL, NULL, NULL, t_get('pR1')) AS j) x));
SELECT t_check('T70e sales by branch row + a branch filter of another tenant is refused',
  (SELECT jsonb_array_length(j -> 'by_branch') = 1 AND (j -> 'by_branch' -> 0 ->> 'net_sales')::numeric = 3550
   FROM (SELECT rpc_report_sales(t_get('bizR'), t70_today(), t70_today()) AS j) x));
SELECT t_err('T70e branch of another tenant → INVALID_BRANCH', $q$ SELECT rpc_report_sales(t_get('bizR'), t70_today(), t70_today(), t_get('brB')) $q$, 'INVALID_BRANCH');

-- F) products: product / category / size / color, out-of-stock with sales
CREATE TEMP TABLE _t70_pr AS SELECT rpc_report_products(t_get('bizR'), t70_today(), t70_today(), NULL, 'product', NULL, 50) AS j;
GRANT SELECT ON _t70_pr TO authenticated;
SELECT t_check('T70f by product: RP1 6 units / 2950 net / 2 returns (1000) / GP 1130; RP2 3 units / 600 / 1 return (200) / GP 240',
  (SELECT r0 ->> 'label' = 'Rapor Elbise' AND (r0 ->> 'units')::int = 6 AND (r0 ->> 'net_sales')::numeric = 2950 AND (r0 ->> 'returns_count')::int = 2
      AND (r0 ->> 'returns_value')::numeric = 1000 AND (r0 ->> 'cogs')::numeric = 1240 AND (r0 ->> 'returned_cogs')::numeric = 420
      AND (r0 ->> 'gross_profit')::numeric = 1130
      AND r1 ->> 'label' = 'Rapor Çanta' AND (r1 ->> 'units')::int = 3 AND (r1 ->> 'net_sales')::numeric = 600 AND (r1 ->> 'returns_value')::numeric = 200
      AND (r1 ->> 'gross_profit')::numeric = 240
   FROM (SELECT j -> 'rows' -> 0 AS r0, j -> 'rows' -> 1 AS r1 FROM _t70_pr) x),
  (SELECT j -> 'rows' FROM _t70_pr)::text);
SELECT t_check('T70f by category: Elbise 6 / 2950, Çanta 3 / 600',
  (SELECT r0 ->> 'label' = 'Elbise' AND (r0 ->> 'units')::int = 6 AND r1 ->> 'label' = 'Çanta' AND (r1 ->> 'net_sales')::numeric = 600
   FROM (SELECT j -> 'rows' -> 0 AS r0, j -> 'rows' -> 1 AS r1 FROM (SELECT rpc_report_products(t_get('bizR'), t70_today(), t70_today(), NULL, 'category') AS j) y) x));
SELECT t_check('T70f sizes: S 3 units / 1500, M 3 units / 1450; colours: Siyah 4 / 2000, Kırmızı 2 / 950 (the bag has neither and is left out)',
  (SELECT (SELECT count(*) FROM jsonb_array_elements(j -> 'top_sizes')) = 2
      AND (j -> 'top_sizes' -> 0 ->> 'label') = 'S' AND (j -> 'top_sizes' -> 0 ->> 'units')::int = 3 AND (j -> 'top_sizes' -> 0 ->> 'net_sales')::numeric = 1500
      AND (j -> 'top_sizes' -> 1 ->> 'label') = 'M' AND (j -> 'top_sizes' -> 1 ->> 'units')::int = 3 AND (j -> 'top_sizes' -> 1 ->> 'net_sales')::numeric = 1450
      AND (SELECT count(*) FROM jsonb_array_elements(j -> 'top_colors')) = 2
      AND (j -> 'top_colors' -> 0 ->> 'label') = 'Siyah' AND (j -> 'top_colors' -> 0 ->> 'units')::int = 4 AND (j -> 'top_colors' -> 0 ->> 'net_sales')::numeric = 2000
      AND (j -> 'top_colors' -> 1 ->> 'label') = 'Kırmızı' AND (j -> 'top_colors' -> 1 ->> 'units')::int = 2
   FROM _t70_pr), (SELECT j -> 'top_sizes' FROM _t70_pr)::text || (SELECT j -> 'top_colors' FROM _t70_pr)::text);
SELECT t_check('T70f out-of-stock with sales: none yet (RP1-M-KRM still has 1)', (SELECT jsonb_array_length(j -> 'out_of_stock_with_sales') = 0 FROM _t70_pr));
SELECT t_err('T70f unknown grouping refused', $q$ SELECT rpc_report_products(t_get('bizR'), t70_today(), t70_today(), NULL, 'brand') $q$, 'INVALID_GROUP');

-- G) staff: salesperson attribution separate from the cashier
CREATE TEMP TABLE _t70_st AS SELECT rpc_report_staff(t_get('bizR'), t70_today(), t70_today()) AS j;
GRANT SELECT ON _t70_st TO authenticated;
SELECT t_check('T70g salespeople: u3 3 sales / 5 units / 2200 net / returns 1000; u2 3 sales / 4 units / 1350 net / returns 200',
  (SELECT (SELECT count(*) FROM jsonb_array_elements(j -> 'salespeople')) = 2
      AND (j -> 'salespeople' -> 0 ->> 'user_id')::uuid = t_get('u3') AND (j -> 'salespeople' -> 0 ->> 'transactions')::int = 3
      AND (j -> 'salespeople' -> 0 ->> 'units')::int = 5 AND (j -> 'salespeople' -> 0 ->> 'net_sales')::numeric = 2200
      AND (j -> 'salespeople' -> 0 ->> 'returns_value')::numeric = 1000 AND (j -> 'salespeople' -> 0 ->> 'avg_basket')::numeric = 733.33
      AND (j -> 'salespeople' -> 1 ->> 'user_id')::uuid = t_get('u2') AND (j -> 'salespeople' -> 1 ->> 'transactions')::int = 3
      AND (j -> 'salespeople' -> 1 ->> 'net_sales')::numeric = 1350 AND (j -> 'salespeople' -> 1 ->> 'returns_value')::numeric = 200
   FROM _t70_st), (SELECT j -> 'salespeople' FROM _t70_st)::text);
SELECT t_check('T70g cashiers: u2 rang up 5 sales, u3 1',
  (SELECT (j -> 'cashiers' -> 0 ->> 'user_id')::uuid = t_get('u2') AND (j -> 'cashiers' -> 0 ->> 'transactions')::int = 5
      AND (j -> 'cashiers' -> 1 ->> 'user_id')::uuid = t_get('u3') AND (j -> 'cashiers' -> 1 ->> 'transactions')::int = 1 FROM _t70_st),
  (SELECT j -> 'cashiers' FROM _t70_st)::text);

-- H) payments: tender by method vs money that moved vs drawer
CREATE TEMP TABLE _t70_pay AS SELECT rpc_report_payments(t_get('bizR'), t70_today(), t70_today()) AS j;
GRANT SELECT ON _t70_pay TO authenticated;
SELECT t_check('T70h by method: cash 2250 over 5 payments, card 850 over 2; one split-payment sale; change 50; exchange credit 500',
  (SELECT (SELECT sum((m ->> 'amount_base')::numeric) FROM jsonb_array_elements(j -> 'by_method') m WHERE m ->> 'method' = 'cash') = 2250
      AND (SELECT sum((m ->> 'payments')::int) FROM jsonb_array_elements(j -> 'by_method') m WHERE m ->> 'method' = 'cash') = 5
      AND (SELECT sum((m ->> 'amount_base')::numeric) FROM jsonb_array_elements(j -> 'by_method') m WHERE m ->> 'method' = 'card') = 850
      AND (j -> 'sales' ->> 'split_payment_sales')::int = 1 AND (j -> 'sales' ->> 'change_given')::numeric = 50
      AND (j -> 'sales' ->> 'credit_applied')::numeric = 500 AND (j -> 'sales' ->> 'tendered_base')::numeric = 3100
      AND (j -> 'sales' ->> 'net_sales')::numeric = 3550 FROM _t70_pay), (SELECT j FROM _t70_pay)::text);
SELECT t_check('T70h identity: net sales = tendered − change + exchange credit (3550 = 3100 − 50 + 500)',
  (SELECT (j -> 'sales' ->> 'net_sales')::numeric = (j -> 'sales' ->> 'tendered_base')::numeric - (j -> 'sales' ->> 'change_given')::numeric + (j -> 'sales' ->> 'credit_applied')::numeric FROM _t70_pay));
SELECT t_check('T70h refunds: cash 500 + card 200 = 700; net payment movement 2350 = 3100 − 50 − 700',
  (SELECT (j ->> 'refund_total')::numeric = 700 AND (j ->> 'net_payment_movement')::numeric = 2350
      AND (SELECT (r ->> 'amount_base')::numeric FROM jsonb_array_elements(j -> 'refunds') r WHERE r ->> 'method' = 'cash') = 500
      AND (SELECT (r ->> 'amount_base')::numeric FROM jsonb_array_elements(j -> 'refunds') r WHERE r ->> 'method' = 'card') = 200 FROM _t70_pay));
SELECT t_check('T70h drawer is a different thing: sale_cash +2250, change_out −50, refund_cash_out −500 (card never touches it)',
  (SELECT (SELECT (d ->> 'amount_base')::numeric FROM jsonb_array_elements(j -> 'drawer') d WHERE d ->> 'movement_type' = 'sale_cash') = 2250
      AND (SELECT (d ->> 'amount_base')::numeric FROM jsonb_array_elements(j -> 'drawer') d WHERE d ->> 'movement_type' = 'change_out') = -50
      AND (SELECT (d ->> 'amount_base')::numeric FROM jsonb_array_elements(j -> 'drawer') d WHERE d ->> 'movement_type' = 'refund_cash_out') = -500
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'drawer') d WHERE d ->> 'movement_type' NOT IN ('sale_cash','change_out','refund_cash_out'))
   FROM _t70_pay), (SELECT j -> 'drawer' FROM _t70_pay)::text);
SELECT t_check('T70h drawer cross-check against cash_movements', (SELECT (SELECT sum((d ->> 'amount_base')::numeric) FROM jsonb_array_elements(j -> 'drawer') d) FROM _t70_pay)
  = (SELECT sum(amount_base) FROM cash_movements WHERE business_id = t_get('bizR')));

-- I) stock + valuation
CREATE TEMP TABLE _t70_stk AS SELECT rpc_report_stock(t_get('bizR'), t_get('brR'), 2) AS j;
GRANT SELECT ON _t70_stk TO authenticated;
SELECT t_check('T70i stock: sellable 11 (incl. the RP2 receipt), reserved 0, damaged 1, quarantine 1, low-stock 1 (RP1-M-KRM=1), none out',
  (SELECT (j -> 'totals' ->> 'sellable')::int = 11 AND (j -> 'totals' ->> 'reserved')::int = 0 AND (j -> 'totals' ->> 'available')::int = 11
      AND (j -> 'totals' ->> 'damaged')::int = 1 AND (j -> 'totals' ->> 'quarantine')::int = 1
      AND (j -> 'totals' ->> 'out_of_stock')::int = 0 AND (j -> 'totals' ->> 'low_stock')::int = 1
      AND (j -> 'low_stock' -> 0 ->> 'sku') = 'RP1-M-KRM' AND (j -> 'low_stock' -> 0 ->> 'available')::int = 1 FROM _t70_stk),
  (SELECT j -> 'totals' FROM _t70_stk)::text);
SELECT t_check('T70i valuation (manager): pool on-hand 13, value 2260 (600 + 1100 + 210 + 160 + 2 × 95 landed), equal to the pools',
  (SELECT (j -> 'valuation' ->> 'on_hand_qty')::int = 13 AND (j -> 'valuation' ->> 'total_value_base')::numeric = 2260 FROM _t70_stk)
  AND (SELECT (j -> 'valuation' ->> 'total_value_base')::numeric = (SELECT round(sum(total_value_base), 2) FROM variant_cost_pools WHERE business_id = t_get('bizR')) FROM _t70_stk),
  (SELECT j -> 'valuation' FROM _t70_stk)::text);

-- J) receiving (posted only), customers, returns
SELECT t_check('T70j receiving: 1 posted receipt, 2 units, purchase 180, charges 10, landed 190, liability 190',
  (SELECT (j -> 'totals' ->> 'receipts')::int = 1 AND (j -> 'totals' ->> 'units')::int = 2 AND (j -> 'totals' ->> 'purchase_value_base')::numeric = 180
      AND (j -> 'totals' ->> 'charges_base')::numeric = 10 AND (j -> 'totals' ->> 'landed_total_base')::numeric = 190
      AND (j -> 'totals' ->> 'liability_base')::numeric = 190 AND (j -> 'by_supplier' -> 0 ->> 'supplier') = 'Rapor Tedarikçi'
      AND (j -> 'reversals' ->> 'count')::int = 0
   FROM (SELECT rpc_report_receiving(t_get('bizR'), t70_today(), t70_today()) AS j) x));
CREATE TEMP TABLE _t70_cu AS SELECT rpc_report_customers(t_get('bizR'), t70_today(), t70_today()) AS j;
GRANT SELECT ON _t70_cu TO authenticated;
SELECT t_check('T70j customers: 6 sales, 4 identified, 2 walk-in, 2 customers, 2 repeat, top A 1200 / B 950, A returned 700',
  (SELECT (j -> 'totals' ->> 'sales')::int = 6 AND (j -> 'totals' ->> 'identified_sales')::int = 4 AND (j -> 'totals' ->> 'walk_in_sales')::int = 2
      AND (j -> 'totals' ->> 'customers_with_sale')::int = 2 AND (j -> 'totals' ->> 'repeat_customers')::int = 2
      AND (j -> 'totals' ->> 'identified_net_sales')::numeric = 2150 AND (j -> 'totals' ->> 'walk_in_net_sales')::numeric = 1400
      AND (j -> 'top' -> 0 ->> 'name') = 'Rapor Müşteri A' AND (j -> 'top' -> 0 ->> 'net_spend')::numeric = 1200 AND (j -> 'top' -> 0 ->> 'sales')::int = 2
      AND (j -> 'top' -> 0 ->> 'returns_value')::numeric = 700
      AND (j -> 'top' -> 1 ->> 'name') = 'Rapor Müşteri B' AND (j -> 'top' -> 1 ->> 'net_spend')::numeric = 950
      AND (j -> 'top' -> 0) ? 'name' AND NOT ((j -> 'top' -> 0) ? 'phone') FROM _t70_cu), (SELECT j FROM _t70_cu)::text);
CREATE TEMP TABLE _t70_ret AS SELECT rpc_report_returns(t_get('bizR'), t70_today(), t70_today()) AS j;
GRANT SELECT ON _t70_ret TO authenticated;
SELECT t_check('T70j returns: 3 returns (1 exchange, 2 refunds), 3 units, value 1200, refunded 700, returned COGS 500',
  (SELECT (j -> 'totals' ->> 'returns')::int = 3 AND (j -> 'totals' ->> 'exchanges')::int = 1 AND (j -> 'totals' ->> 'refunds')::int = 2
      AND (j -> 'totals' ->> 'returned_units')::int = 3 AND (j -> 'totals' ->> 'returns_value')::numeric = 1200
      AND (j -> 'totals' ->> 'refund_amount')::numeric = 700 AND (j -> 'totals' ->> 'returned_cogs')::numeric = 500 FROM _t70_ret),
  (SELECT j -> 'totals' FROM _t70_ret)::text);
SELECT t_check('T70j returns by reason (labels resolved), by disposition (sellable / damaged / quarantine 1 each), by type',
  (SELECT (SELECT count(*) FROM jsonb_array_elements(j -> 'by_reason')) = 3
      AND (SELECT r ->> 'label' FROM jsonb_array_elements(j -> 'by_reason') r WHERE r ->> 'code' = 'beden_olmadi') = 'Beden olmadı'
      AND (SELECT (r ->> 'value')::numeric FROM jsonb_array_elements(j -> 'by_reason') r WHERE r ->> 'code' = 'renk_degisimi') = 500
      AND (SELECT count(*) FROM jsonb_array_elements(j -> 'by_disposition')) = 3
      AND (SELECT (d ->> 'units')::int FROM jsonb_array_elements(j -> 'by_disposition') d WHERE d ->> 'disposition' = 'damaged') = 1
      AND (SELECT (t ->> 'returns')::int FROM jsonb_array_elements(j -> 'by_type') t WHERE t ->> 'return_type' = 'refund') = 2 FROM _t70_ret),
  (SELECT j FROM _t70_ret)::text);
SELECT t_check('T70j return rate: RP1 2 of 6 (33.3 %, not meaningful < 10 sold), RP2 1 of 3; size S 1 of 3, M 1 of 3 — none flagged meaningful',
  (SELECT (SELECT (p ->> 'rate_pct')::numeric FROM jsonb_array_elements(j -> 'rate_by_product') p WHERE p ->> 'product' = 'Rapor Elbise') = 33.3
      AND (SELECT (p ->> 'sold_units')::int FROM jsonb_array_elements(j -> 'rate_by_product') p WHERE p ->> 'product' = 'Rapor Elbise') = 6
      AND (SELECT (p ->> 'rate_pct')::numeric FROM jsonb_array_elements(j -> 'rate_by_product') p WHERE p ->> 'product' = 'Rapor Çanta') = 33.3
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rate_by_product') p WHERE (p ->> 'meaningful')::boolean)
      AND (SELECT (s ->> 'returned_units')::int FROM jsonb_array_elements(j -> 'rate_by_size') s WHERE s ->> 'size' = 'S') = 1
      AND (SELECT (s ->> 'sold_units')::int FROM jsonb_array_elements(j -> 'rate_by_size') s WHERE s ->> 'size' = 'M') = 3 FROM _t70_ret),
  (SELECT j -> 'rate_by_product' FROM _t70_ret)::text || (SELECT j -> 'rate_by_size' FROM _t70_ret)::text);
SELECT t_logout();

-- K) role model
SELECT t_login('u3');
CREATE TEMP TABLE _t70_s3 AS SELECT rpc_report_overview(t_get('bizR'), t70_today(), t70_today()) AS j;
GRANT SELECT ON _t70_s3 TO authenticated;
SELECT t_check('T70k sales_staff (scope own): sees only what they sold or were attributed — 3 sales / 2200 / returns 1000 — and no financial key at all',
  (SELECT (j -> 'current' ->> 'transactions')::int = 3 AND (j -> 'current' ->> 'net_sales')::numeric = 2200 AND (j -> 'current' ->> 'returns_value')::numeric = 1000
      AND NOT ((j -> 'current') ? 'cogs') AND NOT ((j -> 'current') ? 'gross_profit') AND NOT ((j -> 'current') ? 'gross_margin_pct') AND NOT ((j -> 'current') ? 'returned_cogs')
      AND NOT ((j -> 'daily' -> 0) ? 'gross_profit') AND NOT (j ->> 'financial')::boolean AND j ->> 'scope' = 'own' FROM _t70_s3),
  (SELECT j FROM _t70_s3)::text);
SELECT t_check('T70k sales_staff product / staff / customer / returns rows carry no cost, profit or margin keys',
  (SELECT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rows') r WHERE r ? 'cogs' OR r ? 'gross_profit' OR r ? 'gross_margin_pct' OR r ? 'returned_cogs')
      AND jsonb_array_length(j -> 'rows') = 2
   FROM (SELECT rpc_report_products(t_get('bizR'), t70_today(), t70_today()) AS j) x)
  AND (SELECT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'salespeople') r WHERE r ? 'gross_profit' OR r ? 'gross_margin_pct')
       FROM (SELECT rpc_report_staff(t_get('bizR'), t70_today(), t70_today()) AS j) x)
  AND (SELECT NOT ((j -> 'totals') ? 'returned_cogs') AND (j -> 'totals' ->> 'returns')::int = 2
       FROM (SELECT rpc_report_returns(t_get('bizR'), t70_today(), t70_today()) AS j) x)
  AND (SELECT (j -> 'totals' ->> 'sales')::int = 3 FROM (SELECT rpc_report_customers(t_get('bizR'), t70_today(), t70_today()) AS j) x));
SELECT t_err('T70k sales_staff: payments report FORBIDDEN', $q$ SELECT rpc_report_payments(t_get('bizR'), t70_today(), t70_today()) $q$, 'FORBIDDEN');
SELECT t_err('T70k sales_staff: receiving report FORBIDDEN', $q$ SELECT rpc_report_receiving(t_get('bizR'), t70_today(), t70_today()) $q$, 'FORBIDDEN');
SELECT t_check('T70k sales_staff: stock report has quantities but no valuation',
  (SELECT (j -> 'totals' ->> 'sellable')::int = 11 AND j -> 'valuation' = 'null'::jsonb AND NOT (j ->> 'financial')::boolean
   FROM (SELECT rpc_report_stock(t_get('bizR'), t_get('brR')) AS j) x));
SELECT t_logout();
-- scope widened to business: the same sales_staff now sees every sale, still without money keys
UPDATE businesses SET settings = settings || '{"sales_visibility_scope":"business"}'::jsonb WHERE id = t_get('bizR');
SELECT t_login('u3');
SELECT t_check('T70k sales_staff under scope=business sees all 6 sales, still no COGS',
  (SELECT (j -> 'current' ->> 'transactions')::int = 6 AND NOT ((j -> 'current') ? 'cogs') AND j ->> 'scope' = 'business'
   FROM (SELECT rpc_report_overview(t_get('bizR'), t70_today(), t70_today()) AS j) x));
SELECT t_logout();
UPDATE businesses SET settings = settings || '{"sales_visibility_scope":"own"}'::jsonb WHERE id = t_get('bizR');
SELECT t_login('u4');
SELECT t_err('T70k stock_staff: overview FORBIDDEN', $q$ SELECT rpc_report_overview(t_get('bizR'), t70_today(), t70_today()) $q$, 'FORBIDDEN');
SELECT t_err('T70k stock_staff: customers FORBIDDEN', $q$ SELECT rpc_report_customers(t_get('bizR'), t70_today(), t70_today()) $q$, 'FORBIDDEN');
SELECT t_err('T70k stock_staff: returns FORBIDDEN', $q$ SELECT rpc_report_returns(t_get('bizR'), t70_today(), t70_today()) $q$, 'FORBIDDEN');
SELECT t_err('T70k stock_staff: payments FORBIDDEN', $q$ SELECT rpc_report_payments(t_get('bizR'), t70_today(), t70_today()) $q$, 'FORBIDDEN');
SELECT t_err('T70k stock_staff: receiving FORBIDDEN', $q$ SELECT rpc_report_receiving(t_get('bizR'), t70_today(), t70_today()) $q$, 'FORBIDDEN');
SELECT t_check('T70k stock_staff: stock report (operational) allowed, no valuation',
  (SELECT (j -> 'totals' ->> 'damaged')::int = 1 AND j -> 'valuation' = 'null'::jsonb FROM (SELECT rpc_report_stock(t_get('bizR')) AS j) x));
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T70k other tenant: overview FORBIDDEN (business_id is not an authorisation)', $q$ SELECT rpc_report_overview(t_get('bizR'), t70_today(), t70_today()) $q$, 'FORBIDDEN');
SELECT t_err('T70k other tenant: stock FORBIDDEN', $q$ SELECT rpc_report_stock(t_get('bizR')) $q$, 'FORBIDDEN');
SELECT t_err('T70k other tenant: products FORBIDDEN', $q$ SELECT rpc_report_products(t_get('bizR'), t70_today(), t70_today()) $q$, 'FORBIDDEN');
SELECT t_check('T70k other tenant sees only its own figures (equal to the raw sums of bizB, none of bizR)',
  (SELECT (j -> 'current' ->> 'transactions')::int = (SELECT count(*) FROM sales WHERE business_id = t_get('bizB') AND status = 'completed')
      AND (j -> 'current' ->> 'net_sales')::numeric = (SELECT COALESCE(sum(total), 0) FROM sales WHERE business_id = t_get('bizB') AND status = 'completed')
      AND (j -> 'current' ->> 'net_sales')::numeric <> 3550
   FROM (SELECT rpc_report_overview(t_get('bizB'), (now() AT TIME ZONE 'Europe/Istanbul')::date, (now() AT TIME ZONE 'Europe/Istanbul')::date) AS j) x));
SELECT t_logout();
SELECT t_err('T70k unauthenticated: refused', $q$ SELECT rpc_report_overview(t_get('bizR'), t70_today(), t70_today()) $q$, 'UNAUTHENTICATED');
SELECT t_check('T70k reporting wrote nothing: sales / returns / movements / pools untouched by every report call',
  (SELECT count(*) FROM sales WHERE business_id = t_get('bizR')) = 6 AND (SELECT count(*) FROM returns WHERE business_id = t_get('bizR')) = 3
  AND (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizR')) = 4 + 8 + 3 + 1);

-- ============================================================
-- T71 — Phase 11A fashion intelligence: deterministic signals over an isolated tenant with
--        six synthetic products (A fast M, B old excess, C broken size run, D colour
--        imbalance, E size-specific returns, F reserved with no availability). Arrival and
--        sale dates are backdated on the synthetic rows only (immutability triggers are
--        switched off for those statements — a test fixture, never a code path).
-- ============================================================
SELECT t_logout();
SELECT t_set('bizF', 'b0000000-0000-4000-8000-00000000000f');
INSERT INTO businesses (id, name, code, settings) VALUES (t_get('bizF'), 'Moda Zekâsı Butik', 'FSH', jsonb_build_object(
  'accepted_currencies', jsonb_build_array('TRY'), 'sales_visibility_scope', 'own',
  'money_refund_allowed', true, 'store_credit_allowed', false, 'exchange_window_days', 60, 'timezone', 'Europe/Istanbul'));
WITH x AS (INSERT INTO branches (business_id, name, code, is_default) VALUES (t_get('bizF'), 'Moda Merkez', 'FM', true) RETURNING id) SELECT t_set('brF', id) FROM x;
INSERT INTO business_members (business_id, user_id, role) VALUES
  (t_get('bizF'), t_get('u1'), 'owner'), (t_get('bizF'), t_get('u2'), 'manager'),
  (t_get('bizF'), t_get('u3'), 'sales_staff'), (t_get('bizF'), t_get('u4'), 'stock_staff');
WITH x AS (INSERT INTO categories (business_id, name, slug) VALUES (t_get('bizF'), 'Üst', 'ust') RETURNING id) SELECT t_set('catF1', id) FROM x;
WITH x AS (INSERT INTO categories (business_id, name, slug) VALUES (t_get('bizF'), 'Alt', 'alt') RETURNING id) SELECT t_set('catF2', id) FROM x;
WITH x AS (INSERT INTO product_options (business_id, name, kind, sort_order) VALUES (t_get('bizF'), 'Beden', 'size', 10) RETURNING id) SELECT t_set('optF_size', id) FROM x;
WITH x AS (INSERT INTO product_options (business_id, name, kind, sort_order) VALUES (t_get('bizF'), 'Renk', 'color', 5) RETURNING id) SELECT t_set('optF_color', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optF_size'), 'S', 'S', 1) RETURNING id) SELECT t_set('ovF_s', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optF_size'), 'M', 'M', 2) RETURNING id) SELECT t_set('ovF_m', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optF_size'), 'L', 'L', 3) RETURNING id) SELECT t_set('ovF_l', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optF_size'), 'XL', 'XL', 4) RETURNING id) SELECT t_set('ovF_xl', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optF_color'), 'Siyah', 'SYH', 1) RETURNING id) SELECT t_set('ovF_syh', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optF_color'), 'Kırmızı', 'KRM', 2) RETURNING id) SELECT t_set('ovF_krm', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optF_color'), 'Bej', 'BEJ', 3) RETURNING id) SELECT t_set('ovF_bej', id) FROM x;
-- products
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, category_id, status) VALUES (t_get('bizF'), 'A Hızlı Tişört', 'FA', 300, t_get('catF1'), 'active') RETURNING id) SELECT t_set('pFA', id) FROM x;
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, category_id, status) VALUES (t_get('bizF'), 'B Eski Kaban', 'FB', 900, t_get('catF1'), 'active') RETURNING id) SELECT t_set('pFB', id) FROM x;
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, category_id, status) VALUES (t_get('bizF'), 'C Kırık Beden Elbise', 'FC', 600, t_get('catF1'), 'active') RETURNING id) SELECT t_set('pFC', id) FROM x;
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, category_id, status) VALUES (t_get('bizF'), 'D Renk Gömlek', 'FD', 400, t_get('catF1'), 'active') RETURNING id) SELECT t_set('pFD', id) FROM x;
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, category_id, status) VALUES (t_get('bizF'), 'E İade Pantolon', 'FE', 500, t_get('catF2'), 'active') RETURNING id) SELECT t_set('pFE', id) FROM x;
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, category_id, status) VALUES (t_get('bizF'), 'F Rezerve Çanta', 'FF', 700, t_get('catF2'), 'active') RETURNING id) SELECT t_set('pFF', id) FROM x;
-- variants (key: v<product><size/colour>)
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFA'), 'FA-S') RETURNING id) SELECT t_set('vFAS', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFAS'), t_get('optF_size'), t_get('ovF_s'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFA'), 'FA-M') RETURNING id) SELECT t_set('vFAM', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFAM'), t_get('optF_size'), t_get('ovF_m'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFA'), 'FA-L') RETURNING id) SELECT t_set('vFAL', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFAL'), t_get('optF_size'), t_get('ovF_l'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFB'), 'FB-STD') RETURNING id) SELECT t_set('vFB', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFB'), t_get('optF_color'), t_get('ovF_bej'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFC'), 'FC-S') RETURNING id) SELECT t_set('vFCS', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFCS'), t_get('optF_size'), t_get('ovF_s'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFC'), 'FC-M') RETURNING id) SELECT t_set('vFCM', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFCM'), t_get('optF_size'), t_get('ovF_m'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFC'), 'FC-L') RETURNING id) SELECT t_set('vFCL', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFCL'), t_get('optF_size'), t_get('ovF_l'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFC'), 'FC-XL') RETURNING id) SELECT t_set('vFCXL', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFCXL'), t_get('optF_size'), t_get('ovF_xl'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFD'), 'FD-M-SYH') RETURNING id) SELECT t_set('vFDS', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFDS'), t_get('optF_size'), t_get('ovF_m')), (t_get('vFDS'), t_get('optF_color'), t_get('ovF_syh'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFD'), 'FD-M-KRM') RETURNING id) SELECT t_set('vFDK', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFDK'), t_get('optF_size'), t_get('ovF_m')), (t_get('vFDK'), t_get('optF_color'), t_get('ovF_krm'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFE'), 'FE-S') RETURNING id) SELECT t_set('vFES', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFES'), t_get('optF_size'), t_get('ovF_s'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFE'), 'FE-M') RETURNING id) SELECT t_set('vFEM', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFEM'), t_get('optF_size'), t_get('ovF_m'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFE'), 'FE-L') RETURNING id) SELECT t_set('vFEL', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFEL'), t_get('optF_size'), t_get('ovF_l'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pFF'), 'FF-STD') RETURNING id) SELECT t_set('vFF', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vFF'), t_get('optF_color'), t_get('ovF_bej'));
WITH x AS (INSERT INTO cash_registers (business_id, branch_id, name) VALUES (t_get('bizF'), t_get('brF'), 'Moda Kasa') RETURNING id) SELECT t_set('regF', id) FROM x;
WITH x AS (INSERT INTO customers (business_id, full_name, phone) VALUES (t_get('bizF'), 'Moda Müşteri', '+90 555 071 0001') RETURNING id) SELECT t_set('cF', id) FROM x;

-- sales in the window (each a separate ticket; salesperson = manager)
CREATE FUNCTION t71_sell(k TEXT, qty INT) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE r JSONB; BEGIN
  r := rpc_pos_complete_sale(t_get('sessF'), t_json_items(k, qty::text, NULL), t_pay('cash','TRY', qty * (SELECT COALESCE(pv.sale_price_override, p.default_sale_price) FROM product_variants pv JOIN products p ON p.id = pv.product_id WHERE pv.id = t_get(k))), gen_random_uuid());
  RETURN (r ->> 'sale_id')::uuid; END $$;
-- supply (opening stock with known costs) + sales, all through the RPCs
SELECT t_login('u2');
SELECT t_ok('T71 supply: A 5/12/5 @100, B 20 @200, C 4×4 @150, D 10/10 @80, E 12/15/12 @120, F 3 @90', $q$
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFAS'), 'sellable', 5, 'fixture', 'manual_cost', 100);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFAM'), 'sellable', 12, 'fixture', 'manual_cost', 100);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFAL'), 'sellable', 5, 'fixture', 'manual_cost', 100);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFB'), 'sellable', 20, 'fixture', 'manual_cost', 200);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFCS'), 'sellable', 4, 'fixture', 'manual_cost', 150);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFCM'), 'sellable', 4, 'fixture', 'manual_cost', 150);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFCL'), 'sellable', 4, 'fixture', 'manual_cost', 150);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFCXL'), 'sellable', 4, 'fixture', 'manual_cost', 150);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFDS'), 'sellable', 10, 'fixture', 'manual_cost', 80);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFDK'), 'sellable', 10, 'fixture', 'manual_cost', 80);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFES'), 'sellable', 12, 'fixture', 'manual_cost', 120);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFEM'), 'sellable', 15, 'fixture', 'manual_cost', 120);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFEL'), 'sellable', 12, 'fixture', 'manual_cost', 120);
  SELECT rpc_post_inventory_adjustment(t_get('bizF'), t_get('brF'), t_get('vFF'),  'sellable', 3, 'fixture', 'manual_cost', 90) $q$);
SELECT t_set('sessF', rpc_open_register_session(t_get('regF'), '[]'::jsonb));
SELECT t_ok('T71 sales: A S1 M10 L1 · C M4 L4 · D Siyah9 Kırmızı1 · E S10 M12 L10 · F 1 · B 1 (to be backdated out of the window)', $q$
  SELECT t71_sell('vFAS', 1); SELECT t71_sell('vFAM', 2); SELECT t71_sell('vFAM', 2); SELECT t71_sell('vFAM', 2); SELECT t71_sell('vFAM', 2); SELECT t71_sell('vFAM', 2); SELECT t71_sell('vFAL', 1);
  SELECT t71_sell('vFCM', 2); SELECT t71_sell('vFCM', 2); SELECT t71_sell('vFCL', 2); SELECT t71_sell('vFCL', 2);
  SELECT t71_sell('vFDS', 3); SELECT t71_sell('vFDS', 3); SELECT t71_sell('vFDS', 3); SELECT t71_sell('vFDK', 1);
  SELECT t71_sell('vFES', 5); SELECT t71_sell('vFES', 5); SELECT t71_sell('vFEM', 4); SELECT t71_sell('vFEM', 4); SELECT t71_sell('vFEM', 4); SELECT t71_sell('vFEL', 5); SELECT t71_sell('vFEL', 5);
  SELECT t71_sell('vFF', 1) $q$);
SELECT t_set('sFB', t71_sell('vFB', 1));
-- returns on E: M 4 (2 back to sellable, 2 damaged), S 1 quarantine
SELECT t_set('siFEM1', (SELECT si.id FROM sale_items si JOIN sales s ON s.id = si.sale_id WHERE si.variant_id = t_get('vFEM') ORDER BY s.created_at LIMIT 1));
SELECT t_set('siFEM2', (SELECT si.id FROM sale_items si JOIN sales s ON s.id = si.sale_id WHERE si.variant_id = t_get('vFEM') ORDER BY s.created_at OFFSET 1 LIMIT 1));
SELECT t_set('siFES1', (SELECT si.id FROM sale_items si JOIN sales s ON s.id = si.sale_id WHERE si.variant_id = t_get('vFES') ORDER BY s.created_at LIMIT 1));
SELECT t_ok('T71 returns: E-M 2 sellable + 2 damaged, E-S 1 quarantine', $q$
  SELECT rpc_pos_return((SELECT sale_id FROM sale_items WHERE id = t_get('siFEM1')), t68_ret_item('siFEM1', 2, 'sellable'), 'refund', gen_random_uuid(), 'beden_olmadi', NULL, t_get('sessF'), 'cash');
  SELECT rpc_pos_return((SELECT sale_id FROM sale_items WHERE id = t_get('siFEM2')), t68_ret_item('siFEM2', 2, 'damaged'), 'refund', gen_random_uuid(), 'kusurlu_urun', NULL, t_get('sessF'), 'cash');
  SELECT rpc_pos_return((SELECT sale_id FROM sale_items WHERE id = t_get('siFES1')), t68_ret_item('siFES1', 1, 'quarantine'), 'refund', gen_random_uuid(), 'beden_olmadi', NULL, t_get('sessF'), 'cash') $q$);
-- reservations on F: two active holds (1 unit each) + one cancelled
SELECT t_set('rvF1', (rpc_pos_reservation_create(t_get('brF'), t_get('cF'), t_json_items('vFF','1',NULL)) ->> 'reservation_id')::uuid);
SELECT t_set('rvF2', (rpc_pos_reservation_create(t_get('brF'), t_get('cF'), t_json_items('vFF','1',NULL)) ->> 'reservation_id')::uuid);
SELECT t_set('rvF3', (rpc_pos_reservation_create(t_get('brF'), t_get('cF'), t_json_items('vFAS','1',NULL)) ->> 'reservation_id')::uuid);
SELECT t_ok('T71 one hold cancelled', $q$ SELECT rpc_reservation_cancel(t_get('rvF3'), 'vazgeçti') $q$);
SELECT t_logout();

-- backdate arrivals (A −20, B −150, C −45, D −30, E −25, F −10 days) and B's sale (−40 days): synthetic rows only
ALTER TABLE inventory_movements DISABLE TRIGGER trg_imm_inventory_movements;
UPDATE inventory_movements SET occurred_at = now() - interval '20 days' WHERE business_id = t_get('bizF') AND reason = 'adjustment' AND variant_id IN (t_get('vFAS'), t_get('vFAM'), t_get('vFAL'));
UPDATE inventory_movements SET occurred_at = now() - interval '150 days' WHERE business_id = t_get('bizF') AND reason = 'adjustment' AND variant_id = t_get('vFB');
UPDATE inventory_movements SET occurred_at = now() - interval '45 days' WHERE business_id = t_get('bizF') AND reason = 'adjustment' AND variant_id IN (t_get('vFCS'), t_get('vFCM'), t_get('vFCL'), t_get('vFCXL'));
UPDATE inventory_movements SET occurred_at = now() - interval '30 days' WHERE business_id = t_get('bizF') AND reason = 'adjustment' AND variant_id IN (t_get('vFDS'), t_get('vFDK'));
UPDATE inventory_movements SET occurred_at = now() - interval '25 days' WHERE business_id = t_get('bizF') AND reason = 'adjustment' AND variant_id IN (t_get('vFES'), t_get('vFEM'), t_get('vFEL'));
UPDATE inventory_movements SET occurred_at = now() - interval '10 days' WHERE business_id = t_get('bizF') AND reason = 'adjustment' AND variant_id = t_get('vFF');
ALTER TABLE inventory_movements ENABLE TRIGGER trg_imm_inventory_movements;
ALTER TABLE sales DISABLE TRIGGER trg_guard_sales;
UPDATE sales SET occurred_at = now() - interval '40 days' WHERE id = t_get('sFB');
ALTER TABLE sales ENABLE TRIGGER trg_guard_sales;

-- A) privileges
SELECT t_check('T71a privileges: intelligence RPCs to authenticated only, facts and helpers internal',
  has_function_privilege('authenticated', 'rpc_intel_home(uuid,uuid,integer,integer,integer,integer,integer,integer,integer,integer,integer)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_intel_home(uuid,uuid,integer,integer,integer,integer,integer,integer,integer,integer,integer)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_intel_dimensions(uuid,uuid,integer,uuid,uuid,integer)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_intel_product(uuid,integer,integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_intel_facts(uuid,uuid,timestamptz,timestamptz,boolean,boolean,boolean,uuid,text,uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_intel_access(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_intel_window(uuid,integer)', 'EXECUTE'));

-- B) manager home
SELECT t_login('u2');
CREATE TEMP TABLE _t71 AS SELECT rpc_intel_home(t_get('bizF'), NULL, 30) AS j;
GRANT SELECT ON _t71 TO authenticated;
SELECT t_check('T71b summary: 14 variants / 6 products, 12 with stock, 3 out (C-M, C-L, F), 63 sold and 5 returned in the window, 2 active holds, enough data',
  (SELECT (j -> 'summary' ->> 'variants')::int = 14 AND (j -> 'summary' ->> 'products')::int = 6 AND (j -> 'summary' ->> 'with_stock')::int = 12
      AND (j -> 'summary' ->> 'out_of_stock')::int = 3 AND (j -> 'summary' ->> 'never_stocked')::int = 0
      AND (j -> 'summary' ->> 'sold_win')::int = 63 AND (j -> 'summary' ->> 'returned_win')::int = 5 AND (j -> 'summary' ->> 'holds_active')::int = 2
      AND (j -> 'summary' ->> 'enough_data')::boolean AND (j -> 'window' ->> 'days')::int = 30 AND (j ->> 'financial')::boolean FROM _t71),
  (SELECT j -> 'summary' FROM _t71)::text);
SELECT t_check('T71b fast movers by velocity: E 32/26 = 1.23, A 12/21 = 0.57, D 10/30 = 0.33, C 8/30 = 0.27; F (1 unit) and B (0) excluded',
  (SELECT jsonb_array_length(j -> 'fast_movers') = 4
      AND (j -> 'fast_movers' -> 0 ->> 'product') = 'E İade Pantolon' AND (j -> 'fast_movers' -> 0 ->> 'velocity')::numeric = 1.23 AND (j -> 'fast_movers' -> 0 ->> 'active_days')::int = 26
      AND (j -> 'fast_movers' -> 1 ->> 'product') = 'A Hızlı Tişört' AND (j -> 'fast_movers' -> 1 ->> 'velocity')::numeric = 0.57 AND (j -> 'fast_movers' -> 1 ->> 'sold_win')::int = 12
      AND (j -> 'fast_movers' -> 1 ->> 'sell_through_pct')::numeric = 54.5 AND (j -> 'fast_movers' -> 1 ->> 'days_of_cover')::numeric = 18
      AND (j -> 'fast_movers' -> 2 ->> 'product') = 'D Renk Gömlek' AND (j -> 'fast_movers' -> 2 ->> 'velocity')::numeric = 0.33
      AND (j -> 'fast_movers' -> 3 ->> 'product') = 'C Kırık Beden Elbise' AND (j -> 'fast_movers' -> 3 ->> 'velocity')::numeric = 0.27 FROM _t71),
  (SELECT j -> 'fast_movers' FROM _t71)::text);
SELECT t_check('T71b slow movers: only B (150 days, 19 available, 0 in window, last sale 40 days ago) with its explanation and value 3800',
  (SELECT jsonb_array_length(j -> 'slow_movers') = 1 AND (j -> 'slow_movers' -> 0 ->> 'sku') = 'FB-STD' AND (j -> 'slow_movers' -> 0 ->> 'age_days')::int = 150
      AND (j -> 'slow_movers' -> 0 ->> 'available')::int = 19 AND (j -> 'slow_movers' -> 0 ->> 'days_since_sale')::int = 40
      AND (j -> 'slow_movers' -> 0 ->> 'sellable_value')::numeric = 3800
      AND (j -> 'slow_movers' -> 0 ->> 'why') = '150 gündür stokta, 19 adet müsait, son 30 günde 0 adet satıldı, son satış 40 gün önce' FROM _t71),
  (SELECT j -> 'slow_movers' FROM _t71)::text);
SELECT t_check('T71b broken size run: only C — S XL available, M L missing (8 sold from the missing sizes), no never-stocked size',
  (SELECT jsonb_array_length(j -> 'broken_size_runs') = 1 AND (j -> 'broken_size_runs' -> 0 ->> 'product') = 'C Kırık Beden Elbise'
      AND (j -> 'broken_size_runs' -> 0 ->> 'sizes_available') = 'S XL' AND (j -> 'broken_size_runs' -> 0 ->> 'sizes_missing') = 'M L'
      AND (j -> 'broken_size_runs' -> 0 -> 'sizes_never_stocked') = 'null'::jsonb
      AND (j -> 'broken_size_runs' -> 0 ->> 'sold_win_missing_sizes')::int = 8 AND (j -> 'broken_size_runs' -> 0 ->> 'available')::int = 8 FROM _t71),
  (SELECT j -> 'broken_size_runs' FROM _t71)::text);
SELECT t_check('T71b out of stock with demand: C-M (4), C-L (4), F (1 sold, 2 holds)',
  (SELECT jsonb_array_length(j -> 'out_of_stock') = 3
      AND (SELECT string_agg(x ->> 'sku', ',' ORDER BY (x ->> 'sold_win')::int DESC, x ->> 'sku') FROM jsonb_array_elements(j -> 'out_of_stock') x) = 'FC-L,FC-M,FF-STD'
      AND (SELECT (x ->> 'holds_active')::int FROM jsonb_array_elements(j -> 'out_of_stock') x WHERE x ->> 'sku' = 'FF-STD') = 2 FROM _t71),
  (SELECT j -> 'out_of_stock' FROM _t71)::text);
SELECT t_check('T71b replenishment candidates: A-M (10 sold, 2 left), E-L / E-S (10, 2), D-Siyah (9, 1), C-M (4, 0), C-L (4, 0), F (holds ≥ available) — each with its sentence',
  (SELECT jsonb_array_length(j -> 'replenishment') = 7
      AND (j -> 'replenishment' -> 0 ->> 'sku') = 'FA-M' AND (j -> 'replenishment' -> 0 ->> 'why') = 'Son 30 günde 10 adet satıldı, 2 adet müsait kaldı.'
      AND (j -> 'replenishment' -> 3 ->> 'sku') = 'FD-M-SYH' AND (j -> 'replenishment' -> 3 ->> 'available')::int = 1
      AND (SELECT string_agg(x ->> 'sku', ',' ORDER BY x ->> 'sku') FROM jsonb_array_elements(j -> 'replenishment') x) = 'FA-M,FC-L,FC-M,FD-M-SYH,FE-L,FE-S,FF-STD'
      AND (SELECT x ->> 'why' FROM jsonb_array_elements(j -> 'replenishment') x WHERE x ->> 'sku' = 'FF-STD') = 'Son 30 günde 1 adet satıldı, 0 adet müsait, 2 aktif rezervasyon bekliyor.' FROM _t71),
  (SELECT j -> 'replenishment' FROM _t71)::text);
SELECT t_check('T71b excess: only B (19 available ≥ 10, 150 days, nothing sold in the window); D-Kırmızı (9, 30 days) is not',
  (SELECT jsonb_array_length(j -> 'excess') = 1 AND (j -> 'excess' -> 0 ->> 'sku') = 'FB-STD'
      AND (j -> 'excess' -> 0 ->> 'why') = '19 adet müsait, 150 gündür stokta, son 30 günde hiç satılmadı.' FROM _t71),
  (SELECT j -> 'excess' FROM _t71)::text);
SELECT t_check('T71b aging by first arrival: 0–30 = 31 units / 9 variants / 3060; 31–60 = 8 / 2 / 1200; 61–90 0; 91–120 0; 120+ = 19 / 1 / 3800',
  (SELECT jsonb_array_length(j -> 'aging') = 5
      AND (j -> 'aging' -> 0 ->> 'units')::int = 31 AND (j -> 'aging' -> 0 ->> 'variants')::int = 9 AND (j -> 'aging' -> 0 ->> 'value')::numeric = 3060
      AND (j -> 'aging' -> 1 ->> 'units')::int = 8 AND (j -> 'aging' -> 1 ->> 'variants')::int = 2 AND (j -> 'aging' -> 1 ->> 'value')::numeric = 1200
      AND (j -> 'aging' -> 2 ->> 'units')::int = 0 AND (j -> 'aging' -> 3 ->> 'units')::int = 0
      AND (j -> 'aging' -> 4 ->> 'bucket') = '120+' AND (j -> 'aging' -> 4 ->> 'units')::int = 19 AND (j -> 'aging' -> 4 ->> 'value')::numeric = 3800
      AND (j -> 'aging' -> 4 ->> 'no_sale_units')::int = 19 FROM _t71),
  (SELECT j -> 'aging' FROM _t71)::text);
SELECT t_check('T71b aging value equals the cost pools (MWA × sellable)',
  (SELECT (SELECT sum((x ->> 'value')::numeric) FROM jsonb_array_elements(j -> 'aging') x) FROM _t71)
  = (SELECT round(sum(vcp.total_value_base / vcp.on_hand_qty * (SELECT sum(m.quantity) FROM inventory_movements m WHERE m.variant_id = vcp.variant_id AND m.bucket = 'sellable')), 2)
     FROM variant_cost_pools vcp WHERE vcp.business_id = t_get('bizF') AND vcp.on_hand_qty > 0));
SELECT t_check('T71b return signals: E·M size 4/12 = 33.3 % meaningful, E·S 1/10 = 10 % meaningful, product E 5/32 = 15.6 %; nothing for A–D, F',
  (SELECT (SELECT (x ->> 'rate_pct')::numeric FROM jsonb_array_elements(j -> 'return_signals') x WHERE x ->> 'kind' = 'size' AND x ->> 'key' = t_get('pFE')::text || ':M') = 33.3
      AND (SELECT (x ->> 'meaningful')::boolean FROM jsonb_array_elements(j -> 'return_signals') x WHERE x ->> 'kind' = 'size' AND x ->> 'key' = t_get('pFE')::text || ':M')
      AND (SELECT (x ->> 'rate_pct')::numeric FROM jsonb_array_elements(j -> 'return_signals') x WHERE x ->> 'kind' = 'size' AND x ->> 'key' = t_get('pFE')::text || ':S') = 10.0
      AND (SELECT (x ->> 'rate_pct')::numeric FROM jsonb_array_elements(j -> 'return_signals') x WHERE x ->> 'kind' = 'product') = 15.6
      AND (SELECT (x ->> 'sold_win')::int FROM jsonb_array_elements(j -> 'return_signals') x WHERE x ->> 'kind' = 'product') = 32
      AND (SELECT count(*) FROM jsonb_array_elements(j -> 'return_signals') x WHERE x ->> 'kind' = 'variant') = 2
      AND (j -> 'return_signals' -> 0 ->> 'rate_pct')::numeric = 33.3 FROM _t71),
  (SELECT j -> 'return_signals' FROM _t71)::text);
SELECT t_check('T71b reservation demand: F 2 active holds on 2 sellable → 0 available, low stock; A-S shows the cancelled hold',
  (SELECT (SELECT (x ->> 'holds_active')::int = 2 AND (x ->> 'reserved')::int = 2 AND (x ->> 'sellable')::int = 2 AND (x ->> 'available')::int = 0 AND (x ->> 'low_stock')::boolean
          FROM jsonb_array_elements(j -> 'reservation_demand') x WHERE x ->> 'sku' = 'FF-STD')
      AND (SELECT (x ->> 'cancelled_win')::int = 1 AND (x ->> 'holds_active')::int = 0 FROM jsonb_array_elements(j -> 'reservation_demand') x WHERE x ->> 'sku' = 'FA-S')
      AND jsonb_array_length(j -> 'reservation_demand') = 2 FROM _t71),
  (SELECT j -> 'reservation_demand' FROM _t71)::text);
SELECT t_check('T71b a 7-day window makes B''s 40-day-old sale and the 30-day stocked D still count correctly (window bounded, thresholds echoed)',
  (SELECT (j -> 'window' ->> 'days')::int = 7 AND (j -> 'thresholds' ->> 'min_sample')::int = 5 AND (j -> 'thresholds' ->> 'slow_age_days')::int = 60
   FROM (SELECT rpc_intel_home(t_get('bizF'), NULL, 3, 5) AS j) x));
SELECT t_err('T71b branch of another tenant refused', $q$ SELECT rpc_intel_home(t_get('bizF'), t_get('brB')) $q$, 'INVALID_BRANCH');

-- C) size / colour dimensions
CREATE TEMP TABLE _t71d AS SELECT rpc_intel_dimensions(t_get('bizF'), NULL, 30) AS j;
GRANT SELECT ON _t71d TO authenticated;
SELECT t_check('T71c sizes: S 11 (17.7 %), M 36 (58.1 %), L 15 (24.2 %), XL 0 — over 62 sized units; availability and stockouts per size',
  (SELECT (j ->> 'sold_sized')::int = 62 AND jsonb_array_length(j -> 'sizes') = 4
      AND (j -> 'sizes' -> 0 ->> 'value') = 'S' AND (j -> 'sizes' -> 0 ->> 'sold_win')::int = 11 AND (j -> 'sizes' -> 0 ->> 'share_pct')::numeric = 17.7
      AND (j -> 'sizes' -> 1 ->> 'value') = 'M' AND (j -> 'sizes' -> 1 ->> 'sold_win')::int = 36 AND (j -> 'sizes' -> 1 ->> 'share_pct')::numeric = 58.1
      AND (j -> 'sizes' -> 1 ->> 'returned_win')::int = 4 AND (j -> 'sizes' -> 1 ->> 'return_rate_pct')::numeric = 11.1
      AND (j -> 'sizes' -> 1 ->> 'variants_out')::int = 1 AND (j -> 'sizes' -> 1 ->> 'available')::int = 2 + 0 + 1 + 9 + 5
      AND (j -> 'sizes' -> 2 ->> 'value') = 'L' AND (j -> 'sizes' -> 2 ->> 'share_pct')::numeric = 24.2
      AND (j -> 'sizes' -> 3 ->> 'value') = 'XL' AND (j -> 'sizes' -> 3 ->> 'sold_win')::int = 0 AND (j -> 'sizes' -> 3 ->> 'share_pct')::numeric = 0 FROM _t71d),
  (SELECT j -> 'sizes' FROM _t71d)::text);
SELECT t_check('T71c colours: Siyah 9 (81.8 %), Kırmızı 1 (9.1 %), Bej 1 (9.1 %) over 11 coloured units; Kırmızı 9 available, Siyah 1',
  (SELECT (j ->> 'sold_colored')::int = 11
      AND (j -> 'colors' -> 0 ->> 'value') = 'Siyah' AND (j -> 'colors' -> 0 ->> 'share_pct')::numeric = 81.8 AND (j -> 'colors' -> 0 ->> 'available')::int = 1
      AND (SELECT (x ->> 'available')::int FROM jsonb_array_elements(j -> 'colors') x WHERE x ->> 'value' = 'Kırmızı') = 9
      AND (SELECT (x ->> 'share_pct')::numeric FROM jsonb_array_elements(j -> 'colors') x WHERE x ->> 'value' = 'Bej') = 9.1
      AND (SELECT (x ->> 'return_rate_pct') IS NULL FROM jsonb_array_elements(j -> 'colors') x WHERE x ->> 'value' = 'Bej') FROM _t71d),
  (SELECT j -> 'colors' FROM _t71d)::text);
SELECT t_check('T71c small sample: category Alt alone has E + F; a product filter on D shows shares (10 units) but no return rate (< 10 per colour)',
  (SELECT (j -> 'colors' -> 0 ->> 'share_pct')::numeric = 90.0 AND (j -> 'colors' -> 0 ->> 'return_rate_pct') IS NULL AND (j ->> 'sold_colored')::int = 10
   FROM (SELECT rpc_intel_dimensions(t_get('bizF'), NULL, 30, NULL, t_get('pFD')) AS j) x)
  AND (SELECT (j ->> 'sold_win')::int = 33 AND (SELECT count(*) FROM jsonb_array_elements(j -> 'sizes')) = 3
       FROM (SELECT rpc_intel_dimensions(t_get('bizF'), NULL, 30, t_get('catF2')) AS j) x));
SELECT t_check('T71c below the sample threshold shares are withheld (min_sample 100 → NULL), counts still shown',
  (SELECT (j -> 'sizes' -> 1 ->> 'share_pct') IS NULL AND (j -> 'sizes' -> 1 ->> 'sold_win')::int = 36
   FROM (SELECT rpc_intel_dimensions(t_get('bizF'), NULL, 30, NULL, NULL, 100) AS j) x));

-- D) product intelligence
CREATE TEMP TABLE _t71p AS SELECT rpc_intel_product(t_get('pFA'), 30) AS j;
GRANT SELECT ON _t71p TO authenticated;
SELECT t_check('T71d product A: 12 sold / 22 supplied → sell-through 54.5 %, velocity 0.57 over 21 active days, cover 18 days, stock 10, age 20, value 1000',
  (SELECT (j ->> 'sold_win')::int = 12 AND (j ->> 'supplied')::int = 22 AND (j ->> 'sell_through_pct')::numeric = 54.5
      AND (j ->> 'velocity')::numeric = 0.57 AND (j ->> 'active_days')::int = 21 AND (j ->> 'days_of_cover')::numeric = 18
      AND (j -> 'stock' ->> 'available')::int = 10 AND (j -> 'stock' ->> 'sellable')::int = 10 AND (j ->> 'age_days')::int = 20
      AND (j ->> 'stock_value')::numeric = 1000 AND (j ->> 'enough_data')::boolean AND (j ->> 'return_rate_pct')::numeric = 0
      AND (j ->> 'holds_active')::int = 0 AND (j ->> 'variants_out')::int = 0 FROM _t71p),
  (SELECT j FROM _t71p)::text);
SELECT t_check('T71d product A sizes: M 10 of 12 = 83.3 %, 2 available; S 1 (8.3 %); L 1; variants detail in size order',
  (SELECT (j -> 'sizes' -> 1 ->> 'value') = 'M' AND (j -> 'sizes' -> 1 ->> 'share_pct')::numeric = 83.3 AND (j -> 'sizes' -> 1 ->> 'available')::int = 2
      AND (j -> 'sizes' -> 0 ->> 'value') = 'S' AND (j -> 'sizes' -> 0 ->> 'share_pct')::numeric = 8.3
      AND (j -> 'variants_detail' -> 0 ->> 'sku') = 'FA-S' AND (j -> 'variants_detail' -> 1 ->> 'sku') = 'FA-M' AND (j -> 'variants_detail' -> 1 ->> 'age_days')::int = 20 FROM _t71p),
  (SELECT j -> 'sizes' FROM _t71p)::text);
SELECT t_check('T71d product B: sell-through 5 %, no sale in the window → velocity 0, no cover, last sale 40 days ago, not enough data',
  (SELECT (j ->> 'sell_through_pct')::numeric = 5.0 AND (j ->> 'velocity')::numeric = 0 AND (j ->> 'days_of_cover') IS NULL
      AND (j ->> 'days_since_sale')::int = 40 AND (j ->> 'age_days')::int = 150 AND NOT (j ->> 'enough_data')::boolean AND (j ->> 'return_rate_pct') IS NULL
   FROM (SELECT rpc_intel_product(t_get('pFB'), 30) AS j) x));
SELECT t_check('T71d product C sizes flag the missing M and L',
  (SELECT (SELECT bool_and((x ->> 'out')::boolean) FROM jsonb_array_elements(j -> 'sizes') x WHERE x ->> 'value' IN ('M','L'))
      AND (SELECT bool_and(NOT (x ->> 'out')::boolean) FROM jsonb_array_elements(j -> 'sizes') x WHERE x ->> 'value' IN ('S','XL'))
      AND (j ->> 'variants_out')::int = 2 FROM (SELECT rpc_intel_product(t_get('pFC'), 30) AS j) x));
SELECT t_err('T71d unknown product → NOT_FOUND', $q$ SELECT rpc_intel_product(gen_random_uuid()) $q$, 'NOT_FOUND');
SELECT t_logout();

-- E) roles
SELECT t_login('u3');
CREATE TEMP TABLE _t71s AS SELECT rpc_intel_home(t_get('bizF'), NULL, 30) AS j;
GRANT SELECT ON _t71s TO authenticated;
SELECT t_check('T71e sales_staff (scope own, sold nothing): no sales-derived signals, no money; stock-side signals intact (broken C, F waits on holds)',
  (SELECT NOT (j ->> 'financial')::boolean AND j ->> 'scope' = 'own' AND (j -> 'summary' ->> 'sold_win')::int = 0 AND NOT (j -> 'summary' ->> 'enough_data')::boolean
      AND jsonb_array_length(j -> 'fast_movers') = 0 AND jsonb_array_length(j -> 'broken_size_runs') = 1
      AND (SELECT string_agg(x ->> 'sku', ',' ORDER BY x ->> 'sku') FROM jsonb_array_elements(j -> 'replenishment') x) = 'FF-STD'
      AND (j -> 'aging' -> 4 -> 'value') = 'null'::jsonb AND (j -> 'aging' -> 4 ->> 'units')::int = 19
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'slow_movers') x WHERE (x -> 'sellable_value') <> 'null'::jsonb) FROM _t71s),
  (SELECT j FROM _t71s)::text);
SELECT t_check('T71e sales_staff product view: no stock value, no sell-through from invisible sales',
  (SELECT (j ->> 'stock_value') IS NULL AND (j ->> 'sold_win')::int = 0 AND (j ->> 'sell_through_pct')::numeric = 0 AND (j -> 'stock' ->> 'available')::int = 10
   FROM (SELECT rpc_intel_product(t_get('pFA'), 30) AS j) x));
SELECT t_logout();
UPDATE businesses SET settings = settings || '{"sales_visibility_scope":"business"}'::jsonb WHERE id = t_get('bizF');
SELECT t_login('u3');
SELECT t_check('T71e sales_staff under scope=business sees the sales-derived signals, still no money',
  (SELECT (j -> 'summary' ->> 'sold_win')::int = 63 AND jsonb_array_length(j -> 'fast_movers') = 4 AND jsonb_array_length(j -> 'replenishment') = 7
      AND (j -> 'slow_movers' -> 0 -> 'sellable_value') = 'null'::jsonb AND (j -> 'aging' -> 0 -> 'value') = 'null'::jsonb
   FROM (SELECT rpc_intel_home(t_get('bizF'), NULL, 30) AS j) x));
SELECT t_logout();
UPDATE businesses SET settings = settings || '{"sales_visibility_scope":"own"}'::jsonb WHERE id = t_get('bizF');
SELECT t_login('u4');
SELECT t_check('T71e stock_staff: stock-side only — sales, returns, holds and value sections absent; F counts as available (holds invisible)',
  (SELECT (j -> 'fast_movers') = 'null'::jsonb AND (j -> 'slow_movers') = 'null'::jsonb AND (j -> 'replenishment') = 'null'::jsonb AND (j -> 'excess') = 'null'::jsonb
      AND (j -> 'return_signals') = 'null'::jsonb AND (j -> 'reservation_demand') = 'null'::jsonb AND NOT (j ->> 'sales')::boolean
      AND jsonb_array_length(j -> 'broken_size_runs') = 1 AND (j -> 'summary' ->> 'out_of_stock')::int = 2
      AND (j -> 'aging' -> 4 ->> 'units')::int = 19 AND (j -> 'aging' -> 4 -> 'value') = 'null'::jsonb
   FROM (SELECT rpc_intel_home(t_get('bizF'), NULL, 30) AS j) x));
SELECT t_check('T71e stock_staff dimensions: availability only, no sold units',
  (SELECT (j ->> 'sold_win')::int = 0 AND (j -> 'sizes' -> 1 ->> 'available')::int = 2 + 0 + 1 + 9 + 5 AND (j -> 'sizes' -> 1 ->> 'share_pct') IS NULL
   FROM (SELECT rpc_intel_dimensions(t_get('bizF'), NULL, 30) AS j) x));
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T71e other tenant: home FORBIDDEN', $q$ SELECT rpc_intel_home(t_get('bizF')) $q$, 'FORBIDDEN');
SELECT t_err('T71e other tenant: product FORBIDDEN', $q$ SELECT rpc_intel_product(t_get('pFA')) $q$, 'FORBIDDEN');
SELECT t_err('T71e other tenant: dimensions FORBIDDEN', $q$ SELECT rpc_intel_dimensions(t_get('bizF')) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_err('T71e unauthenticated refused', $q$ SELECT rpc_intel_home(t_get('bizF')) $q$, 'UNAUTHENTICATED');
SELECT t_login('u5');
SELECT t_check('T71e sparse tenant (bizB) answers honestly: no fabricated fast movers, slow movers or candidates from a handful of sales',
  (SELECT jsonb_array_length(j -> 'slow_movers') = 0 AND jsonb_array_length(j -> 'excess') = 0
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'fast_movers') x WHERE (x ->> 'sold_win')::int < 3 OR (x ->> 'active_days')::int < 7)
   FROM (SELECT rpc_intel_home(t_get('bizB'), NULL, 30) AS j) x));
SELECT t_logout();
SELECT t_check('T71e intelligence wrote nothing', (SELECT count(*) FROM sales WHERE business_id = t_get('bizF')) = 24
  AND (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizF')) = 14 + 24 + 3);

-- ============================================================
-- T72 — Phase 12A purchase orders: lifecycle, zero side effects before receipt POST,
--        receipt link + partial receiving + over-receipt + draft/cancelled receipts not counted,
--        cost and FX independence, reversal, close remaining, cancel rules, roles, cross-tenant.
-- ============================================================
SELECT t_logout();
SELECT t_set('bizP', 'b0000000-0000-4000-8000-000000000010');
INSERT INTO businesses (id, name, code, settings) VALUES (t_get('bizP'), 'Sipariş Butik', 'PO', jsonb_build_object(
  'accepted_currencies', jsonb_build_array('TRY','EUR'), 'money_refund_allowed', false, 'store_credit_allowed', false, 'exchange_window_days', 14,
  'default_charge_allocation_method', 'invoice_value_proportional'));
WITH x AS (INSERT INTO branches (business_id, name, code, is_default) VALUES (t_get('bizP'), 'Sipariş Merkez', 'SM', true) RETURNING id) SELECT t_set('brP', id) FROM x;
INSERT INTO business_members (business_id, user_id, role) VALUES
  (t_get('bizP'), t_get('u1'), 'owner'), (t_get('bizP'), t_get('u2'), 'manager'),
  (t_get('bizP'), t_get('u3'), 'sales_staff'), (t_get('bizP'), t_get('u4'), 'stock_staff');
WITH x AS (INSERT INTO suppliers (business_id, name, currency) VALUES (t_get('bizP'), 'Tedarikçi A', 'EUR') RETURNING id) SELECT t_set('supPA', id) FROM x;
WITH x AS (INSERT INTO suppliers (business_id, name, currency) VALUES (t_get('bizP'), 'Tedarikçi B', 'TRY') RETURNING id) SELECT t_set('supPB', id) FROM x;
WITH x AS (INSERT INTO product_options (business_id, name, kind, sort_order) VALUES (t_get('bizP'), 'Beden', 'size', 10) RETURNING id) SELECT t_set('optP_size', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optP_size'), 'S', 'S', 1) RETURNING id) SELECT t_set('ovP_s', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optP_size'), 'M', 'M', 2) RETURNING id) SELECT t_set('ovP_m', id) FROM x;
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('bizP'), 'Siyah Elbise', 'PD', 900, 'active') RETURNING id) SELECT t_set('pPD', id) FROM x;
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('bizP'), 'Tek Beden Üst', 'PT', 400, 'active') RETURNING id) SELECT t_set('pPT', id) FROM x;
WITH x AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status) VALUES (t_get('bizP'), 'Diğer Ürün', 'PX', 100, 'active') RETURNING id) SELECT t_set('pPX', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pPD'), 'PD-S') RETURNING id) SELECT t_set('vPDS', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vPDS'), t_get('optP_size'), t_get('ovP_s'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pPD'), 'PD-M') RETURNING id) SELECT t_set('vPDM', id) FROM x;
INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id) VALUES (t_get('vPDM'), t_get('optP_size'), t_get('ovP_m'));
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pPT'), 'PT-STD') RETURNING id) SELECT t_set('vPT', id) FROM x;
WITH x AS (INSERT INTO product_variants (product_id, sku) VALUES (t_get('pPX'), 'PX-STD') RETURNING id) SELECT t_set('vPX', id) FROM x;
CREATE TEMP TABLE _t72_base AS
  SELECT (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizP')) AS movements,
         (SELECT count(*) FROM variant_cost_pools WHERE business_id = t_get('bizP')) AS pools,
         (SELECT COALESCE(sum(on_hand_qty), 0) FROM variant_cost_pools WHERE business_id = t_get('bizP')) AS on_hand,
         (SELECT count(*) FROM supplier_account_entries WHERE business_id = t_get('bizP')) AS liabilities,
         (SELECT count(*) FROM inventory_movement_costs WHERE business_id = t_get('bizP')) AS mcosts;
GRANT SELECT ON _t72_base TO authenticated;
CREATE FUNCTION t72_untouched() RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER AS $$
  SELECT (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizP')) = (SELECT movements FROM _t72_base)
     AND (SELECT count(*) FROM variant_cost_pools WHERE business_id = t_get('bizP')) = (SELECT pools FROM _t72_base)
     AND (SELECT COALESCE(sum(on_hand_qty), 0) FROM variant_cost_pools WHERE business_id = t_get('bizP')) = (SELECT on_hand FROM _t72_base)
     AND (SELECT count(*) FROM supplier_account_entries WHERE business_id = t_get('bizP')) = (SELECT liabilities FROM _t72_base)
     AND (SELECT count(*) FROM inventory_movement_costs WHERE business_id = t_get('bizP')) = (SELECT mcosts FROM _t72_base) $$;
CREATE FUNCTION t72_received(po TEXT, v TEXT) RETURNS INTEGER LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT received FROM fn_po_received(t_get(po)) WHERE variant_id = t_get(v)), 0) $$;
CREATE FUNCTION t72_status(po TEXT) RETURNS TEXT LANGUAGE sql SECURITY DEFINER AS $$ SELECT status::text FROM purchase_orders WHERE id = t_get(po) $$;
CREATE FUNCTION t72_lines(gr TEXT, OUT n INT, OUT qty INT, OUT unpriced BOOLEAN) LANGUAGE sql SECURITY DEFINER AS $$
  SELECT count(*)::int, COALESCE(sum(quantity), 0)::int, COALESCE(bool_and(unit_cost IS NULL), true) FROM goods_receipt_items WHERE goods_receipt_id = t_get(gr) $$;
CREATE FUNCTION t72_expected(po TEXT, v TEXT) RETURNS NUMERIC LANGUAGE sql SECURITY DEFINER AS $$ SELECT expected_unit_cost FROM purchase_order_items WHERE purchase_order_id = t_get(po) AND variant_id = t_get(v) $$;

-- A) privileges + numbering
SELECT t_check('T72a privileges: PO RPCs to authenticated only; tables write-locked for clients; expected cost column unreadable',
  has_function_privilege('authenticated', 'rpc_po_create(uuid,uuid,text,numeric,date,date,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_po_create(uuid,uuid,text,numeric,date,date,text,text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_po_approve(uuid)', 'EXECUTE') AND has_function_privilege('authenticated', 'rpc_po_create_receipt(uuid,date,text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'rpc_po_list(uuid,text,integer)', 'EXECUTE') AND has_function_privilege('authenticated', 'rpc_po_detail(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fn_po_received(uuid)', 'EXECUTE') AND NOT has_function_privilege('authenticated', 'fn_po_refresh_status(uuid)', 'EXECUTE')
  AND NOT has_table_privilege('authenticated', 'purchase_orders', 'INSERT') AND NOT has_table_privilege('authenticated', 'purchase_orders', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'purchase_orders', 'DELETE') AND NOT has_table_privilege('authenticated', 'purchase_order_items', 'INSERT')
  AND has_column_privilege('authenticated', 'purchase_order_items', 'ordered_quantity', 'SELECT')
  AND NOT has_column_privilege('authenticated', 'purchase_order_items', 'expected_unit_cost', 'SELECT'));

-- B) draft: create, lines, edit, total 2,400 EUR; zero side effects
SELECT t_login('u2');
SELECT t_set('po1', rpc_po_create(t_get('brP'), t_get('supPA'), 'EUR', 35, CURRENT_DATE, CURRENT_DATE + 14, 'A-REF-1', 'ilk sipariş'));
SELECT t_check('T72b draft created with a PO-YYYY-000001 number in EUR', (SELECT status = 'draft' AND po_number ~ ('^PO-' || extract(year from now())::int || '-[0-9]{6}$') AND currency = 'EUR' AND fx_rate_snapshot = 35 AND created_by = t_get('u2') FROM purchase_orders WHERE id = t_get('po1')));
SELECT t_ok('T72b lines: S 10 @100, M 12 @100 (edited to 10), Top 5 @80, a stray line removed', $q$
  SELECT rpc_po_upsert_line(t_get('po1'), t_get('vPDS'), 10, 100);
  SELECT rpc_po_upsert_line(t_get('po1'), t_get('vPDM'), 12, 100);
  SELECT rpc_po_upsert_line(t_get('po1'), t_get('vPDM'), 10, 100);
  SELECT rpc_po_upsert_line(t_get('po1'), t_get('vPT'), 5, 80);
  SELECT rpc_po_upsert_line(t_get('po1'), t_get('vPX'), 1, 1);
  SELECT rpc_po_remove_line(t_get('po1'), t_get('vPX')) $q$);
SELECT t_check('T72b detail: 3 lines, 25 ordered, 0 received, expected total 2400, timeline created',
  (SELECT (j -> 'totals' ->> 'lines')::int = 3 AND (j -> 'totals' ->> 'ordered')::int = 25 AND (j -> 'totals' ->> 'received')::int = 0 AND (j -> 'totals' ->> 'remaining')::int = 25
      AND (j -> 'totals' ->> 'expected_total')::numeric = 2400 AND (j -> 'totals' ->> 'unpriced_lines')::int = 0 AND (j ->> 'financial')::boolean
      AND (j -> 'timeline' -> 'created' ->> 'at') IS NOT NULL AND (j -> 'timeline' -> 'approved') = 'null'::jsonb
      AND (SELECT (l ->> 'expected_total')::numeric FROM jsonb_array_elements(j -> 'lines') l WHERE l ->> 'sku' = 'PD-M') = 1000
   FROM (SELECT rpc_po_detail(t_get('po1')) AS j) x), rpc_po_detail(t_get('po1'))::text);
SELECT t_err('T72b foreign supplier refused', $q$ SELECT rpc_po_create(t_get('brP'), t_get('sup1'), 'TRY') $q$, 'INVALID_SUPPLIER');
SELECT t_err('T72b foreign branch refused', $q$ SELECT rpc_po_create(t_get('brB'), t_get('supPA'), 'TRY') $q$, 'FORBIDDEN');
SELECT t_err('T72b foreign variant refused', $q$ SELECT rpc_po_upsert_line(t_get('po1'), t_get('v66a'), 1, 1) $q$, 'INVALID_VARIANT');
SELECT t_err('T72b TRY order with a rate ≠ 1 refused', $q$ SELECT rpc_po_create(t_get('brP'), t_get('supPB'), 'TRY', 2) $q$, 'INVALID_FX');
SELECT t_err('T72b expected date before order date refused', $q$ SELECT rpc_po_update(t_get('po1'), CURRENT_DATE - 1, NULL, NULL) $q$, 'INVALID_DATE');
SELECT t_err('T72b zero quantity refused', $q$ SELECT rpc_po_upsert_line(t_get('po1'), t_get('vPDS'), 0, 100) $q$, 'INVALID_QTY');
-- C) approve → ordered; terms frozen; expected date still editable; zero side effects
SELECT t_set('po_empty', rpc_po_create(t_get('brP'), t_get('supPB'), 'TRY'));
SELECT t_err('T72c empty order cannot be approved', $q$ SELECT rpc_po_approve(t_get('po_empty')) $q$, 'EMPTY_DOCUMENT');
SELECT t_err('T72c a draft cannot be marked ordered before approval', $q$ SELECT rpc_po_mark_ordered(t_get('po1')) $q$, 'INVALID_STATE');
SELECT t_ok('T72c approve', $q$ SELECT rpc_po_approve(t_get('po1')) $q$);
SELECT t_check('T72c approved by the manager, stamped', (SELECT status = 'approved' AND approved_by = t_get('u2') AND approved_at IS NOT NULL FROM purchase_orders WHERE id = t_get('po1')));
SELECT t_err('T72c lines frozen after approval', $q$ SELECT rpc_po_upsert_line(t_get('po1'), t_get('vPDS'), 11, 100) $q$, 'INVALID_STATE');
SELECT t_err('T72c approve twice refused', $q$ SELECT rpc_po_approve(t_get('po1')) $q$, 'INVALID_STATE');
SELECT t_err('T72c receipt cannot be created before the order is sent', $q$ SELECT rpc_po_create_receipt(t_get('po1')) $q$, 'PO_NOT_OPEN');
SELECT t_ok('T72c expected date / note stay editable', $q$ SELECT rpc_po_update(t_get('po1'), CURRENT_DATE + 21, 'A-REF-1b', 'not güncellendi') $q$);
SELECT t_ok('T72c mark ordered', $q$ SELECT rpc_po_mark_ordered(t_get('po1')) $q$);
SELECT t_check('T72c ordered by the manager, expected date kept', (SELECT status = 'ordered' AND ordered_by = t_get('u2') AND ordered_at IS NOT NULL AND expected_date = CURRENT_DATE + 21 FROM purchase_orders WHERE id = t_get('po1')));
SELECT t_logout();
SELECT t_err('T72c commercial terms frozen even for the database owner path', $q$ UPDATE purchase_orders SET supplier_id = t_get('supPB') WHERE id = t_get('po1') $q$, 'IMMUTABLE');
SELECT t_err('T72c lines of an ordered PO cannot be inserted directly', $q$ INSERT INTO purchase_order_items (purchase_order_id, variant_id, ordered_quantity) VALUES (t_get('po1'), t_get('vPX'), 1) $q$, 'IMMUTABLE');
SELECT t_check('T72c ZERO side effects: draft → approved → ordered wrote no movement, pool, cost or liability', t72_untouched());

-- D) receipt #1 from the PO: prefilled remaining, no cost, linked; operator changes quantities; manager prices differently; POST
SELECT t_login('u4');
SELECT t_set('gr1', rpc_po_create_receipt(t_get('po1'), CURRENT_DATE, 'IRS-1'));
SELECT t_logout();
SELECT t_check('T72d stock_staff created the draft receipt: linked, EUR @35 prefilled, 3 lines with remaining quantities and NO cost, still zero side effects',
  (SELECT purchase_order_id = t_get('po1') AND status = 'draft' AND invoice_currency = 'EUR' AND exchange_rate = 35 AND supplier_id = t_get('supPA') AND branch_id = t_get('brP') AND document_ref = 'IRS-1' FROM goods_receipts WHERE id = t_get('gr1'))
  AND (SELECT count(*) = 3 AND bool_and(unit_cost IS NULL) AND sum(quantity) = 25 FROM goods_receipt_items WHERE goods_receipt_id = t_get('gr1'))
  AND t72_untouched());
SELECT t_login('u2');
SELECT t_ok('T72d delivered S 6, M 4, Top 5; manager prices S 110 (≠ expected 100), M 100, Top 80', $q$
  SELECT rpc_goods_receipt_upsert_line(t_get('gr1'), t_get('vPDS'), 6, 110);
  SELECT rpc_goods_receipt_upsert_line(t_get('gr1'), t_get('vPDM'), 4, 100);
  SELECT rpc_goods_receipt_upsert_line(t_get('gr1'), t_get('vPT'), 5, 80);
  SELECT * FROM rpc_goods_receipt_review(t_get('gr1')) $q$);
SELECT t_check('T72d draft receipt does not count: PO still ordered, received 0', t72_status('po1') = 'ordered' AND t72_received('po1', 'vPDS') = 0 AND t72_untouched());
SELECT t_ok('T72d POST receipt #1', $q$ SELECT rpc_post_goods_receipt(t_get('gr1')) $q$);
SELECT t_check('T72d PO is PARTIALLY_RECEIVED: S 6/10, M 4/10, Top 5/5 → remaining S 4, M 6, Top 0; received 15 / remaining 10',
  t72_status('po1') = 'partially_received' AND t72_received('po1', 'vPDS') = 6 AND t72_received('po1', 'vPDM') = 4 AND t72_received('po1', 'vPT') = 5
  AND (SELECT (j -> 'totals' ->> 'received')::int = 15 AND (j -> 'totals' ->> 'remaining')::int = 10
          AND (SELECT (l ->> 'remaining')::int FROM jsonb_array_elements(j -> 'lines') l WHERE l ->> 'sku' = 'PD-S') = 4
          AND (SELECT (l ->> 'remaining')::int FROM jsonb_array_elements(j -> 'lines') l WHERE l ->> 'sku' = 'PT-STD') = 0
          AND jsonb_array_length(j -> 'receipts') = 1 AND (j -> 'receipts' -> 0 ->> 'status') = 'posted'
       FROM (SELECT rpc_po_detail(t_get('po1')) AS j) x), rpc_po_detail(t_get('po1'))::text);
SELECT t_check('T72d the receipt carried its own cost and FX: S landed 110 EUR × 35 = 3,850 TRY per unit in the pool; liability 1,460 EUR @35; PO expected cost untouched',
  (SELECT total_value_base = 6 * 110 * 35 AND on_hand_qty = 6 FROM variant_cost_pools WHERE business_id = t_get('bizP') AND variant_id = t_get('vPDS'))
  AND (SELECT amount_original = 6*110 + 4*100 + 5*80 AND currency = 'EUR' AND exchange_rate = 35 FROM supplier_account_entries WHERE reference_type = 'goods_receipt' AND reference_id = t_get('gr1'))
  AND t72_expected('po1', 'vPDS') = 100);
SELECT t_check('T72d PO reference for the receipt editor: expected vs remaining (manager sees expected cost)',
  (SELECT j ->> 'po_status' = 'partially_received' AND (SELECT (l ->> 'expected_unit_cost')::numeric = 100 AND (l ->> 'remaining')::int = 4 FROM jsonb_array_elements(j -> 'lines') l WHERE l ->> 'variant_id' = t_get('vPDS')::text)
   FROM (SELECT rpc_receipt_po_reference(t_get('gr1')) AS j) x));

-- E) over-receipt blocked at POST (nothing posted), draft #2 not counted, cancelled draft not counted, foreign variant blocked
SELECT t_set('gr2', rpc_po_create_receipt(t_get('po1')));
SELECT t_check('T72e receipt #2 prefilled with the remaining S 4, M 6 only (Top complete)',
  (SELECT n = 2 AND qty = 10 AND unpriced FROM t72_lines('gr2'))
  AND t72_status('po1') = 'partially_received');
SELECT t_ok('T72e operator claims S 5 (one too many), M 6, priced', $q$
  SELECT rpc_goods_receipt_upsert_line(t_get('gr2'), t_get('vPDS'), 5, 100);
  SELECT rpc_goods_receipt_upsert_line(t_get('gr2'), t_get('vPDM'), 6, 100);
  SELECT * FROM rpc_goods_receipt_review(t_get('gr2')) $q$);
SELECT t_logout();
CREATE TEMP TABLE _t72_mid AS SELECT (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizP')) AS movements, (SELECT count(*) FROM supplier_account_entries WHERE business_id = t_get('bizP')) AS liabilities;
GRANT SELECT ON _t72_mid TO authenticated;
SELECT t_login('u2');
SELECT t_err('T72e OVER_RECEIPT: S would reach 11 of 10', $q$ SELECT rpc_post_goods_receipt(t_get('gr2')) $q$, 'OVER_RECEIPT');
SELECT t_check('T72e the refused POST left nothing behind: receipt still draft, no movement, no liability, PO unchanged',
  (SELECT status = 'draft' FROM goods_receipts WHERE id = t_get('gr2')) AND t72_status('po1') = 'partially_received' AND t72_received('po1', 'vPDS') = 6
  AND (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizP')) = (SELECT movements FROM _t72_mid)
  AND (SELECT count(*) FROM supplier_account_entries WHERE business_id = t_get('bizP')) = (SELECT liabilities FROM _t72_mid));
SELECT t_ok('T72e a variant that is not on the PO is added to the linked receipt', $q$ SELECT rpc_goods_receipt_upsert_line(t_get('gr2'), t_get('vPDS'), 4, 100); SELECT rpc_goods_receipt_upsert_line(t_get('gr2'), t_get('vPX'), 1, 10); SELECT * FROM rpc_goods_receipt_review(t_get('gr2')) $q$);
SELECT t_err('T72e NOT_IN_PO blocks the POST', $q$ SELECT rpc_post_goods_receipt(t_get('gr2')) $q$, 'NOT_IN_PO');
SELECT t_err('T72e a partly received PO cannot be cancelled', $q$ SELECT rpc_po_cancel(t_get('po1'), 'vazgeçtik') $q$, 'INVALID_STATE');
SELECT t_err('T72e close is refused while a draft receipt is open against the PO', $q$ SELECT rpc_po_close(t_get('po1'), 'kalanı gelmeyecek') $q$, 'OPEN_RECEIPTS');
UPDATE goods_receipts SET status = 'cancelled' WHERE id = t_get('gr2');
SELECT t_check('T72e cancelled draft receipt is not counted', t72_status('po1') = 'partially_received' AND t72_received('po1', 'vPDS') = 6
  AND (SELECT (j -> 'receipts' -> 1 ->> 'status') = 'cancelled' AND (j ->> 'open_draft_receipts')::int = 0 FROM (SELECT rpc_po_detail(t_get('po1')) AS j) x));

-- F) receipt #3 receives the remainder at a different FX (36) → RECEIVED; close; immutable
SELECT t_set('gr3', rpc_po_create_receipt(t_get('po1'), CURRENT_DATE, 'IRS-3'));
UPDATE goods_receipts SET exchange_rate = 36 WHERE id = t_get('gr3');
SELECT t_ok('T72f remainder S 4 @100, M 6 @100 at 36 TRY/EUR', $q$
  SELECT rpc_goods_receipt_upsert_line(t_get('gr3'), t_get('vPDS'), 4, 100);
  SELECT rpc_goods_receipt_upsert_line(t_get('gr3'), t_get('vPDM'), 6, 100);
  SELECT * FROM rpc_goods_receipt_review(t_get('gr3'));
  SELECT rpc_post_goods_receipt(t_get('gr3')) $q$);
SELECT t_check('T72f PO RECEIVED: S 10/10, M 10/10, Top 5/5; receipt #3 liability 1,000 EUR @36; PO snapshot still 35',
  t72_status('po1') = 'received' AND t72_received('po1', 'vPDS') = 10 AND t72_received('po1', 'vPDM') = 10
  AND (SELECT amount_original = 1000 AND exchange_rate = 36 FROM supplier_account_entries WHERE reference_type = 'goods_receipt' AND reference_id = t_get('gr3'))
  AND (SELECT fx_rate_snapshot = 35 FROM purchase_orders WHERE id = t_get('po1'))
  AND (SELECT on_hand_qty = 10 AND total_value_base = 6*110*35 + 4*100*36 FROM variant_cost_pools WHERE business_id = t_get('bizP') AND variant_id = t_get('vPDS')));
SELECT t_err('T72f nothing remains → no further receipt', $q$ SELECT rpc_po_create_receipt(t_get('po1')) $q$, 'NOTHING_REMAINING');
SELECT t_ok('T72f close the received order', $q$ SELECT rpc_po_close(t_get('po1')) $q$);
SELECT t_check('T72f closed by the manager', (SELECT status = 'closed' AND closed_by = t_get('u2') FROM purchase_orders WHERE id = t_get('po1')));
SELECT t_err('T72f closed PO immutable via RPC', $q$ SELECT rpc_po_update(t_get('po1'), NULL, NULL, 'x') $q$, 'INVALID_STATE');
SELECT t_err('T72f closed PO cannot be cancelled', $q$ SELECT rpc_po_cancel(t_get('po1'), 'x') $q$, 'INVALID_STATE');
SELECT t_logout();
SELECT t_err('T72f closed PO immutable at the table', $q$ UPDATE purchase_orders SET note = 'x' WHERE id = t_get('po1') $q$, 'IMMUTABLE');
SELECT t_err('T72f PO never deleted', $q$ DELETE FROM purchase_orders WHERE id = t_get('po1') $q$, 'IMMUTABLE');

-- G) reversal + close remaining on a second PO (TRY, supplier B)
SELECT t_login('u2');
SELECT t_set('po2', rpc_po_create(t_get('brP'), t_get('supPB'), 'TRY'));
SELECT t_ok('T72g PO2: Top 8 @80, approved and ordered', $q$ SELECT rpc_po_upsert_line(t_get('po2'), t_get('vPT'), 8, 80); SELECT rpc_po_approve(t_get('po2')); SELECT rpc_po_mark_ordered(t_get('po2')) $q$);
SELECT t_set('gr4', rpc_po_create_receipt(t_get('po2')));
SELECT t_ok('T72g receipt #4: 3 of 8 posted', $q$ SELECT rpc_goods_receipt_upsert_line(t_get('gr4'), t_get('vPT'), 3, 80); SELECT * FROM rpc_goods_receipt_review(t_get('gr4')); SELECT rpc_post_goods_receipt(t_get('gr4')) $q$);
SELECT t_check('T72g PO2 partially received 3/8', t72_status('po2') = 'partially_received' AND t72_received('po2', 'vPT') = 3);
SELECT t_ok('T72g receipt #4 reversed', $q$ SELECT rpc_reverse_goods_receipt(t_get('gr4'), 'yanlış parti') $q$);
SELECT t_check('T72g reversal takes the units out: PO2 back to ordered, received 0, the receipt listed as reversed',
  t72_status('po2') = 'ordered' AND t72_received('po2', 'vPT') = 0
  AND (SELECT (j -> 'receipts' -> 0 ->> 'reversed')::boolean AND (j -> 'totals' ->> 'remaining')::int = 8 FROM (SELECT rpc_po_detail(t_get('po2')) AS j) x),
  t72_status('po2') || ' recv=' || t72_received('po2', 'vPT') || ' ' || rpc_po_detail(t_get('po2'))::text);
SELECT t_set('gr5', rpc_po_create_receipt(t_get('po2')));
SELECT t_check('T72g after the reversal the next receipt is prefilled with the full 8', (SELECT n = 1 AND qty = 8 FROM t72_lines('gr5')));
SELECT t_ok('T72g receipt #5: 5 of 8 posted', $q$ SELECT rpc_goods_receipt_upsert_line(t_get('gr5'), t_get('vPT'), 5, 80); SELECT * FROM rpc_goods_receipt_review(t_get('gr5')); SELECT rpc_post_goods_receipt(t_get('gr5')) $q$);
SELECT t_err('T72g close remaining needs a reason', $q$ SELECT rpc_po_close(t_get('po2')) $q$, 'REASON_REQUIRED');
SELECT t_ok('T72g close remaining', $q$ SELECT rpc_po_close(t_get('po2'), 'tedarikçi kalanı göndermeyecek') $q$);
SELECT t_check('T72g close remaining: CLOSED with 5 received, 3 abandoned, no movement fabricated',
  t72_status('po2') = 'closed'
  AND (SELECT (j -> 'totals' ->> 'received')::int = 5 AND (j -> 'totals' ->> 'remaining')::int = 3 AND (j -> 'timeline' -> 'closed' ->> 'reason') = 'tedarikçi kalanı göndermeyecek' FROM (SELECT rpc_po_detail(t_get('po2')) AS j) x));
SELECT t_check('T72g ledger rows for the top: gr1 +5, gr4 +3, reversal −3, gr5 +5 = 4 movements, on hand 10',
  (SELECT count(*) = 4 AND sum(quantity) = 10 FROM inventory_movements WHERE business_id = t_get('bizP') AND variant_id = t_get('vPT')));

-- H) cancel rules on a third PO
SELECT t_set('po3', rpc_po_create(t_get('brP'), t_get('supPB'), 'TRY'));
SELECT t_ok('T72h PO3 line + approve + order', $q$ SELECT rpc_po_upsert_line(t_get('po3'), t_get('vPX'), 2, 10); SELECT rpc_po_approve(t_get('po3')); SELECT rpc_po_mark_ordered(t_get('po3')) $q$);
SELECT t_set('gr6', rpc_po_create_receipt(t_get('po3')));
SELECT t_err('T72h cancel refused while a draft receipt is open', $q$ SELECT rpc_po_cancel(t_get('po3'), 'iptal') $q$, 'OPEN_RECEIPTS');
SELECT t_err('T72h cancel needs a reason', $q$ SELECT rpc_po_cancel(t_get('po_empty'), '') $q$, 'REASON_REQUIRED');
UPDATE goods_receipts SET status = 'cancelled' WHERE id = t_get('gr6');
SELECT t_ok('T72h ordered PO with no posted receipt cancels; draft PO cancels', $q$ SELECT rpc_po_cancel(t_get('po3'), 'tedarikçi iptal etti'); SELECT rpc_po_cancel(t_get('po_empty'), 'yanlış açıldı') $q$);
SELECT t_check('T72h both retained as cancelled',
  t72_status('po3') = 'cancelled' AND t72_status('po_empty') = 'cancelled'
  AND (SELECT count(*) FROM purchase_orders WHERE business_id = t_get('bizP') AND status = 'cancelled') = 2);
-- (PO4 below adds a third cancelled order)
SELECT t_err('T72h a receipt cannot be created against a cancelled PO', $q$ SELECT rpc_po_create_receipt(t_get('po3')) $q$, 'PO_NOT_OPEN');
SELECT t_set('po4', rpc_po_create(t_get('brP'), t_get('supPA'), 'EUR', 35));
SELECT t_ok('T72h PO4 (supplier A) ordered', $q$ SELECT rpc_po_upsert_line(t_get('po4'), t_get('vPX'), 1, 1); SELECT rpc_po_approve(t_get('po4')); SELECT rpc_po_mark_ordered(t_get('po4')) $q$);
SELECT t_set('gr7', rpc_create_goods_receipt(t_get('brP'), t_get('supPB'), 'TRY', 1, CURRENT_DATE, 'B-MANUAL', NULL));
SELECT t_set('gr8', rpc_create_goods_receipt(t_get('brP'), t_get('supPA'), 'EUR', 35, CURRENT_DATE, 'A-MANUAL', NULL));
SELECT t_err('T72h clients cannot set the link column directly (8A column grants)', $q$ UPDATE goods_receipts SET purchase_order_id = t_get('po4') WHERE id = t_get('gr8') $q$, 'permission denied');
SELECT t_logout();
SELECT t_err('T72h a receipt of another supplier cannot be linked to the PO', $q$ UPDATE goods_receipts SET purchase_order_id = t_get('po4') WHERE id = t_get('gr7') $q$, 'PO_SUPPLIER_MISMATCH');
SELECT t_err('T72h a draft receipt cannot be linked to a closed PO', $q$ UPDATE goods_receipts SET purchase_order_id = t_get('po1') WHERE id = t_get('gr8') $q$, 'PO_NOT_OPEN');
SELECT t_ok('T72h a draft receipt of the right supplier can be linked to an open PO', $q$ UPDATE goods_receipts SET purchase_order_id = t_get('po4') WHERE id = t_get('gr8') $q$);
SELECT t_err('T72h the link is never moved', $q$ UPDATE goods_receipts SET purchase_order_id = t_get('po2') WHERE id = t_get('gr8') $q$, 'IMMUTABLE');
UPDATE goods_receipts SET status = 'cancelled' WHERE id IN (t_get('gr7'), t_get('gr8'));
SELECT t_login('u2');
SELECT t_ok('T72h PO4 cancelled after its drafts are gone', $q$ SELECT rpc_po_cancel(t_get('po4'), 'gerek kalmadı') $q$);
SELECT t_check('T72h list: 5 orders, summary counts only open ones, financial for the manager',
  (SELECT jsonb_array_length(j -> 'rows') = 5 AND (j ->> 'financial')::boolean AND (j -> 'summary' ->> 'open')::int = 0
      AND (SELECT (r ->> 'expected_total')::numeric FROM jsonb_array_elements(j -> 'rows') r WHERE r ->> 'id' = t_get('po1')::text) = 2400
      AND (SELECT (r ->> 'received')::int FROM jsonb_array_elements(j -> 'rows') r WHERE r ->> 'id' = t_get('po2')::text) = 5
   FROM (SELECT rpc_po_list(t_get('bizP')) AS j) x), rpc_po_list(t_get('bizP'))::text);
SELECT t_logout();

-- I) roles + cross-tenant
SELECT t_login('u4');
SELECT t_check('T72i stock_staff: list and detail without any expected cost key',
  (SELECT NOT (j ->> 'financial')::boolean AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rows') r WHERE r ? 'expected_total') FROM (SELECT rpc_po_list(t_get('bizP')) AS j) x)
  AND (SELECT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'lines') l WHERE l ? 'expected_unit_cost' OR l ? 'expected_total') AND NOT ((j -> 'totals') ? 'expected_total')
       FROM (SELECT rpc_po_detail(t_get('po1')) AS j) x)
  AND (SELECT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'lines') l WHERE l ? 'expected_unit_cost') FROM (SELECT rpc_receipt_po_reference(t_get('gr1')) AS j) x));
SELECT t_err('T72i stock_staff cannot create', $q$ SELECT rpc_po_create(t_get('brP'), t_get('supPB'), 'TRY') $q$, 'FORBIDDEN');
SELECT t_err('T72i stock_staff cannot approve', $q$ SELECT rpc_po_approve(t_get('po1')) $q$, 'FORBIDDEN');
SELECT t_err('T72i stock_staff cannot add lines', $q$ SELECT rpc_po_upsert_line(t_get('po1'), t_get('vPX'), 1, 1) $q$, 'FORBIDDEN');
SELECT t_err('T72i stock_staff cannot close or cancel', $q$ SELECT rpc_po_close(t_get('po2'), 'x') $q$, 'FORBIDDEN');
SELECT t_err('T72i stock_staff cannot read the expected cost column', $q$ SELECT expected_unit_cost FROM purchase_order_items LIMIT 1 $q$, 'permission denied');
SELECT t_check('T72i stock_staff reads the operational columns through RLS', t_count($q$ SELECT count(*) FROM purchase_orders WHERE business_id = t_get('bizP') $q$) = 5);
SELECT t_logout();
SELECT t_login('u3');
SELECT t_err('T72i sales_staff: list FORBIDDEN', $q$ SELECT rpc_po_list(t_get('bizP')) $q$, 'FORBIDDEN');
SELECT t_err('T72i sales_staff: detail FORBIDDEN', $q$ SELECT rpc_po_detail(t_get('po1')) $q$, 'FORBIDDEN');
SELECT t_check('T72i sales_staff sees no PO rows', t_count($q$ SELECT count(*) FROM purchase_orders $q$) = 0 AND t_count($q$ SELECT count(*) FROM purchase_order_items $q$) = 0);
SELECT t_logout();
SELECT t_login('u5');
SELECT t_err('T72i other tenant: detail FORBIDDEN', $q$ SELECT rpc_po_detail(t_get('po1')) $q$, 'FORBIDDEN');
SELECT t_err('T72i other tenant: list FORBIDDEN', $q$ SELECT rpc_po_list(t_get('bizP')) $q$, 'FORBIDDEN');
SELECT t_err('T72i other tenant cannot create a receipt from it', $q$ SELECT rpc_po_create_receipt(t_get('po2')) $q$, 'FORBIDDEN');
SELECT t_check('T72i other tenant sees nothing through RLS', t_count($q$ SELECT count(*) FROM purchase_orders $q$) = 0);
SELECT t_logout();
WITH x AS (INSERT INTO goods_receipts (business_id, branch_id, supplier_id, receipt_number, status) VALUES (t_get('biz'), t_get('br1'), t_get('sup1'), 'GR-FORGE-72', 'draft') RETURNING id) SELECT t_set('gr_forge', id) FROM x;
SELECT t_err('T72i linkage cannot be forged across tenants', $q$ UPDATE goods_receipts SET purchase_order_id = t_get('po2') WHERE id = t_get('gr_forge') $q$, 'INVALID_PO');
SELECT t_err('T72i unauthenticated refused', $q$ SELECT rpc_po_list(t_get('bizP')) $q$, 'UNAUTHENTICATED');
SELECT t_check('T72i only receipt POSTs wrote to the ledger: movements 5 (gr1 3 lines, gr3 2, gr4 1, reversal 1, gr5 1 = 8), liabilities 4 (+1 credit)',
  (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizP')) = 8
  AND (SELECT count(*) FROM supplier_account_entries WHERE business_id = t_get('bizP') AND entry_type = 'liability') = 4
  AND (SELECT count(*) FROM supplier_account_entries WHERE business_id = t_get('bizP') AND entry_type = 'credit') = 1);

-- ============================================================
-- T73  SaaS platform foundation  (Phase 13A)
-- ============================================================
SELECT t_check('T73a saas tables have RLS and no write policies',
  (SELECT count(*) FROM pg_class WHERE relname IN ('saas_plans','business_applications','business_subscriptions') AND relrowsecurity) = 3
  AND (SELECT count(*) FROM pg_policies WHERE tablename IN ('saas_plans','business_applications','business_subscriptions') AND cmd <> 'SELECT') = 0);
SELECT t_check('T73a2 clients cannot write saas tables',
  NOT has_table_privilege('authenticated', 'saas_plans', 'INSERT') AND NOT has_table_privilege('authenticated', 'saas_plans', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'business_applications', 'INSERT') AND NOT has_table_privilege('authenticated', 'business_applications', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'business_subscriptions', 'INSERT') AND NOT has_table_privilege('authenticated', 'business_subscriptions', 'UPDATE')
  AND NOT has_table_privilege('anon', 'business_applications', 'SELECT') AND NOT has_table_privilege('anon', 'business_subscriptions', 'SELECT'));
SELECT t_check('T73a3 platform tables still have zero policies and the audit log gained the application target',
  (SELECT count(*) FROM pg_policies WHERE tablename IN ('platform_admins','platform_audit_log')) = 0
  AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'platform_audit_log' AND column_name = 'target_application_id'));
SELECT t_check('T73a4 businesses still has no client INSERT policy and no pending status',
  (SELECT count(*) FROM pg_policies WHERE tablename = 'businesses' AND cmd = 'INSERT') = 0
  AND (SELECT count(*) FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'business_status') = 3);
SELECT t_check('T73a5 the plan catalog is data: one active plan with a price, callable by anon',
  (SELECT count(*) FROM saas_plans WHERE is_active) = 1
  AND has_function_privilege('anon', 'rpc_saas_plans()', 'EXECUTE')
  AND (SELECT (rpc_saas_plans() -> 0 ->> 'price_amount')::numeric > 0));

-- the platform admin of T41 was retired at the end of that block; bring them back
UPDATE platform_admins SET is_active = true WHERE user_id = t_get('u8');
-- applicants: a9 (unconfirmed at first), a10, a11
SELECT t_set('a9',  'aaaaaaaa-0000-4000-8000-000000000021');
SELECT t_set('a10', 'aaaaaaaa-0000-4000-8000-000000000022');
SELECT t_set('a11', 'aaaaaaaa-0000-4000-8000-000000000023');
INSERT INTO auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_user_meta_data) VALUES
  (t_get('a9'),  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'applicant-a@boutiqueos.test', NULL, '{"full_name":"Aylin Kaya"}'),
  (t_get('a10'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'applicant-b@boutiqueos.test', now(), '{}'),
  (t_get('a11'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'applicant-c@boutiqueos.test', now(), '{}')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES (t_get('a9')), (t_get('a10')), (t_get('a11')) ON CONFLICT DO NOTHING;
CREATE FUNCTION t73_app(p_user TEXT) RETURNS UUID LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT id FROM business_applications WHERE applicant_user_id = t_get(p_user) ORDER BY (status = 'pending') DESC, submitted_at DESC, id DESC LIMIT 1 $$;
CREATE FUNCTION t73_biz(p_user TEXT) RETURNS UUID LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT business_id FROM business_applications WHERE applicant_user_id = t_get(p_user) AND status = 'approved' LIMIT 1 $$;
-- evaluate a boolean from the superuser's side while a tenant/platform session is active
CREATE FUNCTION t73_q(p_sql TEXT) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE b BOOLEAN; BEGIN EXECUTE 'SELECT (' || p_sql || ')' INTO b; RETURN COALESCE(b, false); END $$;
CREATE FUNCTION t73_sub(p_user TEXT) RETURNS UUID LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT id FROM business_subscriptions WHERE business_id = t73_biz(p_user) ORDER BY created_at DESC LIMIT 1 $$;
CREATE FUNCTION t73_app_in(p_user TEXT, p_status TEXT) RETURNS UUID LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT id FROM business_applications WHERE applicant_user_id = t_get(p_user) AND status::text = p_status ORDER BY submitted_at DESC LIMIT 1 $$;
CREATE TEMP TABLE _t73 AS SELECT (SELECT count(*) FROM businesses) AS biz, (SELECT count(*) FROM platform_audit_log) AS audit;
GRANT SELECT ON _t73 TO authenticated;

-- ---------------- submission ----------------
SELECT t_err('T73b unauthenticated cannot apply', $q$ SELECT rpc_submit_business_application('ZZ Aylin Butik') $q$, 'UNAUTHENTICATED');
SELECT t_login('a9');
SELECT t_err('T73b2 an unconfirmed address cannot apply', $q$ SELECT rpc_submit_business_application('ZZ Aylin Butik') $q$, 'EMAIL_NOT_CONFIRMED');
SELECT t_logout();
UPDATE auth.users SET email_confirmed_at = now() WHERE id = t_get('a9');
SELECT t_login('a9');
SELECT t_err('T73b3 the business name is required', $q$ SELECT rpc_submit_business_application(' ') $q$, 'INVALID_NAME');
SELECT t_err('T73b4 the currency is validated', $q$ SELECT rpc_submit_business_application('ZZ Aylin Butik', 'TR', 'XXX') $q$, 'INVALID_CURRENCY');
SELECT t_err('T73b5 the plan must be offered', $q$ SELECT rpc_submit_business_application('ZZ Aylin Butik', 'TR', 'TRY', NULL, NULL, NULL, gen_random_uuid()) $q$, 'INVALID_PLAN');
SELECT t_ok('T73c a confirmed applicant submits',
  $q$ SELECT rpc_submit_business_application('ZZ Aylin Butik', 'TR', 'TRY', '+90 555 000 0001', 'butik', 'Merkez', (SELECT id FROM saas_plans WHERE code = 'starter'), 'Aylin Kaya') $q$);
SELECT t_check('T73c2 the application is pending and the registrant name landed on the profile',
  (SELECT status = 'pending' AND country = 'TR' AND currency = 'TRY' AND plan_id IS NOT NULL FROM business_applications WHERE id = t73_app('a9'))
  AND (SELECT full_name = 'Aylin Kaya' FROM profiles WHERE id = t_get('a9')));
SELECT t_check('T73c3 a second submission replays the first (no duplicate)',
  (SELECT (r ->> 'replayed')::boolean AND (r ->> 'application_id')::uuid = t73_app('a9') FROM rpc_submit_business_application('ZZ Baska Isim') r)
  AND (SELECT count(*) FROM business_applications WHERE applicant_user_id = t_get('a9')) = 1);
SELECT t_check('T73c4 the applicant reads own status only, without internals',
  (SELECT r ->> 'status' = 'pending' AND r ->> 'business_name' = 'ZZ Aylin Butik' AND r -> 'plan' ->> 'code' = 'starter' AND r ->> 'business_active' IS NULL FROM rpc_my_business_application() r)
  AND (SELECT count(*) FROM business_applications) = 1);
SELECT t_err('T73c5 the applicant cannot approve their own application', $q$ SELECT rpc_platform_approve_application(t73_app('a9')) $q$, 'FORBIDDEN');
SELECT t_err('T73c6 the applicant cannot read the platform queue', $q$ SELECT rpc_platform_applications() $q$, 'FORBIDDEN');
SELECT t_err('T73c7 the applicant cannot insert a business', $q$ INSERT INTO businesses (name, code) VALUES ('X', 'XXX') $q$, '42501');
SELECT t_err('T73c8 the applicant cannot assign themselves to a tenant', $q$ INSERT INTO business_members (business_id, user_id, role) VALUES (t_get('biz'), t_get('a9'), 'owner') $q$, '42501');
SELECT t_check('T73c9 no business exists for the applicant before approval', (SELECT count(*) FROM business_members WHERE user_id = t_get('a9')) = 0);
SELECT t_logout();

-- ---------------- who may approve ----------------
SELECT t_login('u1');
SELECT t_err('T73d a tenant owner cannot approve', $q$ SELECT rpc_platform_approve_application(t73_app('a9')) $q$, 'FORBIDDEN');
SELECT t_err('T73d2 a tenant owner cannot reject', $q$ SELECT rpc_platform_reject_application(t73_app('a9'), 'no') $q$, 'FORBIDDEN');
SELECT t_check('T73d3 a tenant owner sees no application of others', (SELECT count(*) FROM business_applications) = 0);
SELECT t_check('T73d4 whoami says not a platform admin', (SELECT NOT (rpc_platform_whoami() ->> 'platform_admin')::boolean));
SELECT t_logout();

-- ---------------- atomic activation ----------------
UPDATE auth.users SET email_confirmed_at = NULL WHERE id = t_get('a9');
SELECT t_login('u8');
SELECT t_err('T73e approval refuses an applicant whose address became unconfirmed', $q$ SELECT rpc_platform_approve_application(t73_app('a9')) $q$, 'EMAIL_NOT_CONFIRMED');
SELECT t_logout();
UPDATE auth.users SET email_confirmed_at = now() WHERE id = t_get('a9');
SELECT t_login('u8');
SELECT t_check('T73e2 whoami says platform admin with one pending application',
  (SELECT (r ->> 'platform_admin')::boolean AND (r ->> 'pending_applications')::int = 1 FROM rpc_platform_whoami() r));
SELECT t_ok('T73e3 the platform admin approves', $q$ SELECT rpc_platform_approve_application(t73_app('a9'), 'pilot onayi') $q$);
SELECT t_logout();
SELECT t_check('T73e4 exactly one business was created, active, with a readable unique code',
  (SELECT count(*) FROM businesses) = (SELECT biz + 1 FROM _t73)
  AND (SELECT status = 'active' AND code = 'ZZAYLINB' AND name = 'ZZ Aylin Butik' AND base_currency = 'TRY' AND phone = '+90 555 000 0001' FROM businesses WHERE id = t73_biz('a9')));
SELECT t_check('T73e5 the registrant is the first and only owner',
  (SELECT count(*) FROM business_members WHERE business_id = t73_biz('a9')) = 1
  AND (SELECT role = 'owner' AND is_active FROM business_members WHERE business_id = t73_biz('a9') AND user_id = t_get('a9')));
SELECT t_check('T73e6 the initial branch Merkez is the default',
  (SELECT count(*) FROM branches WHERE business_id = t73_biz('a9')) = 1
  AND (SELECT name = 'Merkez' AND is_default AND status = 'active' FROM branches WHERE business_id = t73_biz('a9')));
SELECT t_check('T73e7 default settings carry every key the RPCs read',
  (SELECT settings ? 'accepted_currencies' AND settings ? 'money_refund_allowed' AND settings ? 'store_credit_allowed' AND settings ? 'exchange_window_days'
          AND settings ->> 'sales_visibility_scope' = 'own' AND settings ->> 'timezone' = 'Europe/Istanbul' AND settings -> 'accepted_currencies' @> '["TRY"]'
   FROM businesses WHERE id = t73_biz('a9')));
SELECT t_check('T73e8 a pending subscription on the chosen plan, no dates, no provider',
  (SELECT count(*) FROM business_subscriptions WHERE business_id = t73_biz('a9')) = 1
  AND (SELECT status = 'pending' AND starts_at IS NULL AND activated_at IS NULL AND external_provider IS NULL AND source = 'platform_manual'
       FROM business_subscriptions WHERE business_id = t73_biz('a9')));
SELECT t_check('T73e9 the application is approved, reviewed, linked; the audit log has the approval',
  (SELECT status = 'approved' AND reviewed_by = t_get('u8') AND reviewed_at IS NOT NULL AND review_note = 'pilot onayi' AND business_id IS NOT NULL FROM business_applications WHERE id = t73_app('a9'))
  AND (SELECT count(*) FROM platform_audit_log WHERE action = 'approve_application' AND target_application_id = t73_app('a9') AND target_business_id = t73_biz('a9')) = 1);
SELECT t_login('u8');
SELECT t_check('T73f approving again replays the same business (idempotent)',
  (SELECT (r ->> 'replayed')::boolean AND (r ->> 'business_id')::uuid = t73_biz('a9') FROM rpc_platform_approve_application(t73_app('a9')) r)
  AND t73_q($q$ (SELECT count(*) FROM businesses) = (SELECT biz + 1 FROM _t73) $q$)
  AND t73_q($q$ (SELECT count(*) FROM business_members WHERE user_id = t_get('a9')) = 1 $q$)
  AND t73_q($q$ (SELECT count(*) FROM platform_audit_log WHERE action = 'approve_application') = 1 $q$));
SELECT t_err('T73f2 an approved application cannot be rejected', $q$ SELECT rpc_platform_reject_application(t73_app('a9'), 'gec kaldi') $q$, 'INVALID_STATE');
SELECT t_err('T73f3 unknown application', $q$ SELECT rpc_platform_approve_application(gen_random_uuid()) $q$, 'NOT_FOUND');
SELECT t_check('T73f4 the platform queue lists the application with the applicant and plan',
  (SELECT (r ->> 'total')::int = 1 AND (r ->> 'pending')::int = 0 AND r -> 'rows' -> 0 -> 'applicant' ->> 'email' = 'applicant-a@boutiqueos.test'
          AND r -> 'rows' -> 0 -> 'plan' ->> 'code' = 'starter' FROM rpc_platform_applications() r));
SELECT t_check('T73f5 the detail view carries business, subscription and reviewer',
  (SELECT r -> 'business' ->> 'code' = 'ZZAYLINB' AND r -> 'subscription' ->> 'status' = 'pending' AND r -> 'applicant' ->> 'name' = 'Aylin Kaya' AND (r -> 'applicant' ->> 'other_memberships')::int = 0
   FROM rpc_platform_application_detail(t73_app('a9')) r));
SELECT t_check('T73f6 the business directory finds it by code with owners=1 and the subscription',
  (SELECT (r ->> 'total')::int = 1 AND (r -> 'rows' -> 0 ->> 'owners')::int = 1 AND (r -> 'rows' -> 0 ->> 'branches')::int = 1 AND r -> 'rows' -> 0 -> 'subscription' ->> 'plan' = 'starter'
   FROM rpc_platform_businesses(NULL, 'ZZAYLINB') r));
SELECT t_check('T73f7 the business detail shows the owner, timezone and the audit trail',
  (SELECT r -> 'owners' -> 0 ->> 'email' = 'applicant-a@boutiqueos.test' AND r ->> 'timezone' = 'Europe/Istanbul' AND jsonb_array_length(r -> 'audit') = 1 AND r -> 'application' ->> 'status' = 'approved'
   FROM rpc_platform_business_detail(t73_biz('a9')) r));
SELECT t_logout();

-- ---------------- the new owner lives in a normal tenant ----------------
SELECT t_login('a9');
SELECT t_check('T73g the registrant sees exactly one active membership as owner',
  (SELECT count(*) FROM business_members WHERE user_id = t_get('a9') AND is_active) = 1
  AND fn_is_business_active(t73_biz('a9')));
SELECT t_check('T73g2 the applicant page now says approved and active',
  (SELECT r ->> 'status' = 'approved' AND (r ->> 'business_active')::boolean FROM rpc_my_business_application() r));
SELECT t_ok('T73g3 the owner can use a tenant RPC right away (timezone)', $q$ SELECT rpc_business_set_timezone(t73_biz('a9'), 'Asia/Nicosia') $q$);
SELECT t_check('T73g4 the owner reads own subscription, nobody else''s',
  (SELECT count(*) FROM business_subscriptions) = 1);
SELECT t_err('T73g5 the owner cannot change platform status', $q$ UPDATE businesses SET status = 'suspended' WHERE id = t73_biz('a9') $q$, 'PLATFORM_MANAGED_FIELD');
SELECT t_err('T73g6 the owner cannot touch the subscription', $q$ UPDATE business_subscriptions SET status = 'active' WHERE business_id = t73_biz('a9') $q$, '42501');
SELECT t_err('T73g7 the owner cannot activate the subscription through the platform RPC', $q$ SELECT rpc_platform_set_subscription_status(t73_sub('a9'), 'active') $q$, 'FORBIDDEN');
-- the 3.5B guard is a deferred constraint trigger: it speaks at commit / SET CONSTRAINTS IMMEDIATE
SELECT t_err_deferred('T73g8 last-owner protection holds for the first owner', $q$ UPDATE business_members SET is_active = false WHERE business_id = t73_biz('a9') AND user_id = t_get('a9') $q$, 'LAST_OWNER');
SELECT t_err('T73g9 the owner cannot see the platform tables', $q$ SELECT count(*) FROM platform_audit_log $q$, '42501');
SELECT t_err('T73g10 an approved application cannot be withdrawn', $q$ SELECT rpc_withdraw_business_application(t73_app('a9')) $q$, 'INVALID_STATE');
SELECT t_logout();
SELECT t_login('u1');
SELECT t_check('T73g11 the TLC owner sees nothing of the new tenant',
  (SELECT count(*) FROM business_subscriptions) = 0 AND (SELECT count(*) FROM business_applications) = 0
  AND (SELECT count(*) FROM branches WHERE business_id = t73_biz('a9')) = 0);
SELECT t_logout();

-- ---------------- subscription lifecycle (manual, platform only) ----------------
SELECT t_login('u8');
SELECT t_err('T73h the status is validated', $q$ SELECT rpc_platform_set_subscription_status(t73_sub('a9'), 'paid') $q$, 'INVALID_STATUS');
SELECT t_err('T73h2 manual activation without a paid invoice is refused (13B: payment activates)',
  $q$ SELECT rpc_platform_set_subscription_status(t73_sub('a9'), 'active', 'havale alindi') $q$, 'USE_PAYMENT');
SELECT t_ok('T73h2b the platform issues the first invoice and records the full bank transfer',
  $q$ SELECT rpc_platform_record_payment((rpc_platform_issue_invoice(t73_sub('a9')) ->> 'invoice_id')::uuid, (SELECT price_amount FROM saas_plans WHERE code = 'starter'), 'USD', 'bank_transfer', 'HAVALE-T73', now(), 'havale alindi') $q$);
SELECT t_check('T73h3 the paid invoice activates the subscription for one calendar year',
  t73_q($q$ SELECT status = 'active' AND starts_at IS NOT NULL AND activated_at IS NOT NULL AND ends_at = starts_at + interval '1 year' AND renews_at = ends_at
   FROM business_subscriptions WHERE business_id = t73_biz('a9') $q$));
SELECT t_ok('T73h4 past_due keeps the dates', $q$ SELECT rpc_platform_set_subscription_status(t73_sub('a9'), 'past_due') $q$);
SELECT t_ok('T73h5 cancellation', $q$ SELECT rpc_platform_set_subscription_status(t73_sub('a9'), 'cancelled', 'istek') $q$);
SELECT t_err('T73h6 a cancelled subscription is final', $q$ SELECT rpc_platform_set_subscription_status(t73_sub('a9'), 'active') $q$, 'INVALID_STATE');
SELECT t_check('T73h7 every subscription change is audited (payment activation + two manual moves)',
  t73_q($q$ (SELECT count(*) FROM platform_audit_log WHERE action = 'set_subscription_status' AND target_business_id = t73_biz('a9')) = 2
            AND (SELECT count(*) FROM platform_audit_log WHERE action = 'record_payment' AND target_business_id = t73_biz('a9')) = 1 $q$));
SELECT t_check('T73h8 the business itself stayed active: subscription state never touches tenant status',
  t73_q($q$ SELECT status = 'active' FROM businesses WHERE id = t73_biz('a9') $q$));
-- plans are data
SELECT t_ok('T73i the platform adds a plan', $q$ SELECT rpc_platform_upsert_plan('pro_monthly', 'Pro Aylik', NULL, 'monthly', 9, 'USD', true, 20) $q$);
SELECT t_ok('T73i2 and edits it by code', $q$ SELECT rpc_platform_upsert_plan('pro_monthly', 'Pro Aylik', 'iki sube', 'monthly', 12, 'USD', false, 20) $q$);
SELECT t_check('T73i3 the inactive plan is hidden from the public catalog but listed to the platform',
  t73_q($q$ (SELECT count(*) FROM saas_plans) = 2 $q$) AND jsonb_array_length(rpc_saas_plans()) = 1 AND jsonb_array_length(rpc_platform_plans()) = 2);
SELECT t_logout();
SELECT t_login('u1');
SELECT t_err('T73i4 a tenant owner cannot edit plans', $q$ SELECT rpc_platform_upsert_plan('starter', 'X', NULL, 'annual', 1, 'USD') $q$, 'FORBIDDEN');
SELECT t_err('T73i5 nor list them with counts', $q$ SELECT rpc_platform_plans() $q$, 'FORBIDDEN');
SELECT t_check('T73i6 anon-visible plan rows are only the active ones', (SELECT count(*) FROM saas_plans) = 1);
SELECT t_logout();

-- ---------------- rejection, withdrawal, history, code collisions ----------------
SELECT t_login('a10');
SELECT t_ok('T73j applicant B submits with the same business name', $q$ SELECT rpc_submit_business_application('ZZ Aylin Butik', 'CY', 'EUR') $q$);
SELECT t_ok('T73j2 applicant B withdraws', $q$ SELECT rpc_withdraw_business_application(t73_app('a10')) $q$);
SELECT t_check('T73j3 the withdrawn application is kept and the status page says withdrawn',
  (SELECT status = 'withdrawn' FROM business_applications WHERE id = t73_app('a10'))
  AND (SELECT r ->> 'status' = 'withdrawn' FROM rpc_my_business_application() r));
SELECT t_ok('T73j4 applicant B submits again (new row, history preserved)', $q$ SELECT rpc_submit_business_application('ZZ Aylin Butik', 'CY', 'EUR') $q$);
SELECT t_check('T73j5 two rows for B, one pending', (SELECT count(*) FROM business_applications WHERE applicant_user_id = t_get('a10')) = 2
  AND (SELECT count(*) FROM business_applications WHERE applicant_user_id = t_get('a10') AND status = 'pending') = 1);
SELECT t_logout();
SELECT t_login('u8');
SELECT t_err('T73j6 approving the withdrawn row is refused',
  $q$ SELECT rpc_platform_approve_application(t73_app_in('a10', 'withdrawn')) $q$, 'INVALID_STATE');
SELECT t_ok('T73j7 the platform approves the pending one', $q$ SELECT rpc_platform_approve_application(t73_app_in('a10', 'pending')) $q$);
SELECT t_check('T73j8 the colliding name gets a numbered code and country defaults (Cyprus, EUR)',
  t73_q($q$ SELECT code = 'ZZAYLIN2' AND base_currency = 'EUR' AND settings ->> 'timezone' = 'Asia/Nicosia' AND settings -> 'accepted_currencies' @> '["EUR"]' FROM businesses WHERE id = t73_biz('a10') $q$));
SELECT t_check('T73j9 B is the only owner of the second tenant and A is untouched',
  t73_q($q$ (SELECT count(*) FROM business_members WHERE business_id = t73_biz('a10')) = 1 AND (SELECT count(*) FROM business_members WHERE business_id = t73_biz('a9')) = 1 $q$));
SELECT t_logout();
SELECT t_login('a11');
SELECT t_ok('T73k applicant C submits', $q$ SELECT rpc_submit_business_application('ZZ Red Test', 'TR', 'TRY') $q$);
SELECT t_logout();
SELECT t_login('u8');
SELECT t_err('T73k2 rejection without a note', $q$ SELECT rpc_platform_reject_application(t73_app('a11'), ' ') $q$, 'REASON_REQUIRED');
SELECT t_ok('T73k3 rejection with a note', $q$ SELECT rpc_platform_reject_application(t73_app('a11'), 'eksik bilgi') $q$);
SELECT t_check('T73k4 rejection creates no business, no membership, and is audited',
  t73_q($q$ (SELECT status = 'rejected' AND business_id IS NULL AND review_note = 'eksik bilgi' FROM business_applications WHERE id = t73_app('a11'))
  AND (SELECT count(*) FROM business_members WHERE user_id = t_get('a11')) = 0
  AND (SELECT count(*) FROM platform_audit_log WHERE action = 'reject_application' AND target_application_id = t73_app('a11')) = 1 $q$));
SELECT t_check('T73k5 the queue filters by status and paginates',
  (SELECT (r ->> 'total')::int = 1 FROM rpc_platform_applications('rejected') r)
  AND (SELECT (r ->> 'total')::int = 4 AND jsonb_array_length(r -> 'rows') = 2 AND (r ->> 'limit')::int = 2 FROM rpc_platform_applications(NULL, 2, 0) r));
SELECT t_logout();
SELECT t_login('a11');
SELECT t_check('T73k6 the rejected applicant sees the note and may apply again',
  (SELECT r ->> 'status' = 'rejected' AND r ->> 'review_note' = 'eksik bilgi' FROM rpc_my_business_application() r)
  AND (SELECT NOT (r ->> 'replayed')::boolean FROM rpc_submit_business_application('ZZ Red Test 2') r));
SELECT t_check('T73k7 an applicant without any membership has no inactive business to show', jsonb_array_length(rpc_my_inactive_businesses()) = 0);
SELECT t_check('T73k8 the onboarding summary bundles application + inactive businesses + platform flag',
  (SELECT NOT (r ->> 'platform_admin')::boolean AND r -> 'application' ->> 'status' = 'pending' AND jsonb_array_length(r -> 'inactive_businesses') = 0 FROM rpc_my_onboarding() r));
SELECT t_logout();

-- ---------------- suspension keeps working through the 3.5G path ----------------
SELECT t_login('u8');
SELECT t_ok('T73l the platform suspends the new tenant with the existing audited RPC', $q$ SELECT rpc_platform_set_business_status(t73_biz('a9'), 'suspended', 'odeme yok') $q$);
SELECT t_logout();
SELECT t_login('a9');
SELECT t_check('T73l2 the suspended owner gets a safe status list (name + status only)',
  (SELECT r -> 0 ->> 'name' = 'ZZ Aylin Butik' AND r -> 0 ->> 'status' = 'suspended' AND jsonb_array_length(r) = 1 FROM rpc_my_inactive_businesses() r));
SELECT t_err('T73l3 and cannot use the tenant', $q$ SELECT rpc_business_set_timezone(t73_biz('a9'), 'UTC') $q$, 'BUSINESS_SUSPENDED');
SELECT t_logout();
SELECT t_check('T73m TLC was not touched by any of this',
  (SELECT status = 'active' FROM businesses WHERE id = t_get('biz'))
  AND (SELECT count(*) FROM business_subscriptions WHERE business_id = t_get('biz')) = 0
  AND (SELECT count(*) FROM business_applications WHERE business_id = t_get('biz')) = 0);

-- ============================================================
-- T74  SaaS billing foundation — manual billing only  (Phase 13B)
-- ============================================================
SELECT t_check('T74a billing tables exist with RLS on and zero policies (reads and writes only through RPCs)',
  (SELECT count(*) FROM pg_class WHERE relname IN ('saas_invoices','saas_invoice_items','saas_payments','saas_invoice_sequences','platform_settings') AND relrowsecurity) = 5
  AND (SELECT count(*) FROM pg_policies WHERE tablename IN ('saas_invoices','saas_invoice_items','saas_payments','saas_invoice_sequences','platform_settings')) = 0);
SELECT t_check('T74a2 tenants and anon hold no privilege on the billing ledger',
  NOT has_table_privilege('authenticated', 'saas_invoices', 'SELECT') AND NOT has_table_privilege('authenticated', 'saas_invoices', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'saas_invoice_items', 'SELECT') AND NOT has_table_privilege('authenticated', 'saas_payments', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'saas_payments', 'INSERT') AND NOT has_table_privilege('authenticated', 'platform_settings', 'SELECT')
  AND NOT has_table_privilege('anon', 'saas_invoices', 'SELECT') AND NOT has_table_privilege('anon', 'saas_payments', 'SELECT'));
SELECT t_check('T74a3 the billing ledger is separate from POS money (no FK into sale_payments / cash / supplier tables)',
  (SELECT count(*) FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid JOIN pg_class f ON f.oid = c.confrelid
   WHERE c.contype = 'f' AND r.relname IN ('saas_invoices','saas_invoice_items','saas_payments')
     AND f.relname NOT IN ('businesses','business_subscriptions','saas_plans','profiles','saas_invoices')) = 0);
SELECT t_check('T74a4 provider columns exist, are nullable and are constrained to NULL in 13B',
  (SELECT count(*) FROM information_schema.columns WHERE table_name = 'saas_payments' AND column_name IN ('provider','provider_reference') AND is_nullable = 'YES') = 2
  AND (SELECT count(*) FROM information_schema.columns WHERE table_name = 'saas_invoices' AND column_name IN ('provider','provider_invoice_id') AND is_nullable = 'YES') = 2
  AND (SELECT count(*) FROM pg_constraint WHERE conname IN ('chk_saas_pay_no_provider','chk_saas_inv_no_provider')) = 2);
SELECT t_check('T74a5 payment methods are the three manual ones; no card method exists',
  (SELECT array_agg(enumlabel::text ORDER BY enumsortorder) FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'saas_payment_method') = ARRAY['bank_transfer','cash_manual','other_manual']);
SELECT t_check('T74a6 billing settings are data', (SELECT count(*) FROM platform_settings WHERE key IN ('invoice_due_days','billing_grace_days')) = 2);

-- fixtures: a10 owns ZZAYLIN2 (active, EUR/CY) with a PENDING subscription on the USD starter plan; a11 becomes its manager
CREATE FUNCTION t74_inv(p_user TEXT, p_status TEXT DEFAULT NULL) RETURNS UUID LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT id FROM saas_invoices WHERE subscription_id = t73_sub(p_user) AND (p_status IS NULL OR status::text = p_status) ORDER BY invoice_number DESC LIMIT 1 $$;
CREATE FUNCTION t74_no(p_user TEXT, p_status TEXT DEFAULT NULL) RETURNS TEXT LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT invoice_number FROM saas_invoices WHERE id = t74_inv(p_user, p_status) $$;
CREATE FUNCTION t74_total(p_user TEXT, p_status TEXT DEFAULT NULL) RETURNS NUMERIC LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT total FROM saas_invoices WHERE id = t74_inv(p_user, p_status) $$;
CREATE FUNCTION t73_q_num(p_sql TEXT) RETURNS NUMERIC LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE n NUMERIC; BEGIN EXECUTE p_sql INTO n; RETURN n; END $$;
CREATE FUNCTION t74_price() RETURNS NUMERIC LANGUAGE sql SECURITY DEFINER STABLE AS $$ SELECT price_amount FROM saas_plans WHERE code = 'starter' $$;
INSERT INTO business_members (business_id, user_id, role, is_active) VALUES (t73_biz('a10'), t_get('a11'), 'manager', true);
CREATE TEMP TABLE _t74 AS SELECT (SELECT count(*) FROM saas_invoices) AS inv, (SELECT count(*) FROM saas_payments) AS pay, (SELECT count(*) FROM platform_audit_log) AS audit,
  (SELECT extract(year FROM now())::int) AS yr;
GRANT SELECT ON _t74 TO authenticated;

-- ---------------- who reads what ----------------
SELECT t_login('a10');
SELECT t_check('T74b the owner reads own billing: pending subscription, no invoice, grace setting',
  (SELECT r -> 'subscription' ->> 'status' = 'pending' AND r -> 'subscription' -> 'plan' ->> 'code' = 'starter' AND jsonb_array_length(r -> 'invoices') = 0
          AND (r -> 'settings' ->> 'billing_grace_days')::int >= 0 FROM rpc_my_billing(t73_biz('a10')) r));
SELECT t_err('T74b2 the owner cannot read another business''s billing (TLC)', $q$ SELECT rpc_my_billing(t_get('biz')) $q$, 'FORBIDDEN');
SELECT t_err('T74b3 nor a business they are not a member of', $q$ SELECT rpc_my_billing(t73_biz('a9')) $q$, 'FORBIDDEN');
SELECT t_err('T74b4 the owner cannot issue an invoice', $q$ SELECT rpc_platform_issue_invoice(t73_sub('a10')) $q$, 'FORBIDDEN');
SELECT t_err('T74b5 the owner cannot record a payment', $q$ SELECT rpc_platform_record_payment(gen_random_uuid(), 1, 'USD', 'bank_transfer', 'X1') $q$, 'FORBIDDEN');
SELECT t_err('T74b6 the owner cannot activate own subscription', $q$ SELECT rpc_platform_set_subscription_status(t73_sub('a10'), 'active') $q$, 'FORBIDDEN');
SELECT t_err('T74b7 the owner cannot list platform invoices', $q$ SELECT rpc_platform_invoices() $q$, 'FORBIDDEN');
SELECT t_err('T74b8 the owner cannot read the billing overview', $q$ SELECT rpc_platform_billing_overview() $q$, 'FORBIDDEN');
SELECT t_err('T74b9 the owner cannot write the ledger directly', $q$ INSERT INTO saas_payments (business_id, subscription_id, invoice_id, amount, currency, method, reference, paid_at, recorded_by) VALUES (t73_biz('a10'), t73_sub('a10'), gen_random_uuid(), 1, 'USD', 'bank_transfer', 'X', now(), t_get('a10')) $q$, '42501');
SELECT t_err('T74b10 nor read it', $q$ SELECT count(*) FROM saas_invoices $q$, '42501');
SELECT t_err('T74b11 nor change billing settings', $q$ SELECT rpc_platform_set_billing_setting('invoice_due_days', 1) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('a11');
SELECT t_err('T74b12 a manager has no SaaS billing surface', $q$ SELECT rpc_my_billing(t73_biz('a10')) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u1');
SELECT t_err('T74b13 the TLC owner cannot read the ZZ tenant''s billing', $q$ SELECT rpc_my_billing(t73_biz('a10')) $q$, 'FORBIDDEN');
SELECT t_check('T74b14 TLC has no subscription and rpc_my_billing says so without inventing one',
  (SELECT r -> 'subscription' IS NULL OR r ->> 'subscription' IS NULL FROM rpc_my_billing(t_get('biz')) r) AND (SELECT count(*) FROM business_subscriptions WHERE business_id = t_get('biz')) = 0);
SELECT t_logout();

-- ---------------- issue the first invoice (snapshot) ----------------
SELECT t_login('u8');
SELECT t_check('T74c the overview counts the pending subscription as awaiting its first invoice',
  (SELECT (r ->> 'awaiting_first_invoice')::int = 1 AND (r -> 'settings' ->> 'invoice_due_days')::int = 14 FROM rpc_platform_billing_overview() r));
SELECT t_ok('T74c2 the platform issues the first invoice', $q$ SELECT rpc_platform_issue_invoice(t73_sub('a10'), 'ilk donem') $q$);
SELECT t_check('T74c3 the invoice is a snapshot of the plan: number, price, plan currency (not the business currency), interval, period, due, tax policy',
  t73_q($q$ SELECT i.invoice_number = 'BOS-' || (SELECT yr FROM _t74)::text || '-' || lpad(((SELECT inv FROM _t74) + 1)::text, 6, '0')
                   AND i.status = 'open' AND i.plan_code = 'starter' AND i.currency = 'USD' AND i.subtotal = t74_price() AND i.tax_amount = 0 AND i.tax_policy = 'none_unconfigured'
                   AND i.total = t74_price() AND i.amount_paid = 0 AND i.billing_interval = 'annual'
                   AND i.billing_period_end = i.billing_period_start + interval '1 year' AND i.due_at = i.issued_at + interval '14 days'
                   AND i.business_id = t73_biz('a10') AND i.note = 'ilk donem'
            FROM saas_invoices i WHERE i.id = t74_inv('a10') $q$));
SELECT t_check('T74c4 one item line carries the plan price; the audit trail has the issue',
  t73_q($q$ (SELECT count(*) = 1 AND min(line_total) = t74_price() AND min(quantity) = 1 FROM saas_invoice_items WHERE invoice_id = t74_inv('a10'))
            AND (SELECT count(*) FROM platform_audit_log WHERE action = 'issue_invoice' AND target_business_id = t73_biz('a10')) = 1 $q$));
SELECT t_check('T74c5 issuing again replays the open invoice (exactly one invoice per period)',
  (SELECT (r ->> 'replayed')::boolean AND (r ->> 'invoice_id')::uuid = t74_inv('a10') FROM rpc_platform_issue_invoice(t73_sub('a10')) r)
  AND t73_q($q$ (SELECT count(*) FROM saas_invoices WHERE subscription_id = t73_sub('a10')) = 1 $q$));
SELECT t_check('T74c6 the subscription is still pending: issuing an invoice activates nothing',
  t73_q($q$ SELECT status = 'pending' AND starts_at IS NULL FROM business_subscriptions WHERE id = t73_sub('a10') $q$));
SELECT t_check('T74c7 the invoice detail carries items, empty payments, the subscription and the business',
  (SELECT r ->> 'status' = 'open' AND jsonb_array_length(r -> 'items') = 1 AND jsonb_array_length(r -> 'payments') = 0 AND r -> 'business' ->> 'code' = 'ZZAYLIN2'
          AND r -> 'subscription' ->> 'status' = 'pending' AND NOT (r ->> 'overdue')::boolean FROM rpc_platform_invoice_detail(t74_inv('a10')) r));
SELECT t_logout();
SELECT t_login('a10');
SELECT t_check('T74c8 the owner sees the open invoice with its amounts and no platform internals',
  (SELECT jsonb_array_length(r -> 'invoices') = 1 AND r -> 'invoices' -> 0 ->> 'status' = 'open' AND (r -> 'invoices' -> 0 ->> 'total')::numeric = t74_price()
          AND (r -> 'invoices' -> 0 ->> 'balance')::numeric = t74_price() AND NOT (r -> 'invoices' -> 0 ->> 'overdue')::boolean
          AND r -> 'invoices' -> 0 ? 'invoice_number' AND NOT (r -> 'invoices' -> 0 ? 'issued_by') AND NOT (r -> 'invoices' -> 0 ? 'provider')
   FROM rpc_my_billing(t73_biz('a10')) r));
SELECT t_logout();

-- ---------------- payment validation ----------------
SELECT t_login('u8');
SELECT t_err('T74d a card method does not exist', $q$ SELECT rpc_platform_record_payment(t74_inv('a10'), t74_price(), 'USD', 'card', 'REF-1') $q$, 'INVALID_METHOD');
SELECT t_err('T74d2 the currency must match the invoice', $q$ SELECT rpc_platform_record_payment(t74_inv('a10'), t74_price(), 'EUR', 'bank_transfer', 'REF-1') $q$, 'CURRENCY_MISMATCH');
SELECT t_err('T74d3 zero is not a payment', $q$ SELECT rpc_platform_record_payment(t74_inv('a10'), 0, 'USD', 'bank_transfer', 'REF-1') $q$, 'INVALID_AMOUNT');
SELECT t_err('T74d4 sub-cent amounts are refused', $q$ SELECT rpc_platform_record_payment(t74_inv('a10'), 10.001, 'USD', 'bank_transfer', 'REF-1') $q$, 'INVALID_AMOUNT');
SELECT t_err('T74d5 a reference is required', $q$ SELECT rpc_platform_record_payment(t74_inv('a10'), 10, 'USD', 'bank_transfer', ' ') $q$, 'REFERENCE_REQUIRED');
SELECT t_err('T74d6 overpayment is refused (no credit balance)', $q$ SELECT rpc_platform_record_payment(t74_inv('a10'), t74_price() + 0.01, 'USD', 'bank_transfer', 'REF-1') $q$, 'OVERPAYMENT');
SELECT t_err('T74d7 a payment cannot be dated in the future', $q$ SELECT rpc_platform_record_payment(t74_inv('a10'), 10, 'USD', 'bank_transfer', 'REF-1', now() + interval '3 days') $q$, 'INVALID_DATE');
SELECT t_err('T74d8 an unknown invoice', $q$ SELECT rpc_platform_record_payment(gen_random_uuid(), 10, 'USD', 'bank_transfer', 'REF-1') $q$, 'NOT_FOUND');

-- ---------------- partial payment, idempotent reference, full payment activates ----------------
SELECT t_check('T74e a partial bank transfer is recorded; the invoice stays open; nothing activates',
  (SELECT r ->> 'invoice_status' = 'open' AND (r ->> 'amount_paid')::numeric = t74_price() - 10 AND (r ->> 'balance')::numeric = 10 AND NOT (r ->> 'subscription_activated')::boolean AND NOT (r ->> 'replayed')::boolean
   FROM rpc_platform_record_payment(t74_inv('a10'), t74_price() - 10, 'USD', 'bank_transfer', 'HAVALE-001', now() - interval '1 hour', 'kismi') r)
  AND t73_q($q$ SELECT status = 'pending' FROM business_subscriptions WHERE id = t73_sub('a10') $q$));
SELECT t_check('T74e2 the same reference recorded again is one payment (two admins, one bank line)',
  (SELECT (r ->> 'replayed')::boolean FROM rpc_platform_record_payment(t74_inv('a10'), t74_price() - 10, 'USD', 'bank_transfer', ' havale-001 ') r)
  AND t73_q($q$ (SELECT count(*) FROM saas_payments WHERE invoice_id = t74_inv('a10')) = 1 AND (SELECT amount_paid = t74_price() - 10 FROM saas_invoices WHERE id = t74_inv('a10')) $q$));
SELECT t_err('T74e3 the remaining balance cannot be exceeded', $q$ SELECT rpc_platform_record_payment(t74_inv('a10'), 10.01, 'USD', 'bank_transfer', 'HAVALE-002') $q$, 'OVERPAYMENT');
SELECT t_err('T74e4 a partially paid invoice cannot be voided', $q$ SELECT rpc_platform_void_invoice(t74_inv('a10'), 'yanlis') $q$, 'HAS_PAYMENTS');
SELECT t_check('T74e5 the closing cash payment settles the invoice and activates the subscription in one transaction',
  (SELECT r ->> 'invoice_status' = 'paid' AND (r ->> 'balance')::numeric = 0 AND (r ->> 'subscription_activated')::boolean
   FROM rpc_platform_record_payment(t74_inv('a10'), 10, 'USD', 'cash_manual', 'MAKBUZ-7', now(), 'nakit') r));
SELECT t_check('T74e6 invoice paid with paid_at; subscription active for exactly the invoiced period (calendar year), renews at period end',
  t73_q($q$ (SELECT status = 'paid' AND paid_at IS NOT NULL AND amount_paid = total FROM saas_invoices WHERE id = t74_inv('a10'))
            AND (SELECT s.status = 'active' AND s.starts_at = i.billing_period_start AND s.ends_at = i.billing_period_end AND s.renews_at = i.billing_period_end
                        AND s.ends_at = s.starts_at + interval '1 year' AND s.activated_at IS NOT NULL
                 FROM business_subscriptions s JOIN saas_invoices i ON i.id = t74_inv('a10') WHERE s.id = t73_sub('a10')) $q$));
SELECT t_check('T74e7 two payments, both audited, the last one marked invoice_paid; the business status never moved',
  t73_q($q$ (SELECT count(*) FROM saas_payments WHERE invoice_id = t74_inv('a10')) = 2
            AND (SELECT count(*) FROM platform_audit_log WHERE action = 'record_payment' AND target_business_id = t73_biz('a10')) = 2
            AND (SELECT count(*) FROM platform_audit_log WHERE action = 'record_payment' AND target_business_id = t73_biz('a10') AND (payload ->> 'invoice_paid')::boolean AND payload ->> 'to' = 'active') = 1
            AND (SELECT status = 'active' FROM businesses WHERE id = t73_biz('a10')) $q$));
SELECT t_err('T74e8 a paid invoice takes no further payment', $q$ SELECT rpc_platform_record_payment(t74_inv('a10'), 1, 'USD', 'bank_transfer', 'HAVALE-003') $q$, 'INVALID_STATE');
SELECT t_check('T74e9 the exact same reference on the paid invoice still replays instead of erroring (retry after timeout)',
  (SELECT (r ->> 'replayed')::boolean FROM rpc_platform_record_payment(t74_inv('a10'), 10, 'USD', 'cash_manual', 'MAKBUZ-7') r));
SELECT t_logout();

-- ---------------- immutability (even for the superuser) ----------------
SELECT t_err('T74f a paid invoice is immutable', $q$ UPDATE saas_invoices SET note = 'x' WHERE id = t74_inv('a10') $q$, 'INVOICE_IMMUTABLE');
SELECT t_err('T74f2 an issued invoice is never deleted', $q$ DELETE FROM saas_invoices WHERE id = t74_inv('a10') $q$, 'INVOICE_RETAINED');
SELECT t_err('T74f3 payments are frozen', $q$ UPDATE saas_payments SET amount = 1 WHERE invoice_id = t74_inv('a10') $q$, 'BILLING_ROW_FROZEN');
SELECT t_err('T74f4 payments are never deleted', $q$ DELETE FROM saas_payments WHERE invoice_id = t74_inv('a10') $q$, 'BILLING_ROW_FROZEN');
SELECT t_err('T74f5 items are frozen', $q$ DELETE FROM saas_invoice_items WHERE invoice_id = t74_inv('a10') $q$, 'BILLING_ROW_FROZEN');
SELECT t_err('T74f6 no provider reference can be written on a payment', $q$ INSERT INTO saas_payments (business_id, subscription_id, invoice_id, amount, currency, method, reference, paid_at, recorded_by, provider, provider_reference) VALUES (t73_biz('a10'), t73_sub('a10'), t74_inv('a10'), 1, 'USD', 'other_manual', 'PROV', now(), t_get('u8'), 'stripe', 'pi_1') $q$, 'chk_saas_pay_no_provider');

-- ---------------- renewal, plan price change, void ----------------
SELECT t_login('u8');
SELECT t_check('T74g the renewal invoice starts where the paid period ends and gets the next number',
  (SELECT NOT (r ->> 'replayed')::boolean FROM rpc_platform_issue_invoice(t73_sub('a10')) r)
  AND t73_q($q$ SELECT n.billing_period_start = p.billing_period_end AND n.billing_period_end = n.billing_period_start + interval '1 year' AND n.status = 'open'
                       AND n.invoice_number = 'BOS-' || (SELECT yr FROM _t74)::text || '-' || lpad(((SELECT inv FROM _t74) + 2)::text, 6, '0')
                FROM saas_invoices n, saas_invoices p WHERE n.id = t74_inv('a10', 'open') AND p.id = t74_inv('a10', 'paid') $q$));
SELECT t_check('T74g2 a second renewal request replays the open one (no duplicate renewal)',
  (SELECT (r ->> 'replayed')::boolean FROM rpc_platform_issue_invoice(t73_sub('a10')) r)
  AND t73_q($q$ (SELECT count(*) FROM saas_invoices WHERE subscription_id = t73_sub('a10') AND status = 'open') = 1 $q$));
SELECT t_ok('T74g3 the catalogue price changes', $q$ SELECT rpc_platform_upsert_plan('starter', 'BoutiqueOS Starter', NULL, 'annual', t74_price() + 10, 'USD', true, 10) $q$);
SELECT t_check('T74g4 neither the paid nor the open invoice moved (snapshots)',
  t73_q($q$ (SELECT count(*) FROM saas_invoices WHERE subscription_id = t73_sub('a10') AND subtotal = t74_price() - 10) = 2 $q$));
SELECT t_err('T74g5 voiding needs a reason', $q$ SELECT rpc_platform_void_invoice(t74_inv('a10', 'open'), ' ') $q$, 'REASON_REQUIRED');
SELECT t_check('T74g6 the open renewal is voided with actor and reason, kept as history, audited',
  (SELECT r ->> 'status' = 'void' AND NOT (r ->> 'replayed')::boolean FROM rpc_platform_void_invoice(t74_inv('a10', 'open'), 'fiyat degisti') r)
  AND t73_q($q$ (SELECT status = 'void' AND voided_by = t_get('u8') AND void_reason = 'fiyat degisti' AND voided_at IS NOT NULL FROM saas_invoices WHERE id = t74_inv('a10', 'void'))
                AND (SELECT count(*) FROM platform_audit_log WHERE action = 'void_invoice' AND target_business_id = t73_biz('a10')) = 1 $q$));
SELECT t_check('T74g7 voiding again replays', (SELECT (r ->> 'replayed')::boolean FROM rpc_platform_void_invoice(t74_inv('a10', 'void'), 'tekrar') r));
SELECT t_err('T74g8 a void invoice is immutable too', $q$ SELECT rpc_platform_record_payment(t74_inv('a10', 'void'), 1, 'USD', 'bank_transfer', 'X9') $q$, 'INVALID_STATE');
SELECT t_check('T74g9 the re-issued renewal covers the same period at the NEW catalogue price and a new number',
  (SELECT NOT (r ->> 'replayed')::boolean FROM rpc_platform_issue_invoice(t73_sub('a10')) r)
  AND t73_q($q$ SELECT n.billing_period_start = v.billing_period_start AND n.subtotal = t74_price() AND n.invoice_number > v.invoice_number AND n.status = 'open'
                FROM saas_invoices n, saas_invoices v WHERE n.id = t74_inv('a10', 'open') AND v.id = t74_inv('a10', 'void') $q$));
SELECT t_ok('T74g10 the catalogue price goes back', $q$ SELECT rpc_platform_upsert_plan('starter', 'BoutiqueOS Starter', NULL, 'annual', t74_price() - 10, 'USD', true, 10) $q$);
SELECT t_check('T74g11 the paid invoice and its item still carry the price they were issued at',
  t73_q($q$ (SELECT subtotal = t74_price() FROM saas_invoices WHERE id = t74_inv('a10', 'paid')) AND (SELECT unit_amount = t74_price() FROM saas_invoice_items WHERE invoice_id = t74_inv('a10', 'paid')) $q$));

-- ---------------- overdue is derived; the sweep materialises past_due; payment re-activates ----------------
SELECT t_check('T74h before the due date nothing is overdue',
  (SELECT (r ->> 'total')::int = 0 FROM rpc_platform_invoices('overdue') r) AND (SELECT (r -> 'invoices' ->> 'overdue')::int = 0 FROM rpc_platform_billing_overview() r));
SELECT t_logout();
-- test fixture only: push the open renewal past its due date (the guard forbids this on the code path)
ALTER TABLE saas_invoices DISABLE TRIGGER trg_saas_invoice_guard;
UPDATE saas_invoices SET due_at = now() - interval '3 days' WHERE id = t74_inv('a10', 'open');
ALTER TABLE saas_invoices ENABLE TRIGGER trg_saas_invoice_guard;
SELECT t_login('u8');
SELECT t_check('T74h2 overdue is derived from due_at, without any job',
  (SELECT (r ->> 'total')::int = 1 AND (r -> 'rows' -> 0 ->> 'overdue')::boolean AND (r -> 'rows' -> 0 ->> 'days_overdue')::int >= 3 FROM rpc_platform_invoices('overdue') r)
  AND t73_q($q$ SELECT status = 'active' FROM business_subscriptions WHERE id = t73_sub('a10') $q$));
SELECT t_check('T74h3 the sweep marks the subscription past_due (audited) and does nothing to the business',
  (SELECT (r ->> 'marked_past_due')::int = 1 AND (r ->> 'cancelled_at_period_end')::int = 0 FROM rpc_platform_billing_sweep() r)
  AND t73_q($q$ (SELECT status = 'past_due' AND ends_at IS NOT NULL FROM business_subscriptions WHERE id = t73_sub('a10'))
                AND (SELECT status = 'active' FROM businesses WHERE id = t73_biz('a10'))
                AND (SELECT count(*) FROM platform_audit_log WHERE action = 'billing_sweep' AND target_business_id = t73_biz('a10')) = 1 $q$));
SELECT t_check('T74h4 a second sweep changes nothing', (SELECT (r ->> 'marked_past_due')::int = 0 FROM rpc_platform_billing_sweep() r));
SELECT t_logout();
SELECT t_login('a10');
SELECT t_check('T74h5 the owner sees the overdue renewal, its grace end and the past_due subscription; the tenant still works',
  (SELECT (r -> 'invoices' -> 0 ->> 'overdue')::boolean AND r -> 'invoices' -> 0 ? 'grace_ends_at' AND r -> 'subscription' ->> 'status' = 'past_due' FROM rpc_my_billing(t73_biz('a10')) r)
  AND fn_is_business_active(t73_biz('a10')));
SELECT t_logout();
SELECT t_login('u8');
SELECT t_check('T74h6 paying the renewal in full re-activates the subscription and moves ends_at to the renewal period end',
  (SELECT (r ->> 'subscription_activated')::boolean FROM rpc_platform_record_payment(t74_inv('a10', 'open'), t74_total('a10', 'open'), 'USD', 'bank_transfer', 'HAVALE-RENEW') r)
  AND t73_q($q$ SELECT s.status = 'active' AND s.ends_at = i.billing_period_end AND s.starts_at < i.billing_period_start
                FROM business_subscriptions s JOIN saas_invoices i ON i.id = t74_inv('a10', 'paid') WHERE s.id = t73_sub('a10') $q$));
SELECT t_check('T74h7 two paid invoices, one void, no open; numbers strictly increase in issue order',
  t73_q($q$ (SELECT count(*) FILTER (WHERE status = 'paid') = 2 AND count(*) FILTER (WHERE status = 'void') = 1 AND count(*) FILTER (WHERE status = 'open') = 0 FROM saas_invoices WHERE subscription_id = t73_sub('a10'))
            AND (SELECT count(*) FROM (SELECT invoice_number, lag(invoice_number) OVER (ORDER BY issued_at, created_at) prev FROM saas_invoices) x WHERE prev IS NOT NULL AND invoice_number <= prev) = 0 $q$));

-- ---------------- cancellation ----------------
SELECT t_err('T74i cancellation needs a reason', $q$ SELECT rpc_platform_cancel_subscription(t73_sub('a10'), 'at_period_end', '') $q$, 'REASON_REQUIRED');
SELECT t_err('T74i2 the mode is validated', $q$ SELECT rpc_platform_cancel_subscription(t73_sub('a10'), 'later', 'istek') $q$, 'INVALID_MODE');
SELECT t_check('T74i3 cancel at period end keeps the paid period, clears the renewal date and blocks renewals',
  (SELECT (r ->> 'cancel_at_period_end')::boolean AND r ->> 'status' = 'active' FROM rpc_platform_cancel_subscription(t73_sub('a10'), 'at_period_end', 'musteri istegi') r)
  AND t73_q($q$ SELECT status = 'active' AND cancel_at_period_end AND renews_at IS NULL AND ends_at IS NOT NULL FROM business_subscriptions WHERE id = t73_sub('a10') $q$));
SELECT t_err('T74i4 no renewal is issued for a scheduled cancellation', $q$ SELECT rpc_platform_issue_invoice(t73_sub('a10')) $q$, 'CANCEL_SCHEDULED');
SELECT t_check('T74i5 the scheduled cancellation is withdrawn ("keep") and the renewal date returns',
  (SELECT NOT (r ->> 'cancel_at_period_end')::boolean FROM rpc_platform_cancel_subscription(t73_sub('a10'), 'keep', 'vazgecti') r)
  AND t73_q($q$ SELECT NOT cancel_at_period_end AND renews_at = ends_at FROM business_subscriptions WHERE id = t73_sub('a10') $q$));
SELECT t_ok('T74i6 a renewal can be issued again', $q$ SELECT rpc_platform_issue_invoice(t73_sub('a10')) $q$);
SELECT t_err('T74i7 immediate cancellation is refused while an invoice is open', $q$ SELECT rpc_platform_cancel_subscription(t73_sub('a10'), 'immediate', 'kapat') $q$, 'OPEN_INVOICE');
SELECT t_err('T74i8 the manual status path refuses it for the same reason', $q$ SELECT rpc_platform_set_subscription_status(t73_sub('a10'), 'cancelled') $q$, 'OPEN_INVOICE');
SELECT t_ok('T74i9 the open renewal is voided', $q$ SELECT rpc_platform_void_invoice(t74_inv('a10', 'open'), 'iptal edildi') $q$);
-- period-end materialisation: schedule the cancellation, then let the period end (fixture backdate on the subscription)
SELECT t_ok('T74i10 schedule again', $q$ SELECT rpc_platform_cancel_subscription(t73_sub('a10'), 'at_period_end', 'donem sonu') $q$);
SELECT t_logout();
UPDATE business_subscriptions SET ends_at = now() - interval '1 minute' WHERE id = t73_sub('a10');
SELECT t_login('u8');
SELECT t_check('T74i11 the sweep cancels the subscription when its period has ended (audited); the business stays active',
  (SELECT (r ->> 'cancelled_at_period_end')::int = 1 FROM rpc_platform_billing_sweep() r)
  AND t73_q($q$ (SELECT status = 'cancelled' AND cancelled_at IS NOT NULL FROM business_subscriptions WHERE id = t73_sub('a10')) AND (SELECT status = 'active' FROM businesses WHERE id = t73_biz('a10')) $q$));
SELECT t_err('T74i12 a cancelled subscription takes no invoice', $q$ SELECT rpc_platform_issue_invoice(t73_sub('a10')) $q$, 'INVALID_STATE');
SELECT t_err('T74i13 nor a cancellation', $q$ SELECT rpc_platform_cancel_subscription(t73_sub('a10'), 'immediate', 'kapat') $q$, 'INVALID_STATE');
SELECT t_logout();

-- ---------------- immediate cancellation on a fresh tenant + settings ----------------
SELECT t_set('a12', 'aaaaaaaa-0000-4000-8000-000000000024');
INSERT INTO auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_user_meta_data) VALUES
  (t_get('a12'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'applicant-d@boutiqueos.test', now(), '{}') ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES (t_get('a12')) ON CONFLICT DO NOTHING;
SELECT t_login('a12');
SELECT t_ok('T74j applicant D applies', $q$ SELECT rpc_submit_business_application('ZZ Billing Test', 'TR', 'TRY') $q$);
SELECT t_logout();
SELECT t_login('u8');
SELECT t_ok('T74j2 approved', $q$ SELECT rpc_platform_approve_application(t73_app('a12')) $q$);
SELECT t_err('T74j3 settings keys are an allow-list', $q$ SELECT rpc_platform_set_billing_setting('vat_rate', 20) $q$, 'INVALID_SETTING');
SELECT t_err('T74j4 settings values are bounded', $q$ SELECT rpc_platform_set_billing_setting('invoice_due_days', 400) $q$, 'INVALID_VALUE');
SELECT t_ok('T74j5 the due window becomes 30 days (audited)', $q$ SELECT rpc_platform_set_billing_setting('invoice_due_days', 30) $q$);
SELECT t_check('T74j6 the new invoice is due in 30 days and the pending subscription is untouched',
  (SELECT NOT (r ->> 'replayed')::boolean FROM rpc_platform_issue_invoice(t73_sub('a12')) r)
  AND t73_q($q$ (SELECT due_at = issued_at + interval '30 days' AND currency = 'USD' FROM saas_invoices WHERE id = t74_inv('a12'))
                AND (SELECT status = 'pending' FROM business_subscriptions WHERE id = t73_sub('a12'))
                AND (SELECT count(*) FROM platform_audit_log WHERE action = 'set_billing_setting') = 1 $q$));
SELECT t_ok('T74j7 back to 14 days', $q$ SELECT rpc_platform_set_billing_setting('invoice_due_days', 14) $q$);
SELECT t_err('T74j8 immediate cancellation waits for the open invoice', $q$ SELECT rpc_platform_cancel_subscription(t73_sub('a12'), 'immediate', 'vazgecti') $q$, 'OPEN_INVOICE');
SELECT t_ok('T74j9 void it', $q$ SELECT rpc_platform_void_invoice(t74_inv('a12'), 'vazgecti') $q$);
SELECT t_check('T74j10 immediate cancellation ends the subscription now, audited with the mode',
  (SELECT r ->> 'status' = 'cancelled' FROM rpc_platform_cancel_subscription(t73_sub('a12'), 'immediate', 'vazgecti') r)
  AND t73_q($q$ (SELECT status = 'cancelled' AND cancelled_at IS NOT NULL AND NOT cancel_at_period_end FROM business_subscriptions WHERE id = t73_sub('a12'))
                AND (SELECT payload ->> 'mode' = 'immediate' FROM platform_audit_log WHERE action = 'cancel_subscription' AND target_business_id = t73_biz('a12') ORDER BY occurred_at DESC LIMIT 1) $q$));

-- ---------------- lists, pagination, overview ----------------
SELECT t_check('T74k the invoice list filters by status and searches by number / business code, paginated',
  (SELECT (r ->> 'total')::int = 6 FROM rpc_platform_invoices() r)              -- T73: 1 paid · a10: 2 paid + 2 void · a12: 1 void
  AND (SELECT (r ->> 'total')::int = 3 FROM rpc_platform_invoices('paid') r)
  AND (SELECT (r ->> 'total')::int = 3 FROM rpc_platform_invoices('void') r)
  AND (SELECT (r ->> 'total')::int = 0 FROM rpc_platform_invoices('open') r)
  AND (SELECT (r ->> 'total')::int = 4 FROM rpc_platform_invoices(NULL, 'ZZAYLIN2') r)
  AND (SELECT (r ->> 'total')::int = 6 AND jsonb_array_length(r -> 'rows') = 2 AND (r ->> 'limit')::int = 2 AND (r ->> 'offset')::int = 2 FROM rpc_platform_invoices(NULL, NULL, 2, 2) r)
  AND (SELECT (r ->> 'total')::int = 1 AND r -> 'rows' -> 0 ->> 'status' = 'paid' FROM rpc_platform_invoices(NULL, t74_no('a10', 'paid')) r));
SELECT t_err('T74k2 the status filter is validated', $q$ SELECT rpc_platform_invoices('draft') $q$, 'INVALID_STATUS');
SELECT t_check('T74k3 the subscription list carries business, plan, period, latest invoice and counts',
  (SELECT (r ->> 'total')::int >= 3 FROM rpc_platform_subscriptions() r)
  AND (SELECT (r ->> 'total')::int = 1 AND r -> 'rows' -> 0 -> 'business' ->> 'code' = 'ZZAYLIN2' AND (r -> 'rows' -> 0 ->> 'invoice_count')::int = 2
              AND r -> 'rows' -> 0 -> 'latest_invoice' ->> 'status' = 'paid' AND r -> 'rows' -> 0 -> 'plan' ->> 'code' = 'starter'
       FROM rpc_platform_subscriptions('cancelled', 'ZZAYLIN2') r));
SELECT t_check('T74k4 the business detail shows each subscription''s latest invoice and count',
  (SELECT (r -> 'subscriptions' -> 0 ->> 'invoice_count')::int = 2 AND r -> 'subscriptions' -> 0 -> 'latest_invoice' ->> 'status' = 'paid' AND (r -> 'subscriptions' -> 0 ->> 'cancel_at_period_end')::boolean
   FROM rpc_platform_business_detail(t73_biz('a10')) r));
SELECT t_check('T74k5 the overview aggregates by currency and never counts TLC',
  (SELECT (r -> 'invoices' ->> 'paid_30d')::int = 3 AND (r -> 'invoices' ->> 'open')::int = 0 AND (r -> 'paid_30d_totals' ->> 'USD')::numeric = t73_q_num($q$ SELECT sum(amount) FROM saas_payments $q$)
          AND (r -> 'subscriptions' ->> 'cancelled')::int >= 2 AND (r ->> 'awaiting_first_invoice')::int = 0
   FROM rpc_platform_billing_overview() r));
SELECT t_logout();

-- ---------------- money, TLC, isolation ----------------
SELECT t_check('T74l amounts are exact decimals (money2), totals add up, no float',
  (SELECT count(*) FROM saas_invoices WHERE total <> subtotal + tax_amount OR scale(total) > 2 OR scale(amount_paid) > 2) = 0
  AND (SELECT count(*) FROM saas_payments WHERE scale(amount) > 2) = 0
  AND (SELECT sum(amount) FROM saas_payments WHERE invoice_id = t74_inv('a10', 'paid')) = (SELECT amount_paid FROM saas_invoices WHERE id = t74_inv('a10', 'paid')));
SELECT t_check('T74l2 TLC has no invoice, payment or subscription and its status/settings did not move',
  (SELECT count(*) FROM saas_invoices WHERE business_id = t_get('biz')) = 0 AND (SELECT count(*) FROM saas_payments WHERE business_id = t_get('biz')) = 0
  AND (SELECT count(*) FROM business_subscriptions WHERE business_id = t_get('biz')) = 0 AND (SELECT status = 'active' FROM businesses WHERE id = t_get('biz')));
SELECT t_check('T74l3 the POS money tables were not touched by any billing action',
  (SELECT count(*) FROM sale_payments WHERE business_id = t73_biz('a10')) = 0 AND (SELECT count(*) FROM cash_movements WHERE business_id = t73_biz('a10')) = 0);
SELECT t_login('a10');
SELECT t_check('T74l4 the owner of a cancelled subscription still reads own history (2 paid, 2 void), payments listed without actors',
  (SELECT jsonb_array_length(r -> 'invoices') = 4 AND r -> 'subscription' ->> 'status' = 'cancelled'
          AND (SELECT count(*) FROM jsonb_array_elements(r -> 'invoices') i WHERE i ->> 'status' = 'paid') = 2
          AND (SELECT bool_and(NOT (p ? 'recorded_by')) FROM jsonb_array_elements(r -> 'invoices') i, jsonb_array_elements(i -> 'payments') p)
   FROM rpc_my_billing(t73_biz('a10')) r));
SELECT t_err('T74l5 the owner cannot read applicant D''s billing', $q$ SELECT rpc_my_billing(t73_biz('a12')) $q$, 'FORBIDDEN');
SELECT t_err('T74l6 nor void an invoice', $q$ SELECT rpc_platform_void_invoice(t74_inv('a10', 'paid'), 'x') $q$, 'FORBIDDEN');
SELECT t_err('T74l7 nor cancel own subscription through the platform RPC', $q$ SELECT rpc_platform_cancel_subscription(t73_sub('a10'), 'immediate', 'x') $q$, 'FORBIDDEN');
SELECT t_err('T74l8 nor run the sweep', $q$ SELECT rpc_platform_billing_sweep() $q$, 'FORBIDDEN');
SELECT t_logout();

-- ============================================================
-- T75  E-commerce catalog + storefront foundation  (Phase 14A)
-- ============================================================
SELECT t_check('T75a storefront tables have RLS; storefront_domains has no policy; anon holds no table privilege',
  (SELECT count(*) FROM pg_class WHERE relname IN ('storefronts','storefront_domains') AND relrowsecurity) = 2
  AND (SELECT count(*) FROM pg_policies WHERE tablename = 'storefront_domains') = 0
  AND NOT has_table_privilege('anon', 'storefronts', 'SELECT') AND NOT has_table_privilege('anon', 'storefront_domains', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'storefronts', 'INSERT') AND NOT has_table_privilege('authenticated', 'storefronts', 'UPDATE'));
SELECT t_check('T75a2 the public RPCs are the only anon surface',
  has_function_privilege('anon', 'rpc_shop_resolve(text)', 'EXECUTE') AND has_function_privilege('anon', 'rpc_shop_home(text, integer)', 'EXECUTE')
  AND has_function_privilege('anon', 'rpc_shop_products(text, text, text, text, integer, integer)', 'EXECUTE') AND has_function_privilege('anon', 'rpc_shop_product(text, text)', 'EXECUTE')
  AND has_function_privilege('anon', 'rpc_shop_availability(text, uuid[])', 'EXECUTE') AND has_function_privilege('anon', 'rpc_shop_resolve_host(text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_storefront_upsert(uuid, jsonb)', 'EXECUTE') AND NOT has_function_privilege('anon', 'rpc_storefront_publish_product(uuid, uuid, boolean)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_storefront_admin(uuid, text, integer, integer)', 'EXECUTE') AND NOT has_function_privilege('anon', 'fn_shop_available(uuid, uuid, uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_onboard_product(uuid, jsonb, jsonb)', 'EXECUTE') AND NOT has_function_privilege('anon', 'rpc_goods_receipt_financial(uuid)', 'EXECUTE'));
SELECT t_check('T75a3 the public bucket exists and only public roles may carry a public path',
  (SELECT public FROM storage.buckets WHERE id = 'storefront-images') AND NOT (SELECT public FROM storage.buckets WHERE id = 'product-images')
  AND (SELECT count(*) FROM pg_constraint WHERE conname IN ('chk_product_images_public_role','chk_product_images_public_path')) = 2);

-- fixtures: applicant D's business (ZZ Billing Test, active) becomes the storefront tenant; a12 is its owner
SELECT t_set('bizS', t73_biz('a12'));
SELECT t_set('brS', (SELECT id FROM branches WHERE business_id = t_get('bizS') AND is_default LIMIT 1));
WITH x AS (INSERT INTO product_options (business_id, name, kind, sort_order) VALUES (t_get('bizS'), 'Renk', 'color', 1) RETURNING id) SELECT t_set('optS_color', id) FROM x;
WITH x AS (INSERT INTO product_options (business_id, name, kind, sort_order) VALUES (t_get('bizS'), 'Beden', 'size', 2) RETURNING id) SELECT t_set('optS_size', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, color_hex, sort_order) VALUES (t_get('optS_color'), 'Siyah', 'SYH', '#111111', 1) RETURNING id) SELECT t_set('vS_black', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, color_hex, sort_order) VALUES (t_get('optS_color'), 'Bej', 'BEJ', '#d9c9a8', 2) RETURNING id) SELECT t_set('vS_beige', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optS_size'), 'S', 'S', 1) RETURNING id) SELECT t_set('vS_s', id) FROM x;
WITH x AS (INSERT INTO option_values (product_option_id, value, code, sort_order) VALUES (t_get('optS_size'), 'M', 'M', 2) RETURNING id) SELECT t_set('vS_m', id) FROM x;
WITH x AS (INSERT INTO categories (business_id, name, slug) VALUES (t_get('bizS'), 'Elbise', 'elbise') RETURNING id) SELECT t_set('catS_elbise', id) FROM x;
WITH x AS (INSERT INTO categories (business_id, name, slug) VALUES (t_get('bizS'), 'Triko', 'triko') RETURNING id) SELECT t_set('catS_triko', id) FROM x;
WITH x AS (INSERT INTO categories (business_id, name, slug) VALUES (t_get('bizS'), 'Pantolon', 'pantolon') RETURNING id) SELECT t_set('catS_pant', id) FROM x;
CREATE FUNCTION t75_q(p_sql TEXT) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE b BOOLEAN; BEGIN EXECUTE 'SELECT (' || p_sql || ')' INTO b; RETURN COALESCE(b, false); END $$;
CREATE FUNCTION t75_pid(p_prefix TEXT) RETURNS UUID LANGUAGE sql SECURITY DEFINER STABLE AS $$ SELECT id FROM products WHERE business_id = t_get('bizS') AND sku_prefix = p_prefix $$;
CREATE FUNCTION t75_vid(p_sku TEXT) RETURNS UUID LANGUAGE sql SECURITY DEFINER STABLE AS $$ SELECT id FROM product_variants WHERE business_id = t_get('bizS') AND sku = p_sku $$;

SELECT t_login('a12');
-- A: dress, colour + size (4 variants)
SELECT t_ok('T75b A: dress with colour and size', $q$ SELECT rpc_onboard_product(t_get('bizS'),
  jsonb_build_object('name', 'Keten Elbise', 'sku_prefix', 'ELB-A', 'category_id', t_get('catS_elbise')::text, 'default_sale_price', '1200', 'description', 'Yazlık keten elbise.'),
  jsonb_build_array(
    jsonb_build_object('sku', 'ELB-A-SYH-S', 'option_value_ids', jsonb_build_array(t_get('vS_black')::text, t_get('vS_s')::text)),
    jsonb_build_object('sku', 'ELB-A-SYH-M', 'option_value_ids', jsonb_build_array(t_get('vS_black')::text, t_get('vS_m')::text)),
    jsonb_build_object('sku', 'ELB-A-BEJ-S', 'option_value_ids', jsonb_build_array(t_get('vS_beige')::text, t_get('vS_s')::text)),
    jsonb_build_object('sku', 'ELB-A-BEJ-M', 'option_value_ids', jsonb_build_array(t_get('vS_beige')::text, t_get('vS_m')::text)))) $q$);
-- B: one-size knit (no options)
SELECT t_ok('T75b2 B: one-size knit', $q$ SELECT rpc_onboard_product(t_get('bizS'),
  jsonb_build_object('name', 'Triko Kazak', 'sku_prefix', 'TRK-B', 'category_id', t_get('catS_triko')::text, 'default_sale_price', '800'),
  jsonb_build_array(jsonb_build_object('sku', 'TRK-B-STD', 'option_value_ids', '[]'::jsonb))) $q$);
-- C: size-only trousers
SELECT t_ok('T75b3 C: size-only trousers', $q$ SELECT rpc_onboard_product(t_get('bizS'),
  jsonb_build_object('name', 'Yün Pantolon', 'sku_prefix', 'PNT-C', 'category_id', t_get('catS_pant')::text, 'default_sale_price', '950'),
  jsonb_build_array(jsonb_build_object('sku', 'PNT-C-S', 'option_value_ids', jsonb_build_array(t_get('vS_s')::text)),
                    jsonb_build_object('sku', 'PNT-C-M', 'option_value_ids', jsonb_build_array(t_get('vS_m')::text)))) $q$);
-- D: sold-out product (no stock ever)
SELECT t_ok('T75b4 D: sold-out product', $q$ SELECT rpc_onboard_product(t_get('bizS'),
  jsonb_build_object('name', 'İpek Fular', 'sku_prefix', 'FLR-D', 'category_id', t_get('catS_triko')::text, 'default_sale_price', '450'),
  jsonb_build_array(jsonb_build_object('sku', 'FLR-D-STD', 'option_value_ids', '[]'::jsonb))) $q$);
-- E: never published
SELECT t_ok('T75b5 E: unpublished product', $q$ SELECT rpc_onboard_product(t_get('bizS'),
  jsonb_build_object('name', 'Gizli Ceket', 'sku_prefix', 'CKT-E', 'category_id', t_get('catS_elbise')::text, 'default_sale_price', '2500'),
  jsonb_build_array(jsonb_build_object('sku', 'CKT-E-STD', 'option_value_ids', '[]'::jsonb))) $q$);
-- F: product with private proof images
SELECT t_ok('T75b6 F: product with private label/proof images', $q$ SELECT rpc_onboard_product(t_get('bizS'),
  jsonb_build_object('name', 'Deri Çanta', 'sku_prefix', 'CNT-F', 'category_id', t_get('catS_triko')::text, 'default_sale_price', '3200'),
  jsonb_build_array(jsonb_build_object('sku', 'CNT-F-STD', 'option_value_ids', '[]'::jsonb))) $q$);
-- stock: A black S 5, A black M 2 (low), A beige S 5, A beige M 0; B 10; C S 1 (low), C M 0; D 0; F 3
SELECT t_ok('T75b7 stock via adjustments', $q$ SELECT rpc_post_inventory_adjustment(t_get('bizS'), t_get('brS'), t75_vid('ELB-A-SYH-S'), 'sellable', 5, 'acilis', 'manual_cost', 400),
  rpc_post_inventory_adjustment(t_get('bizS'), t_get('brS'), t75_vid('ELB-A-SYH-M'), 'sellable', 2, 'acilis', 'manual_cost', 400),
  rpc_post_inventory_adjustment(t_get('bizS'), t_get('brS'), t75_vid('ELB-A-BEJ-S'), 'sellable', 5, 'acilis', 'manual_cost', 400),
  rpc_post_inventory_adjustment(t_get('bizS'), t_get('brS'), t75_vid('TRK-B-STD'), 'sellable', 10, 'acilis', 'manual_cost', 300),
  rpc_post_inventory_adjustment(t_get('bizS'), t_get('brS'), t75_vid('PNT-C-S'), 'sellable', 1, 'acilis', 'manual_cost', 350),
  rpc_post_inventory_adjustment(t_get('bizS'), t_get('brS'), t75_vid('CNT-F-STD'), 'sellable', 3, 'acilis', 'manual_cost', 1500),
  rpc_post_inventory_adjustment(t_get('bizS'), t_get('brS'), t75_vid('CNT-F-STD'), 'damaged', 2, 'hasarli', 'manual_cost', 1500) $q$);
SELECT t_logout();
-- images (rows only; the files live in storage): F has a main image, a label tag and a receiving proof; A has a main image + one variant image
WITH x AS (INSERT INTO product_images (product_id, role, storage_path, mime_type, byte_size) VALUES (t75_pid('CNT-F'), 'product_main', 'business/' || t_get('bizS') || '/products/' || t75_pid('CNT-F') || '/aaaaaaaa-0000-4000-8000-000000000001.jpg', 'image/jpeg', 1000) RETURNING id) SELECT t_set('imgF_main', id) FROM x;
WITH x AS (INSERT INTO product_images (product_id, role, storage_path, mime_type, byte_size) VALUES (t75_pid('CNT-F'), 'label_tag', 'business/' || t_get('bizS') || '/products/' || t75_pid('CNT-F') || '/aaaaaaaa-0000-4000-8000-000000000002.jpg', 'image/jpeg', 1000) RETURNING id) SELECT t_set('imgF_label', id) FROM x;
WITH x AS (INSERT INTO suppliers (business_id, name, currency) VALUES (t_get('bizS'), 'ZZ Tedarikçi', 'TRY') RETURNING id) SELECT t_set('supS', id) FROM x;
WITH x AS (INSERT INTO goods_receipts (business_id, branch_id, supplier_id, receipt_number, invoice_currency, exchange_rate)
  VALUES (t_get('bizS'), t_get('brS'), t_get('supS'), 'GR-ZZ-0001', 'TRY', 1) RETURNING id) SELECT t_set('grS', id) FROM x;
WITH x AS (INSERT INTO product_images (goods_receipt_id, role, storage_path, mime_type, byte_size) VALUES (t_get('grS'), 'receiving_proof', 'business/' || t_get('bizS') || '/receipts/' || t_get('grS') || '/aaaaaaaa-0000-4000-8000-000000000003.jpg', 'image/jpeg', 1000) RETURNING id) SELECT t_set('imgF_proof', id) FROM x;
WITH x AS (INSERT INTO product_images (product_id, role, storage_path, mime_type, byte_size) VALUES (t75_pid('ELB-A'), 'product_main', 'business/' || t_get('bizS') || '/products/' || t75_pid('ELB-A') || '/aaaaaaaa-0000-4000-8000-000000000004.jpg', 'image/jpeg', 1000) RETURNING id) SELECT t_set('imgA_main', id) FROM x;
WITH x AS (INSERT INTO product_images (product_id, variant_id, role, storage_path, mime_type, byte_size) VALUES (t75_pid('ELB-A'), t75_vid('ELB-A-BEJ-S'), 'variant', 'business/' || t_get('bizS') || '/products/' || t75_pid('ELB-A') || '/aaaaaaaa-0000-4000-8000-000000000005.jpg', 'image/jpeg', 1000) RETURNING id) SELECT t_set('imgA_beige', id) FROM x;

-- ---------------- storefront settings ----------------
SELECT t_login('a12');
SELECT t_err('T75c the slug is validated', $q$ SELECT rpc_storefront_upsert(t_get('bizS'), '{"slug":"ZZ Store!","store_name":"ZZ"}') $q$, 'INVALID_SLUG');
SELECT t_err('T75c2 the store name is required', $q$ SELECT rpc_storefront_upsert(t_get('bizS'), '{"slug":"zz-store","store_name":" "}') $q$, 'INVALID_NAME');
SELECT t_ok('T75c3 the owner creates the storefront (disabled)', $q$ SELECT rpc_storefront_upsert(t_get('bizS'), jsonb_build_object('slug', 'zz-store', 'store_name', 'ZZ Store', 'tagline', 'sessiz lüks', 'instagram', '@zzstore', 'whatsapp', '+90 555 000 00 00', 'enabled', false, 'fulfillment_branch_id', t_get('brS')::text)) $q$);
SELECT t_check('T75c4 settings are normalised (instagram without @, whatsapp digits, state display, threshold 3)',
  t75_q($q$ SELECT instagram = 'zzstore' AND whatsapp = '+905550000000' AND stock_display = 'state' AND low_stock_threshold = 3 AND NOT enabled FROM storefronts WHERE business_id = t_get('bizS') $q$));
SELECT t_logout();
SELECT t_check('T75c5 a disabled store resolves to nothing for anon', rpc_shop_resolve('zz-store') IS NULL AND rpc_shop_home('zz-store') IS NULL AND rpc_shop_products('zz-store') IS NULL AND rpc_shop_product('zz-store', 'keten-elbise') IS NULL);
SELECT t_login('u1');
SELECT t_err('T75c6 another tenant''s owner cannot touch these settings', $q$ SELECT rpc_storefront_upsert(t_get('bizS'), '{"slug":"zz-store","store_name":"X"}') $q$, 'FORBIDDEN');
SELECT t_err('T75c7 the TLC owner cannot take the slug of another store', $q$ SELECT rpc_storefront_upsert(t_get('biz'), '{"slug":"zz-store","store_name":"Things"}') $q$, 'SLUG_TAKEN');
SELECT t_check('T75c8 and sees no storefront row of the other tenant', (SELECT count(*) FROM storefronts) = 0);
SELECT t_logout();
SELECT t_login('a11');
SELECT t_err('T75c9 a manager of another business is refused too', $q$ SELECT rpc_storefront_admin(t_get('bizS')) $q$, 'FORBIDDEN');
SELECT t_logout();

-- ---------------- publishing ----------------
SELECT t_login('a12');
SELECT t_err('T75d publishing needs an active product', $q$ SELECT rpc_storefront_publish_product(t_get('bizS'), gen_random_uuid(), true) $q$, 'INVALID_PRODUCT');
SELECT t_ok('T75d2 A is published (slug derived from the Turkish name)', $q$ SELECT rpc_storefront_publish_product(t_get('bizS'), t75_pid('ELB-A'), true) $q$);
SELECT t_check('T75d3 slug, timestamp and state', t75_q($q$ SELECT web_published AND web_slug = 'keten-elbise' AND web_published_at IS NOT NULL FROM products WHERE id = t75_pid('ELB-A') $q$));
SELECT t_ok('T75d4 B, C, D, F published', $q$ SELECT rpc_storefront_publish_product(t_get('bizS'), t75_pid('TRK-B'), true), rpc_storefront_publish_product(t_get('bizS'), t75_pid('PNT-C'), true),
  rpc_storefront_publish_product(t_get('bizS'), t75_pid('FLR-D'), true), rpc_storefront_publish_product(t_get('bizS'), t75_pid('CNT-F'), true) $q$);
SELECT t_ok('T75d5 web copy: title, description, featured, sort', $q$ SELECT rpc_storefront_set_product_web(t_get('bizS'), t75_pid('ELB-A'), '{"web_title":"Keten Elbise — Yaz","web_description":"Web açıklaması.","web_featured":true,"web_sort_order":1}') $q$);
SELECT t_err('T75d6 a product slug cannot collide inside the store', $q$ SELECT rpc_storefront_set_product_web(t_get('bizS'), t75_pid('TRK-B'), '{"web_slug":"keten-elbise"}') $q$, 'SLUG_TAKEN');
SELECT t_ok('T75d7 a variant can be taken off the web (A beige M)', $q$ SELECT rpc_storefront_set_variant_web(t_get('bizS'), t75_vid('ELB-A-BEJ-M'), false) $q$);
SELECT t_ok('T75d8 the main image of F and A''s images are published (paths recorded)', $q$ SELECT
  rpc_storefront_set_image_public(t_get('bizS'), t_get('imgF_main'), 'store/' || t_get('bizS') || '/products/' || t75_pid('CNT-F') || '/' || t_get('imgF_main') || '.jpg'),
  rpc_storefront_set_image_public(t_get('bizS'), t_get('imgA_main'), 'store/' || t_get('bizS') || '/products/' || t75_pid('ELB-A') || '/' || t_get('imgA_main') || '.jpg'),
  rpc_storefront_set_image_public(t_get('bizS'), t_get('imgA_beige'), 'store/' || t_get('bizS') || '/products/' || t75_pid('ELB-A') || '/' || t_get('imgA_beige') || '.jpg') $q$);
SELECT t_err('T75d9 a label tag can never be published', $q$ SELECT rpc_storefront_set_image_public(t_get('bizS'), t_get('imgF_label'), 'store/' || t_get('bizS') || '/products/' || t75_pid('CNT-F') || '/' || t_get('imgF_label') || '.jpg') $q$, 'PRIVATE_ROLE');
SELECT t_err('T75d10 nor a receiving proof', $q$ SELECT rpc_storefront_set_image_public(t_get('bizS'), t_get('imgF_proof'), 'store/' || t_get('bizS') || '/products/' || t75_pid('CNT-F') || '/' || t_get('imgF_proof') || '.jpg') $q$, 'PRIVATE_ROLE');
SELECT t_err('T75d11 a public path under another tenant/product is refused', $q$ SELECT rpc_storefront_set_image_public(t_get('bizS'), t_get('imgA_main'), 'store/' || t_get('biz') || '/products/' || t75_pid('ELB-A') || '/' || t_get('imgA_main') || '.jpg') $q$, 'PUBLIC_PATH_MISMATCH');
SELECT t_ok('T75d12 the store goes live', $q$ SELECT rpc_storefront_upsert(t_get('bizS'), jsonb_build_object('slug', 'zz-store', 'store_name', 'ZZ Store', 'enabled', true, 'fulfillment_branch_id', t_get('brS')::text, 'announcement', 'Kargo bedava')) $q$);
SELECT t_check('T75d13 the admin overview lists 6 active products, 5 published, with web variant counts and public image counts',
  (SELECT (r ->> 'published_count')::int = 5 AND (r ->> 'total')::int = 6 AND (r -> 'storefront' ->> 'enabled')::boolean
          AND (SELECT count(*) FROM jsonb_array_elements(r -> 'products') p WHERE (p ->> 'web_published')::boolean) = 5
          AND (SELECT (p ->> 'web_variants')::int = 3 AND (p ->> 'public_images')::int = 2 FROM jsonb_array_elements(r -> 'products') p WHERE p ->> 'name' = 'Keten Elbise')
   FROM rpc_storefront_admin(t_get('bizS')) r));
SELECT t_check('T75d14 the per-product admin view carries variants with labels and images with their public state',
  (SELECT jsonb_array_length(r -> 'variants') = 4 AND jsonb_array_length(r -> 'images') = 2
          AND (SELECT v ->> 'labels' = 'Siyah / S' FROM jsonb_array_elements(r -> 'variants') v WHERE v ->> 'sku' = 'ELB-A-SYH-S')
   FROM rpc_storefront_admin_product(t_get('bizS'), t75_pid('ELB-A')) r));
SELECT t_logout();
-- superuser: the CHECK holds even without the RPC
SELECT t_err('T75d15 the column constraint refuses a public path on a proof image', $q$ UPDATE product_images SET public_path = 'store/' || t_get('bizS') || '/products/' || t75_pid('CNT-F') || '/' || t_get('imgF_proof') || '.jpg' WHERE id = t_get('imgF_proof') $q$, 'chk_product_images_public_role');
UPDATE product_variants SET web_enabled = false WHERE product_id = t75_pid('FLR-D');
SELECT t_login('a12');
SELECT t_err('T75d16 publishing needs a web-enabled variant', $q$ SELECT rpc_storefront_publish_product(t_get('bizS'), t75_pid('FLR-D'), true) $q$, 'NO_WEB_VARIANT');
SELECT t_logout();
UPDATE product_variants SET web_enabled = true WHERE product_id = t75_pid('FLR-D');
UPDATE products SET status = 'archived' WHERE id = t75_pid('CNT-F');
SELECT t_check('T75d17 archiving a product unpublishes it (trigger)', (SELECT NOT web_published FROM products WHERE id = t75_pid('CNT-F')));
UPDATE products SET status = 'active' WHERE id = t75_pid('CNT-F');
SELECT t_check('T75d18 reactivating does not republish by itself', (SELECT NOT web_published FROM products WHERE id = t75_pid('CNT-F')));
SELECT t_login('a12');
SELECT t_ok('T75d19 F is published again by the owner', $q$ SELECT rpc_storefront_publish_product(t_get('bizS'), t75_pid('CNT-F'), true) $q$);
SELECT t_logout();

-- ---------------- anon browsing ----------------
SET ROLE anon;
SELECT t_check('T75e resolve: identity, currency, categories with published counts, announcement, no internals',
  (SELECT r ->> 'store_name' = 'ZZ Store' AND r ->> 'currency' = 'TRY' AND r ->> 'announcement' = 'Kargo bedava' AND (r ->> 'published_count')::int = 5
          AND jsonb_array_length(r -> 'categories') = 3
          AND (SELECT (c ->> 'count')::int = 1 FROM jsonb_array_elements(r -> 'categories') c WHERE c ->> 'slug' = 'elbise')   -- E is unpublished
          AND (SELECT (c ->> 'count')::int = 3 FROM jsonb_array_elements(r -> 'categories') c WHERE c ->> 'slug' = 'triko')
          AND NOT (r ? 'business_id') AND NOT (r ? 'fulfillment_branch_id')
   FROM rpc_shop_resolve('zz-store') r));
SELECT t_check('T75e2 unknown slug resolves to nothing', rpc_shop_resolve('nope') IS NULL AND rpc_shop_products('nope') IS NULL);
SELECT t_check('T75e3 home: featured A only; new arrivals 5 published; cards carry price, availability, image path, colours',
  (SELECT jsonb_array_length(r -> 'featured') = 1 AND r -> 'featured' -> 0 ->> 'slug' = 'keten-elbise' AND jsonb_array_length(r -> 'new_arrivals') = 5
          AND (r -> 'featured' -> 0 ->> 'price_from')::numeric = 1200 AND r -> 'featured' -> 0 ->> 'availability' = 'in_stock'
          AND r -> 'featured' -> 0 -> 'image' ->> 'path' LIKE 'store/%' AND jsonb_array_length(r -> 'featured' -> 0 -> 'colors') = 2
          AND r -> 'featured' -> 0 ->> 'name' = 'Keten Elbise — Yaz'
   FROM rpc_shop_home('zz-store') r));
SELECT t_check('T75e4 listing: all 5, category filter, search, sort by price, pagination',
  (SELECT (r ->> 'total')::int = 5 FROM rpc_shop_products('zz-store') r)
  AND (SELECT (r ->> 'total')::int = 3 AND r -> 'category' ->> 'name' = 'Triko' FROM rpc_shop_products('zz-store', 'triko') r)
  AND (SELECT (r ->> 'total')::int = 0 FROM rpc_shop_products('zz-store', 'yok') r)
  AND (SELECT (r ->> 'total')::int = 1 AND r -> 'rows' -> 0 ->> 'slug' = 'keten-elbise' FROM rpc_shop_products('zz-store', NULL, 'elbise') r)
  AND (SELECT r -> 'rows' -> 0 ->> 'slug' = 'ipek-fular' AND r -> 'rows' -> 4 ->> 'slug' = 'deri-canta' FROM rpc_shop_products('zz-store', NULL, NULL, 'price_asc') r)
  AND (SELECT jsonb_array_length(r -> 'rows') = 2 AND (r ->> 'offset')::int = 2 FROM rpc_shop_products('zz-store', NULL, NULL, 'newest', 2, 2) r));
SELECT t_err('T75e5 the sort key is validated', $q$ SELECT rpc_shop_products('zz-store', NULL, NULL, 'cost') $q$, 'INVALID_SORT');
SELECT t_check('T75e6 availability states: D sold out, C low (1 of threshold 3), B in stock; E is invisible',
  (SELECT (SELECT c ->> 'availability' FROM jsonb_array_elements(r -> 'rows') c WHERE c ->> 'slug' = 'ipek-fular') = 'sold_out'
          AND (SELECT c ->> 'availability' FROM jsonb_array_elements(r -> 'rows') c WHERE c ->> 'slug' = 'yun-pantolon') = 'low'
          AND (SELECT c ->> 'availability' FROM jsonb_array_elements(r -> 'rows') c WHERE c ->> 'slug' = 'triko-kazak') = 'in_stock'
          AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'rows') c WHERE c ->> 'name' ILIKE '%ceket%')
   FROM rpc_shop_products('zz-store') r));
SELECT t_check('T75e7 product A detail: colour first then size, 3 web variants, states per variant, variant image mapped, no SKU/barcode/cost keys',
  (SELECT r ->> 'name' = 'Keten Elbise — Yaz' AND r ->> 'description' = 'Web açıklaması.' AND r ->> 'currency' = 'TRY'
          AND jsonb_array_length(r -> 'options') = 2 AND r -> 'options' -> 0 ->> 'kind' = 'color' AND r -> 'options' -> 1 ->> 'kind' = 'size'
          AND jsonb_array_length(r -> 'options' -> 0 -> 'values') = 2 AND r -> 'options' -> 0 -> 'values' -> 0 ->> 'hex' = '#111111'
          AND jsonb_array_length(r -> 'variants') = 3
          AND (SELECT count(*) FROM jsonb_array_elements(r -> 'variants') v WHERE v ->> 'state' = 'low') = 1
          AND (SELECT bool_and(v ->> 'available' IS NULL AND (v ->> 'price')::numeric = 1200 AND NOT (v ? 'sku') AND NOT (v ? 'cost')) FROM jsonb_array_elements(r -> 'variants') v)
          AND jsonb_array_length(r -> 'images') = 2 AND (SELECT count(*) FROM jsonb_array_elements(r -> 'variants') v WHERE v ->> 'image_id' IS NOT NULL) = 1
          AND NOT (r ? 'notes') AND NOT (r ? 'supplier_id') AND NOT (r ? 'sku_prefix')
   FROM rpc_shop_product('zz-store', 'keten-elbise') r));
SELECT t_check('T75e8 B detail: no options, one variant; C detail: size only; D detail: sold out',
  (SELECT jsonb_array_length(r -> 'options') = 0 AND jsonb_array_length(r -> 'variants') = 1 FROM rpc_shop_product('zz-store', 'triko-kazak') r)
  AND (SELECT jsonb_array_length(r -> 'options') = 1 AND r -> 'options' -> 0 ->> 'kind' = 'size' AND jsonb_array_length(r -> 'variants') = 2 FROM rpc_shop_product('zz-store', 'yun-pantolon') r)
  AND (SELECT r -> 'variants' -> 0 ->> 'state' = 'sold_out' FROM rpc_shop_product('zz-store', 'ipek-fular') r));
SELECT t_check('T75e9 F detail exposes only the published main image, never the label tag or proof',
  (SELECT jsonb_array_length(r -> 'images') = 1 AND r -> 'images' -> 0 ->> 'role' = 'product_main' AND r -> 'images' -> 0 ->> 'path' LIKE 'store/%'
          AND NOT (r::text LIKE '%business/%') AND NOT (r::text ILIKE '%label%') AND NOT (r::text ILIKE '%receiving%')
   FROM rpc_shop_product('zz-store', 'deri-canta') r));
SELECT t_check('T75e10 the unpublished product and a foreign slug return nothing',
  rpc_shop_product('zz-store', 'gizli-ceket') IS NULL AND rpc_shop_product('zz-store', 'keten-gomlek') IS NULL);
SELECT t_check('T75e11 availability endpoint: A black M low, D sold out, unknown/disabled variants sold out, exact numbers hidden in state mode',
  (SELECT r -> (t75_vid('ELB-A-SYH-M')::text) ->> 'state' = 'low' AND r -> (t75_vid('ELB-A-SYH-M')::text) ->> 'available' IS NULL
          AND r -> (t75_vid('FLR-D-STD')::text) ->> 'state' = 'sold_out'
          AND r -> (t75_vid('ELB-A-BEJ-M')::text) ->> 'state' = 'sold_out' AND r -> (t75_vid('ELB-A-BEJ-M')::text) ->> 'price' IS NULL
          AND r -> (t75_vid('CKT-E-STD')::text) ->> 'state' = 'sold_out'
          AND r -> ('00000000-0000-4000-8000-000000000000') ->> 'state' = 'sold_out'
   FROM rpc_shop_availability('zz-store', ARRAY[t75_vid('ELB-A-SYH-M'), t75_vid('FLR-D-STD'), t75_vid('ELB-A-BEJ-M'), t75_vid('CKT-E-STD'), '00000000-0000-4000-8000-000000000000'::uuid]) r));
SELECT t_err('T75e12 the availability call is bounded', $q$ SELECT rpc_shop_availability('zz-store', (SELECT array_agg(gen_random_uuid()) FROM generate_series(1, 51))) $q$, 'INVALID_INPUT');
-- the operational tables are RLS-guarded by membership helpers anon may not even execute: every direct read fails
SELECT t_err('T75e13 anon cannot read product_images directly', $q$ SELECT count(*) FROM product_images $q$, '42501');
SELECT t_err('T75e13b nor barcodes', $q$ SELECT count(*) FROM barcodes $q$, '42501');
SELECT t_err('T75e13c nor suppliers', $q$ SELECT count(*) FROM suppliers $q$, '42501');
SELECT t_err('T75e13d nor customers', $q$ SELECT count(*) FROM customers $q$, '42501');
SELECT t_err('T75e13e nor inventory movements', $q$ SELECT count(*) FROM inventory_movements $q$, '42501');
SELECT t_err('T75e13f nor cost pools', $q$ SELECT count(*) FROM variant_cost_pools $q$, '42501');
SELECT t_err('T75e13g nor reservations', $q$ SELECT count(*) FROM reservations $q$, '42501');
SELECT t_err('T75e13h nor goods receipts', $q$ SELECT count(*) FROM goods_receipts $q$, '42501');
SELECT t_err('T75e13i nor storefront settings', $q$ SELECT count(*) FROM storefronts $q$, '42501');
SELECT t_err('T75e14 anon cannot call the admin RPCs', $q$ SELECT rpc_storefront_admin(t_get('bizS')) $q$, '42501');
SELECT t_err('T75e15 anon cannot publish', $q$ SELECT rpc_storefront_publish_product(t_get('bizS'), t75_pid('CKT-E'), true) $q$, '42501');
SELECT t_err('T75e16 anon cannot read a product row directly', $q$ SELECT count(*) FROM products $q$, '42501');
SELECT t_check('T75e17 the TLC catalogue is not reachable through the public surface (no storefront)', rpc_shop_resolve('things-like-crop') IS NULL AND rpc_shop_resolve('tlc') IS NULL);
SELECT t_check('T75e18 host resolver: no verified domain → nothing', rpc_shop_resolve_host('zz.example.com') IS NULL);
RESET ROLE;

-- ---------------- availability = sellable − active holds; damaged never counts ----------------
SELECT t_check('T75f the damaged bucket never shows: F available 3 (not 5)',
  t75_q($q$ SELECT fn_shop_available(t_get('bizS'), t_get('brS'), t75_vid('CNT-F-STD')) = 3 $q$));
WITH x AS (INSERT INTO customers (business_id, full_name) VALUES (t_get('bizS'), 'Web Müşteri') RETURNING id) SELECT t_set('cS', id) FROM x;
SELECT t_login('a12');
SELECT t_set('vAS', t75_vid('ELB-A-SYH-S'));
SELECT t_ok('T75f2 a POS hold of 4 on A black S', $q$ SELECT rpc_pos_reservation_create(t_get('brS'), t_get('cS'), t_json_items('vAS','4',NULL)) $q$);
SELECT t_logout();
SET ROLE anon;
SELECT t_check('T75f3 the public availability drops to 1 (low) while the hold is active; on_hand is untouched',
  (SELECT r -> (t_get('vAS')::text) ->> 'state' = 'low' FROM rpc_shop_availability('zz-store', ARRAY[t_get('vAS')]) r)
  AND t75_q($q$ SELECT fn_bucket_qty(t_get('bizS'), t_get('brS'), t_get('vAS'), 'sellable') = 5 $q$));
RESET ROLE;
SELECT t_check('T75f4 the storefront created no inventory movement and no reservation of its own',
  (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizS')) = 7 AND (SELECT count(*) FROM reservations WHERE business_id = t_get('bizS')) = 1);

-- ---------------- exact display mode + cross-tenant ----------------
SELECT t_login('a12');
SELECT t_ok('T75g the merchant switches to exact numbers with threshold 2', $q$ SELECT rpc_storefront_upsert(t_get('bizS'), jsonb_build_object('slug', 'zz-store', 'store_name', 'ZZ Store', 'enabled', true, 'stock_display', 'exact', 'low_stock_threshold', 2)) $q$);
SELECT t_logout();
SET ROLE anon;
SELECT t_check('T75g2 exact numbers appear and the threshold moved (A black M = 2 → low, A black S = 1 → low)',
  (SELECT (r -> (t75_vid('ELB-A-SYH-M')::text) ->> 'available')::int = 2 AND r -> (t75_vid('ELB-A-SYH-M')::text) ->> 'state' = 'low'
          AND (r -> (t_get('vAS')::text) ->> 'available')::int = 1 AND (r -> (t75_vid('TRK-B-STD')::text) ->> 'available')::int = 10 AND r -> (t75_vid('TRK-B-STD')::text) ->> 'state' = 'in_stock'
   FROM rpc_shop_availability('zz-store', ARRAY[t75_vid('ELB-A-SYH-M'), t_get('vAS'), t75_vid('TRK-B-STD')]) r));
SELECT t_check('T75g3 a variant of another tenant is sold_out/unknown even through the right store',
  (SELECT r -> (t_get('v62a')::text) ->> 'state' = 'sold_out' AND r -> (t_get('v62a')::text) ->> 'price' IS NULL FROM rpc_shop_availability('zz-store', ARRAY[t_get('v62a')]) r));
RESET ROLE;
SELECT t_check('T75h TLC: no storefront, no published product, no public image, no web flag moved',
  (SELECT count(*) FROM storefronts WHERE business_id = t_get('biz')) = 0
  AND (SELECT count(*) FROM products WHERE business_id = t_get('biz') AND (web_published OR web_slug IS NOT NULL OR web_featured)) = 0
  AND (SELECT count(*) FROM product_images WHERE business_id = t_get('biz') AND public_path IS NOT NULL) = 0);

-- ============================================================
-- T76  Guest order + checkout foundation  (Phase 14B)
-- ============================================================
SELECT t_check('T76a order tables: RLS on, zero policies, no anon/authenticated privilege; hold link on reservations; public RPCs are the only anon surface',
  (SELECT count(*) FROM pg_class WHERE relname IN ('storefront_orders','storefront_order_items','storefront_order_events') AND relrowsecurity) = 3
  AND (SELECT count(*) FROM pg_policies WHERE tablename IN ('storefront_orders','storefront_order_items','storefront_order_events')) = 0
  AND NOT has_table_privilege('anon', 'storefront_orders', 'SELECT') AND NOT has_table_privilege('authenticated', 'storefront_orders', 'SELECT')
  AND NOT has_table_privilege('anon', 'storefront_orders', 'INSERT') AND NOT has_table_privilege('authenticated', 'storefront_order_items', 'SELECT')
  AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'reservations' AND column_name = 'storefront_order_id')
  AND has_function_privilege('anon', 'rpc_shop_create_order(text, text, jsonb, jsonb, text)', 'EXECUTE')
  AND has_function_privilege('anon', 'rpc_shop_order(text, text)', 'EXECUTE') AND has_function_privilege('anon', 'rpc_shop_cancel_order(text, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_online_orders(uuid, text, text, integer, integer)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_online_order_confirm(uuid, uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'rpc_pos_complete_online_order(uuid, uuid, jsonb, uuid, uuid, text)', 'EXECUTE'));
-- fixtures: the storefront of T75 (zz-store, exact display, threshold 2); a9 joins as stock_staff; keys are 64-hex client secrets
INSERT INTO business_members (business_id, user_id, role, is_active) VALUES (t_get('bizS'), t_get('a9'), 'stock_staff', true), (t_get('bizS'), t_get('a11'), 'manager', true);
CREATE FUNCTION t76_key(p_n INT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$ SELECT encode(sha256(('t76-key-' || p_n::text)::bytea), 'hex') $$;
CREATE FUNCTION t76_order(p_no TEXT) RETURNS UUID LANGUAGE sql SECURITY DEFINER STABLE AS $$ SELECT id FROM storefront_orders WHERE business_id = t_get('bizS') AND order_number = p_no $$;
CREATE FUNCTION t76_q(p_sql TEXT) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$ DECLARE b BOOLEAN; BEGIN EXECUTE 'SELECT (' || p_sql || ')' INTO b; RETURN COALESCE(b, false); END $$;
CREATE FUNCTION t76_num(p_sql TEXT) RETURNS NUMERIC LANGUAGE plpgsql SECURITY DEFINER AS $$ DECLARE n NUMERIC; BEGIN EXECUTE p_sql INTO n; RETURN n; END $$;
CREATE FUNCTION t76_txt(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$ DECLARE s TEXT; BEGIN EXECUTE p_sql INTO s; RETURN s; END $$;
CREATE TEMP TABLE _t76 AS SELECT (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizS')) AS mov, (SELECT count(*) FROM customers WHERE business_id = t_get('bizS')) AS cust,
  (SELECT count(*) FROM sales WHERE business_id = t_get('bizS')) AS sales, (SELECT extract(year FROM now())::int) AS yr;
GRANT SELECT ON _t76 TO authenticated, anon;
CREATE FUNCTION t76_cust(p_name TEXT DEFAULT 'Misafir Müşteri', p_phone TEXT DEFAULT '0532 111 22 33', p_email TEXT DEFAULT 'guest@example.com') RETURNS JSONB LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('name', p_name, 'phone', p_phone, 'email', p_email, 'note', 'Öğleden sonra alırım') $$;
CREATE FUNCTION t76_line(p_sku TEXT, p_qty INT) RETURNS JSONB LANGUAGE sql SECURITY DEFINER STABLE AS $$ SELECT jsonb_build_object('variant_id', t75_vid(p_sku), 'quantity', p_qty) $$;

-- ---------------- checkout validation (anon) ----------------
SET ROLE anon;
SELECT t_err('T76b unknown store', $q$ SELECT rpc_shop_create_order('nope', t76_key(0), jsonb_build_array(t76_line('TRK-B-STD', 1)), t76_cust()) $q$, 'STORE_UNAVAILABLE');
SELECT t_err('T76b2 shipping is not offered', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), jsonb_build_array(t76_line('TRK-B-STD', 1)), t76_cust(), 'shipping') $q$, 'FULFILLMENT_UNAVAILABLE');
SELECT t_err('T76b3 the idempotency key must be long', $q$ SELECT rpc_shop_create_order('zz-store', 'short', jsonb_build_array(t76_line('TRK-B-STD', 1)), t76_cust()) $q$, 'INVALID_INPUT');
SELECT t_err('T76b4 empty cart', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), '[]'::jsonb, t76_cust()) $q$, 'EMPTY_CART');
SELECT t_err('T76b5 quantity 11 is over the line limit', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), jsonb_build_array(t76_line('TRK-B-STD', 11)), t76_cust()) $q$, 'INVALID_QTY');
SELECT t_err('T76b6 more than 30 units', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), jsonb_build_array(t76_line('TRK-B-STD', 10), t76_line('ELB-A-SYH-S', 10), t76_line('ELB-A-BEJ-S', 10), t76_line('CNT-F-STD', 1)), t76_cust()) $q$, 'CART_LIMIT');
SELECT t_err('T76b7 name required', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), jsonb_build_array(t76_line('TRK-B-STD', 1)), t76_cust(' ')) $q$, 'INVALID_NAME');
SELECT t_err('T76b8 phone validated', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), jsonb_build_array(t76_line('TRK-B-STD', 1)), t76_cust('Ad', '12')) $q$, 'INVALID_PHONE');
SELECT t_err('T76b9 email validated', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), jsonb_build_array(t76_line('TRK-B-STD', 1)), t76_cust('Ad', '0532 111 22 33', 'not-an-email')) $q$, 'INVALID_EMAIL');
SELECT t_err('T76b10 an unpublished product cannot be ordered', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), jsonb_build_array(t76_line('CKT-E-STD', 1)), t76_cust()) $q$, 'UNAVAILABLE');
SELECT t_err('T76b11 a web-disabled variant cannot be ordered', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), jsonb_build_array(t76_line('ELB-A-BEJ-M', 1)), t76_cust()) $q$, 'UNAVAILABLE');
SELECT t_err('T76b12 a sold-out product is refused with the available count', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), jsonb_build_array(t76_line('FLR-D-STD', 1)), t76_cust()) $q$, 'INSUFFICIENT');
SELECT t_err('T76b13 a POS hold is respected (A black S: 5 on hand, 4 held → 2 requested refused)', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), jsonb_build_array(t76_line('ELB-A-SYH-S', 2)), t76_cust()) $q$, 'INSUFFICIENT');
SELECT t_err('T76b14 another tenant''s variant is unknown here', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(0), jsonb_build_array(jsonb_build_object('variant_id', t_get('v62a'), 'quantity', 1)), t76_cust()) $q$, 'UNAVAILABLE');
SELECT t_check('T76b15 nothing was created by any refused checkout',
  t76_q($q$ (SELECT count(*) FROM storefront_orders WHERE business_id = t_get('bizS')) = 0 AND (SELECT count(*) FROM reservations WHERE business_id = t_get('bizS') AND source = 'online') = 0 $q$));

-- ---------------- successful checkout: browser price ignored, totals server-side, hold created ----------------
CREATE TEMP TABLE _t76_o1 AS SELECT rpc_shop_create_order('zz-store', t76_key(1),
  jsonb_build_array(t76_line('ELB-A-SYH-M', 1) || '{"unit_price": 1, "price": 1}'::jsonb, t76_line('TRK-B-STD', 2) || '{"unit_price": 1}'::jsonb), t76_cust()) AS r;
GRANT SELECT ON _t76_o1 TO authenticated, anon;
SELECT t_check('T76c the order request is created: WEB number, 64-hex token, pending, total 2800 (1200 + 2×800) — the browser''s 1 ignored',
  (SELECT r ->> 'order_number' = 'WEB-' || (SELECT yr FROM _t76)::text || '-000001' AND r ->> 'tracking_token' ~ '^[0-9a-f]{64}$' AND r ->> 'status' = 'pending_confirmation'
          AND (r ->> 'total')::numeric = 2800 AND r ->> 'currency' = 'TRY' AND NOT (r ->> 'replayed')::boolean
          AND (r ->> 'reservation_expires_at')::timestamptz BETWEEN now() + interval '1439 minutes' AND now() + interval '1441 minutes' FROM _t76_o1));
SELECT t_check('T76c2 items snapshot: names, labels, prices; the hold is an ordinary reservation (guest name, online, no customer) with the RV number',
  t76_q($q$ (SELECT count(*) = 2 AND sum(line_total) = 2800 AND bool_or(variant_labels = 'Siyah / M') AND bool_or(product_name = 'Keten Elbise — Yaz') FROM storefront_order_items WHERE order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'))
            AND (SELECT status = 'active' AND customer_id IS NULL AND hold_name = 'Misafir Müşteri' AND source = 'online' AND reservation_number LIKE 'RV-%' AND created_by IS NULL
                 FROM reservations WHERE storefront_order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'))
            AND (SELECT count(*) FROM reservation_items ri JOIN reservations r ON r.id = ri.reservation_id WHERE r.storefront_order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) = 2 $q$));
SELECT t_check('T76c3 availability drops (A black M 2→1, B 10→8); on_hand, movements and CRM untouched',
  (SELECT (r -> (t75_vid('ELB-A-SYH-M')::text) ->> 'available')::int = 1 AND (r -> (t75_vid('TRK-B-STD')::text) ->> 'available')::int = 8 FROM rpc_shop_availability('zz-store', ARRAY[t75_vid('ELB-A-SYH-M'), t75_vid('TRK-B-STD')]) r)
  AND t76_q($q$ fn_bucket_qty(t_get('bizS'), t_get('brS'), t75_vid('ELB-A-SYH-M'), 'sellable') = 2 AND (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizS')) = (SELECT mov FROM _t76)
            AND (SELECT count(*) FROM customers WHERE business_id = t_get('bizS')) = (SELECT cust FROM _t76) $q$));
SELECT t_check('T76c4 phone kept as typed and normalised; e-mail lowercased; the created event is by the customer',
  t76_q($q$ SELECT phone = '0532 111 22 33' AND phone_normalized = '905321112233' AND email = 'guest@example.com' FROM storefront_orders WHERE id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001') $q$)
  AND t76_q($q$ (SELECT count(*) FROM storefront_order_events WHERE order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001') AND event = 'created' AND actor_type = 'customer') = 1 $q$));
SELECT t_check('T76c5 the same key replays the same order and token; no second order or hold',
  (SELECT (r ->> 'replayed')::boolean AND r ->> 'order_number' = (SELECT r ->> 'order_number' FROM _t76_o1) AND r ->> 'tracking_token' = (SELECT r ->> 'tracking_token' FROM _t76_o1)
   FROM rpc_shop_create_order('zz-store', t76_key(1), jsonb_build_array(t76_line('TRK-B-STD', 9)), t76_cust('Baska Biri')) r)
  AND t76_q($q$ (SELECT count(*) FROM storefront_orders WHERE business_id = t_get('bizS')) = 1 $q$));
CREATE TEMP TABLE _t76_o2 AS SELECT rpc_shop_create_order('zz-store', t76_key(2), jsonb_build_array(t76_line('ELB-A-SYH-M', 1)), t76_cust('İkinci Müşteri', '+90 533 000 00 02', NULL)) AS r;
GRANT SELECT ON _t76_o2 TO authenticated, anon;
SELECT t_check('T76c6 a second customer takes the last A black M (available 1 → 0)',
  (SELECT r ->> 'order_number' = 'WEB-' || (SELECT yr FROM _t76)::text || '-000002' FROM _t76_o2)
  AND (SELECT r -> (t75_vid('ELB-A-SYH-M')::text) ->> 'state' = 'sold_out' FROM rpc_shop_availability('zz-store', ARRAY[t75_vid('ELB-A-SYH-M')]) r),
  (SELECT r::text FROM _t76_o2) || ' | ' || (SELECT r::text FROM rpc_shop_availability('zz-store', ARRAY[t75_vid('ELB-A-SYH-M')]) r));
SELECT t_err('T76c7 a third checkout for the same unit is refused (last unit)', $q$ SELECT rpc_shop_create_order('zz-store', t76_key(3), jsonb_build_array(t76_line('ELB-A-SYH-M', 1)), t76_cust()) $q$, 'INSUFFICIENT');
SELECT t_check('T76c8 an international phone (+90 533…) is kept and normalised without rewriting',
  t76_q($q$ SELECT phone = '+90 533 000 00 02' AND phone_normalized = '905330000002' AND email IS NULL FROM storefront_orders WHERE id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000002') $q$));

-- ---------------- tracking (anon) ----------------
SELECT t_check('T76d the customer reads own order by token: number, status, items, pickup branch, expiry, can_cancel; no internals',
  (SELECT r ->> 'order_number' LIKE 'WEB-%' AND r ->> 'status' = 'pending_confirmation' AND jsonb_array_length(r -> 'items') = 2 AND r -> 'pickup' ->> 'branch' = 'Merkez'
          AND (r ->> 'can_cancel')::boolean AND (r ->> 'reservation_active')::boolean AND r -> 'items' -> 0 ? 'labels'
          AND NOT (r ? 'id') AND NOT (r ? 'business_id') AND NOT (r ? 'branch_id') AND NOT (r ? 'actors') AND NOT (r ? 'events') AND NOT (r ? 'items_live')
   FROM rpc_shop_order('zz-store', (SELECT r ->> 'tracking_token' FROM _t76_o1)) r));
SELECT t_check('T76d2 a wrong token, the order number, or the token on another store yields nothing',
  rpc_shop_order('zz-store', repeat('0', 64)) IS NULL AND rpc_shop_order('zz-store', 'WEB-2026-000001') IS NULL AND rpc_shop_order('nope', (SELECT r ->> 'tracking_token' FROM _t76_o1)) IS NULL);
SELECT t_err('T76d3 anon cannot read the order table', $q$ SELECT count(*) FROM storefront_orders $q$, '42501');
SELECT t_err('T76d4 nor the items', $q$ SELECT count(*) FROM storefront_order_items $q$, '42501');
SELECT t_err('T76d5 nor list orders', $q$ SELECT rpc_online_orders(t_get('bizS')) $q$, '42501');
SELECT t_err('T76d6 nor confirm', $q$ SELECT rpc_online_order_confirm(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) $q$, '42501');
SELECT t_err('T76d7 nor mark ready', $q$ SELECT rpc_online_order_ready(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) $q$, '42501');
SELECT t_err('T76d8 nor create a sale', $q$ SELECT rpc_pos_complete_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'), gen_random_uuid(), '[]'::jsonb, gen_random_uuid()) $q$, '42501');
SELECT t_err('T76d9 nor touch reservations directly', $q$ UPDATE reservations SET expires_at = now() + interval '30 days' WHERE source = 'online' $q$, '42501');
SELECT t_err('T76d10 nor insert an order', $q$ INSERT INTO storefront_orders (business_id, storefront_id, branch_id, order_number, customer_name, phone, phone_normalized, currency, subtotal, total, item_count, tracking_token_hash, idempotency_key_hash) VALUES (t_get('bizS'), gen_random_uuid(), t_get('brS'), 'X', 'x y', '05321112233', '905321112233', 'TRY', 0, 0, 1, repeat('a', 64), repeat('b', 64)) $q$, '42501');
RESET ROLE;

-- ---------------- merchant: who sees what ----------------
SELECT t_login('a9');
SELECT t_err('T76e stock_staff has no order access (PII)', $q$ SELECT rpc_online_orders(t_get('bizS')) $q$, 'FORBIDDEN');
SELECT t_err('T76e2 nor detail', $q$ SELECT rpc_online_order_detail(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) $q$, 'FORBIDDEN');
SELECT t_err('T76e3 nor the POS preload', $q$ SELECT rpc_pos_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('u1');
SELECT t_err('T76e4 another tenant''s owner cannot list (business_id injection)', $q$ SELECT rpc_online_orders(t_get('bizS')) $q$, 'FORBIDDEN');
SELECT t_err('T76e5 nor read a detail', $q$ SELECT rpc_online_order_detail(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) $q$, 'FORBIDDEN');
SELECT t_err('T76e6 nor preload it in POS', $q$ SELECT rpc_pos_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) $q$, 'NOT_FOUND');
SELECT t_err('T76e7 nor convert it', $q$ SELECT rpc_pos_complete_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'), gen_random_uuid(), '[]'::jsonb, gen_random_uuid()) $q$, 'NOT_FOUND');
SELECT t_logout();
SELECT t_login('a12');
SELECT t_check('T76f the owner lists 2 new orders with counts; search by phone digits works; detail carries PII, live items, hold, events',
  (SELECT (r ->> 'total')::int = 2 AND (r -> 'counts' ->> 'new')::int = 2 AND r -> 'rows' -> 0 ->> 'phone' IS NOT NULL FROM rpc_online_orders(t_get('bizS'), 'new') r)
  AND (SELECT (r ->> 'total')::int = 1 FROM rpc_online_orders(t_get('bizS'), NULL, '0533 000') r)
  AND (SELECT r ->> 'customer_name' = 'Misafir Müşteri' AND jsonb_array_length(r -> 'items_live') = 2 AND (r -> 'reservation' ->> 'active')::boolean AND jsonb_array_length(r -> 'events') = 1 AND r ->> 'note' = 'Öğleden sonra alırım'
       FROM rpc_online_order_detail(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) r));
SELECT t_err('T76f2 the owner cannot inject another business id', $q$ SELECT rpc_online_orders(t_get('biz')) $q$, 'FORBIDDEN');
SELECT t_err('T76f3 the status filter is validated', $q$ SELECT rpc_online_orders(t_get('bizS'), 'paid') $q$, 'INVALID_STATUS');
SELECT t_err('T76f4 ready needs confirmation first', $q$ SELECT rpc_online_order_ready(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) $q$, 'INVALID_STATE');
SELECT t_err('T76f5 POS conversion needs confirmation first', $q$ SELECT rpc_pos_complete_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'), gen_random_uuid(), '[]'::jsonb, gen_random_uuid()) $q$, 'INVALID_STATE');
SELECT t_check('T76f6 confirm: confirmed_at/by, hold refreshed to a full hold window, event; replay',
  (SELECT r ->> 'status' = 'confirmed' AND NOT (r ->> 'replayed')::boolean FROM rpc_online_order_confirm(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) r)
  AND t76_q($q$ (SELECT status = 'confirmed' AND confirmed_at IS NOT NULL AND confirmed_by = t_get('a12') FROM storefront_orders WHERE id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'))
                AND (SELECT expires_at BETWEEN now() + interval '1439 minutes' AND now() + interval '1441 minutes' FROM reservations WHERE storefront_order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) $q$)
  AND (SELECT (r ->> 'replayed')::boolean FROM rpc_online_order_confirm(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) r));
SELECT t_logout();
SET ROLE anon;
SELECT t_check('T76f7 the customer sees confirmed and may no longer cancel',
  (SELECT r ->> 'status' = 'confirmed' AND NOT (r ->> 'can_cancel')::boolean FROM rpc_shop_order('zz-store', (SELECT r ->> 'tracking_token' FROM _t76_o1)) r));
SELECT t_err('T76f8 customer cancellation after confirmation is refused', $q$ SELECT rpc_shop_cancel_order('zz-store', (SELECT r ->> 'tracking_token' FROM _t76_o1), 'vazgectim') $q$, 'CANCEL_NOT_ALLOWED');
RESET ROLE;
SELECT t_login('a11');
SELECT t_check('T76f9 the manager marks it ready (operational) and the customer timeline shows it',
  (SELECT r ->> 'status' = 'ready' FROM rpc_online_order_ready(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) r)
  AND t76_q($q$ (SELECT status = 'ready' AND ready_by = t_get('a11') FROM storefront_orders WHERE id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) $q$));
SELECT t_err('T76f10 a manager cannot cancel without a reason', $q$ SELECT rpc_online_order_cancel(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000002'), ' ') $q$, 'REASON_REQUIRED');
SELECT t_logout();

-- ---------------- customer cancellation of the second (pending) order ----------------
SET ROLE anon;
CREATE TEMP TABLE _t76_o2tok AS SELECT r ->> 'tracking_token' AS tok FROM _t76_o2;
CREATE TEMP TABLE _t76_c2 AS SELECT rpc_shop_cancel_order('zz-store', (SELECT tok FROM _t76_o2tok), 'başka bir şey buldum') AS r;
GRANT SELECT ON _t76_c2 TO anon;
SELECT t_check('T76g the customer cancels the pending order: hold released, availability restored (A black M 0→1), no movement, event by customer; replay',
  (SELECT r ->> 'status' = 'cancelled' AND NOT (r ->> 'replayed')::boolean FROM _t76_c2)
  AND (SELECT (r -> (t75_vid('ELB-A-SYH-M')::text) ->> 'available')::int = 1 FROM rpc_shop_availability('zz-store', ARRAY[t75_vid('ELB-A-SYH-M')]) r)
  AND t76_q($q$ (SELECT status = 'cancelled' AND cancelled_by_customer AND cancel_reason = 'başka bir şey buldum' FROM storefront_orders WHERE id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000002'))
                AND (SELECT status = 'cancelled' FROM reservations WHERE storefront_order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000002'))
                AND (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizS')) = (SELECT mov FROM _t76) $q$)
  AND (SELECT (r ->> 'replayed')::boolean FROM rpc_shop_cancel_order('zz-store', (SELECT tok FROM _t76_o2tok)) r),
  t76_txt($q$ SELECT (SELECT status::text || '/' || cancelled_by_customer::text || '/' || COALESCE(cancel_reason, 'null') FROM storefront_orders WHERE order_number LIKE 'WEB-%000002') || ' res=' || (SELECT string_agg(status::text, ',') FROM reservations WHERE storefront_order_id = (SELECT id FROM storefront_orders WHERE order_number LIKE 'WEB-%000002')) || ' avail=' || fn_shop_available(t_get('bizS'), t_get('brS'), t75_vid('ELB-A-SYH-M'))::text $q$));
SELECT t_check('T76g2 the tracking page of the cancelled order says cancelled by the customer', (SELECT r ->> 'status' = 'cancelled' AND (r ->> 'cancelled_by_customer')::boolean FROM rpc_shop_order('zz-store', (SELECT tok FROM _t76_o2tok)) r));
RESET ROLE;

-- ---------------- merchant cancellation + expiry + re-reserve ----------------
SET ROLE anon;
SELECT rpc_shop_create_order('zz-store', t76_key(4), jsonb_build_array(t76_line('TRK-B-STD', 1)), t76_cust('Üçüncü', '0555 000 00 03', NULL)) ->> 'order_number' AS o3;
SELECT rpc_shop_create_order('zz-store', t76_key(5), jsonb_build_array(t76_line('TRK-B-STD', 1)), t76_cust('Dördüncü', '0555 000 00 04', NULL)) ->> 'order_number' AS o4;
RESET ROLE;
SELECT t_login('a12');
SELECT t_check('T76h the owner cancels order 3 with a reason: hold released, event carries the reason, replay',
  (SELECT r ->> 'status' = 'cancelled' FROM rpc_online_order_cancel(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000003'), 'müşteri aradı, vazgeçti') r)
  AND t76_q($q$ (SELECT status = 'cancelled' AND cancelled_by = t_get('a12') AND NOT cancelled_by_customer FROM storefront_orders WHERE id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000003'))
                AND (SELECT status = 'cancelled' AND cancelled_by = t_get('a12') FROM reservations WHERE storefront_order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000003')) $q$)
  AND (SELECT (r ->> 'replayed')::boolean FROM rpc_online_order_cancel(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000003'), 'tekrar') r));
SELECT t_logout();
-- fixture: order 4's hold lapses (the reservation guard allows expires_at to move while active)
UPDATE reservations SET expires_at = now() - interval '1 minute' WHERE storefront_order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004');
SET ROLE anon;
SELECT t_check('T76h2 a lapsed hold reads as expired to the customer before any sweep, and no longer reduces availability (B 10 − 2 held by order 1 = 8)',
  (SELECT r ->> 'status' = 'expired' AND NOT (r ->> 'reservation_active')::boolean FROM rpc_shop_order('zz-store', t76_txt($q$ SELECT encode(sha256(convert_to('token:' || t76_key(5) || ':' || (SELECT id::text FROM storefronts WHERE slug = 'zz-store'), 'UTF8')), 'hex') $q$)) r)
  AND (SELECT (r -> (t75_vid('TRK-B-STD')::text) ->> 'available')::int = 8 FROM rpc_shop_availability('zz-store', ARRAY[t75_vid('TRK-B-STD')]) r));
RESET ROLE;
SELECT t_login('a12');
SELECT t_err('T76h3 confirming a lapsed order is refused', $q$ SELECT rpc_online_order_confirm(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004')) $q$, 'RESERVATION_EXPIRED');
SELECT t_check('T76h4 the list shows it as expired (derived) and the sweep materialises exactly it; a second sweep does nothing',
  (SELECT r -> 'rows' -> 0 ->> 'public_status' = 'expired' FROM rpc_online_orders(t_get('bizS'), NULL, 'Dördüncü') r)
  AND (SELECT (r ->> 'expired')::int = 1 FROM rpc_online_orders_sweep(t_get('bizS')) r)
  AND t76_q($q$ (SELECT status = 'expired' AND expired_at IS NOT NULL FROM storefront_orders WHERE id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004'))
                AND (SELECT status = 'expired' FROM reservations WHERE storefront_order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004')) $q$)
  AND (SELECT (r ->> 'expired')::int = 0 FROM rpc_online_orders_sweep(t_get('bizS')) r),
  (SELECT r::text FROM rpc_online_orders(t_get('bizS'), NULL, 'Dördüncü') r) || ' | ' || t76_txt($q$ SELECT string_agg(o.order_number || ':' || o.status::text, ',') FROM storefront_orders o WHERE o.business_id = t_get('bizS') $q$));
SELECT t_check('T76h5 re-reserve reopens the expired order with a fresh hold (stock re-checked), then it can be confirmed',
  (SELECT r ->> 'status' = 'pending_confirmation' FROM rpc_online_order_rereserve(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004')) r)
  AND t76_q($q$ (SELECT count(*) FROM reservations WHERE hold_name = 'Dördüncü') = 2 AND (SELECT r.status = 'active' AND r.expires_at > now() FROM fn_online_order_reservation(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004')) r)
                AND (SELECT count(*) FROM storefront_order_events WHERE order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004') AND event = 'rereserved') = 1 $q$)
  AND (SELECT r ->> 'status' = 'confirmed' FROM rpc_online_order_confirm(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004')) r));
SELECT t_err('T76h6 re-reserving a live hold is refused', $q$ SELECT rpc_online_order_rereserve(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004')) $q$, 'HOLD_ACTIVE');
SELECT t_logout();
-- guards even for the superuser
SELECT t_err('T76h7 a cancelled order never moves', $q$ UPDATE storefront_orders SET status = 'confirmed' WHERE id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000003') $q$, 'ORDER_FINAL');
SELECT t_err('T76h8 orders are never deleted', $q$ DELETE FROM storefront_orders WHERE id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000003') $q$, 'ORDER_RETAINED');
SELECT t_err('T76h9 items are frozen', $q$ UPDATE storefront_order_items SET unit_price = 1 WHERE order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001') $q$, 'ORDER_ROW_FROZEN');
SELECT t_err('T76h10 the snapshot is locked', $q$ UPDATE storefront_orders SET total = 1, subtotal = 1 WHERE id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001') $q$, 'ORDER_SNAPSHOT_LOCKED');
SELECT t_err('T76h11 a sale can only be bound by the POS conversion', $q$ UPDATE storefront_orders SET converted_sale_id = (SELECT id FROM sales LIMIT 1) WHERE id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001') $q$, 'ORDER_SALE_ONLY_BY_POS');

-- ---------------- POS conversion (the one real sale) ----------------
WITH x AS (INSERT INTO cash_registers (business_id, branch_id, name) VALUES (t_get('bizS'), t_get('brS'), 'ZZ Kasa') RETURNING id) SELECT t_set('regS', id) FROM x;
-- price rule fixture: B's list price rises to 900 (order holds 800 → honoured 800); A's list falls to 1000 (order 1200 → charged 1000)
UPDATE products SET default_sale_price = 900 WHERE id = t75_pid('TRK-B');
UPDATE products SET default_sale_price = 1000 WHERE id = t75_pid('ELB-A');
SELECT t_login('a12');
SELECT t_set('sessS', rpc_open_register_session(t_get('regS'), '[{"currency":"TRY","amount":0}]'::jsonb));
SELECT t_check('T76i the POS preload carries the verified lines with the honoured price (B 800 of 900, A 1000 of 1200)',
  (SELECT r ->> 'order_number' LIKE 'WEB-%' AND (r ->> 'reservation_active')::boolean AND jsonb_array_length(r -> 'lines') = 2
          AND (SELECT (l ->> 'unit_price')::numeric = 800 AND (l ->> 'list_price')::numeric = 900 FROM jsonb_array_elements(r -> 'lines') l WHERE l ->> 'sku' = 'TRK-B-STD')
          AND (SELECT (l ->> 'unit_price')::numeric = 1000 AND (l ->> 'order_price')::numeric = 1200 FROM jsonb_array_elements(r -> 'lines') l WHERE l ->> 'sku' = 'ELB-A-SYH-M')
   FROM rpc_pos_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001')) r));
SELECT t_err('T76i2 conversion needs a real session', $q$ SELECT rpc_pos_complete_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'), gen_random_uuid(), '[{"method":"cash","currency":"TRY","amount":2600}]'::jsonb, gen_random_uuid()) $q$, 'INVALID_REGISTER_SESSION');
SELECT t_err('T76i3 conversion needs the client transaction id', $q$ SELECT rpc_pos_complete_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'), t_get('sessS'), '[{"method":"cash","currency":"TRY","amount":2600}]'::jsonb, NULL) $q$, 'CLIENT_TRANSACTION_REQUIRED');
SELECT t_err('T76i4 the existing payment rule applies (short payment)', $q$ SELECT rpc_pos_complete_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'), t_get('sessS'), '[{"method":"cash","currency":"TRY","amount":100}]'::jsonb, gen_random_uuid()) $q$, 'PAYMENT_SHORT');
SELECT t_set('ctidS', gen_random_uuid());
CREATE TEMP TABLE _t76_sale AS SELECT rpc_pos_complete_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'), t_get('sessS'), '[{"method":"cash","currency":"TRY","amount":2600}]'::jsonb, t_get('ctidS'), t_get('a12'), NULL) AS r;
SELECT t_check('T76i5 one real sale through the sale core: total 2600 (1000 + 2×800), not replayed, order number attached',
  (SELECT (r ->> 'total')::numeric = 2600 AND NOT (r ->> 'replayed')::boolean AND r ->> 'order_number' LIKE 'WEB-%' AND r ->> 'sale_number' LIKE 'S-%' FROM _t76_sale));
SELECT t_check('T76i6 the order is completed and bound to that sale; the hold is converted and linked; events converted + completed',
  t76_q($q$ (SELECT o.status = 'completed' AND o.completed_at IS NOT NULL AND o.converted_sale_id = (SELECT (r ->> 'sale_id')::uuid FROM _t76_sale) FROM storefront_orders o WHERE o.id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'))
            AND (SELECT status = 'converted' AND converted_to_sale_id = (SELECT (r ->> 'sale_id')::uuid FROM _t76_sale) AND fulfilled_at IS NOT NULL FROM reservations WHERE storefront_order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'))
            AND (SELECT count(*) FROM storefront_order_events WHERE order_id = t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001') AND event IN ('converted','completed')) = 2 $q$));
SELECT t_check('T76i7 exactly one sale, one movement per line, COGS from the historical pool, on_hand decremented once (A black M 2→1, B 10→8)',
  t76_q($q$ (SELECT count(*) FROM sales WHERE business_id = t_get('bizS')) = (SELECT sales FROM _t76) + 1
            AND (SELECT count(*) FROM inventory_movements WHERE business_id = t_get('bizS')) = (SELECT mov FROM _t76) + 2
            AND (SELECT count(*) FROM sale_items si JOIN sale_item_costs c ON c.sale_item_id = si.id WHERE si.sale_id = (SELECT (r ->> 'sale_id')::uuid FROM _t76_sale) AND c.unit_cost_at_sale > 0) = 2
            AND fn_bucket_qty(t_get('bizS'), t_get('brS'), t75_vid('ELB-A-SYH-M'), 'sellable') = 1 AND fn_bucket_qty(t_get('bizS'), t_get('brS'), t75_vid('TRK-B-STD'), 'sellable') = 8
            AND (SELECT count(*) FROM sale_items WHERE sale_id = (SELECT (r ->> 'sale_id')::uuid FROM _t76_sale) AND unit_price_at_sale = 800) = 1
            AND (SELECT count(*) FROM sale_items WHERE sale_id = (SELECT (r ->> 'sale_id')::uuid FROM _t76_sale) AND unit_price_at_sale = 1000) = 1 $q$));
SELECT t_check('T76i8 a retry with the same client transaction id replays the sale; a new id on the completed order replays too — never a second sale',
  (SELECT (r ->> 'replayed')::boolean AND r ->> 'sale_id' = (SELECT r ->> 'sale_id' FROM _t76_sale) FROM rpc_pos_complete_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'), t_get('sessS'), '[{"method":"cash","currency":"TRY","amount":2600}]'::jsonb, t_get('ctidS')) r)
  AND (SELECT (r ->> 'replayed')::boolean AND r ->> 'sale_id' = (SELECT r ->> 'sale_id' FROM _t76_sale) FROM rpc_pos_complete_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'), t_get('sessS'), '[{"method":"cash","currency":"TRY","amount":2600}]'::jsonb, gen_random_uuid()) r)
  AND t76_q($q$ (SELECT count(*) FROM sales WHERE business_id = t_get('bizS')) = (SELECT sales FROM _t76) + 1 $q$));
SELECT t_check('T76i9 the sale carries the online-order note and the sales report counts only the real sale (net 2600), never the order total',
  t76_q($q$ (SELECT note LIKE 'Online sipariş WEB-%' FROM sales WHERE id = (SELECT (r ->> 'sale_id')::uuid FROM _t76_sale)) $q$)
  AND (SELECT (j -> 'current' ->> 'transactions')::int = 1 AND (j -> 'current' ->> 'net_sales')::numeric = 2600
       FROM (SELECT rpc_report_overview(t_get('bizS'), (now() AT TIME ZONE 'Europe/Istanbul')::date, (now() AT TIME ZONE 'Europe/Istanbul')::date, NULL, (now() AT TIME ZONE 'Europe/Istanbul')::date - 1, (now() AT TIME ZONE 'Europe/Istanbul')::date - 1) AS j) x));
SELECT t_err('T76i10 a completed order cannot be cancelled', $q$ SELECT rpc_online_order_cancel(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000001'), 'geç kaldı') $q$, 'INVALID_STATE');
SELECT t_logout();
UPDATE products SET default_sale_price = 800 WHERE id = t75_pid('TRK-B');
UPDATE products SET default_sale_price = 1200 WHERE id = t75_pid('ELB-A');
SET ROLE anon;
SELECT t_check('T76i11 the customer sees completed; the sale id is not on the public page',
  (SELECT r ->> 'status' = 'completed' AND NOT (r ? 'converted_sale') AND NOT (r::text LIKE '%sale_id%') FROM rpc_shop_order('zz-store', (SELECT r ->> 'tracking_token' FROM _t76_o1)) r));
RESET ROLE;
-- conversion vs cancel: order 4 is confirmed; a manager cancels it, then a conversion attempt finds no valid state and creates nothing
SELECT t_login('a9');
SELECT t_err('T76j stock_staff cannot cancel an order', $q$ SELECT rpc_online_order_cancel(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004'), 'x y z') $q$, 'FORBIDDEN');
SELECT t_err('T76j2 stock_staff cannot convert', $q$ SELECT rpc_pos_complete_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004'), t_get('sessS'), '[{"method":"cash","currency":"TRY","amount":800}]'::jsonb, gen_random_uuid()) $q$, 'FORBIDDEN');
SELECT t_logout();
SELECT t_login('a12');
SELECT t_ok('T76j3 the owner cancels the confirmed order 4', $q$ SELECT rpc_online_order_cancel(t_get('bizS'), t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004'), 'müşteri gelmedi') $q$);
SELECT t_err('T76j4 converting the cancelled order creates nothing', $q$ SELECT rpc_pos_complete_online_order(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004'), t_get('sessS'), '[{"method":"cash","currency":"TRY","amount":800}]'::jsonb, gen_random_uuid()) $q$, 'INVALID_STATE');
SELECT t_check('T76j5 still exactly one sale for the tenant; the hold of order 4 is cancelled and B is back to 8 available (10 − 2 sold)',
  t76_q($q$ (SELECT count(*) FROM sales WHERE business_id = t_get('bizS')) = (SELECT sales FROM _t76) + 1 AND (SELECT r.status = 'cancelled' FROM fn_online_order_reservation(t76_order('WEB-' || (SELECT yr FROM _t76)::text || '-000004')) r)
            AND fn_shop_available(t_get('bizS'), t_get('brS'), t75_vid('TRK-B-STD')) = 8 $q$));
SELECT t_logout();
SELECT t_check('T76k TLC: no online order, no online hold, no sale from any of this',
  (SELECT count(*) FROM storefront_orders WHERE business_id = t_get('biz')) = 0 AND (SELECT count(*) FROM reservations WHERE business_id = t_get('biz') AND source = 'online') = 0);

-- ============================================================
-- SUMMARY
-- ============================================================
DO $$
DECLARE v_fail INT; v_pass INT; r RECORD;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM _tr;
  RAISE NOTICE '============================================================';
  RAISE NOTICE 'BoutiqueOS Rev 3 verification: % passed, % failed', v_pass, v_fail;
  FOR r IN SELECT name, detail FROM _tr WHERE NOT ok ORDER BY n LOOP
    RAISE NOTICE '  FAILED: % — %', r.name, r.detail;
  END LOOP;
  RAISE NOTICE '============================================================';
  IF v_fail > 0 THEN
    RAISE EXCEPTION 'VERIFICATION FAILED: % test(s) failed', v_fail;
  END IF;
END $$;

ROLLBACK;
