import { requireTenant } from "@/lib/tenant";
import { getMyBilling } from "@/lib/saas/queries";
import { INVOICE_STATUS_LABELS, PAYMENT_METHOD_LABELS, SUBSCRIPTION_STATUS_LABELS, formatMoney, formatPlanPrice } from "@/lib/saas/model";
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
import { Badge } from "@/components/ui/badge";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";

export const metadata = { title: "Abonelik · Ayarlar · BoutiqueOS" };

const dateOnly = new Intl.DateTimeFormat("tr-TR", { dateStyle: "medium" });
const fmt = (iso: string | null | undefined) => (iso ? dateOnly.format(new Date(iso)) : "—");

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-4 py-2 text-sm">
      <dt className="text-text-muted">{label}</dt>
      <dd className="text-right text-text-primary">{children}</dd>
    </div>
  );
}

/**
 * The owner's view of the commercial relationship with BoutiqueOS: plan, subscription
 * state, period, invoices and the payments the platform recorded. Read-only by design —
 * there is nothing to pay here. Money moves outside the app (bank transfer / cash) and
 * the platform records it; the page says so instead of pretending to collect it.
 * Owner only: managers and staff have no SaaS billing surface.
 */
export default async function SubscriptionSettingsPage() {
  const { active } = await requireTenant();
  if (active.role !== "owner") {
    return (
      <div className="space-y-8">
        <PageHeader eyebrow={{ href: "/app/ayarlar", label: "Ayarlar" }} title="Abonelik" />
        <EmptyState compact title="Bu bölüm işletme sahibine açıktır" description="Abonelik ve fatura bilgilerini yalnız işletme sahibi görür." />
      </div>
    );
  }
  const billing = await getMyBilling(active.business_id);
  const sub = billing.subscription;

  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow={{ href: "/app/ayarlar", label: "Ayarlar" }}
        title="Abonelik"
        description={`${active.business_name} işletmesinin BoutiqueOS aboneliği ve faturaları.`}
        actions={sub ? <Badge tone={sub.status === "active" ? "success" : sub.status === "past_due" ? "warning" : sub.status === "pending" ? "accent" : "neutral"}>{SUBSCRIPTION_STATUS_LABELS[sub.status]}</Badge> : null}
      />

      {!sub ? (
        <EmptyState compact title="Bu işletme için abonelik kaydı yok" description="Platform öncesi kiracı: abonelik ve faturalama BoutiqueOS ekibi tarafından ayrıca yönetilir." />
      ) : (
        <>
          <section className="space-y-2">
            <SectionHeader title="Plan ve dönem" />
            <dl className="divide-y divide-border border-y border-border">
              <Row label="Plan">{sub.plan ? <>{sub.plan.name} <span className="text-text-muted" data-numeric>— {formatPlanPrice(sub.plan)}</span></> : "—"}</Row>
              <Row label="Durum">{SUBSCRIPTION_STATUS_LABELS[sub.status]}{sub.lapsed ? " · dönem sona erdi" : ""}</Row>
              <Row label="Dönem"><span data-numeric>{sub.starts_at ? `${fmt(sub.starts_at)} – ${fmt(sub.ends_at)}` : "henüz başlamadı"}</span></Row>
              <Row label="Yenileme"><span data-numeric>{sub.cancel_at_period_end ? "dönem sonunda sona erecek" : fmt(sub.renews_at)}</span></Row>
            </dl>
            <p className="text-xs leading-relaxed text-text-muted">
              {sub.status === "pending"
                ? "Ödeme bilgileri işletmenizle paylaşılacaktır. Ödemeniz alındıktan sonra aboneliğiniz etkinleştirilecektir."
                : "Yenileme faturası dönem sonuna doğru kesilir; ödeme bilgileri işletmenizle paylaşılır. Ödeme alındığında bir sonraki dönem etkinleşir."}
            </p>
          </section>

          <section className="space-y-3">
            <SectionHeader title="Faturalar" meta={billing.invoices.length > 0 ? `${billing.invoices.length}` : undefined} />
            {billing.invoices.length === 0 ? (
              <p className="text-sm text-text-muted">Henüz fatura kesilmedi.</p>
            ) : (
              <TableShell minWidth="40rem">
                <THead>
                  <TH>Fatura</TH>
                  <TH>Dönem</TH>
                  <TH align="right">Tutar</TH>
                  <TH>Vade</TH>
                  <TH>Durum</TH>
                </THead>
                <TBody>
                  {billing.invoices.map((i) => (
                    <TR key={i.id}>
                      <TD>
                        <CellTitle sub={`${i.plan_name} · ${fmt(i.issued_at)}`}>
                          <span data-numeric>{i.invoice_number}</span>
                        </CellTitle>
                        {i.payments.length > 0 ? (
                          <ul className="mt-1 space-y-0.5 text-xs text-text-muted">
                            {i.payments.map((p, n) => (
                              <li key={n} data-numeric>
                                {fmt(p.paid_at)} · {PAYMENT_METHOD_LABELS[p.method]} · {formatMoney(p.amount, p.currency)}
                              </li>
                            ))}
                          </ul>
                        ) : null}
                      </TD>
                      <TD nowrap muted>{fmt(i.billing_period_start)} – {fmt(i.billing_period_end)}</TD>
                      <TD align="right" numeric>
                        {formatMoney(i.total, i.currency)}
                        {i.status === "open" && i.amount_paid > 0 ? <><br /><span className="text-xs text-text-muted">kalan {formatMoney(i.balance, i.currency)}</span></> : null}
                      </TD>
                      <TD nowrap muted>{i.status === "open" ? fmt(i.due_at) : i.status === "paid" ? `ödendi ${fmt(i.paid_at)}` : "—"}</TD>
                      <TD>
                        {i.status === "open" && i.overdue ? <Badge tone="warning">Vadesi geçti</Badge> : <Badge tone={i.status === "paid" ? "success" : i.status === "open" ? "accent" : "neutral"}>{INVOICE_STATUS_LABELS[i.status]}</Badge>}
                      </TD>
                    </TR>
                  ))}
                </TBody>
              </TableShell>
            )}
            <p className="text-2xs leading-relaxed text-text-muted">
              Bu belgeler abonelik ödeme özetidir, yasal fatura değildir; vergi uygulanmamıştır. Ödemeler platform tarafından, para alındıktan sonra kaydedilir.
            </p>
          </section>
        </>
      )}
    </div>
  );
}
