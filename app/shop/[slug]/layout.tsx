import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getStore } from "@/lib/shop/queries";
import { siteOrigin } from "@/lib/url";
import { ShopHeader } from "@/components/shop/header";
import { ShopFooter } from "@/components/shop/footer";

/**
 * Public storefront shell. No session, no tenant bootstrap, no admin chrome: the store
 * is resolved once by its slug (cached) and everything below reads through the
 * read-only public RPCs. An unknown or disabled store is a plain 404 (app/shop/not-found);
 * a missing page inside a live store renders the store's own 404 ([slug]/not-found).
 */
export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const { slug } = await params;
  const store = await getStore(slug);
  if (!store) return { title: "Sayfa bulunamadı", robots: { index: false, follow: false } };
  return {
    title: { default: store.store_name, template: `%s · ${store.store_name}` },
    description: store.tagline ?? `${store.store_name} online mağaza`,
    metadataBase: new URL(siteOrigin()),
    alternates: { canonical: `/shop/${store.slug}` },
    openGraph: { siteName: store.store_name, type: "website", locale: "tr_TR" },
    robots: { index: true, follow: true },
  };
}

export default async function ShopLayout({ children, params }: { children: React.ReactNode; params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const store = await getStore(slug);
  if (!store) notFound();
  return (
    <div className="shop">
      <a href="#shop-main" className="shop-skip">İçeriğe geç</a>
      <ShopHeader store={store} />
      <main id="shop-main" className="shop-container shop-main">{children}</main>
      <ShopFooter store={store} />
    </div>
  );
}
