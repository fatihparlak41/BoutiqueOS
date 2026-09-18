import type { UserRole } from "@/lib/roles";
import type { Currency } from "@/lib/receiving/model";

/**
 * Purchase order vocabulary shared by server and client. No data access.
 *
 * A PO is a planning document: nothing here moves stock, cost or liability — only a
 * posted goods receipt does (Phase 8A). Expected costs exist in the payload only for
 * owner/manager; the RPC omits the keys for stock_staff.
 */

export type PoStatus = "draft" | "approved" | "ordered" | "partially_received" | "received" | "closed" | "cancelled";

export const PO_STATUS_LABELS: Record<PoStatus, string> = {
  draft: "Taslak",
  approved: "Onaylı",
  ordered: "Sipariş verildi",
  partially_received: "Kısmen teslim",
  received: "Teslim alındı",
  closed: "Kapatıldı",
  cancelled: "İptal",
};

export const PO_OPEN_STATUSES: PoStatus[] = ["approved", "ordered", "partially_received"];

export type ProcurementCaps = {
  /** purchase_orders SELECT → fn_is_procurement (owner | manager | stock_staff) */
  canView: boolean;
  /** create / edit / approve / order / cancel / close → owner | manager */
  canManage: boolean;
  /** expected cost keys exist only for owner | manager */
  canSeeCost: boolean;
  /** "Mal kabul oluştur" → procurement roles (the receipt engine's own roles) */
  canReceive: boolean;
};

export function procurementCaps(role: UserRole): ProcurementCaps {
  const manager = role === "owner" || role === "manager";
  const procurement = manager || role === "stock_staff";
  return { canView: procurement, canManage: manager, canSeeCost: manager, canReceive: procurement };
}

export type PoListRow = {
  id: string;
  po_number: string;
  status: PoStatus;
  supplier: string;
  branch: string;
  currency: Currency;
  order_date: string;
  expected_date: string | null;
  supplier_reference: string | null;
  lines: number;
  ordered: number;
  received: number;
  remaining: number;
  overdue: boolean;
  expected_total?: number;
  unpriced_lines?: number;
};

export type PoList = {
  financial: boolean;
  rows: PoListRow[];
  summary: { open: number; draft: number; expected_units: number; received_units: number; remaining_units: number; overdue: number };
};

export type PoLine = {
  variant_id: string;
  product_id: string;
  product: string;
  sku: string;
  options: string | null;
  ordered: number;
  received: number;
  remaining: number;
  note: string | null;
  available: number;
  expected_unit_cost?: number | null;
  expected_total?: number | null;
};

export type PoReceiptRef = {
  id: string;
  receipt_number: string;
  status: "draft" | "posted" | "cancelled";
  received_at: string;
  posted_at: string | null;
  reversed: boolean;
  units: number;
  invoice_currency: Currency;
  exchange_rate: number;
};

export type PoActor = { at: string; by: string | null; reason?: string | null } | null;

export type PoDetail = {
  id: string;
  po_number: string;
  status: PoStatus;
  financial: boolean;
  role: UserRole;
  supplier_id: string;
  supplier: string;
  branch_id: string;
  branch: string;
  currency: Currency;
  fx_rate_snapshot: number | null;
  order_date: string;
  expected_date: string | null;
  supplier_reference: string | null;
  note: string | null;
  timeline: { created: PoActor; approved: PoActor; ordered: PoActor; cancelled: PoActor; closed: PoActor };
  lines: PoLine[];
  totals: { ordered: number; received: number; remaining: number; lines: number; expected_total?: number; unpriced_lines?: number };
  receipts: PoReceiptRef[];
  open_draft_receipts: number;
};

/** What the receipt editor shows next to a PO-linked draft: expected vs remaining per variant. */
export type ReceiptPoReference = {
  purchase_order_id: string;
  po_number: string;
  po_status: PoStatus;
  po_currency: Currency;
  financial: boolean;
  lines: Array<{ variant_id: string; ordered: number; received: number; remaining: number; expected_unit_cost?: number | null }>;
};

export const PO_LIST_LIMIT = 200;
