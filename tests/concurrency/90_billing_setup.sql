-- Phase 13B • SaaS billing races • setup (run as postgres, COMMITS)
-- Two platform admins (P1, P2) and a confirmed applicant Z whose application P1 approves → one PENDING subscription.
\set ON_ERROR_STOP on
BEGIN;
DROP TABLE IF EXISTS zz_bill_ctx;
CREATE TABLE zz_bill_ctx (k TEXT PRIMARY KEY, v TEXT);
INSERT INTO auth.users (id, instance_id, aud, role, email, email_confirmed_at) VALUES
  ('cccccccc-0000-4000-8000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'race-platform-1@boutiqueos.test', now()),
  ('cccccccc-0000-4000-8000-000000000012', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'race-platform-2@boutiqueos.test', now()),
  ('dddddddd-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'race-applicant-z@boutiqueos.test', now())
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES ('cccccccc-0000-4000-8000-000000000011'), ('cccccccc-0000-4000-8000-000000000012'), ('dddddddd-0000-4000-8000-000000000003') ON CONFLICT DO NOTHING;
INSERT INTO platform_admins (user_id, note) VALUES ('cccccccc-0000-4000-8000-000000000011', 'race'), ('cccccccc-0000-4000-8000-000000000012', 'race')
ON CONFLICT (user_id) DO UPDATE SET is_active = true;
COMMIT;
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000003","role":"authenticated"}', true);
INSERT INTO zz_bill_ctx SELECT 'app_z', rpc_submit_business_application('ZZ Bill Race ' || to_char(clock_timestamp(), 'HH24MISSMS'), 'TR', 'TRY') ->> 'application_id';
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000011","role":"authenticated"}', true);
INSERT INTO zz_bill_ctx SELECT 'sub_z', rpc_platform_approve_application((SELECT v::uuid FROM zz_bill_ctx WHERE k = 'app_z'), 'race') ->> 'subscription_id';
INSERT INTO zz_bill_ctx SELECT 'price_before', price_amount::text FROM saas_plans WHERE code = 'starter';
COMMIT;
SELECT k, v FROM zz_bill_ctx ORDER BY k;
