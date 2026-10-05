import type { MetadataRoute } from "next";
import { getSitemapEntries } from "@/lib/shop/queries";
import { storefrontUrl } from "@/lib/shop/seo";

/**
 * Root sitemap: only indexable public storefront URLs (enabled stores on active businesses,
 * their all-products page, categories with published products, published products). No
 * cart / checkout / tracking / filtered URLs, no operational routes. lastModified only
 * where a stored timestamp belongs to the record (products). Rebuilt at most hourly.
 */
export const revalidate = 3600;

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const rows = await getSitemapEntries();
  return rows.map((r) => ({ url: storefrontUrl(r.s, r.k, r.p), ...(r.m ? { lastModified: new Date(r.m) } : {}) }));
}
