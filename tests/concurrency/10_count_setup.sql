-- Phase 7A • double-post race • setup (run as postgres, COMMITS)
-- One manager user, one variant with 5 units @100 at br1, a FULL stock count reviewed with counted = 3.
\set ON_ERROR_STOP on
BEGIN;
DROP TABLE IF EXISTS zz_sc_ctx;
CREATE TABLE zz_sc_ctx (k TEXT PRIMARY KEY, v UUID);
INSERT INTO auth.users (id, instance_id, aud, role, email)
VALUES ('cccccccc-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cc-manager@tlc.test')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES ('cccccccc-0000-4000-8000-000000000002') ON CONFLICT DO NOTHING;
INSERT INTO business_members (business_id, user_id, role)
VALUES ('b0000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000002', 'manager')
ON CONFLICT DO NOTHING;
WITH p AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status)
           VALUES ('b0000000-0000-4000-8000-000000000001', 'Sayım Yarış Ürünü', 'SCR-' || to_char(clock_timestamp(),'HH24MISSMS'), 500, 'active') RETURNING id),
     v AS (INSERT INTO product_variants (product_id, sku) SELECT p.id, 'SCR-' || to_char(clock_timestamp(),'HH24MISSMS') || '-1' FROM p RETURNING id)
INSERT INTO zz_sc_ctx SELECT 'variant', id FROM v;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000002","role":"authenticated"}', true);
SELECT rpc_post_inventory_adjustment('b0000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001',
  (SELECT v FROM zz_sc_ctx WHERE k = 'variant'), 'sellable', 5, 'sayım yarış fixture', 'manual_cost', 100);
INSERT INTO zz_sc_ctx SELECT 'count', rpc_stock_count_create('b0000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', 'cycle', 'double-post race');
SELECT rpc_stock_count_set_quantity((SELECT v FROM zz_sc_ctx WHERE k = 'count'), (SELECT v FROM zz_sc_ctx WHERE k = 'variant'), 'sellable', 3, gen_random_uuid());
SELECT rpc_stock_count_review((SELECT v FROM zz_sc_ctx WHERE k = 'count'));
COMMIT;
SELECT k, v FROM zz_sc_ctx ORDER BY k;
SELECT status, count_number FROM stock_counts WHERE id = (SELECT v FROM zz_sc_ctx WHERE k = 'count');
