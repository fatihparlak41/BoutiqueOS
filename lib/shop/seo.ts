import "server-only";

import { siteOrigin } from "@/lib/url";
import { publicImageUrl, type AvailabilityMap, type ShopImage, type ShopProduct, type Store } from "@/lib/shop/model";

/**
 * Storefront SEO in ONE place: the canonical origin, absolute public URLs, metadata text
 * and JSON-LD. Pages never build canonical strings or schema objects themselves.
 *
 * Canonical origin (Phase 14C-6): the platform origin (NEXT_PUBLIC_SITE_URL), paths under
 * /shop/<slug>. Custom domains are NOT routed yet. When a later pass serves a store on a
 * verified primary domain (storefront_domains.verified_at + is_primary), only
 * `storefrontOrigin` and `storefrontPath` change — every canonical, og:url, JSON-LD url and
 * sitemap <loc> already flows through them.
 */

export type StorePathKind = "home" | "all" | "category" | "product";

/** Origin a store's public URLs live on. Today: the platform origin for every store. */
export function storefrontOrigin(_storeSlug: string): string {
  return siteOrigin();
}

/** Path of a public storefront URL (no query string — canonical URLs are always clean). */
export function storefrontPath(storeSlug: string, kind: StorePathKind = "home", key?: string | null): string {
  const base = `/shop/${storeSlug}`;
  if (kind === "all") return `${base}/urunler`;
  if (kind === "category") return `${base}/kategori/${key}`;
  if (kind === "product") return `${base}/urun/${key}`;
  return base;
}

export function storefrontUrl(storeSlug: string, kind: StorePathKind = "home", key?: string | null): string {
  return `${storefrontOrigin(storeSlug)}${storefrontPath(storeSlug, kind, key)}`;
}

/** Absolute public image URL — only ever a published storefront-images path (never private storage). */
export function seoImage(img: Pick<ShopImage, "path" | "alt" | "width" | "height"> | null | undefined, fallbackAlt: string) {
  const url = publicImageUrl(img?.path);
  if (!url || !img?.path.startsWith("store/")) return null;
  return { url, alt: img.alt ?? fallbackAlt, ...(img.width && img.height ? { width: img.width, height: img.height } : {}) };
}

/** One factual sentence for a meta description: whitespace collapsed, cut at a word, ≤ 160. */
export function metaText(text: string | null | undefined, max = 160): string | null {
  const t = (text ?? "").replace(/\s+/g, " ").trim();
  if (!t) return null;
  if (t.length <= max) return t;
  const cut = t.slice(0, max - 1);
  return `${cut.slice(0, Math.max(cut.lastIndexOf(" "), max - 40)).trim()}…`;
}

export function storeDescription(store: Store): string {
  return metaText(store.tagline) ?? metaText(store.about) ?? `${store.store_name} online mağazası.`;
}

// ------------------------------------------------------------------ JSON-LD

/**
 * Serialises JSON-LD for an inline <script type="application/ld+json">. Merchant text can
 * contain "</script>", "<!--" or line separators; escaping <, >, & and U+2028/2029 keeps
 * every value inside the JSON string literal, so nothing can close the script element.
 */
export function serializeJsonLd(data: unknown): string {
  // String.raw keeps the backslash: the output contains the six characters \u003c, not "<"
  return JSON.stringify(data)
    .replace(/</g, String.raw`\u003c`)
    .replace(/>/g, String.raw`\u003e`)
    .replace(/&/g, String.raw`\u0026`)
    .split(String.fromCharCode(0x2028)).join(String.raw`\u2028`)
    .split(String.fromCharCode(0x2029)).join(String.raw`\u2029`);
}

const storeId = (slug: string) => `${storefrontUrl(slug)}#store`;

/**
 * The store as schema.org ClothingStore — only configured, public fields: name, url,
 * description, logo, image, telephone, email, Instagram. No address (no explicitly public
 * address exists; the branch address is internal), no opening hours, no ratings.
 */
export function storeJsonLd(store: Store, image: string | null) {
  const logo = publicImageUrl(store.logo_path);
  return {
    "@context": "https://schema.org",
    "@type": "ClothingStore",
    "@id": storeId(store.slug),
    name: store.store_name,
    url: storefrontUrl(store.slug),
    description: storeDescription(store),
    ...(logo ? { logo } : {}),
    ...(image ? { image } : {}),
    ...(store.contact_phone ? { telephone: store.contact_phone } : {}),
    ...(store.contact_email ? { email: store.contact_email } : {}),
    ...(store.instagram ? { sameAs: [`https://www.instagram.com/${store.instagram}/`] } : {}),
    ...(store.currency ? { currenciesAccepted: store.currency } : {}),
  };
}

export function breadcrumbJsonLd(items: Array<{ name: string; url: string }>) {
  return {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: items.map((it, i) => ({ "@type": "ListItem", position: i + 1, name: it.name, item: it.url })),
  };
}

/**
 * Product + Offer / AggregateOffer (not ProductGroup): the page has one URL and no
 * per-variant URLs or public identifiers, so per-variant markup would have to invent them.
 * Prices are the authoritative web prices of the PUBLIC web-enabled variants, overlaid with
 * the fresh availability read; availability is "any variant sellable now" (sellable − active
 * holds, the existing public rule) and never a quantity. No SKU, barcode, id, brand, rating.
 */
export function productJsonLd(store: Store, product: ShopProduct, fresh: AvailabilityMap) {
  const url = storefrontUrl(store.slug, "product", product.slug);
  const prices = product.variants.map((v) => fresh[v.id]?.price ?? v.price).filter((p): p is number => typeof p === "number" && p > 0);
  const inStock = product.variants.some((v) => (fresh[v.id]?.state ?? v.state) !== "sold_out");
  const availability = inStock ? "https://schema.org/InStock" : "https://schema.org/OutOfStock";
  const images = product.images.map((i) => seoImage(i, product.name)?.url).filter((u): u is string => Boolean(u));
  const low = prices.length ? Math.min(...prices) : null;
  const high = prices.length ? Math.max(...prices) : null;
  const common = {
    priceCurrency: product.currency,
    availability,
    url,
    seller: { "@type": "ClothingStore", "@id": storeId(store.slug), name: store.store_name, url: storefrontUrl(store.slug) },
    ...(store.orders_enabled ? { availableDeliveryMethod: "https://schema.org/OnSitePickup" } : {}),
  };
  const offers =
    low === null
      ? undefined
      : low === high
        ? { "@type": "Offer", price: low, ...common }
        : { "@type": "AggregateOffer", lowPrice: low, highPrice: high, offerCount: prices.length, ...common };
  return {
    "@context": "https://schema.org",
    "@type": "Product",
    name: product.name,
    url,
    ...(metaText(product.description, 5000) ? { description: metaText(product.description, 5000) } : {}),
    ...(images.length ? { image: images } : {}),
    ...(product.category ? { category: product.category.name } : {}),
    ...(offers ? { offers } : {}),
  };
}
