-- Phase 3 A: POS conversion of order A — HOLD 3 s (order, reservation, pools locked).
\set ON_ERROR_STOP on
SELECT v AS o1 FROM zz_ord_ctx WHERE k = 'o1' \gset
SELECT v AS sess FROM zz_ord_ctx WHERE k = 'sess' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000009","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A3] converting ...
SELECT 'A3_REPLAYED=' || (rpc_pos_complete_online_order(:'o1'::uuid, :'sess'::uuid, '[{"method":"cash","currency":"TRY","amount":500}]'::jsonb, 'aaaaaaaa-0000-4000-8000-00000000c1d1') ->> 'replayed') AS a;
\echo [A3] holding 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A3] COMMIT done
