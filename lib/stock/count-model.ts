import type { UserRole } from "@/lib/tenant";
import type { Bucket } from "@/lib/stock/model";

/**
 * Stock count vocabulary. Client-safe: no data access. Mirrors the stock_count_status /
 * stock_count_type enums of migration 20260915150000. The ledger stays authoritative:
 * a count is a working document until POST, and nothing here carries a cost.
 */

export type StockCountStatus = "draft" | "counting" | "review" | "posted" | "cancelled";
export type StockCountType = "full" | "cycle";

export const COUNT_STATUS_LABELS: Record<StockCountStatus, string> = {
  draft: "Taslak",
  counting: "Sayılıyor",
  review: "İncelemede",
  posted: "İşlendi",
  cancelled: "İptal",
};

export const COUNT_TYPE_LABELS: Record<StockCountType, string> = {
  full: "Tam sayım",
  cycle: "Kısmi sayım",
};

export const COUNT_TYPE_HINTS: Record<StockCountType, string> = {
  full: "Şubedeki her şey sayılır. Defterde olup sayılmayan ürünler incelemede açık kalır; 0 ancak siz onaylarsanız yazılır.",
  cycle: "Yalnız saydığınız varyantlar karşılaştırılır; diğer stok dokunulmadan kalır.",
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

export type CountLine = CountVariant & {
  id: string;
  bucket: Bucket;
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
  lines: CountLine[];
};

export type StockCountListRow = Omit<StockCount, "lines"> & { line_count: number; counted_lines: number };

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
};

/** Mirrors the RPC role checks; the database is the boundary, this only hides buttons. */
export function countCaps(role: UserRole): CountCaps {
  return {
    canCount: role === "owner" || role === "manager" || role === "stock_staff",
    canPost: role === "owner" || role === "manager",
  };
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
