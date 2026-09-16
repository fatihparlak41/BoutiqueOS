-- Session B: reserving the unit a POS sale (A) is taking (expect INSUFFICIENT_AVAILABLE_STOCK after A commits) ...
\set ON_ERROR_STOP off
SELECT v AS variant FROM zz_cc_ctx WHERE k = 'variant' \gset
SELECT v AS customer FROM zz_cc_ctx WHERE k = 'customer' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] reserving the unit a POS sale (A) is taking (expect INSUFFICIENT_AVAILABLE_STOCK after A commits) ...
SELECT clock_timestamp() AS started;
SELECT rpc_pos_reservation_create('b1000000-0000-4000-8000-000000000001', :'customer',
  jsonb_build_array(jsonb_build_object('variant_id', :'variant', 'quantity', 1)), now() + interval '1 day', 'cc race') AS b_result;
SELECT clock_timestamp() AS finished;
COMMIT;
