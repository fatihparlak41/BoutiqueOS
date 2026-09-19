-- Phase 14B • online order races • setup (run as postgres, COMMITS)
-- Business Z (owner P1 = cccccccc-…11 also platform admin from earlier races), storefront zz-race enabled,
-- one product with a single-unit variant (LAST) and a plenty variant (MANY), a register with an open session.
\set ON_ERROR_STOP on
BEGIN;
DROP TABLE IF EXISTS zz_ord_ctx;
CREATE TABLE zz_ord_ctx (k TEXT PRIMARY KEY, v TEXT);
INSERT INTO auth.users (id, instance_id, aud, role, email, email_confirmed_at) VALUES
  ('cccccccc-0000-4000-8000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'race-platform-1@boutiqueos.test', now()),
  ('dddddddd-0000-4000-8000-000000000009', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'race-owner-z@boutiqueos.test', now())
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES ('cccccccc-0000-4000-8000-000000000011'), ('dddddddd-0000-4000-8000-000000000009') ON CONFLICT DO NOTHING;
INSERT INTO platform_admins (user_id, note) VALUES ('cccccccc-0000-4000-8000-000000000011', 'race') ON CONFLICT (user_id) DO UPDATE SET is_active = true;
COMMIT;
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000009","role":"authenticated"}', true);
INSERT INTO zz_ord_ctx SELECT 'app', rpc_submit_business_application('ZZ Order Race ' || to_char(clock_timestamp(), 'HH24MISSMS'), 'TR', 'TRY') ->> 'application_id';
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000011","role":"authenticated"}', true);
INSERT INTO zz_ord_ctx SELECT 'biz', rpc_platform_approve_application((SELECT v::uuid FROM zz_ord_ctx WHERE k = 'app'), 'race') ->> 'business_id';
INSERT INTO zz_ord_ctx SELECT 'br', id::text FROM branches WHERE business_id = (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz') AND is_default;
SELECT set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000009","role":"authenticated"}', true);
INSERT INTO zz_ord_ctx SELECT 'sf', rpc_storefront_upsert((SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz'), jsonb_build_object('slug', 'zz-race', 'store_name', 'ZZ Race', 'enabled', true, 'order_hold_minutes', 60)) ->> 'storefront_id';
CREATE TEMP TABLE _p AS SELECT * FROM rpc_onboard_product((SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz'),
  jsonb_build_object('name', 'Race Elbise', 'sku_prefix', 'RACE', 'default_sale_price', '500'),
  jsonb_build_array(jsonb_build_object('sku', 'RACE-LAST', 'option_value_ids', '[]'::jsonb)));
CREATE TEMP TABLE _p2 AS SELECT * FROM rpc_onboard_product((SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz'),
  jsonb_build_object('name', 'Race Kazak', 'sku_prefix', 'RACE2', 'default_sale_price', '300'),
  jsonb_build_array(jsonb_build_object('sku', 'RACE-MANY', 'option_value_ids', '[]'::jsonb)));
INSERT INTO zz_ord_ctx SELECT 'p_last', product_id::text FROM _p LIMIT 1;
INSERT INTO zz_ord_ctx SELECT 'v_last', variant_id::text FROM _p LIMIT 1;
INSERT INTO zz_ord_ctx SELECT 'p_many', product_id::text FROM _p2 LIMIT 1;
INSERT INTO zz_ord_ctx SELECT 'v_many', variant_id::text FROM _p2 LIMIT 1;
SELECT rpc_post_inventory_adjustment((SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz'), (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'br'), (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'v_last'), 'sellable', 1, 'acilis', 'manual_cost', 200);
SELECT rpc_post_inventory_adjustment((SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz'), (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'br'), (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'v_many'), 'sellable', 20, 'acilis', 'manual_cost', 100);
SELECT rpc_storefront_publish_product((SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz'), (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'p_last'), true);
SELECT rpc_storefront_publish_product((SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz'), (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'p_many'), true);
INSERT INTO cash_registers (business_id, branch_id, name) VALUES ((SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz'), (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'br'), 'Race Kasa');
INSERT INTO zz_ord_ctx SELECT 'sess', rpc_open_register_session((SELECT id FROM cash_registers WHERE business_id = (SELECT v::uuid FROM zz_ord_ctx WHERE k = 'biz')), '[]'::jsonb)::text;
COMMIT;
SELECT k, v FROM zz_ord_ctx ORDER BY k;
