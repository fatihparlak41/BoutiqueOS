import type { UserRole } from "@/lib/roles";

/**
 * Reporting vocabulary shared by server and client. No data access here.
 *
 * Every figure comes from one bounded PostgreSQL aggregate (rpc_report_*): the browser
 * never receives transaction rows to add up. Financial keys (COGS, gross profit, margin,
 * valuation, purchasing, supplier liability) exist in the payload only when the RPC
 * decided the caller is owner/manager — the UI renders what is there and never computes
 * a margin itself.
 */

export type ReportCaps = {
  /** Sales-side reports (overview, sales, products, staff, customers, returns): owner / manager / sales_staff. */
  canViewSales: boolean;
  /** Money that is not revenue: COGS, profit, margin, valuation, purchasing, payments. */
  canViewFinancial: boolean;
  /** Stock quantities: every role. */
  canViewStock: boolean;
  /** Reporting timezone setting. */
  canConfigure: boolean;
};

export function reportCaps(role: UserRole): ReportCaps {
  const manager = role === "owner" || role === "manager";
  return {
    canViewSales: manager || role === "sales_staff",
    canViewFinancial: manager,
    canViewStock: true,
    canConfigure: manager,
  };
}

/** Feedback of the timezone form; lives here because a "use server" module may export only actions. */
export type TimezoneActionState = { error: string | null; ok: boolean };
export const TIMEZONE_IDLE: TimezoneActionState = { error: null, ok: false };

/** Platform default when settings.timezone is absent (mirrors fn_business_timezone). */
export const DEFAULT_TIMEZONE = "Europe/Istanbul";

/** Bounded choice for the settings page; the RPC validates against pg_timezone_names anyway. */
export const TIMEZONE_OPTIONS: Array<{ value: string; label: string }> = [
  { value: "Asia/Nicosia", label: "Lefkoşa (Asia/Nicosia, UTC+2 / yaz +3)" },
  { value: "Europe/Istanbul", label: "İstanbul (Europe/Istanbul, UTC+3)" },
  { value: "Europe/London", label: "Londra (Europe/London)" },
  { value: "Europe/Berlin", label: "Berlin (Europe/Berlin)" },
  { value: "Europe/Athens", label: "Atina (Europe/Athens)" },
  { value: "Asia/Dubai", label: "Dubai (Asia/Dubai, UTC+4)" },
  { value: "Asia/Baku", label: "Bakü (Asia/Baku, UTC+4)" },
  { value: "UTC", label: "UTC" },
];

// ------------------------------------------------------------------ periods

export type PeriodPreset = "today" | "yesterday" | "7d" | "month" | "last_month" | "custom";

export const PERIOD_PRESETS: Array<{ key: PeriodPreset; label: string }> = [
  { key: "today", label: "Bugün" },
  { key: "yesterday", label: "Dün" },
  { key: "7d", label: "Son 7 gün" },
  { key: "month", label: "Bu ay" },
  { key: "last_month", label: "Geçen ay" },
  { key: "custom", label: "Özel tarih" },
];

export type Period = {
  preset: PeriodPreset;
  /** Inclusive local calendar days (YYYY-MM-DD) in the tenant timezone. */
  from: string;
  to: string;
  /** The comparable previous window, or null when a preset has no natural predecessor. */
  prevFrom: string | null;
  prevTo: string | null;
  timezone: string;
  timezoneSet: boolean;
};

// ------------------------------------------------------------------ payload shapes (what the RPCs return)

export type PeriodTotals = {
  transactions: number;
  units: number;
  gross_sales: number;
  discounts: number;
  net_sales: number;
  avg_basket: number | null;
  returns_count: number;
  exchanges_count: number;
  returned_units: number;
  returns_value: number;
  net_sales_after_returns: number;
  /** manager+ only */
  cogs?: number;
  returned_cogs?: number;
  gross_profit?: number;
  gross_margin_pct?: number | null;
};

export type DailyPoint = {
  date: string;
  transactions: number;
  units: number;
  net_sales: number;
  returns_count: number;
  returns_value: number;
  gross_profit?: number;
};

export type ReportPeriodInfo = { from: string; to: string; timezone: string; timezone_set?: boolean; prev_from?: string | null; prev_to?: string | null };

