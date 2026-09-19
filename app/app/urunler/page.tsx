import Link from "next/link";
import { Plus, Shirt } from "lucide-react";
import {
  listProducts,
  listCategories,
  listBrands,
  loadCatalogContext,
  resolveBarcode,
  type ProductStatus,
} from "@/lib/catalog/queries";
import { Button } from "@/components/ui/button";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";
import { BarcodeLookup } from "@/components/catalog/barcode-lookup";
import { ProductFilters } from "@/components/catalog/product-filters";
import { ProductList } from "@/components/catalog/product-list";
import { AdvancedAddMenu } from "@/components/catalog/advanced-add-menu";

export const metadata = { title: "Ürünler · BoutiqueOS" };

type SearchParams = {
  q?: string;
  kategori?: string;
  marka?: string;
  durum?: string;
  barkod?: string;
};

function isProductStatus(value: string | undefined): value is ProductStatus {
  return value === "draft" || value === "active" || value === "archived";
}

/**
 * Products: one primary action ("Ürün ekle" → the guided flow), a search field, filters
 * behind a button, and the list. The legacy form (/app/urunler/yeni) stays reachable as
 * "Gelişmiş ürün ekleme" in the quiet menu next to the primary action.
 */
export default async function ProductsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const search = params.q?.trim() ?? "";
  const categoryId = params.kategori ?? "";
  const brandId = params.marka ?? "";
  const status = isProductStatus(params.durum) ? params.durum : undefined;

  const { caps } = await loadCatalogContext();
  // a scanned code typed into the search box resolves like the old barcode field did
  const barcode = params.barkod?.trim() || (search && /^[0-9A-Za-z-]{6,}$/.test(search) && /\d/.test(search) ? search : "");

  const [products, categories, brands, hit] = await Promise.all([
    listProducts({ search, categoryId: categoryId || undefined, brandId: brandId || undefined, status }),
    listCategories(),
    listBrands(),
    barcode ? resolveBarcode(barcode) : Promise.resolve(null),
  ]);

  const hasFilter = Boolean(search || categoryId || brandId || status);

  return (
    <div className="space-y-5">
      <PageHeader
        title="Ürünler"
        actions={
          caps.canEditCatalog ? (
            <>
              <Link href="/app/urunler/katalog-ekle" data-testid="primary-add-product">
                <Button variant="accent">
                  <Plus aria-hidden className="h-4 w-4" />
                  Ürün ekle
                </Button>
              </Link>
              <AdvancedAddMenu />
            </>
          ) : undefined
        }
      />

      {barcode && hit ? <BarcodeLookup code={barcode} hit={hit} showForm={false} /> : null}

      {products.length === 0 && !hasFilter ? (
        <EmptyState
          editorial
          icon={<Shirt />}
          title="İlk ürününü ekle"
          description="Ürünlerini, renklerini ve bedenlerini birkaç adımda oluştur."
          action={
            caps.canEditCatalog ? (
              <Link href="/app/urunler/katalog-ekle">
                <Button variant="accent" size="lg">
                  <Plus aria-hidden className="h-4 w-4" />
                  Ürün ekle
                </Button>
              </Link>
            ) : undefined
          }
        />
      ) : (
        <>
          <ProductFilters search={search} categoryId={categoryId} brandId={brandId} status={status ?? ""} categories={categories} brands={brands} />
          {products.length === 0 ? (
            <EmptyState compact title="Bu aramaya uyan ürün yok" description="Yazımı kontrol et ya da filtreleri temizle." action={<Link href="/app/urunler"><Button variant="outline" size="sm">Filtreleri temizle</Button></Link>} />
          ) : (
            <ProductList products={products} canEdit={caps.canEditCatalog} footer={`${products.length} ürün${products.length === 200 ? " (ilk 200)" : ""}`} />
          )}
        </>
      )}
    </div>
  );
}
