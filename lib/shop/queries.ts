import "server-only";

import { unstable_cache } from "next/cache";
import { createClient } from "@supabase/supabase-js";
import { publicSupabaseEnv } from "@/lib/env";
import type { AvailabilityMap, ListingFilters, ProductList, PublicOrder, ShopHome, ShopProduct, Store } from "@/lib/shop/model";

/**
 * Public storefront reads. No cookies, no session, no tenant bootstrap: one anon client
 * and one explicitly shaped RPC per page. The catalogue copy (store, product, listing
 * cards) is cached for a short while and invalidated by tag when a merchant publishes;
 * availability is never cached — it is re-read on every request and by the cart.
 */

function anon() {
  const { url, anonKey } = publicSupabaseEnv();
  return createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } });
}

export const shopTag = (slug: string) => `shop:${slug}`;

/** Store identity + navigation. Cached 2 min; null when unknown / disabled. */
export const getStore = (slug: string): Promise<Store | null> =>
  unstable_cache(
    async () => {
      const { data, error } = await anon().rpc("rpc_shop_resolve", { p_slug: slug });
      if (error) throw new Error(`Mağaza okunamadı: ${error.message}`);
      return (data ?? null) as Store | null;
    },
    ["shop-resolve", slug],
    { revalidate: 120, tags: [shopTag(slug)] },
  )();

/** Home sections. Cards carry availability, so this is cached only briefly. */
export const getHome = (slug: string): Promise<ShopHome | null> =>
  unstable_cache(
    async () => {
      const { data, error } = await anon().rpc("rpc_shop_home", { p_slug: slug, p_limit: 4 });
      if (error) throw new Error(`Mağaza ana sayfası okunamadı: ${error.message}`);
      return (data ?? null) as ShopHome | null;
    },
    ["shop-home-v2", slug],
    { revalidate: 60, tags: [shopTag(slug)] },
  )();

/**
 * Listing page. Cached briefly per (category, query, filters, sort, window). Filtering is
 * server authoritative (rpc_shop_products); the browser only names public option values.
 */
export const listProducts = (
  slug: string,
  category: string | null,
  filters: ListingFilters,
  offset: number,
  limit: number,
): Promise<ProductList | null> =>
  unstable_cache(
    async () => {
      const { data, error } = await anon().rpc("rpc_shop_products", {
        p_slug: slug,
        p_category: category,
        p_q: filters.q,
        p_sort: filters.sort,
        p_limit: limit,
        p_offset: offset,
        p_color: filters.colors.length ? filters.colors : null,
        p_size: filters.sizes.length ? filters.sizes : null,
        p_in_stock: filters.inStock,
      });
      if (error) throw new Error(`Ürünler okunamadı: ${error.message}`);
      return (data ?? null) as ProductList | null;
    },
    ["shop-products", slug, category ?? "", filters.q ?? "", filters.sort, JSON.stringify(filters.colors), JSON.stringify(filters.sizes), filters.inStock ? "1" : "0", String(offset), String(limit)],
    { revalidate: 60, tags: [shopTag(slug)] },
  )();

/**
 * Product copy, images, options and variants. The per-variant state inside is a snapshot
 * of the cache moment; the page overlays fresh availability from getAvailability.
 */
export const getProduct = (slug: string, productSlug: string): Promise<ShopProduct | null> =>
  unstable_cache(
    async () => {
      const { data, error } = await anon().rpc("rpc_shop_product", { p_slug: slug, p_product_slug: productSlug });
      if (error) throw new Error(`Ürün okunamadı: ${error.message}`);
      return (data ?? null) as ShopProduct | null;
    },
    ["shop-product", slug, productSlug],
    { revalidate: 300, tags: [shopTag(slug)] },
  )();

export type SitemapRow = { s: string; k: "home" | "all" | "category" | "product"; p: string | null; m: string | null };
/** One sitemap file holds ≤ 50 000 URLs; beyond that, split with generateSitemaps (same RPC, offset ranges). */
export const SITEMAP_MAX_URLS = 50000;
const SITEMAP_PAGE = 5000;

/**
 * Every indexable public storefront URL across tenants, from the one public sitemap RPC
 * (published-only by construction). Paged in 5000-row steps, capped at one sitemap file;
 * cached for an hour under its own tag.
 */
export const getSitemapEntries = (): Promise<SitemapRow[]> =>
  unstable_cache(
    async () => {
      const rows: SitemapRow[] = [];
      for (let offset = 0; offset < SITEMAP_MAX_URLS; offset += SITEMAP_PAGE) {
        const { data, error } = await anon().rpc("rpc_shop_sitemap", { p_offset: offset, p_limit: SITEMAP_PAGE });
        if (error) throw new Error(`Site haritası okunamadı: ${error.message}`);
        const page = ((data as { rows?: SitemapRow[] } | null)?.rows ?? []);
        rows.push(...page);
        if (page.length < SITEMAP_PAGE) break;
      }
      return rows.slice(0, SITEMAP_MAX_URLS);
    },
    ["shop-sitemap"],
    { revalidate: 3600, tags: ["shop-sitemap"] },
  )();

/** Fresh availability for up to 50 variants. Never cached. */
export async function getAvailability(slug: string, variantIds: string[]): Promise<AvailabilityMap> {
  if (variantIds.length === 0) return {};
  const { data, error } = await anon().rpc("rpc_shop_availability", { p_slug: slug, p_variant_ids: variantIds.slice(0, 50) });
  if (error) throw new Error(`Stok durumu okunamadı: ${error.message}`);
  return (data ?? {}) as AvailabilityMap;
}

/** The customer's order by tracking token. Never cached; null for any unknown token. */
export async function getPublicOrder(slug: string, token: string): Promise<PublicOrder | null> {
  if (!/^[0-9a-f]{64}$/.test(token)) return null;
  const { data, error } = await anon().rpc("rpc_shop_order", { p_slug: slug, p_token: token });
  if (error) throw new Error(`Sipariş okunamadı: ${error.message}`);
  return (data ?? null) as PublicOrder | null;
}

