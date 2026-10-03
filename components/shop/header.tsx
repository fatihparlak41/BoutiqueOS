"use client";

import Link from "next/link";
import Image from "next/image";
import { usePathname } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { ChevronDown, Menu, Search } from "lucide-react";
import type { Store } from "@/lib/shop/model";
import { publicImageUrl } from "@/lib/shop/model";
import { CartButton } from "@/components/shop/cart-button";
import { MenuDrawer } from "@/components/shop/menu-drawer";
import { SearchSheet } from "@/components/shop/search-sheet";

/**
 * Storefront chrome. Phone: Menü · centred brand · Ara · Sepet. Desktop: brand, a short
 * fixed navigation (Yeni Gelenler, Tüm Ürünler, Kategoriler ▾) and Ara · Sepet. Categories
 * never sit in the bar itself — they live in a compact panel (desktop) or the drawer
 * (phone), so any number of categories fits. Nothing here belongs to the operational UI.
 */
export function ShopHeader({ store }: { store: Store }) {
  const pathname = usePathname();
  const [menu, setMenu] = useState(false);
  const [search, setSearch] = useState(false);
  const [cats, setCats] = useState(false);
  const catsRef = useRef<HTMLDivElement>(null);
  const closeMenu = useCallback(() => setMenu(false), []);
  const closeSearch = useCallback(() => setSearch(false), []);
  const base = `/shop/${store.slug}`;
  const logo = publicImageUrl(store.logo_path);

  // the category panel closes on navigation, outside click and Escape
  useEffect(() => { setCats(false); setMenu(false); setSearch(false); }, [pathname]);
  useEffect(() => {
    if (!cats) return;
    const onDown = (e: MouseEvent) => { if (!catsRef.current?.contains(e.target as Node)) setCats(false); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setCats(false); };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); document.removeEventListener("keydown", onKey); };
  }, [cats]);

  const inCategory = pathname.startsWith(`${base}/kategori/`);

  return (
    <>
      {store.announcement ? <div className="shop-announce">{store.announcement}</div> : null}
      <header className="shop-header" data-testid="shop-header">
        <div className="shop-container shop-header-row">
          <div className="shop-header-start">
            <button type="button" className="shop-icon shop-only-mobile" aria-label="Menü" aria-expanded={menu} onClick={() => setMenu(true)} data-testid="shop-menu-button">
              <Menu aria-hidden strokeWidth={1.4} />
            </button>
            <Link href={base} className="shop-wordmark shop-brand-desktop" aria-label={`${store.store_name} ana sayfa`}>
              {logo ? <Image src={logo} alt={store.store_name} width={140} height={32} unoptimized /> : store.store_name}
            </Link>
            <nav className="shop-nav" aria-label="Alışveriş">
              <Link href={`${base}/urunler?sirala=newest`}>Yeni Gelenler</Link>
              <Link href={`${base}/urunler`} aria-current={pathname === `${base}/urunler` ? "page" : undefined}>Tüm Ürünler</Link>
              {store.categories.length > 0 ? (
                <div className="shop-cats-menu" ref={catsRef}>
                  <button type="button" aria-expanded={cats} aria-controls="shop-cats-panel" data-current={inCategory ? "true" : undefined} onClick={() => setCats((v) => !v)}>
                    Kategoriler <ChevronDown aria-hidden strokeWidth={1.4} />
                  </button>
                  {cats ? (
                    <div id="shop-cats-panel" className="shop-cats-panel">
                      <ul>
                        {store.categories.map((c) => {
                          const href = `${base}/kategori/${c.slug}`;
                          return <li key={c.slug}><Link href={href} aria-current={pathname === href ? "page" : undefined}>{c.name}</Link></li>;
                        })}
                      </ul>
                    </div>
                  ) : null}
                </div>
              ) : null}
            </nav>
          </div>

          <Link href={base} className="shop-wordmark shop-brand-mobile" aria-label={`${store.store_name} ana sayfa`}>
            {logo ? <Image src={logo} alt={store.store_name} width={120} height={28} unoptimized /> : store.store_name}
          </Link>

          <div className="shop-header-end">
            <button type="button" className="shop-icon" aria-label="Ara" aria-expanded={search} onClick={() => setSearch(true)} data-testid="shop-search-button">
              <Search aria-hidden strokeWidth={1.4} />
              <span className="shop-icon-label">Ara</span>
            </button>
            <CartButton slug={store.slug} />
          </div>
        </div>
      </header>
      <MenuDrawer store={store} open={menu} onClose={closeMenu} pathname={pathname} />
      <SearchSheet store={store} open={search} onClose={closeSearch} />
    </>
  );
}
