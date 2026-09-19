-- Session A1: P1 issues the first invoice — HOLD 3 s before COMMIT (subscription row stays locked).
\set ON_ERROR_STOP on
SELECT v AS sub_z FROM zz_bill_ctx WHERE k = 'sub_z' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000011","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A1] P1 issuing the first invoice ...
SELECT rpc_platform_issue_invoice(:'sub_z'::uuid, 'race A1') ->> 'replayed' AS a1_replayed;
\echo [A1] holding 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A1] COMMIT done
