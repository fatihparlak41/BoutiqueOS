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
SELECT t_check('T01 all 51 domain tables present',
  (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename NOT LIKE '\_%') = 51,
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
INSERT INTO goods_receipt_items (goods_receipt_id, variant_id, quantity, unit_cost) VALUES (t_get('gr3'), t_get('v1'), 4, 120);
SELECT t_ok ('T35aa rpc-created draft posts via existing rpc_post_goods_receipt', $q$ SELECT rpc_post_goods_receipt(t_get('gr3')) $q$);
SELECT t_err('T35ab second post of the same receipt rejected', $q$ SELECT rpc_post_goods_receipt(t_get('gr3')) $q$, 'INVALID_STATE');
SELECT t_err('T35ac empty rpc-created draft cannot be posted', $q$ SELECT rpc_post_goods_receipt(t_get('gr6')) $q$, 'EMPTY_DOCUMENT');
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
-- own register session and its cash stay readable (reconciliation)
SELECT t_check('T40w cashier sees the session they opened',
  t_count($q$ SELECT count(*) FROM register_sessions WHERE id = t_get('sess1') $q$) = 1);
SELECT t_check('T40x cashier sees the cash movements of their own session',
  t_count($q$ SELECT count(*) FROM cash_movements WHERE register_session_id = t_get('sess1') $q$) > 0);
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
