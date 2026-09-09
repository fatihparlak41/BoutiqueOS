import type { UserRole } from "@/lib/tenant";

/**
 * Receiving vocabulary shared by server queries and client forms.
 *
 * The unions mirror the enums from migration 20260908000001 — goods_receipt_status,
 * supplier_status and the iso_currency domain. Nothing here is invented.
 */

export type ReceiptStatus = "draft" | "posted" | "cancelled";
export type SupplierStatus = "active" | "inactive";
export type Currency = "TRY" | "GBP" | "EUR" | "USD";

export const RECEIPT_STATUS_LABELS: Record<ReceiptStatus, string> = {
  draft: "Taslak",
  posted: "İşlendi",
  cancelled: "İptal",
};

export const SUPPLIER_STATUS_LABELS: Record<SupplierStatus, string> = {
  active: "Aktif",
  inactive: "Pasif",
};

/** iso_currency domain: CHECK (VALUE IN ('TRY','GBP','EUR','USD')). */
export const CURRENCIES: Currency[] = ["TRY", "GBP", "EUR", "USD"];

export const BASE_CURRENCY: Currency = "TRY";

export type Supplier = {
  id: string;
  name: string;
  code: string | null;
  currency: Currency;
  status: SupplierStatus;
  contact_name: string | null;
  phone: string | null;
  email: string | null;
  city: string | null;
  country: string;
  notes: string | null;
};

export type ReceiptListRow = {
  id: string;
  receipt_number: string;
  received_at: string;
  status: ReceiptStatus;
  invoice_currency: Currency;
  exchange_rate: number;
  document_ref: string | null;
  supplier_name: string;
  branch_name: string;
  line_count: number;
  total_quantity: number;
  /** Sum of quantity * unit_cost in the invoice currency, computed from the lines. */
  total_original: number;
  posted_at: string | null;
  created_at: string;
};

export type ReceiptLine = {
  id: string;
  variant_id: string;
  product_name: string;
  sku: string;
  options: string;
  primary_barcode: string | null;
  quantity: number;
  unit_cost: number;
  /** Written by rpc_post_goods_receipt; null while the receipt is a draft. */
  fx_rate_snapshot: number | null;
  unit_cost_base: number | null;
  total_cost_base: number | null;
};

export type ReceiptDetail = {
  id: string;
  receipt_number: string;
  received_at: string;
  status: ReceiptStatus;
  invoice_currency: Currency;
  exchange_rate: number;
  document_ref: string | null;
  note: string | null;
  supplier_id: string;
  supplier_name: string;
  branch_id: string;
  branch_name: string;
  posted_at: string | null;
  created_at: string;
  lines: ReceiptLine[];
};

/** A variant offered in the line picker. */
export type PickableVariant = {
  variant_id: string;
  product_id: string;
  product_name: string;
  sku: string;
  options: string;
  primary_barcode: string | null;
};

export type ReceivingCaps = {
  /** suppliers / goods_receipts / goods_receipt_items SELECT => fn_is_procurement */
  canRead: boolean;
  /** suppliers write => fn_is_manager_plus */
  canWriteSupplier: boolean;
  /** draft create + line writes + posting => owner | manager | stock_staff */
  canWriteReceipt: boolean;
  /** variant_cost_pools / inventory_movement_costs SELECT => fn_is_manager_plus */
  canSeePoolCost: boolean;
};

/**
 * Mirrors the RLS predicates so a screen is hidden when the database would refuse it.
 * Hiding is a courtesy; RLS and the RPC role guards are the boundary.
 *
 * Note stock_staff: it may read goods_receipt_items.unit_cost (pol_gri_select is
 * fn_is_procurement) but not variant_cost_pools — that split is deliberate.
 */
export function receivingCaps(role: UserRole): ReceivingCaps {
  const procurement = role === "owner" || role === "manager" || role === "stock_staff";
  const managerPlus = role === "owner" || role === "manager";
  return {
    canRead: procurement,
    canWriteSupplier: managerPlus,
    canWriteReceipt: procurement,
    canSeePoolCost: managerPlus,
  };
}

/** Result envelope for the line picker's server action. */
export type VariantSearchState = {
  error: string | null;
  term: string;
  results: PickableVariant[];
};

export const VARIANT_SEARCH_IDLE: VariantSearchState = { error: null, term: "", results: [] };
