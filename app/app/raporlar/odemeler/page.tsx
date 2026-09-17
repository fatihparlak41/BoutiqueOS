import { redirect } from "next/navigation";
import { getPaymentsReport, reportPageState } from "@/lib/reports/queries";
import { DRAWER_MOVEMENT_LABELS, PAYMENT_METHOD_LABELS } from "@/lib/reports/model";
import { ReportPage, PeriodBar } from "@/components/reports/report-shell";
import { Kpi, KpiStrip } from "@/components/reports/kpi";
import { fmtInt, fmtMoney, fmtMoneyShort } from "@/components/reports/format";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";

export const metadata = { title: "Ödeme raporu · BoutiqueOS" };

type Params = { d?: string; from?: string; to?: string; sube?: string };

/**
 * Payments (manager+). Three different things are kept apart on purpose:
 *  - tender: what customers handed over, by method (sale_payments);
 *  - money movement: tender − change − refunds = what actually stayed;
 *  - the drawer: physical cash movements of the register sessions.
 * Net sales is revenue and equals tender − change + exchange credit; it is not cash.
 */
export default async function PaymentsReportPage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const state = await reportPageState(params);
  if (!state.caps.canViewFinancial) redirect("/app/raporlar");
  const report = await getPaymentsReport(state.period, state.branchId);
  const s = report.sales;
  const empty = s.transactions === 0 && report.refund_total === 0 && report.drawer.length === 0;

  return (
    <ReportPage title="Ödemeler" description="Tahsilat yöntemine göre; iadeler ve para üstü düşülmüş net para hareketi; kasa çekmecesi ayrı." current="/app/raporlar/odemeler" caps={state.caps} query={state.query}>
      <PeriodBar basePath="/app/raporlar/odemeler" period={state.period} branches={state.branches} branchId={state.branchId} />

      {empty ? (
        <EmptyState compact title="Bu dönemde tahsilat, iade ya da kasa hareketi yok." />
      ) : (
        <>
          <KpiStrip>
            <Kpi label="Tahsilat" value={fmtMoneyShort(s.tendered_base)} hint={`${fmtInt(s.transactions)} işlem`} />
            <Kpi label="Para üstü" value={fmtMoneyShort(s.change_given)} />
            <Kpi label="İade edilen" value={fmtMoneyShort(report.refund_total)} />
            <Kpi label="Net para hareketi" value={fmtMoneyShort(report.net_payment_movement)} hint="tahsilat − para üstü − iade" />
            <Kpi label="Net satış" value={fmtMoneyShort(s.net_sales)} hint="tahsilat − para üstü + değişim kredisi" />
            <Kpi label="Değişim kredisi" value={fmtMoneyShort(s.credit_applied)} hint="geri gelen ürünle ödenen" />
            <Kpi label="Parçalı ödeme" value={fmtInt(s.split_payment_sales)} hint="birden çok ödeme satırı" />
          </KpiStrip>

          <section className="space-y-3">
            <SectionHeader title="Yönteme göre tahsilat" />
            {report.by_method.length === 0 ? (
              <EmptyState compact title="Tahsilat yok." />
            ) : (
              <TableShell minWidth="30rem">
                <THead>
                  <TH>Yöntem</TH>
                  <TH align="right">Ödeme</TH>
                  <TH align="right">Satış</TH>
                  <TH align="right">Tutar</TH>
                  <TH align="right">TRY karşılığı</TH>
                </THead>
                <TBody>
                  {report.by_method.map((m) => (
                    <TR key={`${m.method}-${m.currency}`}>
                      <TD>{PAYMENT_METHOD_LABELS[m.method] ?? m.method}{m.currency !== "TRY" ? ` (${m.currency})` : ""}</TD>
                      <TD align="right" numeric muted>{fmtInt(m.payments)}</TD>
                      <TD align="right" numeric muted>{fmtInt(m.sales)}</TD>
                      <TD align="right" numeric>{m.currency === "TRY" ? fmtMoney(m.amount) : `${m.amount.toLocaleString("tr-TR", { minimumFractionDigits: 2 })} ${m.currency}`}</TD>
                      <TD align="right" numeric>{fmtMoney(m.amount_base)}</TD>
                    </TR>
                  ))}
                </TBody>
              </TableShell>
            )}
          </section>

          <div className="grid gap-6 lg:grid-cols-2">
            <section className="space-y-3">
              <SectionHeader title="İadeler (para çıkışı)" />
              {report.refunds.length === 0 ? (
                <EmptyState compact title="Para iadesi yok." />
              ) : (
                <TableShell minWidth="20rem">
                  <THead>
                    <TH>Yöntem</TH>
                    <TH align="right">Belge</TH>
                    <TH align="right">Tutar</TH>
                  </THead>
                  <TBody>
                    {report.refunds.map((r) => (
                      <TR key={r.method ?? "-"}>
                        <TD>{r.method ? PAYMENT_METHOD_LABELS[r.method] ?? r.method : "—"}</TD>
                        <TD align="right" numeric muted>{fmtInt(r.returns)}</TD>
                        <TD align="right" numeric>{fmtMoney(r.amount_base)}</TD>
                      </TR>
                    ))}
                  </TBody>
                </TableShell>
              )}
            </section>
            <section className="space-y-3">
              <SectionHeader title="Kasa çekmecesi" meta="fiziksel nakit hareketi" />
              {report.drawer.length === 0 ? (
                <EmptyState compact title="Kasa hareketi yok." />
              ) : (
                <TableShell minWidth="20rem">
                  <THead>
                    <TH>Hareket</TH>
                    <TH align="right">Adet</TH>
                    <TH align="right">Tutar</TH>
                  </THead>
                  <TBody>
                    {report.drawer.map((d) => (
                      <TR key={`${d.movement_type}-${d.currency}`}>
                        <TD>{DRAWER_MOVEMENT_LABELS[d.movement_type] ?? d.movement_type}{d.currency !== "TRY" ? ` (${d.currency})` : ""}</TD>
                        <TD align="right" numeric muted>{fmtInt(d.count)}</TD>
                        <TD align="right" numeric>{fmtMoney(d.amount_base)}</TD>
                      </TR>
                    ))}
                  </TBody>
                </TableShell>
              )}
              <p className="text-2xs text-text-muted">Kart tahsilatı çekmeceye girmez; kasa mutabakatı oturum kapanışında yapılır.</p>
            </section>
          </div>
        </>
      )}
    </ReportPage>
  );
}
