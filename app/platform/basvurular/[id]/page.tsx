import Link from "next/link";
import { notFound } from "next/navigation";
import { getApplication } from "@/lib/platform/queries";
import { BUSINESS_TYPE_OPTIONS, COUNTRY_OPTIONS, formatPlanPrice } from "@/lib/saas/model";
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { ApplicationPill, BusinessPill, SubscriptionPill, fmtDateTime } from "@/components/platform/pills";
import { ApproveApplicationForm, RejectApplicationForm } from "@/components/platform/forms";

export const metadata = { title: "Başvuru · Platform · BoutiqueOS" };

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-4 py-2 text-sm">
      <dt className="text-text-muted">{label}</dt>
      <dd className="text-right text-text-primary">{children}</dd>
    </div>
  );
}

export default async function ApplicationDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const app = await getApplication(id);
  if (!app) notFound();

  const country = COUNTRY_OPTIONS.find((o) => o.value === app.country)?.label ?? app.country;
  const type = BUSINESS_TYPE_OPTIONS.find((o) => o.value === app.business_type)?.label ?? app.business_type ?? "—";
  const open = app.status === "pending";

  return (
    <div className="space-y-8">
      <PageHeader
        eyebrow={{ href: "/platform/basvurular", label: "Başvurular" }}
        title={app.business_name}
        description={`Gönderildi: ${fmtDateTime(app.submitted_at)}`}
        actions={<ApplicationPill status={app.status} />}
      />

      <div className="grid grid-cols-1 gap-8 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <div className="space-y-8">
          <section className="space-y-2">
            <SectionHeader title="Başvuran" />
            <dl className="divide-y divide-border border-y border-border">
              <Row label="Ad Soyad">{app.applicant.name ?? "—"}</Row>
              <Row label="E-posta">{app.applicant.email ?? "—"}</Row>
              <Row label="E-posta doğrulaması">{app.applicant.confirmed_at ? fmtDateTime(app.applicant.confirmed_at) : "Doğrulanmadı — onay bunu bekler"}</Row>
              <Row label="Başka işletmelerde üyelik">{app.applicant.other_memberships}</Row>
            </dl>
          </section>

          <section className="space-y-2">
            <SectionHeader title="İşletme" />
            <dl className="divide-y divide-border border-y border-border">
              <Row label="Ülke / bölge">{country}</Row>
              <Row label="Ana para birimi">{app.currency}</Row>
              <Row label="Tür">{type}</Row>
              <Row label="Telefon">{app.phone ?? "—"}</Row>
              <Row label="İlk şube">{app.branch_name}</Row>
              <Row label="Plan">{app.plan ? `${app.plan.name} — ${formatPlanPrice(app.plan)}` : "Seçilmedi (onayda sunulan ilk plan yazılır)"}</Row>
            </dl>
          </section>

          {app.status !== "pending" ? (
            <section className="space-y-2">
              <SectionHeader title="Karar" />
              <dl className="divide-y divide-border border-y border-border">
                <Row label="İnceleyen">{app.reviewer ?? "—"}</Row>
                <Row label="Tarih">{fmtDateTime(app.reviewed_at)}</Row>
                <Row label="Not">{app.review_note ?? "—"}</Row>
                {app.business ? (
                  <Row label="İşletme">
                    <Link href={`/platform/isletmeler/${app.business.id}`} className="underline-offset-4 hover:underline">{app.business.name}</Link>{" "}
                    <span className="text-text-muted" data-numeric>{app.business.code}</span> <BusinessPill status={app.business.status} />
                  </Row>
                ) : null}
                {app.subscription ? (
                  <Row label="Abonelik"><SubscriptionPill status={app.subscription.status} /></Row>
                ) : null}
              </dl>
            </section>
          ) : null}
        </div>

        <aside className="space-y-4">
          {open ? (
            <>
              <ApproveApplicationForm applicationId={app.id} disabled={!app.applicant.confirmed_at} />
              <RejectApplicationForm applicationId={app.id} />
            </>
          ) : (
            <p className="rounded border border-border bg-surface p-4 text-sm text-text-muted">Bu başvuru kapanmış; yeni bir karar alınamaz.</p>
          )}
        </aside>
      </div>
    </div>
  );
}
