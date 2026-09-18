import Link from "next/link";
import { listApplications } from "@/lib/platform/queries";
import { pageOffset } from "@/lib/platform/model";
import { APPLICATION_STATUS_LABELS, type ApplicationStatus } from "@/lib/saas/model";
import { PageHeader } from "@/components/ui/page-header";
import { FilterBar } from "@/components/ui/filter-bar";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { EmptyState } from "@/components/ui/empty-state";
import { ApplicationPill, fmtDateTime } from "@/components/platform/pills";
import { Pager } from "@/components/platform/pager";

export const metadata = { title: "Başvurular · Platform · BoutiqueOS" };

const STATUSES: ApplicationStatus[] = ["pending", "approved", "rejected", "withdrawn"];

export default async function ApplicationsPage({ searchParams }: { searchParams: Promise<{ durum?: string; sayfa?: string }> }) {
  const { durum, sayfa } = await searchParams;
  const status = STATUSES.includes(durum as ApplicationStatus) ? (durum as ApplicationStatus) : null;
  const offset = pageOffset(sayfa);
  const list = await listApplications(status, offset);
  const href = (page: number) => `/platform/basvurular?${new URLSearchParams({ ...(status ? { durum: status } : {}), sayfa: String(page) }).toString()}`;

  return (
    <div className="space-y-6">
      <PageHeader title="Başvurular" description="Her başvuru bir kişi ve bir işletme adıdır; onay tek işlemde işletmeyi ilk sahibiyle açar." />
      <FilterBar clearHref="/platform/basvurular" hasFilter={Boolean(status)} columns={4}>
        <div className="space-y-1.5">
          <Label htmlFor="durum">Durum</Label>
          <Select id="durum" name="durum" defaultValue={status ?? ""}>
            <option value="">Tümü</option>
            {STATUSES.map((s) => (
              <option key={s} value={s}>{APPLICATION_STATUS_LABELS[s]}</option>
            ))}
          </Select>
        </div>
      </FilterBar>
      {list.rows.length === 0 ? (
        <EmptyState title="Başvuru yok" description={status ? "Bu durumda başvuru bulunmuyor." : "Henüz hiç başvuru alınmadı."} />
      ) : (
        <TableShell minWidth="44rem" footer={`${list.total} başvuru`}>
          <THead>
            <TH>İşletme</TH>
            <TH>Başvuran</TH>
            <TH>Plan</TH>
            <TH>Gönderildi</TH>
            <TH>Durum</TH>
          </THead>
          <TBody>
            {list.rows.map((a) => (
              <TR key={a.id}>
                <TD>
                  <CellTitle sub={`${a.country} · ${a.currency}`}>
                    <Link href={`/platform/basvurular/${a.id}`} className="hover:underline">{a.business_name}</Link>
                  </CellTitle>
                </TD>
                <TD muted>
                  {a.applicant.name ?? "—"}
                  <br />
                  <span className="text-xs">{a.applicant.email ?? "—"}{a.applicant.confirmed ? "" : " · doğrulanmadı"}</span>
                </TD>
                <TD muted>{a.plan?.name ?? "—"}</TD>
                <TD nowrap muted>{fmtDateTime(a.submitted_at)}</TD>
                <TD><ApplicationPill status={a.status} /></TD>
              </TR>
            ))}
          </TBody>
        </TableShell>
      )}
      <Pager total={list.total} offset={list.offset} href={href} />
    </div>
  );
}
