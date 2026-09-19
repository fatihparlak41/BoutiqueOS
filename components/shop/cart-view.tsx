"use client";

import Image from "next/image";
import Link from "next/link";
import { useEffect, useState } from "react";
import { createBrowserClient } from "@supabase/ssr";
import { publicSupabaseEnv } from "@/lib/env";
import {
  CART_MAX_QTY,
  availabilityText,
  cartTotal,
  formatShopPrice,
  publicImageUrl,
  readCart,
  writeCart,
  type AvailabilityMap,
  type Cart,
  type Store,
} from "@/lib/shop/model";

/**
 * Cart page. Browser state for ONE store, re-checked against live availability on every
 * visit through the anon RPC (the same read-only boundary the pages use). Nothing here
 * reserves stock, takes payment or creates an order: checkout is a later phase, so the
 * page says how to complete the purchase with the boutique instead of pretending.
 */
export function CartView({ store }: { store: Store }) {
  const [cart, setCart] = useState<Cart | null>(null);
  const [fresh, setFresh] = useState<AvailabilityMap>({});
  const [checking, setChecking] = useState(false);

  useEffect(() => {
    const c = readCart(store.slug);
    setCart(c);
    if (c.lines.length === 0) return;
    setChecking(true);
    const { url, anonKey } = publicSupabaseEnv();
    const sb = createBrowserClient(url, anonKey);
    Promise.resolve(sb.rpc("rpc_shop_availability", { p_slug: store.slug, p_variant_ids: c.lines.map((l) => l.variant_id) }))
      .then(({ data }) => setFresh((data ?? {}) as AvailabilityMap))
      .catch(() => setFresh({}))
      .finally(() => setChecking(false));
  }, [store.slug]);

  function update(next: Cart) {
    writeCart(next);
    setCart({ ...next });
  }
  function setQty(variantId: string, qty: number) {
    if (!cart) return;
    const lines = cart.lines.map((l) => (l.variant_id === variantId ? { ...l, quantity: Math.max(0, Math.min(CART_MAX_QTY, qty)) } : l)).filter((l) => l.quantity > 0);
    update({ ...cart, lines });
  }

  if (!cart) return <div className="shop-section"><p className="shop-muted">Sepet yükleniyor…</p></div>;
  if (cart.lines.length === 0) {
    return (
      <div className="shop-section" style={{ textAlign: "center" }}>
        <p className="shop-eyebrow">Sepet</p>
        <h1 className="shop-h2" style={{ marginTop: 8 }}>Sepetiniz boş</h1>
        <p className="shop-muted" style={{ marginTop: 12 }}>Beğendiğiniz ürünleri sepete ekleyin; sepet bu tarayıcıda saklanır.</p>
        <p style={{ marginTop: 24 }}><Link href={`/shop/${store.slug}/urunler`} className="shop-btn shop-btn-ghost" style={{ width: "auto" }}>Ürünlere göz atın</Link></p>
      </div>
    );
  }

  const problems = cart.lines.filter((l) => fresh[l.variant_id] && fresh[l.variant_id].state === "sold_out");
  const priceChanged = cart.lines.filter((l) => fresh[l.variant_id]?.price !== undefined && fresh[l.variant_id].price !== null && fresh[l.variant_id].price !== l.unit_price);
  const total = cartTotal({ ...cart, lines: cart.lines.map((l) => ({ ...l, unit_price: fresh[l.variant_id]?.price ?? l.unit_price })) });
  const wa = store.whatsapp ? `https://wa.me/${store.whatsapp.replace(/[^0-9]/g, "")}?text=${encodeURIComponent(`Merhaba, ${store.store_name} sepetimdeki ürünler: ` + cart.lines.map((l) => `${l.name}${l.labels ? ` (${l.labels})` : ""} × ${l.quantity}`).join(", "))}` : null;

  return (
    <div className="shop-cart">
      <div>
        <p className="shop-eyebrow">Sepet</p>
        <h1 className="shop-h2" style={{ marginTop: 8, marginBottom: 8 }}>{cart.lines.length} ürün</h1>
        {checking ? <p className="shop-note">Stok durumu kontrol ediliyor…</p> : null}
        {problems.length > 0 ? <p className="shop-state" data-state="sold_out" role="alert" style={{ fontSize: 13 }}>Bazı ürünler tükendi; sepetten çıkarın ya da başka bir seçenek seçin.</p> : null}
        {priceChanged.length > 0 ? <p className="shop-note" role="status">Bazı fiyatlar güncellendi; güncel fiyat gösterilir.</p> : null}
        <div>
          {cart.lines.map((l) => {
            const f = fresh[l.variant_id];
            const img = publicImageUrl(l.image_path);
            const price = f?.price ?? l.unit_price;
            return (
              <div key={l.variant_id} className="shop-line">
                <Link href={`/shop/${store.slug}/urun/${l.product_slug}`} className="shop-line-media">
                  {img ? <Image src={img} alt={l.name} width={88} height={117} unoptimized /> : null}
                </Link>
                <div style={{ display: "grid", gap: 6, alignContent: "start" }}>
                  <div style={{ display: "flex", justifyContent: "space-between", gap: 12 }}>
                    <Link href={`/shop/${store.slug}/urun/${l.product_slug}`} style={{ textDecoration: "none", fontSize: 14 }}>{l.name}</Link>
                    <span className="shop-price" style={{ fontSize: 14 }}>{formatShopPrice(price * l.quantity, l.currency)}</span>
                  </div>
                  {l.labels ? <span className="shop-muted" style={{ fontSize: 13 }}>{l.labels}</span> : null}
                  <span className="shop-state" data-state={f?.state}>{f ? availabilityText(f.state, f.available, store.stock_display) : ""}</span>
                  <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, marginTop: 4 }}>
                    <div className="shop-qty" aria-label="Adet">
                      <button type="button" onClick={() => setQty(l.variant_id, l.quantity - 1)} aria-label="Azalt">−</button>
                      <span data-numeric>{l.quantity}</span>
                      <button type="button" onClick={() => setQty(l.variant_id, l.quantity + 1)} aria-label="Artır" disabled={l.quantity >= CART_MAX_QTY || (f?.available !== null && f?.available !== undefined && l.quantity >= f.available)}>+</button>
                    </div>
                    <button type="button" className="shop-icon-btn" style={{ padding: 0, borderBottom: "1px solid currentColor", fontSize: 12 }} onClick={() => setQty(l.variant_id, 0)}>Kaldır</button>
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </div>

      <aside className="shop-summary">
        <div className="shop-row"><span>Ara toplam</span><span className="shop-price">{formatShopPrice(total, store.currency)}</span></div>
        <p className="shop-note">Online ödeme ve sipariş henüz açık değil. Sepetinizi mağazaya iletin; teslimat ve ödeme mağazayla birlikte kararlaştırılır. Sepet stok ayırmaz.</p>
        {wa ? <a className="shop-btn" href={wa} target="_blank" rel="noopener noreferrer">WhatsApp ile mağazaya ilet</a> : null}
        {store.instagram ? <a className="shop-btn shop-btn-ghost" href={`https://instagram.com/${store.instagram}`} target="_blank" rel="noopener noreferrer">Instagram&apos;dan yazın</a> : null}
        {store.contact_email ? <a className="shop-btn shop-btn-ghost" href={`mailto:${store.contact_email}`}>E-posta gönderin</a> : null}
        <Link href={`/shop/${store.slug}/urunler`} className="shop-note" style={{ textAlign: "center" }}>Alışverişe devam et</Link>
      </aside>
    </div>
  );
}
