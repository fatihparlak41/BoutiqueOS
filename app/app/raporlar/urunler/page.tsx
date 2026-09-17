import Link from "next/link";
import { redirect } from "next/navigation";
import { getProductsReport, reportPageState } from "@/lib/reports/queries";
import { listCategories } from "@/lib/catalog/queries";
import { PRODUCT_GROUPS, isProductGroup, type ProductGroup } from "@/lib/reports/model";
import { ReportPage, PeriodBar, ScopeNote } from "@/components/reports/report-shell";
import { RankedTable, MetricDefinitions } from "@/components/reports/tables";
import { fmtInt, fmtMoney } from "@/components/reports/format";
import { SectionHeader } from "@/components/ui/section-header";
import { Select } from "@/components/ui/select";
import { Label } from "@/components/ui/label";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { cn } from "@/lib/utils";

export const metadata = { title: "Ürün performansı · BoutiqueOS" };

type Params = { d?: string; from?: string; to?: string; sube?: string; grup?: string; kategori?: string };

/** Product performance: one RPC returns the ranked rows for the chosen grouping plus the fashion views (sizes, colours, sold-out variants). */
export default async function ProductsReportPage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const state = await reportPageState(params);
  if (!state.caps.canViewSales) redirect("/app/raporlar/stok");
  const group: ProductGroup = isProductGroup(params.grup) ? params.grup : "product";
  const categories = await listCategories();
  const categoryId = params.kategori && categories.some((c) => c.id === params.kategori) ? params.kategori : null;
  const report = await getProductsReport(state.period, state.branchId, group, categoryId);
  const fin = report.financial;
  const extra = { grup: group !== "product" ? group : undefined, kategori: categoryId ?? undefined };
  const groupLabel = PRODUCT_GROUPS.find((g) => g.key === group)?.label ?? "Ürün";
  const filterQuery = new URLSearchParams(Object.entries(extra).filter((e): e is [string, string] => Boolean(e[1]))).toString();

  return (
    <ReportPage title="Ürün performansı" description="Satılan adet ve net satış; iadeler kendi dönemine yazılır. Puan ya da tahmin yok, yalnız gerçekleşen." current="/app/raporlar/urunler" caps={state.caps} query={state.query + (filterQuery ? `&${filterQuery}` : "")}>
      <PeriodBar basePath="/app/raporlar/urunler" period={state.period} branches={state.branches} branchId={state.branchId} extra={extra} />
      <ScopeNote scope={report.scope} />

      <div className="flex flex-wrap items-end gap-3">
        <div className="flex flex-wrap gap-1.5" role="group" aria-label="Gruplama">
          {PRODUCT_GROUPS.map((g) => (
            <Link
              key={g.key}
              href={`/app/raporlar/urunler${state.query}&grup=${g.key}${categoryId ? `&kategori=${categoryId}` : ""}`}
              aria-current={g.key === group ? "true" : undefined}
              className={cn(
                "inline-flex h-9 items-center rounded border px-3 text-xs focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                g.key === group ? "border-text-primary bg-surface font-medium text-text-primary" : "border-border text-text-secondary hover:border-border-strong hover:text-text-primary",
              )}
            >
              {g.label}
            </Link>
          ))}
        </div>
        {categories.length > 0 ? (
          <form method="get" action="/app/raporlar/urunler" className="flex items-end gap-2">
            <input type="hidden" name="d" value={state.period.preset} />
            {state.period.preset === "custom" ? <input type="hidden" name="from" value={state.period.from} /> : null}
            {state.period.preset === "custom" ? <input type="hidden" name="to" value={state.period.to} /> : null}
            {state.branchId ? <input type="hidden" name="sube" value={state.branchId} /> : null}
            <input type="hidden" name="grup" value={group} />
            <div className="space-y-1.5">
              <Label htmlFor="kategori">Kategori</Label>
              <Select id="kategori" name="kategori" defaultValue={categoryId ?? ""} className="h-9 sm:h-9">
                <option value="">Tümü</option>
                {categories.map((c) => (
                  <option key={c.id} value={c.id}>{c.name}</option>
                ))}
              </Select>
            </div>
            <Button type="submit" size="sm" variant="outline" className="h-9">Uygula</Button>
          </form>
        ) : null}
      </div>

      <section className="space-y-3">
        <SectionHeader title={`${groupLabel} bazında`} meta={`${report.rows.length} satır · net satışa göre`} />
        <RankedTable
          rows={report.rows}
          financial={fin}
          header={groupLabel}
          title={(r) => ("label" in r ? String(r.label) : "—")}
          sub={(r) => ("sub" in r && r.sub ? String(r.sub) : undefined)}
        />
      </section>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <section className="space-y-3">
          <SectionHeader title="En çok satan bedenler" />
          {report.top_sizes.length === 0 ? (
            <EmptyState compact title="Beden seçeneği olan satış yok." />
          ) : (
            <ol className="divide-y divide-border rounded border border-border">
              {report.top_sizes.map((s) => (
                <li key={s.key} className="flex items-baseline justify-between gap-3 px-4 py-2.5 text-sm">
                  <span className="font-medium text-text-primary">{s.label}</span>
                  <span className="text-xs text-text-muted" data-numeric>{fmtInt(s.units)} adet · {fmtMoney(s.net_sales)}{s.returned_units > 0 ? ` · ${fmtInt(s.returned_units)} iade` : ""}</span>
                </li>
              ))}
            </ol>
          )}
        </section>
        <section className="space-y-3">
          <SectionHeader title="En çok satan renkler" />
          {report.top_colors.length === 0 ? (
            <EmptyState compact title="Renk seçeneği olan satış yok." />
          ) : (
            <ol className="divide-y divide-border rounded border border-border">
              {report.top_colors.map((s) => (
                <li key={s.key} className="flex items-baseline justify-between gap-3 px-4 py-2.5 text-sm">
                  <span className="font-medium text-text-primary">{s.label}</span>
                  <span className="text-xs text-text-muted" data-numeric>{fmtInt(s.units)} adet · {fmtMoney(s.net_sales)}{s.returned_units > 0 ? ` · ${fmtInt(s.returned_units)} iade` : ""}</span>
                </li>
              ))}
            </ol>
          )}
        </section>
      </div>

      <section className="space-y-3">
        <SectionHeader title="Satışı olup stoku biten varyantlar" meta="şu anki müsait stok ≤ 0" />
        {report.out_of_stock_with_sales.length === 0 ? (
          <EmptyState compact title="Bu dönemde satılan her varyantın müsait stoku var." />
        ) : (
          <TableShell minWidth="28rem">
            <THead>
              <TH>Varyant</TH>
              <TH align="right">Dönemde satılan</TH>
              <TH align="right">Müsait</TH>
            </THead>
            <TBody>
              {report.out_of_stock_with_sales.map((v) => (
                <TR key={v.variant_id}>
                  <TD>
                    <CellTitle sub={v.sku} subNumeric>
                      <Link href={`/app/stok/${v.variant_id}`} className="hover:underline">{v.product}</Link>
                    </CellTitle>
                  </TD>
                  <TD align="right" numeric>{fmtInt(v.units_sold)}</TD>
                  <TD align="right" numeric>{fmtInt(v.available)}</TD>
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
