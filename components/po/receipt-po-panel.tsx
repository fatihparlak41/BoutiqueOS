import Link from "next/link";
import type { ReceiptDetail } from "@/lib/receiving/model";
import type { ReceiptPoReference } from "@/lib/po/model";
import { PO_STATUS_LABELS } from "@/lib/po/model";
import { formatMoney, formatQuantity } from "@/lib/receiving/format";

/**
 * The purchase order behind a linked receipt: ordered / received so far / remaining per
 * variant, and — for owner / manager — the expected unit cost as a REFERENCE. The receipt's
 * own unit cost is the authoritative one and is never filled in from here.
 */
export function ReceiptPoPanel({ receipt, reference: ref }: { receipt: ReceiptDetail; reference: ReceiptPoReference }) {
  const labels = new Map(receipt.lines.map((l) => [l.variant_id, l]));
  const overs = ref.lines.filter((l) => (labels.get(l.variant_id)?.quantity ?? 0) > l.remaining);
  return (
    <section className="space-y-3 rounded border border-border bg-background/60 p-4" data-testid="receipt-po-panel">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="text-sm font-medium tracking-tightish">
          Sipariş: <Link href={`/app/satin-alma/${ref.purchase_order_id}`} className="underline underline-offset-4" data-numeric>{ref.po_number}</Link>
          <span className="ml-2 text-xs font-normal text-text-muted">{PO_STATUS_LABELS[ref.po_status]} · {ref.po_currency}</span>
        </h3>
        <p className="text-2xs text-text-muted">Beklenen adet ve maliyet planlamadır; bu belgedeki adet ve birim maliyet teslim edilen gerçek değerlerdir.</p>
      </div>
      <ul className="divide-y divide-border text-xs">
        {ref.lines.map((l) => {
          const line = labels.get(l.variant_id);
          const claimed = line?.quantity ?? 0;
          return (
            <li key={l.variant_id} className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-0.5 py-1.5">
              <span className="text-text-primary">{line ? `${line.product_name} · ${line.sku}` : <span className="text-text-muted">belgede olmayan sipariş satırı</span>}</span>
              <span className="text-text-secondary" data-numeric>
                sipariş {formatQuantity(l.ordered)} · alınan {formatQuantity(l.received)} · kalan {formatQuantity(l.remaining)}
                {line ? ` · bu belgede ${formatQuantity(claimed)}` : ""}
                {claimed > l.remaining ? <span className="ml-1 font-medium text-danger">kalanı aşıyor</span> : null}
                {ref.financial && l.expected_unit_cost != null ? ` · beklenen ${formatMoney(l.expected_unit_cost, ref.po_currency)}` : ""}
              </span>
            </li>
          );
        })}
      </ul>
      {overs.length > 0 ? <p className="text-2xs text-danger">Kalan miktarı aşan satır var; POST OVER_RECEIPT ile reddedilir.</p> : null}
    </section>
  );
}
