import "server-only";

import { loadAppContext } from "@/lib/app-context";
import { getOverview } from "@/lib/reports/queries";
import { resolvePeriod } from "@/lib/reports/period";
import { reportCaps } from "@/lib/reports/model";
import { posCaps } from "@/lib/pos/model";
import { crmCaps } from "@/lib/crm/model";
import { orderCaps } from "@/lib/orders/model";
import { receivingCaps } from "@/lib/receiving/model";
import { catalogCaps } from "@/lib/catalog/model";
import { countCaps } from "@/lib/stock/count-model";
import { stockAvailabilitySummary } from "@/lib/stock/queries";
import { listOnlineOrders } from "@/lib/orders/queries";
import type { UserRole } from "@/lib/tenant";

/**
 * The operational home screen, read in ONE parallel round: what a role may not see is
 * not queried for it (no financial data fetched and hidden). Every read is bounded —
 * head counts, `limit 5`, or an aggregate RPC the reports already use. Roughly ten
 * bounded reads for an owner, fewer for staff; nothing per row.
 */

export type DashboardCaps = {
  canSell: boolean;
  canEditCatalog: boolean;
  canCount: boolean;
  canAccessCrm: boolean;
  canViewOrders: boolean;
  canReceive: boolean;
  managerPlus: boolean;
  canViewSales: boolean;
};

export type OpenSession = { id: string; session_number: string; opened_at: string; register_name: string; hours_open: number };

export type Attention = {
  kind: "register_open_long" | "orders_pending" | "out_of_stock" | "count_in_review" | "receipts_draft" | "timezone_missing";
  title: string;
  detail: string;
  href: string;
  action: string;
  /** manager+ only items are never built for other roles; this flag is informational */
  level: "warning" | "info";
};

export type Activity = { kind: "sale" | "product" | "count" | "order"; when: string; title: string; detail: string | null; href: string };

export type Dashboard = {
  caps: DashboardCaps;
  today: { transactions: number; units: number; net_sales: number | null; returns_count: number; scope: string } | null;
  openSessions: OpenSession[];
  attention: Attention[];
  starter: { products: boolean; stock: boolean; sale: boolean } | null;
  activity: Activity[];
  ordersPending: number;
  timezoneSet: boolean;
};

const LONG_OPEN_HOURS = 16;

function dashboardCaps(role: UserRole): DashboardCaps {
  const managerPlus = role === "owner" || role === "manager";
  return {
    canSell: posCaps(role, 0).canSell,
    canEditCatalog: catalogCaps(role).canEditCatalog,
    canCount: countCaps(role).canCount,
    canAccessCrm: crmCaps(role).canAccessCrm,
    canViewOrders: orderCaps(role).canView,
    canReceive: receivingCaps(role).canRead,
    managerPlus,
    canViewSales: reportCaps(role).canViewSales,
  };
}

function fmtDay(iso: string): string {
  return new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long" }).format(new Date(iso));
}

