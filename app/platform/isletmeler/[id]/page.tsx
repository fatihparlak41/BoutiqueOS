import Link from "next/link";
import { notFound } from "next/navigation";
import { getBusiness } from "@/lib/platform/queries";
import { AUDIT_ACTION_LABELS, AUDIT_PAYLOAD_KEYS } from "@/lib/platform/model";
import { formatPlanPrice } from "@/lib/saas/model";
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";
import { BusinessPill, SubscriptionPill, ApplicationPill, InvoicePill, fmtDate, fmtDateTime } from "@/components/platform/pills";
import { BusinessStatusForm, SubscriptionStatusForm } from "@/components/platform/forms";
import { CancelSubscriptionForm, IssueInvoiceForm } from "@/components/platform/billing-forms";
import { formatMoney } from "@/lib/saas/model";

export const metadata = { title: "İşletme · Platform · BoutiqueOS" };

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-4 py-2 text-sm">
      <dt className="text-text-muted">{label}</dt>
      <dd className="text-right text-text-primary">{children}</dd>
    </div>
  );
}

export default async function BusinessDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const biz = await getBusiness(id);
  if (!biz) notFound();

  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow={{ href: "/platform/isletmeler", label: "İşletmeler" }}
        title={biz.name}
        description={
          <>
            <span data-numeric>{biz.code}</span> · {biz.base_currency} · {biz.timezone ?? "saat dilimi ayarlanmamış"} · açılış {fmtDate(biz.created_at)}
          </>
        }
        actions={<BusinessPill status={biz.status} />}
      />

      <div className="grid grid-cols-1 gap-8 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <div className="space-y-8">
          <section className="space-y-2">
            <SectionHeader title="Sahipler" meta={`${biz.members} üye · ${biz.branches} şube`} />
            <dl className="divide-y divide-border border-y border-border">
              {biz.owners.map((o, i) => (
                <Row key={i} label={o.name ?? "—"}>{o.email ?? "—"}</Row>
              ))}
              {biz.application ? (
                <Row label="Başvuru">
                  <Link href={`/platform/basvurular/${biz.application.id}`} className="underline-offset-4 hover:underline">{fmtDate(biz.application.submitted_at)}</Link>{" "}
                  <ApplicationPill status={biz.application.status} />
                </Row>
              ) : (
                <Row label="Başvuru">Platform tarafından doğrudan açıldı (başvuru kaydı yok)</Row>
              )}
            </dl>
          </section>

          <section className="space-y-3">
            <SectionHeader title="Abonelikler" />
            {biz.subscriptions.length === 0 ? (
              <p className="text-sm text-text-muted">Bu işletmenin abonelik kaydı yok (platform öncesi kiracı).</p>
            ) : (
              <ul className="space-y-3">
                {biz.subscriptions.map((s) => (
                  <li key={s.id} className="space-y-3 rounded border border-border bg-surface p-4">
                    <div className="flex flex-wrap items-baseline justify-between gap-2">
                      <p className="text-sm font-medium text-text-primary">
                        {s.plan} <span className="text-text-muted" data-numeric>— {formatPlanPrice(s)}</span>
                      </p>
                      <SubscriptionPill status={s.status} />
                    </div>
                    <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-xs text-text-muted sm:grid-cols-4">
                      <div><dt>Başlangıç</dt><dd className="text-text-secondary" data-numeric>{fmtDate(s.starts_at)}</dd></div>
                      <div><dt>Bitiş</dt><dd className="text-text-secondary" data-numeric>{fmtDate(s.ends_at)}{s.lapsed ? " · dönem bitti" : ""}</dd></div>
                      <div><dt>Yenileme</dt><dd className="text-text-secondary" data-numeric>{s.cancel_at_period_end ? "dönem sonunda iptal" : fmtDate(s.renews_at)}</dd></div>
                      <div><dt>Fatura</dt><dd className="text-text-secondary" data-numeric>{s.invoice_count}</dd></div>
                    </dl>
                    {s.latest_invoice ? (
                      <p className="flex flex-wrap items-center gap-2 text-xs text-text-secondary">
                        <Link href={`/platform/faturalar/${s.latest_invoice.id}`} className="underline-offset-4 hover:underline" data-numeric>{s.latest_invoice.invoice_number}</Link>
                        <span data-numeric>{formatMoney(s.latest_invoice.total, s.latest_invoice.currency)}</span>
                        <InvoicePill status={s.latest_invoice.status} overdue={s.latest_invoice.overdue} />
                        {s.latest_invoice.status === "open" ? <span className="text-text-muted">vade {fmtDate(s.latest_invoice.due_at)}</span> : null}
                      </p>
                    ) : (
                      <p className="text-xs text-text-muted">Henüz fatura kesilmedi. Abonelik, ilk faturası ödendiğinde etkinleşir.</p>
                    )}
                    {s.note ? <p className="text-xs text-text-muted">{s.note}</p> : null}
                    {s.status === "cancelled" || s.status === "expired" ? (
                      <p className="text-xs text-text-muted">Bu abonelik kapanmış; yeni dönem için yeni bir abonelik açılır.</p>
                    ) : (
                      <div className="space-y-2 border-t border-border pt-3">
                        <IssueInvoiceForm
                          subscriptionId={s.id}
                          kind={s.invoice_count === 0 ? "first" : "renewal"}
                          disabled={Boolean(s.latest_invoice && s.latest_invoice.status === "open") || s.cancel_at_period_end}
                          disabledReason={s.cancel_at_period_end ? "Dönem sonunda iptal planlı; yenileme faturası kesilmez." : "Açık bir fatura var; önce ödemesini kaydedin ya da iptal edin."}
                        />
                        <SubscriptionStatusForm key={s.status} subscriptionId={s.id} current={s.status} />
                        <CancelSubscriptionForm key={`c-${s.cancel_at_period_end}`} subscriptionId={s.id} scheduled={s.cancel_at_period_end} />
                      </div>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </section>

          <section className="space-y-3">
            <SectionHeader title="Denetim kaydı" meta={biz.audit.length > 0 ? `son ${biz.audit.length}` : undefined} />
            {biz.audit.length === 0 ? (
              <p className="text-sm text-text-muted">Platform işlemi yok.</p>
            ) : (
              <TableShell minWidth="36rem">
                <THead>
                  <TH>Zaman</TH>
                  <TH>İşlem</TH>
                  <TH>Yetkili</TH>
                  <TH>Ayrıntı</TH>
                </THead>
                <TBody>
                  {biz.audit.map((a, i) => (
                    <TR key={i}>
                      <TD nowrap muted>{fmtDateTime(a.at)}</TD>
                      <TD>{AUDIT_ACTION_LABELS[a.action] ?? a.action}</TD>
                      <TD muted>{a.admin ?? "—"}</TD>
                      <TD muted>
                        <span className="text-xs">
                          {AUDIT_PAYLOAD_KEYS.filter((k) => a.payload[k] !== null && a.payload[k] !== undefined)
                            .map((k) => `${k}: ${String(a.payload[k])}`)
                            .join(" · ") || "—"}
                        </span>
                      </TD>
                    </TR>
                  ))}
                </TBody>
              </TableShell>
            )}
          </section>
        </div>

        <aside className="space-y-4">
          <BusinessStatusForm key={biz.status} businessId={biz.id} current={biz.status} />
        </aside>
      </div>
    </div>
  );
}
