import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getAvailability, getProduct, getStore, listProducts } from "@/lib/shop/queries";
import { publicImageUrl } from "@/lib/shop/model";
import { siteOrigin } from "@/lib/url";
import { ProductView } from "@/components/shop/product-view";
import { ProductGrid } from "@/components/shop/product-card";

/**
 * Public product page. Copy, images and options come from the cached product read;
 * availability is fetched fresh on every request and overlaid on the variants. Related
 * products are ONE bounded, cached public listing read (same category, newest, 5 rows,
 * the current product removed). The JSON-LD offer carries price, currency and an
 * availability state — nothing internal.
 */
export async function generateMetadata({ params }: { params: Promise<{ slug: string; pslug: string }> }): Promise<Metadata> {
  const { slug, pslug } = await params;
  const [store, product] = await Promise.all([getStore(slug), getProduct(slug, pslug)]);
  if (!store || !product) return { title: "Ürün bulunamadı" };
  const img = publicImageUrl(product.images[0]?.path);
  const description = (product.description ?? `${product.name} — ${store.store_name}`).slice(0, 160);
  return {
    title: product.name,
    description,
    alternates: { canonical: `/shop/${slug}/urun/${product.slug}` },
    openGraph: { title: product.name, description, type: "website", images: img ? [{ url: img }] : undefined, siteName: store.store_name },
  };
}

const RELATED = 4;

export default async function ProductPage({ params }: { params: Promise<{ slug: string; pslug: string }> }) {
  const { slug, pslug } = await params;
  const [store, product] = await Promise.all([getStore(slug), getProduct(slug, pslug)]);
  if (!store || !product) notFound();
  const [fresh, related] = await Promise.all([
    getAvailability(slug, product.variants.map((v) => v.id)),
    listProducts(slug, product.category?.slug ?? null, { q: null, colors: [], sizes: [], inStock: false, sort: "newest" }, 0, RELATED + 1),
  ]);
  const relatedCards = (related?.rows ?? []).filter((c) => c.slug !== product.slug).slice(0, RELATED);

  const prices = product.variants.map((v) => fresh[v.id]?.price ?? v.price);
  const anyLive = product.variants.some((v) => (fresh[v.id]?.state ?? v.state) !== "sold_out");
  const origin = siteOrigin();
  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "Product",
    name: product.name,
    description: product.description ?? undefined,
    image: product.images.map((i) => publicImageUrl(i.path)).filter(Boolean),
    brand: { "@type": "Brand", name: store.store_name },
    offers: prices.length
      ? {
          "@type": "AggregateOffer",
          priceCurrency: product.currency,
          lowPrice: Math.min(...prices),
          highPrice: Math.max(...prices),
          offerCount: product.variants.length,
          availability: anyLive ? "https://schema.org/InStock" : "https://schema.org/OutOfStock",
          url: `${origin}/shop/${slug}/urun/${product.slug}`,
        }
      : undefined,
  };
  return (
    <>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }} />
      <ProductView store={store} product={product} fresh={fresh} />
      {relatedCards.length > 0 ? (
        <section className="shop-related" aria-labelledby="shop-related-title" data-testid="shop-related">
          <h2 id="shop-related-title" className="shop-related-title">Benzer Ürünler</h2>
          <ProductGrid slug={slug} cards={relatedCards} currency={store.currency} variant="catalog" />
        </section>
      ) : null}
    </>
  );
}
