-- Session B: starts ~1 s after A; must BLOCK on the pool row lock and then FAIL with INSUFFICIENT_STOCK.
\set ON_ERROR_STOP off
SELECT v AS variant FROM zz_cc_ctx WHERE k = 'variant' \gset
SELECT v AS session FROM zz_cc_ctx WHERE k = 'session' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] posting sale for the same last unit (expect INSUFFICIENT_STOCK after A commits) ...
SELECT clock_timestamp() AS b_started;
SELECT rpc_process_sale('b0000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', :'session',
  jsonb_build_array(jsonb_build_object('variant_id', :'variant', 'quantity', 1)),
  jsonb_build_array(jsonb_build_object('method','cash','currency','TRY','amount',1000))) AS b_result;
SELECT clock_timestamp() AS b_finished;
COMMIT;
