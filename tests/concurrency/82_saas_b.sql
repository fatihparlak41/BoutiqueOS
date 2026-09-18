-- Session B, 1 s later: P2 approves the same application (blocks on the row lock, then REPLAYS A's business —
-- no second tenant); applicant Y submits again (blocks on the one-pending-per-applicant index, then replays A's row).
SELECT v AS app_x FROM zz_saas_ctx WHERE k = 'app_x' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000012","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] P2 approving app_x (must wait, then replay) ...
SELECT 'B_APPROVE_REPLAYED=' || (rpc_platform_approve_application(:'app_x', 'race B') ->> 'replayed') AS b;
COMMIT;
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] applicant Y submitting (must wait, then replay) ...
SELECT 'B_SUBMIT_REPLAYED=' || (rpc_submit_business_application('ZZ Race Y Butik B', 'TR', 'TRY') ->> 'replayed') AS b;
COMMIT;
\echo [B] COMMIT done
