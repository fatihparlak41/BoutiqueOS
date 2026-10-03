"use client";

import Link from "next/link";
import { useRef } from "react";
import { X } from "lucide-react";
import type { Store } from "@/lib/shop/model";
import { useOverlay } from "@/components/shop/overlay";

/**
 * Phone navigation: a near-full-height drawer from the left. Shopping first (new arrivals,
 * all products, every category with published products), then only the contact channels
 * the store configured. No BoutiqueOS link of any kind.
 */
export function MenuDrawer({ store, open, onClose, pathname }: { store: Store; open: boolean; onClose: () => void; pathname: string }) {
  const panel = useRef<HTMLDivElement>(null);
  const closeBtn = useRef<HTMLButtonElement>(null);
  useOverlay(open, onClose, panel, closeBtn);
  if (!open) return null;

  const base = `/shop/${store.slug}`;
  const primary = [
    { href: `${base}/urunler?sirala=newest`, label: "Yeni Gelenler", current: false },
    { href: `${base}/urunler`, label: "Tüm Ürünler", current: pathname === `${base}/urunler` },
  ];
  const contact = [
    store.instagram ? { href: `https://instagram.com/${store.instagram}`, label: "Instagram", external: true } : null,
    store.whatsapp ? { href: `https://wa.me/${store.whatsapp.replace(/[^0-9]/g, "")}`, label: "WhatsApp", external: true } : null,
    store.contact_email ? { href: `mailto:${store.contact_email}`, label: store.contact_email, external: false } : null,
    store.contact_phone ? { href: `tel:${store.contact_phone.replace(/[^0-9+]/g, "")}`, label: store.contact_phone, external: false } : null,
  ].filter((x): x is { href: string; label: string; external: boolean } => x !== null);

  return (
    <div className="shop-layer" data-testid="shop-menu">
      <button type="button" className="shop-scrim" aria-label="Menüyü kapat" tabIndex={-1} onClick={onClose} />
      <div ref={panel} className="shop-drawer" role="dialog" aria-modal="true" aria-label="Menü" tabIndex={-1}>
        <div className="shop-layer-head">
          <span className="shop-wordmark shop-wordmark-sm">{store.store_name}</span>
          <button ref={closeBtn} type="button" className="shop-icon" aria-label="Kapat" onClick={onClose}>
            <X aria-hidden strokeWidth={1.4} />
          </button>
        </div>
        <nav aria-label="Alışveriş" className="shop-drawer-nav">
          {primary.map((l) => (
            <Link key={l.href} href={l.href} onClick={onClose} className="shop-drawer-link shop-drawer-link-lg" aria-current={l.current ? "page" : undefined}>{l.label}</Link>
          ))}
        </nav>
        {store.categories.length > 0 ? (
          <nav aria-label="Kategoriler" className="shop-drawer-nav">
            <p className="shop-kicker">Kategoriler</p>
            {store.categories.map((c) => {
              const href = `${base}/kategori/${c.slug}`;
              return <Link key={c.slug} href={href} onClick={onClose} className="shop-drawer-link" aria-current={pathname === href ? "page" : undefined}>{c.name}</Link>;
            })}
          </nav>
        ) : null}
        {contact.length > 0 ? (
          <div className="shop-drawer-nav shop-drawer-foot">
            <p className="shop-kicker">İletişim</p>
            {contact.map((c) => (
              <a key={c.href} href={c.href} className="shop-drawer-link shop-drawer-link-sm" {...(c.external ? { target: "_blank", rel: "noopener noreferrer" } : {})}>{c.label}</a>
            ))}
          </div>
        ) : null}
      </div>
    </div>
  );
}
