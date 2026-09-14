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
import { PageHeader } from "@/components/ui/page-header";
import { FilterBar, FilterField } from "@/components/ui/filter-bar";
import { EmptyState } from "@/components/ui/empty-state";
import { CellTitle, TBody, TD, TH, THead, TR, TableShell, rowLinkClass } from "@/components/ui/table";
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
      <PageHeader
        title="Ürünler"
        description="Ürün modelleri ve satılabilir varyantları. Stok miktarı bu ekranda tutulmaz; mal kabulle gelir."
        actions={
          caps.canEditCatalog ? (
            <Link href="/app/urunler/yeni">
              <Button size="sm">Yeni ürün</Button>
            </Link>
          ) : undefined
        }
      />

      <FilterBar clearHref="/app/urunler" hasFilter={hasFilter}>
        <FilterField wide>
          <Label htmlFor="q">Ara</Label>
          <Input id="q" name="q" defaultValue={search} placeholder="Ürün adı veya SKU ön eki" spellCheck={false} />
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
          <Label htmlFor="durum">Durum</Label>
          <Select id="durum" name="durum" defaultValue={status ?? ""}>
            <option value="">Tümü</option>
            {Object.entries(PRODUCT_STATUS_LABELS).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </Select>
        </FilterField>
      </FilterBar>

      {products.length === 0 ? (
        hasFilter ? (
          <EmptyState
            compact
            title="Bu filtrelere uyan ürün yok"
            description="Aramayı daraltmayı ya da filtreleri temizlemeyi deneyin."
          />
        ) : (
          <EmptyState
            editorial
            title="Henüz ürün yok"
            description="İlk ürünü ekleyerek başlayın; varyantları ürün eklendikten sonra tanımlarsınız."
            action={
              caps.canEditCatalog ? (
                <Link href="/app/urunler/yeni">
                  <Button>İlk ürünü ekle</Button>
                </Link>
              ) : undefined
            }
          />
        )
      ) : (
        <TableShell
          minWidth="46rem"
          footer={`${products.length} ürün listeleniyor${products.length === 200 ? " (ilk 200)" : ""}.`}
        >
          <THead>
            <TH>Ürün</TH>
            <TH>Kategori</TH>
            <TH>Marka</TH>
            <TH align="right">Varyant</TH>
            <TH align="right">Fiyat</TH>
            <TH>Durum</TH>
          </THead>
          <TBody>
            {products.map((product) => (
              <TR key={product.id}>
                <TD>
                  <CellTitle sub={product.sku_prefix} subNumeric>
                    <Link href={`/app/urunler/${product.id}`} className={rowLinkClass}>
                      {product.name}
                    </Link>
                  </CellTitle>
                </TD>
                <TD muted>{product.category?.name ?? "—"}</TD>
                <TD muted>{product.brand?.name ?? "—"}</TD>
                <TD muted numeric align="right">{product.variant_count}</TD>
                <TD muted numeric align="right">
                  {product.variant_count === 0
                    ? formatPrice(product.default_sale_price)
                    : formatPriceRange(product.price_min, product.price_max)}
                </TD>
                <TD>
                  <StatusPill status={product.status} />
                </TD>
              </TR>
            ))}
          </TBody>
        </TableShell>
      )}
    </div>
  );
}
