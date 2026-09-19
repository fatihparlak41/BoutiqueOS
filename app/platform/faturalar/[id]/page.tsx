import Link from "next/link";
import { notFound } from "next/navigation";
import { getInvoice } from "@/lib/platform/queries";
import { PAYMENT_METHOD_LABELS, formatMoney } from "@/lib/saas/model";
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";
import { BusinessPill, InvoicePill, SubscriptionPill, fmtDate, fmtDateTime } from "@/components/platform/pills";
import { RecordPaymentForm, VoidInvoiceForm } from "@/components/platform/billing-forms";

export const metadata = { title: "Fatura · Platform · BoutiqueOS" };

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-4 py-2 text-sm">
      <dt className="text-text-muted">{label}</dt>
      <dd className="text-right text-text-primary" data-numeric>{children}</dd>
    </div>
  );
}

export default async function InvoiceDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const inv = await getInvoice(id);
  if (!inv) notFound();
  const money = (v: number) => formatMoney(v, inv.currency);

  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow={{ href: "/platform/faturalar", label: "Faturalar" }}
        title={inv.invoice_number}
        description={
          <>
            <Link href={`/platform/isletmeler/${inv.business.id}`} className="underline-offset-4 hover:underline">{inv.business.name}</Link> · <span data-numeric>{inv.business.code}</span> · {inv.plan_name} · kesim {fmtDate(inv.issued_at)}
            {inv.issued_by ? ` · ${inv.issued_by}` : ""}
          </>
        }
        actions={<InvoicePill status={inv.status} overdue={inv.overdue} />}
      />

      <div className="grid grid-cols-1 gap-8 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <div className="space-y-8">
          <section className="space-y-2">
            <SectionHeader title="Abonelik ödeme özeti" meta="yasal fatura değildir" />
            <TableShell minWidth="28rem">
              <THead>
                <TH>Kalem</TH>
                <TH align="right">Adet</TH>
                <TH align="right">Birim</TH>
                <TH align="right">Tutar</TH>
              </THead>
              <TBody>
                {inv.items.map((it) => (
                  <TR key={it.line_no}>
                    <TD>{it.description}</TD>
                    <TD align="right" numeric>{it.quantity}</TD>
                    <TD align="right" numeric>{money(it.unit_amount)}</TD>
                    <TD align="right" numeric>{money(it.line_total)}</TD>
                  </TR>
                ))}
              </TBody>
            </TableShell>
            <dl className="ml-auto max-w-sm divide-y divide-border border-y border-border">
              <Row label="Ara toplam">{money(inv.subtotal)}</Row>
              <Row label="Vergi">{money(inv.tax_amount)} <span className="text-xs text-text-muted">(uygulanmadı — yapılandırılmamış)</span></Row>
              <Row label="Toplam">{money(inv.total)}</Row>
              <Row label="Ödenen">{money(inv.amount_paid)}</Row>
              {inv.status === "open" ? <Row label="Kalan">{money(inv.balance)}</Row> : null}
            </dl>
          </section>

          <section className="space-y-2">
            <SectionHeader title="Dönem ve vade" />
            <dl className="divide-y divide-border border-y border-border">
              <Row label="Fatura dönemi">{fmtDate(inv.billing_period_start)} – {fmtDate(inv.billing_period_end)}</Row>
              <Row label="Kesim">{fmtDateTime(inv.issued_at)}</Row>
              <Row label="Vade">{fmtDate(inv.due_at)}{inv.overdue ? ` · ${inv.days_overdue} gün geçti · ek süre sonu ${fmtDate(inv.grace_ends_at)}` : ""}</Row>
              {inv.paid_at ? <Row label="Ödendi">{fmtDateTime(inv.paid_at)}</Row> : null}
              {inv.voided_at ? <Row label="İptal">{fmtDateTime(inv.voided_at)}{inv.voided_by ? ` · ${inv.voided_by}` : ""}{inv.void_reason ? ` · ${inv.void_reason}` : ""}</Row> : null}
              {inv.note ? <Row label="Not">{inv.note}</Row> : null}
            </dl>
          </section>

          <section className="space-y-3">
            <SectionHeader title="Ödemeler" meta={inv.payments.length > 0 ? `${inv.payments.length}` : undefined} />
            {inv.payments.length === 0 ? (
              <p className="text-sm text-text-muted">Henüz ödeme kaydedilmedi.</p>
            ) : (
              <TableShell minWidth="40rem">
                <THead>
                  <TH>Tarih</TH>
                  <TH>Yöntem</TH>
                  <TH>Referans</TH>
                  <TH align="right">Tutar</TH>
                  <TH>Kaydeden</TH>
                </THead>
                <TBody>
                  {inv.payments.map((p) => (
                    <TR key={p.id}>
                      <TD nowrap muted>{fmtDate(p.paid_at)}</TD>
                      <TD>{PAYMENT_METHOD_LABELS[p.method]}</TD>
                      <TD muted><span data-numeric>{p.reference}</span>{p.note ? <><br /><span className="text-xs">{p.note}</span></> : null}</TD>
                      <TD align="right" numeric>{formatMoney(p.amount, p.currency)}</TD>
                      <TD muted>{p.recorded_by ?? "—"}<br /><span className="text-xs">{fmtDateTime(p.recorded_at)}</span></TD>
                    </TR>
                  ))}
                </TBody>
              </TableShell>
            )}
          </section>
        </div>

        <aside className="space-y-4">
          <div className="space-y-2 rounded border border-border bg-surface p-4 text-sm">
            <div className="flex items-center justify-between gap-2">
              <span className="text-text-muted">İşletme</span>
              <BusinessPill status={inv.business.status} />
            </div>
            <div className="flex items-center justify-between gap-2">
              <span className="text-text-muted">Abonelik</span>
              <SubscriptionPill status={inv.subscription.status} />
            </div>
            <p className="text-xs text-text-muted" data-numeric>
              {inv.subscription.plan?.name ?? inv.plan_name} · {fmtDate(inv.subscription.starts_at)} – {fmtDate(inv.subscription.ends_at)}
              {inv.subscription.cancel_at_period_end ? " · dönem sonunda iptal" : ""}
            </p>
            <Link href={`/platform/isletmeler/${inv.business.id}`} className="text-xs underline-offset-4 hover:underline">İşletme sayfası →</Link>
          </div>
          {inv.status === "open" ? (
            <>
              <RecordPaymentForm invoiceId={inv.id} currency={inv.currency} balance={inv.balance} />
              <VoidInvoiceForm invoiceId={inv.id} disabled={inv.amount_paid > 0} />
            </>
          ) : (
            <p className="text-xs leading-relaxed text-text-muted">
              {inv.status === "paid" ? "Ödenmiş fatura değiştirilemez; tutar, dönem ve ödemeler dondurulmuştur." : "İptal edilmiş fatura tarih olarak saklanır; aynı dönem için yeni fatura kesilebilir."}
            </p>
          )}
        </aside>
      </div>
    </div>
  );
}
