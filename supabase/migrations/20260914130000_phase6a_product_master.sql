-- ============================================================
-- Phase 6A — fashion product master, variant matrix, product images
-- ============================================================
-- Additive only. No table is dropped or recreated; existing fixtures, RLS predicates and
-- RPC signatures are untouched. Rollback: the objects below can be dropped in reverse
-- order (policies, RPCs, indexes, columns, enums, bucket row) without touching data that
-- existed before this migration — new columns are nullable or defaulted.
--
--   products          + style_code (optional model/style code; tenant-scoped duplicate WARNING,
--                       never a unique constraint — two boutiques may share a code, one may
--                       legitimately re-use one)
--   product_options   + kind (color | size | other) — drives the matrix UX, not the schema
--   option_values     + code (short key for SKU generation), color_hex (UI swatch only; never identity)
--   product_images    + role, storage_path, mime_type, byte_size, width, height, created_by,
--                       goods_receipt_id; url and product_id become optional (a receiving
--                       proof has no product; a stored file has no external url)
--   storage           product-images bucket (private) + tenant-scoped object policies
--   rpc_generate_variants   atomic, idempotent matrix creation (manager+)
--   rpc_resolve_barcode     tenant-safe barcode / SKU lookup (member)
--   rpc_set_main_image      one product_main per product (manager+)
-- ============================================================

-- ------------------------------------------------------------ enums
CREATE TYPE option_kind AS ENUM ('color', 'size', 'other');
CREATE TYPE image_role  AS ENUM ('product_main', 'product_gallery', 'variant', 'label_tag', 'receiving_proof');

-- ------------------------------------------------------------ products
ALTER TABLE products ADD COLUMN style_code TEXT
  CHECK (style_code IS NULL OR (length(style_code) BETWEEN 1 AND 64));
CREATE INDEX ix_products_style_code ON products (business_id, lower(style_code)) WHERE style_code IS NOT NULL;

-- ------------------------------------------------------------ options
ALTER TABLE product_options ADD COLUMN kind option_kind NOT NULL DEFAULT 'other';

ALTER TABLE option_values
  ADD COLUMN code      TEXT CHECK (code IS NULL OR (length(code) BETWEEN 1 AND 16)),
  ADD COLUMN color_hex TEXT CHECK (color_hex IS NULL OR color_hex ~ '^#[0-9A-Fa-f]{6}$');

-- ------------------------------------------------------------ images
ALTER TABLE product_images
  ADD COLUMN role             image_role NOT NULL DEFAULT 'product_gallery',
  ADD COLUMN storage_path     TEXT,
  ADD COLUMN mime_type        TEXT,
  ADD COLUMN byte_size        INTEGER CHECK (byte_size IS NULL OR byte_size > 0),
  ADD COLUMN width            INTEGER CHECK (width  IS NULL OR width  > 0),
  ADD COLUMN height           INTEGER CHECK (height IS NULL OR height > 0),
  ADD COLUMN created_by       UUID REFERENCES profiles(id),
  ADD COLUMN goods_receipt_id UUID;

ALTER TABLE product_images ALTER COLUMN url DROP NOT NULL;
ALTER TABLE product_images ALTER COLUMN product_id DROP NOT NULL;

ALTER TABLE product_images
  ADD CONSTRAINT product_images_source_chk CHECK (url IS NOT NULL OR storage_path IS NOT NULL),
  -- a receiving proof belongs to a goods receipt; everything else belongs to a product
  ADD CONSTRAINT product_images_owner_chk CHECK (
    (role = 'receiving_proof' AND goods_receipt_id IS NOT NULL)
    OR (role <> 'receiving_proof' AND product_id IS NOT NULL AND goods_receipt_id IS NULL)
  ),
  ADD CONSTRAINT product_images_variant_chk CHECK (role <> 'variant' OR variant_id IS NOT NULL),
  ADD CONSTRAINT product_images_mime_chk CHECK (
    mime_type IS NULL OR mime_type IN ('image/jpeg', 'image/png', 'image/webp')
  ),
  ADD FOREIGN KEY (business_id, goods_receipt_id) REFERENCES goods_receipts (business_id, id) ON DELETE CASCADE;

CREATE UNIQUE INDEX uix_product_main_image ON product_images (product_id) WHERE role = 'product_main';
CREATE UNIQUE INDEX uix_product_images_path ON product_images (business_id, storage_path) WHERE storage_path IS NOT NULL;
CREATE INDEX ix_product_images_product ON product_images (product_id, role, sort_order);