export type OverviewReport = {
  period: ReportPeriodInfo;
  scope: "own" | "branch" | "business";
  financial: boolean;
  current: PeriodTotals;
  previous: PeriodTotals | null;
  daily: DailyPoint[];
};

export type SalesReport = {
  period: ReportPeriodInfo;
  scope: string;
  financial: boolean;
  filters: { branch_id: string | null; salesperson_id: string | null; category_id: string | null; product_id: string | null };
  totals: PeriodTotals;
  daily: DailyPoint[];
  by_branch: Array<{ branch_id: string; branch: string; transactions: number; units: number; net_sales: number; returns_value: number }>;
};

export type ProductRow = {
  key: string;
  label: string;
  sub: string | null;
  transactions: number;
  units: number;
  gross_sales: number;
  discounts: number;
  net_sales: number;
  returns_count: number;
  returned_units: number;
  returns_value: number;
  net_sales_after_returns: number;
  cogs?: number;
  returned_cogs?: number;
  gross_profit?: number;
  gross_margin_pct?: number | null;
};

export type ProductGroup = "product" | "variant" | "category" | "color" | "size";

export const PRODUCT_GROUPS: Array<{ key: ProductGroup; label: string }> = [
  { key: "product", label: "Ürün" },
  { key: "variant", label: "Varyant" },
  { key: "category", label: "Kategori" },
  { key: "color", label: "Renk" },
  { key: "size", label: "Beden" },
];

export function isProductGroup(v: string | undefined): v is ProductGroup {
  return v === "product" || v === "variant" || v === "category" || v === "color" || v === "size";
}

export type ProductsReport = {
  period: ReportPeriodInfo;
  scope: string;
  financial: boolean;
  group: ProductGroup;
  rows: ProductRow[];
  top_sizes: ProductRow[];
  top_colors: ProductRow[];
  out_of_stock_with_sales: Array<{ variant_id: string; sku: string; product: string; units_sold: number; available: number }>;
};

export type StaffRow = {
  user_id: string;
  name: string;
  transactions: number;
  units: number;
  gross_sales: number;
  discounts: number;
  net_sales: number;
  avg_basket: number | null;
  returns_count: number;
  returned_units: number;
  returns_value: number;
  net_sales_after_returns: number;
  gross_profit?: number;
  gross_margin_pct?: number | null;
};

export type StaffReport = {
  period: ReportPeriodInfo;
  scope: string;
  financial: boolean;
  salespeople: StaffRow[];
  cashiers: Array<{ user_id: string; name: string; transactions: number; net_sales: number }>;
};

export type PaymentsReport = {
  period: ReportPeriodInfo;
  financial: true;
  sales: { transactions: number; net_sales: number; credit_applied: number; tendered_base: number; change_given: number; split_payment_sales: number };
  by_method: Array<{ method: string; currency: string; amount: number; amount_base: number; payments: number; sales: number }>;
  refunds: Array<{ method: string | null; amount_base: number; returns: number }>;
  refund_total: number;
  net_payment_movement: number;
  drawer: Array<{ movement_type: string; currency: string; amount: number; amount_base: number; count: number }>;
};

export type StockReport = {
  branch_id: string | null;
  financial: boolean;
  low_threshold: number;
  totals: { variants: number; sellable: number; reserved: number; available: number; damaged: number; quarantine: number; out_of_stock: number; low_stock: number };
  out_of_stock: Array<{ variant_id: string; sku: string; product: string; sellable: number; reserved: number }>;
  low_stock: Array<{ variant_id: string; sku: string; product: string; sellable: number; reserved: number; available: number }>;
  valuation: { on_hand_qty: number; total_value_base: number; variants_with_stock: number } | null;
};

export type ReceivingReport = {
  period: ReportPeriodInfo;
  financial: true;
  totals: { receipts: number; units: number; purchase_value_base: number; charges_base: number; landed_total_base: number; liability_base: number; reversed_receipts: number };
  reversals: { count: number; value_removed_base: number };
  by_supplier: Array<{ supplier_id: string; supplier: string; receipts: number; units: number; purchase_value_base: number; landed_total_base: number; liability_base: number }>;
};

