import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getAvailability, getProduct, getStore, listProducts } from "@/lib/shop/queries";
import { JsonLd } from "@/components/shop/json-ld";
import { breadcrumbJsonLd, metaText, productJsonLd, seoImage, storefrontUrl } from "@/lib/shop/seo";
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
  // unknown / unpublished / disabled: nothing about the record leaks before notFound()
  if (!store || !product) return { title: "Ürün bulunamadı", robots: { index: false, follow: false } };
  const description = metaText(product.description) ?? `${product.name}${product.category ? ` — ${product.category.name}` : ""} · ${store.store_name}`;
  const url = storefrontUrl(store.slug, "product", product.slug);
  const img = seoImage(product.images[0], product.name);
  return {
    title: product.name,
    description,
    alternates: { canonical: url },
    openGraph: { title: `${product.name} | ${store.store_name}`, description, url, type: "website", siteName: store.store_name, images: img ? [img] : undefined },
    twitter: { card: img ? "summary_large_image" : "summary", title: `${product.name} | ${store.store_name}`, description, images: img ? [img.url] : undefined },
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

  const crumbs = [
    { name: store.store_name, url: storefrontUrl(store.slug) },
    ...(product.category ? [{ name: product.category.name, url: storefrontUrl(store.slug, "category", product.category.slug) }] : []),
    { name: product.name, url: storefrontUrl(store.slug, "product", product.slug) },
  ];
  return (
    <>
      <JsonLd data={productJsonLd(store, product, fresh)} />
      <JsonLd data={breadcrumbJsonLd(crumbs)} />
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
