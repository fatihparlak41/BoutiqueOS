-- ============================================================
-- BoutiqueOS  •  Phase 14C Pass 2  •  public listing filters
-- ============================================================
-- rpc_shop_products gains customer filters — colour, size, "only in stock" — and returns
-- the filter vocabulary (facets) of the current scope in the same call. Nothing else in
-- the public API changes; anon still reaches data only through this SECURITY DEFINER RPC.
--
-- Matching is per VARIANT: a product matches when ONE of its sellable web variants (active,
-- web_enabled) carries one of the chosen colours AND one of the chosen sizes AND, with
-- p_in_stock, is available now (fn_shop_available: sellable − active holds; no second stock
-- rule). "Siyah + M" therefore never matches a product that only has Siyah S and Bej M,
-- and a disabled variant can never make a product match.
--
-- Values are the public option-value names already published on product pages
-- (option_values.value of colour / size options); there is no enum and no UUID in the URL.
-- Facets list only values carried by published products' web variants in the current
-- category + search scope (they ignore the colour/size/stock filters themselves, so a
-- choice never makes its siblings disappear).
--
-- fn_shop_card adds `image_hover` (the second public product image, if any — same public
-- roles as `image`) and returns colours in option order instead of DISTINCT order.
--
-- Page size stays bounded: at most 96 rows per call (load-more shows ≤ 4 × 24).
-- Rollback: restore the 14A rpc_shop_products and fn_shop_card bodies. No data is written.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_shop_card(s storefronts, p products, p_branch UUID)
RETURNS JSONB LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  WITH v AS (
    SELECT pv.id, fn_web_price(pv.id) AS price, fn_shop_available(s.business_id, p_branch, pv.id) AS avail
    FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled
  ), img AS (
    SELECT i.public_path, i.alt_text, i.width, i.height,
           row_number() OVER (ORDER BY (i.role = 'product_main') DESC, i.sort_order, i.created_at) AS n
    FROM product_images i
    WHERE i.product_id = p.id AND i.public_path IS NOT NULL AND i.role = ANY (ARRAY['product_main','product_gallery','variant']::image_role[])
  ), col AS (
    SELECT DISTINCT ON (ov.value) ov.value, ov.color_hex, po.sort_order AS po_sort, ov.sort_order AS ov_sort
    FROM v JOIN variant_option_values vov ON vov.variant_id = v.id
    JOIN product_options po ON po.id = vov.product_option_id AND po.kind = 'color'
    JOIN option_values ov ON ov.id = vov.option_value_id
    ORDER BY ov.value, po.sort_order, ov.sort_order
  )
  SELECT jsonb_build_object(
    'slug', p.web_slug, 'name', COALESCE(p.web_title, p.name), 'featured', p.web_featured,
    'price_from', (SELECT min(price) FROM v), 'price_to', (SELECT max(price) FROM v),
    'availability', fn_shop_state((SELECT COALESCE(sum(avail), 0)::int FROM v), s.low_stock_threshold),
    'image', (SELECT jsonb_build_object('path', public_path, 'alt', alt_text, 'width', width, 'height', height) FROM img WHERE n = 1),
    'image_hover', (SELECT jsonb_build_object('path', public_path, 'alt', alt_text, 'width', width, 'height', height) FROM img WHERE n = 2),
    'colors', (SELECT COALESCE(jsonb_agg(jsonb_build_object('value', value, 'hex', color_hex) ORDER BY po_sort, ov_sort, value), '[]'::jsonb) FROM col),
    'category', (SELECT jsonb_build_object('slug', c.slug, 'name', c.name) FROM categories c WHERE c.id = p.category_id),
    'published_at', p.web_published_at);
$$;
REVOKE EXECUTE ON FUNCTION fn_shop_card(storefronts, products, UUID) FROM PUBLIC, anon, authenticated;

