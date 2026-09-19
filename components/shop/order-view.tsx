"use client";

import Image from "next/image";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { createBrowserClient } from "@supabase/ssr";
import { publicSupabaseEnv } from "@/lib/env";
import { toUserMessage } from "@/lib/db-errors";
import { ORDER_STATUS_LABELS, formatShopPrice, publicImageUrl, type PublicOrder } from "@/lib/shop/model";

const dt = new Intl.DateTimeFormat("tr-TR", { dateStyle: "medium", timeStyle: "short" });
const fmt = (iso: string | null | undefined) => (iso ? dt.format(new Date(iso)) : "—");

const STATUS_COPY: Record<PublicOrder["status"], { title: string; text: string }> = {
  pending_confirmation: { title: "Sipariş talebiniz alındı.", text: "Mağaza siparişinizi kontrol ettikten sonra sizinle iletişime geçecektir. Ürünleriniz belirtilen süre boyunca ayrılmıştır." },
  confirmed: { title: "Siparişiniz onaylandı.", text: "Mağaza siparişinizi hazırlıyor; hazır olduğunda size haber verilecektir." },
  ready: { title: "Siparişiniz teslime hazır.", text: "Mağazadan teslim alabilirsiniz. Ödeme teslim sırasında mağazada yapılır." },
  completed: { title: "Siparişiniz teslim edildi.", text: "Teşekkür ederiz." },
  cancelled: { title: "Sipariş iptal edildi.", text: "Ayrılan ürünler serbest bırakıldı. Yeniden sipariş verebilirsiniz." },
  expired: { title: "Ayırma süresi doldu.", text: "Ürünler artık sizin için ayrılmıyor. Dilerseniz yeniden sipariş verebilir ya da mağazayla iletişime geçebilirsiniz." },
};

const EVENT_LABELS: Record<string, string> = {
  created: "Sipariş talebi alındı", confirmed: "Mağaza onayladı", ready: "Teslime hazır", cancelled: "İptal edildi", expired: "Ayırma süresi doldu", rereserved: "Ürünler yeniden ayrıldı", completed: "Teslim edildi",
};

