-- Phase 2 B: the customer cancels the same order (must block on the row, then be refused: already confirmed).
\set ON_ERROR_STOP off
SELECT v AS tok FROM zz_ord_ctx WHERE k = 'tok1' \gset
BEGIN;
SET LOCAL ROLE anon;
\echo [B2] customer cancel (must wait, then CANCEL_NOT_ALLOWED) ...
SELECT rpc_shop_cancel_order('zz-race', :'tok', 'vazgectim');
ROLLBACK;
\echo [B2] done
