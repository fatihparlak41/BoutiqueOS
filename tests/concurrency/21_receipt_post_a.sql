-- Session A: posts the receipt, then HOLDS the transaction open for 3 s before COMMIT.
\set ON_ERROR_STOP on
SELECT v AS gr FROM zz_gr_ctx WHERE k = 'gr' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A] posting goods receipt ...
SELECT rpc_post_goods_receipt(:'gr');
\echo [A] posted, holding lock 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A] COMMIT done
