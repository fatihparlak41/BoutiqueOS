import Link from "next/link";
import { requireTenant } from "@/lib/tenant";
import { listOnlineOrders, sweepOnlineOrders } from "@/lib/orders/queries";
import { MERCHANT_STATUS_LABELS, ORDER_FILTERS, ORDER_FILTER_LABELS, orderCaps, type OrderFilter } from "@/lib/orders/model";
import { formatShopPrice } from "@/lib/shop/model";
import { PageHeader } from "@/components/ui/page-header";
import { ShoppingBag } from "lucide-react";
import { EmptyState } from "@/components/ui/empty-state";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { SearchFilters } from "@/components/ui/search-filters";
import { cn } from "@/lib/utils";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { OrderPill, fmtDateTime } from "@/components/orders/pills";

export const metadata = { title: "Online siparişler · BoutiqueOS" };
const PAGE = 50;

/**
 * Online order desk. Requests come from the storefront, the hold lives in reservations,
 * the money and the stock move only when the order is completed at the POS. Opening the
 * list materialises lapsed holds (the reads already show them as expired).
 */
export default async function OnlineOrdersPage({ searchParams }: { searchParams: Promise<{ durum?: string; q?: string; sayfa?: string }> }) {
  const { active } = await requireTenant();
  if (!orderCaps(active.role).canView) {
    return (
      <div className="space-y-8">
        <PageHeader title="Online siparişler" />
        <EmptyState compact title="Bu bölüm satış rollerine açıktır" description="Online siparişleri sahip, yönetici ve satış personeli görür." />
      </div>
    );
  }
  const { durum, q, sayfa } = await searchParams;
  const status = ORDER_FILTERS.includes(durum as OrderFilter) ? (durum as OrderFilter) : null;
  const query = (q ?? "").trim().slice(0, 80) || null;
  const page = Math.max(1, Number.parseInt(sayfa ?? "1", 10) || 1);
  await sweepOnlineOrders();
  const list = await listOnlineOrders(status, query, (page - 1) * PAGE, PAGE);
  const pages = Math.max(1, Math.ceil(list.total / PAGE));
  const href = (p: number) => `/app/online-siparisler?${new URLSearchParams({ ...(status ? { durum: status } : {}), ...(query ? { q: query } : {}), sayfa: String(p) })}`;

  const holdShown = (s: string) => s === "pending_confirmation" || s === "confirmed" || s === "ready";

  return (
    <div className="space-y-5">
      <PageHeader
        title="Online siparişler"
        description="Vitrinden gelen talepler; ürün ayrılır, teslim ve ödeme kasada olur."
      />

      <div className="-mx-4 flex gap-1.5 overflow-x-auto px-4 pb-1 text-xs sm:mx-0 sm:flex-wrap sm:px-0" role="tablist" aria-label="Durum">
        <Link href="/app/online-siparisler" role="tab" aria-selected={!status} className={cn("shrink-0 rounded border px-2.5 py-1.5", !status ? "border-accent bg-accent-muted text-accent" : "border-border text-text-secondary hover:text-text-primary")}>
          Tümü
        </Link>
        {ORDER_FILTERS.map((f) => (
          <Link key={f} href={`/app/online-siparisler?durum=${f}`} role="tab" aria-selected={status === f} className={cn("shrink-0 rounded border px-2.5 py-1.5", status === f ? "border-accent bg-accent-muted text-accent" : "border-border text-text-secondary hover:text-text-primary")}>
            {ORDER_FILTER_LABELS[f]} <span data-numeric className="opacity-70">{list.counts[f]}</span>
          </Link>
        ))}
      </div>

      <SearchFilters
        basePath="/app/online-siparisler"
        search={query ?? ""}
        placeholder="Sipariş no, ad ya da telefon"
        selects={[{ name: "durum", label: "Durum", value: status ?? "", options: ORDER_FILTERS.map((f) => ({ value: f, label: ORDER_FILTER_LABELS[f] })) }]}
      />

      {list.rows.length === 0 ? (
        status || query ? (
          <EmptyState compact title="Bu filtreye uyan sipariş yok" description="Durumu ya da aramayı değiştir." action={<Link href="/app/online-siparisler"><Button variant="outline" size="sm">Filtreleri temizle</Button></Link>} />
        ) : (
          <EmptyState editorial icon={<ShoppingBag />} title="Henüz online sipariş yok" description="Online mağazandan gelen talepler burada sıralanır; onayladığında ürün ayrılır, teslim kasada yapılır." action={orderCaps(active.role).canConfirm ? <Link href="/app/online-magaza"><Button variant="outline">Online mağaza ayarları</Button></Link> : undefined} />
        )
      ) : (
        <>
          {/* phone / tablet: one card per order, the queue at a glance */}
          <ul className="divide-y divide-border border-y border-border lg:hidden" data-testid="order-cards">
            {list.rows.map((o) => (
              <li key={o.id}>
                <Link href={`/app/online-siparisler/${o.id}`} className="flex min-h-16 items-center gap-3 py-3 hover:bg-surface-muted/60">
                  <div className="min-w-0 flex-1">
                    <p className="flex flex-wrap items-center gap-x-2 gap-y-1">
                      <span className="truncate text-sm font-medium text-text-primary">{o.customer_name}</span>
                      <OrderPill status={o.status} />
                      {o.public_status !== o.status ? <Badge tone="warning">{MERCHANT_STATUS_LABELS[o.public_status]}</Badge> : null}
                    </p>
                    <p className="mt-0.5 truncate text-xs text-text-muted" data-numeric>
                      {o.order_number} · {fmtDateTime(o.created_at)} · {o.item_count} ürün
                    </p>
                    {holdShown(o.status) && o.reservation_expires_at ? (
                      <p className="mt-0.5 text-2xs text-text-muted" data-numeric>ayırma bitişi {fmtDateTime(o.reservation_expires_at)}</p>
                    ) : null}
                  </div>
                  <span className="shrink-0 text-sm font-medium text-text-primary" data-numeric>{formatShopPrice(o.total, o.currency)}</span>
                </Link>
              </li>
            ))}
          </ul>

          {/* desktop: the table */}
          <div className="hidden lg:block" data-testid="order-table">
            <TableShell minWidth="56rem" footer={`${list.total} sipariş`}>
              <THead>
                <TH>Müşteri</TH>
                <TH>Sipariş</TH>
                <TH align="right">Tutar</TH>
                <TH>Ayırma bitişi</TH>
                <TH>Durum</TH>
                <TH>Satış</TH>
              </THead>
              <TBody>
                {list.rows.map((o) => (
                  <TR key={o.id}>
                    <TD>
                      <CellTitle sub={o.phone}>
                        <Link href={`/app/online-siparisler/${o.id}`} className="hover:underline">{o.customer_name}</Link>
                      </CellTitle>
                    </TD>
                    <TD>
                      <CellTitle sub={`${o.item_count} ürün · ${fmtDateTime(o.created_at)}`}>
                        <Link href={`/app/online-siparisler/${o.id}`} className="hover:underline" data-numeric>{o.order_number}</Link>
                      </CellTitle>
                    </TD>
                    <TD align="right" numeric>{formatShopPrice(o.total, o.currency)}</TD>
                    <TD nowrap muted>{holdShown(o.status) ? fmtDateTime(o.reservation_expires_at) : "—"}</TD>
                    <TD>
                      <span className="flex flex-wrap gap-1">
                        <OrderPill status={o.status} />
                        {o.public_status !== o.status ? <Badge tone="warning">{MERCHANT_STATUS_LABELS[o.public_status]}</Badge> : null}
                      </span>
                    </TD>
                    <TD muted data-numeric>{o.converted_sale_number ?? "—"}</TD>
                  </TR>
                ))}
              </TBody>
            </TableShell>
          </div>
        </>
      )}
      {pages > 1 ? (
        <nav className="flex items-center gap-4 text-xs text-text-muted" aria-label="Sayfalar" data-numeric>
          {page > 1 ? <Link href={href(page - 1)} className="underline-offset-4 hover:underline">← Önceki</Link> : <span>← Önceki</span>}
          <span>{page} / {pages}</span>
          {page < pages ? <Link href={href(page + 1)} className="underline-offset-4 hover:underline">Sonraki →</Link> : <span>Sonraki →</span>}
        </nav>
      ) : null}
    </div>
  );
}
