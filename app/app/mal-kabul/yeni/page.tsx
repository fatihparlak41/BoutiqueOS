import Link from "next/link";
import { redirect } from "next/navigation";
import { listBranches, listSuppliers, loadFxHints, loadReceivingContext } from "@/lib/receiving/queries";
import { ReceiptCreateForm } from "@/components/receiving/receipt-create-form";
import { Button } from "@/components/ui/button";

export const metadata = { title: "Yeni mal kabul · BoutiqueOS" };

export default async function NewReceiptPage() {
  const { caps, branchId } = await loadReceivingContext();
  if (!caps.canWriteReceipt) redirect("/app/mal-kabul");

  const today = new Date().toISOString().slice(0, 10);
  const [suppliers, branches, fxHints] = await Promise.all([
    listSuppliers({ status: "active" }),
    listBranches(),
    loadFxHints(today),
  ]);

  return (
    <div className="max-w-3xl space-y-6">
      <header>
        <Link href="/app/mal-kabul" className="text-xs text-muted underline-offset-2 hover:underline">
          ← Mal kabul
        </Link>
        <h2 className="mt-2 font-serif text-xl leading-tight tracking-tightish">Yeni mal kabul</h2>
        <p className="mt-1 text-xs text-muted">
          Önce belge başlığı kaydedilir. Satırlar ve işleme adımı bir sonraki ekranda yapılır.
        </p>
      </header>

      <ol className="flex flex-wrap gap-x-5 gap-y-1 border-y border-line py-2.5 text-2xs text-muted">
        <li className="font-medium text-ink">1. Belge başlığı</li>
        <li>2. Satırlar</li>
        <li>3. Kontrol</li>
        <li>4. İşle</li>
      </ol>

      {suppliers.length === 0 ? (
        <div className="border border-dashed border-line-strong px-6 py-12 text-center">
          <p className="text-sm text-ink-70">Aktif tedarikçi yok.</p>
          <p className="mt-1 text-xs text-muted">
            Mal kabul belgesi bir tedarikçiye bağlanmak zorunda; önce tedarikçi tanımlayın.
          </p>
          {caps.canWriteSupplier ? (
            <Link href="/app/tedarikciler/yeni" className="mt-4 inline-block">
              <Button size="sm" variant="outline">
                Tedarikçi ekle
              </Button>
            </Link>
          ) : null}
        </div>
      ) : branches.length === 0 ? (
        <div className="border border-dashed border-line-strong px-6 py-12 text-center">
          <p className="text-sm text-ink-70">Aktif şube yok.</p>
          <p className="mt-1 text-xs text-muted">Mal kabul için en az bir aktif şube gerekir.</p>
        </div>
      ) : (
        <ReceiptCreateForm
          suppliers={suppliers}
          branches={branches}
          defaultBranchId={branchId ?? branches[0]?.id ?? null}
          fxHints={fxHints}
          today={today}
        />
      )}
    </div>
  );
}
