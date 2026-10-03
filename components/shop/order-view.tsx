"use client";

import Image from "next/image";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { createBrowserClient } from "@supabase/ssr";
import { publicSupabaseEnv } from "@/lib/env";
import { cancelErrorMessage } from "@/lib/shop/customer-errors";
import { lineLabels } from "@/lib/shop/cart-display";
import { ORDER_STATUS_LABELS, formatShopPrice, publicImageUrl, type PublicOrder } from "@/lib/shop/model";

const dt = new Intl.DateTimeFormat("tr-TR", { dateStyle: "medium", timeStyle: "short" });
const fmt = (iso: string | null | undefined) => (iso ? dt.format(new Date(iso)) : "");

const STATUS_COPY: Record<PublicOrder["status"], { title: string; text: string }> = {
  pending_confirmation: { title: "Sipariş talebiniz alındı.", text: "Mağaza siparişinizi kontrol ettikten sonra sizinle iletişime geçecektir." },
  confirmed: { title: "Siparişiniz onaylandı.", text: "Mağaza siparişinizi hazırlıyor; hazır olduğunda size haber verilecektir." },
  ready: { title: "Siparişiniz hazır.", text: "Mağazadan teslim alabilirsiniz. Ödeme teslim sırasında mağazada yapılır." },
  completed: { title: "Sipariş tamamlandı.", text: "Teşekkür ederiz." },
  cancelled: { title: "Sipariş iptal edildi.", text: "Dilerseniz yeniden sipariş verebilirsiniz." },
  expired: { title: "Sipariş talebinin süresi doldu.", text: "Ürünler artık bu sipariş için ayrılmış değil." },
};

/**
 * Customer milestones only, from the order's own status timestamps — never the engine's
 * internal events (re-reservation, POS conversion, sweeps). Normal path: Talep alındı →
 * Onaylandı → Hazır → Tamamlandı; a cancelled or expired order ends where it stopped.
 */
function milestones(o: PublicOrder): Array<{ label: string; at: string | null; done: boolean; terminal?: boolean }> {
  const steps = [
    { label: ORDER_STATUS_LABELS.pending_confirmation, at: o.created_at },
    { label: ORDER_STATUS_LABELS.confirmed, at: o.confirmed_at },
    { label: ORDER_STATUS_LABELS.ready, at: o.ready_at },
    { label: ORDER_STATUS_LABELS.completed, at: o.completed_at },
  ];
  if (o.status === "cancelled" || o.status === "expired") {
    const reached = steps.filter((s) => s.at).map((s) => ({ ...s, done: true }));
    return [...reached, { label: ORDER_STATUS_LABELS[o.status], at: o.status === "cancelled" ? o.cancelled_at : o.expired_at, done: true, terminal: true }];
  }
  return steps.map((s) => ({ ...s, done: Boolean(s.at) }));
}

