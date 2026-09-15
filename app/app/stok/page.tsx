import Link from "next/link";
import { loadAppContext } from "@/lib/app-context";
import { listBranchOptions, listStock } from "@/lib/stock/queries";
import { countCaps } from "@/lib/stock/count-model";
import { Button } from "@/components/ui/button";
import { STOCK_STATE_LABELS, type StockState } from "@/lib/stock/model";
import { listBrands, listCategories } from "@/lib/catalog/queries";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { PageHeader } from "@/components/ui/page-header";
import { FilterBar, FilterField } from "@/components/ui/filter-bar";
import { EmptyState } from "@/components/ui/empty-state";
import { StockCards, StockTable } from "@/components/stock/stock-rows";

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

  const { role } = await loadAppContext();
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
      <PageHeader
        title="Stok"
        description="Miktarlar değişmez stok defterinden gelir. Bu ekranda elle stok girişi yoktur."
        actions={
          countCaps(role).canCount ? (
            <Link href="/app/stok/sayim">
              <Button size="sm" variant="outline">Stok sayımı</Button>
            </Link>
          ) : undefined
        }
      />

      <FilterBar clearHref="/app/stok" hasFilter={hasFilter}>
        <FilterField wide>
          <Label htmlFor="q">Ara</Label>
          <Input id="q" name="q" defaultValue={search} placeholder="Ürün adı, SKU veya barkod" spellCheck={false} />
        </FilterField>
        <FilterField>
          <Label htmlFor="kategori">Kategori</Label>
          <Select id="kategori" name="kategori" defaultValue={categoryId}>
            <option value="">Tümü</option>
            {categories.map((category) => (
              <option key={category.id} value={category.id}>
                {category.name}
              </option>
            ))}
          </Select>
        </FilterField>
        <FilterField>
          <Label htmlFor="marka">Marka</Label>
          <Select id="marka" name="marka" defaultValue={brandId}>
            <option value="">Tümü</option>
            {brands.map((brand) => (
              <option key={brand.id} value={brand.id}>
                {brand.name}
              </option>
            ))}
          </Select>
        </FilterField>
        <FilterField>
          <Label htmlFor="sube">Şube</Label>
          <Select id="sube" name="sube" defaultValue={branchId}>
            {branches.map((branch) => (
              <option key={branch.id} value={branch.id}>
                {branch.name}
              </option>
            ))}
          </Select>
        </FilterField>
        <FilterField>
          <Label htmlFor="durum">Stok durumu</Label>
          <Select id="durum" name="durum" defaultValue={state ?? ""}>
            <option value="">Tümü</option>
            {Object.entries(STOCK_STATE_LABELS).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </Select>
        </FilterField>
      </FilterBar>

      {rows.length === 0 ? (
        hasFilter ? (
          <EmptyState
            compact
            title="Bu filtrelere uyan varyant yok"
            description="Aramayı daraltmayı ya da filtreleri temizlemeyi deneyin."
          />
        ) : (
          <EmptyState
            editorial
            title="Stokta henüz bir şey yok"
            description="Önce ürün ve varyant tanımlayın, sonra mal kabulle stoğa alın. Miktarlar burada kendiliğinden görünür."
          />
        )
      ) : (
        <>
          <StockCards rows={rows} />
          <StockTable rows={rows} />
          <p className="text-2xs leading-relaxed text-text-muted" data-numeric>
            {rows.length} varyant, şube: {activeBranch}. Toplam = satılabilir + karantina + hasarlı; uygun =
            satılabilir − rezerve.
          </p>
        </>
      )}
    </div>
  );
}
