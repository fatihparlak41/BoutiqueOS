-- Phase 9B concurrency setup (run AFTER 00_setup.sql, as postgres, COMMITS):
-- the single unit is sold to a customer; a replacement variant with 2 units is added.
-- The racing sessions then try to exchange that ONE sold unit twice.
\set ON_ERROR_STOP on
BEGIN;
UPDATE business_members SET role = 'manager' WHERE user_id = 'cccccccc-0000-4000-8000-000000000001';
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000001","role":"authenticated"}', true);
INSERT INTO zz_cc_ctx
SELECT 'sale', (rpc_pos_complete_sale((SELECT v FROM zz_cc_ctx WHERE k='session'),
  jsonb_build_array(jsonb_build_object('variant_id', (SELECT v FROM zz_cc_ctx WHERE k='variant'), 'quantity', 1)),
  jsonb_build_array(jsonb_build_object('method','cash','currency','TRY','amount',1000)),
  md5((SELECT v FROM zz_cc_ctx WHERE k='variant')::text || 'ret-setup-sale')::uuid) ->> 'sale_id')::uuid;
INSERT INTO zz_cc_ctx SELECT 'sale_item', id FROM sale_items WHERE sale_id = (SELECT v FROM zz_cc_ctx WHERE k='sale');
WITH p AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status)
           VALUES ('b0000000-0000-4000-8000-000000000001', 'Değişim Elbise', 'CX-' || to_char(clock_timestamp(),'HH24MISSMS'), 1000, 'active') RETURNING id),
     v AS (INSERT INTO product_variants (product_id, sku) SELECT p.id, 'CX-' || to_char(clock_timestamp(),'HH24MISSMS') || '-1' FROM p RETURNING id)
INSERT INTO zz_cc_ctx SELECT 'variant2', id FROM v;
SELECT rpc_post_inventory_adjustment('b0000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001',
  (SELECT v FROM zz_cc_ctx WHERE k='variant2'), 'sellable', 2, 'cc return fixture', 'manual_cost', 500);
COMMIT;
SELECT k, v FROM zz_cc_ctx ORDER BY k;
