import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { loadPosContext } from "@/lib/pos/queries";
import { getReturnDocument } from "@/lib/pos/returns-queries";
import { CONDITION_LABELS, RETURN_TYPE_LABELS } from "@/lib/pos/returns-model";
import { PAYMENT_LABELS } from "@/lib/pos/model";
import { formatDateTime, formatMoney, formatQuantity } from "@/lib/receiving/format";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const metadata = { title: "İade belgesi · BoutiqueOS" };
const money = (n: number) => formatMoney(n, "TRY");

/**
 * The return document: what came back, in what condition, what it was worth to the
 * customer, what was refunded or which replacement sale carries the credit. Visibility
 * follows the return row (processor, manager+, or whoever may see the original sale).
 * No historical COGS appears here for anyone.
 */
export default async function ReturnDocumentPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const { caps } = await loadPosContext();
  if (!caps.canSell) redirect("/app");
  const doc = await getReturnDocument(id);
  if (!doc) notFound();
  const methodLabel = (m: string) => (m === "bank_transfer" ? "Havale" : PAYMENT_LABELS[m as keyof typeof PAYMENT_LABELS] ?? m);

  return (
    <div className="max-w-2xl space-y-6" data-testid="return-doc">
      <header className="space-y-1">
        <Link href="/app/pos/iade" className="text-xs text-muted underline-offset-2 hover:underline">← İade / Değişim</Link>
        <div className="flex flex-wrap items-center gap-3">
          <h2 className="font-serif text-xl leading-tight tracking-tightish" data-numeric>{doc.return_number}</h2>
          <span className="border border-success/40 px-1.5 py-0.5 text-2xs text-success">{RETURN_TYPE_LABELS[doc.return_type]}</span>
        </div>
        <p className="text-xs text-muted" data-numeric>{formatDateTime(doc.created_at)} · {doc.branch_name}</p>
      </header>

      <dl className="divide-y divide-line border-y border-line text-sm">
        <div className="flex justify-between gap-6 py-2"><dt className="text-muted">Orijinal satış</dt><dd className="text-right"><Link href={`/app/pos/satis/${doc.original_sale_id}`} className="underline-offset-2 hover:underline" data-numeric>{doc.original_sale_number}</Link></dd></div>
        {doc.replacement_sale_id ? (
          <div className="flex justify-between gap-6 py-2"><dt className="text-muted">Yeni satış</dt><dd className="text-right"><Link href={`/app/pos/satis/${doc.replacement_sale_id}`} className="underline-offset-2 hover:underline" data-numeric>{doc.replacement_sale_number}</Link></dd></div>
        ) : null}
        <div className="flex justify-between gap-6 py-2"><dt className="text-muted">İşleyen</dt><dd className="text-right">{doc.processed_by_name ?? "—"}</dd></div>
        <div className="flex justify-between gap-6 py-2"><dt className="text-muted">Müşteri</dt><dd className="text-right">{doc.customer ? `${doc.customer.full_name ?? "—"} · ${doc.customer.phone}` : "Kayıtsız müşteri"}</dd></div>
        <div className="flex justify-between gap-6 py-2"><dt className="text-muted">Neden</dt><dd className="text-right">{doc.reason_label ?? doc.reason_code ?? "—"}</dd></div>
      </dl>

      <ul className="divide-y divide-line border-y border-line" data-testid="return-lines">
        {doc.items.map((it) => (
          <li key={it.id} className="flex items-center gap-3 py-2.5">
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-medium text-ink">{it.product_name}</p>
              <p className="truncate text-2xs text-muted"><span data-numeric>{it.sku}</span> · {CONDITION_LABELS[it.disposition]}</p>
              <p className="text-2xs text-muted" data-numeric>{formatQuantity(it.quantity)} × {money(it.unit_price_at_sale)}</p>
            </div>
            <span className="text-sm font-medium" data-numeric>{money(it.quantity * it.unit_price_at_sale)}</span>
          </li>
        ))}
      </ul>

      <dl className="divide-y divide-line border-y border-line text-sm" data-testid="return-totals">
        <div className="flex justify-between py-2"><dt className="text-muted">İade değeri</dt><dd data-numeric>{money(doc.credit_value_base)}</dd></div>
        {doc.return_type === "exchange" ? (
          <div className="flex justify-between py-2"><dt className="text-muted">Yeni satışa aktarılan</dt><dd data-numeric>{money(doc.credit_value_base - doc.refund_amount_base)}</dd></div>
        ) : null}
        {doc.refund_amount_base > 0 ? (
          <div className="flex justify-between py-2 text-base font-medium"><dt>İade edilen{doc.refund_method ? ` (${methodLabel(doc.refund_method)})` : ""}</dt><dd data-numeric>{money(doc.refund_amount_base)}</dd></div>
        ) : null}
      </dl>
      {doc.note ? <p className="text-xs text-ink-70">{doc.note}</p> : null}

      <Link href="/app/pos/iade" className="inline-flex h-11 items-center border border-line-strong px-4 text-sm sm:h-9">Yeni iade</Link>
    </div>
  );
}
