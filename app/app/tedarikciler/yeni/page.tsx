import Link from "next/link";
import { redirect } from "next/navigation";
import { loadReceivingContext } from "@/lib/receiving/queries";
import { createSupplierAction } from "@/app/app/tedarikciler/actions";
import { SupplierForm } from "@/components/receiving/supplier-form";

export const metadata = { title: "Yeni tedarikçi · BoutiqueOS" };

export default async function NewSupplierPage() {
  const { caps } = await loadReceivingContext();
  // Read access alone must not reach the create screen; RLS would refuse the insert anyway.
  if (!caps.canWriteSupplier) redirect("/app/tedarikciler");

  return (
    <div className="max-w-3xl space-y-6">
      <header>
        <Link href="/app/tedarikciler" className="text-xs text-muted underline-offset-2 hover:underline">
          ← Tedarikçiler
        </Link>
        <h2 className="mt-2 font-serif text-xl leading-tight tracking-tightish">Yeni tedarikçi</h2>
        <p className="mt-1 text-xs text-muted">
          Varsayılan para birimi mal kabul belgesinde ön seçili gelir; belge bazında değiştirilebilir.
        </p>
      </header>

      <SupplierForm
        action={createSupplierAction}
        submitLabel="Tedarikçiyi kaydet"
        pendingLabel="Kaydediliyor…"
      />
    </div>
  );
}
