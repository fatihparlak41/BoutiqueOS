-- ============================================================
-- Phase 14A — E-commerce catalog + storefront foundation (public catalog, no checkout)
--
-- Decisions (docs/09 ADR-21):
--   * BoutiqueOS stays the only catalog. The storefront reads products / variants / options /
--     images / price / availability from the operational tables through explicitly shaped,
--     read-only, anon-callable RPCs (rpc_shop_*). anon receives NO table privilege.
--   * Publishing is explicit and separate from operational status: products.web_published
--     (+ web copy, slug, featured, sort) and product_variants.web_enabled. An archived or
--     draft product can never be published (trigger); a published product may be sold out.
--   * Web price = the current selling price (COALESCE(variant override, product default)).
--     No second price list in 14A.
--   * Public availability = sellable ledger − active, unexpired holds at the storefront's
--     fulfillment branch. Exposed as a state (in_stock / low / sold_out) or, when the
--     merchant chooses, as the exact number. Never damaged / quarantine / cost / supplier.
--   * Images: the private product-images bucket stays private. A published image is a copy in
--     the public storefront-images bucket at store/<business>/<product>/<image>.<ext>, recorded
--     in product_images.public_path. Only product_main / product_gallery / variant roles may
--     carry a public path (CHECK); label_tag and receiving_proof can never be published.
--   * Storefront settings live in storefronts (one per business): enabled, slug (public URL),
--     store name, announcement, contact links, fulfillment branch, stock display. Custom
--     domains are a table (storefront_domains) and a resolver only — no DNS automation.
--   * Cart is browser state; nothing here reserves or moves stock (CART ≠ RESERVATION).
-- ============================================================

CREATE TYPE stock_display AS ENUM ('state', 'exact');

-- ------------------------------------------------------------ storefront settings
CREATE TABLE storefronts (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           UUID NOT NULL UNIQUE REFERENCES businesses(id),
  enabled               BOOLEAN NOT NULL DEFAULT false,
  slug                  TEXT NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9](?:[a-z0-9-]{1,48}[a-z0-9])$'),
  store_name            TEXT NOT NULL CHECK (length(trim(store_name)) BETWEEN 2 AND 80),
  tagline               TEXT CHECK (tagline IS NULL OR length(tagline) <= 160),
  announcement          TEXT CHECK (announcement IS NULL OR length(announcement) <= 200),
  about                 TEXT CHECK (about IS NULL OR length(about) <= 2000),
  instagram             TEXT CHECK (instagram IS NULL OR instagram ~ '^[A-Za-z0-9._]{1,30}$'),
  whatsapp              TEXT CHECK (whatsapp IS NULL OR whatsapp ~ '^\+?[0-9]{8,15}$'),
  contact_email         TEXT CHECK (contact_email IS NULL OR contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  contact_phone         TEXT CHECK (contact_phone IS NULL OR length(contact_phone) <= 32),
  fulfillment_branch_id UUID,
  stock_display         stock_display NOT NULL DEFAULT 'state',
  low_stock_threshold   INTEGER NOT NULL DEFAULT 3 CHECK (low_stock_threshold BETWEEN 1 AND 50),
  logo_path             TEXT CHECK (logo_path IS NULL OR logo_path ~ '^store/[0-9a-f-]{36}/logo/'),
  theme                 JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (business_id, fulfillment_branch_id) REFERENCES branches (business_id, id)
);
ALTER TABLE storefronts ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_storefronts_member ON storefronts FOR SELECT USING (fn_is_member(business_id));
REVOKE ALL ON storefronts FROM anon, authenticated;
GRANT SELECT ON storefronts TO authenticated;

