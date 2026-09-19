"use client";

import Link from "next/link";
import Image from "next/image";
import { usePathname } from "next/navigation";
import { useState } from "react";
import type { Store } from "@/lib/shop/model";
import { publicImageUrl } from "@/lib/shop/model";
import { CartButton } from "@/components/shop/cart-button";

/**
 * Storefront chrome: announcement, brand, category navigation, cart. On phones the
 * categories fold into a menu opened with one thumb; on wider screens they sit inline.
 */
export function ShopHeader({ store }: { store: Store }) {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const base = `/shop/${store.slug}`;
  const logo = publicImageUrl(store.logo_path);
  const links = [{ href: `${base}/urunler`, label: "Tüm ürünler" }, ...store.categories.map((c) => ({ href: `${base}/kategori/${c.slug}`, label: c.name }))];
  return (
    <>
      {store.announcement ? <div className="shop-announce">{store.announcement}</div> : null}
      <header className="shop-header">
        <div className="shop-container shop-header-row">
          <button type="button" className="shop-icon-btn md:hidden" aria-expanded={open} aria-controls="shop-menu" onClick={() => setOpen((o) => !o)}>
            {open ? "Kapat" : "Menü"}
          </button>
          <Link href={base} className="shop-brand" aria-label={store.store_name}>
            {logo ? <Image src={logo} alt={store.store_name} width={120} height={32} unoptimized /> : store.store_name}
          </Link>
          <nav className="shop-nav" aria-label="Kategoriler">
            {links.map((l) => (
              <Link key={l.href} href={l.href} aria-current={pathname === l.href ? "page" : undefined}>{l.label}</Link>
            ))}
          </nav>
          <CartButton slug={store.slug} />
        </div>
        {open ? (
          <div id="shop-menu" className="shop-menu md:hidden">
            <nav className="shop-container" aria-label="Kategoriler">
              {links.map((l) => (
                <Link key={l.href} href={l.href} onClick={() => setOpen(false)}>{l.label}</Link>
              ))}
            </nav>
          </div>
        ) : null}
      </header>
    </>
  );
}
