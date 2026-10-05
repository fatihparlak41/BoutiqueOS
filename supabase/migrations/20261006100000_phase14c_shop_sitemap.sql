-- ============================================================
-- BoutiqueOS  •  Phase 14C Pass 6 — public sitemap RPC
-- ============================================================
-- The sitemap needs every indexable storefront URL across ALL tenants. No existing public
-- RPC can list stores (each takes a slug), and anon has no table privilege (ADR-25), so
-- this adds exactly ONE narrowly scoped SECURITY DEFINER read — the anon public RPC
-- allowlist grows from 10 to 11 deliberately.
--
-- It returns only data that is already public through the storefront itself:
--   * stores    — enabled storefront on an ACTIVE business (same rule as fn_shop_resolve)
--   * all       — the store's "Tüm Ürünler" listing
--   * category  — active categories that hold ≥ 1 published active product (same rule as
--                 the categories in rpc_shop_resolve)
--   * product   — web_published AND status = 'active' (same rule as rpc_shop_product)
-- Row shape: {s: store slug, k: kind, p: category/product slug | null, m: lastmod | null}.
-- No ids, no names, no prices, no customer / order data. lastmod is given only where a
-- stored timestamp belongs to the record behind the URL: products.updated_at (the row
-- carrying the public copy and web fields). Home, "all" and category pages are derived
-- views without one honest timestamp → no lastmod.
--
-- Bounded: p_limit is clamped to 1..10000 (one sitemap file holds ≤ 50000 URLs); the
-- caller pages with p_offset over a deterministic order (store, kind, key).
--
-- Rollback: DROP FUNCTION rpc_shop_sitemap(INTEGER, INTEGER). No data is touched.
-- ============================================================

CREATE OR REPLACE FUNCTION rpc_shop_sitemap(p_offset INTEGER DEFAULT 0, p_limit INTEGER DEFAULT 5000)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH stores AS (
    SELECT s.business_id, s.slug FROM storefronts s JOIN businesses b ON b.id = s.business_id
    WHERE s.enabled AND b.status = 'active'
  ), urls AS (
    SELECT st.slug AS s, 0 AS ord, 'home'::text AS k, NULL::text AS p, NULL::timestamptz AS m FROM stores st
    UNION ALL
    SELECT st.slug, 1, 'all', NULL, NULL FROM stores st
    UNION ALL
    SELECT st.slug, 2, 'category', c.slug, NULL FROM stores st JOIN categories c ON c.business_id = st.business_id
    WHERE c.is_active AND EXISTS (SELECT 1 FROM products p WHERE p.category_id = c.id AND p.web_published AND p.status = 'active')
    UNION ALL
    SELECT st.slug, 3, 'product', p.web_slug, p.updated_at FROM stores st JOIN products p ON p.business_id = st.business_id
    WHERE p.web_published AND p.status = 'active' AND p.web_slug IS NOT NULL
  ), page AS (
    SELECT * FROM urls ORDER BY s, ord, p NULLS FIRST
    OFFSET GREATEST(COALESCE(p_offset, 0), 0) LIMIT LEAST(GREATEST(COALESCE(p_limit, 5000), 1), 10000)
  )
  SELECT jsonb_build_object(
    'rows', COALESCE((SELECT jsonb_agg(jsonb_build_object('s', s, 'k', k, 'p', p, 'm', m) ORDER BY s, ord, p NULLS FIRST) FROM page), '[]'::jsonb),
    'total', (SELECT count(*) FROM urls));
$$;
REVOKE EXECUTE ON FUNCTION rpc_shop_sitemap(INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION rpc_shop_sitemap(INTEGER, INTEGER) TO anon, authenticated;
