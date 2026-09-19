import { notFound } from "next/navigation";
import {
  findSimilarProducts,
  getProduct,
  listBrands,
  listCategories,
  listProductOptions,
  loadCatalogContext,
} from "@/lib/catalog/queries";
import { listStockForVariants, productInventoryValue } from "@/lib/stock/queries";
import { Notice } from "@/components/catalog/intake/primitives";
import { fmtMoney } from "@/components/reports/format";
import { getIntelProduct } from "@/lib/intel/queries";
import { ProductIntel } from "@/components/intel/product-intel";
import { formatPrice, formatPriceRange } from "@/lib/catalog/format";
import { updateProductAction } from "@/app/app/urunler/actions";
import Link from "next/link";
import { ProductHero } from "@/components/catalog/product-hero";
import { countCaps } from "@/lib/stock/count-model";
import { SectionHeader } from "@/components/ui/section-header";
import { EmptyState } from "@/components/ui/empty-state";
import { SimilarProducts } from "@/components/catalog/similar-products";
import { VariantMatrix } from "@/components/catalog/variant-matrix";
import { MatrixBuilder } from "@/components/catalog/matrix-builder";
import { ImageManager } from "@/components/catalog/image-manager";
import { ProductForm } from "@/components/catalog/product-form";
import { OptionManager } from "@/components/catalog/option-manager";
import { VariantManager } from "@/components/catalog/variant-manager";
import { BrandQuickAdd } from "@/components/catalog/brand-quick-add";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const metadata = { title: "Ürün · BoutiqueOS" };

/**
 * Product master screen. Header with the main image and identity; a summary; the sellable
 * matrix; then, for owners and managers, the tools that grow it: matrix builder, images,
 * basic data, options, per-variant editing. Cost is not on this screen in any role.
 */
