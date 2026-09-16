-- Session A (POS): rpc_pos_complete_sale for the last unit, holds the transaction 3 s before COMMIT.
\set ON_ERROR_STOP on
SELECT v AS variant FROM zz_cc_ctx WHERE k = 'variant' \gset
SELECT v AS session FROM zz_cc_ctx WHERE k = 'session' \gset
-- client_transaction_id derived from this run's variant so re-runs never collide
SELECT md5(:'variant'::text || 'pos-a')::uuid AS ctid \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A] POS sale for the last unit ...
SELECT rpc_pos_complete_sale(:'session',
  jsonb_build_array(jsonb_build_object('variant_id', :'variant', 'quantity', 1)),
  jsonb_build_array(jsonb_build_object('method','cash','currency','TRY','amount',1000)),
  :'ctid') AS a_result;
\echo [A] sale posted, holding lock 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A] COMMIT done
