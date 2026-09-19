import { redirect } from "next/navigation";
import { listBrands, listCategoryTree, listProductOptions, loadCatalogContext } from "@/lib/catalog/queries";
import { PageHeader } from "@/components/ui/page-header";
import { IntakeWizard } from "@/components/catalog/intake/intake-wizard";

export const metadata = { title: "Ürün ekle · BoutiqueOS" };

/**
 * Physical catalogue intake: the person stands in the shop with the garment and enters
 * only what the label and the piece itself show. Product master only — no quantity,
 * no cost, no receipt. Manager and owner; RLS refuses everyone else anyway.
 */
export default async function CatalogIntakePage() {
  const { caps } = await loadCatalogContext();
  if (!caps.canEditCatalog) redirect("/app/urunler");

  const [options, categories, brands] = await Promise.all([listProductOptions(), listCategoryTree(), listBrands()]);

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <PageHeader eyebrow={{ href: "/app/urunler", label: "Ürünler" }} title="Ürün ekle" description="Fotoğraf, ad, renk ve bedenler. Stok sonra sayımla girilir." />
      <IntakeWizard initialOptions={options} initialCategories={categories} brands={brands} />
    </div>
  );
}
