import Link from "next/link";
import {
  listProducts,
  listCategories,
  listBrands,
  loadCatalogContext,
  PRODUCT_STATUS_LABELS,
  type ProductStatus,
} from "@/lib/catalog/queries";
import { formatPrice, formatPriceRange } from "@/lib/catalog/format";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { StatusPill } from "@/components/catalog/status-pill";

export const metadata = { title: "Ürünler · BoutiqueOS" };

type SearchParams = {
  q?: string;
  kategori?: string;
  marka?: string;
  durum?: string;
};

function isProductStatus(value: string | undefined): value is ProductStatus {
  return value === "draft" || value === "active" || value === "archived";
}

export default async function ProductsPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const params = await searchParams;
  const search = params.q?.trim() ?? "";
  const categoryId = params.kategori ?? "";
  const brandId = params.marka ?? "";
  const status = isProductStatus(params.durum) ? params.durum : undefined;

  const { caps } = await loadCatalogContext();

  const [products, categories, brands] = await Promise.all([
    listProducts({ search, categoryId: categoryId || undefined, brandId: brandId || undefined, status }),
    listCategories(),
    listBrands(),
  ]);

  const hasFilter = Boolean(search || categoryId || brandId || status);

  return (
    <div className="space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h2 className="font-serif text-xl leading-tight tracking-tightish">Ürünler</h2>
          <p className="mt-1 text-xs text-muted">
            Ürün modelleri ve satılabilir varyantları. Stok miktarı bu ekranda tutulmaz; mal kabulle gelir.
          </p>
        </div>
        {caps.canEditCatalog ? (
          <Link href="/app/urunler/yeni">
            <Button size="sm">Yeni ürün</Button>
          </Link>
        ) : null}
      </header>

      <form method="get" className="grid gap-3 border-y border-line py-4 sm:grid-cols-2 lg:grid-cols-5">
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="q">Ara</Label>
          <Input id="q" name="q" defaultValue={search} placeholder="Ürün adı veya SKU ön eki" spellCheck={false} />
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
          <Label htmlFor="durum">Durum</Label>
          <Select id="durum" name="durum" defaultValue={status ?? ""}>
            <option value="">Tümü</option>
            {Object.entries(PRODUCT_STATUS_LABELS).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </Select>
        </div>

        <div className="flex items-center gap-3 sm:col-span-2 lg:col-span-5">
          <Button type="submit" size="sm" variant="outline">
            Filtrele
          </Button>
          {hasFilter ? (
            <Link href="/app/urunler" className="text-xs text-muted underline underline-offset-2 hover:text-ink">
              Filtreleri temizle
            </Link>
          ) : null}
        </div>
      </form>

      {products.length === 0 ? (
        <div className="border border-dashed border-line-strong px-6 py-12 text-center">
          <p className="text-sm text-ink-70">
            {hasFilter ? "Bu filtrelere uyan ürün yok." : "Henüz ürün eklenmemiş."}
          </p>
          <p className="mt-1 text-xs text-muted">
            {hasFilter
              ? "Aramayı daraltmayı ya da filtreleri temizlemeyi deneyin."
              : "İlk ürünü ekleyerek başlayın; varyantları ürün eklendikten sonra tanımlarsınız."}
          </p>
        </div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[46rem] border-collapse text-sm">
            <thead>
              <tr className="border-y border-line text-left text-xs text-muted">
                <th scope="col" className="py-2 pr-4 font-medium">Ürün</th>
                <th scope="col" className="py-2 pr-4 font-medium">Kategori</th>
                <th scope="col" className="py-2 pr-4 font-medium">Marka</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Varyant</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Fiyat</th>
                <th scope="col" className="py-2 font-medium">Durum</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {products.map((product) => (
                <tr key={product.id} className="transition-colors hover:bg-panel/60">
                  <td className="py-2.5 pr-4">
                    <Link
                      href={`/app/urunler/${product.id}`}
                      className="font-medium text-ink underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
                    >
                      {product.name}
                    </Link>
                    <span className="mt-0.5 block text-2xs text-muted" data-numeric>
                      {product.sku_prefix}
                    </span>
                  </td>
                  <td className="py-2.5 pr-4 text-ink-70">{product.category?.name ?? "—"}</td>
                  <td className="py-2.5 pr-4 text-ink-70">{product.brand?.name ?? "—"}</td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                    {product.variant_count}
                  </td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                    {product.variant_count === 0
                      ? formatPrice(product.default_sale_price)
                      : formatPriceRange(product.price_min, product.price_max)}
                  </td>
                  <td className="py-2.5">
                    <StatusPill status={product.status} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="mt-3 text-2xs text-muted">
            {products.length} ürün listeleniyor{products.length === 200 ? " (ilk 200)" : ""}.
          </p>
        </div>
      )}
    </div>
  );
}
