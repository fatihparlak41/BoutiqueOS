import { getIntelDimensions, loadIntelContext, parseDays, resolveBranch } from "@/lib/intel/queries";
import { listCategories, listProducts } from "@/lib/catalog/queries";
import { IntelPage, WindowBar, IntelDefinitions, ShareBar } from "@/components/intel/intel-shell";
import { fmtInt, fmtPct } from "@/components/reports/format";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
import { Select } from "@/components/ui/select";
import { Label } from "@/components/ui/label";
import { Button } from "@/components/ui/button";
import { TableShell, THead, TH, TBody, TR, TD } from "@/components/ui/table";
import type { DimensionRow } from "@/lib/intel/model";

export const metadata = { title: "Beden & renk · BoutiqueOS" };

type Params = Record<string, string | undefined>;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PRODUCT_FILTER_LIMIT = 300;

/** Size and colour: units sold and share, availability, stockouts, return rate — per value, for a product or a category. */
export default async function DimensionsPage({ searchParams }: { searchParams: Promise<Params> }) {
  const params = await searchParams;
  const ctx = await loadIntelContext();
  const days = parseDays(params.gun);
  // category / product ids only narrow the tenant's own facts inside the RPC (a foreign id yields nothing),
  // so the aggregate can start alongside the filter lists; the branch is validated first only when given
  const catP = params.kategori && UUID.test(params.kategori) ? params.kategori : null;
  const prodP = params.urun && UUID.test(params.urun) ? params.urun : null;
  const branchP = resolveBranch(params.sube);
  const [{ branchId, branches }, categories, products, dims] = await Promise.all([
    branchP,
    listCategories(),
    listProducts({}, { thumbnails: false, stock: false }),
    params.sube ? branchP.then((b) => getIntelDimensions(b.branchId, days, catP, prodP)) : getIntelDimensions(null, days, catP, prodP),
  ]);
  const categoryId = catP && categories.some((c) => c.id === catP) ? catP : null;
  const productId = prodP && products.some((p) => p.id === prodP) ? prodP : null;
  const extra = { kategori: categoryId ?? undefined, urun: productId ?? undefined };
  const query = `?gun=${days}${branchId ? `&sube=${branchId}` : ""}`;
  const scopeLabel = productId ? products.find((p) => p.id === productId)?.name : categoryId ? categories.find((c) => c.id === categoryId)?.name : "tüm katalog";

  return (
    <IntelPage title="Beden & renk" description="Hangi beden ve renk satıyor, hangisi bekliyor, hangisi tükendi — sayılarla. Pay yüzdeleri yalnız örneklem yeterliyse gösterilir." current="/app/analiz/beden-renk" caps={ctx.caps} query={query}>
      <WindowBar basePath="/app/analiz/beden-renk" window={dims.window} days={days} branches={branches} branchId={branchId} extra={extra} />

      <form method="get" action="/app/analiz/beden-renk" className="grid grid-cols-2 gap-3 rounded border border-border bg-background/60 p-4 lg:grid-cols-4">
        <input type="hidden" name="gun" value={days} />
        {branchId ? <input type="hidden" name="sube" value={branchId} /> : null}
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
          <Button type="submit" size="sm" variant="outline">Uygula</Button>
        </div>
      </form>
      <p className="text-xs text-text-muted" data-numeric>
        Kapsam: <span className="text-text-secondary">{scopeLabel}</span>
        {dims.sales ? ` · dönemde ${fmtInt(dims.sold_win)} adet satıldı (${fmtInt(dims.sold_sized)} bedenli, ${fmtInt(dims.sold_colored)} renkli)` : ""}
        {dims.scope !== "business" ? " · yalnız görebildiğiniz satışlar" : ""}
      </p>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <DimensionTable title="Beden" rows={dims.sizes} total={dims.sold_sized} minSample={dims.min_sample} sales={dims.sales} empty="Beden seçeneği olan varyant yok." />
        <DimensionTable title="Renk" rows={dims.colors} total={dims.sold_colored} minSample={dims.min_sample} sales={dims.sales} empty="Renk seçeneği olan varyant yok." />
      </div>

      <IntelDefinitions financial={dims.financial} />
    </IntelPage>
  );
}

function DimensionTable({ title, rows, total, minSample, sales, empty }: { title: string; rows: DimensionRow[]; total: number; minSample: number; sales: boolean; empty: string }) {
  const sparse = sales && total < minSample;
  return (
    <section className="space-y-3">
      <SectionHeader title={title} meta={rows.length > 0 ? `${fmtInt(rows.length)} değer` : undefined} />
      {rows.length === 0 ? (
        <EmptyState compact title={empty} />
      ) : (
        <>
          {sparse ? <p className="text-2xs text-text-muted">Henüz yeterli veri yok: pay yüzdesi için dönemde en az {fmtInt(minSample)} adet satış gerekir ({fmtInt(total)} var). Adetler yine gösterilir.</p> : null}
          <TableShell minWidth={sales ? "34rem" : "22rem"}>
            <THead>
              <TH>{title}</TH>
              {sales ? <TH align="right">Satılan</TH> : null}
              {sales ? <TH>Satış payı</TH> : null}
              <TH align="right">Müsait</TH>
              <TH align="right">Tükenen varyant</TH>
              {sales ? <TH align="right">İade</TH> : null}
            </THead>
            <TBody>
              {rows.map((r) => (
                <TR key={r.value}>
                  <TD>{r.value}{r.holds_active > 0 ? <span className="ml-2 text-2xs text-text-muted">{fmtInt(r.holds_active)} rezervasyon</span> : null}</TD>
                  {sales ? <TD align="right" numeric>{fmtInt(r.sold_win)}</TD> : null}
                  {sales ? <TD>{r.share_pct !== null ? <ShareBar pct={r.share_pct} label={fmtPct(r.share_pct)} /> : <span className="text-2xs text-text-muted">—</span>}</TD> : null}
                  <TD align="right" numeric>{fmtInt(r.available)}{r.reserved > 0 ? <span className="ml-1 text-2xs text-text-muted">({fmtInt(r.reserved)} rezerve)</span> : null}</TD>
                  <TD align="right" numeric muted>{r.variants_out > 0 ? `${fmtInt(r.variants_out)} / ${fmtInt(r.variants)}` : "—"}</TD>
                  {sales ? (
                    <TD align="right" numeric muted>
                      {r.returned_win > 0 ? `${fmtInt(r.returned_win)}${r.return_rate_pct !== null ? ` · ${fmtPct(r.return_rate_pct)}` : " · küçük örneklem"}` : "—"}
                    </TD>
                  ) : null}
                </TR>
              ))}
            </TBody>
          </TableShell>
        </>
      )}
    </section>
  );
}
