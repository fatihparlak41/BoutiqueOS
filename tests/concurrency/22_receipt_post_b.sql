-- Session B: same POST 1 s later. Must block on the header row lock, then fail with INVALID_STATE.
SELECT v AS gr FROM zz_gr_ctx WHERE k = 'gr' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] posting the same goods receipt ...
SELECT rpc_post_goods_receipt(:'gr');
COMMIT;
