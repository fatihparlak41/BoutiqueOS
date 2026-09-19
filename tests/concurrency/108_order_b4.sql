-- Phase 4 B: the merchant raises MANY's price to 350 while A4 holds its uncommitted order.
\set ON_ERROR_STOP on
SELECT v AS p_many FROM zz_ord_ctx WHERE k = 'p_many' \gset
BEGIN;
UPDATE products SET default_sale_price = 350 WHERE id = :'p_many'::uuid;
COMMIT;
\echo [B4] PRICE_CHANGED=true
\echo [B4] COMMIT done