-- Custom domain foundation: host → storefront. Nothing resolves hosts in 14A; no DNS automation.
CREATE TABLE storefront_domains (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  storefront_id UUID NOT NULL REFERENCES storefronts(id),
  host          TEXT NOT NULL UNIQUE CHECK (host = lower(host) AND host ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'),
  is_primary    BOOLEAN NOT NULL DEFAULT false,
  verified_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE storefront_domains ENABLE ROW LEVEL SECURITY;          -- no policies: platform later
REVOKE ALL ON storefront_domains FROM anon, authenticated;

-- ------------------------------------------------------------ publishing columns
ALTER TABLE products
  ADD COLUMN web_published    BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN web_published_at TIMESTAMPTZ,
  ADD COLUMN web_title        TEXT CHECK (web_title IS NULL OR length(web_title) BETWEEN 2 AND 120),
  ADD COLUMN web_description  TEXT CHECK (web_description IS NULL OR length(web_description) <= 4000),
  ADD COLUMN web_slug         TEXT CHECK (web_slug IS NULL OR web_slug ~ '^[a-z0-9](?:[a-z0-9-]{0,78}[a-z0-9])?$'),
  ADD COLUMN web_featured     BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN web_sort_order   INTEGER NOT NULL DEFAULT 100;
CREATE UNIQUE INDEX uix_products_web_slug ON products (business_id, web_slug) WHERE web_slug IS NOT NULL;
CREATE INDEX idx_products_web_published ON products (business_id, web_sort_order, web_published_at DESC) WHERE web_published;

ALTER TABLE product_variants ADD COLUMN web_enabled BOOLEAN NOT NULL DEFAULT true;

ALTER TABLE product_images
  ADD COLUMN public_path TEXT,
  ADD CONSTRAINT chk_product_images_public_role CHECK (public_path IS NULL OR role = ANY (ARRAY['product_main','product_gallery','variant']::image_role[])),
  ADD CONSTRAINT chk_product_images_public_path CHECK (public_path IS NULL OR public_path ~ '^store/[0-9a-f-]{36}/products/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$');
CREATE UNIQUE INDEX uix_product_images_public_path ON product_images (public_path) WHERE public_path IS NOT NULL;

-- the public path must belong to the image's own tenant and product
CREATE OR REPLACE FUNCTION fn_product_image_public_guard()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF NEW.public_path IS NOT NULL AND NEW.public_path NOT LIKE 'store/' || NEW.business_id::text || '/products/' || NEW.product_id::text || '/%' THEN
    RAISE EXCEPTION 'PUBLIC_PATH_MISMATCH: public path must live under the image''s tenant and product' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_product_image_public_guard BEFORE INSERT OR UPDATE OF public_path ON product_images FOR EACH ROW EXECUTE FUNCTION fn_product_image_public_guard();

-- operationally active ≠ published, but a non-active product can never stay published
CREATE OR REPLACE FUNCTION fn_product_web_guard()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF NEW.status <> 'active' AND NEW.web_published THEN
    NEW.web_published := false;
  END IF;
  IF NEW.web_published AND NOT OLD.web_published THEN NEW.web_published_at := now(); END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_product_web_guard BEFORE UPDATE ON products FOR EACH ROW EXECUTE FUNCTION fn_product_web_guard();

-- ------------------------------------------------------------ public image bucket (published copies only)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('storefront-images', 'storefront-images', true, 5242880, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO NOTHING;

-- Tenant id from a public object path: store/<uuid>/... ; NULL for anything else.
CREATE OR REPLACE FUNCTION fn_store_business_id(p_name TEXT)
RETURNS UUID LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_name ~ '^store/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/' THEN split_part(p_name, '/', 2)::uuid END;
$$;
REVOKE EXECUTE ON FUNCTION fn_store_business_id(TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_store_business_id(TEXT) TO anon, authenticated, service_role;

DROP POLICY IF EXISTS pol_storefront_images_select ON storage.objects;
DROP POLICY IF EXISTS pol_storefront_images_insert ON storage.objects;
DROP POLICY IF EXISTS pol_storefront_images_delete ON storage.objects;
-- public bucket: objects are served by their public URL; listing/reading through the API is open by design (published copies only)
CREATE POLICY pol_storefront_images_select ON storage.objects FOR SELECT TO anon, authenticated
  USING (bucket_id = 'storefront-images');
CREATE POLICY pol_storefront_images_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'storefront-images'
              AND fn_is_manager_plus(fn_store_business_id(name))
              AND fn_is_business_active(fn_store_business_id(name)));
CREATE POLICY pol_storefront_images_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'storefront-images' AND fn_is_manager_plus(fn_store_business_id(name)));

-- ------------------------------------------------------------ helpers
-- URL slug from a name: Turkish letters folded, anything else collapsed to '-'.
CREATE OR REPLACE FUNCTION fn_web_slug_for(p_text TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(trim(both '-' FROM regexp_replace(lower(translate(COALESCE(p_text, ''), 'çğıöşüÇĞİÖŞÜâîûÂÎÛ', 'cgiosucgiosuaiuaiu')), '[^a-z0-9]+', '-', 'g')), '');
$$;
REVOKE EXECUTE ON FUNCTION fn_web_slug_for(TEXT) FROM PUBLIC, anon, authenticated;

-- Web price of a variant: the current selling price. No second price list.
CREATE OR REPLACE FUNCTION fn_web_price(p_variant_id UUID)
RETURNS NUMERIC LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(pv.sale_price_override, p.default_sale_price) FROM product_variants pv JOIN products p ON p.id = pv.product_id WHERE pv.id = p_variant_id;
$$;
REVOKE EXECUTE ON FUNCTION fn_web_price(UUID) FROM PUBLIC, anon, authenticated;

-- Public availability: sellable ledger − active unexpired holds, at one branch. Never below 0.
CREATE OR REPLACE FUNCTION fn_shop_available(p_business_id UUID, p_branch_id UUID, p_variant_id UUID)
RETURNS INTEGER LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT GREATEST(fn_bucket_qty(p_business_id, p_branch_id, p_variant_id, 'sellable') - fn_reserved_qty(p_business_id, p_branch_id, p_variant_id), 0);
$$;
REVOKE EXECUTE ON FUNCTION fn_shop_available(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION fn_shop_state(p_available INTEGER, p_threshold INTEGER)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_available <= 0 THEN 'sold_out' WHEN p_available <= p_threshold THEN 'low' ELSE 'in_stock' END;
$$;
REVOKE EXECUTE ON FUNCTION fn_shop_state(INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;

-- The storefront a public request is for: enabled, on an active business, with a fulfillment branch.
CREATE OR REPLACE FUNCTION fn_shop_resolve(p_slug TEXT)
RETURNS storefronts LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT s.* FROM storefronts s JOIN businesses b ON b.id = s.business_id
  WHERE s.slug = lower(trim(COALESCE(p_slug, ''))) AND s.enabled AND b.status = 'active';
$$;
REVOKE EXECUTE ON FUNCTION fn_shop_resolve(TEXT) FROM PUBLIC, anon, authenticated;

-- Effective fulfillment branch: the configured one, else the business's default branch.
CREATE OR REPLACE FUNCTION fn_shop_branch(s storefronts)
RETURNS UUID LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(s.fulfillment_branch_id,
                  (SELECT id FROM branches WHERE business_id = s.business_id AND status = 'active' ORDER BY is_default DESC, created_at LIMIT 1));
$$;
REVOKE EXECUTE ON FUNCTION fn_shop_branch(storefronts) FROM PUBLIC, anon, authenticated;

-- Public image URL path (relative to the public bucket). Only published copies ever appear here.
CREATE OR REPLACE FUNCTION fn_shop_product_images(p_product_id UUID)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', i.id, 'path', i.public_path, 'alt', i.alt_text, 'role', i.role, 'variant_id', i.variant_id, 'width', i.width, 'height', i.height)
                            ORDER BY (i.role = 'product_main') DESC, i.sort_order, i.created_at), '[]'::jsonb)
  FROM product_images i
  WHERE i.product_id = p_product_id AND i.public_path IS NOT NULL AND i.role = ANY (ARRAY['product_main','product_gallery','variant']::image_role[]);
$$;
REVOKE EXECUTE ON FUNCTION fn_shop_product_images(UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------ public RPCs (anon, read-only, explicitly shaped)
-- Store identity + navigation in one call. NULL when the slug is unknown, disabled or the business is not active.
CREATE OR REPLACE FUNCTION rpc_shop_resolve(p_slug TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s storefronts; v_branch UUID; v JSONB;
BEGIN
  s := fn_shop_resolve(p_slug);
  IF s.id IS NULL THEN RETURN NULL; END IF;
  v_branch := fn_shop_branch(s);
  SELECT jsonb_build_object(
    'slug', s.slug, 'store_name', s.store_name, 'tagline', s.tagline, 'announcement', s.announcement, 'about', s.about,
    'instagram', s.instagram, 'whatsapp', s.whatsapp, 'contact_email', s.contact_email, 'contact_phone', s.contact_phone,
    'logo_path', s.logo_path, 'theme', s.theme, 'stock_display', s.stock_display, 'low_stock_threshold', s.low_stock_threshold,
    'currency', b.base_currency,
    'categories', (SELECT COALESCE(jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name, 'count', x.n) ORDER BY x.sort_order, x.name), '[]'::jsonb)
                   FROM (SELECT c.slug, c.name, c.sort_order, count(*) AS n FROM categories c JOIN products p ON p.category_id = c.id
                         WHERE c.business_id = s.business_id AND c.is_active AND p.web_published AND p.status = 'active'
                         GROUP BY c.id) x),
    'published_count', (SELECT count(*) FROM products p WHERE p.business_id = s.business_id AND p.web_published AND p.status = 'active'))
  INTO v FROM businesses b WHERE b.id = s.business_id;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_shop_resolve(TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_resolve(TEXT) TO anon, authenticated;

-- Listing card shape shared by the home sections and the category / all-products pages.
CREATE OR REPLACE FUNCTION fn_shop_card(s storefronts, p products, p_branch UUID)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  WITH v AS (
    SELECT pv.id, fn_web_price(pv.id) AS price, fn_shop_available(s.business_id, p_branch, pv.id) AS avail
    FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled
  )
  SELECT jsonb_build_object(
    'slug', p.web_slug, 'name', COALESCE(p.web_title, p.name), 'featured', p.web_featured,
    'price_from', (SELECT min(price) FROM v), 'price_to', (SELECT max(price) FROM v),
    'availability', fn_shop_state((SELECT COALESCE(sum(avail), 0)::int FROM v), s.low_stock_threshold),
    'image', (SELECT jsonb_build_object('path', i.public_path, 'alt', i.alt_text, 'width', i.width, 'height', i.height)
              FROM product_images i WHERE i.product_id = p.id AND i.public_path IS NOT NULL AND i.role = ANY (ARRAY['product_main','product_gallery','variant']::image_role[])
              ORDER BY (i.role = 'product_main') DESC, i.sort_order, i.created_at LIMIT 1),
    'colors', (SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('value', ov.value, 'hex', ov.color_hex)), '[]'::jsonb)
               FROM v JOIN variant_option_values vov ON vov.variant_id = v.id
               JOIN product_options po ON po.id = vov.product_option_id AND po.kind = 'color'
               JOIN option_values ov ON ov.id = vov.option_value_id),
    'category', (SELECT jsonb_build_object('slug', c.slug, 'name', c.name) FROM categories c WHERE c.id = p.category_id),
    'published_at', p.web_published_at);
$$;
REVOKE EXECUTE ON FUNCTION fn_shop_card(storefronts, products, UUID) FROM PUBLIC, anon, authenticated;

-- Home: featured + newest, bounded. Copy-stable except availability, which is recomputed each call.
CREATE OR REPLACE FUNCTION rpc_shop_home(p_slug TEXT, p_limit INTEGER DEFAULT 8)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s storefronts; v_branch UUID; v_lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 8), 1), 24);
BEGIN
  s := fn_shop_resolve(p_slug);
  IF s.id IS NULL THEN RETURN NULL; END IF;
  v_branch := fn_shop_branch(s);
  RETURN jsonb_build_object(
    'featured', (SELECT COALESCE(jsonb_agg(fn_shop_card(s, p, v_branch) ORDER BY p.web_sort_order, p.web_published_at DESC, p.id), '[]'::jsonb)
                 FROM (SELECT id FROM products WHERE business_id = s.business_id AND web_published AND status = 'active' AND web_featured
                       ORDER BY web_sort_order, web_published_at DESC, id LIMIT v_lim) pg JOIN products p ON p.id = pg.id),
    'new_arrivals', (SELECT COALESCE(jsonb_agg(fn_shop_card(s, p, v_branch) ORDER BY p.web_published_at DESC, p.web_sort_order, p.id), '[]'::jsonb)
                     FROM (SELECT id FROM products WHERE business_id = s.business_id AND web_published AND status = 'active'
                           ORDER BY web_published_at DESC, web_sort_order, id LIMIT v_lim) pg JOIN products p ON p.id = pg.id));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_shop_home(TEXT, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_home(TEXT, INTEGER) TO anon, authenticated;

-- Listing: optional category, optional search, sort newest | price_asc | price_desc; offset pagination ≤ 48.
CREATE OR REPLACE FUNCTION rpc_shop_products(p_slug TEXT, p_category TEXT DEFAULT NULL, p_q TEXT DEFAULT NULL, p_sort TEXT DEFAULT 'newest', p_limit INTEGER DEFAULT 24, p_offset INTEGER DEFAULT 0)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s storefronts; v_branch UUID; v_lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 24), 1), 48); v_off INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
        v_q TEXT := NULLIF(trim(COALESCE(p_q, '')), ''); v_cat UUID; v_total BIGINT; v_rows JSONB; v_sort TEXT := COALESCE(p_sort, 'newest');
