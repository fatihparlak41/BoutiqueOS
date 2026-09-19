import type { UserRole } from "@/lib/tenant";
import type { Bucket } from "@/lib/stock/model";

/**
 * Stock count vocabulary. Client-safe: no data access. Mirrors the stock_count_status /
 * stock_count_type enums of migration 20260915150000. The ledger stays authoritative:
 * a count is a working document until POST. The only cost a count carries is the
 * Phase 15B-0 bridge: an explicit owner/manager unit cost for a surplus that the ledger
 * cannot price (stock_count_line_costs, manager+ only; never loaded for other roles).
 */

export type StockCountStatus = "draft" | "counting" | "review" | "posted" | "cancelled";
export type StockCountType = "full" | "cycle";

export const COUNT_STATUS_LABELS: Record<StockCountStatus, string> = {
  draft: "Taslak",
  counting: "Sayılıyor",
  review: "İncelemede",
  posted: "Tamamlandı",
  cancelled: "İptal",
};

export const COUNT_TYPE_LABELS: Record<StockCountType, string> = {
  full: "Tüm mağaza",
  cycle: "Bir kısmı",
};

export const COUNT_TYPE_HINTS: Record<StockCountType, string> = {
  full: "Şubedeki her şey sayılır. Sistemde olup okutulmayan ürünler incelemede açık kalır; 0 ancak sen onaylarsan yazılır.",
  cycle: "Yalnız okuttuğun ürün seçenekleri karşılaştırılır; diğer stok dokunulmadan kalır.",
};

/** What the count knows about a variant; enough to recognise the garment in hand. */
export type CountVariant = {
  variant_id: string;
  product_id: string;
  product_name: string;
  sku: string;
  /** "Siyah / M" */
  options: string;
  color: string | null;
  size: string | null;
  primary_barcode: string | null;
  /** Short-lived signed URL of the product's main image, or null. */
  thumbnail_url: string | null;
};

/** Where an entered opening cost comes from. Mirrors the stock_count_cost_source enum. */
export type CountCostSource = "documented_purchase" | "owner_declared_opening_cost";

export const COST_SOURCE_LABELS: Record<CountCostSource, string> = {
  documented_purchase: "Belgeli alış (fatura / fiş)",
  owner_declared_opening_cost: "Sahip beyanı (açılış maliyeti)",
};

export const COST_SOURCE_HINTS: Record<CountCostSource, string> = {
  documented_purchase: "Tedarikçi faturası ya da fişiyle desteklenen birim alış maliyeti; referansı açıklamaya yazın.",
  owner_declared_opening_cost: "Belgeye bağlanmamış, sahibin beyan ettiği maliyet. Fatura doğrulaması ima etmez.",
};

/** The manager-entered cost of one count line (owner/manager only; absent for other roles). */
export type CountLineCost = {
  unit_cost_base: number;
  cost_source: CountCostSource;
  note: string | null;
  entered_at: string;
  /** Written by POST: true = priced the surplus; false = the pool had a basis, moving average used. */
  applied: boolean | null;
  applied_quantity: number | null;
  applied_value_base: number | null;
};

export type CountLine = CountVariant & {
  id: string;
  bucket: Bucket;
  /** Set at review: counted above expected on a pool with no usable cost basis. Operational, carries no value. */
  cost_required: boolean;
  /** Only loaded for owner/manager; null otherwise or when nothing was entered. */
  cost: CountLineCost | null;
  /** Ledger quantity captured at review; null before the count entered review. */
  expected_quantity: number | null;
  /** null = not counted / unresolved. 0 only through an explicit action. */
  counted_quantity: number | null;
  zero_confirmed: boolean;
  counted_at: string | null;
  /** Filled by POST. */
  posted_delta: number | null;
};

export type StockCount = {
  id: string;
  count_number: string;
  count_type: StockCountType;
  status: StockCountStatus;
  branch_id: string;
  branch_name: string;
  note: string | null;
  created_by_name: string | null;
  created_at: string;
  counting_started_at: string | null;
  reviewed_at: string | null;
  posted_at: string | null;
  posted_by_name: string | null;
  cancelled_at: string | null;
  cancel_reason: string | null;
  /** Fingerprint of the reviewed document; POST sends it back so a re-reviewed document is refused. */
  review_hash: string | null;
  /** businesses.base_currency — every count cost is in it. */
  base_currency: string;
  lines: CountLine[];
};

export type StockCountListRow = Omit<StockCount, "lines" | "review_hash" | "base_currency"> & { line_count: number; counted_lines: number };

export type PostSummary = {
  count_id: string;
  count_number: string;
  lines: number;
  adjustments: number;
  shortage_units: number;
  surplus_units: number;
};

export type CountCaps = {
  /** owner | manager | stock_staff: create, scan, review, reopen (fn_is_procurement) */
  canCount: boolean;
  /** owner | manager only: POST (rpc_stock_count_post) and cancel */
  canPost: boolean;
  /** owner | manager only: read and enter the opening cost of a surplus line (rpc_stock_count_set_line_cost) */
  canCost: boolean;
};

/** Mirrors the RPC role checks; the database is the boundary, this only hides buttons. */
export function countCaps(role: UserRole): CountCaps {
  return {
    canCount: role === "owner" || role === "manager" || role === "stock_staff",
    canPost: role === "owner" || role === "manager",
    canCost: role === "owner" || role === "manager",
  };
}

/** Lines whose surplus cannot be posted until a cost is entered. */
export function costPendingLines(lines: CountLine[]): CountLine[] {
  return lines.filter((l) => l.cost_required && !l.cost);
}

export function formatBaseMoney(value: number, currency: string): string {
  return new Intl.NumberFormat("tr-TR", { style: "currency", currency, minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value);
}

export function lineDifference(line: CountLine): number | null {
  if (line.counted_quantity === null || line.expected_quantity === null) return null;
  return line.counted_quantity - line.expected_quantity;
}

export function formatSigned(n: number): string {
  return n > 0 ? `+${n}` : String(n);
}

export type ReviewFilter = "all" | "differences" | "shortages" | "surpluses" | "zero" | "unresolved";

export const REVIEW_FILTER_LABELS: Record<ReviewFilter, string> = {
  all: "Tümü",
  differences: "Yalnız farklar",
  shortages: "Eksikler",
  surpluses: "Fazlalar",
  zero: "0 onaylananlar",
  unresolved: "Sayılmamış",
};

export function matchesReviewFilter(line: CountLine, filter: ReviewFilter): boolean {
  const diff = lineDifference(line);
  switch (filter) {
    case "all": return true;
    case "differences": return diff !== null && diff !== 0;
    case "shortages": return diff !== null && diff < 0;
    case "surpluses": return diff !== null && diff > 0;
    case "zero": return line.zero_confirmed;
    case "unresolved": return line.counted_quantity === null;
  }
}

export function summarize(lines: CountLine[]) {
  let counted = 0, differences = 0, shortage = 0, surplus = 0, unresolved = 0;
  for (const l of lines) {
    if (l.counted_quantity === null) { unresolved++; continue; }
    counted++;
    const d = lineDifference(l);
    if (d === null || d === 0) continue;
    differences++;
    if (d < 0) shortage += -d; else surplus += d;
  }
  return { counted, differences, shortage, surplus, unresolved };
}

/** "15.09.2026 10:57" in the boutique's locale; "—" when there is no timestamp yet. */
export function formatWhen(iso: string | null): string {
  if (!iso) return "—";
  return new Intl.DateTimeFormat("tr-TR", { dateStyle: "short", timeStyle: "short" }).format(new Date(iso));
}
