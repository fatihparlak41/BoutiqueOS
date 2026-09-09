import Link from "next/link";
import { redirect } from "next/navigation";
import { listCategories, listBrands, loadCatalogContext } from "@/lib/catalog/queries";
import { createProductAction } from "@/app/app/urunler/actions";
import { ProductForm } from "@/components/catalog/product-form";
import { BrandQuickAdd } from "@/components/catalog/brand-quick-add";

export const metadata = { title: "Yeni ürün · BoutiqueOS" };

export default async function NewProductPage() {
  const { caps } = await loadCatalogContext();
  // Read access alone must not reach the create screen; RLS would refuse the insert anyway.
  if (!caps.canEditCatalog) redirect("/app/urunler");

  const [categories, brands] = await Promise.all([listCategories(), listBrands()]);

  return (
    <div className="max-w-3xl space-y-6">
      <header>
        <Link href="/app/urunler" className="text-xs text-muted underline-offset-2 hover:underline">
          ← Ürünler
        </Link>
        <h2 className="mt-2 font-serif text-xl leading-tight tracking-tightish">Yeni ürün</h2>
        <p className="mt-1 text-xs text-muted">
          Önce ürünün temel bilgileri kaydedilir. Seçenekler, varyantlar ve barkodlar bir sonraki
          adımda, ürün sayfasında tanımlanır.
        </p>
      </header>

      <ol className="flex flex-wrap gap-x-5 gap-y-1 border-y border-line py-2.5 text-2xs text-muted">
        <li className="font-medium text-ink">1. Temel bilgiler</li>
        <li>2. Seçenekler</li>
        <li>3. Varyantlar</li>
        <li>4. Fiyat</li>
        <li>5. Barkod</li>
      </ol>

      <ProductForm
        action={createProductAction}
        categories={categories}
        brands={brands}
        submitLabel="Kaydet ve devam et"
        pendingLabel="Kaydediliyor…"
      />

      <BrandQuickAdd />
    </div>
  );
}
