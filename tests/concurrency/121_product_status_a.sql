-- Session A: archives the product, then HOLDS the transaction open for 3 s before COMMIT.
\set ON_ERROR_STOP on
SELECT v AS product FROM zz_pst_ctx WHERE k = 'product' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000004","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A] archiving ...
SELECT rpc_product_set_status(:'product', 'archived', 'yarış A');
\echo [A] archived, holding lock 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A] COMMIT done
