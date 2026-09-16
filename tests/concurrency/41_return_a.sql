-- Session A: exchanging the last returnable unit, holding the transaction 3 s before COMMIT ...
\set ON_ERROR_STOP on
SELECT v AS sale FROM zz_cc_ctx WHERE k = 'sale' \gset
SELECT v AS sale_item FROM zz_cc_ctx WHERE k = 'sale_item' \gset
SELECT v AS variant2 FROM zz_cc_ctx WHERE k = 'variant2' \gset
SELECT v AS session FROM zz_cc_ctx WHERE k = 'session' \gset
SELECT md5(:'sale'::text || 'ret-a')::uuid AS ctid \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000001","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A] exchanging the last returnable unit, holding the transaction 3 s before COMMIT ...
SELECT clock_timestamp() AS started;
SELECT rpc_pos_exchange(:'session', :'sale',
  jsonb_build_array(jsonb_build_object('sale_item_id', :'sale_item', 'quantity', 1)),
  jsonb_build_array(jsonb_build_object('variant_id', :'variant2', 'quantity', 1)),
  '[]'::jsonb, :'ctid') AS a_result;
SELECT clock_timestamp() AS finished;
SELECT pg_sleep(3);
COMMIT;
\echo [A] COMMIT done