/** The customer's own order, reached only through its tracking token. A request, not a purchase. */
export function OrderView({ slug, order, token, justCreated }: { slug: string; order: PublicOrder; token: string; justCreated: boolean }) {
  const router = useRouter();
  const [arm, setArm] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const base = `/shop/${slug}`;
  const success = justCreated && order.status === "pending_confirmation";
  const copy = STATUS_COPY[order.status];
  const live = order.status === "pending_confirmation" || order.status === "confirmed" || order.status === "ready";
  const heldUntil = live && order.reservation_active && order.reservation_expires_at ? fmt(order.reservation_expires_at) : null;

  async function cancel() {
    setBusy(true); setError(null);
    const { url, anonKey } = publicSupabaseEnv();
    const sb = createBrowserClient(url, anonKey);
    const { error: err } = await sb.rpc("rpc_shop_cancel_order", { p_slug: slug, p_token: token, p_reason: "müşteri iptali" });
    if (err) { setError(cancelErrorMessage(err)); setBusy(false); return; }
    setArm(false); setBusy(false);
    router.refresh();
  }

  return (
    <div className="shop-order shop-page" data-testid={success ? "shop-order-success" : "shop-order"}>
      <header className="shop-order-head">
        <p className="shop-kicker">{success ? "Teşekkürler" : "Siparişin"}</p>
        <h1 className="shop-page-title" data-sentence={success ? "true" : undefined}>{success ? copy.title : <span data-numeric>{order.order_number}</span>}</h1>
        {success ? (
          <p className="shop-order-number">Sipariş numarası <span data-numeric>{order.order_number}</span></p>
        ) : (
          <p className="shop-order-status" data-status={order.status} data-testid="shop-order-status">{ORDER_STATUS_LABELS[order.status]}</p>
        )}
        <p className="shop-order-text">{success ? copy.text : `${copy.title} ${copy.text}`}</p>
        {heldUntil ? <p className="shop-order-hold">Ürünleriniz <span data-numeric>{heldUntil}</span> tarihine kadar sizin için ayrıldı.</p> : null}
        {success ? (
          <div className="shop-order-actions">
            <Link href={`${base}/siparis/${token}`} className="shop-btn" data-testid="shop-order-view-status">Sipariş durumunu görüntüle</Link>
            <Link href={`${base}/urunler`} className="shop-link">Alışverişe devam et</Link>
          </div>
        ) : null}
      </header>

      {!success ? (
        <ol className="shop-steps" aria-label="Sipariş durumu">
          {milestones(order).map((m) => (
            <li key={m.label} data-done={m.done ? "true" : undefined} data-terminal={m.terminal ? "true" : undefined} aria-current={m.label === ORDER_STATUS_LABELS[order.status] ? "step" : undefined}>
              <span className="shop-step-dot" aria-hidden />
              <span className="shop-step-label">{m.label}</span>
              {m.at ? <span className="shop-step-at" data-numeric>{fmt(m.at)}</span> : null}
            </li>
          ))}
        </ol>
      ) : null}

      <div className="shop-order-grid">
        <section className="shop-order-block" aria-labelledby="ord-items">
          <h2 id="ord-items" className="shop-kicker">Ürünler</h2>
          <ul className="shop-co-lines">
            {order.items.map((it, i) => {
              const img = publicImageUrl(it.image_path);
              return (
                <li key={i} className="shop-co-line">
                  <Link href={`${base}/urun/${it.product_slug}`} className="shop-co-thumb" aria-label={it.name}>{img ? <Image src={img} alt="" fill sizes="64px" unoptimized /> : null}</Link>
                  <div className="shop-co-line-info">
                    <div className="shop-bag-row"><span>{it.name}</span><span className="shop-price" data-numeric>{formatShopPrice(it.line_total, order.currency)}</span></div>
                    <p className="shop-bag-meta">{it.labels ? `${lineLabels(it.labels)} · ` : ""}<span data-numeric>{it.quantity} adet</span></p>
                  </div>
                </li>
              );
            })}
          </ul>
          <div className="shop-sum-row shop-sum-total"><span>Toplam</span><span className="shop-price" data-numeric>{formatShopPrice(order.total, order.currency)}</span></div>
        </section>

        <section className="shop-order-block" aria-labelledby="ord-pickup">
          <h2 id="ord-pickup" className="shop-kicker">Teslimat</h2>
          <p className="shop-order-line">Mağazadan Teslim{order.pickup ? ` — ${order.pickup.branch}` : ""}</p>
          {order.pickup?.note ? <p className="shop-order-muted">{order.pickup.note}</p> : null}
          <p className="shop-order-muted">Ödeme teslim sırasında mağazada yapılır.</p>

          <h2 className="shop-kicker shop-order-sub">İletişim bilgileriniz</h2>
          <p className="shop-order-line">{order.customer_name}</p>
          <p className="shop-order-muted"><span data-numeric>{order.phone}</span>{order.email ? ` · ${order.email}` : ""}</p>
          {order.note ? <p className="shop-order-muted">Not: {order.note}</p> : null}

          {order.pickup?.whatsapp ? (
            <p className="shop-order-help">Sorunuz mu var? <a href={`https://wa.me/${order.pickup.whatsapp.replace(/[^0-9]/g, "")}?text=${encodeURIComponent(`Merhaba, ${order.order_number} numaralı siparişim hakkında`)}`} target="_blank" rel="noopener noreferrer">Mağazaya yazın</a></p>
          ) : null}

          {order.can_cancel && !success ? (
            <div className="shop-order-cancel">
              {!arm ? (
                <button type="button" className="shop-link" onClick={() => setArm(true)}>Siparişi iptal et</button>
              ) : (
                <div className="shop-order-confirm" role="group" aria-label="İptali onayla">
                  <p className="shop-order-muted">Sipariş talebiniz iptal edilir; bu işlem geri alınamaz.</p>
                  <div className="shop-order-actions">
                    <button type="button" className="shop-btn" disabled={busy} onClick={cancel}>{busy ? "İptal ediliyor…" : "Evet, iptal et"}</button>
                    <button type="button" className="shop-link" onClick={() => setArm(false)}>Vazgeç</button>
                  </div>
                </div>
              )}
              {error ? <p className="shop-bag-problem" role="alert">{error}</p> : null}
            </div>
          ) : null}
        </section>
      </div>

      <p className="shop-order-foot">Bu sayfa yalnız size özel bağlantıyla açılır; bağlantıyı saklayın. <Link href={`${base}/urunler`}>Alışverişe devam et</Link></p>
    </div>
  );
}
