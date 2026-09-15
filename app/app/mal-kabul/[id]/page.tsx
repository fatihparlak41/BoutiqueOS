import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { getAllocationPreview, getReceipt, listSuppliers, loadFxHints, loadReceivingContext } from "@/lib/receiving/queries";
import { formatDate, formatDateTime, formatMoney, formatQuantity, formatRate } from "@/lib/receiving/format";
import { ALLOCATION_LABELS } from "@/lib/receiving/model";
import { ReceiptStatusPill } from "@/components/receiving/receipt-status-pill";
import { ReceiptEditor } from "@/components/receiving/receipt-editor";
import { ChargesSection, ReversalPanel } from "@/components/receiving/landed-cost-panels";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const metadata = { title: "Mal kabul belgesi · BoutiqueOS" };

export default async function ReceiptDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();

  const { caps } = await loadReceivingContext();
  if (!caps.canRead) redirect("/app");

  const receipt = await getReceipt(id);
  // RLS scopes the query to the tenant, so another business's receipt reads as missing.
  if (!receipt) notFound();

  const isDraft = receipt.status === "draft";
  const editing = isDraft && caps.canWriteReceipt;
  const [fxHints, preview, suppliers] = await Promise.all([
    isDraft && receipt.invoice_currency !== "TRY" ? loadFxHints(receipt.received_at) : Promise.resolve([]),
    editing ? getAllocationPreview(receipt.id) : Promise.resolve(null),
    editing ? listSuppliers({ status: "active" }) : Promise.resolve([]),
  ]);
  const fxHint = fxHints.find((h) => h.currency === receipt.invoice_currency)?.rate ?? null;
  const isPosted = receipt.status === "posted";

  const totalQuantity = receipt.lines.reduce((sum, line) => sum + line.quantity, 0);
  const totalOriginal = receipt.lines.reduce((sum, line) => sum + line.quantity * line.unit_cost, 0);
  // After posting, the authoritative base values come from the item snapshots, not a preview.
  const totalBase = receipt.lines.reduce((sum, line) => sum + (line.total_cost_base ?? 0), 0);
  const landedTotal = receipt.posted_landed_total_base ?? receipt.lines.reduce((sum, line) => sum + (line.landed_total_cost_base ?? 0), 0);

  return (
    <div className="max-w-4xl space-y-8">
      <header>
        <Link href="/app/mal-kabul" className="text-xs text-muted underline-offset-2 hover:underline">
          ← Mal kabul
        </Link>
        <div className="mt-2 flex flex-wrap items-center gap-3">
          <h2 className="font-serif text-xl leading-tight tracking-tightish" data-numeric>
            {receipt.receipt_number}
          </h2>
          <ReceiptStatusPill status={receipt.status} />
        </div>
        <p className="mt-1 flex flex-wrap gap-x-3 text-xs text-muted">
          <span>{receipt.supplier_name}</span>
          <span>{receipt.branch_name}</span>
          <span data-numeric>{formatDate(receipt.received_at)}</span>
          <span data-numeric>{receipt.invoice_currency}</span>
          {receipt.document_ref ? <span>{receipt.document_ref}</span> : null}
        </p>
      </header>

      {editing && preview ? (
        <ReceiptEditor receipt={receipt} fxHint={fxHint} preview={preview} suppliers={suppliers} />
      ) : (
        <div className="space-y-8">
          {receipt.reversal ? (
            <div className="border-l-2 border-danger bg-panel px-3 py-2 text-xs text-ink-70" data-testid="reversal-banner">
              <p className="font-medium text-danger">Bu belge ters kaydedildi.</p>
              <p className="mt-0.5">
                {formatDateTime(receipt.reversal.reversed_at)}
                {receipt.reversal.reversed_by_name ? ` · ${receipt.reversal.reversed_by_name}` : ""} · Neden: {receipt.reversal.reason}
              </p>
              <p className="mt-0.5">
                Stoktan düşülen değer: <span data-numeric>{formatMoney(receipt.reversal.value_removed_base, "TRY")}</span>. Orijinal
                belge ve hareketleri değiştirilmedi; ters kayıt ayrı hareketler ve alacak kayıtlarıyla yapıldı.
              </p>
            </div>
          ) : isPosted ? (
            <p className="border-l-2 border-accent bg-accent-soft px-3 py-2 text-xs text-accent">
              Bu belge işlendi ve değiştirilemez. Stok hareketleri ve tedarikçi borcu oluşturuldu.
            </p>
          ) : receipt.status === "cancelled" ? (
            <p className="border-l-2 border-line-strong bg-panel px-3 py-2 text-xs text-ink-70">
              Bu belge iptal edildi. Stoğa hiçbir etkisi olmadı.
            </p>
          ) : (
            <p className="border-l-2 border-line-strong bg-panel px-3 py-2 text-xs text-ink-70">
              Bu belgeyi düzenlemek için mal kabul yetkisi gerekir.
            </p>
          )}

          <section className="space-y-3">
            <h3 className="text-sm font-medium tracking-tightish">Belge bilgileri</h3>
            <dl className="divide-y divide-line border-y border-line text-sm">
              {[
                ["Tedarikçi", receipt.supplier_name],
                ["Şube", receipt.branch_name],
                ["Alım tarihi", formatDate(receipt.received_at)],
                ["Belge referansı", receipt.document_ref ?? "—"],
                ["Para birimi", receipt.invoice_currency],
                ["Kur", formatRate(receipt.exchange_rate)],
                ["Satır sayısı", String(receipt.lines.length)],
                ["Toplam adet", formatQuantity(totalQuantity)],
                ["Belge tutarı", formatMoney(totalOriginal, receipt.invoice_currency)],
                ["TRY karşılığı", isPosted ? formatMoney(totalBase, "TRY") : "—"],
                ["Dağıtım yöntemi", ALLOCATION_LABELS[receipt.allocation_method]],
                ["Maliyete dahil masraflar", isPosted && receipt.posted_charges_base !== null ? formatMoney(receipt.posted_charges_base, "TRY") : "—"],
                ["İniş maliyeti toplamı", isPosted ? formatMoney(landedTotal, "TRY") : "—"],
                ["İşlenme", receipt.posted_at ? formatDateTime(receipt.posted_at) : "—"],
              ].map(([label, value]) => (
                <div key={label} className="flex justify-between gap-6 py-2">
                  <dt className="text-muted">{label}</dt>
                  <dd className="text-right" data-numeric>
                    {value}
                  </dd>
                </div>
              ))}
            </dl>
            {receipt.note ? (
              <p className="text-xs leading-relaxed text-ink-70">{receipt.note}</p>
            ) : null}
          </section>

          <section className="space-y-3">
            <h3 className="text-sm font-medium tracking-tightish">Satırlar</h3>
            {receipt.lines.length === 0 ? (
              <p className="border border-dashed border-line-strong px-4 py-8 text-center text-xs text-muted">
                Belgede satır yok.
              </p>
            ) : (
              <div className="relative overflow-x-auto">
                <table className={`w-full border-collapse text-sm ${isPosted ? "min-w-[72rem]" : "min-w-[40rem]"}`}>
                  <thead>
                    <tr className="border-y border-line text-left text-xs text-muted">
                      <th scope="col" className="py-2 pr-4 font-medium">Ürün</th>
                      <th scope="col" className="py-2 pr-4 font-medium">SKU / barkod</th>
                      <th scope="col" className="py-2 pr-4 text-right font-medium">Adet</th>
                      <th scope="col" className="py-2 pr-4 text-right font-medium">Birim maliyet</th>
                      <th scope="col" className="py-2 pr-4 text-right font-medium">Satır tutarı</th>
                      {isPosted ? (
                        <>
                          <th scope="col" className="py-2 pr-4 text-right font-medium">Kur</th>
                          <th scope="col" className="py-2 pr-4 text-right font-medium">TRY tutarı</th>
                          <th scope="col" className="py-2 pr-4 text-right font-medium">Masraf payı</th>
                          <th scope="col" className="py-2 pr-4 text-right font-medium">İniş birim</th>
                          <th scope="col" className="py-2 text-right font-medium">İniş toplam</th>
                        </>
                      ) : null}
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-line">
                    {receipt.lines.map((line) => (
                      <tr key={line.id}>
                        <td className="py-2.5 pr-4">
                          <span className="font-medium">{line.product_name}</span>
                          <span className="mt-0.5 block text-2xs text-muted">{line.options}</span>
                        </td>
                        <td className="py-2.5 pr-4 text-ink-70" data-numeric>
                          {line.sku}
                          {line.primary_barcode ? (
                            <span className="mt-0.5 block text-2xs text-muted">{line.primary_barcode}</span>
                          ) : null}
                        </td>
                        <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                          {formatQuantity(line.quantity)}
                        </td>
                        <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                          {formatMoney(line.unit_cost, receipt.invoice_currency)}
                        </td>
                        <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                          {formatMoney(line.quantity * line.unit_cost, receipt.invoice_currency)}
                        </td>
                        {isPosted ? (
                          <>
                            <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                              {line.fx_rate_snapshot === null ? "—" : formatRate(line.fx_rate_snapshot)}
                            </td>
                            <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                              {line.total_cost_base === null ? "—" : formatMoney(line.total_cost_base, "TRY")}
                            </td>
                            <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                              {line.allocated_charge_base === null ? "—" : formatMoney(line.allocated_charge_base, "TRY")}
                            </td>
                            <td className="py-2.5 pr-4 text-right font-medium" data-numeric>
                              {line.landed_unit_cost_base === null ? "—" : formatMoney(line.landed_unit_cost_base, "TRY")}
                            </td>
                            <td className="py-2.5 text-right text-ink-70" data-numeric>
                              {line.landed_total_cost_base === null ? "—" : formatMoney(line.landed_total_cost_base, "TRY")}
                            </td>
                          </>
                        ) : null}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>

          {receipt.charges.length > 0 ? <ChargesSection receipt={receipt} suppliers={[]} editable={false} /> : null}

          {isPosted && !receipt.reversal && caps.canReverse ? <ReversalPanel receipt={receipt} /> : null}
        </div>
      )}
    </div>
  );
}
