"use client";

import Image from "next/image";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { createBrowserClient } from "@supabase/ssr";
import { publicSupabaseEnv } from "@/lib/env";
import { checkoutErrorMessage } from "@/lib/shop/customer-errors";
import { lineLabels, lineProblem } from "@/lib/shop/cart-display";
import {
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

type Field = "name" | "phone" | "email";

/**
 * Guest checkout — an ORDER REQUEST, never a payment (Phase 14B unchanged). The server
 * re-reads publication, price and availability, creates the order and the hold in one
 * transaction and returns a tracking token. One idempotency key per attempt, kept until an
 * order exists, plus an in-flight lock: a double tap or a retry returns the same order.
 * The cart is cleared only after the server confirmed the order.
 */
export function CheckoutView({ store }: { store: Store }) {
  const router = useRouter();
  const [cart, setCart] = useState<Cart | null>(null);
  const [fresh, setFresh] = useState<AvailabilityMap>({});
  const [checking, setChecking] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const inFlight = useRef(false);
  const [error, setError] = useState<string | null>(null);
  const [fieldErrors, setFieldErrors] = useState<Partial<Record<Field, string>>>({});
  const [notices, setNotices] = useState<string[]>([]);
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

  const base = `/shop/${store.slug}`;
  if (!cart) return <div className="shop-page"><p className="shop-muted">Yükleniyor…</p></div>;
  if (cart.lines.length === 0) {
    return (
      <section className="shop-empty shop-page" data-testid="shop-cart-empty">
        <h1 className="shop-page-title">Sepetin boş.</h1>
        <p className="shop-empty-text">Beğendiğin ürünleri sepete ekleyerek başlayabilirsin.</p>
        <Link href={`${base}/urunler`} className="shop-btn shop-empty-cta">Ürünleri keşfet</Link>
      </section>
    );
  }
  if (!store.orders_enabled) {
    return (
      <section className="shop-empty shop-page">
        <h1 className="shop-page-title">Online sipariş şu an kapalı.</h1>
        <p className="shop-empty-text">Sepetinizi mağazaya iletmek için iletişim bilgilerini kullanabilirsiniz.</p>
        <Link href={`${base}/sepet`} className="shop-link">Sepete dön</Link>
      </section>
    );
  }

  const exact = store.stock_display === "exact";
  const blocked = cart.lines.filter((l) => lineProblem(l, fresh[l.variant_id], exact));
  const total = cart.lines.reduce((n, l) => n + l.quantity * (fresh[l.variant_id]?.price ?? l.unit_price), 0);

  function validate(): Partial<Record<Field, string>> {
    const e: Partial<Record<Field, string>> = {};
    if (form.name.trim().length < 2) e.name = "Lütfen adınızı girin.";
    const digits = form.phone.replace(/\D/g, "");
    if (digits.length === 0) e.phone = "Lütfen telefon numaranızı girin.";
    else if (digits.length < 7 || digits.length > 15) e.phone = "Lütfen geçerli bir telefon numarası girin.";
    if (form.email.trim() && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(form.email.trim())) e.email = "E-posta adresini kontrol edin.";
    return e;
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!cart || inFlight.current) return;           // a second tap while the first is in flight does nothing
    setError(null); setNotices([]);
    const fe = validate();
    setFieldErrors(fe);
    if (Object.keys(fe).length > 0) {
      document.getElementById(`co-${Object.keys(fe)[0]}`)?.focus();
      return;
    }
    inFlight.current = true;
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
          // the cart follows the server's truth: lines no longer available leave, over-asked lines shrink
          const next = { ...cart, lines: cart.lines.flatMap((l) => {
            const p = list.find((x) => x.variant_id === l.variant_id);
            if (!p) return [l];
            if (p.code === "UNAVAILABLE" || (p.available ?? 0) <= 0) return [];
            return [{ ...l, quantity: Math.min(l.quantity, p.available ?? l.quantity) }];
          }) };
          writeCart(next); setCart(next);
          setNotices(list.map((p) => {
            const name = `${p.name ?? "Bir ürün"}${p.labels ? ` (${lineLabels(p.labels)})` : ""}`;
            return p.code === "UNAVAILABLE" || (p.available ?? 0) <= 0
              ? `${name}: bu ürün artık müsait değil ve sepetten çıkarıldı.`
              : `${name}: adet müsait olana göre güncellendi.`;
          }));
        } catch { setError("Bu ürün artık müsait değil. Lütfen sepetinizi kontrol edin."); }
      } else {
        setError(checkoutErrorMessage(err));
      }
      inFlight.current = false;
      setSubmitting(false);
      return;
    }
    const r = data as CheckoutResult;
    clearCheckoutKey(store.slug);
    rememberOrder(store.slug, r.order_number, r.tracking_token);
    writeCart({ store: store.slug, lines: [], updated_at: new Date().toISOString() });
    router.push(`${base}/siparis/${r.tracking_token}?yeni=1`);
  }

  const field = (name: Field) => ({
    id: `co-${name}`,
    "aria-invalid": fieldErrors[name] ? true : undefined,
    "aria-describedby": fieldErrors[name] ? `co-${name}-err` : undefined,
  });

  return (
    <form className="shop-bag shop-page" onSubmit={submit} noValidate data-testid="shop-checkout">
      <div className="shop-co-main">
        <h1 className="shop-page-title">Sipariş talebi</h1>

        <fieldset className="shop-co-group">
          <legend className="shop-kicker">İletişim bilgileri</legend>
          <label className="shop-field" htmlFor="co-name">
            <span>Ad Soyad</span>
            <input className="shop-input" {...field("name")} name="name" autoComplete="name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            {fieldErrors.name ? <span className="shop-field-error" id="co-name-err">{fieldErrors.name}</span> : null}
          </label>
          <label className="shop-field" htmlFor="co-phone">
            <span>Telefon</span>
            <input className="shop-input" {...field("phone")} name="phone" type="tel" inputMode="tel" autoComplete="tel" required placeholder="05xx xxx xx xx" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
            {fieldErrors.phone ? <span className="shop-field-error" id="co-phone-err">{fieldErrors.phone}</span> : null}
          </label>
          <label className="shop-field" htmlFor="co-email">
            <span>E-posta <em>isteğe bağlı</em></span>
            <input className="shop-input" {...field("email")} name="email" type="email" inputMode="email" autoComplete="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
            {fieldErrors.email ? <span className="shop-field-error" id="co-email-err">{fieldErrors.email}</span> : null}
          </label>
          <label className="shop-field" htmlFor="co-note">
            <span>Not <em>isteğe bağlı</em></span>
            <textarea className="shop-input shop-textarea" id="co-note" name="note" rows={3} maxLength={500} value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} />
          </label>
        </fieldset>

        <fieldset className="shop-co-group">
          <legend className="shop-kicker">Teslimat</legend>
          <div className="shop-co-pickup">
            <span className="shop-co-radio" aria-hidden />
            <div>
              <p className="shop-co-pickup-title">Mağazadan Teslim</p>
              <p className="shop-co-pickup-text">{store.pickup_branch ?? store.store_name}</p>
              {store.pickup_note ? <p className="shop-co-pickup-text">{store.pickup_note}</p> : null}
            </div>
          </div>
        </fieldset>

        <p className="shop-co-explain">
          Bu işlem bir sipariş talebi oluşturur.<br />
          Mağaza siparişinizi onayladıktan sonra sizinle iletişime geçecektir.
        </p>
      </div>

      <aside className="shop-bag-summary" aria-label="Sipariş özeti">
        <p className="shop-kicker">Sipariş özeti</p>
        <ul className="shop-co-lines">
          {cart.lines.map((l) => {
            const f = fresh[l.variant_id];
            const img = publicImageUrl(l.image_path);
            const problem = lineProblem(l, f, exact);
            return (
              <li key={l.variant_id} className="shop-co-line">
                <div className="shop-co-thumb">{img ? <Image src={img} alt="" fill sizes="64px" /> : null}</div>
                <div className="shop-co-line-info">
                  <div className="shop-bag-row"><span>{l.name}</span><span className="shop-price" data-numeric>{formatShopPrice((f?.price ?? l.unit_price) * l.quantity, l.currency)}</span></div>
                  <p className="shop-bag-meta">{l.labels ? `${lineLabels(l.labels)} · ` : ""}<span data-numeric>{l.quantity} adet</span></p>
                  {problem ? <p className="shop-bag-problem">{problem}</p> : null}
                </div>
              </li>
            );
          })}
        </ul>
        <div className="shop-sum-row shop-sum-total"><span>Toplam</span><span className="shop-price" data-numeric>{formatShopPrice(total, store.currency)}</span></div>
        <p className="shop-note">Ödeme mağazada teslim sırasında yapılır.</p>
        {notices.length > 0 ? <div className="shop-bag-problem" role="alert">{notices.map((n) => <p key={n}>{n}</p>)}</div> : null}
        {blocked.length > 0 && notices.length === 0 ? <p className="shop-bag-problem" role="alert">Bazı ürünler bu adette müsait değil. <Link href={`${base}/sepet`}>Sepeti düzenleyin</Link>.</p> : null}
        {error ? <p className="shop-bag-problem" role="alert">{error}</p> : null}
        <button type="submit" className="shop-btn" disabled={submitting || checking || blocked.length > 0} aria-busy={submitting} data-testid="shop-checkout-submit">
          {submitting ? "Gönderiliyor…" : "Sipariş Talebi Oluştur"}
        </button>
        <Link href={`${base}/sepet`} className="shop-link shop-bag-back">Sepete dön</Link>
      </aside>
    </form>
  );
}