export async function loadDashboard(): Promise<Dashboard> {
  const { supabase, businessId, branchId, role, tenant } = await loadAppContext();
  const caps = dashboardCaps(role);
  const timezone = tenant.active.timezone;
  const today = resolvePeriod({ d: "today" }, timezone);

  const [overview, sessions, orders, stock, countsInReview, recentCounts, draftReceipts, products, sales] = await Promise.all([
    caps.canViewSales ? getOverview(today, branchId).catch(() => null) : Promise.resolve(null),
    // open drawers are visible to every member (a cashier must find the session a manager opened)
    supabase.from("register_sessions").select("id, session_number, opened_at, cash_registers(name)").eq("business_id", businessId).eq("status", "open").order("opened_at", { ascending: true }).limit(5),
    caps.canViewOrders ? listOnlineOrders("new", null, 0, 3).catch(() => null) : Promise.resolve(null),
    stockAvailabilitySummary(),
    caps.canCount ? supabase.from("stock_counts").select("id", { count: "exact", head: true }).eq("business_id", businessId).in("status", ["counting", "review"]) : Promise.resolve({ count: 0 }),
    caps.canCount ? supabase.from("stock_counts").select("id, count_number, status, posted_at, updated_at").eq("business_id", businessId).eq("status", "posted").order("posted_at", { ascending: false }).limit(3) : Promise.resolve({ data: [] }),
    caps.canReceive ? supabase.from("goods_receipts").select("id", { count: "exact", head: true }).eq("business_id", businessId).eq("status", "draft") : Promise.resolve({ count: 0 }),
    supabase.from("products").select("id, name, created_at", { count: "exact" }).eq("business_id", businessId).order("created_at", { ascending: false }).limit(3),
    supabase.from("sales").select("id, sale_number, occurred_at, total", { count: "exact" }).eq("business_id", businessId).eq("status", "completed").order("occurred_at", { ascending: false }).limit(3),
  ]);

  const now = Date.now();
  const openSessions: OpenSession[] = ((sessions.data ?? []) as Array<{ id: string; session_number: string; opened_at: string; cash_registers: { name: string } | { name: string }[] | null }>).map((s) => {
    const reg = Array.isArray(s.cash_registers) ? s.cash_registers[0] : s.cash_registers;
    return { id: s.id, session_number: s.session_number, opened_at: s.opened_at, register_name: reg?.name ?? "Kasa", hours_open: Math.round((now - new Date(s.opened_at).getTime()) / 36e5) };
  });

  const ordersPending = orders?.counts?.new ?? 0;
  const attention: Attention[] = [];
  for (const s of openSessions) {
    if (s.hours_open >= LONG_OPEN_HOURS && caps.canSell) {
      attention.push({
        kind: "register_open_long",
        level: "warning",
        title: "Kasa oturumu uzun süredir açık",
        detail: `${s.register_name} · ${fmtDay(s.opened_at)} tarihinde açıldı${s.hours_open >= 48 ? ` (${Math.floor(s.hours_open / 24)} gün)` : ""}.`,
        href: "/app/pos",
        action: "Kasaya git",
      });
    }
  }
  if (ordersPending > 0) attention.push({ kind: "orders_pending", level: "warning", title: `${ordersPending} online sipariş onay bekliyor`, detail: "Müşteri talebi stok ayırdı; onaylayın ya da iptal edin.", href: "/app/online-siparisler?durum=new", action: "Siparişleri aç" });
  if ((countsInReview.count ?? 0) > 0) attention.push({ kind: "count_in_review", level: "info", title: `${countsInReview.count} stok sayımı tamamlanmayı bekliyor`, detail: "Sayılıyor ya da incelemede; işlenene kadar stok değişmez.", href: "/app/stok/sayim", action: "Sayımlara git" });
  if (stock.total > 0 && stock.outOfStock > 0) attention.push({ kind: "out_of_stock", level: "info", title: `${stock.outOfStock} ürün seçeneği tükendi`, detail: `${stock.total} aktif seçenekten ${stock.available} tanesi stokta.`, href: "/app/stok?durum=out_of_stock", action: "Stoğu gör" });
  if ((draftReceipts.count ?? 0) > 0) attention.push({ kind: "receipts_draft", level: "info", title: `${draftReceipts.count} taslak mal kabul`, detail: "İşlenene kadar stoğu etkilemez.", href: "/app/mal-kabul?durum=draft", action: "Mal kabule git" });
  if (caps.managerPlus && !timezone) attention.push({ kind: "timezone_missing", level: "info", title: "Saat dilimi ayarlanmamış", detail: "Raporlar varsayılan Europe/Istanbul gününe göre gruplanır.", href: "/app/ayarlar/raporlama", action: "Ayarlara git" });

  const productCount = products.count ?? 0;
  const saleCount = sales.count ?? 0;
  const postedCounts = ((recentCounts.data ?? []) as Array<{ id: string; count_number: string; posted_at: string | null }>);
  const stockDone = stock.available > 0 || postedCounts.length > 0;
  const starter = productCount > 0 && stockDone && saleCount > 0 ? null : { products: productCount > 0, stock: stockDone, sale: saleCount > 0 };

  const activity: Activity[] = [];
  for (const s of (sales.data ?? []) as Array<{ id: string; sale_number: string; occurred_at: string; total: number | string }>) {
    activity.push({ kind: "sale", when: s.occurred_at, title: `Satış ${s.sale_number}`, detail: caps.canViewSales ? `₺${Number(s.total).toLocaleString("tr-TR", { minimumFractionDigits: 2 })}` : null, href: `/app/pos/satis/${s.id}` });
  }
  for (const p of (products.data ?? []) as Array<{ id: string; name: string; created_at: string }>) {
    activity.push({ kind: "product", when: p.created_at, title: p.name, detail: "Ürün eklendi", href: `/app/urunler/${p.id}` });
  }
  for (const c of postedCounts) {
    if (c.posted_at) activity.push({ kind: "count", when: c.posted_at, title: `Sayım ${c.count_number}`, detail: "İşlendi", href: `/app/stok/sayim/${c.id}` });
  }
  for (const o of orders?.rows ?? []) {
    activity.push({ kind: "order", when: o.created_at, title: `Online sipariş ${o.order_number}`, detail: o.customer_name, href: `/app/online-siparisler/${o.id}` });
  }
  activity.sort((a, b) => (a.when < b.when ? 1 : -1));

  const cur = overview?.current ?? null;
  return {
    caps,
    today: cur ? { transactions: cur.transactions, units: cur.units, net_sales: overview?.financial || caps.canViewSales ? cur.net_sales : null, returns_count: cur.returns_count, scope: overview?.scope ?? "own" } : null,
    openSessions,
    attention,
    starter,
    activity: activity.slice(0, 6),
    ordersPending,
    timezoneSet: timezone !== null,
  };
}
