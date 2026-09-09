import Link from "next/link";
import { notFound } from "next/navigation";
import {
  getProduct,
  listBrands,
  listCategories,
  listProductOptions,
  loadCatalogContext,
} from "@/lib/catalog/queries";
import { formatPrice } from "@/lib/catalog/format";
import { updateProductAction } from "@/app/app/urunler/actions";
import { ProductForm } from "@/components/catalog/product-form";
import { OptionManager } from "@/components/catalog/option-manager";
import { VariantManager } from "@/components/catalog/variant-manager";
import { StatusPill } from "@/components/catalog/status-pill";
import { BrandQuickAdd } from "@/components/catalog/brand-quick-add";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const metadata = { title: "Ürün · BoutiqueOS" };

export default async function ProductDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();

  const { caps } = await loadCatalogContext();
  const product = await getProduct(id);
  // RLS scopes the query to the tenant, so a product from another business reads as missing.
  if (!product) notFound();

  const [options, categories, brands] = await Promise.all([
    listProductOptions(),
    listCategories(),
    listBrands(),
  ]);

  return (
    <div className="max-w-4xl space-y-10">
      <header>
        <Link href="/app/urunler" className="text-xs text-muted underline-offset-2 hover:underline">
          ← Ürünler
        </Link>
        <div className="mt-2 flex flex-wrap items-center gap-3">
          <h2 className="font-serif text-xl leading-tight tracking-tightish">{product.name}</h2>
          <StatusPill status={product.status} />
        </div>
        <p className="mt-1 flex flex-wrap gap-x-3 text-xs text-muted">
          <span data-numeric>{product.sku_prefix}</span>
          <span>{product.category?.name ?? "Kategorisiz"}</span>
          <span>{product.brand?.name ?? "Markasız"}</span>
          <span data-numeric>{formatPrice(product.default_sale_price)}</span>
          <span>{product.variants.length} varyant</span>
        </p>
      </header>

      <section className="space-y-4">
        <h3 className="text-sm font-medium tracking-tightish">Temel bilgiler</h3>
        {caps.canEditCatalog ? (
          <ProductForm
            action={updateProductAction}
            categories={categories}
            brands={brands}
            product={product}
            submitLabel="Değişiklikleri kaydet"
            pendingLabel="Kaydediliyor…"
          />
        ) : (
          <dl className="divide-y divide-line border-y border-line text-sm">
            <div className="flex justify-between gap-6 py-2.5">
              <dt className="text-muted">Satış fiyatı</dt>
              <dd data-numeric>{formatPrice(product.default_sale_price)}</dd>
            </div>
            <div className="flex justify-between gap-6 py-2.5">
              <dt className="text-muted">KDV</dt>
              <dd data-numeric>
                %{product.tax_rate} {product.is_tax_inclusive ? "(dahil)" : "(hariç)"}
              </dd>
            </div>
            <div className="flex justify-between gap-6 py-2.5">
              <dt className="text-muted">Koleksiyon</dt>
              <dd>{product.collection ?? "—"}</dd>
            </div>
            {product.description ? (
              <div className="py-2.5">
                <dt className="text-muted">Açıklama</dt>
                <dd className="mt-1 leading-relaxed">{product.description}</dd>
              </div>
            ) : null}
          </dl>
        )}
        {caps.canEditCatalog ? <BrandQuickAdd /> : null}
      </section>

      <OptionManager options={options} canEdit={caps.canEditCatalog} />

      <VariantManager
        productId={product.id}
        skuPrefix={product.sku_prefix}
        defaultPrice={product.default_sale_price}
        options={options}
        variants={product.variants}
        canEdit={caps.canEditCatalog}
        canManageBarcodes={caps.canManageBarcodes}
      />
    </div>
  );
}
