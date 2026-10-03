-- Session B: the same archive (a double click / retry from a second device). Must block on
-- A's row lock, then see 'archived' and return changed=false without writing an event.
\set ON_ERROR_STOP on
SELECT v AS product FROM zz_pst_ctx WHERE k = 'product' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000005","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] archiving the same product ...
SELECT 'B_RESULT changed=' || (rpc_product_set_status(:'product', 'archived', 'yarış B')->>'changed') AS r;
COMMIT;
\echo [B] COMMIT done
