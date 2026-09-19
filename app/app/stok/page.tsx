import Link from "next/link";
import { loadAppContext } from "@/lib/app-context";
import { listBranchOptions, listStock } from "@/lib/stock/queries";
import { countCaps } from "@/lib/stock/count-model";
import { Button } from "@/components/ui/button";
import { STOCK_STATE_LABELS, type StockState } from "@/lib/stock/model";
import { listBrands, listCategories } from "@/lib/catalog/queries";
import { PageHeader } from "@/components/ui/page-header";
import { SearchFilters } from "@/components/ui/search-filters";
import { Boxes, ClipboardCheck } from "lucide-react";
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
  searchParams: Promise<{ q?: string; kategori?: string; marka?: string; sube?: string; durum?: string; arsiv?: string }>;
}) {
  const params = await searchParams;
  const search = params.q?.trim() ?? "";
  const categoryId = params.kategori ?? "";
  const brandId = params.marka ?? "";
  const branchId = params.sube ?? "";
  const state = isState(params.durum) ? params.durum : undefined;
  const includeArchived = params.arsiv === "1";

  const { role } = await loadAppContext();
  const [rows, branches, categories, brands] = await Promise.all([
    listStock({
      search,
      categoryId: categoryId || undefined,
      brandId: brandId || undefined,
      branchId: branchId || undefined,
      state,
      includeArchived,
    }),
    listBranchOptions(),
    listCategories(),
    listBrands(),
  ]);

  const hasFilter = Boolean(search || categoryId || brandId || state || includeArchived);
  const activeBranch = rows[0]?.branch_name ?? branches.find((b) => b.id === branchId)?.name ?? branches[0]?.name ?? "—";
  const carry = { ...(search ? { q: search } : {}), ...(categoryId ? { kategori: categoryId } : {}), ...(brandId ? { marka: brandId } : {}), ...(branchId ? { sube: branchId } : {}), ...(state ? { durum: state } : {}) };

  return (
    <div className="space-y-5">
      <PageHeader
        title="Stok"
        description={`Neyden kaç tane var — ${activeBranch}.`}
        actions={
          countCaps(role).canCount ? (
            <Link href="/app/stok/sayim">
              <Button variant="accent">
                <ClipboardCheck aria-hidden className="h-4 w-4" />
                Stok say
              </Button>
            </Link>
          ) : undefined
        }
      />

      <SearchFilters
        basePath="/app/stok"
        search={search}
        placeholder="Ürün adı ya da barkod okut"
        hidden={{ ...(branchId ? { sube: branchId } : {}), ...(includeArchived ? { arsiv: "1" } : {}) }}
        inline
        selects={[
          { name: "kategori", label: "Kategori", value: categoryId, options: categories.map((c) => ({ value: c.id, label: c.name })) },
          { name: "marka", label: "Marka", value: brandId, options: brands.map((b) => ({ value: b.id, label: b.name })) },
          ...(branches.length > 1 ? [{ name: "sube", label: "Şube", value: branchId, options: branches.map((b) => ({ value: b.id, label: b.name })), allLabel: "Varsayılan" }] : []),
          { name: "durum", label: "Stok durumu", value: state ?? "", options: Object.entries(STOCK_STATE_LABELS).map(([value, label]) => ({ value, label })) },
        ]}
      />

      {rows.length === 0 ? (
        hasFilter ? (
          <EmptyState compact title="Bu aramaya uyan ürün yok" description="Yazımı kontrol et ya da filtreleri temizle." action={<Link href="/app/stok"><Button variant="outline" size="sm">Filtreleri temizle</Button></Link>} />
        ) : (
          <EmptyState
            editorial
            icon={<Boxes />}
            title="Rafta henüz bir şey yok"
            description="Ürünlerini ekle, sonra raftakileri say; miktarlar burada kendiliğinden görünür."
            action={countCaps(role).canCount ? <Link href="/app/stok/sayim"><Button variant="outline">Stok say</Button></Link> : undefined}
          />
        )
      ) : (
        <>
          <StockCards rows={rows} />
          <StockTable rows={rows} />
          <p className="text-2xs leading-relaxed text-text-muted" data-numeric>
            {rows.length} ürün seçeneği · {activeBranch}. Satılabilir = rafta − ayrılmış (hasarlı ve karantina sayılmaz). Arşivdeki ürünler yalnız stoğu kaldığı sürece listelenir
            {includeArchived ? null : <> · <Link href={{ pathname: "/app/stok", query: { ...carry, arsiv: "1" } }} className="underline underline-offset-4 hover:text-text-primary">arşivdekilerin tümünü göster</Link></>}.
          </p>
        </>
      )}
    </div>
  );
}
