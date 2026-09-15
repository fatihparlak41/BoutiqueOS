-- ============================================================
-- Phase 6B — physical catalogue onboarding (product master only)
-- ============================================================
-- Additive. Nothing here touches stock, cost pools, supplier accounts or goods
-- receipts: the onboarding RPCs write products, product_variants,
-- variant_option_values and barcodes, and nothing else. Test T62 asserts that.
--
--   product_variants  + created_by
--   fn_stamp_created_by()   BEFORE INSERT on products / product_variants /
--                           product_images / categories: created_by := auth user
--   rpc_onboard_variants(p_product_id, p_combos)   manager+, atomic
--   rpc_onboard_product(p_business_id, p_product, p_combos)   manager+, atomic
--
-- Rollback: drop the two RPCs, the four triggers and the function, then
-- ALTER TABLE product_variants DROP COLUMN created_by. No data is rewritten.
-- ============================================================

-- ------------------------------------------------------------ creator stamping
-- The team audit log is a member-lifecycle log with its own enum; catalogue entry
-- traceability uses the created_by / created_at columns the schema already carries.
-- products and product_images had created_by but nothing filled it; variants had none.
ALTER TABLE product_variants ADD COLUMN created_by UUID REFERENCES profiles(id);

CREATE OR REPLACE FUNCTION fn_stamp_created_by()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  -- auth.uid() is the JWT subject for browser sessions and for SECURITY DEFINER RPCs
  -- called from them; NULL for maintenance sessions, which keep whatever they set.
  NEW.created_by := COALESCE(NEW.created_by, auth.uid());
  RETURN NEW;
END $$;

CREATE TRIGGER trg_created_by_products        BEFORE INSERT ON products         FOR EACH ROW EXECUTE FUNCTION fn_stamp_created_by();
CREATE TRIGGER trg_created_by_product_variants BEFORE INSERT ON product_variants FOR EACH ROW EXECUTE FUNCTION fn_stamp_created_by();
CREATE TRIGGER trg_created_by_product_images  BEFORE INSERT ON product_images   FOR EACH ROW EXECUTE FUNCTION fn_stamp_created_by();
CREATE TRIGGER trg_created_by_categories      BEFORE INSERT ON categories       FOR EACH ROW EXECUTE FUNCTION fn_stamp_created_by();

