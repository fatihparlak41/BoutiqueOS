import Link from "next/link";
import { notFound } from "next/navigation";
import { getVariantStock, listMovements } from "@/lib/stock/queries";
import { BUCKET_LABELS, MOVEMENT_REASON_LABELS } from "@/lib/stock/model";
import { formatDateTime, formatQuantity, formatSigned } from "@/lib/receiving/format";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const metadata = { title: "Stok detayı · BoutiqueOS" };

/** Read-only. No cost column is queried; inventory_movement_costs is out of scope here. */
export default async function StockDetailPage({ params }: { params: Promise<{ variantId: string }> }) {
  const { variantId } = await params;
  if (!UUID.test(variantId)) notFound();

  const [branchRows, movements] = await Promise.all([
    getVariantStock(variantId),
    listMovements(variantId),
  ]);

  if (branchRows.length === 0) notFound();
  const variant = branchRows[0];

  return (
    <div className="max-w-4xl space-y-8">
      <header>
        <Link href="/app/stok" className="text-xs text-muted underline-offset-2 hover:underline">
          ← Stok
        </Link>
        <h2 className="mt-2 font-serif text-xl leading-tight tracking-tightish">{variant.product_name}</h2>
        <p className="mt-1 flex flex-wrap gap-x-3 text-xs text-muted">
          <span>{variant.options}</span>
          <span data-numeric>{variant.sku}</span>
          {variant.primary_barcode ? <span data-numeric>{variant.primary_barcode}</span> : null}
          {variant.category_name ? <span>{variant.category_name}</span> : null}
          {variant.brand_name ? <span>{variant.brand_name}</span> : null}
        </p>
        <p className="mt-2">
          <Link
            href={`/app/urunler/${variant.product_id}`}
            className="text-xs text-accent underline underline-offset-2"
          >
            Ürün kartına git
          </Link>
        </p>
      </header>

      <section className="space-y-3">
        <h3 className="text-sm font-medium tracking-tightish">Şube bazında stok</h3>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[44rem] border-collapse text-sm">
            <thead>
              <tr className="border-y border-line text-left text-xs text-muted">
                <th scope="col" className="py-2 pr-4 font-medium">Şube</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">{BUCKET_LABELS.sellable}</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">{BUCKET_LABELS.quarantine}</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">{BUCKET_LABELS.damaged}</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Toplam</th>
                <th scope="col" className="py-2 pr-4 text-right font-medium">Rezerve</th>
                <th scope="col" className="py-2 text-right font-medium">Uygun</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {branchRows.map((row) => (
                <tr key={row.branch_id}>
                  <td className="py-2.5 pr-4">{row.branch_name}</td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.sellable)}</td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.quarantine)}</td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.damaged)}</td>
                  <td className="py-2.5 pr-4 text-right font-medium" data-numeric>{formatQuantity(row.on_hand)}</td>
                  <td className="py-2.5 pr-4 text-right text-ink-70" data-numeric>{formatQuantity(row.reserved)}</td>
                  <td className="py-2.5 text-right font-medium" data-numeric>{formatQuantity(row.available)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="space-y-3">
        <h3 className="text-sm font-medium tracking-tightish">Stok hareketleri</h3>
        <p className="text-xs text-muted">
          Değişmez defter kaydı. Satırlar silinmez veya düzeltilmez; düzeltme yeni bir hareketle yapılır.
        </p>

        {movements.length === 0 ? (
          <p className="border border-dashed border-line-strong px-4 py-8 text-center text-xs text-muted">
            Bu varyant için henüz hareket yok.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[48rem] border-collapse text-sm">
              <thead>
                <tr className="border-y border-line text-left text-xs text-muted">
                  <th scope="col" className="py-2 pr-4 font-medium">Zaman</th>
                  <th scope="col" className="py-2 pr-4 text-right font-medium">Miktar</th>
                  <th scope="col" className="py-2 pr-4 font-medium">Kova</th>
                  <th scope="col" className="py-2 pr-4 font-medium">Sebep</th>
                  <th scope="col" className="py-2 font-medium">Kaynak</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {movements.map((movement) => (
                  <tr key={movement.id}>
                    <td className="py-2.5 pr-4 text-ink-70" data-numeric>
                      {formatDateTime(movement.occurred_at)}
                    </td>
                    <td
                      className={`py-2.5 pr-4 text-right font-medium ${movement.quantity < 0 ? "text-danger" : "text-ink"}`}
                      data-numeric
                    >
                      {formatSigned(movement.quantity)}
                    </td>
                    <td className="py-2.5 pr-4 text-ink-70">{BUCKET_LABELS[movement.bucket]}</td>
                    <td className="py-2.5 pr-4 text-ink-70">{MOVEMENT_REASON_LABELS[movement.reason]}</td>
                    <td className="py-2.5 text-ink-70">
                      {movement.receipt_id ? (
                        <Link
                          href={`/app/mal-kabul/${movement.receipt_id}`}
                          className="text-accent underline underline-offset-2"
                          data-numeric
                        >
                          {movement.receipt_number}
                        </Link>
                      ) : (
                        <span className="text-2xs text-muted">{movement.reference_type}</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
