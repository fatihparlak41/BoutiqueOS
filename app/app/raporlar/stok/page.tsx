import Link from "next/link";
import { getStockReport, reportPageState } from "@/lib/reports/queries";
import { ReportPage } from "@/components/reports/report-shell";
import { Kpi, KpiStrip } from "@/components/reports/kpi";
import { fmtInt, fmtMoneyShort } from "@/components/reports/format";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
import { Select } from "@/components/ui/select";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Button } from "@/components/ui/button";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";

export const metadata = { title: "Stok raporu · BoutiqueOS" };

type Params = { sube?: string; esik?: string };

/**
 * Stock report: a point-in-time picture of the ledger (no period). Quantities for every
 * role; valuation from the current cost pools only when the RPC included it (manager+).
 * Historical profit is never derived from this valuation.
 */
export default async function StockReportPage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const state = await reportPageState(params);
  const threshold = Math.min(Math.max(Number.parseInt(params.esik ?? "2", 10) || 2, 0), 999);
  const report = await getStockReport(state.branchId, threshold);
  const t = report.totals;
  const branchQuery = state.branchId ? `?sube=${state.branchId}` : "";

  return (
    <ReportPage title="Stok" description="Değişmez stok defterinin şu anki toplamı: satılabilir, rezerve, müsait, hasarlı, karantina." current="/app/raporlar/stok" caps={state.caps} query={state.query}>
      <form method="get" action="/app/raporlar/stok" className="grid grid-cols-2 items-end gap-3 rounded border border-border bg-background/60 p-4 sm:grid-cols-[auto_auto_auto]">
        {state.branches.length > 1 ? (
          <div className="space-y-1.5">
            <Label htmlFor="sube">Şube</Label>
            <Select id="sube" name="sube" defaultValue={state.branchId ?? ""} className="h-9 sm:h-9">
              <option value="">Tüm şubeler</option>
              {state.branches.map((b) => (
                <option key={b.id} value={b.id}>{b.name}</option>
              ))}
            </Select>
          </div>
        ) : null}
        <div className="space-y-1.5">
          <Label htmlFor="esik">Düşük stok eşiği</Label>
          <Input id="esik" name="esik" type="number" min={0} max={999} defaultValue={threshold} className="h-9" />
        </div>
        <Button type="submit" size="sm" variant="outline" className="h-9">Uygula</Button>
      </form>

      {t.variants === 0 ? (
        <EmptyState editorial title="Henüz aktif varyant yok" description="Katalogdaki ürünler ve varyantlar aktif olduğunda stok özeti burada görünür." />
      ) : (
        <>
          <KpiStrip>
            <Kpi label="Satılabilir" value={fmtInt(t.sellable)} hint={`${fmtInt(t.variants)} aktif varyant`} />
            <Kpi label="Rezerve" value={fmtInt(t.reserved)} hint="aktif, süresi dolmamış" />
            <Kpi label="Müsait" value={fmtInt(t.available)} hint="satılabilir − rezerve" />
            <Kpi label="Hasarlı / karantina" value={`${fmtInt(t.damaged)} / ${fmtInt(t.quarantine)}`} />
            <Kpi label="Stoku biten" value={fmtInt(t.out_of_stock)} hint="müsait ≤ 0" />
            <Kpi label="Düşük stok" value={fmtInt(t.low_stock)} hint={`müsait ≤ ${threshold}`} />
            {report.valuation ? <Kpi label="Stok değeri" value={fmtMoneyShort(report.valuation.total_value_base)} hint={`${fmtInt(report.valuation.on_hand_qty)} adet, mevcut maliyet havuzu`} /> : null}
          </KpiStrip>

          <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
            <section className="space-y-3">
              <SectionHeader title="Stoku biten varyantlar" meta={t.out_of_stock > 100 ? `ilk 100 / ${fmtInt(t.out_of_stock)}` : `${fmtInt(t.out_of_stock)}`} />
              {report.out_of_stock.length === 0 ? (
                <EmptyState compact title="Stoku biten aktif varyant yok." />
              ) : (
                <TableShell minWidth="22rem">
                  <THead>
                    <TH>Varyant</TH>
                    <TH align="right">Satılabilir</TH>
                    <TH align="right">Rezerve</TH>
                  </THead>
                  <TBody>
                    {report.out_of_stock.map((v) => (
                      <TR key={v.variant_id}>
                        <TD>
                          <CellTitle sub={v.sku} subNumeric>
                            <Link href={`/app/stok/${v.variant_id}`} className="hover:underline">{v.product}</Link>
                          </CellTitle>
                        </TD>
                        <TD align="right" numeric>{fmtInt(v.sellable)}</TD>
                        <TD align="right" numeric muted>{fmtInt(v.reserved)}</TD>
                      </TR>
                    ))}
                  </TBody>
                </TableShell>
              )}
            </section>
            <section className="space-y-3">
              <SectionHeader title="Düşük stok" meta={`müsait 1–${threshold}`} />
              {report.low_stock.length === 0 ? (
                <EmptyState compact title="Eşiğin altında varyant yok." />
              ) : (
                <TableShell minWidth="22rem">
                  <THead>
                    <TH>Varyant</TH>
                    <TH align="right">Müsait</TH>
                    <TH align="right">Rezerve</TH>
                  </THead>
                  <TBody>
                    {report.low_stock.map((v) => (
                      <TR key={v.variant_id}>
                        <TD>
                          <CellTitle sub={v.sku} subNumeric>
                            <Link href={`/app/stok/${v.variant_id}`} className="hover:underline">{v.product}</Link>
                          </CellTitle>
                        </TD>
                        <TD align="right" numeric>{fmtInt(v.available)}</TD>
                        <TD align="right" numeric muted>{fmtInt(v.reserved)}</TD>
                      </TR>
                    ))}
                  </TBody>
                </TableShell>
              )}
            </section>
          </div>
          <p className="text-2xs text-text-muted">
            Ayrıntılı liste ve kova bazında miktarlar <Link href={`/app/stok${branchQuery}`} className="underline underline-offset-4">Stok</Link> ekranında.
          </p>
        </>
      )}
    </ReportPage>
  );
}
