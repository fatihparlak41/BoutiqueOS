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
SELECT t_check('T01 all 47 domain tables present',
  (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename NOT LIKE '\_%') = 47,
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
INSERT INTO goods_receipt_items (goods_receipt_id, variant_id, quantity, unit_cost) VALUES
  (t_get('gr1'), t_get('v1'), 10, 100), (t_get('gr1'), t_get('v2'), 5, 100), (t_get('gr1'), t_get('v3'), 3, 200);
SELECT t_ok('T08a stock_staff posts TRY goods receipt', $q$ SELECT rpc_post_goods_receipt(t_get('gr1')) $q$);
SELECT t_check('T08b stock_staff can read acquisition cost on receipt items', t_count($q$ SELECT count(*) FROM goods_receipt_items WHERE unit_cost_base IS NOT NULL $q$) = 3);
SELECT t_check('T08c stock_staff cannot read supplier ledger', t_count($q$ SELECT count(*) FROM supplier_account_entries $q$) = 0);
SELECT t_check('T08d stock_staff cannot read cost pools', t_count($q$ SELECT count(*) FROM variant_cost_pools $q$) = 0);
-- Posted receipts are protected by TWO layers. As a member, RLS (pol_gr_update USING status='draft')
-- filters the row out, so the UPDATE is a silent no-op (0 rows) rather than an error. The trigger
-- fires for RLS-bypassing roles; that half is asserted as postgres in T11d2 below.
SELECT t_check('T11d1 posted receipt not updatable by member (RLS: 0 rows)',
  t_count($q$ WITH u AS (UPDATE goods_receipts SET note = 'x' WHERE id = t_get('gr1') RETURNING 1) SELECT count(*) FROM u $q$) = 0);
SELECT t_err('T11e posted receipt items frozen', $q$ INSERT INTO goods_receipt_items (goods_receipt_id, variant_id, quantity, unit_cost) VALUES (t_get('gr1'), t_get('v1'), 1, 1) $q$, 'IMMUTABLE');
SELECT t_err('T11f posting twice rejected', $q$ SELECT rpc_post_goods_receipt(t_get('gr1')) $q$, 'INVALID_STATE');

WITH x AS (INSERT INTO goods_receipts (business_id, branch_id, supplier_id, receipt_number, invoice_currency, exchange_rate)
  VALUES (t_get('biz'), t_get('br1'), t_get('sup2'), 'GR-2026-0002', 'GBP', 40) RETURNING id) SELECT t_set('gr2', id) FROM x;
INSERT INTO goods_receipt_items (goods_receipt_id, variant_id, quantity, unit_cost) VALUES (t_get('gr2'), t_get('v1'), 10, 4);
SELECT t_ok('T12a stock_staff posts GBP goods receipt @40', $q$ SELECT rpc_post_goods_receipt(t_get('gr2')) $q$);
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
SELECT t_login('u3');
SELECT t_err('T22a sale without open register rejected', $q$ SELECT rpc_process_sale(t_get('biz'), t_get('br1'), gen_random_uuid(), t_json_items('v1','1',NULL), t_pay('cash','TRY',1000)) $q$, 'INVALID_REGISTER_SESSION');
SELECT t_set('sess1', rpc_open_register_session(t_get('reg'), '[{"currency":"TRY","amount":500}]'::jsonb));
SELECT t_err('T22b second open session on same register rejected', $q$ SELECT rpc_open_register_session(t_get('reg'), '[]'::jsonb) $q$, 'REGISTER_ALREADY_OPEN');
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
SELECT t_check('T21d cash overpayment => change 200 recorded and change_out movement',
  (SELECT change_given_base FROM sales WHERE id = t_get('sale5')) = 200
  AND (SELECT count(*) FROM cash_movements WHERE reference_id = t_get('sale5') AND movement_type = 'change_out' AND amount = -200) = 1);
SELECT t_logout();
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
SELECT t_err('T28a refund rejected by policy', $q$ SELECT rpc_process_return(t_get('biz'), t_get('br1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1)), 'refund', 'x', t_get('sess1'), 'cash') $q$, 'REFUND_NOT_ALLOWED');
SELECT t_err('T28b store credit rejected by policy', $q$ SELECT rpc_process_return(t_get('biz'), t_get('br1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1)), 'store_credit', 'x') $q$, 'STORE_CREDIT_NOT_ALLOWED');
SELECT t_err('T28c bare exchange return must use rpc_process_exchange', $q$ SELECT rpc_process_return(t_get('biz'), t_get('br1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1)), 'exchange', 'x') $q$, 'USE_EXCHANGE_RPC');
SELECT t_err('T24a sales_staff cannot choose sellable disposition', $q$ SELECT rpc_process_exchange(t_get('biz'), t_get('br1'), t_get('sess1'), t_get('sale1'), jsonb_build_array(jsonb_build_object('sale_item_id', t_get('si1'), 'quantity', 1, 'disposition', 'sellable')), t_json_items('v1','1',NULL), '[]'::jsonb) $q$, 'DISPOSITION_NOT_AUTHORIZED');
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
SELECT t_login('u3');
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
SELECT t_err('T34g goods receipt reversal is DEFERRED', $q$ SELECT rpc_reverse_goods_receipt(t_get('gr1')) $q$, 'NOT_IMPLEMENTED');
SELECT t_err('T34h owner cannot write supplier_returns directly', $q$ INSERT INTO supplier_returns (business_id, branch_id, supplier_id, return_number) VALUES (t_get('biz'), t_get('br1'), t_get('sup1'), 'SR-1') $q$, '42501');
SELECT t_logout();
SELECT t_err('T34i missing policy setting raises (no invented defaults)', $q$ SELECT fn_setting(t_get('bizB'), 'exchange_window_days') $q$, 'SETTING_MISSING');
SELECT t_check('T34j no unit_cost anywhere in member-readable tables',
  (SELECT count(*) FROM information_schema.columns WHERE table_schema='public'
     AND table_name IN ('inventory_movements','sale_items','return_items','sales','returns','reservations','reservation_items','stock_transfer_lines')
     AND column_name ILIKE '%cost%') = 0);

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
