import { redirect } from "next/navigation";
import { getSalesReport, reportPageState } from "@/lib/reports/queries";
import { listMembers } from "@/lib/pos/queries";
import { listCategories, listProducts } from "@/lib/catalog/queries";
import { ReportPage, PeriodBar, ScopeNote } from "@/components/reports/report-shell";
import { Kpi, KpiStrip } from "@/components/reports/kpi";
import { TrendChart } from "@/components/reports/trend-chart";
import { DailyTable, MetricDefinitions } from "@/components/reports/tables";
import { fmtInt, fmtMoney, fmtMoneyShort, fmtPct } from "@/components/reports/format";
import { SectionHeader } from "@/components/ui/section-header";
import { Select } from "@/components/ui/select";
import { Label } from "@/components/ui/label";
import { Button } from "@/components/ui/button";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";

export const metadata = { title: "Satış raporu · BoutiqueOS" };

type Params = { d?: string; from?: string; to?: string; sube?: string; satici?: string; kategori?: string; urun?: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PRODUCT_FILTER_LIMIT = 300;

/** Sales report: the window totals under the chosen filters, one RPC. Filters are validated against the tenant's own lists before they reach the RPC. */
export default async function SalesReportPage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const state = await reportPageState(params);
  if (!state.caps.canViewSales) redirect("/app/raporlar/stok");
  const [members, categories, products] = await Promise.all([listMembers(), listCategories(), listProducts({}, { thumbnails: false, stock: false })]);
  const salespersonId = params.satici && members.some((m) => m.user_id === params.satici) ? params.satici : null;
  const categoryId = params.kategori && categories.some((c) => c.id === params.kategori) ? params.kategori : null;
  const productId = params.urun && UUID.test(params.urun) && products.some((p) => p.id === params.urun) ? params.urun : null;
  const report = await getSalesReport(state.period, { branchId: state.branchId, salespersonId, categoryId, productId });
  const t = report.totals;
  const fin = report.financial;
  const extra = { satici: salespersonId ?? undefined, kategori: categoryId ?? undefined, urun: productId ?? undefined };
  const filterQuery = new URLSearchParams(Object.entries(extra).filter((e): e is [string, string] => Boolean(e[1]))).toString();

  return (
    <ReportPage title="Satış" description="Brüt, indirim, net; iade sonrası net; işlem ve adet. Değişimin yeni ürünü tam değerle satış sayılır, geri gelen ürün iade sayılır." current="/app/raporlar/satis" caps={state.caps} query={state.query + (filterQuery ? `&${filterQuery}` : "")}>
      <PeriodBar basePath="/app/raporlar/satis" period={state.period} branches={state.branches} branchId={state.branchId} extra={extra} />
      <ScopeNote scope={report.scope} />

      <form method="get" action="/app/raporlar/satis" className="grid grid-cols-2 gap-3 rounded border border-border bg-background/60 p-4 lg:grid-cols-4">
        <input type="hidden" name="d" value={state.period.preset} />
        {state.period.preset === "custom" ? <input type="hidden" name="from" value={state.period.from} /> : null}
        {state.period.preset === "custom" ? <input type="hidden" name="to" value={state.period.to} /> : null}
        {state.branchId ? <input type="hidden" name="sube" value={state.branchId} /> : null}
        <div className="space-y-1.5">
          <Label htmlFor="satici">Satıcı</Label>
          <Select id="satici" name="satici" defaultValue={salespersonId ?? ""}>
            <option value="">Tümü</option>
            {members.filter((m) => m.can_sell).map((m) => (
              <option key={m.user_id} value={m.user_id}>{m.full_name ?? "—"}</option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="kategori">Kategori</Label>
          <Select id="kategori" name="kategori" defaultValue={categoryId ?? ""}>
            <option value="">Tümü</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>{c.name}</option>
            ))}
          </Select>
        </div>
        {products.length <= PRODUCT_FILTER_LIMIT ? (
          <div className="space-y-1.5">
            <Label htmlFor="urun">Ürün</Label>
            <Select id="urun" name="urun" defaultValue={productId ?? ""}>
              <option value="">Tümü</option>
              {products.map((p) => (
                <option key={p.id} value={p.id}>{p.name}</option>
              ))}
            </Select>
          </div>
        ) : null}
        <div className="flex items-end">
          <Button type="submit" size="sm" variant="outline">Filtrele</Button>
        </div>
      </form>

      <KpiStrip>
        <Kpi label="Brüt satış" value={fmtMoneyShort(t.gross_sales)} />
        <Kpi label="İndirim" value={fmtMoneyShort(t.discounts)} hint={t.gross_sales > 0 ? fmtPct((t.discounts / t.gross_sales) * 100) + " brütün" : undefined} />
        <Kpi label="Net satış" value={fmtMoneyShort(t.net_sales)} />
        <Kpi label="İşlem" value={fmtInt(t.transactions)} hint={`${fmtInt(t.units)} adet`} />
        <Kpi label="Ortalama sepet" value={fmtMoneyShort(t.avg_basket)} />
        <Kpi label="İade" value={fmtMoneyShort(t.returns_value)} hint={`${fmtInt(t.returns_count)} belge · ${fmtInt(t.returned_units)} adet`} />
        <Kpi label="İade sonrası net" value={fmtMoneyShort(t.net_sales_after_returns)} />
        {fin ? <Kpi label="Brüt kâr" value={fmtMoneyShort(t.gross_profit)} hint={fmtPct(t.gross_margin_pct) + " marj"} /> : null}
      </KpiStrip>

      <section className="space-y-3 rounded border border-border bg-surface p-4">
        <TrendChart daily={report.daily} from={report.period.from} to={report.period.to} />
      </section>

      {report.by_branch.length > 1 ? (
        <section className="space-y-3">
          <SectionHeader title="Şubeye göre" />
          <TableShell minWidth="28rem">
            <THead>
              <TH>Şube</TH>
              <TH align="right">İşlem</TH>
              <TH align="right">Adet</TH>
              <TH align="right">Net satış</TH>
              <TH align="right">İade</TH>
            </THead>
            <TBody>
              {report.by_branch.map((b) => (
                <TR key={b.branch_id}>
                  <TD>{b.branch}</TD>
                  <TD align="right" numeric>{fmtInt(b.transactions)}</TD>
                  <TD align="right" numeric>{fmtInt(b.units)}</TD>
                  <TD align="right" numeric>{fmtMoney(b.net_sales)}</TD>
                  <TD align="right" numeric muted>{fmtMoney(b.returns_value)}</TD>
                </TR>
              ))}
            </TBody>
          </TableShell>
        </section>
      ) : null}

      <section className="space-y-3">
        <SectionHeader title="Güne göre" meta={`${report.daily.length} gün`} />
        <DailyTable daily={report.daily} financial={fin} />
      </section>

      <MetricDefinitions financial={fin} />
    </ReportPage>
  );
}
