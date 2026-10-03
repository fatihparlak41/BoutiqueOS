import Link from "next/link";
import type { Store } from "@/lib/shop/model";

/**
 * Storefront footer: only what the merchant configured. Shopping links, the contact
 * channels that exist, the pickup branch. No legal, shipping or returns pages are linked
 * because the platform does not publish such pages.
 */
export function ShopFooter({ store }: { store: Store }) {
  const base = `/shop/${store.slug}`;
  const contact = [
    store.instagram ? { href: `https://instagram.com/${store.instagram}`, label: "Instagram", external: true } : null,
    store.whatsapp ? { href: `https://wa.me/${store.whatsapp.replace(/[^0-9]/g, "")}`, label: "WhatsApp", external: true } : null,
    store.contact_email ? { href: `mailto:${store.contact_email}`, label: store.contact_email, external: false } : null,
    store.contact_phone ? { href: `tel:${store.contact_phone.replace(/[^0-9+]/g, "")}`, label: store.contact_phone, external: false } : null,
  ].filter((x): x is { href: string; label: string; external: boolean } => x !== null);
  const year = new Date().getFullYear();

  return (
    <footer className="shop-footer" data-testid="shop-footer">
      <div className="shop-container">
        <div className="shop-footer-grid">
          <div className="shop-footer-brand">
            <Link href={base} className="shop-wordmark">{store.store_name}</Link>
            {store.tagline ? <p>{store.tagline}</p> : null}
          </div>
          <nav aria-label="Alışveriş" className="shop-footer-col">
            <p className="shop-kicker">Alışveriş</p>
            <Link href={`${base}/urunler?sirala=newest`}>Yeni Gelenler</Link>
            <Link href={`${base}/urunler`}>Tüm Ürünler</Link>
            {store.categories.slice(0, 6).map((c) => (
              <Link key={c.slug} href={`${base}/kategori/${c.slug}`}>{c.name}</Link>
            ))}
          </nav>
          {contact.length > 0 || store.pickup_branch ? (
            <div className="shop-footer-col">
              <p className="shop-kicker">İletişim</p>
              {contact.map((c) => (
                <a key={c.href} href={c.href} {...(c.external ? { target: "_blank", rel: "noopener noreferrer" } : {})}>{c.label}</a>
              ))}
              {store.pickup_branch ? <span>Mağazadan teslim · {store.pickup_branch}</span> : null}
            </div>
          ) : null}
        </div>
        <p className="shop-footer-legal" data-numeric>© {year} {store.store_name}</p>
      </div>
    </footer>
  );
}
