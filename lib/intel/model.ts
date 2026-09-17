import type { UserRole } from "@/lib/roles";

/**
 * Fashion-intelligence vocabulary shared by server and client. No data access.
 *
 * Every signal comes from one deterministic PostgreSQL rule (rpc_intel_*) and carries the
 * numbers that produced it; the UI never ranks, scores or extrapolates on its own.
 * Financial keys (stock value) exist in the payload only for owner/manager; sales-side
 * sections are null for stock_staff. The thresholds below mirror the RPC defaults and are
 * shown on the page so a reader knows why a row is there.
 */

export type IntelCaps = {
  canView: boolean;
  canViewSales: boolean;
  canViewFinancial: boolean;
};

export function intelCaps(role: UserRole): IntelCaps {
  const manager = role === "owner" || role === "manager";
  return { canView: true, canViewSales: manager || role === "sales_staff", canViewFinancial: manager };
}

export const INTEL_WINDOWS: Array<{ days: number; label: string }> = [
  { days: 14, label: "Son 14 gün" },
  { days: 30, label: "Son 30 gün" },
  { days: 90, label: "Son 90 gün" },
];

/** Defaults mirrored from rpc_intel_home; the page echoes what the RPC actually used. */
export const INTEL_DEFAULTS = {
  days: 30,
  min_sample: 10,
  min_stock: 2,
  slow_age_days: 60,
  slow_no_sale_days: 30,
  slow_min_qty: 3,
  replenish_min_sold: 3,
  excess_min_qty: 10,
  excess_cover_days: 120,
  fast_min_units: 3,
  fast_min_active_days: 7,
} as const;

export type IntelWindow = { days: number; from: string; to: string; timezone: string };

export type IntelThresholds = {
  min_sample: number;
  min_stock: number;
  slow_age_days: number;
  slow_no_sale_days: number;
  slow_min_qty: number;
  replenish_min_sold: number;
  excess_min_qty: number;
  excess_cover_days: number;
};

export type FastMover = {
  product_id: string;
  product: string;
  category: string | null;
  sold_win: number;
  returned_win: number;
  active_days: number;
  velocity: number;
  available: number;
  variants_out: number;
  variants: number;
  days_of_cover: number | null;
  sell_through_pct: number | null;
};

export type VariantSignal = {
  variant_id: string;
  product_id: string;
  product: string;
  sku: string;
  size: string | null;
  color: string | null;
  available: number;
  sold_win: number;
  why?: string;
  age_days?: number | null;
  days_since_sale?: number | null;
  sellable_value?: number | null;
  holds_active?: number;
  velocity?: number;
  days_of_cover?: number | null;
  last_sale_at?: string | null;
};

export type BrokenSizeRun = {
  product_id: string;
  product: string;
  sizes_available: string | null;
  sizes_missing: string | null;
  sizes_never_stocked: string | null;
  sold_win: number;
  sold_win_missing_sizes: number | null;
  holds_active: number;
  available: number;
};

export type AgingBucket = { bucket: string; order: number; units: number; variants: number; value: number | null; no_sale_units: number };

export type ReturnSignal = {
  kind: "product" | "size" | "variant";
  key: string;
  label: string;
  sold_win: number;
  returned_win: number;
  rate_pct: number | null;
  meaningful: boolean;
};

export type HoldSignal = {
  variant_id: string;
  product_id: string;
  product: string;
  sku: string;
  size: string | null;
  color: string | null;
  holds_active: number;
  reserved: number;
  available: number;
  sellable: number;
  converted_win: number;
  cancelled_win: number;
  expired_win: number;
  low_stock: boolean;
};

export type IntelHome = {
  window: IntelWindow;
  thresholds: IntelThresholds;
  role: UserRole;
  financial: boolean;
  sales: boolean;
  scope: "own" | "branch" | "business";
  summary: {
    variants: number;
    products: number;
    with_stock: number;
    out_of_stock: number;
    never_stocked: number;
    sold_win: number;
    returned_win: number;
    sales_win: number;
    holds_active: number;
    enough_data: boolean;
  };
  fast_movers: FastMover[] | null;
  slow_movers: VariantSignal[] | null;
  broken_size_runs: BrokenSizeRun[];
  out_of_stock: VariantSignal[];
  replenishment: VariantSignal[] | null;
  excess: VariantSignal[] | null;
  aging: AgingBucket[];
  return_signals: ReturnSignal[] | null;
  reservation_demand: HoldSignal[] | null;
};

