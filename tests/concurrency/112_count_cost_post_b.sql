-- Session B: same POST 1 s later. Must block on the header row lock, then fail with ALREADY_POSTED.
SELECT v AS count FROM zz_scc_ctx WHERE k = 'count' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000003","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] posting the same stock count ...
SELECT * FROM rpc_stock_count_post(:'count');
COMMIT;
