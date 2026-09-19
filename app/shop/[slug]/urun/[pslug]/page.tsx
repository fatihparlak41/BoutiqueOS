import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getAvailability, getProduct, getStore } from "@/lib/shop/queries";
import { publicImageUrl } from "@/lib/shop/model";
import { siteOrigin } from "@/lib/url";
import { ProductView } from "@/components/shop/product-view";

/**
 * Public product page. Copy, images and options come from the cached product read;
 * availability is fetched fresh on every request and overlaid on the variants. The
 * JSON-LD offer carries price, currency and an availability state — nothing internal.
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

export default async function ProductPage({ params }: { params: Promise<{ slug: string; pslug: string }> }) {
  const { slug, pslug } = await params;
  const [store, product] = await Promise.all([getStore(slug), getProduct(slug, pslug)]);
  if (!store || !product) notFound();
  const fresh = await getAvailability(slug, product.variants.map((v) => v.id));
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
      <ProductView slug={slug} product={product} fresh={fresh} />
    </>
  );
}
