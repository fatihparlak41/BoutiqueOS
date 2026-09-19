-- Session B2: P2 records the SAME reference on the same invoice — must block, then REPLAY (no second payment, no second activation).
\set ON_ERROR_STOP on
SELECT v AS inv_z FROM zz_bill_ctx WHERE k = 'inv_z' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000012","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B2] P2 recording race-ref (must wait, then replay) ...
SELECT 'B2_PAY_REPLAYED=' || (rpc_platform_record_payment(:'inv_z'::uuid, (SELECT price_amount FROM saas_plans WHERE code = 'starter'), 'USD', 'bank_transfer', 'race-ref') ->> 'replayed') AS b;
COMMIT;
\echo [B2] COMMIT done
