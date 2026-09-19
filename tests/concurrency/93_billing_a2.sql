-- Session A2: P1 records the full bank transfer with reference RACE-REF — HOLD 3 s (invoice + subscription rows locked).
\set ON_ERROR_STOP on
SELECT v AS inv_z FROM zz_bill_ctx WHERE k = 'inv_z' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000011","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A2] P1 recording the full payment ...
SELECT rpc_platform_record_payment(:'inv_z'::uuid, (SELECT price_amount FROM saas_plans WHERE code = 'starter'), 'USD', 'bank_transfer', 'RACE-REF') ->> 'subscription_activated' AS a2_activated;
\echo [A2] holding 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A2] COMMIT done
