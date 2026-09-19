import Link from "next/link";
import { listSubscriptions } from "@/lib/platform/queries";
import { SUBSCRIPTION_FILTERS, SUBSCRIPTION_FILTER_LABELS, pageOffset, type SubscriptionFilter } from "@/lib/platform/model";
import { formatMoney, formatPlanPrice } from "@/lib/saas/model";
import { PageHeader } from "@/components/ui/page-header";
import { FilterBar } from "@/components/ui/filter-bar";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { EmptyState } from "@/components/ui/empty-state";
import { InvoicePill, SubscriptionPill, fmtDate } from "@/components/platform/pills";
import { Pager } from "@/components/platform/pager";
import { IssueInvoiceForm } from "@/components/platform/billing-forms";

export const metadata = { title: "Abonelikler · Platform · BoutiqueOS" };

export default async function SubscriptionsPage({ searchParams }: { searchParams: Promise<{ durum?: string; q?: string; sayfa?: string }> }) {
  const { durum, q, sayfa } = await searchParams;
  const status = SUBSCRIPTION_FILTERS.includes(durum as SubscriptionFilter) ? (durum as SubscriptionFilter) : null;
  const query = (q ?? "").trim().slice(0, 80) || null;
  const offset = pageOffset(sayfa);
  const list = await listSubscriptions(status, query, offset);
  const href = (page: number) =>
    `/platform/abonelikler?${new URLSearchParams({ ...(status ? { durum: status } : {}), ...(query ? { q: query } : {}), sayfa: String(page) }).toString()}`;

  return (
    <div className="space-y-6">
      <PageHeader title="Abonelikler" description="Her işletmenin ticari kaydı: plan, dönem, yenileme ve son fatura. Abonelik durumu işletme durumundan ayrıdır; ödeme gecikmesi işletmeyi kendiliğinden askıya almaz." />
      <FilterBar clearHref="/platform/abonelikler" hasFilter={Boolean(status || query)} columns={4}>
        <div className="space-y-1.5">
          <Label htmlFor="q">İşletme adı ya da kodu</Label>
          <Input id="q" name="q" defaultValue={query ?? ""} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="durum">Durum</Label>
          <Select id="durum" name="durum" defaultValue={status ?? ""}>
            <option value="">Tümü</option>
            {SUBSCRIPTION_FILTERS.map((s) => (
              <option key={s} value={s}>{SUBSCRIPTION_FILTER_LABELS[s]}</option>
            ))}
          </Select>
        </div>
      </FilterBar>
      {list.rows.length === 0 ? (
        <EmptyState title="Abonelik yok" description={status || query ? "Bu filtreye uyan abonelik bulunmuyor." : "Onaylanan her başvuru bir abonelik açar."} />
      ) : (
        <TableShell minWidth="60rem" footer={`${list.total} abonelik`}>
          <THead>
            <TH>İşletme</TH>
            <TH>Plan</TH>
            <TH>Dönem</TH>
            <TH>Yenileme</TH>
            <TH>Son fatura</TH>
            <TH>Durum</TH>
            <TH>İşlem</TH>
          </THead>
          <TBody>
            {list.rows.map((s) => {
              const closed = s.status === "cancelled" || s.status === "expired";
              const openInvoice = Boolean(s.latest_invoice && s.latest_invoice.status === "open");
              return (
                <TR key={s.id}>
                  <TD>
                    <CellTitle sub={s.business.code}>
                      <Link href={`/platform/isletmeler/${s.business.id}`} className="hover:underline">{s.business.name}</Link>
                    </CellTitle>
                  </TD>
                  <TD muted>{s.plan ? <>{s.plan.name}<br /><span className="text-xs" data-numeric>{formatPlanPrice(s.plan)}</span></> : "—"}</TD>
                  <TD nowrap muted>{s.starts_at ? `${fmtDate(s.starts_at)} – ${fmtDate(s.ends_at)}` : "başlamadı"}{s.lapsed ? <><br /><span className="text-xs text-warning">dönem bitti</span></> : null}</TD>
                  <TD nowrap muted>{s.cancel_at_period_end ? "dönem sonunda iptal" : closed ? "—" : fmtDate(s.renews_at)}</TD>
                  <TD muted>
                    {s.latest_invoice ? (
                      <>
                        <Link href={`/platform/faturalar/${s.latest_invoice.id}`} className="hover:underline" data-numeric>{s.latest_invoice.invoice_number}</Link>
                        <br />
                        <span className="text-xs" data-numeric>{formatMoney(s.latest_invoice.total, s.latest_invoice.currency)}</span>{" "}
                        <InvoicePill status={s.latest_invoice.status} overdue={s.latest_invoice.overdue} />
                      </>
                    ) : (
                      "kesilmedi"
                    )}
                  </TD>
                  <TD><SubscriptionPill status={s.status} /></TD>
                  <TD>
                    {closed ? (
                      <span className="text-xs text-text-muted">kapalı</span>
                    ) : (
                      <IssueInvoiceForm
                        subscriptionId={s.id}
                        kind={s.invoice_count === 0 ? "first" : "renewal"}
                        disabled={openInvoice || s.cancel_at_period_end}
                        disabledReason={s.cancel_at_period_end ? "dönem sonu iptali planlı" : "açık fatura var"}
                      />
                    )}
                  </TD>
                </TR>
              );
            })}
          </TBody>
        </TableShell>
      )}
      <Pager total={list.total} offset={list.offset} href={href} />
    </div>
  );
}
