import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireTenant } from "@/lib/tenant";
import { getOnlineOrder } from "@/lib/orders/queries";
import { EVENT_LABELS, orderCaps, MERCHANT_STATUS_LABELS } from "@/lib/orders/model";
import { formatShopPrice } from "@/lib/shop/model";
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { Badge } from "@/components/ui/badge";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";
import { OrderPill, fmtDateTime } from "@/components/orders/pills";
import { CancelOrderForm, ConfirmOrderForm, ReadyOrderForm, RereserveOrderForm } from "@/app/app/online-siparisler/forms";

export const metadata = { title: "Online Sipariş · BoutiqueOS" };

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-4 py-2 text-sm">
      <dt className="text-text-muted">{label}</dt>
      <dd className="text-right text-text-primary">{children}</dd>
    </div>
  );
}

export default async function OnlineOrderDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { active } = await requireTenant();
  const caps = orderCaps(active.role);
  if (!caps.canView) redirect("/app/online-siparisler");
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const o = await getOnlineOrder(id);
  if (!o) notFound();
  const holdLive = Boolean(o.reservation?.active);
  const lapsed = o.status !== o.stored_status; // derived expiry not yet materialised
  const open = o.status === "pending_confirmation" || o.status === "confirmed" || o.status === "ready";

  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow={{ href: "/app/online-siparisler", label: "Online Siparişler" }}
        title={o.order_number}
        description={<>{o.customer_name} · <span data-numeric>{o.phone}</span>{o.email ? ` · ${o.email}` : ""} · talep {fmtDateTime(o.created_at)} · mağazadan teslim ({o.pickup?.branch ?? "—"})</>}
        actions={<span className="flex gap-1"><OrderPill status={o.stored_status} />{lapsed ? <Badge tone="warning">{MERCHANT_STATUS_LABELS[o.status]}</Badge> : null}</span>}
      />

      <div className="grid grid-cols-1 gap-8 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <div className="space-y-8">
          <section className="space-y-2">
            <SectionHeader title="Ürünler" meta={`${o.item_count} adet`} />
            <TableShell minWidth="40rem">
              <THead>
                <TH>Ürün</TH>
                <TH align="right">Adet</TH>
                <TH align="right">Sipariş fiyatı</TH>
                <TH align="right">Liste (şimdi)</TH>
                <TH align="right">Müsait (şimdi)</TH>
              </THead>
              <TBody>
                {o.items.map((it, i) => {
                  const live = o.items_live[i];
                  return (
                    <TR key={i}>
                      <TD>{it.name}{it.labels ? <span className="text-text-muted"> · {it.labels}</span> : null}<br /><span className="text-2xs text-text-muted" data-numeric>{live?.sku}</span></TD>
                      <TD align="right" numeric>{it.quantity}</TD>
                      <TD align="right" numeric>{formatShopPrice(it.unit_price, o.currency)}</TD>
                      <TD align="right" numeric>{live ? formatShopPrice(live.list_price_now, o.currency) : "—"}{live && live.list_price_now !== it.unit_price ? <span className="text-warning"> ≠</span> : null}</TD>
                      <TD align="right" numeric>{live?.available_now ?? "—"}</TD>
                    </TR>
                  );
                })}
              </TBody>
            </TableShell>
            <dl className="ml-auto max-w-sm divide-y divide-border border-y border-border">
              <Row label="Sipariş toplamı"><span data-numeric>{formatShopPrice(o.total, o.currency)}</span></Row>
            </dl>
            <p className="text-xs leading-relaxed text-text-muted">
              Kasada uygulanacak fiyat: sipariş fiyatı ile o anki liste fiyatının küçüğü (müşteriye onaylanan tutardan fazlası istenmez; listeden pahalıya satılmaz). Listenin altındaki fiyat kasada indirim yetkisine tabidir.
            </p>
          </section>

          <section className="space-y-2">
            <SectionHeader title="Stok ayırma" />
            <dl className="divide-y divide-border border-y border-border">
              <Row label="Rezervasyon">{o.reservation ? <><span data-numeric>{o.reservation.reservation_number}</span> · {o.reservation.status}</> : "—"}</Row>
              <Row label="Ayırma bitişi"><span data-numeric>{fmtDateTime(o.reservation?.expires_at)}</span>{o.reservation ? (holdLive ? " · geçerli" : " · doldu") : ""}</Row>
              {o.converted_sale ? <Row label="POS satışı"><Link href={`/app/pos/satis/${o.converted_sale.id}`} className="underline-offset-4 hover:underline" data-numeric>{o.converted_sale.sale_number}</Link> · {formatShopPrice(o.converted_sale.total, o.currency)}</Row> : null}
              {o.note ? <Row label="Müşteri notu">{o.note}</Row> : null}
              {o.cancel_reason ? <Row label="İptal nedeni">{o.cancel_reason}{o.cancelled_by_customer ? " (müşteri)" : o.actors.cancelled_by ? ` (${o.actors.cancelled_by})` : ""}</Row> : null}
            </dl>
          </section>

          <section className="space-y-3">
            <SectionHeader title="Geçmiş" />
            <TableShell minWidth="30rem">
              <THead>
                <TH>Zaman</TH>
                <TH>Olay</TH>
                <TH>Kim</TH>
              </THead>
              <TBody>
                {o.events.map((e, i) => (
                  <TR key={i}>
                    <TD nowrap muted>{fmtDateTime(e.at)}</TD>
                    <TD>{EVENT_LABELS[e.event] ?? e.event}{typeof e.payload.reason === "string" ? <span className="text-text-muted"> · {String(e.payload.reason)}</span> : null}</TD>
                    <TD muted>{e.actor_type === "customer" ? "Müşteri" : e.actor_type === "system" ? "Sistem" : (e.actor ?? "—")}</TD>
                  </TR>
                ))}
              </TBody>
            </TableShell>
          </section>
        </div>

        <aside className="space-y-4">
          <div className="space-y-3 rounded border border-border bg-surface p-4">
            <p className="text-sm font-medium text-text-primary">İşlemler</p>
            {o.stored_status === "pending_confirmation" && holdLive && caps.canConfirm ? <ConfirmOrderForm orderId={o.id} /> : null}
            {o.stored_status === "confirmed" && holdLive && caps.canReady ? <ReadyOrderForm orderId={o.id} /> : null}
            {(o.stored_status === "confirmed" || o.stored_status === "ready") && holdLive && caps.canConvert ? (
              <div className="space-y-1">
                <Link href={`/app/pos?siparis=${o.id}`} className="inline-flex h-9 items-center rounded border border-primary bg-primary px-3 text-sm text-primary-foreground">POS&apos;ta tamamla</Link>
                <p className="text-2xs text-text-muted">Kasada teslim: ödeme, stok düşümü ve satış fişi mevcut kasa akışıyla oluşur.</p>
              </div>
            ) : null}
            {open && !holdLive && caps.canRereserve && o.reservation ? <RereserveOrderForm orderId={o.id} /> : null}
            {o.stored_status === "expired" && caps.canRereserve ? <RereserveOrderForm orderId={o.id} /> : null}
            {open && caps.canCancel ? <CancelOrderForm orderId={o.id} /> : null}
            {!open && o.stored_status !== "expired" ? <p className="text-xs text-text-muted">Bu sipariş kapanmış.</p> : null}
            {!caps.canConfirm && open ? <p className="text-2xs text-text-muted">Onay ve iptal sahip/yönetici yetkisindedir.</p> : null}
          </div>
          <p className="text-2xs leading-relaxed text-text-muted">Sipariş bir orkestrasyon belgesidir: stok, ödeme, maliyet ve rapor yalnız kasa satışıyla oluşur.</p>
        </aside>
      </div>
    </div>
  );
}
