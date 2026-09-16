import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { getCustomer, getCustomerFinancials, listCustomerReservations, listCustomerSales, listSources, loadCrmContext } from "@/lib/crm/queries";
import { CustomerForm } from "@/components/crm/customer-form";
import { RESERVATION_STATUS_LABELS } from "@/lib/crm/model";
import { RETURN_TYPE_LABELS } from "@/lib/pos/returns-model";
import { formatDateTime, formatMoney } from "@/lib/receiving/format";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const metadata = { title: "Müşteri · BoutiqueOS" };
const money = (n: number) => formatMoney(n, "TRY");

/**
 * One customer: identity / contact / source / note, the sales they made (derived from
 * `sales`, RLS-scoped), returns on those sales, reservations. Revenue / COGS / gross margin
 * is loaded for owner and manager only — sales_staff never receives it.
 */
export default async function CustomerPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ duzenle?: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const { caps } = await loadCrmContext();
  if (!caps.canAccessCrm) redirect("/app");
  const customer = await getCustomer(id);
  if (!customer) notFound();
  const { duzenle } = await searchParams;
  const [sales, reservations, sources, financials] = await Promise.all([listCustomerSales(id), listCustomerReservations(id), listSources(), getCustomerFinancials(id)]);
  const sourceLabel = sources.find((s) => s.code === customer.source)?.label ?? customer.source;

  return (
    <div className="max-w-3xl space-y-6" data-testid="customer-detail">
      <header className="space-y-1">
        <Link href="/app/musteriler" className="text-xs text-muted underline-offset-2 hover:underline">← Müşteriler</Link>
        <div className="flex flex-wrap items-center gap-3">
          <h2 className="font-serif text-xl leading-tight tracking-tightish">{customer.full_name}</h2>
          {!customer.is_active ? <span className="border border-line-strong px-1.5 py-0.5 text-2xs text-muted">arşiv</span> : null}
        </div>
        <p className="text-xs text-muted" data-numeric>{[customer.phone, customer.email, customer.instagram ? `@${customer.instagram}` : null].filter(Boolean).join(" · ") || "iletişim bilgisi yok"}{sourceLabel ? ` · ${sourceLabel}` : ""}</p>
        {customer.notes ? <p className="text-xs text-ink-70">{customer.notes}</p> : null}
      </header>

      {duzenle === "1" ? (
        <section className="space-y-3 border border-line bg-panel/40 p-4"><h3 className="text-sm font-medium tracking-tightish">Düzenle</h3><CustomerForm sources={sources} caps={caps} initial={customer} /></section>
      ) : (
        <div className="flex flex-wrap gap-2">
          <Link href={`/app/musteriler/${id}?duzenle=1`} className="inline-flex h-11 items-center border border-line-strong px-4 text-sm sm:h-9" data-testid="customer-edit">Düzenle</Link>
          <Link href={`/app/rezervasyonlar/yeni?musteri=${id}`} className="inline-flex h-11 items-center bg-primary px-4 text-sm text-primary-foreground sm:h-9" data-testid="customer-reserve">Rezervasyon aç</Link>
        </div>
      )}

      <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4" data-testid="customer-stats">
        <div className="border border-line px-3 py-2"><dt className="text-2xs text-muted">Satış</dt><dd className="text-base font-medium" data-numeric>{customer.order_count}</dd></div>
        <div className="border border-line px-3 py-2"><dt className="text-2xs text-muted">Son satış</dt><dd className="text-sm" data-numeric>{customer.last_purchase_at ? formatDateTime(customer.last_purchase_at) : "—"}</dd></div>
        {financials ? (
          <>
            <div className="border border-line px-3 py-2" data-testid="customer-financials"><dt className="text-2xs text-muted">Ciro</dt><dd className="text-sm" data-numeric>{money(financials.revenue)}</dd></div>
            <div className="border border-line px-3 py-2"><dt className="text-2xs text-muted">Brüt kâr (COGS {money(financials.cogs)})</dt><dd className="text-sm" data-numeric>{money(financials.gross_margin)}</dd></div>
          </>
        ) : null}
      </dl>

      <section className="space-y-2">
        <h3 className="text-sm font-medium tracking-tightish">Rezervasyonlar</h3>
        {reservations.length === 0 ? <p className="text-xs text-muted">Rezervasyon yok.</p> : (
          <ul className="divide-y divide-line border-y border-line text-sm" data-testid="customer-reservations">
            {reservations.map((r) => (
              <li key={r.id} className="flex items-center justify-between gap-3 py-2">
                <Link href={`/app/rezervasyonlar/${r.id}`} className="underline-offset-2 hover:underline" data-numeric>{r.reservation_number}</Link>
                <span className="text-2xs text-muted">{RESERVATION_STATUS_LABELS[r.status]} · <span data-numeric>{r.item_count} adet · {formatDateTime(r.expires_at)}</span></span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="space-y-2">
        <h3 className="text-sm font-medium tracking-tightish">Satış geçmişi</h3>
        {sales.length === 0 ? <p className="text-xs text-muted">Görüntülenebilir satış yok.</p> : (
          <ul className="divide-y divide-line border-y border-line" data-testid="customer-sales">
            {sales.map((s) => (
              <li key={s.id} className="space-y-1 py-2.5">
                <div className="flex items-center justify-between gap-3 text-sm">
                  <Link href={`/app/pos/satis/${s.id}`} className="font-medium underline-offset-2 hover:underline" data-numeric>{s.sale_number}{s.status === "voided" ? <span className="ml-2 text-2xs text-danger">iptal</span> : null}</Link>
                  <span data-numeric>{money(s.total)}</span>
                </div>
                <p className="text-2xs text-muted" data-numeric>{formatDateTime(s.occurred_at)} · {s.branch_name} · {s.item_count} adet · {s.items_summary}</p>
                {s.returns.length > 0 ? <p className="text-2xs text-muted">{s.returns.map((r) => <Link key={r.id} href={`/app/pos/iade/${r.id}`} className="mr-2 underline-offset-2 hover:underline" data-numeric>{r.return_number} · {RETURN_TYPE_LABELS[r.return_type as keyof typeof RETURN_TYPE_LABELS] ?? r.return_type}</Link>)}</p> : null}
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
