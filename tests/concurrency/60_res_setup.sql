-- Phase 10A concurrency setup (run AFTER 00_setup.sql, as postgres, COMMITS): one synthetic
-- customer in the LOCAL test tenant (never DEV) for the racing reservations.
\set ON_ERROR_STOP on
BEGIN;
WITH c AS (INSERT INTO customers (business_id, full_name, phone, source) VALUES ('b0000000-0000-4000-8000-000000000001', 'CC Rezervasyon Müşterisi', '0555 000 ' || to_char(clock_timestamp(),'MISS'), 'walk_in') RETURNING id)
INSERT INTO zz_cc_ctx SELECT 'customer', id FROM c;
COMMIT;
SELECT k, v FROM zz_cc_ctx ORDER BY k;
