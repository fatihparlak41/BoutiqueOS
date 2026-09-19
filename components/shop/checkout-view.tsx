"use client";

import Image from "next/image";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { createBrowserClient } from "@supabase/ssr";
import { publicSupabaseEnv } from "@/lib/env";
import { toUserMessage } from "@/lib/db-errors";
import {
  availabilityText,
  clearCheckoutKey,
  formatShopPrice,
  getOrCreateCheckoutKey,
  publicImageUrl,
  readCart,
  rememberOrder,
  writeCart,
  type AvailabilityMap,
  type Cart,
  type CartProblem,
  type CheckoutResult,
  type Store,
} from "@/lib/shop/model";

/**
 * Guest checkout. Nothing here is a payment: the customer leaves an ORDER REQUEST with a
 * name and a phone; the server re-reads publication, price and availability, computes the
 * total, creates the order and holds the stock in one transaction, and returns a tracking
 * token. Browser prices are display only. The idempotency key is minted once per attempt
 * and kept until an order exists, so a double click or a retry returns the same order.
 */
export function CheckoutView({ store }: { store: Store }) {
  const router = useRouter();
  const [cart, setCart] = useState<Cart | null>(null);
  const [fresh, setFresh] = useState<AvailabilityMap>({});
  const [checking, setChecking] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [problems, setProblems] = useState<CartProblem[]>([]);
  const [form, setForm] = useState({ name: "", phone: "", email: "", note: "" });

  useEffect(() => {
    const c = readCart(store.slug);
    setCart(c);
    if (c.lines.length === 0) { setChecking(false); return; }
    const { url, anonKey } = publicSupabaseEnv();
    const sb = createBrowserClient(url, anonKey);
    Promise.resolve(sb.rpc("rpc_shop_availability", { p_slug: store.slug, p_variant_ids: c.lines.map((l) => l.variant_id) }))
      .then(({ data }) => setFresh((data ?? {}) as AvailabilityMap))
      .catch(() => setFresh({}))
      .finally(() => setChecking(false));
  }, [store.slug]);

  if (!cart) return <div className="shop-section"><p className="shop-muted">Yükleniyor…</p></div>;
  if (cart.lines.length === 0) {
    return (
      <div className="shop-section" style={{ textAlign: "center" }}>
        <h1 className="shop-h2">Sepetiniz boş</h1>
        <p style={{ marginTop: 24 }}><Link href={`/shop/${store.slug}/urunler`} className="shop-btn shop-btn-ghost" style={{ width: "auto" }}>Ürünlere göz atın</Link></p>
      </div>
    );
  }
  if (!store.orders_enabled) {
    return (
      <div className="shop-section" style={{ textAlign: "center" }}>
        <h1 className="shop-h2">Online sipariş şu an kapalı</h1>
        <p className="shop-muted" style={{ marginTop: 12 }}>Sepetinizi mağazaya iletmek için iletişim kanallarını kullanabilirsiniz.</p>
        <p style={{ marginTop: 24 }}><Link href={`/shop/${store.slug}/sepet`} className="shop-btn shop-btn-ghost" style={{ width: "auto" }}>Sepete dön</Link></p>
      </div>
    );
  }

  const blocked = cart.lines.filter((l) => {
    const f = fresh[l.variant_id];
    return f && (f.state === "sold_out" || (f.available !== null && l.quantity > f.available));
  });
  const total = cart.lines.reduce((n, l) => n + l.quantity * (fresh[l.variant_id]?.price ?? l.unit_price), 0);
  const holdText = store.order_hold_minutes >= 60 ? `${Math.round(store.order_hold_minutes / 60)} saat` : `${store.order_hold_minutes} dakika`;

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!cart || submitting) return;
    setError(null); setProblems([]);
    if (form.name.trim().length < 2) { setError("Ad soyad gerekli."); return; }
    if (form.phone.replace(/\D/g, "").length < 7) { setError("Geçerli bir telefon numarası girin."); return; }
    setSubmitting(true);
    const key = getOrCreateCheckoutKey(store.slug);
    const { url, anonKey } = publicSupabaseEnv();
    const sb = createBrowserClient(url, anonKey);
    const { data, error: err } = await sb.rpc("rpc_shop_create_order", {
      p_slug: store.slug,
      p_idempotency_key: key,
      p_items: cart.lines.map((l) => ({ variant_id: l.variant_id, quantity: l.quantity })),
      p_customer: { name: form.name.trim(), phone: form.phone.trim(), email: form.email.trim() || null, note: form.note.trim() || null },
      p_fulfillment: "store_pickup",
    });
    if (err) {
      const m = /CART_PROBLEMS: (\[.*\])/.exec(err.message ?? "");
      if (m) {
        try {
          const list = JSON.parse(m[1]) as CartProblem[];
          setProblems(list);
          // the cart follows the server's truth: sold-out lines leave, over-asked lines shrink
          const next = { ...cart, lines: cart.lines.flatMap((l) => {
            const p = list.find((x) => x.variant_id === l.variant_id);
            if (!p) return [l];
            if (p.code === "UNAVAILABLE" || (p.available ?? 0) <= 0) return [];
            return [{ ...l, quantity: Math.min(l.quantity, p.available ?? l.quantity) }];
          }) };
          writeCart(next); setCart(next);
        } catch { setError("Sepetinizdeki bazı ürünler artık alınamıyor. Sepeti kontrol edin."); }
      } else {
        setError(toUserMessage(err));
      }
      setSubmitting(false);
      return;
    }
    const r = data as CheckoutResult;
    clearCheckoutKey(store.slug);
    rememberOrder(store.slug, r.order_number, r.tracking_token);
    writeCart({ store: store.slug, lines: [], updated_at: new Date().toISOString() });
    router.push(`/shop/${store.slug}/siparis/${r.tracking_token}`);
  }

  return (
    <form className="shop-cart" onSubmit={submit} noValidate>
      <div style={{ display: "grid", gap: 24 }}>
        <div>
          <p className="shop-eyebrow">Sipariş talebi</p>
          <h1 className="shop-h2" style={{ marginTop: 8 }}>Bilgileriniz</h1>
          <p className="shop-note" style={{ marginTop: 8 }}>Hesap gerekmez. Mağaza siparişinizi kontrol ettikten sonra sizinle iletişime geçecektir.</p>
        </div>
        <div style={{ display: "grid", gap: 14 }}>
          <label style={{ display: "grid", gap: 6, fontSize: 13 }}>Ad soyad
            <input className="shop-input" name="name" autoComplete="name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
          </label>
          <label style={{ display: "grid", gap: 6, fontSize: 13 }}>Telefon
            <input className="shop-input" name="phone" type="tel" inputMode="tel" autoComplete="tel" required placeholder="05xx… ya da +90 / +357…" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
          </label>
          <label style={{ display: "grid", gap: 6, fontSize: 13 }}>E-posta <span className="shop-muted">(isteğe bağlı)</span>
            <input className="shop-input" name="email" type="email" inputMode="email" autoComplete="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
          </label>
          <label style={{ display: "grid", gap: 6, fontSize: 13 }}>Not <span className="shop-muted">(isteğe bağlı)</span>
            <textarea className="shop-input" name="note" rows={3} maxLength={500} style={{ height: "auto", padding: 10 }} value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} />
          </label>
        </div>
        <div style={{ borderTop: "1px solid var(--shop-line)", paddingTop: 16 }}>
          <p className="shop-eyebrow">Teslimat</p>
          <p style={{ marginTop: 8, fontSize: 15 }}><strong>Mağazadan teslim</strong> — {store.pickup_branch ?? store.store_name}</p>
          {store.pickup_note ? <p className="shop-note" style={{ marginTop: 6 }}>{store.pickup_note}</p> : null}
          <p className="shop-note" style={{ marginTop: 10 }}>Ürünleriniz talebiniz alındığında <strong>{holdText}</strong> boyunca sizin için ayrılır. Ödeme mağazada, teslim sırasında yapılır; online ödeme yoktur.</p>
        </div>
      </div>

      <aside className="shop-summary">
        <p className="shop-eyebrow">Özet</p>
        {checking ? <p className="shop-note">Stok kontrol ediliyor…</p> : null}
        {cart.lines.map((l) => {
          const f = fresh[l.variant_id];
          const img = publicImageUrl(l.image_path);
          const price = f?.price ?? l.unit_price;
          const isBlocked = blocked.includes(l);
          return (
            <div key={l.variant_id} className="shop-line" style={{ gridTemplateColumns: "56px minmax(0,1fr)", padding: "10px 0" }}>
              <div className="shop-line-media">{img ? <Image src={img} alt={l.name} width={56} height={75} unoptimized /> : null}</div>
              <div style={{ fontSize: 13, display: "grid", gap: 2 }}>
                <div style={{ display: "flex", justifyContent: "space-between", gap: 8 }}><span>{l.name}</span><span className="shop-price">{formatShopPrice(price * l.quantity, l.currency)}</span></div>
                <span className="shop-muted">{l.labels ? `${l.labels} · ` : ""}{l.quantity} adet</span>
                {f ? <span className="shop-state" data-state={isBlocked ? "sold_out" : f.state}>{isBlocked ? "Bu adette müsait değil" : availabilityText(f.state, f.available, store.stock_display)}</span> : null}
              </div>
            </div>
          );
        })}
        <div className="shop-row" style={{ fontSize: 16 }}><span>Toplam</span><span className="shop-price">{formatShopPrice(total, store.currency)}</span></div>
        {problems.length > 0 ? (
          <p className="shop-state" data-state="sold_out" role="alert" style={{ fontSize: 13 }}>
            {problems.map((p) => p.code === "UNAVAILABLE" ? "Bir ürün artık satışta değil ve sepetten çıkarıldı." : `${p.name ?? "Bir ürün"}${p.labels ? ` (${p.labels})` : ""}: yalnız ${p.available ?? 0} adet müsait; sepet güncellendi.`).join(" ")}
          </p>
        ) : null}
        {error ? <p className="shop-state" data-state="sold_out" role="alert" style={{ fontSize: 13 }}>{error}</p> : null}
        <button type="submit" className="shop-btn" disabled={submitting || checking || blocked.length > 0 || cart.lines.length === 0}>
          {submitting ? "Gönderiliyor…" : "Sipariş Talebi Oluştur"}
        </button>
        <p className="shop-note">Bu bir sipariş talebidir; ödeme alınmaz. Mağaza onayladığında hazırlanır.</p>
        <Link href={`/shop/${store.slug}/sepet`} className="shop-note" style={{ textAlign: "center" }}>Sepete dön</Link>
      </aside>
    </form>
  );
}
