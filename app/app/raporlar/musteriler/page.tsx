import Link from "next/link";
import { redirect } from "next/navigation";
import { getCustomersReport, reportPageState } from "@/lib/reports/queries";
import { ReportPage, PeriodBar, ScopeNote } from "@/components/reports/report-shell";
import { Kpi, KpiStrip } from "@/components/reports/kpi";
import { fmtInt, fmtMoney, fmtMoneyShort, fmtPct } from "@/components/reports/format";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";
import { formatDate } from "@/lib/receiving/format";

export const metadata = { title: "Müşteri raporu · BoutiqueOS" };

type Params = { d?: string; from?: string; to?: string; sube?: string };

/** Customers, V1: who bought, how often, how much — derived from sales, no profiling. The top list carries the name only. */
export default async function CustomersReportPage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const state = await reportPageState(params);
  if (!state.caps.canViewSales) redirect("/app/raporlar/stok");
  const report = await getCustomersReport(state.period, state.branchId);
  const t = report.totals;

  return (
    <ReportPage title="Müşteriler" description="Tamamlanmış satışlardan türetilir: kayıtlı müşteriyle ve anonim yapılan satışlar, tekrar eden müşteriler." current="/app/raporlar/musteriler" caps={state.caps} query={state.query}>
      <PeriodBar basePath="/app/raporlar/musteriler" period={state.period} branches={state.branches} branchId={state.branchId} />
      <ScopeNote scope={report.scope} />

      {t.sales === 0 ? (
        <EmptyState compact title="Bu dönemde satış yok." />
      ) : (
        <>
          <KpiStrip>
            <Kpi label="Kayıtlı müşteriyle satış" value={fmtInt(t.identified_sales)} hint={`${fmtPct((t.identified_sales / t.sales) * 100)} · ${fmtMoneyShort(t.identified_net_sales)}`} />
            <Kpi label="Anonim satış" value={fmtInt(t.walk_in_sales)} hint={fmtMoneyShort(t.walk_in_net_sales)} />
            <Kpi label="Alışveriş yapan müşteri" value={fmtInt(t.customers_with_sale)} />
            <Kpi label="Tekrar eden" value={fmtInt(t.repeat_customers)} hint="dönemde 2+ satış" />
            <Kpi label="Yeni kayıt" value={fmtInt(t.new_customers)} hint="dönemde oluşturulan müşteri" />
          </KpiStrip>

          <section className="space-y-3">
            <SectionHeader title="En çok alışveriş yapanlar" meta="net harcamaya göre, ilk 10" />
            {report.top.length === 0 ? (
              <EmptyState compact title="Kayıtlı müşteriyle satış yok." />
            ) : (
              <TableShell minWidth="32rem">
                <THead>
                  <TH>Müşteri</TH>
                  <TH align="right">Satış</TH>
                  <TH align="right">Adet</TH>
                  <TH align="right">Net harcama</TH>
                  <TH align="right">İade</TH>
                  <TH align="right">Son alışveriş</TH>
                </THead>
                <TBody>
                  {report.top.map((c) => (
                    <TR key={c.customer_id}>
                      <TD>
                        <Link href={`/app/musteriler/${c.customer_id}`} className="font-medium hover:underline">{c.name ?? "—"}</Link>
                      </TD>
                      <TD align="right" numeric>{fmtInt(c.sales)}</TD>
                      <TD align="right" numeric muted>{fmtInt(c.units)}</TD>
                      <TD align="right" numeric>{fmtMoney(c.net_spend)}</TD>
                      <TD align="right" numeric muted>{c.returns_value > 0 ? fmtMoney(c.returns_value) : "—"}</TD>
                      <TD align="right" nowrap muted>{c.last_purchase_at ? formatDate(c.last_purchase_at) : "—"}</TD>
                    </TR>
                  ))}
                </TBody>
              </TableShell>
            )}
          </section>
        </>
      )}
    </ReportPage>
  );
}
