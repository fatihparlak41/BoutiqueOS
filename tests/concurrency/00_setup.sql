-- BoutiqueOS Rev 3 • concurrency test • setup (run as postgres, COMMITS)
-- Creates: 1 sales_staff user, 1 product/variant with exactly ONE sellable unit, 1 open register session.
-- Context ids are stored in zz_cc_ctx for the two racing sessions.
\set ON_ERROR_STOP on
BEGIN;
DROP TABLE IF EXISTS zz_cc_ctx;
CREATE TABLE zz_cc_ctx (k TEXT PRIMARY KEY, v UUID);

INSERT INTO auth.users (id, instance_id, aud, role, email)
VALUES ('cccccccc-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cc-staff@tlc.test')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES ('cccccccc-0000-4000-8000-000000000001') ON CONFLICT DO NOTHING;
INSERT INTO business_members (business_id, user_id, role)
VALUES ('b0000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'sales_staff')
ON CONFLICT DO NOTHING;
INSERT INTO zz_cc_ctx VALUES ('staff', 'cccccccc-0000-4000-8000-000000000001');

WITH s AS (INSERT INTO suppliers (business_id, name) VALUES ('b0000000-0000-4000-8000-000000000001', 'CC Supplier ' || clock_timestamp()::text) RETURNING id),
     p AS (INSERT INTO products (business_id, supplier_id, name, sku_prefix, default_sale_price, status)
           SELECT 'b0000000-0000-4000-8000-000000000001', s.id, 'Son Birim Elbise', 'CC-' || to_char(clock_timestamp(),'HH24MISSMS'), 1000, 'active' FROM s RETURNING id),
     v AS (INSERT INTO product_variants (product_id, sku) SELECT p.id, 'CC-' || to_char(clock_timestamp(),'HH24MISSMS') || '-1' FROM p RETURNING id),
     g AS (INSERT INTO goods_receipts (business_id, branch_id, supplier_id, receipt_number, invoice_currency, exchange_rate)
           SELECT 'b0000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', s.id, 'GR-CC-' || to_char(clock_timestamp(),'HH24MISSMS'), 'TRY', 1 FROM s RETURNING id),
     gi AS (INSERT INTO goods_receipt_items (goods_receipt_id, variant_id, quantity, unit_cost) SELECT g.id, v.id, 1, 400 FROM g, v RETURNING goods_receipt_id, variant_id)
INSERT INTO zz_cc_ctx SELECT 'gr', goods_receipt_id FROM gi UNION ALL SELECT 'variant', variant_id FROM gi;
COMMIT;

-- post the receipt and open the register as the staff member (RPCs are SECURITY DEFINER; membership checks apply)
-- stock_staff/manager+ needed for receipt posting -> use a temporary manager grant, then revoke
BEGIN;
UPDATE business_members SET role = 'manager' WHERE user_id = 'cccccccc-0000-4000-8000-000000000001';
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000001","role":"authenticated"}', true);
SELECT rpc_post_goods_receipt((SELECT v FROM zz_cc_ctx WHERE k = 'gr'));
INSERT INTO zz_cc_ctx
SELECT 'session', rpc_open_register_session('e0000000-0000-4000-8000-000000000001', '[{"currency":"TRY","amount":0}]'::jsonb)
WHERE NOT EXISTS (SELECT 1 FROM register_sessions WHERE cash_register_id = 'e0000000-0000-4000-8000-000000000001' AND status = 'open');
INSERT INTO zz_cc_ctx SELECT 'session', id FROM register_sessions WHERE cash_register_id = 'e0000000-0000-4000-8000-000000000001' AND status = 'open'
ON CONFLICT (k) DO NOTHING;
UPDATE business_members SET role = 'sales_staff' WHERE user_id = 'cccccccc-0000-4000-8000-000000000001';
COMMIT;

SELECT k, v FROM zz_cc_ctx ORDER BY k;
SELECT on_hand_qty, total_value_base FROM variant_cost_pools WHERE variant_id = (SELECT v FROM zz_cc_ctx WHERE k='variant');
