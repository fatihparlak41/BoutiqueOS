import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { getSaleReceipt, loadPosContext } from "@/lib/pos/queries";
import { getExchangeOrigin, listReturnsOfSale } from "@/lib/pos/returns-queries";
import { RETURN_TYPE_LABELS } from "@/lib/pos/returns-model";
import { PAYMENT_LABELS } from "@/lib/pos/model";
import { formatDateTime, formatMoney, formatQuantity } from "@/lib/receiving/format";
import { ProductThumb } from "@/components/catalog/product-thumb";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const metadata = { title: "Satış fişi · BoutiqueOS" };
const money = (n: number) => formatMoney(n, "TRY");

/**
 * The receipt of a completed sale: reference, when, where, who rang it up, who sold it,
 * lines, discount, total and how it was paid. Visibility is the sales scope (RLS): a
 * sale another person may not see is a 404. No purchase cost, MWA or COGS appears here
 * for anyone — that belongs to reports.
 */
export default async function SaleReceiptPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const { caps } = await loadPosContext();
  if (!caps.canSell) redirect("/app");
  const sale = await getSaleReceipt(id);
  if (!sale) notFound();
  const [returns, origin] = await Promise.all([listReturnsOfSale(id), getExchangeOrigin(id)]);

  const methodLabel = (m: string) => (m === "bank_transfer" ? "Havale" : PAYMENT_LABELS[m as keyof typeof PAYMENT_LABELS] ?? m);

  return (
    <div className="max-w-2xl space-y-6" data-testid="receipt">
      <header className="space-y-1">
        <Link href="/app/pos" className="text-xs text-muted underline-offset-2 hover:underline">← Kasa</Link>
        <div className="flex flex-wrap items-center gap-3">
          <h2 className="font-serif text-xl leading-tight tracking-tightish" data-numeric>{sale.sale_number}</h2>
          {sale.status === "voided" ? (
            <span className="border border-danger/40 px-1.5 py-0.5 text-2xs text-danger">İptal edildi</span>
          ) : (
            <span className="border border-success/40 px-1.5 py-0.5 text-2xs text-success">Tamamlandı</span>
          )}
        </div>
        <p className="text-xs text-muted" data-numeric>{formatDateTime(sale.occurred_at)} · {sale.branch_name}</p>
      </header>

      <dl className="divide-y divide-line border-y border-line text-sm">
        {[
          ["Kasiyer", sale.cashier_name ?? "—"],
          ["Satışı yapan", sale.salesperson_name ?? "—"],
          ["Müşteri", sale.customer ? `${sale.customer.full_name ?? "—"} · ${sale.customer.phone}` : "Kayıtsız müşteri"],
        ].map(([k, v]) => (
          <div key={k} className="flex justify-between gap-6 py-2"><dt className="text-muted">{k}</dt><dd className="text-right">{v}</dd></div>
        ))}
      </dl>

      <ul className="divide-y divide-line border-y border-line" data-testid="receipt-lines">
        {sale.items.map((it) => (
          <li key={it.id} className="flex items-center gap-3 py-2.5">
            <ProductThumb url={it.variant.thumbnail_url} alt={it.variant.product_name} size="sm" />
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-medium text-ink">{it.variant.product_name}</p>
              <p className="truncate text-2xs text-muted">
                {[it.variant.color, it.variant.size].filter(Boolean).join(" / ") || it.variant.options || "Tek seçenek"} · <span data-numeric>{it.variant.sku}</span>
              </p>
              <p className="text-2xs text-muted" data-numeric>
                {formatQuantity(it.quantity)} × {money(it.unit_price)}
                {it.discount_amount > 0 ? <span className="text-danger"> · indirim −{money(it.discount_amount)} (liste {money(it.list_price)})</span> : null}
              </p>
            </div>
            <span className="text-sm font-medium" data-numeric>{money(it.line_total)}</span>
          </li>
        ))}
      </ul>

      <dl className="divide-y divide-line border-y border-line text-sm" data-testid="receipt-totals">
        <div className="flex justify-between py-2"><dt className="text-muted">Ara toplam</dt><dd data-numeric>{money(sale.subtotal)}</dd></div>
        {sale.discount_amount > 0 ? (
          <div className="flex justify-between py-2"><dt className="text-muted">İndirim</dt><dd className="text-danger" data-numeric>−{money(sale.discount_amount)}</dd></div>
        ) : null}
        <div className="flex justify-between py-2 text-base font-medium"><dt>Toplam</dt><dd data-numeric>{money(sale.total)}</dd></div>
        {sale.payments.map((p) => (
          <div key={p.id} className="flex justify-between py-2"><dt className="text-muted">{methodLabel(p.method)}</dt><dd data-numeric>{formatMoney(p.amount, p.currency as "TRY")}</dd></div>
        ))}
        {sale.change_given > 0 ? (
          <div className="flex justify-between py-2"><dt className="text-muted">Para üstü</dt><dd data-numeric>{money(sale.change_given)}</dd></div>
        ) : null}
      </dl>
      {sale.note ? <p className="text-xs text-ink-70">{sale.note}</p> : null}

      {origin ? (
        <p className="border-l-2 border-line-strong bg-panel px-3 py-2 text-xs text-ink-70" data-testid="receipt-exchange-origin">
          Değişim fişi: <Link href={`/app/pos/iade/${origin.return_id}`} className="underline-offset-2 hover:underline" data-numeric>{origin.return_number}</Link> ile{" "}
          <Link href={`/app/pos/satis/${origin.original_sale_id}`} className="underline-offset-2 hover:underline" data-numeric>{origin.original_sale_number}</Link> satışından geldi.
        </p>
      ) : null}
      {returns.length > 0 ? (
        <div className="space-y-1 text-xs" data-testid="receipt-returns">
          <p className="text-muted">Bu satışın iadeleri</p>
          <ul className="divide-y divide-line border-y border-line">
            {returns.map((r) => (
              <li key={r.id} className="flex items-center justify-between gap-3 py-2">
                <Link href={`/app/pos/iade/${r.id}`} className="underline-offset-2 hover:underline" data-numeric>{r.return_number}</Link>
                <span className="text-muted">{RETURN_TYPE_LABELS[r.return_type as keyof typeof RETURN_TYPE_LABELS] ?? r.return_type} · <span data-numeric>{formatDateTime(r.created_at)}</span></span>
                <span data-numeric>{money(r.credit_value_base)}</span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      <div className="flex flex-wrap gap-2">
        <Link href="/app/pos" className="inline-flex h-11 items-center border border-line-strong px-4 text-sm sm:h-9">Yeni satış</Link>
        {sale.status === "completed" ? <Link href={`/app/pos/iade?satis=${sale.id}`} className="inline-flex h-11 items-center border border-line-strong px-4 text-sm sm:h-9" data-testid="receipt-return-link">İade / Değişim</Link> : null}
      </div>
    </div>
  );
}
