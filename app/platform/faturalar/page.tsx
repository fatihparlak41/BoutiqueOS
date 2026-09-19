import Link from "next/link";
import { listInvoices } from "@/lib/platform/queries";
import { INVOICE_FILTERS, INVOICE_FILTER_LABELS, pageOffset, type InvoiceFilter } from "@/lib/platform/model";
import { formatMoney } from "@/lib/saas/model";
import { PageHeader } from "@/components/ui/page-header";
import { FilterBar } from "@/components/ui/filter-bar";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { EmptyState } from "@/components/ui/empty-state";
import { InvoicePill, fmtDate } from "@/components/platform/pills";
import { Pager } from "@/components/platform/pager";

export const metadata = { title: "Faturalar · Platform · BoutiqueOS" };

export default async function InvoicesPage({ searchParams }: { searchParams: Promise<{ durum?: string; q?: string; sayfa?: string }> }) {
  const { durum, q, sayfa } = await searchParams;
  const status = INVOICE_FILTERS.includes(durum as InvoiceFilter) ? (durum as InvoiceFilter) : null;
  const query = (q ?? "").trim().slice(0, 80) || null;
  const offset = pageOffset(sayfa);
  const list = await listInvoices(status, query, offset);
  const href = (page: number) =>
    `/platform/faturalar?${new URLSearchParams({ ...(status ? { durum: status } : {}), ...(query ? { q: query } : {}), sayfa: String(page) }).toString()}`;

  return (
    <div className="space-y-6">
      <PageHeader title="Faturalar" description="Abonelik faturaları. Tutar ve dönem kesim anındaki plan fiyatının anlık görüntüsüdür; ödenen ya da iptal edilen fatura değişmez." />
      <FilterBar clearHref="/platform/faturalar" hasFilter={Boolean(status || query)} columns={4}>
        <div className="space-y-1.5">
          <Label htmlFor="q">Fatura no, işletme adı ya da kodu</Label>
          <Input id="q" name="q" defaultValue={query ?? ""} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="durum">Durum</Label>
          <Select id="durum" name="durum" defaultValue={status ?? ""}>
            <option value="">Tümü</option>
            {INVOICE_FILTERS.map((s) => (
              <option key={s} value={s}>{INVOICE_FILTER_LABELS[s]}</option>
            ))}
          </Select>
        </div>
      </FilterBar>
      {list.rows.length === 0 ? (
        <EmptyState title="Fatura yok" description={status || query ? "Bu filtreye uyan fatura bulunmuyor." : "Henüz hiç fatura kesilmedi. Faturalar abonelik kartından ya da Abonelikler sayfasından kesilir."} />
      ) : (
        <TableShell minWidth="52rem" footer={`${list.total} fatura`}>
          <THead>
            <TH>Fatura</TH>
            <TH>İşletme</TH>
            <TH>Dönem</TH>
            <TH align="right">Tutar</TH>
            <TH align="right">Kalan</TH>
            <TH>Vade</TH>
            <TH>Durum</TH>
          </THead>
          <TBody>
            {list.rows.map((i) => (
              <TR key={i.id}>
                <TD>
                  <CellTitle sub={`${i.plan_name} · ${fmtDate(i.issued_at)}`}>
                    <Link href={`/platform/faturalar/${i.id}`} className="hover:underline" data-numeric>{i.invoice_number}</Link>
                  </CellTitle>
                </TD>
                <TD muted>
                  <Link href={`/platform/isletmeler/${i.business.id}`} className="hover:underline">{i.business.name}</Link>
                  <br />
                  <span className="text-xs" data-numeric>{i.business.code}</span>
                </TD>
                <TD nowrap muted>{fmtDate(i.billing_period_start)} – {fmtDate(i.billing_period_end)}</TD>
                <TD align="right" numeric>{formatMoney(i.total, i.currency)}</TD>
                <TD align="right" numeric>{i.status === "open" ? formatMoney(i.balance, i.currency) : "—"}</TD>
                <TD nowrap muted>{i.status === "open" ? `${fmtDate(i.due_at)}${i.overdue ? ` · ${i.days_overdue} gün` : ""}` : i.status === "paid" ? `ödendi ${fmtDate(i.paid_at)}` : `iptal ${fmtDate(i.voided_at)}`}</TD>
                <TD><InvoicePill status={i.status} overdue={i.overdue} /></TD>
              </TR>
            ))}
          </TBody>
        </TableShell>
      )}
      <Pager total={list.total} offset={list.offset} href={href} />
    </div>
  );
}
