import "server-only";

import { unstable_cache } from "next/cache";
import { createClient } from "@supabase/supabase-js";
import { publicSupabaseEnv } from "@/lib/env";
import type { AvailabilityMap, ProductList, ShopHome, ShopProduct, SortKey, Store } from "@/lib/shop/model";

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
      const { data, error } = await anon().rpc("rpc_shop_home", { p_slug: slug, p_limit: 8 });
      if (error) throw new Error(`Mağaza ana sayfası okunamadı: ${error.message}`);
      return (data ?? null) as ShopHome | null;
    },
    ["shop-home", slug],
    { revalidate: 60, tags: [shopTag(slug)] },
  )();

/** Listing page. Cached briefly per (category, query, sort, page). */
export const listProducts = (slug: string, category: string | null, q: string | null, sort: SortKey, offset: number, limit: number): Promise<ProductList | null> =>
  unstable_cache(
    async () => {
      const { data, error } = await anon().rpc("rpc_shop_products", { p_slug: slug, p_category: category, p_q: q, p_sort: sort, p_limit: limit, p_offset: offset });
      if (error) throw new Error(`Ürünler okunamadı: ${error.message}`);
      return (data ?? null) as ProductList | null;
    },
    ["shop-products", slug, category ?? "", q ?? "", sort, String(offset), String(limit)],
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

/** Fresh availability for up to 50 variants. Never cached. */
export async function getAvailability(slug: string, variantIds: string[]): Promise<AvailabilityMap> {
  if (variantIds.length === 0) return {};
  const { data, error } = await anon().rpc("rpc_shop_availability", { p_slug: slug, p_variant_ids: variantIds.slice(0, 50) });
  if (error) throw new Error(`Stok durumu okunamadı: ${error.message}`);
  return (data ?? {}) as AvailabilityMap;
}
