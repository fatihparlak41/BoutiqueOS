-- Phase 12A • purchase order races • setup (run as postgres, COMMITS)
\set ON_ERROR_STOP on
BEGIN;
DROP TABLE IF EXISTS zz_po_ctx;
CREATE TABLE zz_po_ctx (k TEXT PRIMARY KEY, v UUID);
INSERT INTO auth.users (id, instance_id, aud, role, email)
VALUES ('cccccccc-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cc-manager@tlc.test')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES ('cccccccc-0000-4000-8000-000000000002') ON CONFLICT DO NOTHING;
INSERT INTO business_members (business_id, user_id, role)
VALUES ('b0000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000002', 'manager')
ON CONFLICT DO NOTHING;
WITH s AS (INSERT INTO suppliers (business_id, name) VALUES ('b0000000-0000-4000-8000-000000000001', 'PO Race Supplier ' || clock_timestamp()::text) RETURNING id),
     p AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status)
           VALUES ('b0000000-0000-4000-8000-000000000001', 'Sipariş Yarış Ürünü', 'POR-' || to_char(clock_timestamp(),'HH24MISSMS'), 900, 'active') RETURNING id),
     v AS (INSERT INTO product_variants (product_id, sku) SELECT p.id, 'POR-' || to_char(clock_timestamp(),'HH24MISSMS') || '-1' FROM p RETURNING id)
INSERT INTO zz_po_ctx SELECT 'variant', id FROM v UNION ALL SELECT 'supplier', id FROM s;
COMMIT;
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000002","role":"authenticated"}', true);
-- A) a draft to approve twice
INSERT INTO zz_po_ctx SELECT 'po_a', rpc_po_create('b1000000-0000-4000-8000-000000000001', (SELECT v FROM zz_po_ctx WHERE k='supplier'), 'TRY');
SELECT rpc_po_upsert_line((SELECT v FROM zz_po_ctx WHERE k='po_a'), (SELECT v FROM zz_po_ctx WHERE k='variant'), 5, 100);
-- C) an ordered PO of 10 with two priced, reviewed draft receipts of 6 each (12 > 10)
INSERT INTO zz_po_ctx SELECT 'po_c', rpc_po_create('b1000000-0000-4000-8000-000000000001', (SELECT v FROM zz_po_ctx WHERE k='supplier'), 'TRY');
SELECT rpc_po_upsert_line((SELECT v FROM zz_po_ctx WHERE k='po_c'), (SELECT v FROM zz_po_ctx WHERE k='variant'), 10, 100);
SELECT rpc_po_approve((SELECT v FROM zz_po_ctx WHERE k='po_c'));
SELECT rpc_po_mark_ordered((SELECT v FROM zz_po_ctx WHERE k='po_c'));
INSERT INTO zz_po_ctx SELECT 'gr_a', rpc_po_create_receipt((SELECT v FROM zz_po_ctx WHERE k='po_c'), CURRENT_DATE, 'RACE-A');
INSERT INTO zz_po_ctx SELECT 'gr_b', rpc_po_create_receipt((SELECT v FROM zz_po_ctx WHERE k='po_c'), CURRENT_DATE, 'RACE-B');
SELECT rpc_goods_receipt_upsert_line((SELECT v FROM zz_po_ctx WHERE k='gr_a'), (SELECT v FROM zz_po_ctx WHERE k='variant'), 6, 100);
SELECT rpc_goods_receipt_upsert_line((SELECT v FROM zz_po_ctx WHERE k='gr_b'), (SELECT v FROM zz_po_ctx WHERE k='variant'), 6, 100);
SELECT * FROM rpc_goods_receipt_review((SELECT v FROM zz_po_ctx WHERE k='gr_a'));
SELECT * FROM rpc_goods_receipt_review((SELECT v FROM zz_po_ctx WHERE k='gr_b'));
-- D) an approved PO to mark ordered twice
INSERT INTO zz_po_ctx SELECT 'po_d', rpc_po_create('b1000000-0000-4000-8000-000000000001', (SELECT v FROM zz_po_ctx WHERE k='supplier'), 'TRY');
SELECT rpc_po_upsert_line((SELECT v FROM zz_po_ctx WHERE k='po_d'), (SELECT v FROM zz_po_ctx WHERE k='variant'), 1, 100);
SELECT rpc_po_approve((SELECT v FROM zz_po_ctx WHERE k='po_d'));
COMMIT;
SELECT k, v FROM zz_po_ctx ORDER BY k;
