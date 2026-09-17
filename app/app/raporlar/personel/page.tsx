import { redirect } from "next/navigation";
import { getStaffReport, reportPageState } from "@/lib/reports/queries";
import { ReportPage, PeriodBar, ScopeNote } from "@/components/reports/report-shell";
import { RankedTable, MetricDefinitions } from "@/components/reports/tables";
import { fmtInt, fmtMoney } from "@/components/reports/format";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";

export const metadata = { title: "Personel raporu · BoutiqueOS" };

type Params = { d?: string; from?: string; to?: string; sube?: string };

/** Staff: salesperson attribution (who gets the sale) apart from the cashier (who rang it up). No commissions here. */
export default async function StaffReportPage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const state = await reportPageState(params);
  if (!state.caps.canViewSales) redirect("/app/raporlar/stok");
  const report = await getStaffReport(state.period, state.branchId);
  const fin = report.financial;

  return (
    <ReportPage title="Personel" description="Satıcı: satışın atandığı kişi. Kasiyer: satışı kasada tamamlayan kişi. İkisi ayrı tutulur; prim hesabı yoktur." current="/app/raporlar/personel" caps={state.caps} query={state.query}>
      <PeriodBar basePath="/app/raporlar/personel" period={state.period} branches={state.branches} branchId={state.branchId} />
      <ScopeNote scope={report.scope} />

      <section className="space-y-3">
        <SectionHeader title="Satıcıya göre" meta={`${report.salespeople.length} kişi`} />
        <RankedTable
          rows={report.salespeople}
          financial={fin}
          header="Satıcı"
          title={(r) => ("name" in r ? String(r.name) : "—")}
          sub={(r) => ("avg_basket" in r && r.avg_basket !== null && r.avg_basket !== undefined ? `ortalama sepet ${fmtMoney(Number(r.avg_basket))}` : undefined)}
          emptyText="Bu dönemde atanmış satış yok."
        />
      </section>

      <section className="space-y-3">
        <SectionHeader title="Kasiyere göre" meta="kasada tamamlanan işlem" />
        {report.cashiers.length === 0 ? (
          <EmptyState compact title="Bu dönemde kasa işlemi yok." />
        ) : (
          <TableShell minWidth="24rem">
            <THead>
              <TH>Kasiyer</TH>
              <TH align="right">İşlem</TH>
              <TH align="right">Net satış</TH>
            </THead>
            <TBody>
              {report.cashiers.map((c) => (
                <TR key={c.user_id}>
                  <TD>{c.name}</TD>
                  <TD align="right" numeric>{fmtInt(c.transactions)}</TD>
                  <TD align="right" numeric>{fmtMoney(c.net_sales)}</TD>
                </TR>
              ))}
            </TBody>
          </TableShell>
        )}
      </section>

      <MetricDefinitions financial={fin} />
    </ReportPage>
  );
}
