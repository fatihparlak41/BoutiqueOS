-- Phase 15B-0 • count cost-bridge races • setup (run as postgres, COMMITS)
-- One manager, one variant WITHOUT any cost basis at br1, a cycle count counted = 3 with an
-- explicit unit cost 120 (documented_purchase), reviewed. Second count prepared for the
-- stale scenarios.
\set ON_ERROR_STOP on
BEGIN;
DROP TABLE IF EXISTS zz_scc_ctx;
CREATE TABLE zz_scc_ctx (k TEXT PRIMARY KEY, v UUID);
INSERT INTO auth.users (id, instance_id, aud, role, email)
VALUES ('cccccccc-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cc-manager2@tlc.test')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES ('cccccccc-0000-4000-8000-000000000003') ON CONFLICT DO NOTHING;
INSERT INTO business_members (business_id, user_id, role)
VALUES ('b0000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000003', 'manager')
ON CONFLICT DO NOTHING;
WITH p AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status)
           VALUES ('b0000000-0000-4000-8000-000000000001', 'Açılış Yarış Ürünü', 'SCC-' || to_char(clock_timestamp(),'HH24MISSMS'), 500, 'active') RETURNING id),
     v1 AS (INSERT INTO product_variants (product_id, sku) SELECT p.id, 'SCC-' || to_char(clock_timestamp(),'HH24MISSMS') || '-1' FROM p RETURNING id)
INSERT INTO zz_scc_ctx SELECT 'variant', id FROM v1;
WITH p AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status)
           VALUES ('b0000000-0000-4000-8000-000000000001', 'Açılış Yarış Ürünü 2', 'SCD-' || to_char(clock_timestamp(),'HH24MISSMS'), 500, 'active') RETURNING id),
     v2 AS (INSERT INTO product_variants (product_id, sku) SELECT p.id, 'SCD-' || to_char(clock_timestamp(),'HH24MISSMS') || '-1' FROM p RETURNING id)
INSERT INTO zz_scc_ctx SELECT 'variant2', id FROM v2;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000003","role":"authenticated"}', true);
INSERT INTO zz_scc_ctx SELECT 'count', rpc_stock_count_create('b0000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', 'cycle', 'cost-bridge race A/D');
SELECT rpc_stock_count_set_quantity((SELECT v FROM zz_scc_ctx WHERE k = 'count'), (SELECT v FROM zz_scc_ctx WHERE k = 'variant'), 'sellable', 3, gen_random_uuid());
SELECT rpc_stock_count_review((SELECT v FROM zz_scc_ctx WHERE k = 'count'));
SELECT rpc_stock_count_set_line_cost((SELECT id FROM stock_count_lines WHERE stock_count_id = (SELECT v FROM zz_scc_ctx WHERE k = 'count')), 120, 'documented_purchase', 'yarış fixture');
SELECT rpc_stock_count_review((SELECT v FROM zz_scc_ctx WHERE k = 'count'));
-- second count for the stale scenarios (B, C)
INSERT INTO zz_scc_ctx SELECT 'count2', rpc_stock_count_create('b0000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', 'cycle', 'cost-bridge race B/C');
SELECT rpc_stock_count_set_quantity((SELECT v FROM zz_scc_ctx WHERE k = 'count2'), (SELECT v FROM zz_scc_ctx WHERE k = 'variant2'), 'sellable', 2, gen_random_uuid());
SELECT rpc_stock_count_review((SELECT v FROM zz_scc_ctx WHERE k = 'count2'));
SELECT rpc_stock_count_set_line_cost((SELECT id FROM stock_count_lines WHERE stock_count_id = (SELECT v FROM zz_scc_ctx WHERE k = 'count2')), 90, 'owner_declared_opening_cost', NULL);
SELECT rpc_stock_count_review((SELECT v FROM zz_scc_ctx WHERE k = 'count2'));
COMMIT;
SELECT k, v FROM zz_scc_ctx ORDER BY k;
SELECT status, count_number, review_hash IS NOT NULL AS hashed FROM stock_counts WHERE id IN (SELECT v FROM zz_scc_ctx WHERE k IN ('count','count2'));