-- The generic parent trigger reads products(product_id); a receiving proof has none.
CREATE OR REPLACE FUNCTION fn_set_image_business_id()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_biz UUID;
BEGIN
  IF NEW.product_id IS NOT NULL THEN
    SELECT business_id INTO v_biz FROM products WHERE id = NEW.product_id;
  ELSIF NEW.goods_receipt_id IS NOT NULL THEN
    SELECT business_id INTO v_biz FROM goods_receipts WHERE id = NEW.goods_receipt_id;
  END IF;
  IF v_biz IS NULL THEN
    RAISE EXCEPTION 'product_images: owner (product or goods receipt) not found';
  END IF;
  NEW.business_id := v_biz;
  RETURN NEW;
END $$;
DROP TRIGGER trg_bid_images ON product_images;
CREATE TRIGGER trg_bid_images BEFORE INSERT OR UPDATE ON product_images
  FOR EACH ROW EXECUTE FUNCTION fn_set_image_business_id();

-- ------------------------------------------------------------ storage bucket + policies
-- Private bucket; every object lives under business/<business_id>/... and the policies
-- read that segment. A signed URL is the only way an image leaves the bucket, and
-- creating one is subject to the SELECT policy below, so a member of business A cannot
-- sign a URL for business B's file.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('product-images', 'product-images', false, 5242880, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO NOTHING;

-- Tenant id from an object path: business/<uuid>/... ; NULL for anything else.
CREATE OR REPLACE FUNCTION fn_storage_business_id(p_name TEXT)
RETURNS UUID LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_parts TEXT[] := storage.foldername(p_name);
BEGIN
  IF v_parts IS NULL OR array_length(v_parts, 1) < 2 OR v_parts[1] <> 'business' THEN RETURN NULL; END IF;
  IF v_parts[2] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN NULL; END IF;
  RETURN v_parts[2]::uuid;
END $$;
REVOKE EXECUTE ON FUNCTION fn_storage_business_id(TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_storage_business_id(TEXT) TO anon, authenticated, service_role;

DROP POLICY IF EXISTS pol_product_images_select ON storage.objects;
DROP POLICY IF EXISTS pol_product_images_insert ON storage.objects;
DROP POLICY IF EXISTS pol_product_images_update ON storage.objects;
DROP POLICY IF EXISTS pol_product_images_delete ON storage.objects;

CREATE POLICY pol_product_images_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'product-images' AND fn_is_member(fn_storage_business_id(name)));
CREATE POLICY pol_product_images_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'product-images'
              AND fn_is_manager_plus(fn_storage_business_id(name))
              AND fn_is_business_active(fn_storage_business_id(name)));
CREATE POLICY pol_product_images_update ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'product-images' AND fn_is_manager_plus(fn_storage_business_id(name)))
  WITH CHECK (bucket_id = 'product-images' AND fn_is_manager_plus(fn_storage_business_id(name)));
CREATE POLICY pol_product_images_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'product-images' AND fn_is_manager_plus(fn_storage_business_id(name)));

