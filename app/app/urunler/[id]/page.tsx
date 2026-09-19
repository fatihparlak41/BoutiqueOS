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
import { PageHeader } from "@/components/ui/page-header";
import { SectionHeader } from "@/components/ui/section-header";
import { Stat, StatGrid } from "@/components/ui/stat";
import { EmptyState } from "@/components/ui/empty-state";
import { ProductThumb } from "@/components/catalog/product-thumb";
import { StatusPill } from "@/components/catalog/status-pill";
import { SimilarProducts } from "@/components/catalog/similar-products";
import { VariantMatrix } from "@/components/catalog/variant-matrix";
import { MatrixBuilder } from "@/components/catalog/matrix-builder";
import { ImageManager } from "@/components/catalog/image-manager";
import { ProductForm } from "@/components/catalog/product-form";
import { OptionManager } from "@/components/catalog/option-manager";
import { VariantManager } from "@/components/catalog/variant-manager";
import { BrandQuickAdd } from "@/components/catalog/brand-quick-add";
import { ArchiveToggle } from "./archive-toggle";

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

  const { caps, branchId } = await loadCatalogContext();
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
  const available = stockRows.reduce((sum, r) => sum + r.available, 0);
  const totalBarcodes = product.variants.reduce((n, v) => n + v.barcodes.length, 0);
  const colours = new Set(product.variants.flatMap((v) => v.options.filter((o) => o.option_kind === "color").map((o) => o.value_id)));
  const sizes = new Set(product.variants.flatMap((v) => v.options.filter((o) => o.option_kind === "size").map((o) => o.value_id)));

  return (
    <div className="space-y-10">
      <PageHeader
        eyebrow={{ href: "/app/urunler", label: "Ürünler" }}
        title={
          <span className="flex items-center gap-4">
            <ProductThumb url={main?.url ?? null} alt={product.name} size="md" />
            <span className="min-w-0">
              <span className="block">{product.name}</span>
              <span className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs font-normal text-text-muted">
                {product.style_code ? <span data-numeric>{product.style_code}</span> : null}
                <span data-numeric>{product.sku_prefix}</span>
                <span>{product.category?.name ?? "Kategorisiz"}</span>
                {product.brand ? <span>{product.brand.name}</span> : null}
                <StatusPill status={product.status} />
              </span>
            </span>
          </span>
        }
        actions={caps.canEditCatalog ? <ArchiveToggle productId={product.id} status={product.status} /> : undefined}
      />

      {similar.length > 0 ? <SimilarProducts items={similar} /> : null}

      {product.status === "archived" ? (
        <Notice tone="info" data-testid="archived-notice">
          <span className="font-medium text-text-primary">Bu ürün arşivde.</span> Satış ekranlarında ve ürün seçimlerinde görünmez; geçmiş kayıtları ve
          {available > 0 || (valuation && valuation.on_hand > 0) ? " kalan stoğu defterde durur." : " stok geçmişi defterde durur."}
        </Notice>
      ) : null}

      <section className="space-y-3">
        <SectionHeader title="Özet" />
        <StatGrid>
          <Stat label="Aktif varyant" value={activeVariants.length} hint={`${product.variants.length} toplam`} />
          <Stat label="Renk × beden" value={`${colours.size} × ${sizes.size}`} hint={colours.size === 0 && sizes.size === 0 ? "seçeneksiz" : undefined} />
          <Stat label="Uygun stok" value={available} hint={stockRows[0]?.branch_name ?? "şube"} href="/app/stok" />
          {valuation ? (
            <Stat label="Stok değeri" value={fmtMoney(valuation.value)} hint={`${valuation.on_hand} adet · maliyet havuzu${product.status === "archived" ? " · arşivde olsa da" : ""}`} />
          ) : (
            <Stat label="Satış fiyatı" value={prices.length > 0 ? formatPriceRange(Math.min(...prices), Math.max(...prices)) : formatPrice(product.default_sale_price)} hint={`${totalBarcodes} barkod`} />
          )}
        </StatGrid>
      </section>

      {intel ? <ProductIntel intel={intel} productId={product.id} archived={product.status === "archived"} /> : null}

      <section className="space-y-3">
        <SectionHeader title="Varyantlar" meta={product.variants.length} />
        {product.variants.length === 0 ? (
          <EmptyState
            compact
            title="Henüz varyant yok"
            description={caps.canEditCatalog ? "Aşağıdaki matristen renk ve bedenleri seçip tek seferde oluşturun." : "Varyantlar işletme sahibi ya da yönetici tarafından tanımlanır."}
          />
        ) : (
          <VariantMatrix variants={product.variants} images={product.images} stock={stockRows} defaultPrice={product.default_sale_price} />
        )}
      </section>

      {caps.canEditCatalog ? (
        <section className="space-y-3">
          <SectionHeader title="Varyant ekle" />
          <p className="max-w-prose text-xs leading-relaxed text-text-muted">
            Ürünün geldiği renk ve bedenleri işaretleyin; kombinasyonlar otomatik üretilir, olmayanları kapatın.
            Tek beden ya da tek renk ürünlerde yalnız ilgili seçeneği seçin; seçeneksiz ürünler tek varyant alır.
          </p>
          <MatrixBuilder productId={product.id} skuPrefix={product.sku_prefix} options={options} existing={product.variants} />
        </section>
      ) : null}

      <section className="space-y-3">
        <SectionHeader title="Görseller" meta={product.images.length} />
        <ImageManager productId={product.id} images={product.images} variants={product.variants} canEdit={caps.canEditCatalog} />
      </section>

      <section className="space-y-3">
        <SectionHeader title="Temel bilgiler" />
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

      {caps.canEditCatalog ? (
        <section className="space-y-3">
          <SectionHeader title="Seçenekler" meta="işletme geneli" />
          <OptionManager options={options} canEdit={caps.canEditCatalog} />
        </section>
      ) : null}

      {product.variants.length > 0 && (caps.canEditCatalog || caps.canManageBarcodes) ? (
        <section className="space-y-3">
          <SectionHeader title="Varyant düzenleme ve barkodlar" />
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
    </div>
  );
}
