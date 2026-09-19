-- Phase 4 A: an anonymous checkout for MANY — HOLD 3 s after the price was read.
\set ON_ERROR_STOP on
SELECT v AS v_many FROM zz_ord_ctx WHERE k = 'v_many' \gset
BEGIN;
SET LOCAL ROLE anon;
\echo [A4] checkout of 2 x MANY ...
SELECT 'A4_TOTAL=' || (rpc_shop_create_order('zz-race', repeat('c', 64), jsonb_build_array(jsonb_build_object('variant_id', :'v_many', 'quantity', 2)), '{"name":"Race C","phone":"05320000003"}'::jsonb) ->> 'total') AS a;
\echo [A4] holding 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A4] COMMIT done
