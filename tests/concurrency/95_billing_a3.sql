-- Session A3: P1 issues the RENEWAL invoice — HOLD 3 s. B3 changes the plan price meanwhile (the plan row is not locked by issue).
\set ON_ERROR_STOP on
SELECT v AS sub_z FROM zz_bill_ctx WHERE k = 'sub_z' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000011","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A3] P1 issuing the renewal ...
SELECT rpc_platform_issue_invoice(:'sub_z'::uuid, 'race A3') ->> 'replayed' AS a3_replayed;
\echo [A3] holding 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A3] COMMIT done
