-- ============================================================
-- Phase 6A closure — archive-only lifecycle for products and variants
-- ============================================================
-- Physical deletion is not a tenant operation. The lifecycle is
--   product:  active → archived → active
--   variant:  active → archived
-- and a product or variant that a shop once sold, received or counted stays a row for
-- ever. Until now the write policies were FOR ALL, so an owner or manager could delete a
-- history-less product through the API (history-bearing rows were only saved by RESTRICT
-- foreign keys). Two layers close that:
--   1. the DELETE privilege itself is revoked from the tenant roles — a DELETE statement
--      fails with 42501 before any policy is consulted;
--   2. the FOR ALL policies are split into INSERT and UPDATE policies with the same
--      predicates, so no DELETE policy exists even if a privilege were ever re-granted.
-- Child objects keep their intended semantics: barcodes (procurement may remove a wrong
-- label), product images (manager+ may remove a photo) and option assignments stay as
-- they were. Cascades from a product/variant delete can no longer be triggered by a
-- tenant; maintenance under the service role is unaffected and is never reachable from
-- tenant code.
-- Rollback: re-create the two FOR ALL policies and GRANT DELETE back. Forward-only; the
-- deployed Phase 6A migration is untouched.
-- ============================================================

REVOKE DELETE, TRUNCATE ON products, product_variants FROM anon, authenticated;

DROP POLICY IF EXISTS pol_products_write ON products;
CREATE POLICY pol_products_insert ON products FOR INSERT
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));
CREATE POLICY pol_products_update ON products FOR UPDATE
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

DROP POLICY IF EXISTS pol_variants_write ON product_variants;
CREATE POLICY pol_variants_insert ON product_variants FOR INSERT
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));
CREATE POLICY pol_variants_update ON product_variants FOR UPDATE
  USING (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id))
  WITH CHECK (fn_is_manager_plus(business_id) AND fn_is_business_active(business_id));

-- ============================================================
-- END phase 6A closure
-- ============================================================