-- Does this product have ONE sellable web variant that satisfies every chosen facet?
CREATE OR REPLACE FUNCTION fn_shop_product_matches(p_business UUID, p_branch UUID, p_product UUID, p_colors TEXT[], p_sizes TEXT[], p_in_stock BOOLEAN)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM product_variants pv
    WHERE pv.product_id = p_product AND pv.status = 'active' AND pv.web_enabled
      AND (p_colors IS NULL OR EXISTS (
            SELECT 1 FROM variant_option_values vov
            JOIN product_options po ON po.id = vov.product_option_id AND po.kind = 'color'
            JOIN option_values ov ON ov.id = vov.option_value_id
            WHERE vov.variant_id = pv.id AND ov.value = ANY (p_colors)))
      AND (p_sizes IS NULL OR EXISTS (
            SELECT 1 FROM variant_option_values vov
            JOIN product_options po ON po.id = vov.product_option_id AND po.kind = 'size'
            JOIN option_values ov ON ov.id = vov.option_value_id
            WHERE vov.variant_id = pv.id AND ov.value = ANY (p_sizes)))
      AND (NOT p_in_stock OR fn_shop_available(p_business, p_branch, pv.id) > 0));
$$;
REVOKE EXECUTE ON FUNCTION fn_shop_product_matches(UUID, UUID, UUID, TEXT[], TEXT[], BOOLEAN) FROM PUBLIC, anon, authenticated;

-- Normalise a filter list: trimmed, non-empty, ≤ 60 chars, ≤ 20 values; NULL when nothing is left.
CREATE OR REPLACE FUNCTION fn_shop_filter_values(p TEXT[])
RETURNS TEXT[] LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public AS $$
  SELECT NULLIF(ARRAY(SELECT DISTINCT left(trim(x), 60) FROM unnest(COALESCE(p, ARRAY[]::TEXT[])) x
                      WHERE length(trim(x)) > 0 LIMIT 20), ARRAY[]::TEXT[]);
$$;
REVOKE EXECUTE ON FUNCTION fn_shop_filter_values(TEXT[]) FROM PUBLIC, anon, authenticated;

DROP FUNCTION rpc_shop_products(TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER);