-- ------------------------------------------------------------ rpc_onboard_variants (manager+)
-- Physically confirmed combinations of an existing product, each with the barcodes
-- printed on its label. One transaction: a barcode already registered in the business
-- (23505 on barcodes_business_id_barcode_key) rolls back every variant of the call, so
-- a half-entered garment never exists.
--
-- p_combos: [{ "sku": "...", "option_value_ids": [uuid, ...], "barcodes": ["8690...", ...] }]
-- Barcodes are stored exactly as given (trimmed only): no reformatting, no zero
-- stripping, no generated replacement. Type is 'supplier' (it came on the garment);
-- symbology EAN13 for 13 digits, CODE128 otherwise. The first barcode of a variant that
-- has none becomes primary.
CREATE OR REPLACE FUNCTION rpc_onboard_variants(p_product_id UUID, p_combos JSONB)
RETURNS TABLE (sku TEXT, variant_id UUID, created BOOLEAN, barcodes_added INT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_biz UUID; v_combo JSONB; v_code TEXT; v_n INT; v_has_primary BOOLEAN; v_seen TEXT[]; r RECORD;
BEGIN
  SELECT business_id INTO v_biz FROM products WHERE id = p_product_id;
  IF v_biz IS NULL THEN RAISE EXCEPTION 'INVALID_PRODUCT: %', p_product_id USING ERRCODE = '22023'; END IF;
  PERFORM fn_require_role(v_biz, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(v_biz);

  IF p_combos IS NULL OR jsonb_typeof(p_combos) <> 'array' OR jsonb_array_length(p_combos) = 0 THEN
    RAISE EXCEPTION 'EMPTY_MATRIX: at least one combination is required' USING ERRCODE = '22023';
  END IF;

  FOR v_combo IN SELECT * FROM jsonb_array_elements(p_combos) LOOP
    -- rpc_generate_variants re-checks the role, validates the values, computes the
    -- fingerprint and skips an existing active combination (created = false).
    SELECT g.sku, g.variant_id, g.created INTO r
    FROM rpc_generate_variants(p_product_id, jsonb_build_array(v_combo - 'barcodes')) AS g;

    v_n := 0;
    IF jsonb_typeof(v_combo -> 'barcodes') = 'array' THEN
      SELECT EXISTS (SELECT 1 FROM barcodes b WHERE b.variant_id = r.variant_id AND b.is_primary) INTO v_has_primary;
      v_seen := '{}';
      -- label order is kept: the first code typed becomes primary, not the smallest one
      FOR v_code IN SELECT trim(t.x) FROM jsonb_array_elements_text(v_combo -> 'barcodes') WITH ORDINALITY AS t(x, n)
                    WHERE trim(t.x) <> '' ORDER BY t.n LOOP
        IF v_code = ANY(v_seen) THEN CONTINUE; END IF;
        v_seen := v_seen || v_code;
        IF length(v_code) < 3 OR length(v_code) > 64 THEN
          RAISE EXCEPTION 'INVALID_BARCODE: a barcode has 3 to 64 characters' USING ERRCODE = '22023';
        END IF;
        INSERT INTO barcodes (variant_id, barcode, barcode_type, symbology, is_primary)
        VALUES (r.variant_id, v_code, 'supplier',
                CASE WHEN v_code ~ '^[0-9]{13}$' THEN 'EAN13' ELSE 'CODE128' END,
                NOT v_has_primary);
        v_has_primary := true;
        v_n := v_n + 1;
      END LOOP;
    END IF;

    sku := r.sku; variant_id := r.variant_id; created := r.created; barcodes_added := v_n;
    RETURN NEXT;
  END LOOP;
  RETURN;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_onboard_variants(UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_onboard_variants(UUID, JSONB) TO authenticated;

-- ------------------------------------------------------------ rpc_onboard_product (manager+)
-- A new physical model with its confirmed variants and label barcodes, in one
-- transaction. The business is an explicit argument — the caller states which tenant
-- it is writing into and membership is proven against exactly that id — and the
-- product row is inserted through RLS-equivalent checks (role + active business).
--
-- p_product: { "name", "sku_prefix", "style_code", "category_id", "brand_id",
--              "supplier_id", "default_sale_price", "collection", "description" }
-- Only name and sku_prefix are required; price defaults to 0 when absent (a catalogue
-- entry without a price is not a guess, it is an unset field). Status is 'active'.
CREATE OR REPLACE FUNCTION rpc_onboard_product(p_business_id UUID, p_product JSONB, p_combos JSONB)
RETURNS TABLE (product_id UUID, sku TEXT, variant_id UUID, created BOOLEAN, barcodes_added INT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_pid UUID; v_name TEXT; v_prefix TEXT; v_price NUMERIC;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  PERFORM fn_require_active_business(p_business_id);

  IF p_product IS NULL OR jsonb_typeof(p_product) <> 'object' THEN
    RAISE EXCEPTION 'INVALID_PRODUCT: product payload required' USING ERRCODE = '22023';
  END IF;
  v_name   := NULLIF(trim(p_product ->> 'name'), '');
  v_prefix := NULLIF(trim(p_product ->> 'sku_prefix'), '');
  IF v_name IS NULL OR length(v_name) < 2 OR length(v_name) > 200 THEN
    RAISE EXCEPTION 'INVALID_PRODUCT: name must be 2 to 200 characters' USING ERRCODE = '22023';
  END IF;
  IF v_prefix IS NULL OR length(v_prefix) > 32 THEN
    RAISE EXCEPTION 'INVALID_PRODUCT: sku_prefix must be 1 to 32 characters' USING ERRCODE = '22023';
  END IF;
  v_price := COALESCE(NULLIF(p_product ->> 'default_sale_price', '')::numeric, 0);
  IF v_price < 0 THEN RAISE EXCEPTION 'INVALID_PRODUCT: price must not be negative' USING ERRCODE = '22023'; END IF;

  -- Composite FKs (business_id, category_id / brand_id / supplier_id) refuse a foreign
  -- tenant's reference with 23503; nothing is resolved by name here.
  INSERT INTO products (business_id, name, sku_prefix, style_code, category_id, brand_id, supplier_id,
                        default_sale_price, collection, description, status)
  VALUES (p_business_id, v_name, v_prefix,
          NULLIF(left(trim(p_product ->> 'style_code'), 64), ''),
          NULLIF(p_product ->> 'category_id', '')::uuid,
          NULLIF(p_product ->> 'brand_id', '')::uuid,
          NULLIF(p_product ->> 'supplier_id', '')::uuid,
          v_price,
          NULLIF(left(trim(p_product ->> 'collection'), 80), ''),
          NULLIF(trim(p_product ->> 'description'), ''),
          'active')
  RETURNING id INTO v_pid;

  RETURN QUERY
  SELECT v_pid, v.sku, v.variant_id, v.created, v.barcodes_added
  FROM rpc_onboard_variants(v_pid, p_combos) AS v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_onboard_product(UUID, JSONB, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_onboard_product(UUID, JSONB, JSONB) TO authenticated;
