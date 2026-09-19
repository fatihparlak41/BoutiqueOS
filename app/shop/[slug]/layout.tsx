import type { Metadata } from "next";
import { notFound } from "next/navigation";
import Link from "next/link";
import "@/app/shop/shop.css";
import { getStore } from "@/lib/shop/queries";
import { siteOrigin } from "@/lib/url";
import { ShopHeader } from "@/components/shop/header";

/**
 * Public storefront shell. No session, no tenant bootstrap, no admin chrome: the store
 * is resolved once by its slug (cached) and everything below reads through the
 * read-only public RPCs. An unknown or disabled store is a plain 404.
 */
export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const { slug } = await params;
  const store = await getStore(slug);
  if (!store) return { title: "Mağaza bulunamadı" };
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
      <ShopHeader store={store} />
      <main className="shop-container">{children}</main>
      <footer className="shop-footer">
        <div className="shop-container shop-footer-row">
          <div>
            <p className="shop-brand" style={{ fontSize: 22 }}>{store.store_name}</p>
            {store.about ? <p style={{ marginTop: 10, maxWidth: "40rem", lineHeight: 1.6 }}>{store.about}</p> : null}
            <p style={{ marginTop: 10 }}>{[store.contact_phone, store.contact_email].filter(Boolean).join(" · ")}</p>
          </div>
          <nav aria-label="Bağlantılar">
            {store.instagram ? <a href={`https://instagram.com/${store.instagram}`} target="_blank" rel="noopener noreferrer">Instagram</a> : null}
            {store.whatsapp ? <a href={`https://wa.me/${store.whatsapp.replace(/[^0-9]/g, "")}`} target="_blank" rel="noopener noreferrer">WhatsApp</a> : null}
            <Link href={`/shop/${store.slug}/urunler`}>Tüm ürünler</Link>
          </nav>
        </div>
      </footer>
    </div>
  );
}