/** The customer's own order, reached only through its tracking token. Honest wording: this is a request, not a purchase. */
export function OrderView({ slug, order, token }: { slug: string; order: PublicOrder; token: string }) {
  const router = useRouter();
  const [arm, setArm] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const copy = STATUS_COPY[order.status];

  async function cancel() {
    setBusy(true); setError(null);
    const { url, anonKey } = publicSupabaseEnv();
    const sb = createBrowserClient(url, anonKey);
    const { error: err } = await sb.rpc("rpc_shop_cancel_order", { p_slug: slug, p_token: token, p_reason: "müşteri iptali" });
    if (err) { setError(toUserMessage(err)); setBusy(false); return; }
    router.refresh();
    setBusy(false); setArm(false);
  }

  return (
    <div className="shop-cart">
      <div style={{ display: "grid", gap: 24 }}>
        <div>
          <p className="shop-eyebrow">Sipariş <span data-numeric>{order.order_number}</span> · {ORDER_STATUS_LABELS[order.status]}</p>
          <h1 className="shop-h2" style={{ marginTop: 8 }}>{copy.title}</h1>
          <p className="shop-lead" style={{ marginTop: 10, fontSize: 15 }}>{copy.text}</p>
          {order.reservation_expires_at && (order.status === "pending_confirmation" || order.status === "confirmed" || order.status === "ready") ? (
            <p className="shop-note" style={{ marginTop: 10 }}>Ürünleriniz <strong data-numeric>{fmt(order.reservation_expires_at)}</strong>&apos;e kadar ayrılmıştır.</p>
          ) : null}
        </div>
        <div style={{ borderTop: "1px solid var(--shop-line)", paddingTop: 16 }}>
          <p className="shop-eyebrow">Teslimat</p>
          <p style={{ marginTop: 8, fontSize: 15 }}><strong>Mağazadan teslim</strong>{order.pickup ? ` — ${order.pickup.branch}` : ""}</p>
          {order.pickup?.note ? <p className="shop-note" style={{ marginTop: 6 }}>{order.pickup.note}</p> : null}
          <p className="shop-note" style={{ marginTop: 6 }}>Ödeme teslim sırasında mağazada yapılır.</p>
        </div>
        <div style={{ borderTop: "1px solid var(--shop-line)", paddingTop: 16 }}>
          <p className="shop-eyebrow">İletişim bilgileriniz</p>
          <p style={{ marginTop: 8, fontSize: 14 }}>{order.customer_name} · <span data-numeric>{order.phone}</span>{order.email ? ` · ${order.email}` : ""}</p>
          {order.note ? <p className="shop-note" style={{ marginTop: 6 }}>Not: {order.note}</p> : null}
        </div>
        <div style={{ borderTop: "1px solid var(--shop-line)", paddingTop: 16 }}>
          <p className="shop-eyebrow">Geçmiş</p>
          <ul style={{ marginTop: 8, display: "grid", gap: 6, fontSize: 13 }}>
            {order.timeline.map((e, i) => (
              <li key={i} style={{ display: "flex", justifyContent: "space-between", gap: 12 }}><span>{EVENT_LABELS[e.event] ?? e.event}</span><span className="shop-muted" data-numeric>{fmt(e.at)}</span></li>
            ))}
          </ul>
        </div>
        {order.can_cancel ? (
          <div style={{ borderTop: "1px solid var(--shop-line)", paddingTop: 16 }}>
            {!arm ? (
              <button type="button" className="shop-btn shop-btn-ghost" style={{ width: "auto" }} onClick={() => setArm(true)}>Siparişi iptal et</button>
            ) : (
              <div style={{ display: "grid", gap: 8 }}>
                <p className="shop-note">Ayrılan ürünler serbest bırakılır; bu işlem geri alınamaz.</p>
                <div style={{ display: "flex", gap: 8 }}>
                  <button type="button" className="shop-btn" style={{ width: "auto" }} disabled={busy} onClick={cancel}>{busy ? "İptal ediliyor…" : "Evet, iptal et"}</button>
                  <button type="button" className="shop-btn shop-btn-ghost" style={{ width: "auto" }} onClick={() => setArm(false)}>Vazgeç</button>
                </div>
              </div>
            )}
            {error ? <p className="shop-state" data-state="sold_out" role="alert" style={{ marginTop: 8 }}>{error}</p> : null}
          </div>
        ) : null}
      </div>

      <aside className="shop-summary">
        <p className="shop-eyebrow">Ürünler</p>
        {order.items.map((it, i) => {
          const img = publicImageUrl(it.image_path);
          return (
            <div key={i} className="shop-line" style={{ gridTemplateColumns: "56px minmax(0,1fr)", padding: "10px 0" }}>
              <Link href={`/shop/${slug}/urun/${it.product_slug}`} className="shop-line-media">{img ? <Image src={img} alt={it.name} width={56} height={75} unoptimized /> : null}</Link>
              <div style={{ fontSize: 13, display: "grid", gap: 2 }}>
                <div style={{ display: "flex", justifyContent: "space-between", gap: 8 }}><span>{it.name}</span><span className="shop-price">{formatShopPrice(it.line_total, order.currency)}</span></div>
                <span className="shop-muted">{it.labels ? `${it.labels} · ` : ""}{it.quantity} adet · {formatShopPrice(it.unit_price, order.currency)}</span>
              </div>
            </div>
          );
        })}
        <div className="shop-row" style={{ fontSize: 16 }}><span>Toplam</span><span className="shop-price">{formatShopPrice(order.total, order.currency)}</span></div>
        <p className="shop-note">Bu sayfa yalnız size özel bağlantıyla açılır; bağlantıyı saklayın.</p>
        {order.pickup?.whatsapp ? <a className="shop-btn shop-btn-ghost" href={`https://wa.me/${order.pickup.whatsapp.replace(/[^0-9]/g, "")}?text=${encodeURIComponent(`Merhaba, ${order.order_number} numaralı siparişim hakkında`)}`} target="_blank" rel="noopener noreferrer">Mağazaya yazın</a> : null}
        <Link href={`/shop/${slug}`} className="shop-note" style={{ textAlign: "center" }}>Mağazaya dön</Link>
      </aside>
    </div>
  );
}
