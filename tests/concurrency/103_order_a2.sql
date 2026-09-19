-- Phase 2 A: the merchant confirms order A — HOLD 3 s (order row locked).
\set ON_ERROR_STOP on
SELECT v AS biz FROM zz_ord_ctx WHERE k = 'biz' \gset
SELECT v AS o1 FROM zz_ord_ctx WHERE k = 'o1' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000009","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A2] confirming ...
SELECT 'A2_STATUS=' || (rpc_online_order_confirm(:'biz'::uuid, :'o1'::uuid) ->> 'status') AS a;
\echo [A2] holding 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A2] COMMIT done
