-- Session A: P1 approves app_x, then applicant Y submits — HOLD 3 s before COMMIT.
\set ON_ERROR_STOP on
SELECT v AS app_x FROM zz_saas_ctx WHERE k = 'app_x' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000011","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A] P1 approving app_x ...
SELECT rpc_platform_approve_application(:'app_x', 'race A') ->> 'replayed' AS a_replayed;
SELECT set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000002","role":"authenticated"}', true);
\echo [A] applicant Y submitting ...
SELECT rpc_submit_business_application('ZZ Race Y Butik', 'TR', 'TRY') ->> 'replayed' AS a_submit_replayed;
\echo [A] done, holding locks 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A] COMMIT done
