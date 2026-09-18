import Link from "next/link";
import { listApplications, listBusinesses, listPlans } from "@/lib/platform/queries";
import { PageHeader } from "@/components/ui/page-header";
import { Stat, StatGrid } from "@/components/ui/stat";
import { SectionHeader } from "@/components/ui/section-header";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { EmptyState } from "@/components/ui/empty-state";
import { ApplicationPill, fmtDateTime } from "@/components/platform/pills";

export const metadata = { title: "Platform · BoutiqueOS" };

/** The operator's desk: what is waiting, how many tenants, which plans are on offer. */
export default async function PlatformHome() {
  const [pending, active, suspended, plans] = await Promise.all([
    listApplications("pending", 0),
    listBusinesses("active", null, 0),
    listBusinesses("suspended", null, 0),
    listPlans(),
  ]);

  return (
    <div className="space-y-8">
      <PageHeader title="Genel bakış" description="Başvurular, işletmeler ve plan kataloğu. Her karar denetim kaydına yazılır." />
      <StatGrid>
        <Stat label="Bekleyen başvuru" value={pending.total} href="/platform/basvurular?durum=pending" />
        <Stat label="Aktif işletme" value={active.total} href="/platform/isletmeler?durum=active" />
        <Stat label="Askıdaki işletme" value={suspended.total} href="/platform/isletmeler?durum=suspended" />
        <Stat label="Sunulan plan" value={plans.filter((p) => p.is_active).length} hint={`${plans.length} tanımlı`} href="/platform/planlar" />
      </StatGrid>

      <section className="space-y-3">
        <SectionHeader title="İnceleme bekleyenler" meta={pending.total > 0 ? `${pending.total}` : undefined} action={<Link href="/platform/basvurular" className="underline-offset-4 hover:underline">Tümü</Link>} />
        {pending.rows.length === 0 ? (
          <EmptyState compact title="Bekleyen başvuru yok" description="Yeni başvurular burada listelenir." />
        ) : (
          <TableShell minWidth="40rem">
            <THead>
              <TH>İşletme</TH>
              <TH>Başvuran</TH>
              <TH>Plan</TH>
              <TH>Tarih</TH>
              <TH>Durum</TH>
            </THead>
            <TBody>
              {pending.rows.slice(0, 10).map((a) => (
                <TR key={a.id}>
                  <TD>
                    <CellTitle sub={`${a.country} · ${a.currency}`}>
                      <Link href={`/platform/basvurular/${a.id}`} className="hover:underline">{a.business_name}</Link>
                    </CellTitle>
                  </TD>
                  <TD muted>{a.applicant.name ?? "—"}<br /><span className="text-xs">{a.applicant.email ?? "—"}</span></TD>
                  <TD muted>{a.plan?.name ?? "—"}</TD>
                  <TD nowrap muted>{fmtDateTime(a.submitted_at)}</TD>
                  <TD><ApplicationPill status={a.status} /></TD>
                </TR>
              ))}
            </TBody>
          </TableShell>
        )}
      </section>
    </div>
  );
}
