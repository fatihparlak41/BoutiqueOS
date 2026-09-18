-- Session B: the same four actions 1 s later. Each blocks on A's row lock, then: approve → INVALID_STATE,
-- post gr_b → OVER_RECEIPT (6 + 6 > 10), mark ordered → INVALID_STATE, create → the NEXT number (no gap, no duplicate).
SELECT v AS po_a FROM zz_po_ctx WHERE k = 'po_a' \gset
SELECT v AS gr_b FROM zz_po_ctx WHERE k = 'gr_b' \gset
SELECT v AS po_d FROM zz_po_ctx WHERE k = 'po_d' \gset
SELECT v AS sup FROM zz_po_ctx WHERE k = 'supplier' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] approving po_a (must fail) ...
SELECT rpc_po_approve(:'po_a');
ROLLBACK;
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] posting gr_b (must be refused: 12 of 10) ...
SELECT rpc_post_goods_receipt(:'gr_b');
ROLLBACK;
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] marking po_d ordered (must fail) ...
SELECT rpc_po_mark_ordered(:'po_d');
ROLLBACK;
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [B] creating a PO (numbering) ...
SELECT rpc_po_create('b1000000-0000-4000-8000-000000000001', :'sup', 'TRY');
COMMIT;
\echo [B] COMMIT done
