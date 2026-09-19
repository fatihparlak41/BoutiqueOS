-- Session A: posts the cost-bridge count, then HOLDS the transaction open for 3 s before COMMIT.
\set ON_ERROR_STOP on
SELECT v AS count FROM zz_scc_ctx WHERE k = 'count' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A] posting stock count with entered cost ...
SELECT * FROM rpc_stock_count_post(:'count');
\echo [A] posted, holding lock 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A] COMMIT done