BEGIN
  s := fn_shop_resolve(p_slug);
  IF s.id IS NULL THEN RETURN NULL; END IF;
  IF v_sort NOT IN ('newest','price_asc','price_desc') THEN RAISE EXCEPTION 'INVALID_SORT: %', p_sort USING ERRCODE = '22023'; END IF;
  v_branch := fn_shop_branch(s);
  IF p_category IS NOT NULL THEN
    SELECT id INTO v_cat FROM categories WHERE business_id = s.business_id AND slug = p_category AND is_active;
    IF v_cat IS NULL THEN RETURN jsonb_build_object('rows', '[]'::jsonb, 'total', 0, 'limit', v_lim, 'offset', v_off, 'category', NULL); END IF;
  END IF;
  SELECT count(*) INTO v_total FROM products p
  WHERE p.business_id = s.business_id AND p.web_published AND p.status = 'active'
    AND (v_cat IS NULL OR p.category_id = v_cat)
    AND (v_q IS NULL OR COALESCE(p.web_title, p.name) ILIKE '%' || v_q || '%');
  SELECT COALESCE(jsonb_agg(fn_shop_card(s, p, v_branch) ORDER BY pg.ord), '[]'::jsonb) INTO v_rows
  FROM (SELECT p.id, row_number() OVER (ORDER BY
              CASE WHEN v_sort = 'price_asc'  THEN (SELECT min(fn_web_price(pv.id)) FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled) END ASC NULLS LAST,
              CASE WHEN v_sort = 'price_desc' THEN (SELECT max(fn_web_price(pv.id)) FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled) END DESC NULLS LAST,
              p.web_sort_order, p.web_published_at DESC, p.id) AS ord
        FROM products p
        WHERE p.business_id = s.business_id AND p.web_published AND p.status = 'active'
          AND (v_cat IS NULL OR p.category_id = v_cat)
          AND (v_q IS NULL OR COALESCE(p.web_title, p.name) ILIKE '%' || v_q || '%')
        ORDER BY ord LIMIT v_lim OFFSET v_off) pg JOIN products p ON p.id = pg.id;
  RETURN jsonb_build_object('rows', v_rows, 'total', v_total, 'limit', v_lim, 'offset', v_off,
                            'category', (SELECT jsonb_build_object('slug', c.slug, 'name', c.name) FROM categories c WHERE c.id = v_cat));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_shop_products(TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_products(TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) TO anon, authenticated;

-- Product detail: copy, images, options (color first, then size, then others) and variants with price + availability.
-- Nothing operational: no SKU, no barcode, no cost, no supplier, no notes.
CREATE OR REPLACE FUNCTION rpc_shop_product(p_slug TEXT, p_product_slug TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s storefronts; v_branch UUID; p products; v JSONB;
BEGIN
  s := fn_shop_resolve(p_slug);
  IF s.id IS NULL THEN RETURN NULL; END IF;
  v_branch := fn_shop_branch(s);
  SELECT * INTO p FROM products WHERE business_id = s.business_id AND web_slug = p_product_slug AND web_published AND status = 'active';
  IF p.id IS NULL THEN RETURN NULL; END IF;
  SELECT jsonb_build_object(
    'slug', p.web_slug, 'name', COALESCE(p.web_title, p.name), 'description', COALESCE(p.web_description, p.description),
    'currency', b.base_currency, 'stock_display', s.stock_display, 'low_stock_threshold', s.low_stock_threshold,
    'category', (SELECT jsonb_build_object('slug', c.slug, 'name', c.name) FROM categories c WHERE c.id = p.category_id),
    'images', fn_shop_product_images(p.id),
    'options', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'kind', o.kind,
                  'values', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', ov.id, 'value', ov.value, 'code', ov.code, 'hex', ov.color_hex) ORDER BY ov.sort_order, ov.value), '[]'::jsonb)
                             FROM option_values ov WHERE ov.product_option_id = o.id
                               AND EXISTS (SELECT 1 FROM variant_option_values vov JOIN product_variants pv ON pv.id = vov.variant_id
                                           WHERE vov.option_value_id = ov.id AND pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled)))
                  ORDER BY CASE o.kind WHEN 'color' THEN 0 WHEN 'size' THEN 1 ELSE 2 END, o.sort_order, o.name), '[]'::jsonb)
                FROM product_options o
                WHERE o.business_id = s.business_id
                  AND EXISTS (SELECT 1 FROM variant_option_values vov JOIN product_variants pv ON pv.id = vov.variant_id
                              WHERE vov.product_option_id = o.id AND pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled)),
    'variants', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'id', pv.id, 'price', fn_web_price(pv.id),
                   'option_value_ids', (SELECT COALESCE(jsonb_agg(vov.option_value_id), '[]'::jsonb) FROM variant_option_values vov WHERE vov.variant_id = pv.id),
                   'available', CASE WHEN s.stock_display = 'exact' THEN fn_shop_available(s.business_id, v_branch, pv.id) END,
                   'state', fn_shop_state(fn_shop_available(s.business_id, v_branch, pv.id), s.low_stock_threshold),
                   'image_id', (SELECT i.id FROM product_images i WHERE i.variant_id = pv.id AND i.public_path IS NOT NULL AND i.role = ANY (ARRAY['product_main','product_gallery','variant']::image_role[]) ORDER BY i.sort_order LIMIT 1))
                   ORDER BY pv.created_at), '[]'::jsonb)
                 FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled))
  INTO v FROM businesses b WHERE b.id = s.business_id;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_shop_product(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_product(TEXT, TEXT) TO anon, authenticated;

-- Availability only (the dynamic part, for the cart re-check). Unknown / unpublished / disabled variants come back as sold_out.
CREATE OR REPLACE FUNCTION rpc_shop_availability(p_slug TEXT, p_variant_ids UUID[])
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s storefronts; v_branch UUID;
BEGIN
  s := fn_shop_resolve(p_slug);
  IF s.id IS NULL THEN RETURN NULL; END IF;
  IF p_variant_ids IS NULL OR array_length(p_variant_ids, 1) IS NULL OR array_length(p_variant_ids, 1) > 50 THEN RAISE EXCEPTION 'INVALID_INPUT: 1–50 variants' USING ERRCODE = '22023'; END IF;
  v_branch := fn_shop_branch(s);
  -- a variant counts only while it is web-enabled, active, and its product is published in this store
  RETURN (SELECT COALESCE(jsonb_object_agg(x.vid, jsonb_build_object(
            'state', CASE WHEN p.id IS NULL THEN 'sold_out' ELSE fn_shop_state(fn_shop_available(s.business_id, v_branch, pv.id), s.low_stock_threshold) END,
            'available', CASE WHEN p.id IS NOT NULL AND s.stock_display = 'exact' THEN fn_shop_available(s.business_id, v_branch, pv.id) END,
            'price', CASE WHEN p.id IS NULL THEN NULL ELSE fn_web_price(pv.id) END,
            'product_slug', p.web_slug)), '{}'::jsonb)
          FROM unnest(p_variant_ids) AS x(vid)
          LEFT JOIN product_variants pv ON pv.id = x.vid AND pv.business_id = s.business_id AND pv.status = 'active' AND pv.web_enabled
          LEFT JOIN products p ON p.id = pv.product_id AND p.business_id = s.business_id AND p.web_published AND p.status = 'active');
END $$;
REVOKE EXECUTE ON FUNCTION rpc_shop_availability(TEXT, UUID[]) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_availability(TEXT, UUID[]) TO anon, authenticated;

-- Custom domain foundation: host → slug (not wired into routing in 14A).
CREATE OR REPLACE FUNCTION rpc_shop_resolve_host(p_host TEXT)
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT s.slug FROM storefront_domains d JOIN storefronts s ON s.id = d.storefront_id JOIN businesses b ON b.id = s.business_id
  WHERE d.host = lower(trim(COALESCE(p_host, ''))) AND d.verified_at IS NOT NULL AND s.enabled AND b.status = 'active';
$$;
REVOKE EXECUTE ON FUNCTION rpc_shop_resolve_host(TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_resolve_host(TEXT) TO anon, authenticated;

-- ------------------------------------------------------------ tenant admin RPCs (owner + manager)
-- Storefront settings (create or update). The slug is public and platform-unique.
CREATE OR REPLACE FUNCTION rpc_storefront_upsert(p_business_id UUID, p_settings JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_slug TEXT; v_name TEXT; v_branch UUID; v_display stock_display; v_id UUID; v_enabled BOOLEAN;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  v_slug := lower(trim(COALESCE(p_settings ->> 'slug', '')));
  v_name := trim(COALESCE(p_settings ->> 'store_name', ''));
  IF v_slug !~ '^[a-z0-9](?:[a-z0-9-]{1,48}[a-z0-9])$' THEN RAISE EXCEPTION 'INVALID_SLUG: 3–50 characters, a-z 0-9 and hyphens' USING ERRCODE = '22023'; END IF;
  IF length(v_name) < 2 THEN RAISE EXCEPTION 'INVALID_NAME: store name is required' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM storefronts WHERE slug = v_slug AND business_id <> p_business_id) THEN RAISE EXCEPTION 'SLUG_TAKEN: % is used by another store', v_slug USING ERRCODE = '23505'; END IF;
  v_branch := NULLIF(p_settings ->> 'fulfillment_branch_id', '')::uuid;
  IF v_branch IS NOT NULL THEN PERFORM fn_assert_branch(p_business_id, v_branch); END IF;
  BEGIN v_display := COALESCE(p_settings ->> 'stock_display', 'state')::stock_display; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_STOCK_DISPLAY: %', p_settings ->> 'stock_display' USING ERRCODE = '22023'; END;
  v_enabled := COALESCE((p_settings ->> 'enabled')::boolean, false);
  INSERT INTO storefronts (business_id, enabled, slug, store_name, tagline, announcement, about, instagram, whatsapp, contact_email, contact_phone, fulfillment_branch_id, stock_display, low_stock_threshold)
  VALUES (p_business_id, v_enabled, v_slug, v_name,
          NULLIF(trim(COALESCE(p_settings ->> 'tagline', '')), ''), NULLIF(trim(COALESCE(p_settings ->> 'announcement', '')), ''), NULLIF(trim(COALESCE(p_settings ->> 'about', '')), ''),
          NULLIF(ltrim(trim(COALESCE(p_settings ->> 'instagram', '')), '@'), ''), NULLIF(regexp_replace(COALESCE(p_settings ->> 'whatsapp', ''), '[^0-9+]', '', 'g'), ''),
          NULLIF(lower(trim(COALESCE(p_settings ->> 'contact_email', ''))), ''), NULLIF(trim(COALESCE(p_settings ->> 'contact_phone', '')), ''),
          v_branch, v_display, LEAST(GREATEST(COALESCE((p_settings ->> 'low_stock_threshold')::int, 3), 1), 50))
  ON CONFLICT (business_id) DO UPDATE SET
    enabled = EXCLUDED.enabled, slug = EXCLUDED.slug, store_name = EXCLUDED.store_name, tagline = EXCLUDED.tagline, announcement = EXCLUDED.announcement,
    about = EXCLUDED.about, instagram = EXCLUDED.instagram, whatsapp = EXCLUDED.whatsapp, contact_email = EXCLUDED.contact_email, contact_phone = EXCLUDED.contact_phone,
    fulfillment_branch_id = EXCLUDED.fulfillment_branch_id, stock_display = EXCLUDED.stock_display, low_stock_threshold = EXCLUDED.low_stock_threshold, updated_at = now()
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('storefront_id', v_id, 'slug', v_slug, 'enabled', v_enabled);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_storefront_upsert(UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_storefront_upsert(UUID, JSONB) TO authenticated;

-- Publish / unpublish a product. Publishing validates: active product, ≥ 1 active web-enabled variant with a price > 0.
-- Stock is not required (a published product may show sold out). A slug is derived when missing.
CREATE OR REPLACE FUNCTION rpc_storefront_publish_product(p_business_id UUID, p_product_id UUID, p_published BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE p RECORD; v_slug TEXT; v_base TEXT; n INTEGER := 1; v_images INTEGER;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  SELECT * INTO p FROM products WHERE id = p_product_id AND business_id = p_business_id FOR UPDATE;
  IF p.id IS NULL THEN RAISE EXCEPTION 'INVALID_PRODUCT: product % not in business', p_product_id USING ERRCODE = '22023'; END IF;
  IF NOT p_published THEN
    UPDATE products SET web_published = false, updated_at = now() WHERE id = p.id;
    RETURN jsonb_build_object('product_id', p.id, 'web_published', false);
  END IF;
  IF p.status <> 'active' THEN RAISE EXCEPTION 'NOT_ACTIVE: only an active product can be published' USING ERRCODE = '55000'; END IF;
  IF NOT EXISTS (SELECT 1 FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled) THEN
    RAISE EXCEPTION 'NO_WEB_VARIANT: at least one active, web-enabled variant is required' USING ERRCODE = '55000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled AND fn_web_price(pv.id) > 0) THEN
    RAISE EXCEPTION 'NO_PRICE: a web-enabled variant needs a selling price above zero' USING ERRCODE = '55000';
  END IF;
  v_slug := p.web_slug;
  IF v_slug IS NULL THEN
    v_base := COALESCE(fn_web_slug_for(COALESCE(p.web_title, p.name)), 'urun');
    v_base := left(v_base, 70);
    v_slug := v_base;
    WHILE EXISTS (SELECT 1 FROM products x WHERE x.business_id = p_business_id AND x.web_slug = v_slug AND x.id <> p.id) LOOP
      n := n + 1; v_slug := v_base || '-' || n::text;
    END LOOP;
  END IF;
  SELECT count(*) INTO v_images FROM product_images i WHERE i.product_id = p.id AND i.public_path IS NOT NULL;
  UPDATE products SET web_published = true, web_slug = v_slug, updated_at = now() WHERE id = p.id;
  RETURN jsonb_build_object('product_id', p.id, 'web_published', true, 'web_slug', v_slug, 'public_images', v_images);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_storefront_publish_product(UUID, UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_storefront_publish_product(UUID, UUID, BOOLEAN) TO authenticated;

-- Web copy and placement of a product (title / description / slug / featured / sort order).
CREATE OR REPLACE FUNCTION rpc_storefront_set_product_web(p_business_id UUID, p_product_id UUID, p_web JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE p RECORD; v_slug TEXT;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  SELECT * INTO p FROM products WHERE id = p_product_id AND business_id = p_business_id FOR UPDATE;
  IF p.id IS NULL THEN RAISE EXCEPTION 'INVALID_PRODUCT: product % not in business', p_product_id USING ERRCODE = '22023'; END IF;
  v_slug := NULLIF(lower(trim(COALESCE(p_web ->> 'web_slug', ''))), '');
  IF v_slug IS NOT NULL AND v_slug !~ '^[a-z0-9](?:[a-z0-9-]{0,78}[a-z0-9])?$' THEN RAISE EXCEPTION 'INVALID_SLUG: a-z 0-9 and hyphens' USING ERRCODE = '22023'; END IF;
  IF v_slug IS NOT NULL AND EXISTS (SELECT 1 FROM products x WHERE x.business_id = p_business_id AND x.web_slug = v_slug AND x.id <> p.id) THEN
    RAISE EXCEPTION 'SLUG_TAKEN: % is used by another product' , v_slug USING ERRCODE = '23505';
  END IF;
  UPDATE products SET
    web_title = NULLIF(trim(COALESCE(p_web ->> 'web_title', '')), ''),
    web_description = NULLIF(trim(COALESCE(p_web ->> 'web_description', '')), ''),
    web_slug = COALESCE(v_slug, web_slug),
    web_featured = COALESCE((p_web ->> 'web_featured')::boolean, web_featured),
    web_sort_order = COALESCE((p_web ->> 'web_sort_order')::int, web_sort_order),
    updated_at = now()
  WHERE id = p.id;
  RETURN jsonb_build_object('product_id', p.id, 'web_slug', COALESCE(v_slug, p.web_slug));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_storefront_set_product_web(UUID, UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_storefront_set_product_web(UUID, UUID, JSONB) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_storefront_set_variant_web(p_business_id UUID, p_variant_id UUID, p_enabled BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  UPDATE product_variants SET web_enabled = COALESCE(p_enabled, true), updated_at = now() WHERE id = p_variant_id AND business_id = p_business_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_VARIANT: variant % not in business', p_variant_id USING ERRCODE = '22023'; END IF;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_storefront_set_variant_web(UUID, UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_storefront_set_variant_web(UUID, UUID, BOOLEAN) TO authenticated;

-- Records (or clears) the published copy of an image. The copy itself is made by the app into the public
-- bucket; this only accepts a path under the image's own tenant/product and a public role.
CREATE OR REPLACE FUNCTION rpc_storefront_set_image_public(p_business_id UUID, p_image_id UUID, p_public_path TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE i RECORD;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  SELECT * INTO i FROM product_images WHERE id = p_image_id AND business_id = p_business_id FOR UPDATE;
  IF i.id IS NULL THEN RAISE EXCEPTION 'INVALID_IMAGE: image % not in business', p_image_id USING ERRCODE = '22023'; END IF;
  IF p_public_path IS NOT NULL AND NOT (i.role = ANY (ARRAY['product_main','product_gallery','variant']::image_role[])) THEN
    RAISE EXCEPTION 'PRIVATE_ROLE: % images are never published', i.role USING ERRCODE = '55000';
  END IF;
  UPDATE product_images SET public_path = p_public_path WHERE id = i.id;
  RETURN jsonb_build_object('image_id', i.id, 'public_path', p_public_path);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_storefront_set_image_public(UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_storefront_set_image_public(UUID, UUID, TEXT) TO authenticated;

-- Admin overview: settings + the active products with their web state (bounded, paginated).
CREATE OR REPLACE FUNCTION rpc_storefront_admin(p_business_id UUID, p_q TEXT DEFAULT NULL, p_limit INTEGER DEFAULT 50, p_offset INTEGER DEFAULT 0)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200); v_off INTEGER := GREATEST(COALESCE(p_offset, 0), 0); v_q TEXT := NULLIF(trim(COALESCE(p_q, '')), '');
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  RETURN jsonb_build_object(
    'storefront', (SELECT to_jsonb(s) - 'theme' FROM storefronts s WHERE s.business_id = p_business_id),
    'currency', (SELECT base_currency FROM businesses WHERE id = p_business_id),
    'branches', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'is_default', is_default) ORDER BY is_default DESC, name), '[]'::jsonb) FROM branches WHERE business_id = p_business_id AND status = 'active'),
    'published_count', (SELECT count(*) FROM products WHERE business_id = p_business_id AND web_published AND status = 'active'),
    'products', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'id', p.id, 'name', p.name, 'web_title', p.web_title, 'web_slug', p.web_slug, 'web_published', p.web_published, 'web_featured', p.web_featured, 'web_sort_order', p.web_sort_order,
                   'status', p.status, 'category', (SELECT c.name FROM categories c WHERE c.id = p.category_id),
                   'variants', (SELECT count(*) FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active'),
                   'web_variants', (SELECT count(*) FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled),
                   'public_images', (SELECT count(*) FROM product_images i WHERE i.product_id = p.id AND i.public_path IS NOT NULL),
                   'price_from', (SELECT min(fn_web_price(pv.id)) FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled))
                   ORDER BY p.web_published DESC, p.web_sort_order, p.name), '[]'::jsonb)
                 FROM (SELECT * FROM products WHERE business_id = p_business_id AND status = 'active' AND (v_q IS NULL OR name ILIKE '%' || v_q || '%')
                       ORDER BY web_published DESC, web_sort_order, name LIMIT v_lim OFFSET v_off) p),
    'total', (SELECT count(*) FROM products WHERE business_id = p_business_id AND status = 'active' AND (v_q IS NULL OR name ILIKE '%' || v_q || '%')));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_storefront_admin(UUID, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_storefront_admin(UUID, TEXT, INTEGER, INTEGER) TO authenticated;

-- Per-product admin view: web fields, variants with web flag + option labels, images with their public state.
CREATE OR REPLACE FUNCTION rpc_storefront_admin_product(p_business_id UUID, p_product_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v JSONB;
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  SELECT jsonb_build_object(
    'id', p.id, 'name', p.name, 'status', p.status, 'description', p.description, 'default_sale_price', p.default_sale_price,
    'web_published', p.web_published, 'web_published_at', p.web_published_at, 'web_title', p.web_title, 'web_description', p.web_description,
    'web_slug', p.web_slug, 'web_featured', p.web_featured, 'web_sort_order', p.web_sort_order,
    'variants', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', pv.id, 'sku', pv.sku, 'web_enabled', pv.web_enabled, 'price', fn_web_price(pv.id),
                   'labels', (SELECT COALESCE(string_agg(ov.value, ' / ' ORDER BY CASE po.kind WHEN 'color' THEN 0 WHEN 'size' THEN 1 ELSE 2 END, po.sort_order), '')
                              FROM variant_option_values vov JOIN option_values ov ON ov.id = vov.option_value_id JOIN product_options po ON po.id = vov.product_option_id WHERE vov.variant_id = pv.id))
                   ORDER BY pv.created_at), '[]'::jsonb)
                 FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active'),
    'images', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', i.id, 'role', i.role, 'storage_path', i.storage_path, 'public_path', i.public_path, 'alt', i.alt_text, 'variant_id', i.variant_id, 'mime_type', i.mime_type)
                 ORDER BY (i.role = 'product_main') DESC, i.sort_order, i.created_at), '[]'::jsonb)
               FROM product_images i WHERE i.product_id = p.id))
  INTO v FROM products p WHERE p.id = p_product_id AND p.business_id = p_business_id;
  IF v IS NULL THEN RAISE EXCEPTION 'INVALID_PRODUCT: product % not in business', p_product_id USING ERRCODE = '22023'; END IF;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION rpc_storefront_admin_product(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_storefront_admin_product(UUID, UUID) TO authenticated;

-- ============================================================
-- END phase 14A
-- ============================================================