-- ------------------------------------------------------------ rpc_generate_variants (manager+)
-- Creates every sellable combination of a matrix in ONE transaction. A combination whose
-- active fingerprint already exists is reported with created = false and left alone, so
-- re-running the same matrix never duplicates and never fails half-way.
--
--   p_combos: [{ "sku": "KE-01-SYH-S", "option_value_ids": ["…","…"], "sale_price_override": null }, …]
CREATE OR REPLACE FUNCTION rpc_generate_variants(p_product_id UUID, p_combos JSONB)
RETURNS TABLE (sku TEXT, variant_id UUID, created BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_biz UUID; v_combo JSONB; v_ids UUID[]; v_sku TEXT; v_override NUMERIC;
  v_fp TEXT; v_n INT; v_opts INT; v_existing UUID; v_new UUID;
BEGIN
  SELECT business_id INTO v_biz FROM products WHERE id = p_product_id;
  IF v_biz IS NULL THEN RAISE EXCEPTION 'INVALID_PRODUCT: %', p_product_id USING ERRCODE = '22023'; END IF;
  PERFORM fn_require_role(v_biz, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(v_biz);

  IF p_combos IS NULL OR jsonb_typeof(p_combos) <> 'array' OR jsonb_array_length(p_combos) = 0 THEN
    RAISE EXCEPTION 'EMPTY_MATRIX: at least one combination is required' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_combos) > 500 THEN
    RAISE EXCEPTION 'MATRIX_TOO_LARGE: at most 500 combinations per call' USING ERRCODE = '22023';
  END IF;

  FOR v_combo IN SELECT * FROM jsonb_array_elements(p_combos) LOOP
    v_sku := NULLIF(trim(v_combo ->> 'sku'), '');
    IF v_sku IS NULL OR length(v_sku) > 64 THEN
      RAISE EXCEPTION 'INVALID_SKU: every combination needs a SKU of at most 64 characters' USING ERRCODE = '22023';
    END IF;
    v_override := NULLIF(v_combo ->> 'sale_price_override', '')::numeric;

    SELECT COALESCE(array_agg(x::uuid), '{}') INTO v_ids
    FROM jsonb_array_elements_text(COALESCE(v_combo -> 'option_value_ids', '[]'::jsonb)) AS x;

    -- Same formula as fn_refresh_variant_fingerprint / rpc_create_variant.
    SELECT count(*), count(DISTINCT ov.product_option_id),
           COALESCE(string_agg(ov.product_option_id::text || ':' || ov.id::text, '|' ORDER BY ov.product_option_id), '')
    INTO v_n, v_opts, v_fp
    FROM option_values ov WHERE ov.id = ANY(v_ids) AND ov.business_id = v_biz;
    IF v_n <> COALESCE(array_length(v_ids, 1), 0) THEN
      RAISE EXCEPTION 'INVALID_OPTION_VALUE: one or more option values not found in this business' USING ERRCODE = '22023';
    END IF;
    IF v_opts <> v_n THEN
      RAISE EXCEPTION 'INVALID_COMBINATION: a combination may carry one value per option' USING ERRCODE = '22023';
    END IF;

    SELECT pv.id INTO v_existing FROM product_variants pv
    WHERE pv.product_id = p_product_id AND pv.option_fingerprint = v_fp AND pv.status = 'active';

    IF v_existing IS NOT NULL THEN
      sku := (SELECT pv.sku FROM product_variants pv WHERE pv.id = v_existing);
      variant_id := v_existing; created := false;
      RETURN NEXT;
      CONTINUE;
    END IF;

    INSERT INTO product_variants (product_id, sku, sale_price_override, option_fingerprint)
    VALUES (p_product_id, v_sku, v_override, v_fp) RETURNING id INTO v_new;

    IF v_n > 0 THEN
      INSERT INTO variant_option_values (variant_id, product_option_id, option_value_id)
      SELECT v_new, ov.product_option_id, ov.id
      FROM option_values ov WHERE ov.id = ANY(v_ids) AND ov.business_id = v_biz;
    END IF;

    sku := v_sku; variant_id := v_new; created := true;
    RETURN NEXT;
  END LOOP;
  RETURN;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_generate_variants(UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_generate_variants(UUID, JSONB) TO authenticated;

-- ------------------------------------------------------------ rpc_resolve_barcode (member)
-- A scan resolves to exactly one variant of the caller's business, or to nothing. The
-- barcode wins; the SKU is a fallback for keyboards. Never crosses a tenant: the business
-- is an explicit argument and membership is required before anything is read.
CREATE OR REPLACE FUNCTION rpc_resolve_barcode(p_business_id UUID, p_code TEXT)
RETURNS TABLE (
  variant_id UUID, product_id UUID, product_name TEXT, sku TEXT,
  variant_status variant_status, product_status product_status, matched_by TEXT
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog, public AS $$
DECLARE v_code TEXT := trim(p_code);
BEGIN
  PERFORM fn_require_member(p_business_id);
  IF v_code IS NULL OR v_code = '' THEN RETURN; END IF;

  RETURN QUERY
  SELECT pv.id, p.id, p.name, pv.sku, pv.status, p.status, 'barcode'::text
  FROM barcodes b
  JOIN product_variants pv ON pv.id = b.variant_id
  JOIN products p ON p.id = pv.product_id
  WHERE b.business_id = p_business_id AND b.barcode = v_code
  LIMIT 1;
  IF FOUND THEN RETURN; END IF;

  RETURN QUERY
  SELECT pv.id, p.id, p.name, pv.sku, pv.status, p.status, 'sku'::text
  FROM product_variants pv
  JOIN products p ON p.id = pv.product_id
  WHERE pv.business_id = p_business_id AND pv.sku = v_code
  LIMIT 1;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_resolve_barcode(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_resolve_barcode(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------ rpc_set_main_image (manager+)
-- Promotes one image to product_main and demotes the previous one to the gallery in a
-- single statement order, so the partial unique index never sees two mains.
CREATE OR REPLACE FUNCTION rpc_set_main_image(p_image_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_biz UUID; v_product UUID; v_role image_role;
BEGIN
  SELECT business_id, product_id, role INTO v_biz, v_product, v_role FROM product_images WHERE id = p_image_id;
  IF v_biz IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: image %', p_image_id USING ERRCODE = 'P0002'; END IF;
  IF v_product IS NULL OR v_role = 'receiving_proof' THEN
    RAISE EXCEPTION 'INVALID_STATE: only a product image can become the main image' USING ERRCODE = '22023';
  END IF;
  PERFORM fn_require_role(v_biz, ARRAY['owner','manager']::user_role[]);

  UPDATE product_images SET role = 'product_gallery'
  WHERE product_id = v_product AND role = 'product_main' AND id <> p_image_id;
  UPDATE product_images SET role = 'product_main', variant_id = NULL WHERE id = p_image_id;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_set_main_image(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_set_main_image(UUID) TO authenticated;

-- ============================================================
-- END phase 6A
-- ============================================================
