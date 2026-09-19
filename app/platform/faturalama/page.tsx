import Link from "next/link";
import { getBillingOverview, listInvoices, listSubscriptions } from "@/lib/platform/queries";
import { formatMoney, SUBSCRIPTION_STATUS_LABELS, type SubscriptionStatus } from "@/lib/saas/model";
import { PageHeader } from "@/components/ui/page-header";
import { Stat, StatGrid } from "@/components/ui/stat";
import { SectionHeader } from "@/components/ui/section-header";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { EmptyState } from "@/components/ui/empty-state";
import { InvoicePill, SubscriptionPill, fmtDate } from "@/components/platform/pills";
import { BillingSettingForm, BillingSweepForm } from "@/components/platform/billing-forms";

export const metadata = { title: "Faturalama · Platform · BoutiqueOS" };

const SUB_ORDER: SubscriptionStatus[] = ["pending", "active", "past_due", "cancelled", "expired"];

/**
 * The billing desk. Manual billing only: the platform issues, the customer pays outside
 * the app, the platform records. Every number here is a bounded PostgreSQL aggregate.
 */
export default async function BillingHome() {
  const [overview, overdue, awaiting] = await Promise.all([
    getBillingOverview(),
    listInvoices("overdue", null, 0),
    listSubscriptions("pending", null, 0),
  ]);
  const totals = (t: Record<string, number>) =>
    Object.entries(t).length === 0 ? "—" : Object.entries(t).map(([c, v]) => formatMoney(v, c)).join(" · ");

  return (
    <div className="space-y-8">
      <PageHeader
        title="Faturalama"
        description="Platform faturayı keser, müşteri BoutiqueOS dışında öder, platform ödemeyi doğrulayıp kaydeder, abonelik etkinleşir. Kart, sağlayıcı ya da otomatik tahsilat yoktur."
      />
      <StatGrid>
        <Stat label="Ödeme bekleyen fatura" value={overview.invoices.open} hint={totals(overview.open_totals)} href="/platform/faturalar?durum=open" />
        <Stat label="Vadesi geçmiş" value={overview.invoices.overdue} href="/platform/faturalar?durum=overdue" />
        <Stat label="Son 30 günde ödenen" value={overview.invoices.paid_30d} hint={totals(overview.paid_30d_totals)} href="/platform/faturalar?durum=paid" />
        <Stat label="İlk faturasını bekleyen" value={overview.awaiting_first_invoice} href="/platform/abonelikler?durum=pending" />
        <Stat label="30 gün içinde yenilenecek" value={overview.renewal_due_30d} hint="yenileme faturası kesilmemiş" href="/platform/abonelikler?durum=active" />
        <Stat label="Dönemi bitmiş" value={overview.lapsed} hint="aktif görünen, süresi geçmiş" href="/platform/abonelikler?durum=lapsed" />
        <Stat label="Dönem sonu iptali" value={overview.scheduled_cancellations} href="/platform/abonelikler" />
        <Stat
          label="Abonelikler"
          value={SUB_ORDER.reduce((n, s) => n + (overview.subscriptions[s] ?? 0), 0)}
          hint={SUB_ORDER.filter((s) => overview.subscriptions[s]).map((s) => `${overview.subscriptions[s]} ${SUBSCRIPTION_STATUS_LABELS[s].toLowerCase()}`).join(" · ") || undefined}
          href="/platform/abonelikler"
        />
      </StatGrid>

      <div className="grid grid-cols-1 gap-8 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <div className="space-y-8">
          <section className="space-y-3">
            <SectionHeader title="Vadesi geçmiş faturalar" meta={overdue.total > 0 ? `${overdue.total}` : undefined} action={<Link href="/platform/faturalar?durum=overdue" className="underline-offset-4 hover:underline">Tümü</Link>} />
            {overdue.rows.length === 0 ? (
              <EmptyState compact title="Vadesi geçmiş fatura yok" description="Vade, her okumada fatura tarihine göre hesaplanır." />
            ) : (
              <TableShell minWidth="40rem">
                <THead>
                  <TH>Fatura</TH>
                  <TH>İşletme</TH>
                  <TH align="right">Kalan</TH>
                  <TH>Vade</TH>
                  <TH>Durum</TH>
                </THead>
                <TBody>
                  {overdue.rows.slice(0, 10).map((i) => (
                    <TR key={i.id}>
                      <TD>
                        <CellTitle sub={i.plan_name}>
                          <Link href={`/platform/faturalar/${i.id}`} className="hover:underline" data-numeric>{i.invoice_number}</Link>
                        </CellTitle>
                      </TD>
                      <TD muted><Link href={`/platform/isletmeler/${i.business.id}`} className="hover:underline">{i.business.name}</Link></TD>
                      <TD align="right" numeric>{formatMoney(i.balance, i.currency)}</TD>
                      <TD nowrap muted>{fmtDate(i.due_at)} · {i.days_overdue} gün</TD>
                      <TD><InvoicePill status={i.status} overdue={i.overdue} /></TD>
                    </TR>
                  ))}
                </TBody>
              </TableShell>
            )}
          </section>

          <section className="space-y-3">
            <SectionHeader title="İlk faturasını bekleyen abonelikler" meta={awaiting.total > 0 ? `${awaiting.total}` : undefined} action={<Link href="/platform/abonelikler?durum=pending" className="underline-offset-4 hover:underline">Tümü</Link>} />
            {awaiting.rows.length === 0 ? (
              <EmptyState compact title="Bekleyen abonelik yok" description="Onaylanan her işletme burada, ilk faturası kesilene kadar listelenir." />
            ) : (
              <TableShell minWidth="36rem">
                <THead>
                  <TH>İşletme</TH>
                  <TH>Plan</TH>
                  <TH>Son fatura</TH>
                  <TH>Durum</TH>
                </THead>
                <TBody>
                  {awaiting.rows.slice(0, 10).map((s) => (
                    <TR key={s.id}>
                      <TD>
                        <CellTitle sub={s.business.code}>
                          <Link href={`/platform/isletmeler/${s.business.id}`} className="hover:underline">{s.business.name}</Link>
                        </CellTitle>
                      </TD>
                      <TD muted>{s.plan?.name ?? "—"}</TD>
                      <TD muted>{s.latest_invoice ? <InvoicePill status={s.latest_invoice.status} overdue={s.latest_invoice.overdue} /> : "kesilmedi"}</TD>
                      <TD><SubscriptionPill status={s.status} /></TD>
                    </TR>
                  ))}
                </TBody>
              </TableShell>
            )}
          </section>
        </div>

        <aside className="space-y-4">
          <BillingSweepForm />
          <BillingSettingForm
            settingKey="invoice_due_days"
            label="Vade süresi"
            hint="Yeni kesilen faturanın vadesi: kesim tarihi + bu kadar gün."
            value={overview.settings.invoice_due_days}
          />
          <BillingSettingForm
            settingKey="billing_grace_days"
            label="Ek süre (bilgi)"
            hint="Vadeden sonra gösterilen ek süre. 13B'de yalnız görüntülenir; hiçbir işletme otomatik askıya alınmaz."
            value={overview.settings.billing_grace_days}
          />
          <p className="text-2xs leading-relaxed text-text-muted">
            KDV/vergi uygulanmaz (politika: yapılandırılmamış); belgeler yasal fatura değil, abonelik ödeme özetidir.
          </p>
        </aside>
      </div>
    </div>
  );
}
