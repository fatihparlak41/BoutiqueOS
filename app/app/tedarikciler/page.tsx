import Link from "next/link";
import { redirect } from "next/navigation";
import { listSuppliers, loadReceivingContext } from "@/lib/receiving/queries";
import { SUPPLIER_STATUS_LABELS, type SupplierStatus } from "@/lib/receiving/model";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { SupplierList } from "@/components/receiving/supplier-list";

export const metadata = { title: "Tedarikçiler · BoutiqueOS" };

function isStatus(value: string | undefined): value is SupplierStatus {
  return value === "active" || value === "inactive";
}

export default async function SuppliersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; durum?: string }>;
}) {
  const { caps } = await loadReceivingContext();
  // pol_suppliers_select is fn_is_procurement: sales_staff has no read access at all.
  if (!caps.canRead) redirect("/app");

  const params = await searchParams;
  const search = params.q?.trim() ?? "";
  const status = isStatus(params.durum) ? params.durum : undefined;

  const suppliers = await listSuppliers({ search, status });
  const hasFilter = Boolean(search || status);

  return (
    <div className="space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h2 className="font-serif text-xl leading-tight tracking-tightish">Tedarikçiler</h2>
          <p className="mt-1 text-xs text-muted">
            Mal kabul belgeleri bu listedeki aktif tedarikçilere bağlanır.
          </p>
        </div>
        {caps.canWriteSupplier ? (
          <Link href="/app/tedarikciler/yeni">
            <Button size="sm">Yeni tedarikçi</Button>
          </Link>
        ) : null}
      </header>

      <form method="get" className="grid gap-3 border-y border-line py-4 sm:grid-cols-3">
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="q">Ara</Label>
          <Input id="q" name="q" defaultValue={search} placeholder="Tedarikçi adı veya kodu" spellCheck={false} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="durum">Durum</Label>
          <Select id="durum" name="durum" defaultValue={status ?? ""}>
            <option value="">Tümü</option>
            {Object.entries(SUPPLIER_STATUS_LABELS).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </Select>
        </div>
        <div className="flex items-center gap-3 sm:col-span-3">
          <Button type="submit" size="sm" variant="outline">
            Filtrele
          </Button>
          {hasFilter ? (
            <Link href="/app/tedarikciler" className="text-xs text-muted underline underline-offset-2 hover:text-ink">
              Filtreleri temizle
            </Link>
          ) : null}
        </div>
      </form>

      {suppliers.length === 0 ? (
        <div className="border border-dashed border-line-strong px-6 py-12 text-center">
          <p className="text-sm text-ink-70">
            {hasFilter ? "Bu filtrelere uyan tedarikçi yok." : "Henüz tedarikçi eklenmemiş."}
          </p>
          <p className="mt-1 text-xs text-muted">
            {hasFilter
              ? "Aramayı daraltmayı ya da filtreleri temizlemeyi deneyin."
              : "Mal kabul yapabilmek için önce en az bir tedarikçi tanımlayın."}
          </p>
        </div>
      ) : (
        <>
          <SupplierList suppliers={suppliers} canEdit={caps.canWriteSupplier} />
          <p className="text-2xs text-muted">{suppliers.length} tedarikçi listeleniyor.</p>
        </>
      )}
    </div>
  );
}
