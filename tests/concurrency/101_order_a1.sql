-- Phase 1 A: anonymous checkout for the LAST unit — HOLD 3 s before COMMIT (pool + reservation locks held).
\set ON_ERROR_STOP on
SELECT v AS v_last FROM zz_ord_ctx WHERE k = 'v_last' \gset
BEGIN;
SET LOCAL ROLE anon;
\echo [A1] checkout of the last unit ...
SELECT 'A1_ORDER=' || (rpc_shop_create_order('zz-race', repeat('a', 64), jsonb_build_array(jsonb_build_object('variant_id', :'v_last', 'quantity', 1)), '{"name":"Race A","phone":"05320000001"}'::jsonb) ->> 'order_number') AS a;
\echo [A1] holding 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A1] COMMIT done
