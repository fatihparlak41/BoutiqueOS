-- Phase 8A • receipt double-post race • setup (run as postgres, COMMITS)
\set ON_ERROR_STOP on
BEGIN;
DROP TABLE IF EXISTS zz_gr_ctx;
CREATE TABLE zz_gr_ctx (k TEXT PRIMARY KEY, v UUID);
INSERT INTO auth.users (id, instance_id, aud, role, email)
VALUES ('cccccccc-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cc-manager@tlc.test')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES ('cccccccc-0000-4000-8000-000000000002') ON CONFLICT DO NOTHING;
INSERT INTO business_members (business_id, user_id, role)
VALUES ('b0000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000002', 'manager')
ON CONFLICT DO NOTHING;
WITH s AS (INSERT INTO suppliers (business_id, name) VALUES ('b0000000-0000-4000-8000-000000000001', 'GR Race Supplier ' || clock_timestamp()::text) RETURNING id),
     p AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status)
           VALUES ('b0000000-0000-4000-8000-000000000001', 'Mal Kabul Yarış Ürünü', 'GRR-' || to_char(clock_timestamp(),'HH24MISSMS'), 900, 'active') RETURNING id),
     v AS (INSERT INTO product_variants (product_id, sku) SELECT p.id, 'GRR-' || to_char(clock_timestamp(),'HH24MISSMS') || '-1' FROM p RETURNING id)
INSERT INTO zz_gr_ctx SELECT 'variant', id FROM v UNION ALL SELECT 'supplier', id FROM s;
COMMIT;
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000002","role":"authenticated"}', true);
INSERT INTO zz_gr_ctx SELECT 'gr', rpc_create_goods_receipt('b1000000-0000-4000-8000-000000000001', (SELECT v FROM zz_gr_ctx WHERE k='supplier'), 'TRY', 1, CURRENT_DATE, 'RACE', NULL);
INSERT INTO goods_receipt_items (goods_receipt_id, variant_id, quantity, unit_cost) VALUES ((SELECT v FROM zz_gr_ctx WHERE k='gr'), (SELECT v FROM zz_gr_ctx WHERE k='variant'), 4, 100);
INSERT INTO goods_receipt_charges (goods_receipt_id, kind, amount, liability_mode) VALUES ((SELECT v FROM zz_gr_ctx WHERE k='gr'), 'freight', 40, 'add_to_invoice');
SELECT * FROM rpc_goods_receipt_review((SELECT v FROM zz_gr_ctx WHERE k='gr'));
COMMIT;
SELECT k, v FROM zz_gr_ctx ORDER BY k;
