import { redirect } from "next/navigation";
import { getReceivingReport, reportPageState } from "@/lib/reports/queries";
import { ReportPage, PeriodBar } from "@/components/reports/report-shell";
import { Kpi, KpiStrip } from "@/components/reports/kpi";
import { fmtInt, fmtMoney, fmtMoneyShort } from "@/components/reports/format";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";

export const metadata = { title: "Mal kabul raporu · BoutiqueOS" };

type Params = { d?: string; from?: string; to?: string; sube?: string };

/** Receiving / purchasing (manager+): posted documents by posting day; drafts never enter, reversals are shown apart. */
export default async function ReceivingReportPage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const state = await reportPageState(params);
  if (!state.caps.canViewFinancial) redirect("/app/raporlar");
  const report = await getReceivingReport(state.period, state.branchId);
  const t = report.totals;

  return (
    <ReportPage title="Mal kabul" description="Yalnız işlenmiş (POST edilmiş) belgeler, işlem gününe göre. Taslaklar hiçbir toplama girmez; ters kayıtlar ayrı gösterilir." current="/app/raporlar/mal-kabul" caps={state.caps} query={state.query}>
      <PeriodBar basePath="/app/raporlar/mal-kabul" period={state.period} branches={state.branches} branchId={state.branchId} />

      {t.receipts === 0 && report.reversals.count === 0 ? (
        <EmptyState compact title="Bu dönemde işlenmiş mal kabul yok." />
      ) : (
        <>
          <KpiStrip>
            <Kpi label="Belge" value={fmtInt(t.receipts)} hint={t.reversed_receipts > 0 ? `${fmtInt(t.reversed_receipts)} tanesi sonradan ters kaydedildi` : undefined} />
            <Kpi label="Alınan adet" value={fmtInt(t.units)} />
            <Kpi label="Alış değeri" value={fmtMoneyShort(t.purchase_value_base)} hint="fatura, TRY karşılığı" />
            <Kpi label="Ek masraf" value={fmtMoneyShort(t.charges_base)} hint="maliyete dahil edilen" />
            <Kpi label="İniş maliyeti" value={fmtMoneyShort(t.landed_total_base)} hint="alış + masraf payı" />
            <Kpi label="Oluşan borç" value={fmtMoneyShort(t.liability_base)} hint="tedarikçi hesabına yazılan" />
            {report.reversals.count > 0 ? <Kpi label="Ters kayıt" value={fmtInt(report.reversals.count)} hint={`${fmtMoney(report.reversals.value_removed_base)} stoktan düşüldü`} /> : null}
          </KpiStrip>

          <section className="space-y-3">
            <SectionHeader title="Tedarikçiye göre" meta={`${report.by_supplier.length} tedarikçi`} />
            {report.by_supplier.length === 0 ? (
              <EmptyState compact title="Belge yok." />
            ) : (
              <TableShell minWidth="36rem">
                <THead>
                  <TH>Tedarikçi</TH>
                  <TH align="right">Belge</TH>
                  <TH align="right">Adet</TH>
                  <TH align="right">Alış değeri</TH>
                  <TH align="right">İniş maliyeti</TH>
                  <TH align="right">Borç</TH>
                </THead>
                <TBody>
                  {report.by_supplier.map((s) => (
                    <TR key={s.supplier_id}>
                      <TD>{s.supplier}</TD>
                      <TD align="right" numeric muted>{fmtInt(s.receipts)}</TD>
                      <TD align="right" numeric>{fmtInt(s.units)}</TD>
                      <TD align="right" numeric>{fmtMoney(s.purchase_value_base)}</TD>
                      <TD align="right" numeric>{fmtMoney(s.landed_total_base)}</TD>
                      <TD align="right" numeric muted>{fmtMoney(s.liability_base)}</TD>
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
