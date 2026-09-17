import { redirect } from "next/navigation";
import { getReturnsReport, reportPageState } from "@/lib/reports/queries";
import { DISPOSITION_LABELS, RETURN_TYPE_LABELS } from "@/lib/reports/model";
import { ReportPage, PeriodBar, ScopeNote } from "@/components/reports/report-shell";
import { Kpi, KpiStrip } from "@/components/reports/kpi";
import { fmtInt, fmtMoney, fmtMoneyShort, fmtPct } from "@/components/reports/format";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";

export const metadata = { title: "İade raporu · BoutiqueOS" };

type Params = { d?: string; from?: string; to?: string; sube?: string };

/** Returns and exchanges: counts, reasons, the condition goods came back in, and return rates that say when the sample is too small. */
export default async function ReturnsReportPage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const state = await reportPageState(params);
  if (!state.caps.canViewSales) redirect("/app/raporlar/stok");
  const report = await getReturnsReport(state.period, state.branchId);
  const t = report.totals;
  const fin = report.financial;

  return (
    <ReportPage title="İadeler" description="Dönemde işlenen iade ve değişimler, kendi tarihlerine göre. Oranlar aynı dönemde satılan adede bölünür; 10 adedin altındaki örneklem eğilim sayılmaz." current="/app/raporlar/iadeler" caps={state.caps} query={state.query}>
      <PeriodBar basePath="/app/raporlar/iadeler" period={state.period} branches={state.branches} branchId={state.branchId} />
      <ScopeNote scope={report.scope} />

      {t.returns === 0 ? (
        <EmptyState compact title="Bu dönemde iade ya da değişim yok." />
      ) : (
        <>
          <KpiStrip>
            <Kpi label="İade belgesi" value={fmtInt(t.returns)} hint={`${fmtInt(t.exchanges)} değişim · ${fmtInt(t.refunds)} para iadesi`} />
            <Kpi label="Geri gelen adet" value={fmtInt(t.returned_units)} />
            <Kpi label="İade değeri" value={fmtMoneyShort(t.returns_value)} hint="satış anındaki fiyatla" />
            <Kpi label="Ödenen para" value={fmtMoneyShort(t.refund_amount)} hint="nakit / kart iadesi" />
            {fin ? <Kpi label="Geri gelen maliyet" value={fmtMoneyShort(t.returned_cogs)} hint="tarihsel, havuza döner" /> : null}
          </KpiStrip>

          <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
            <section className="space-y-3">
              <SectionHeader title="Nedene göre" />
              <ul className="divide-y divide-border rounded border border-border text-sm">
                {report.by_reason.map((r) => (
                  <li key={r.code ?? "-"} className="flex items-baseline justify-between gap-3 px-4 py-2.5">
                    <span className="text-text-primary">{r.label}</span>
                    <span className="text-xs text-text-muted" data-numeric>{fmtInt(r.units)} adet · {fmtMoney(r.value)}</span>
                  </li>
                ))}
              </ul>
            </section>
            <section className="space-y-3">
              <SectionHeader title="Geldiği durum" />
              <ul className="divide-y divide-border rounded border border-border text-sm">
                {report.by_disposition.map((d) => (
                  <li key={d.disposition} className="flex items-baseline justify-between gap-3 px-4 py-2.5">
                    <span className="text-text-primary">{DISPOSITION_LABELS[d.disposition] ?? d.disposition}</span>
                    <span className="text-xs text-text-muted" data-numeric>{fmtInt(d.units)} adet · {fmtMoney(d.value)}</span>
                  </li>
                ))}
              </ul>
            </section>
            <section className="space-y-3">
              <SectionHeader title="Türe göre" />
              <ul className="divide-y divide-border rounded border border-border text-sm">
                {report.by_type.map((x) => (
                  <li key={x.return_type} className="flex items-baseline justify-between gap-3 px-4 py-2.5">
                    <span className="text-text-primary">{RETURN_TYPE_LABELS[x.return_type] ?? x.return_type}</span>
                    <span className="text-xs text-text-muted" data-numeric>{fmtInt(x.returns)} belge · {fmtInt(x.units)} adet</span>
                  </li>
                ))}
              </ul>
            </section>
          </div>

          <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
            <section className="space-y-3">
              <SectionHeader title="Ürüne göre iade oranı" meta="dönemde satılan adede göre" />
              <RateTable rows={report.rate_by_product.map((r) => ({ key: r.product_id, label: r.product, ...r }))} header="Ürün" />
            </section>
            <section className="space-y-3">
              <SectionHeader title="Bedene göre iade oranı" />
              {report.rate_by_size.length === 0 ? (
                <EmptyState compact title="Beden seçeneği olan iade yok." />
              ) : (
                <RateTable rows={report.rate_by_size.map((r) => ({ key: r.size, label: r.size, ...r }))} header="Beden" />
              )}
            </section>
          </div>
        </>
      )}
    </ReportPage>
  );
}

function RateTable({ rows, header }: { rows: Array<{ key: string; label: string; sold_units: number; returned_units: number; returns: number; rate_pct: number | null; meaningful: boolean }>; header: string }) {
  return (
    <TableShell minWidth="24rem">
      <THead>
        <TH>{header}</TH>
        <TH align="right">Satılan</TH>
        <TH align="right">İade</TH>
        <TH align="right">Oran</TH>
      </THead>
      <TBody>
        {rows.map((r) => (
          <TR key={r.key}>
            <TD>{r.label}</TD>
            <TD align="right" numeric muted>{fmtInt(r.sold_units)}</TD>
            <TD align="right" numeric>{fmtInt(r.returned_units)}</TD>
            <TD align="right" numeric muted={!r.meaningful}>
              {r.rate_pct === null ? "—" : fmtPct(r.rate_pct)}
              {!r.meaningful ? <span className="ml-1 text-2xs text-text-muted">küçük örneklem</span> : null}
            </TD>
          </TR>
        ))}
      </TBody>
    </TableShell>
  );
}
