import Link from "next/link";
import { listBusinesses } from "@/lib/platform/queries";
import { pageOffset } from "@/lib/platform/model";
import { BUSINESS_STATUS_LABELS, type BusinessStatus } from "@/lib/saas/model";
import { PageHeader } from "@/components/ui/page-header";
import { FilterBar } from "@/components/ui/filter-bar";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { EmptyState } from "@/components/ui/empty-state";
import { BusinessPill, SubscriptionPill, fmtDate } from "@/components/platform/pills";
import { Pager } from "@/components/platform/pager";

export const metadata = { title: "İşletmeler · Platform · BoutiqueOS" };

const STATUSES: BusinessStatus[] = ["active", "suspended", "cancelled"];

export default async function BusinessesPage({ searchParams }: { searchParams: Promise<{ durum?: string; q?: string; sayfa?: string }> }) {
  const { durum, q, sayfa } = await searchParams;
  const status = STATUSES.includes(durum as BusinessStatus) ? (durum as BusinessStatus) : null;
  const query = (q ?? "").trim().slice(0, 80) || null;
  const offset = pageOffset(sayfa);
  const list = await listBusinesses(status, query, offset);
  const href = (page: number) =>
    `/platform/isletmeler?${new URLSearchParams({ ...(status ? { durum: status } : {}), ...(query ? { q: query } : {}), sayfa: String(page) }).toString()}`;

  return (
    <div className="space-y-6">
      <PageHeader title="İşletmeler" description="Tüm kiracılar. Durum ve abonelik platformundur; işletmenin kendi verisi burada görünmez." />
      <FilterBar clearHref="/platform/isletmeler" hasFilter={Boolean(status || query)} columns={4}>
        <div className="space-y-1.5">
          <Label htmlFor="q">Ad ya da kod</Label>
          <Input id="q" name="q" defaultValue={query ?? ""} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="durum">Durum</Label>
          <Select id="durum" name="durum" defaultValue={status ?? ""}>
            <option value="">Tümü</option>
            {STATUSES.map((s) => (
              <option key={s} value={s}>{BUSINESS_STATUS_LABELS[s]}</option>
            ))}
          </Select>
        </div>
      </FilterBar>
      {list.rows.length === 0 ? (
        <EmptyState title="İşletme yok" description="Bu filtreyle eşleşen işletme bulunmuyor." />
      ) : (
        <TableShell minWidth="48rem" footer={`${list.total} işletme`}>
          <THead>
            <TH>İşletme</TH>
            <TH>Durum</TH>
            <TH align="right">Sahip</TH>
            <TH align="right">Üye</TH>
            <TH align="right">Şube</TH>
            <TH>Abonelik</TH>
            <TH>Açılış</TH>
          </THead>
          <TBody>
            {list.rows.map((b) => (
              <TR key={b.id}>
                <TD>
                  <CellTitle sub={`${b.code} · ${b.base_currency}`} subNumeric>
                    <Link href={`/platform/isletmeler/${b.id}`} className="hover:underline">{b.name}</Link>
                  </CellTitle>
                </TD>
                <TD><BusinessPill status={b.status} /></TD>
                <TD align="right" numeric>{b.owners}</TD>
                <TD align="right" numeric>{b.members}</TD>
                <TD align="right" numeric>{b.branches}</TD>
                <TD>
                  {b.subscription ? (
                    <span className="flex items-center gap-2"><SubscriptionPill status={b.subscription.status} /><span className="text-xs text-text-muted">{b.subscription.plan}</span></span>
                  ) : (
                    <span className="text-xs text-text-muted">—</span>
                  )}
                </TD>
                <TD nowrap muted>{fmtDate(b.created_at)}</TD>
              </TR>
            ))}
          </TBody>
        </TableShell>
      )}
      <Pager total={list.total} offset={list.offset} href={href} />
    </div>
  );
}
