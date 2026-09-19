-- Session B1: P2 issues for the same subscription — must block on the row lock, then REPLAY the open invoice.
\set ON_ERROR_STOP on
SELECT v AS sub_z FROM zz_bill_ctx WHERE k = 'sub_z' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000012","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B1] P2 issuing (must wait, then replay) ...
SELECT 'B1_ISSUE_REPLAYED=' || (rpc_platform_issue_invoice(:'sub_z'::uuid, 'race B1') ->> 'replayed') AS b;
COMMIT;
\echo [B1] COMMIT done
