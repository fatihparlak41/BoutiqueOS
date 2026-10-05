"use client";

import Image from "next/image";
import Link from "next/link";
import { useEffect, useState } from "react";
import { Minus, Plus } from "lucide-react";
import { createBrowserClient } from "@supabase/ssr";
import { publicSupabaseEnv } from "@/lib/env";
import {
  CART_MAX_QTY,
  cartTotal,
  formatShopPrice,
  publicImageUrl,
  readCart,
  writeCart,
  type AvailabilityMap,
  type Cart,
  type Store,
} from "@/lib/shop/model";
import { lineLabels, lineProblem } from "@/lib/shop/cart-display";

/**
 * Cart. Browser state for ONE store, re-checked against live availability with ONE batched
 * public call on every visit. The cart reserves nothing and submits nothing: its only job is
 * to lead to the order request ("Siparişe Devam Et"). Payment happens at the store.
 */
export function CartView({ store }: { store: Store }) {
  const [cart, setCart] = useState<Cart | null>(null);
  const [fresh, setFresh] = useState<AvailabilityMap>({});

  useEffect(() => {
    const c = readCart(store.slug);
    setCart(c);
    if (c.lines.length === 0) return;
    const { url, anonKey } = publicSupabaseEnv();
    const sb = createBrowserClient(url, anonKey);
    Promise.resolve(sb.rpc("rpc_shop_availability", { p_slug: store.slug, p_variant_ids: c.lines.map((l) => l.variant_id) }))
      .then(({ data }) => setFresh((data ?? {}) as AvailabilityMap))
      .catch(() => setFresh({}));
  }, [store.slug]);

  function setQty(variantId: string, qty: number) {
    if (!cart) return;
    const lines = cart.lines.map((l) => (l.variant_id === variantId ? { ...l, quantity: Math.max(0, Math.min(CART_MAX_QTY, qty)) } : l)).filter((l) => l.quantity > 0);
    const next = { ...cart, lines };
    writeCart(next);
    setCart(next);
  }

  if (!cart) return <div className="shop-page"><p className="shop-muted">Yükleniyor…</p></div>;
  const base = `/shop/${store.slug}`;
  if (cart.lines.length === 0) {
    return (
      <section className="shop-empty shop-page" data-testid="shop-cart-empty">
        <h1 className="shop-page-title">Sepetin boş.</h1>
        <p className="shop-empty-text">Beğendiğin ürünleri sepete ekleyerek başlayabilirsin.</p>
        <Link href={`${base}/urunler`} className="shop-btn shop-empty-cta">Ürünleri keşfet</Link>
      </section>
    );
  }

  const exact = store.stock_display === "exact";
  const problems = cart.lines.filter((l) => lineProblem(l, fresh[l.variant_id], exact));
  const priced = { ...cart, lines: cart.lines.map((l) => ({ ...l, unit_price: fresh[l.variant_id]?.price ?? l.unit_price })) };
  const total = cartTotal(priced);
  const count = cart.lines.reduce((n, l) => n + l.quantity, 0);
  const help = store.whatsapp
    ? { href: `https://wa.me/${store.whatsapp.replace(/[^0-9]/g, "")}`, label: "WhatsApp'tan yazın", external: true }
    : store.instagram
      ? { href: `https://instagram.com/${store.instagram}`, label: "Instagram'dan yazın", external: true }
      : store.contact_email
        ? { href: `mailto:${store.contact_email}`, label: "E-posta gönderin", external: false }
        : null;

  return (
    <div className="shop-bag shop-page" data-testid="shop-cart">
      <div>
        <h1 className="shop-page-title">Sepet <span className="shop-page-count" data-numeric>({count})</span></h1>
        <ul className="shop-bag-lines">
          {cart.lines.map((l) => {
            const f = fresh[l.variant_id];
            const img = publicImageUrl(l.image_path);
            const unit = f?.price ?? l.unit_price;
            const problem = lineProblem(l, f, exact);
            return (
              <li key={l.variant_id} className="shop-bag-line" data-problem={problem ? "true" : undefined}>
                <Link href={`${base}/urun/${l.product_slug}`} className="shop-bag-media" aria-label={l.name}>
                  {img ? <Image src={img} alt="" fill sizes="(min-width: 900px) 120px, 96px" /> : null}
                </Link>
                <div className="shop-bag-info">
                  <div className="shop-bag-row">
                    <Link href={`${base}/urun/${l.product_slug}`} className="shop-bag-name">{l.name}</Link>
                    <span className="shop-price shop-bag-total" data-numeric>{formatShopPrice(unit * l.quantity, l.currency)}</span>
                  </div>
                  {l.labels ? <p className="shop-bag-meta">{lineLabels(l.labels)}</p> : null}
                  {l.quantity > 1 ? <p className="shop-bag-meta" data-numeric>{formatShopPrice(unit, l.currency)} / adet</p> : null}
                  {problem ? <p className="shop-bag-problem" role="status">{problem}</p> : null}
                  <div className="shop-bag-row shop-bag-controls">
                    <div className="shop-qty" role="group" aria-label={`${l.name} adet`}>
                      <button type="button" onClick={() => setQty(l.variant_id, l.quantity - 1)} aria-label="Bir azalt"><Minus aria-hidden strokeWidth={1.4} /></button>
                      <span data-numeric aria-live="polite">{l.quantity}</span>
                      <button type="button" onClick={() => setQty(l.variant_id, l.quantity + 1)} aria-label="Bir artır" disabled={l.quantity >= CART_MAX_QTY || (f?.available !== null && f?.available !== undefined && l.quantity >= f.available)}><Plus aria-hidden strokeWidth={1.4} /></button>
                    </div>
                    <button type="button" className="shop-link shop-bag-remove" onClick={() => setQty(l.variant_id, 0)}>Kaldır</button>
                  </div>
                </div>
              </li>
            );
          })}
        </ul>
      </div>

      <aside className="shop-bag-summary" aria-label="Sipariş özeti">
        <div className="shop-sum-row"><span>Ara toplam</span><span className="shop-price" data-numeric>{formatShopPrice(total, store.currency)}</span></div>
        <div className="shop-sum-row shop-sum-muted"><span>Teslimat</span><span>Mağazadan teslim</span></div>
        <div className="shop-sum-row shop-sum-total"><span>Toplam</span><span className="shop-price" data-numeric>{formatShopPrice(total, store.currency)}</span></div>
        {store.orders_enabled ? (
          <>
            {problems.length > 0 ? <p className="shop-bag-problem" role="alert">Devam etmeden önce müsait olmayan ürünleri düzenleyin.</p> : null}
            <Link
              href={`${base}/checkout`}
              className="shop-btn"
              aria-disabled={problems.length > 0}
              data-disabled={problems.length > 0 ? "true" : undefined}
              onClick={(e) => { if (problems.length > 0) e.preventDefault(); }}
              data-testid="shop-cart-continue"
            >
              Siparişe Devam Et
            </Link>
            <p className="shop-note">Ödeme mağazada teslim sırasında yapılır.</p>
          </>
        ) : (
          <p className="shop-note">Online sipariş şu an kapalı. Sepetinizi mağazaya iletebilirsiniz.</p>
        )}
        {help ? (
          <p className="shop-bag-help">Sorunuz mu var? <a href={help.href} {...(help.external ? { target: "_blank", rel: "noopener noreferrer" } : {})}>{help.label}</a></p>
        ) : null}
        <Link href={`${base}/urunler`} className="shop-link shop-bag-back">Alışverişe devam et</Link>
      </aside>
    </div>
  );
}
