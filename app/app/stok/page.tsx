import Link from "next/link";
import { listBranchOptions, listStock } from "@/lib/stock/queries";
import { STOCK_STATE_LABELS, type StockState } from "@/lib/stock/model";
import { listBrands, listCategories } from "@/lib/catalog/queries";
import { formatQuantity } from "@/lib/receiving/format";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";

export const metadata = { title: "Stok · BoutiqueOS" };

function isState(value: string | undefined): value is StockState {
  return value === "in_stock" || value === "out_of_stock" || value === "has_quarantine" || value === "has_damaged";
}

/**
 * Read-only by design. There is no quantity input, no adjustment and no condition change
 * on this screen: stock is a consequence of the immutable ledger, and every write path
 * (adjustment, write-off, condition change) is a separate controlled operation.
 */
export default async function StockPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; kategori?: string; marka?: string; sube?: string; durum?: string }>;
}) {
  const params = await searchParams;
  const search = params.q?.trim() ?? "";
  const categoryId = params.kategori ?? "";
  const brandId = params.marka ?? "";
  const branchId = params.sube ?? "";
  const state = isState(params.durum) ? params.durum : undefined;

  const [rows, branches, categories, brands] = await Promise.all([
    listStock({
      search,
      categoryId: categoryId || undefined,
      brandId: brandId || undefined,
      branchId: branchId || undefined,
      state,
    }),
    listBranchOptions(),
    listCategories(),
    listBrands(),
  ]);

  const hasFilter = Boolean(search || categoryId || brandId || state);
  const activeBranch = rows[0]?.branch_name ?? branches.find((b) => b.id === branchId)?.name ?? branches[0]?.name ?? "—";

  return (
    <div className="space-y-6">
      <header>
        <h2 className="font-serif text-xl leading-tight tracking-tightish">Stok</h2>
        <p className="mt-1 text-xs text-muted">
          Miktarlar değişmez stok defterinden gelir. Bu ekranda elle stok girişi yoktur.
        </p>
      </header>

      <form method="get" className="grid grid-cols-2 gap-3 border-y border-line py-4 lg:grid-cols-5">
        <div className="col-span-2 space-y-1.5">
          <Label htmlFor="q">Ara</Label>
          <Input id="q" name="q" defaultValue={search} placeholder="Ürün adı, SKU veya barkod" spellCheck={false} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="kategori">Kategori</Label>
          <Select id="kategori" name="kategori" defaultValue={categoryId}>
            <option value="">Tümü</option>
            {categories.map((category) => (
              <option key={category.id} value={category.id}>
                {category.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="marka">Marka</Label>
          <Select id="marka" name="marka" defaultValue={brandId}>
            <option value="">Tümü</option>
            {brands.map((brand) => (
              <option key={brand.id} value={brand.id}>
                {brand.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="sube">Şube</Label>
          <Select id="sube" name="sube" defaultValue={branchId}>
            {branches.map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="durum">Stok durumu</Label>
          <Select id="durum" name="durum" defaultValue={state ?? ""}>
            <option value="">Tümü</option>
            {Object.entries(STOCK_STATE_LABELS).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </Select>
        </div>
        <div className="col-span-2 flex items-center gap-3 lg:col-span-5">
          <Button type="submit" size="sm" variant="outline">
            Filtrele
          </Button>
          {hasFilter ? (
            <Link href="/app/stok" className="text-xs text-muted underline underline-offset-2 hover:text-ink">
              Filtreleri temizle
            </Link>
          ) : null}
        </div>
      </form>

      {rows.length === 0 ? (
        <div className="border border-dashed border-line-strong px-6 py-12 text-center">
          <p className="text-sm text-ink-70">
            {hasFilter ? "Bu filtrelere uyan varyant yok." : "Gösterilecek varyant yok."}
          </p>
          <p className="mt-1 text-xs text-muted">
            {hasFilter
              ? "Aramayı daraltmayı ya da filtreleri temizlemeyi deneyin."
              : "Önce ürün ve varyant tanımlayın, sonra mal kabulle stoğa alın."}
          </p>
        </div>
      ) : (
        <div className="relative overflow-x-auto">
          <table className="w-full min-w-[62rem] border-collapse text-sm">
            <thead>
              <tr className="border-y border-line text-left text-xs text-muted">
                <th scope="col" className="py-2 pr-4 font-medium">Ürün / varyant</th>
                <th scope="col" className="py-2 pr-4 font-medium">SKU / barkod</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Satılabilir</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Karantina</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Hasarlı</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Toplam</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Rezerve</th>
                <th scope="col" className="py-2 text-right font-medium">Uygun</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {rows.map((row) => (
                <tr key={row.variant_id} className="transition-colors hover:bg-panel/60">
                  <td className="py-2.5 pr-4">
                    <Link
                      href={`/app/stok/${row.variant_id}`}
                      className="font-medium text-ink underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
                    >
                      {row.product_name}
                    </Link>
                    <span className="mt-0.5 block text-2xs text-muted">{row.options}</span>
                  </td>
                  <td className="py-2.5 pr-4 text-ink-70" data-numeric>
                    {row.sku}
                    {row.primary_barcode ? (
                      <span className="mt-0.5 block text-2xs text-muted">{row.primary_barcode}</span>
                    ) : null}
                  </td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.sellable)}</td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.quarantine)}</td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.damaged)}</td>
                  <td className="py-2.5 pr-4 text-right font-medium" data-numeric>{formatQuantity(row.on_hand)}</td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.reserved)}</td>
                  <td className="py-2.5 text-right font-medium" data-numeric>{formatQuantity(row.available)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="mt-3 text-2xs text-muted">
            {rows.length} varyant · şube: {activeBranch} · Toplam = satılabilir + karantina + hasarlı ·
            Uygun = satılabilir − rezerve
          </p>
        </div>
      )}
    </div>
  );
}
