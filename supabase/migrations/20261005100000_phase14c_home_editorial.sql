-- ============================================================
-- BoutiqueOS  •  Phase 14C Pass 5 — editorial homepage: hero + logo media, category blocks
-- ============================================================
-- Schema (deliberately minimal — no page builder, no sections JSON, no theme editor):
--   * storefronts.hero_image_path — the one editorial image of the homepage. Lives in the
--     public storefront-images bucket at store/<own business>/hero/<uuid>.<ext>.
--   * storefronts.hero_heading    — optional short line over the hero CTA (≤ 80). It is not
--     the tagline (tagline is the store's standing line, also used as meta description) and
--     not the announcement (one-line notice bar), so it gets its own column.
--   tagline / about / announcement / logo_path are reused as they are.
--
-- Media security (same model as published product copies, ADR-21):
--   * the object is uploaded by the app with the merchant's own session; the existing
--     storage policy pol_storefront_images_insert already requires manager+ of the business
--     named by the path's tenant segment (and an active business);
--   * rpc_storefront_set_media (owner/manager) records a path only if it is exactly
--     store/<this business>/{logo|hero}/<uuid>.<jpg|png|webp> AND the object exists in the
--     public bucket — no foreign tenant, no product copy, no private bucket path, no free text;
--   * CHECK constraints bind both columns to the row's own business id, so even a superuser
--     write cannot point a store at another tenant's media. The 14A logo_path CHECK only
--     tested the prefix shape; the new one adds the tenant binding (DEV: 0 logos set).
--   * label_tag / receiving_proof never reach this bucket (they are product_images roles;
--     store media is a separate namespace).
--
-- Public reads: rpc_shop_resolve gains hero_image_path + hero_heading (public paths only);
-- rpc_shop_home gains `categories` — published categories with an image taken from their
-- newest published product that has a public image (bounded at 6). No new public RPC; the
-- homepage stays at resolve (shared with the layout) + home.
--
-- Rollback: drop rpc_storefront_set_media, the two CHECKs and the two columns, and restore
-- the 14B rpc_storefront_upsert / rpc_shop_resolve and 14A rpc_shop_home bodies.
-- ============================================================

ALTER TABLE storefronts
  ADD COLUMN hero_image_path TEXT,
  ADD COLUMN hero_heading    TEXT CHECK (hero_heading IS NULL OR length(hero_heading) BETWEEN 1 AND 80);

ALTER TABLE storefronts
  ADD CONSTRAINT chk_storefronts_hero_path CHECK (hero_image_path IS NULL OR hero_image_path ~ ('^store/' || business_id::text || '/hero/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$')),
  ADD CONSTRAINT chk_storefronts_logo_tenant CHECK (logo_path IS NULL OR logo_path ~ ('^store/' || business_id::text || '/logo/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'));

-- ------------------------------------------------------------ media (logo / hero)
CREATE OR REPLACE FUNCTION rpc_storefront_set_media(p_business_id UUID, p_kind TEXT, p_path TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s storefronts; v_prev TEXT; v_path TEXT := NULLIF(trim(COALESCE(p_path, '')), '');
BEGIN
  PERFORM fn_require_role(p_business_id, ARRAY['owner','manager']::user_role[]);
  IF p_kind IS NULL OR p_kind NOT IN ('logo', 'hero') THEN RAISE EXCEPTION 'INVALID_KIND: % (logo | hero)', p_kind USING ERRCODE = '22023'; END IF;
  IF v_path IS NOT NULL THEN
    IF v_path !~ ('^store/' || p_business_id::text || '/' || p_kind || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$') THEN
      RAISE EXCEPTION 'INVALID_PATH: % is not a % path of this store', v_path, p_kind USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'storefront-images' AND o.name = v_path) THEN
      RAISE EXCEPTION 'MEDIA_NOT_FOUND: upload the file first' USING ERRCODE = '22023';
    END IF;
  END IF;
  SELECT * INTO s FROM storefronts WHERE business_id = p_business_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'STORE_NOT_FOUND: save the store settings first' USING ERRCODE = '55000'; END IF;
  IF p_kind = 'logo' THEN
    v_prev := s.logo_path;
    UPDATE storefronts SET logo_path = v_path, updated_at = now() WHERE id = s.id;
  ELSE
    v_prev := s.hero_image_path;
    UPDATE storefronts SET hero_image_path = v_path, updated_at = now() WHERE id = s.id;
  END IF;
  RETURN jsonb_build_object('kind', p_kind, 'path', v_path, 'previous_path', NULLIF(v_prev, v_path), 'slug', s.slug);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_storefront_set_media(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_storefront_set_media(UUID, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------ settings gain hero_heading (same signature, body only)
CREATE OR REPLACE FUNCTION rpc_storefront_upsert(p_business_id UUID, p_settings JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_slug TEXT; v_name TEXT; v_branch UUID; v_display stock_display; v_id UUID; v_enabled BOOLEAN; v_orders BOOLEAN; v_hold INTEGER; v_heading TEXT;
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
  v_orders := COALESCE((p_settings ->> 'orders_enabled')::boolean, true);
  v_hold := LEAST(GREATEST(COALESCE((p_settings ->> 'order_hold_minutes')::int, 1440), 30), 10080);
  v_heading := NULLIF(trim(COALESCE(p_settings ->> 'hero_heading', '')), '');
  IF v_heading IS NOT NULL AND length(v_heading) > 80 THEN RAISE EXCEPTION 'INVALID_HERO_HEADING: at most 80 characters' USING ERRCODE = '22023'; END IF;
  INSERT INTO storefronts (business_id, enabled, slug, store_name, tagline, announcement, about, instagram, whatsapp, contact_email, contact_phone, fulfillment_branch_id, stock_display, low_stock_threshold,
                           orders_enabled, order_hold_minutes, pickup_note, hero_heading)
  VALUES (p_business_id, v_enabled, v_slug, v_name,
          NULLIF(trim(COALESCE(p_settings ->> 'tagline', '')), ''), NULLIF(trim(COALESCE(p_settings ->> 'announcement', '')), ''), NULLIF(trim(COALESCE(p_settings ->> 'about', '')), ''),
          NULLIF(ltrim(trim(COALESCE(p_settings ->> 'instagram', '')), '@'), ''), NULLIF(regexp_replace(COALESCE(p_settings ->> 'whatsapp', ''), '[^0-9+]', '', 'g'), ''),
          NULLIF(lower(trim(COALESCE(p_settings ->> 'contact_email', ''))), ''), NULLIF(trim(COALESCE(p_settings ->> 'contact_phone', '')), ''),
          v_branch, v_display, LEAST(GREATEST(COALESCE((p_settings ->> 'low_stock_threshold')::int, 3), 1), 50),
          v_orders, v_hold, NULLIF(left(trim(COALESCE(p_settings ->> 'pickup_note', '')), 300), ''), v_heading)
  ON CONFLICT (business_id) DO UPDATE SET
    enabled = EXCLUDED.enabled, slug = EXCLUDED.slug, store_name = EXCLUDED.store_name, tagline = EXCLUDED.tagline, announcement = EXCLUDED.announcement,
    about = EXCLUDED.about, instagram = EXCLUDED.instagram, whatsapp = EXCLUDED.whatsapp, contact_email = EXCLUDED.contact_email, contact_phone = EXCLUDED.contact_phone,
    fulfillment_branch_id = EXCLUDED.fulfillment_branch_id, stock_display = EXCLUDED.stock_display, low_stock_threshold = EXCLUDED.low_stock_threshold,
    orders_enabled = EXCLUDED.orders_enabled, order_hold_minutes = EXCLUDED.order_hold_minutes, pickup_note = EXCLUDED.pickup_note,
    hero_heading = EXCLUDED.hero_heading, updated_at = now()
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('storefront_id', v_id, 'slug', v_slug, 'enabled', v_enabled);
END $$;
REVOKE EXECUTE ON FUNCTION rpc_storefront_upsert(UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_storefront_upsert(UUID, JSONB) TO authenticated;

-- ------------------------------------------------------------ public resolve gains the hero (same signature, body only)
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
    'logo_path', s.logo_path, 'hero_image_path', s.hero_image_path, 'hero_heading', s.hero_heading,
    'theme', s.theme, 'stock_display', s.stock_display, 'low_stock_threshold', s.low_stock_threshold,
    'currency', b.base_currency,
    'orders_enabled', (s.orders_enabled AND v_branch IS NOT NULL), 'order_hold_minutes', s.order_hold_minutes, 'pickup_note', s.pickup_note,
    'pickup_branch', (SELECT br.name FROM branches br WHERE br.id = v_branch),
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

-- ------------------------------------------------------------ home gains category blocks (same signature, body only)
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
                           ORDER BY web_published_at DESC, web_sort_order, id LIMIT v_lim) pg JOIN products p ON p.id = pg.id),
    -- editorial category blocks: only categories that have a published product with a public image
    'categories', (SELECT COALESCE(jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name, 'count', x.n, 'image', x.image) ORDER BY x.sort_order, x.name), '[]'::jsonb)
                   FROM (SELECT y.* FROM (SELECT c.slug, c.name, c.sort_order,
                                (SELECT count(*) FROM products p WHERE p.category_id = c.id AND p.web_published AND p.status = 'active') AS n,
                                (SELECT jsonb_build_object('path', i.public_path, 'alt', i.alt_text, 'width', i.width, 'height', i.height)
                                 FROM products p JOIN product_images i ON i.product_id = p.id
                                 WHERE p.category_id = c.id AND p.web_published AND p.status = 'active'
                                   AND i.public_path IS NOT NULL AND i.role = ANY (ARRAY['product_main','product_gallery','variant']::image_role[])
                                 ORDER BY p.web_published_at DESC NULLS LAST, (i.role = 'product_main') DESC, i.sort_order, i.created_at
                                 LIMIT 1) AS image
                         FROM categories c
                         WHERE c.business_id = s.business_id AND c.is_active) y
                         WHERE y.image IS NOT NULL AND y.n > 0
                         ORDER BY y.sort_order, y.name
                         LIMIT 6) x));
END $$;
REVOKE EXECUTE ON FUNCTION rpc_shop_home(TEXT, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_home(TEXT, INTEGER) TO anon, authenticated;
