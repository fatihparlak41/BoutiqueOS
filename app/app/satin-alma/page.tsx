import Link from "next/link";
import { redirect } from "next/navigation";
import { isPoStatus, listPurchaseOrders, loadPoContext } from "@/lib/po/queries";
import { PO_STATUS_LABELS, type PoStatus } from "@/lib/po/model";
import { PoStatusPill } from "@/components/po/po-status-pill";
import { PageHeader } from "@/components/ui/page-header";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { Stat, StatGrid } from "@/components/ui/stat";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { formatDate, formatMoney, formatQuantity } from "@/lib/receiving/format";
import { cn } from "@/lib/utils";

export const metadata = { title: "Satın alma · BoutiqueOS" };

const FILTERS: Array<{ key: PoStatus | "open" | "all"; label: string }> = [
  { key: "open", label: "Açık" },
  { key: "draft", label: "Taslak" },
  { key: "received", label: "Teslim alındı" },
  { key: "closed", label: "Kapatıldı" },
  { key: "cancelled", label: "İptal" },
  { key: "all", label: "Tümü" },
];

/** Purchase orders: one bounded RPC; expected value only for owner / manager. */
export default async function PurchaseOrdersPage({ searchParams }: { searchParams: Promise<{ durum?: string }> }) {
  const params = await searchParams;
  const { caps } = await loadPoContext();
  if (!caps.canView) redirect("/app");
  const filter = params.durum === "all" || params.durum === "open" || isPoStatus(params.durum) ? params.durum : "open";
  const list = await listPurchaseOrders(isPoStatus(filter) ? filter : null);
  const rows = filter === "open" ? list.rows.filter((r) => r.status === "approved" || r.status === "ordered" || r.status === "partially_received") : list.rows;
  const s = list.summary;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Satın alma siparişleri"
        description="Planlama belgesi: sipariş stok, maliyet ya da borç yazmaz; bunlar yalnız mal kabul POST edilince oluşur."
        actions={caps.canManage ? <Link href="/app/satin-alma/yeni"><Button size="sm">Yeni sipariş</Button></Link> : undefined}
      />
      <StatGrid>
        <Stat label="Açık sipariş" value={formatQuantity(s.open)} hint={s.draft > 0 ? `${formatQuantity(s.draft)} taslak` : undefined} />
        <Stat label="Beklenen adet" value={formatQuantity(s.expected_units)} hint="açık siparişlerde" />
        <Stat label="Kalan adet" value={formatQuantity(s.remaining_units)} hint={`${formatQuantity(s.received_units)} teslim alındı`} />
        <Stat label="Tarihi geçen" value={formatQuantity(s.overdue)} hint="beklenen teslim tarihi geçmiş" />
      </StatGrid>
      <nav aria-label="Durum" className="-mx-5 overflow-x-auto px-5 sm:mx-0 sm:px-0">
        <ul className="flex min-w-max gap-1.5">
          {FILTERS.map((f) => (
            <li key={f.key}>
              <Link
                href={f.key === "open" ? "/app/satin-alma" : `/app/satin-alma?durum=${f.key}`}
                aria-current={f.key === filter ? "true" : undefined}
                className={cn(
                  "inline-flex h-9 items-center rounded border px-3 text-xs focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                  f.key === filter ? "border-text-primary bg-surface font-medium text-text-primary" : "border-border text-text-secondary hover:border-border-strong hover:text-text-primary",
                )}
              >
                {f.label}
              </Link>
            </li>
          ))}
        </ul>
      </nav>

      {rows.length === 0 ? (
        <EmptyState
          editorial={filter === "open" && list.rows.length === 0}
          title={filter === "open" ? "Açık sipariş yok" : `${FILTERS.find((f) => f.key === filter)?.label ?? ""} sipariş yok`}
          description={caps.canManage ? "Tedarikçiye vereceğiniz siparişi taslak olarak açın, satırları ekleyin, onaylayın; mal geldiğinde mal kabulü siparişten oluşturun." : "Siparişler sahip ve yöneticiler tarafından açılır; teslim geldiğinde mal kabulü buradan oluşturabilirsiniz."}
          action={caps.canManage ? <Link href="/app/satin-alma/yeni"><Button size="sm" variant="outline">Yeni sipariş</Button></Link> : undefined}
        />
      ) : (
        <>
          <ul className="divide-y divide-border border-y border-border sm:hidden">
            {rows.map((r) => (
              <li key={r.id}>
                <Link href={`/app/satin-alma/${r.id}`} className="block space-y-1 py-3">
                  <span className="flex items-center justify-between gap-3">
                    <span className="text-sm font-medium text-text-primary" data-numeric>{r.po_number}</span>
                    <PoStatusPill status={r.status} />
                  </span>
                  <span className="block text-xs text-text-secondary">{r.supplier} · {r.branch}</span>
                  <span className="block text-2xs text-text-muted" data-numeric>
                    {formatDate(r.order_date)}{r.expected_date ? ` → ${formatDate(r.expected_date)}${r.overdue ? " (geçti)" : ""}` : ""} · {formatQuantity(r.received)} / {formatQuantity(r.ordered)} adet
                    {r.remaining > 0 ? ` · ${formatQuantity(r.remaining)} kalan` : ""}
                    {list.financial && r.expected_total !== undefined ? ` · ${formatMoney(r.expected_total, r.currency)}` : ""}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
          <div className="hidden sm:block">
            <TableShell minWidth={list.financial ? "56rem" : "46rem"}>
              <THead>
                <TH>Sipariş</TH>
                <TH>Tedarikçi</TH>
                <TH>Şube</TH>
                <TH>Tarih</TH>
                <TH>Beklenen</TH>
                <TH>Durum</TH>
                <TH align="right">Sipariş</TH>
                <TH align="right">Teslim</TH>
                <TH align="right">Kalan</TH>
                {list.financial ? <TH align="right">Beklenen tutar</TH> : null}
              </THead>
              <TBody>
                {rows.map((r) => (
                  <TR key={r.id}>
                    <TD>
                      <CellTitle sub={r.supplier_reference ?? undefined} subNumeric>
                        <Link href={`/app/satin-alma/${r.id}`} className="hover:underline" data-numeric>{r.po_number}</Link>
                      </CellTitle>
                    </TD>
                    <TD>{r.supplier}</TD>
                    <TD muted>{r.branch}</TD>
                    <TD nowrap numeric>{formatDate(r.order_date)}</TD>
                    <TD nowrap numeric muted={!r.overdue}>{r.expected_date ? formatDate(r.expected_date) : "—"}{r.overdue ? <span className="ml-1 text-2xs text-warning">geçti</span> : null}</TD>
                    <TD><PoStatusPill status={r.status} /></TD>
                    <TD align="right" numeric>{formatQuantity(r.ordered)}</TD>
                    <TD align="right" numeric>{formatQuantity(r.received)}</TD>
                    <TD align="right" numeric muted>{r.remaining > 0 ? formatQuantity(r.remaining) : "—"}</TD>
                    {list.financial ? <TD align="right" numeric>{r.expected_total !== undefined ? formatMoney(r.expected_total, r.currency) : "—"}{r.unpriced_lines ? <span className="ml-1 text-2xs text-text-muted">{r.unpriced_lines} fiyatsız</span> : null}</TD> : null}
                  </TR>
                ))}
              </TBody>
            </TableShell>
          </div>
          <p className="text-2xs text-text-muted">Durumlar: {Object.values(PO_STATUS_LABELS).join(" · ")}. Beklenen tutar planlama bilgisidir; gerçek alış tutarı mal kabul raporundadır.</p>
        </>
      )}
    </div>
  );
}
