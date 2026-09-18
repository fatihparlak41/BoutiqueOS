import Link from "next/link";
import { notFound } from "next/navigation";
import { getBusiness } from "@/lib/platform/queries";
import { AUDIT_ACTION_LABELS } from "@/lib/platform/model";
import { formatPlanPrice } from "@/lib/saas/model";
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";
import { BusinessPill, SubscriptionPill, ApplicationPill, fmtDate, fmtDateTime } from "@/components/platform/pills";
import { BusinessStatusForm, SubscriptionStatusForm } from "@/components/platform/forms";

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
                      <div><dt>Bitiş</dt><dd className="text-text-secondary" data-numeric>{fmtDate(s.ends_at)}</dd></div>
                      <div><dt>Etkinleştirme</dt><dd className="text-text-secondary" data-numeric>{fmtDate(s.activated_at)}</dd></div>
                      <div><dt>Kaynak</dt><dd className="text-text-secondary">{s.source}</dd></div>
                    </dl>
                    {s.note ? <p className="text-xs text-text-muted">{s.note}</p> : null}
                    <SubscriptionStatusForm subscriptionId={s.id} current={s.status} />
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
                          {Object.entries(a.payload)
                            .filter(([k, v]) => v !== null && v !== undefined && ["from", "to", "reason", "note", "plan", "code"].includes(k))
                            .map(([k, v]) => `${k}: ${String(v)}`)
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
          <BusinessStatusForm businessId={biz.id} current={biz.status} />
        </aside>
      </div>
    </div>
  );
}
