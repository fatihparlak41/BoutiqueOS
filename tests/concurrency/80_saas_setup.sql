-- Phase 13A • SaaS platform races • setup (run as postgres, COMMITS)
-- Two platform admins (P1, P2), a confirmed applicant X with a pending application, and a confirmed
-- applicant Y with none. A and B then approve X concurrently and submit for Y concurrently.
\set ON_ERROR_STOP on
BEGIN;
DROP TABLE IF EXISTS zz_saas_ctx;
CREATE TABLE zz_saas_ctx (k TEXT PRIMARY KEY, v UUID);
INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
  ('cccccccc-0000-4000-8000-000000000011', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'race-platform-1@boutiqueos.test'),
  ('cccccccc-0000-4000-8000-000000000012', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'race-platform-2@boutiqueos.test'),
  ('dddddddd-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'race-applicant-x@boutiqueos.test'),
  ('dddddddd-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'race-applicant-y@boutiqueos.test')
ON CONFLICT (id) DO NOTHING;
INSERT INTO profiles (id) VALUES ('cccccccc-0000-4000-8000-000000000011'), ('cccccccc-0000-4000-8000-000000000012'),
  ('dddddddd-0000-4000-8000-000000000001'), ('dddddddd-0000-4000-8000-000000000002') ON CONFLICT DO NOTHING;
INSERT INTO platform_admins (user_id, note) VALUES ('cccccccc-0000-4000-8000-000000000011', 'race'), ('cccccccc-0000-4000-8000-000000000012', 'race')
ON CONFLICT (user_id) DO UPDATE SET is_active = true;
COMMIT;
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000001","role":"authenticated"}', true);
INSERT INTO zz_saas_ctx SELECT 'app_x', (rpc_submit_business_application('ZZ Race Butik ' || to_char(clock_timestamp(), 'HH24MISSMS'), 'TR', 'TRY') ->> 'application_id')::uuid;
COMMIT;
SELECT k, v FROM zz_saas_ctx ORDER BY k;
