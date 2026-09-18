import { redirect } from "next/navigation";
import { loadPoContext } from "@/lib/po/queries";
import { listBranches, listSuppliers, variantSiblings } from "@/lib/receiving/queries";
import { PageHeader } from "@/components/ui/page-header";
import { PoCreateForm } from "@/components/po/po-create-form";
import { EmptyState } from "@/components/ui/empty-state";

export const metadata = { title: "Yeni sipariş · BoutiqueOS" };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** New draft PO. `?varyant=&neden=` comes from the intelligence page: it only prefills the picker on the next screen. */
export default async function NewPurchaseOrderPage({ searchParams }: { searchParams: Promise<{ varyant?: string; neden?: string }> }) {
  const params = await searchParams;
  const { caps, branchId } = await loadPoContext();
  if (!caps.canManage) redirect("/app/satin-alma");
  const prefillId = params.varyant && UUID.test(params.varyant) ? params.varyant : null;
  const [suppliers, branches, siblings] = await Promise.all([listSuppliers({ status: "active" }), listBranches(), prefillId ? variantSiblings(prefillId) : Promise.resolve([])]);
  const picked = siblings.find((v) => v.variant_id === prefillId) ?? null;
  const today = new Date().toISOString().slice(0, 10);
  return (
    <div className="space-y-8">
      <PageHeader eyebrow={{ href: "/app/satin-alma", label: "Satın alma siparişleri" }} title="Yeni sipariş" description="Taslak açılır; satırlar sonraki ekranda eklenir. Sipariş numarası sunucuda verilir." />
      {suppliers.length === 0 ? (
        <EmptyState compact title="Aktif tedarikçi yok" description="Önce Tedarikçiler bölümünden bir tedarikçi tanımlayın." />
      ) : (
        <PoCreateForm
          suppliers={suppliers}
          branches={branches}
          defaultBranchId={branchId ?? branches[0]?.id ?? null}
          today={today}
          prefill={prefillId ? { variantId: prefillId, why: params.neden?.slice(0, 200) ?? null, label: picked ? `${picked.product_name} · ${picked.sku}` : null } : null}
        />
      )}
    </div>
  );
}
