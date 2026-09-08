-- Session A: takes the pool lock inside the sale, then HOLDS the transaction open for 3 s before COMMIT.
\set ON_ERROR_STOP on
SELECT v AS variant FROM zz_cc_ctx WHERE k = 'variant' \gset
SELECT v AS session FROM zz_cc_ctx WHERE k = 'session' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A] posting sale for the last unit ...
SELECT rpc_process_sale('b0000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', :'session',
  jsonb_build_array(jsonb_build_object('variant_id', :'variant', 'quantity', 1)),
  jsonb_build_array(jsonb_build_object('method','cash','currency','TRY','amount',1000))) AS a_result;
\echo [A] sale posted, holding lock 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A] COMMIT done