export type DimensionRow = {
  value: string;
  sold_win: number;
  returned_win: number;
  share_pct: number | null;
  return_rate_pct: number | null;
  available: number;
  sellable: number;
  reserved: number;
  variants: number;
  variants_out: number;
  holds_active: number;
};

export type IntelDimensions = {
  window: IntelWindow;
  min_sample: number;
  financial: boolean;
  sales: boolean;
  scope: string;
  filters: { category_id: string | null; product_id: string | null };
  sold_win: number;
  sold_sized: number;
  sold_colored: number;
  sizes: DimensionRow[];
  colors: DimensionRow[];
};

export type IntelProduct = {
  window: IntelWindow;
  min_sample: number;
  financial: boolean;
  sales: boolean;
  scope: string;
  enough_data: boolean;
  variants: number;
  variants_out: number;
  sold_win: number;
  returned_win: number;
  sold_all: number;
  returned_all: number;
  supplied: number;
  sell_through_pct: number | null;
  active_days: number | null;
  velocity: number | null;
  days_of_cover: number | null;
  return_rate_pct: number | null;
  stock: { sellable: number; reserved: number; available: number; damaged: number; quarantine: number };
  holds_active: number | null;
  first_arrival: string | null;
  age_days: number | null;
  last_sale_at: string | null;
  days_since_sale: number | null;
  stock_value: number | null;
  sizes: Array<{ value: string; sold_win: number; returned_win: number; share_pct: number | null; return_rate_pct: number | null; available: number; out: boolean; never_stocked: boolean; holds_active: number }>;
  colors: Array<{ value: string; sold_win: number; returned_win: number; share_pct: number | null; available: number; out: boolean }>;
  variants_detail: Array<{ variant_id: string; sku: string; size: string | null; color: string | null; sold_win: number; returned_win: number; available: number; reserved: number; supplied: number; age_days: number | null; days_since_sale: number | null; holds_active: number }>;
};

/** Definitions shown on the pages; they mirror migration 20260917150000. */
export const INTEL_DEFINITIONS: Array<{ label: string; definition: string; financial?: boolean }> = [
  { label: "Arz edilen adet", definition: "Satılabilir kovaya mal kabul, transfer, artı düzeltme ya da durum değişikliğiyle giren adet (açılış stoku dahil). Müşteri iadesi ve iptal arz sayılmaz." },
  { label: "Sell-through", definition: "(Satılan − iade edilen) ÷ arz edilen adet, varyantın tüm geçmişi üzerinden. Parti takibi olmadığından yeni alım oranı düşürür." },
  { label: "Stok yaşı", definition: "Bugün − ilk satılabilir giriş tarihi; yalnız hâlâ satılabilir stoku olan varyantlar. Yeniden alım yaşı sıfırlamaz." },
  { label: "Satış hızı", definition: "Dönemde satılan adet ÷ aktif gün (dönem günü ile ilk girişten bu yana geçen günün küçüğü)." },
  { label: "Kaç günlük stok", definition: "Müsait adet ÷ satış hızı; hız sıfırsa gösterilmez." },
  { label: "Müsait", definition: "Satılabilir − aktif ve süresi dolmamış rezervasyon." },
  { label: "İade oranı", definition: "Dönemde iade edilen ÷ satılan adet; yüzde yalnız satılan adet örneklem eşiğini geçince gösterilir." },
  { label: "Bedeni kırılan ürün", definition: "Bedenli varyantlarından bazıları müsaitken, daha önce arz edilmiş en az bir bedeni tükenen ürün." },
  { label: "Hızlı satan", definition: "Dönemde en az 3 adet satmış ve en az 7 aktif günü olan ürünler, satış hızına göre. Ömür boyu toplam adet tek başına ölçüt değildir." },
  { label: "Yavaş hareket eden", definition: "Yaş ≥ eşik, müsait ≥ eşik, dönemde ≤ 1 satış ve son satıştan bu yana ≥ eşik gün (ya da hiç satılmamış). Yeni gelen ürün yavaş sayılmaz." },
  { label: "Yeniden sipariş adayı", definition: "Dönemde ≥ eşik adet satılıp müsaidi ≤ minimum stok kalan, ya da aktif rezervasyonu müsaidine eşit veya fazla olan varyant. Sipariş oluşturulmaz." },
  { label: "Fazla stok adayı", definition: "Müsaidi ≥ eşik, yaşı ≥ eşik ve bu hızla ≥ eşik günlük stoku olan (ya da hiç satmayan) varyant. İndirim önerilmez." },
  { label: "Stok değeri", definition: "Mevcut maliyet havuzunun ortalama maliyeti × satılabilir adet; tarihsel kâr için kullanılmaz.", financial: true },
];
