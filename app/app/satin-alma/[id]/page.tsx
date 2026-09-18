import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { getPurchaseOrder, loadPoContext } from "@/lib/po/queries";
import { variantSiblings } from "@/lib/receiving/queries";
import { PO_STATUS_LABELS } from "@/lib/po/model";
import { PoStatusPill } from "@/components/po/po-status-pill";
import { ReceiptStatusPill } from "@/components/receiving/receipt-status-pill";
import { PoActions, PoHeaderForm, PoLinePicker, RemoveLineButton } from "@/components/po/po-editor";
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { Stat, StatGrid } from "@/components/ui/stat";
import { EmptyState } from "@/components/ui/empty-state";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { formatDate, formatDateTime, formatMoney, formatQuantity, formatRate } from "@/lib/receiving/format";

export const metadata = { title: "Sipariş · BoutiqueOS" };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Purchase order detail: header, timeline, the line matrix with ordered / received /
 * remaining (derived from posted receipts), linked receipts, and the actions the status
 * and the role allow. Expected costs render only when the RPC included them (manager+).
 */
export default async function PurchaseOrderPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ekle?: string; neden?: string }> }) {
  const { id } = await params;
  const sp = await searchParams;
  if (!UUID.test(id)) notFound();
  const { caps } = await loadPoContext();
  if (!caps.canView) redirect("/app");
  const prefillId = sp.ekle && UUID.test(sp.ekle) ? sp.ekle : null;
  const [po, prefill] = await Promise.all([getPurchaseOrder(id), prefillId && caps.canManage ? variantSiblings(prefillId) : Promise.resolve([])]);
  if (!po) notFound();
  const editing = po.status === "draft" && caps.canManage;
  const headerEditable = caps.canManage && (po.status === "approved" || po.status === "ordered" || po.status === "partially_received");
  const fin = po.financial;
  const today = new Date().toISOString().slice(0, 10);
  const timeline = [
    { label: "Oluşturuldu", e: po.timeline.created },
    { label: "Onaylandı", e: po.timeline.approved },
    { label: "Sipariş verildi", e: po.timeline.ordered },
    { label: "İptal edildi", e: po.timeline.cancelled },
    { label: "Kapatıldı", e: po.timeline.closed },
  ].filter((t) => t.e);

  return (
    <div className="max-w-5xl space-y-8">
      <PageHeader
        eyebrow={{ href: "/app/satin-alma", label: "Satın alma siparişleri" }}
        title={<span className="flex flex-wrap items-center gap-3"><span data-numeric>{po.po_number}</span><PoStatusPill status={po.status} /></span>}
        description={`${po.supplier} · ${po.branch} · ${po.currency}${po.fx_rate_snapshot && po.currency !== "TRY" ? ` (bilgi kuru ${formatRate(po.fx_rate_snapshot)})` : ""} · sipariş ${formatDate(po.order_date)}${po.expected_date ? ` · beklenen ${formatDate(po.expected_date)}` : ""}${po.supplier_reference ? ` · ${po.supplier_reference}` : ""}`}
      />

      <StatGrid>
        <Stat label="Sipariş adedi" value={formatQuantity(po.totals.ordered)} hint={`${formatQuantity(po.totals.lines)} satır`} />
        <Stat label="Teslim alınan" value={formatQuantity(po.totals.received)} hint="POST edilmiş mal kabullerden" />
        <Stat label="Kalan" value={formatQuantity(po.totals.remaining)} hint={po.status === "closed" && po.totals.remaining > 0 ? "kapatıldı, gelmeyecek" : undefined} />
        {fin && po.totals.expected_total !== undefined ? <Stat label="Beklenen tutar" value={formatMoney(po.totals.expected_total, po.currency)} hint={po.totals.unpriced_lines ? `${po.totals.unpriced_lines} satır fiyatsız` : "planlama, muhasebe değil"} /> : null}
      </StatGrid>

      <section className="space-y-3">
        <SectionHeader title="Zaman çizelgesi" />
        <ol className="flex flex-wrap gap-x-6 gap-y-1 text-xs text-text-secondary">
          {timeline.map((t) => (
            <li key={t.label} data-numeric>
              <span className="text-text-muted">{t.label}:</span> {formatDateTime(t.e!.at)}{t.e!.by ? ` · ${t.e!.by}` : ""}{t.e!.reason ? ` · ${t.e!.reason}` : ""}
            </li>
          ))}
        </ol>
        {po.note ? <p className="text-xs text-text-muted">Not: {po.note}</p> : null}
      </section>

      {headerEditable ? (
        <section className="space-y-3">
          <SectionHeader title="Teslim bilgisi" meta="ticari şartlar dondurulmuştur" />
          <PoHeaderForm po={po} />
        </section>
      ) : null}
      {editing ? (
        <section className="space-y-3">
          <SectionHeader title="Başlık" />
          <PoHeaderForm po={po} />
        </section>
      ) : null}

      <section className="space-y-3">
        <SectionHeader title="Satırlar" meta={`${formatQuantity(po.totals.lines)} satır`} />
        {po.lines.length === 0 ? (
          <EmptyState compact title="Henüz satır yok" description={editing ? "Aşağıdan ürün arayıp beden/renk serisinin adetlerini girin." : "Satırlar taslakta eklenir."} />
        ) : (
          <>
            <ul className="divide-y divide-border border-y border-border sm:hidden">
              {po.lines.map((l) => (
                <li key={l.variant_id} className="space-y-1 py-3">
                  <span className="flex items-center justify-between gap-3">
                    <span className="text-sm font-medium text-text-primary">{l.product}</span>
                    <span className="text-xs" data-numeric>{formatQuantity(l.received)} / {formatQuantity(l.ordered)}</span>
                  </span>
                  <span className="block text-2xs text-text-muted" data-numeric>{l.options ?? "seçeneksiz"} · {l.sku} · müsait {formatQuantity(l.available)}{l.remaining > 0 ? ` · kalan ${formatQuantity(l.remaining)}` : ""}{fin && l.expected_unit_cost != null ? ` · beklenen ${formatMoney(l.expected_unit_cost, po.currency)}` : ""}</span>
                  {editing ? <RemoveLineButton poId={po.id} variantId={l.variant_id} /> : null}
                </li>
              ))}
            </ul>
            <div className="hidden sm:block">
              <TableShell minWidth={fin ? "52rem" : "40rem"}>
                <THead>
                  <TH>Ürün</TH>
                  <TH>Renk / beden</TH>
                  <TH align="right">Müsait</TH>
                  <TH align="right">Sipariş</TH>
                  <TH align="right">Teslim</TH>
                  <TH align="right">Kalan</TH>
                  {fin ? <TH align="right">Beklenen maliyet</TH> : null}
                  {fin ? <TH align="right">Beklenen tutar</TH> : null}
                  {editing ? <TH align="right"><span className="sr-only">Sil</span></TH> : null}
                </THead>
                <TBody>
                  {po.lines.map((l) => (
                    <TR key={l.variant_id}>
                      <TD><CellTitle sub={l.sku} subNumeric><Link href={`/app/urunler/${l.product_id}`} className="hover:underline">{l.product}</Link></CellTitle></TD>
                      <TD muted>{l.options ?? "—"}</TD>
                      <TD align="right" numeric muted>{formatQuantity(l.available)}</TD>
                      <TD align="right" numeric>{formatQuantity(l.ordered)}</TD>
                      <TD align="right" numeric>{formatQuantity(l.received)}</TD>
                      <TD align="right" numeric muted={l.remaining === 0}>{formatQuantity(l.remaining)}</TD>
                      {fin ? <TD align="right" numeric>{l.expected_unit_cost != null ? formatMoney(l.expected_unit_cost, po.currency) : <span className="text-text-muted">—</span>}</TD> : null}
                      {fin ? <TD align="right" numeric>{l.expected_total != null ? formatMoney(l.expected_total, po.currency) : "—"}</TD> : null}
                      {editing ? <TD align="right"><RemoveLineButton poId={po.id} variantId={l.variant_id} /></TD> : null}
                    </TR>
                  ))}
                </TBody>
              </TableShell>
            </div>
          </>
        )}
        {editing ? <PoLinePicker po={po} initialResults={prefill} why={prefill.length > 0 ? sp.neden?.slice(0, 200) ?? null : null} canSeeCost={caps.canSeeCost} /> : null}
      </section>

      <section className="space-y-3">
        <SectionHeader title="Bağlı mal kabuller" meta={po.receipts.length > 0 ? `${po.receipts.length} belge` : undefined} />
        {po.receipts.length === 0 ? (
          <p className="text-xs text-text-muted">Henüz bu siparişe bağlı mal kabul yok. Teslim alınan adet yalnız POST edilmiş belgelerden sayılır; taslak ve iptal edilmiş belgeler sayılmaz.</p>
        ) : (
          <ul className="divide-y divide-border rounded border border-border text-sm">
            {po.receipts.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 px-4 py-2.5">
                <span className="flex items-center gap-3">
                  <Link href={`/app/mal-kabul/${r.id}`} className="font-medium hover:underline" data-numeric>{r.receipt_number}</Link>
                  <ReceiptStatusPill status={r.status} />
                  {r.reversed ? <span className="text-2xs text-danger">ters kaydedildi</span> : null}
                </span>
                <span className="text-xs text-text-muted" data-numeric>
                  {formatQuantity(r.units)} adet · {formatDate(r.received_at)} · {r.invoice_currency}{r.invoice_currency !== "TRY" ? ` @ ${formatRate(r.exchange_rate)}` : ""}
                  {r.status === "posted" && !r.reversed ? " · sayıldı" : r.status === "posted" ? " · sayılmıyor (ters kayıt)" : " · sayılmıyor"}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>

      {caps.canManage || (caps.canReceive && (po.status === "ordered" || po.status === "partially_received")) ? <PoActions po={po} caps={caps} today={today} /> : null}
      <p className="text-2xs text-text-muted">Durumlar: {Object.values(PO_STATUS_LABELS).join(" → ")}. Onaydan sonra satırlar ve ticari şartlar değişmez; fark için yeni sipariş açılır. Kısmen teslim alınan sipariş iptal edilmez, bekleyen miktar kapatılır.</p>
    </div>
  );
}
