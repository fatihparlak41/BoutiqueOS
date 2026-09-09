import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { getReceipt, loadFxHints, loadReceivingContext } from "@/lib/receiving/queries";
import { formatDate, formatDateTime, formatMoney, formatQuantity, formatRate } from "@/lib/receiving/format";
import { ReceiptStatusPill } from "@/components/receiving/receipt-status-pill";
import { ReceiptEditor } from "@/components/receiving/receipt-editor";

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
  const fxHints = isDraft && receipt.invoice_currency !== "TRY" ? await loadFxHints(receipt.received_at) : [];
  const fxHint = fxHints.find((h) => h.currency === receipt.invoice_currency)?.rate ?? null;

  const totalQuantity = receipt.lines.reduce((sum, line) => sum + line.quantity, 0);
  const totalOriginal = receipt.lines.reduce((sum, line) => sum + line.quantity * line.unit_cost, 0);
  // After posting, the authoritative base values come from the item snapshots, not a preview.
  const totalBase = receipt.lines.reduce((sum, line) => sum + (line.total_cost_base ?? 0), 0);

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

      {isDraft && caps.canWriteReceipt ? (
        <ReceiptEditor receipt={receipt} fxHint={fxHint} />
      ) : (
        <div className="space-y-8">
          {receipt.status === "posted" ? (
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
                ["TRY karşılığı", receipt.status === "posted" ? formatMoney(totalBase, "TRY") : "—"],
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
              <div className="overflow-x-auto">
                <table className="w-full min-w-[52rem] border-collapse text-sm">
                  <thead>
                    <tr className="border-y border-line text-left text-xs text-muted">
                      <th scope="col" className="py-2 pr-4 font-medium">Ürün</th>
                      <th scope="col" className="py-2 pr-4 font-medium">SKU / barkod</th>
                      <th scope="col" className="py-2 pr-4 text-right font-medium">Adet</th>
                      <th scope="col" className="py-2 pr-4 text-right font-medium">Birim maliyet</th>
                      <th scope="col" className="py-2 pr-4 text-right font-medium">Satır tutarı</th>
                      {receipt.status === "posted" ? (
                        <>
                          <th scope="col" className="py-2 pr-4 text-right font-medium">Kur</th>
                          <th scope="col" className="py-2 text-right font-medium">TRY tutarı</th>
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
                        {receipt.status === "posted" ? (
                          <>
                            <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>
                              {line.fx_rate_snapshot === null ? "—" : formatRate(line.fx_rate_snapshot)}
                            </td>
                            <td className="py-2.5 text-right text-ink-70" data-numeric>
                              {line.total_cost_base === null ? "—" : formatMoney(line.total_cost_base, "TRY")}
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
        </div>
      )}
    </div>
  );
}
