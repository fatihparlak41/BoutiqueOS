-- ============================================================
-- Phase 6B — product_images.storage_path must live under the row's own tenant prefix
-- ============================================================
-- Found during the synthetic catalogue pilot: a manager could insert an image row for
-- their own product whose storage_path pointed at another tenant's object. The bytes
-- were never readable (storage SELECT policy refuses the foreign prefix, so signing
-- fails) but the row was a dangling cross-tenant pointer. The check closes it at the
-- database: the path segment the storage policies read must match business_id, which
-- fn_set_image_business_id fills from the product before constraints are evaluated.
-- Legacy rows with url only (storage_path NULL) are unaffected. Additive; rollback:
-- ALTER TABLE product_images DROP CONSTRAINT product_images_path_tenant_chk.
-- ============================================================
ALTER TABLE product_images
  ADD CONSTRAINT product_images_path_tenant_chk
  CHECK (storage_path IS NULL OR storage_path LIKE 'business/' || business_id::text || '/%');
