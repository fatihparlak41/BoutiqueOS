-- Session A: approve po_a, post gr_a (6 of the 10 on po_c), mark po_d ordered, create a PO (numbering) — then HOLD 3 s before COMMIT.
\set ON_ERROR_STOP on
SELECT v AS po_a FROM zz_po_ctx WHERE k = 'po_a' \gset
SELECT v AS gr_a FROM zz_po_ctx WHERE k = 'gr_a' \gset
SELECT v AS po_d FROM zz_po_ctx WHERE k = 'po_d' \gset
SELECT v AS sup FROM zz_po_ctx WHERE k = 'supplier' \gset
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000002","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
\echo [A] approving po_a, posting gr_a, ordering po_d, creating a PO ...
SELECT rpc_po_approve(:'po_a');
SELECT rpc_post_goods_receipt(:'gr_a');
SELECT rpc_po_mark_ordered(:'po_d');
SELECT rpc_po_create('b1000000-0000-4000-8000-000000000001', :'sup', 'TRY');
\echo [A] done, holding locks 3 s before COMMIT
SELECT pg_sleep(3);
COMMIT;
\echo [A] COMMIT done
