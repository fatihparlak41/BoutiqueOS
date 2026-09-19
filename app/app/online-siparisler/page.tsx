import Link from "next/link";
import { requireTenant } from "@/lib/tenant";
import { listOnlineOrders, sweepOnlineOrders } from "@/lib/orders/queries";
import { ORDER_FILTERS, ORDER_FILTER_LABELS, orderCaps, type OrderFilter } from "@/lib/orders/model";
import { ORDER_STATUS_LABELS, formatShopPrice } from "@/lib/shop/model";
import { PageHeader } from "@/components/ui/page-header";
import { ShoppingBag } from "lucide-react";
import { EmptyState } from "@/components/ui/empty-state";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { FilterBar } from "@/components/ui/filter-bar";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { TableShell, THead, TH, TBody, TR, TD, CellTitle } from "@/components/ui/table";
import { OrderPill, fmtDateTime } from "@/components/orders/pills";

export const metadata = { title: "Online Siparişler · BoutiqueOS" };
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
        <PageHeader title="Online Siparişler" />
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

  return (
    <div className="space-y-6">
      <PageHeader
        title="Online Siparişler"
        description="Mağaza vitrininden gelen sipariş talepleri. Talep stok ayırır; satış, ödeme ve stok düşümü yalnız kasada teslimle olur."
      />
      <div className="flex flex-wrap gap-2 text-xs">
        {ORDER_FILTERS.map((f) => (
          <Link key={f} href={`/app/online-siparisler?durum=${f}`} className={`rounded border px-2.5 py-1 ${status === f ? "border-accent bg-accent-muted text-accent" : "border-border text-text-secondary hover:text-text-primary"}`}>
            {ORDER_FILTER_LABELS[f]} <span data-numeric>{list.counts[f]}</span>
          </Link>
        ))}
      </div>
      <FilterBar clearHref="/app/online-siparisler" hasFilter={Boolean(status || query)} columns={4}>
        <div className="space-y-1.5">
          <Label htmlFor="q">Sipariş no, ad ya da telefon</Label>
          <Input id="q" name="q" defaultValue={query ?? ""} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="durum">Durum</Label>
          <Select id="durum" name="durum" defaultValue={status ?? ""}>
            <option value="">Tümü</option>
            {ORDER_FILTERS.map((f) => <option key={f} value={f}>{ORDER_FILTER_LABELS[f]}</option>)}
          </Select>
        </div>
      </FilterBar>
      {list.rows.length === 0 ? (
        status || query ? (
          <EmptyState compact title="Bu filtreye uyan sipariş yok" description="Durumu ya da aramayı değiştir." />
        ) : (
          <EmptyState icon={<ShoppingBag />} title="Henüz online sipariş yok" description="Online mağazandan gelen sipariş talepleri burada toplanır; onayladığında stok ayrılır, teslim kasada yapılır." action={orderCaps(active.role).canConfirm ? <Link href="/app/online-magaza"><Button variant="outline">Online mağazayı aç</Button></Link> : undefined} />
        )
      ) : (
        <TableShell minWidth="56rem" footer={`${list.total} sipariş`}>
          <THead>
            <TH>Sipariş</TH>
            <TH>Müşteri</TH>
            <TH align="right">Tutar</TH>
            <TH>Ayırma bitişi</TH>
            <TH>Durum</TH>
            <TH>Satış</TH>
          </THead>
          <TBody>
            {list.rows.map((o) => (
              <TR key={o.id}>
                <TD>
                  <CellTitle sub={`${o.item_count} ürün · ${fmtDateTime(o.created_at)}`}>
                    <Link href={`/app/online-siparisler/${o.id}`} className="hover:underline" data-numeric>{o.order_number}</Link>
                  </CellTitle>
                </TD>
                <TD>{o.customer_name}<br /><span className="text-xs text-text-muted" data-numeric>{o.phone}</span></TD>
                <TD align="right" numeric>{formatShopPrice(o.total, o.currency)}</TD>
                <TD nowrap muted>{o.status === "pending_confirmation" || o.status === "confirmed" || o.status === "ready" ? fmtDateTime(o.reservation_expires_at) : "—"}</TD>
                <TD>
                  <span className="flex flex-wrap gap-1">
                    <OrderPill status={o.status} />
                    {o.public_status !== o.status ? <Badge tone="warning">{ORDER_STATUS_LABELS[o.public_status]}</Badge> : null}
                  </span>
                </TD>
                <TD muted data-numeric>{o.converted_sale_number ?? "—"}</TD>
              </TR>
            ))}
          </TBody>
        </TableShell>
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
