-- Session A: reserving the last available unit, holding the transaction 3 s before COMMIT ...
\set ON_ERROR_STOP on
SELECT v AS variant FROM zz_cc_ctx WHERE k = 'variant' \gset
SELECT v AS customer FROM zz_cc_ctx WHERE k = 'customer' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A] reserving the last available unit, holding the transaction 3 s before COMMIT ...
SELECT clock_timestamp() AS started;
SELECT rpc_pos_reservation_create('b1000000-0000-4000-8000-000000000001', :'customer',
  jsonb_build_array(jsonb_build_object('variant_id', :'variant', 'quantity', 1)), now() + interval '1 day', 'cc race') AS a_result;
SELECT clock_timestamp() AS finished;
SELECT pg_sleep(3);
COMMIT;
\echo [A] COMMIT done
