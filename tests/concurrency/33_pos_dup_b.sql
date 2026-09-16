-- Session B (POS double submit): SAME client_transaction_id as A, sent while A is still open.
-- Must wait on the idempotency lock and then replay A's result — no second sale, no error.
\set ON_ERROR_STOP off
SELECT v AS variant FROM zz_cc_ctx WHERE k = 'variant' \gset
SELECT v AS session FROM zz_cc_ctx WHERE k = 'session' \gset
-- client_transaction_id derived from this run's variant so re-runs never collide
SELECT md5(:'variant'::text || 'pos-a')::uuid AS ctid \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] re-submitting the same POS sale (expect replayed=true after A commits) ...
SELECT clock_timestamp() AS b_started;
SELECT rpc_pos_complete_sale(:'session',
  jsonb_build_array(jsonb_build_object('variant_id', :'variant', 'quantity', 1)),
  jsonb_build_array(jsonb_build_object('method','cash','currency','TRY','amount',1000)),
  :'ctid') AS b_result;
SELECT clock_timestamp() AS b_finished;
COMMIT;