export type CustomersReport = {
  period: ReportPeriodInfo;
  scope: string;
  financial: boolean;
  totals: {
    sales: number;
    identified_sales: number;
    walk_in_sales: number;
    customers_with_sale: number;
    repeat_customers: number;
    identified_net_sales: number;
    walk_in_net_sales: number;
    new_customers: number;
  };
  top: Array<{ customer_id: string; name: string | null; sales: number; units: number; net_spend: number; returns_value: number; last_purchase_at: string | null }>;
};

export type ReturnsReport = {
  period: ReportPeriodInfo;
  scope: string;
  financial: boolean;
  totals: { returns: number; exchanges: number; refunds: number; store_credits: number; returned_units: number; returns_value: number; refund_amount: number; returned_cogs?: number };
  by_reason: Array<{ code: string | null; label: string; returns: number; units: number; value: number }>;
  by_disposition: Array<{ disposition: "sellable" | "damaged" | "quarantine"; units: number; value: number }>;
  by_type: Array<{ return_type: "refund" | "exchange" | "store_credit"; returns: number; units: number; value: number }>;
  rate_by_product: Array<{ product_id: string; product: string; sold_units: number; returned_units: number; returns: number; rate_pct: number | null; meaningful: boolean }>;
  rate_by_size: Array<{ size: string; sold_units: number; returned_units: number; returns: number; rate_pct: number | null; meaningful: boolean }>;
};

// ------------------------------------------------------------------ labels

export const PAYMENT_METHOD_LABELS: Record<string, string> = {
  cash: "Nakit",
  card: "Kart",
  bank_transfer: "Havale",
  other: "Diğer",
};

export const DRAWER_MOVEMENT_LABELS: Record<string, string> = {
  sale_cash: "Satış nakdi",
  change_out: "Para üstü",
  void_cash_out: "İptal iadesi",
  refund_cash_out: "Nakit iade",
  cash_in: "Kasaya giriş",
  cash_out: "Kasadan çıkış",
  expense: "Masraf",
};

export const DISPOSITION_LABELS: Record<string, string> = {
  sellable: "Satılabilir",
  damaged: "Hasarlı",
  quarantine: "Karantina",
};

export const RETURN_TYPE_LABELS: Record<string, string> = {
  refund: "İade (para)",
  exchange: "Değişim",
  store_credit: "Mağaza kredisi",
};

/**
 * Metric definitions, shown on the pages so "ciro" is never ambiguous. They mirror the
 * SQL in migration 20260917100000 and docs/10 §21.
 */
export const METRIC_DEFINITIONS: Array<{ key: string; label: string; definition: string; financial?: boolean }> = [
  { key: "gross_sales", label: "Brüt satış", definition: "Satılan kalemlerin liste fiyatı × adet (tamamlanmış satışlar, iptaller hariç)." },
  { key: "discounts", label: "İndirim", definition: "Kalem indirimlerinin toplamı (liste fiyatı − satış fiyatı) × adet." },
  { key: "net_sales", label: "Net satış", definition: "Brüt satış − indirim; müşterinin mal için borçlandığı tutar. Değişimde verilen yeni ürün tam değeriyle sayılır." },
  { key: "returns_value", label: "İade değeri", definition: "Dönemde işlenen iade/değişim satırlarının satış anındaki fiyatı × adet (iade, kendi tarihine yazılır)." },
  { key: "net_sales_after_returns", label: "İade sonrası net", definition: "Net satış − iade değeri." },
  { key: "transactions", label: "İşlem", definition: "Tamamlanmış satış belgesi sayısı." },
  { key: "avg_basket", label: "Ortalama sepet", definition: "Net satış ÷ işlem sayısı." },
  { key: "cogs", label: "Satılan malın maliyeti", definition: "Satış anında kilitlenen tarihsel maliyet (sale_item_costs); bugünkü stok maliyetiyle yeniden hesaplanmaz.", financial: true },
  { key: "gross_profit", label: "Brüt kâr", definition: "İade sonrası net − (tarihsel maliyet − iade edilen tarihsel maliyet).", financial: true },
  { key: "gross_margin_pct", label: "Brüt marj", definition: "Brüt kâr ÷ iade sonrası net; net sıfırsa gösterilmez.", financial: true },
];
