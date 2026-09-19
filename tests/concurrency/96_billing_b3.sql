-- Session B3: P2 raises the catalogue price by 7 while A3 holds its issued (uncommitted) renewal.
\set ON_ERROR_STOP on
SELECT v AS price_before FROM zz_bill_ctx WHERE k = 'price_before' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000012","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B3] P2 changing the plan price ...
SELECT 'B3_PRICE_CHANGED=' || (rpc_platform_upsert_plan('starter', 'BoutiqueOS Starter', NULL, 'annual', :'price_before'::numeric + 7, 'USD', true, 10) IS NOT NULL)::text AS b;
COMMIT;
\echo [B3] COMMIT done
