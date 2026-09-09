import Link from "next/link";
import { redirect } from "next/navigation";
import { listReceipts, listSuppliers, loadReceivingContext } from "@/lib/receiving/queries";
import { RECEIPT_STATUS_LABELS, type ReceiptStatus } from "@/lib/receiving/model";
import { formatDate, formatMoney, formatQuantity } from "@/lib/receiving/format";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { ReceiptStatusPill } from "@/components/receiving/receipt-status-pill";

export const metadata = { title: "Mal kabul · BoutiqueOS" };

function isStatus(value: string | undefined): value is ReceiptStatus {
  return value === "draft" || value === "posted" || value === "cancelled";
}

export default async function ReceiptsPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; durum?: string; tedarikci?: string; baslangic?: string; bitis?: string }>;
}) {
  const { caps } = await loadReceivingContext();
  // pol_gr_select is fn_is_procurement: sales_staff cannot read receiving at all.
  if (!caps.canRead) redirect("/app");

  const params = await searchParams;
  const search = params.q?.trim() ?? "";
  const status = isStatus(params.durum) ? params.durum : undefined;
  const supplierId = params.tedarikci ?? "";
  const from = params.baslangic ?? "";
  const to = params.bitis ?? "";

  const [receipts, suppliers] = await Promise.all([
    listReceipts({ search, status, supplierId: supplierId || undefined, from: from || undefined, to: to || undefined }),
    listSuppliers(),
  ]);

  const hasFilter = Boolean(search || status || supplierId || from || to);

  return (
    <div className="space-y-6">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h2 className="font-serif text-xl leading-tight tracking-tightish">Mal kabul</h2>
          <p className="mt-1 text-xs text-muted">
            Stok yalnız işlenmiş belgelerle oluşur. Taslak belgeler stoğu etkilemez.
          </p>
        </div>
        {caps.canWriteReceipt ? (
          <Link href="/app/mal-kabul/yeni">
            <Button size="sm">Yeni mal kabul</Button>
          </Link>
        ) : null}
      </header>

      <form method="get" className="grid gap-3 border-y border-line py-4 sm:grid-cols-2 lg:grid-cols-5">
        <div className="space-y-1.5 lg:col-span-2">
          <Label htmlFor="q">Ara</Label>
          <Input id="q" name="q" defaultValue={search} placeholder="Belge no veya referans" spellCheck={false} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="durum">Durum</Label>
          <Select id="durum" name="durum" defaultValue={status ?? ""}>
            <option value="">Tümü</option>
            {Object.entries(RECEIPT_STATUS_LABELS).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </Select>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="tedarikci">Tedarikçi</Label>
          <Select id="tedarikci" name="tedarikci" defaultValue={supplierId}>
            <option value="">Tümü</option>
            {suppliers.map((supplier) => (
              <option key={supplier.id} value={supplier.id}>
                {supplier.name}
              </option>
            ))}
          </Select>
        </div>
        <div className="grid grid-cols-2 gap-2">
          <div className="space-y-1.5">
            <Label htmlFor="baslangic">Başlangıç</Label>
            <Input id="baslangic" name="baslangic" type="date" defaultValue={from} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="bitis">Bitiş</Label>
            <Input id="bitis" name="bitis" type="date" defaultValue={to} />
          </div>
        </div>
        <div className="flex items-center gap-3 sm:col-span-2 lg:col-span-5">
          <Button type="submit" size="sm" variant="outline">
            Filtrele
          </Button>
          {hasFilter ? (
            <Link href="/app/mal-kabul" className="text-xs text-muted underline underline-offset-2 hover:text-ink">
              Filtreleri temizle
            </Link>
          ) : null}
        </div>
      </form>

      {receipts.length === 0 ? (
        <div className="border border-dashed border-line-strong px-6 py-12 text-center">
          <p className="text-sm text-ink-70">
            {hasFilter ? "Bu filtrelere uyan belge yok." : "Henüz mal kabul belgesi yok."}
          </p>
          <p className="mt-1 text-xs text-muted">
            {hasFilter
              ? "Aramayı daraltmayı ya da filtreleri temizlemeyi deneyin."
              : "Yeni bir belge açıp satırları girdikten sonra işleyerek stoğa alabilirsiniz."}
          </p>
        </div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[56rem] border-collapse text-sm">
            <thead>
              <tr className="border-y border-line text-left text-xs text-muted">
                <th scope="col" className="py-2 pr-4 font-medium">Belge</th>
                <th scope="col" className="py-2 pr-4 font-medium">Tarih</th>
                <th scope="col" className="py-2 pr-4 font-medium">Tedarikçi</th>
                <th scope="col" className="py-2 pr-4 font-medium">Şube</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Satır</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Adet</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Tutar</th>
                <th scope="col" className="py-2 font-medium">Durum</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {receipts.map((receipt) => (
                <tr key={receipt.id} className="transition-colors hover:bg-panel/60">
                  <td className="py-2.5 pr-4">
                    <Link
                      href={`/app/mal-kabul/${receipt.id}`}
                      className="font-medium text-ink underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
                      data-numeric
                    >
                      {receipt.receipt_number}
                    </Link>
                    {receipt.document_ref ? (
                      <span className="mt-0.5 block text-2xs text-muted">{receipt.document_ref}</span>
                    ) : null}
                  </td>
                  <td className="py-2.5 pr-4 text-ink-70" data-numeric>
                    {formatDate(receipt.received_at)}
                  </td>
                  <td className="py-2.5 pr-4 text-ink-70">{receipt.supplier_name}</td>
                  <td className="py-2.5 pr-4 text-ink-70">{receipt.branch_name}</td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                    {receipt.line_count}
                  </td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                    {formatQuantity(receipt.total_quantity)}
                  </td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                    {formatMoney(receipt.total_original, receipt.invoice_currency)}
                  </td>
                  <td className="py-2.5">
                    <ReceiptStatusPill status={receipt.status} />
                    {receipt.posted_at ? (
                      <span className="mt-0.5 block text-2xs text-muted" data-numeric>
                        {formatDate(receipt.posted_at)}
                      </span>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="mt-3 text-2xs text-muted">{receipts.length} belge listeleniyor.</p>
        </div>
      )}
    </div>
  );
}
