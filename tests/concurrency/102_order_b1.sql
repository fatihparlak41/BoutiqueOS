-- Phase 1 B: a second anonymous checkout for the same last unit — must block, then be refused; then the SAME key as A (idempotent replay).
\set ON_ERROR_STOP off
SELECT v AS v_last FROM zz_ord_ctx WHERE k = 'v_last' \gset
BEGIN;
SET LOCAL ROLE anon;
\echo [B1] checkout of the same last unit with another key (must wait, then fail) ...
SELECT rpc_shop_create_order('zz-race', repeat('b', 64), jsonb_build_array(jsonb_build_object('variant_id', :'v_last', 'quantity', 1)), '{"name":"Race B","phone":"05320000002"}'::jsonb);
ROLLBACK;
BEGIN;
SET LOCAL ROLE anon;
\echo [B1] the same key as A (must replay) ...
SELECT 'B1_REPLAYED=' || (rpc_shop_create_order('zz-race', repeat('a', 64), jsonb_build_array(jsonb_build_object('variant_id', :'v_last', 'quantity', 1)), '{"name":"Race A","phone":"05320000001"}'::jsonb) ->> 'replayed') AS b;
COMMIT;
\echo [B1] COMMIT done