export default async function ProductDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();

  const { caps, branchId, role } = await loadCatalogContext();
  const product = await getProduct(id);
  // RLS scopes the query to the tenant, so a product from another business reads as missing.
  if (!product) notFound();

  const [options, categories, brands, similar, stockRows, intel, valuation] = await Promise.all([
    listProductOptions(),
    listCategories(),
    listBrands(),
    caps.canEditCatalog ? findSimilarProducts({ name: product.name, styleCode: product.style_code, excludeId: product.id }) : Promise.resolve([]),
    // The stock screen's quantities for exactly this product's variants: same views, same RLS, one round trip.
    listStockForVariants(
      product.variants.map((v) => ({
        id: v.id, sku: v.sku,
        options: v.options.length > 0 ? v.options.map((o) => `${o.option_name}: ${o.value}`).join(" · ") : "Seçeneksiz",
        primary_barcode: v.barcodes.find((b) => b.is_primary)?.barcode ?? v.barcodes[0]?.barcode ?? null,
      })),
      { id: product.id, name: product.name, status: product.status, category_name: product.category?.name ?? null, brand_name: product.brand?.name ?? null },
    ),
    // Manager+ intelligence block: one aggregate RPC in the same round trip as the rest.
    caps.canEditCatalog ? getIntelProduct(product.id) : Promise.resolve(null),
    // The cost-pool valuation is read directly: archiving never erases owned inventory,
    // and the intelligence facts count only active products by design (they are sell signals).
    caps.canEditCatalog ? productInventoryValue(product.id, branchId) : Promise.resolve(null),
  ]);

  const main = product.images.find((i) => i.role === "product_main") ?? null;
  const activeVariants = product.variants.filter((v) => v.status === "active");
  const prices = activeVariants.map((v) => v.sale_price_override ?? product.default_sale_price);
  const priceLabel = prices.length > 0 ? formatPriceRange(Math.min(...prices), Math.max(...prices)) : formatPrice(product.default_sale_price);
  const onHand = stockRows.reduce((sum, r) => sum + r.on_hand, 0);
  const reserved = stockRows.reduce((sum, r) => sum + r.reserved, 0);
  const available = stockRows.reduce((sum, r) => sum + r.available, 0);
  const damaged = stockRows.reduce((sum, r) => sum + r.damaged + r.quarantine, 0);
  const canCount = countCaps(role).canCount;

  return (
    <div className="space-y-10">
      <div className="text-xs text-text-muted"><Link href="/app/urunler" className="underline-offset-4 hover:text-text-primary hover:underline">Ürünler</Link></div>

      <ProductHero
        productId={product.id}
        name={product.name}
        price={priceLabel}
        category={product.category?.name ?? null}
        brand={product.brand?.name ?? null}
        styleCode={product.style_code}
        status={product.status}
        imageUrl={main?.url ?? null}
        canEdit={caps.canEditCatalog}
        canCount={canCount}
      />

      {similar.length > 0 ? <SimilarProducts items={similar} /> : null}

      {product.status === "archived" ? (
        <Notice tone="info" data-testid="archived-notice">
          <span className="font-medium text-text-primary">Bu ürün arşivde.</span> Satış ekranlarında ve ürün seçimlerinde görünmez; geçmiş kayıtları
          {onHand > 0 ? " ve kalan stoğu defterde durur." : " defterde durur."}
        </Notice>
      ) : null}

      {/* operational summary: what is on the shelf, what is held, what can be sold — plain words */}
      <section className="space-y-3" data-testid="stock-summary">
        <SectionHeader title="Stok" meta={stockRows[0]?.branch_name} />
        <dl className="flex flex-wrap gap-x-10 gap-y-3 border-y border-border py-4">
          <div><dt className="text-xs text-text-muted">Rafta</dt><dd className="mt-0.5 text-2xl font-medium leading-none text-text-primary" data-numeric>{onHand}</dd></div>
          <div><dt className="text-xs text-text-muted">Ayrılmış</dt><dd className="mt-0.5 text-2xl font-medium leading-none text-text-primary" data-numeric>{reserved}</dd></div>
          <div><dt className="text-xs text-text-muted">Satılabilir</dt><dd className="mt-0.5 text-2xl font-medium leading-none text-accent" data-numeric>{available}</dd></div>
          {damaged > 0 ? <div><dt className="text-xs text-text-muted">Hasarlı / karantina</dt><dd className="mt-0.5 text-2xl font-medium leading-none text-text-secondary" data-numeric>{damaged}</dd></div> : null}
          {valuation ? (
            <div className="ml-auto self-end text-right">
              <dt className="text-xs text-text-muted">Stok değeri</dt>
              <dd className="text-sm text-text-secondary" data-numeric>{fmtMoney(valuation.value)}{product.status === "archived" ? " · arşivde olsa da" : ""}</dd>
            </div>
          ) : null}
        </dl>
      </section>

      {intel ? <ProductIntel intel={intel} productId={product.id} archived={product.status === "archived"} hideValue={valuation !== null} /> : null}

      <section className="space-y-3">
        <SectionHeader title="Renkler ve bedenler" meta={product.variants.length} />
        {product.variants.length === 0 ? (
          <EmptyState
            compact
            title="Henüz renk ya da beden yok"
            description={caps.canEditCatalog ? "Aşağıdan ürünün geldiği renk ve bedenleri işaretle; seçenekler tek seferde oluşur." : "Renk ve bedenleri işletme sahibi ya da yönetici tanımlar."}
          />
        ) : (
          <VariantMatrix variants={product.variants} images={product.images} stock={stockRows} defaultPrice={product.default_sale_price} />
        )}
      </section>

      {caps.canEditCatalog ? (
        <section className="space-y-3">
          <SectionHeader title="Renk veya beden ekle" />
          <p className="max-w-prose text-xs leading-relaxed text-text-muted">Ürünün geldiği renk ve bedenleri işaretle; olmayan kombinasyonları kapat.</p>
          <MatrixBuilder productId={product.id} skuPrefix={product.sku_prefix} options={options} existing={product.variants} />
        </section>
      ) : null}

      <section className="space-y-3">
        <SectionHeader title="Fotoğraflar" meta={product.images.length} />
        <ImageManager productId={product.id} images={product.images} variants={product.variants} canEdit={caps.canEditCatalog} />
      </section>

      <section id="duzenle" className="scroll-mt-20 space-y-3">
        <SectionHeader title="Ürünü düzenle" />
        {caps.canEditCatalog ? (
          <>
            <ProductForm
              action={updateProductAction}
              categories={categories}
              brands={brands}
              product={product}
              submitLabel="Değişiklikleri kaydet"
              pendingLabel="Kaydediliyor…"
            />
            <BrandQuickAdd />
          </>
        ) : (
          <dl className="divide-y divide-border border-y border-border text-sm">
            <div className="flex justify-between gap-6 py-2.5">
              <dt className="text-text-muted">Satış fiyatı</dt>
              <dd data-numeric>{formatPrice(product.default_sale_price)}</dd>
            </div>
            <div className="flex justify-between gap-6 py-2.5">
              <dt className="text-text-muted">Koleksiyon</dt>
              <dd>{product.collection ?? "—"}</dd>
            </div>
            {product.description ? (
              <div className="py-2.5">
                <dt className="text-text-muted">Açıklama</dt>
                <dd className="mt-1 leading-relaxed">{product.description}</dd>
              </div>
            ) : null}
          </dl>
        )}
      </section>

      {caps.canEditCatalog || (product.variants.length > 0 && caps.canManageBarcodes) ? (
        <details className="group rounded border border-border bg-surface" data-testid="product-details">
          <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 px-4 text-sm font-medium text-text-primary">
            Ayrıntılar
            <span className="text-right text-xs font-normal text-text-muted">seçenek kodları, barkodlar, renk ve beden listesi</span>
          </summary>
          <div className="space-y-8 border-t border-border p-4">
            {product.variants.length > 0 && (caps.canEditCatalog || caps.canManageBarcodes) ? (
              <section className="space-y-3">
                <SectionHeader title="Seçenek kodları ve barkodlar" />
                <VariantManager
                  productId={product.id}
                  skuPrefix={product.sku_prefix}
                  defaultPrice={product.default_sale_price}
                  options={options}
                  variants={product.variants}
                  canEdit={caps.canEditCatalog}
                  canManageBarcodes={caps.canManageBarcodes}
                  showAddForm={false}
                />
              </section>
            ) : null}
            {caps.canEditCatalog ? (
              <section className="space-y-3">
                <SectionHeader title="Renk ve beden listesi" meta="işletme geneli" />
                <OptionManager options={options} canEdit={caps.canEditCatalog} />
              </section>
            ) : null}
          </div>
        </details>
      ) : null}
    </div>
  );
}
