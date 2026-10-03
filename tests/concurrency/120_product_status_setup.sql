-- Product status audit • two managers archive the same product at once • setup (run as postgres, COMMITS)
\set ON_ERROR_STOP on
BEGIN;
DROP TABLE IF EXISTS zz_pst_ctx;
CREATE TABLE zz_pst_ctx (k TEXT PRIMARY KEY, v UUID);
INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
  ('cccccccc-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cc-manager3@tlc.test'),
  ('cccccccc-0000-4000-8000-000000000005', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cc-manager4@tlc.test')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES ('cccccccc-0000-4000-8000-000000000004'), ('cccccccc-0000-4000-8000-000000000005') ON CONFLICT DO NOTHING;
INSERT INTO business_members (business_id, user_id, role) VALUES
  ('b0000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000004', 'manager'),
  ('b0000000-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000005', 'manager')
ON CONFLICT DO NOTHING;
WITH p AS (INSERT INTO products (business_id, name, sku_prefix, default_sale_price, status)
           VALUES ('b0000000-0000-4000-8000-000000000001', 'Durum Yarış Ürünü', 'PST-' || to_char(clock_timestamp(),'HH24MISSMS'), 500, 'active') RETURNING id)
INSERT INTO zz_pst_ctx SELECT 'product', id FROM p;
COMMIT;
SELECT k, v FROM zz_pst_ctx ORDER BY k;
