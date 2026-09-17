import Link from "next/link";
import { redirect } from "next/navigation";
import { getOverview, reportPageState } from "@/lib/reports/queries";
import { ReportPage, PeriodBar, ScopeNote } from "@/components/reports/report-shell";
import { Kpi, KpiStrip } from "@/components/reports/kpi";
import { TrendChart } from "@/components/reports/trend-chart";
import { MetricDefinitions } from "@/components/reports/tables";
import { fmtInt, fmtMoney, fmtMoneyShort, fmtPct } from "@/components/reports/format";
import { EmptyState } from "@/components/ui/empty-state";
import { SectionHeader } from "@/components/ui/section-header";

export const metadata = { title: "Raporlar · BoutiqueOS" };

type Params = { d?: string; from?: string; to?: string; sube?: string };

/**
 * Reporting home. One aggregate RPC for the window (and its comparable predecessor),
 * rendered as a compact KPI strip and a single daily trend. sales_staff see their own
 * scope without money-behind-the-money; stock_staff are sent to the stock report.
 */
export default async function ReportsHomePage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const state = await reportPageState(params);
  if (!state.caps.canViewSales) redirect("/app/raporlar/stok");
  const report = await getOverview(state.period, state.branchId);
  const cur = report.current;
  const prev = report.previous;
  const hasPrevious = Boolean(prev && (prev.transactions > 0 || prev.returns_count > 0));
  const fin = report.financial;
  const empty = cur.transactions === 0 && cur.returns_count === 0;

  return (
    <ReportPage title="Genel bakış" description="Tamamlanmış satışlardan, iadelerden ve satış anında kilitlenen maliyetten türetilir." current="/app/raporlar" caps={state.caps} query={state.query}>
      <PeriodBar basePath="/app/raporlar" period={state.period} branches={state.branches} branchId={state.branchId} />
      <ScopeNote scope={report.scope} />

      {empty ? (
        <EmptyState
          editorial
          title="Bu dönemde satış yok"
          description={hasPrevious ? "Önceki dönemde hareket vardı; başka bir dönem seçin ya da satış raporuna bakın." : "Kasa'dan tamamlanan ilk satışla birlikte rakamlar burada görünür."}
          action={<Link href="/app/pos" className="text-sm underline underline-offset-4">Kasaya git</Link>}
        />
      ) : (
        <>
          <KpiStrip>
            <Kpi label="Net satış" value={fmtMoneyShort(cur.net_sales)} current={cur.net_sales} previous={prev?.net_sales} format={fmtMoneyShort} hasPrevious={hasPrevious} hint="brüt − indirim" />
            <Kpi label="Satılan adet" value={fmtInt(cur.units)} current={cur.units} previous={prev?.units} format={fmtInt} hasPrevious={hasPrevious} />
            <Kpi label="İşlem" value={fmtInt(cur.transactions)} current={cur.transactions} previous={prev?.transactions} format={fmtInt} hasPrevious={hasPrevious} />
            <Kpi label="Ortalama sepet" value={fmtMoneyShort(cur.avg_basket)} current={cur.avg_basket} previous={prev?.avg_basket} format={fmtMoneyShort} hasPrevious={hasPrevious} />
            <Kpi
              label="İade / değişim"
              value={`${fmtInt(cur.returns_count)} · ${fmtMoneyShort(cur.returns_value)}`}
              current={cur.returns_value}
              previous={prev?.returns_value}
              format={fmtMoneyShort}
              hasPrevious={hasPrevious}
              hint={cur.exchanges_count > 0 ? `${fmtInt(cur.exchanges_count)} değişim` : undefined}
            />
            <Kpi label="İade sonrası net" value={fmtMoneyShort(cur.net_sales_after_returns)} current={cur.net_sales_after_returns} previous={prev?.net_sales_after_returns} format={fmtMoneyShort} hasPrevious={hasPrevious} />
            {fin ? (
              <Kpi label="Brüt kâr" value={fmtMoneyShort(cur.gross_profit)} current={cur.gross_profit} previous={prev?.gross_profit} format={fmtMoneyShort} hasPrevious={hasPrevious} hint={`maliyet ${fmtMoneyShort((cur.cogs ?? 0) - (cur.returned_cogs ?? 0))}`} />
            ) : null}
            {fin ? (
              <Kpi label="Brüt marj" value={fmtPct(cur.gross_margin_pct)} current={cur.gross_margin_pct ?? null} previous={prev?.gross_margin_pct ?? null} format={fmtPct} hasPrevious={hasPrevious} />
            ) : null}
          </KpiStrip>
          {!hasPrevious && prev ? <p className="text-2xs text-text-muted">Önceki dönemde hareket olmadığından karşılaştırma gösterilmiyor.</p> : null}

          <section className="space-y-3 rounded border border-border bg-surface p-4">
            <TrendChart daily={report.daily} from={report.period.from} to={report.period.to} />
          </section>

          <section className="space-y-3">
            <SectionHeader title="Ayrıntılar" />
            <ul className="grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
              {[
                { href: "/app/raporlar/satis", label: "Satış raporu", hint: `${fmtMoney(cur.gross_sales)} brüt · ${fmtMoney(cur.discounts)} indirim` },
                { href: "/app/raporlar/urunler", label: "Ürün performansı", hint: "ürün, varyant, kategori, renk, beden" },
                { href: "/app/raporlar/personel", label: "Personel", hint: "satıcı atfı ve kasiyer ayrı" },
                ...(fin ? [{ href: "/app/raporlar/odemeler", label: "Ödemeler", hint: "nakit, kart, iade, kasa hareketi" }] : []),
                { href: "/app/raporlar/iadeler", label: "İadeler", hint: `${fmtInt(cur.returned_units)} adet geri geldi` },
                { href: "/app/raporlar/musteriler", label: "Müşteriler", hint: "kayıtlı ve anonim satışlar" },
              ].map((l) => (
                <li key={l.href}>
                  <Link href={l.href + state.query} className="block rounded border border-border px-4 py-3 transition-colors hover:border-border-strong focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
                    <span className="block font-medium text-text-primary">{l.label}</span>
                    <span className="mt-0.5 block text-xs text-text-muted" data-numeric>{l.hint}</span>
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        </>
      )}

      <MetricDefinitions financial={fin} />
    </ReportPage>
  );
}
