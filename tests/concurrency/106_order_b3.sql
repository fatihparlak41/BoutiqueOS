-- Phase 3 B: the same conversion double-submitted with the SAME client transaction id, then a merchant cancel — both must find the completed order.
\set ON_ERROR_STOP off
SELECT v AS o1 FROM zz_ord_ctx WHERE k = 'o1' \gset
SELECT v AS sess FROM zz_ord_ctx WHERE k = 'sess' \gset
SELECT v AS biz FROM zz_ord_ctx WHERE k = 'biz' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000009","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B3] double-submit (must wait, then replay) ...
SELECT 'B3_REPLAYED=' || (rpc_pos_complete_online_order(:'o1'::uuid, :'sess'::uuid, '[{"method":"cash","currency":"TRY","amount":500}]'::jsonb, 'aaaaaaaa-0000-4000-8000-00000000c1d1') ->> 'replayed') AS b;
COMMIT;
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"dddddddd-0000-4000-8000-000000000009","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B3] merchant cancel of the completed order (must be INVALID_STATE) ...
SELECT rpc_online_order_cancel(:'biz'::uuid, :'o1'::uuid, 'gec kaldi');
ROLLBACK;
\echo [B3] done
