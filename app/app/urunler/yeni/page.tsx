import { redirect } from "next/navigation";
import { listCategories, listBrands, loadCatalogContext } from "@/lib/catalog/queries";
import { createProductAction } from "@/app/app/urunler/actions";
import { PageHeader } from "@/components/ui/page-header";
import { ProductForm } from "@/components/catalog/product-form";
import { BrandQuickAdd } from "@/components/catalog/brand-quick-add";

export const metadata = { title: "Yeni ürün · BoutiqueOS" };

/**
 * Step 1 of the product workflow: the model. Saving lands on the product page, where
 * step 2 (colours and sizes → variant matrix), images and barcodes follow.
 */
export default async function NewProductPage() {
  const { caps } = await loadCatalogContext();
  // Read access alone must not reach the create screen; RLS would refuse the insert anyway.
  if (!caps.canEditCatalog) redirect("/app/urunler");

  const [categories, brands] = await Promise.all([listCategories(), listBrands()]);

  return (
    <div className="max-w-3xl space-y-6">
      <PageHeader
        eyebrow={{ href: "/app/urunler", label: "Ürünler" }}
        title="Yeni ürün"
        description="Önce modeli tanımlayın. Renk ve beden matrisi, görseller ve barkodlar kaydettikten sonra ürün sayfasında gelir."
      />

      <ol className="flex flex-wrap gap-x-5 gap-y-1 border-y border-border py-2.5 text-2xs text-text-muted">
        <li className="font-medium text-text-primary">1. Model</li>
        <li>2. Renk ve beden matrisi</li>
        <li>3. Görseller</li>
        <li>4. Barkodlar</li>
      </ol>

      <ProductForm
        action={createProductAction}
        categories={categories}
        brands={brands}
        submitLabel="Kaydet ve matrise geç"
        pendingLabel="Kaydediliyor…"
      />

      <BrandQuickAdd />
    </div>
  );
}