-- Listing: category, search, colour, size, in-stock, sort newest | price_asc | price_desc; ≤ 96 rows.
-- STABLE and side-effect free: the matching ids are computed once, in display order, into an
-- array (a boutique catalogue is small; the array never leaves the function).
CREATE OR REPLACE FUNCTION rpc_shop_products(
  p_slug TEXT, p_category TEXT DEFAULT NULL, p_q TEXT DEFAULT NULL, p_sort TEXT DEFAULT 'newest',
  p_limit INTEGER DEFAULT 24, p_offset INTEGER DEFAULT 0,
  p_color TEXT[] DEFAULT NULL, p_size TEXT[] DEFAULT NULL, p_in_stock BOOLEAN DEFAULT false
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s storefronts; v_branch UUID; v_lim INTEGER := LEAST(GREATEST(COALESCE(p_limit, 24), 1), 96); v_off INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
        v_q TEXT := NULLIF(trim(COALESCE(p_q, '')), ''); v_cat UUID; v_ids UUID[]; v_rows JSONB; v_facets JSONB; v_sort TEXT := COALESCE(p_sort, 'newest');
        v_colors TEXT[] := fn_shop_filter_values(p_color); v_sizes TEXT[] := fn_shop_filter_values(p_size); v_stock BOOLEAN := COALESCE(p_in_stock, false);
        v_filtered BOOLEAN;
BEGIN
  s := fn_shop_resolve(p_slug);
  IF s.id IS NULL THEN RETURN NULL; END IF;
  IF v_sort NOT IN ('newest','price_asc','price_desc') THEN RAISE EXCEPTION 'INVALID_SORT: %', p_sort USING ERRCODE = '22023'; END IF;
  v_branch := fn_shop_branch(s);
  v_filtered := v_colors IS NOT NULL OR v_sizes IS NOT NULL OR v_stock;
  IF p_category IS NOT NULL THEN
    SELECT id INTO v_cat FROM categories WHERE business_id = s.business_id AND slug = p_category AND is_active;
    IF v_cat IS NULL THEN
      RETURN jsonb_build_object('rows', '[]'::jsonb, 'total', 0, 'limit', v_lim, 'offset', v_off, 'category', NULL,
                                'facets', jsonb_build_object('colors', '[]'::jsonb, 'sizes', '[]'::jsonb));
    END IF;
  END IF;

  -- every matching product, in display order (scope: published, active, category, search on name / public title)
  SELECT COALESCE(array_agg(x.id ORDER BY x.ord), ARRAY[]::UUID[]) INTO v_ids
  FROM (SELECT p.id, row_number() OVER (ORDER BY
              CASE WHEN v_sort = 'price_asc'  THEN (SELECT min(fn_web_price(pv.id)) FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled) END ASC NULLS LAST,
              CASE WHEN v_sort = 'price_desc' THEN (SELECT max(fn_web_price(pv.id)) FROM product_variants pv WHERE pv.product_id = p.id AND pv.status = 'active' AND pv.web_enabled) END DESC NULLS LAST,
              p.web_sort_order, p.web_published_at DESC, p.id) AS ord
        FROM products p
        WHERE p.business_id = s.business_id AND p.web_published AND p.status = 'active'
          AND (v_cat IS NULL OR p.category_id = v_cat)
          AND (v_q IS NULL OR COALESCE(p.web_title, p.name) ILIKE '%' || v_q || '%')
          AND (NOT v_filtered OR fn_shop_product_matches(s.business_id, v_branch, p.id, v_colors, v_sizes, v_stock))) x;

  SELECT COALESCE(jsonb_agg(fn_shop_card(s, p, v_branch) ORDER BY w.n), '[]'::jsonb) INTO v_rows
  FROM unnest(v_ids[v_off + 1 : v_off + v_lim]) WITH ORDINALITY AS w(id, n) JOIN products p ON p.id = w.id;

  -- filter vocabulary of the scope (web variants of published products; colour/size/stock filters not applied)
  WITH scope AS (
    SELECT p.id FROM products p
    WHERE p.business_id = s.business_id AND p.web_published AND p.status = 'active'
      AND (v_cat IS NULL OR p.category_id = v_cat)
      AND (v_q IS NULL OR COALESCE(p.web_title, p.name) ILIKE '%' || v_q || '%')
  ), vals AS (
    SELECT po.kind, ov.value, ov.color_hex, po.sort_order AS po_sort, ov.sort_order AS ov_sort
    FROM scope sc JOIN product_variants pv ON pv.product_id = sc.id AND pv.status = 'active' AND pv.web_enabled
    JOIN variant_option_values vov ON vov.variant_id = pv.id
    JOIN product_options po ON po.id = vov.product_option_id AND po.kind IN ('color', 'size')
    JOIN option_values ov ON ov.id = vov.option_value_id
  ), uniq AS (
    SELECT DISTINCT ON (kind, value) kind, value, color_hex, po_sort, ov_sort FROM vals ORDER BY kind, value, po_sort, ov_sort
  )
  SELECT jsonb_build_object(
    'colors', COALESCE((SELECT jsonb_agg(jsonb_build_object('value', value, 'hex', color_hex) ORDER BY po_sort, ov_sort, value) FROM uniq WHERE kind = 'color'), '[]'::jsonb),
    'sizes',  COALESCE((SELECT jsonb_agg(jsonb_build_object('value', value) ORDER BY po_sort, ov_sort, value) FROM uniq WHERE kind = 'size'), '[]'::jsonb))
  INTO v_facets;

  RETURN jsonb_build_object('rows', v_rows, 'total', cardinality(v_ids), 'limit', v_lim, 'offset', v_off,
                            'category', (SELECT jsonb_build_object('slug', c.slug, 'name', c.name) FROM categories c WHERE c.id = v_cat),
                            'facets', v_facets);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_shop_products(TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT[], TEXT[], BOOLEAN) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_products(TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER, TEXT[], TEXT[], BOOLEAN) TO anon, authenticated;

-- ============================================================
-- END phase 14C pass 2
-- ============================================================
